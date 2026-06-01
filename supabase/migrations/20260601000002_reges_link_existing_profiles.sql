-- REGES employee bridge: auto-link records to already-registered profiles.
--
-- Background:
--   ingest_reges_batch used to always insert REGES rows in a "staged" state
--   (employee_pii.user_id = NULL, profile_invites.email = NULL) and rely on
--   the handle_user_registration trigger to backfill user_id when the
--   employee later signed up via OTP. That works for the common path
--   (employer uploads REGES before the employee registers) but breaks for
--   two real cases:
--
--     1. HR uploads a REGES that includes themselves. HR is already
--        registered (typically via scripts/dev/create-company.sh), so the
--        trigger never re-fires and HR's CNP / address / DOB live in a
--        detached PII row that contract/TBI flows can't see.
--     2. An employee registers via OTP before their company's first REGES
--        upload (e.g. invited manually, then later mass-imported). Same
--        symptom.
--
-- Fix: before inserting/updating in either table, look up
--   profiles.user_id WHERE company_id = p_company_id
--                       AND lower(email) = lower(derived_email)
-- When a match is found, link the new REGES rows directly:
--   - profile_invites.user_id + status='active' (skip staged state)
--   - employee_pii.user_id = matched user; if that user already has a PII
--     row (the unique index forbids two), MERGE REGES fields into the
--     existing row.
--
-- Result codes (new):
--   pii_status:    "created_linked" | "merged"
--   invite_status: "created_linked"
-- Existing codes ("created"/"updated"/"skipped_claimed") are unchanged for
-- the staged path (no profile match → previous behaviour).

CREATE OR REPLACE FUNCTION public.ingest_reges_batch(
  p_company_id uuid,
  p_records    jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  rec                jsonb;
  v_invite_id        uuid;
  v_pii_id           uuid;
  v_invite_status    text;
  v_pii_status       text;
  v_was_radiat       boolean;
  v_existing_email   text;
  v_existing_user    uuid;
  -- Pre-flight match: registered profile that already owns derived_email.
  v_match_user       uuid;
  v_match_pii_id     uuid;
  out_results        jsonb := '[]'::jsonb;
BEGIN
  FOR rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    -- 0. Pre-flight: does a registered profile already own derived_email?
    -- Scoped to p_company_id so cross-tenant users never collide.
    v_match_user   := NULL;
    v_match_pii_id := NULL;
    IF rec->>'derived_email' IS NOT NULL THEN
      SELECT user_id INTO v_match_user
        FROM profiles
       WHERE company_id = p_company_id
         AND lower(email) = lower(rec->>'derived_email')
       LIMIT 1;
      IF v_match_user IS NOT NULL THEN
        -- May or may not exist; either way we want a row-level lock so a
        -- concurrent update-employee-pii doesn't race the merge below.
        SELECT id INTO v_match_pii_id
          FROM employee_pii
         WHERE user_id = v_match_user
         FOR UPDATE;
      END IF;
    END IF;

    -- 1. profile_invites upsert (claim-aware) -----------------------------
    SELECT id, email, radiat
      INTO v_invite_id, v_existing_email, v_was_radiat
      FROM profile_invites
     WHERE company_id    = p_company_id
       AND source        = 'reges'
       AND source_ref_id = rec->>'source_ref_id'
     FOR UPDATE;

    IF v_invite_id IS NULL THEN
      -- New REGES invite. When pre-matched to a registered user, attach
      -- directly (status='active', user_id set). Email is still left NULL
      -- to avoid colliding with any manual invite for the same address
      -- (the unique index on lower(email) is partial WHERE email IS NOT
      -- NULL); linkage flows through user_id instead.
      INSERT INTO profile_invites (
        company_id, email, source, source_ref_id,
        first_name, last_name,
        birth_date_hash, derived_email, radiat,
        status, user_id
      ) VALUES (
        p_company_id, NULL, 'reges', rec->>'source_ref_id',
        rec->>'first_name', rec->>'last_name',
        rec->>'birth_date_hash', rec->>'derived_email',
        COALESCE((rec->>'radiat')::boolean, false),
        CASE WHEN v_match_user IS NOT NULL
          THEN 'active'::user_profile_status
          ELSE 'inactive'::user_profile_status
        END,
        v_match_user
      ) RETURNING id INTO v_invite_id;
      v_invite_status := CASE WHEN v_match_user IS NOT NULL
                              THEN 'created_linked'
                              ELSE 'created'
                          END;

    ELSIF v_existing_email IS NOT NULL THEN
      -- Already claimed via OTP signup. Surface radiat transition only.
      IF COALESCE((rec->>'radiat')::boolean, false) AND NOT v_was_radiat THEN
        UPDATE profile_invites
           SET radiat = true
         WHERE id = v_invite_id;
        INSERT INTO company_notifications (company_id, event, event_type, payload)
        VALUES (
          p_company_id, 'user_update', 'reges_terminated',
          jsonb_build_object('invite_id', v_invite_id,
                             'email',     v_existing_email,
                             'employee_name',
                               COALESCE(rec->>'first_name', '') || ' ' ||
                               COALESCE(rec->>'last_name', ''))
        );
      END IF;
      v_invite_status := 'skipped_claimed';

    ELSE
      UPDATE profile_invites SET
        first_name      = rec->>'first_name',
        last_name       = rec->>'last_name',
        birth_date_hash = rec->>'birth_date_hash',
        derived_email   = rec->>'derived_email',
        radiat          = COALESCE((rec->>'radiat')::boolean, false)
      WHERE id = v_invite_id;
      v_invite_status := 'updated';
    END IF;

    -- 2. employee_pii upsert (claim-aware) --------------------------------
    SELECT id, user_id
      INTO v_pii_id, v_existing_user
      FROM employee_pii
     WHERE company_id    = p_company_id
       AND source        = 'reges'
       AND source_ref_id = rec->>'source_ref_id'
     FOR UPDATE;

    IF v_pii_id IS NULL THEN
      IF v_match_user IS NOT NULL AND v_match_pii_id IS NOT NULL THEN
        -- Matched user already has a PII row (e.g. HR who entered their
        -- own PII via update-employee-pii before the REGES upload).
        -- The employee_pii_user_unique index forbids a second row, so MERGE:
        -- REGES fields overwrite NULLs but keep any value the user already
        -- set themselves (COALESCE(new, existing)).
        UPDATE employee_pii SET
          profile_invite_id       = v_invite_id,
          source                  = 'reges',
          source_ref_id           = rec->>'source_ref_id',
          national_id_encrypted   = COALESCE(national_id_encrypted,   rec->>'national_id_encrypted'),
          home_address_encrypted  = COALESCE(home_address_encrypted,  rec->>'home_address_encrypted'),
          date_of_birth_encrypted = COALESCE(date_of_birth_encrypted, rec->>'date_of_birth_encrypted'),
          locality_code           = COALESCE(locality_code,           rec->>'locality_code'),
          locality_code_system    = COALESCE(locality_code_system,    rec->>'locality_code_system'),
          nationality_iso         = COALESCE(nationality_iso,         rec->>'nationality_iso'),
          country_of_domicile_iso = COALESCE(country_of_domicile_iso, rec->>'country_of_domicile_iso'),
          id_document_type        = COALESCE(id_document_type,        rec->>'id_document_type')
        WHERE id = v_match_pii_id
        RETURNING id INTO v_pii_id;
        v_pii_status := 'merged';
      ELSE
        -- Either no profile match (legacy staged path → user_id=NULL) or
        -- profile matched but they have no PII row yet (direct link).
        INSERT INTO employee_pii (
          user_id, company_id, profile_invite_id, source, source_ref_id, country,
          national_id_encrypted, home_address_encrypted, date_of_birth_encrypted,
          locality_code, locality_code_system,
          nationality_iso, country_of_domicile_iso, id_document_type
        ) VALUES (
          v_match_user,
          p_company_id, v_invite_id, 'reges', rec->>'source_ref_id', 'RO',
          rec->>'national_id_encrypted',
          rec->>'home_address_encrypted',
          rec->>'date_of_birth_encrypted',
          rec->>'locality_code', rec->>'locality_code_system',
          rec->>'nationality_iso', rec->>'country_of_domicile_iso',
          rec->>'id_document_type'
        ) RETURNING id INTO v_pii_id;
        v_pii_status := CASE WHEN v_match_user IS NOT NULL
                             THEN 'created_linked'
                             ELSE 'created'
                         END;
      END IF;

    ELSIF v_existing_user IS NOT NULL THEN
      v_pii_status := 'skipped_claimed';

    ELSE
      UPDATE employee_pii SET
        profile_invite_id       = v_invite_id,
        national_id_encrypted   = rec->>'national_id_encrypted',
        home_address_encrypted  = rec->>'home_address_encrypted',
        date_of_birth_encrypted = rec->>'date_of_birth_encrypted',
        locality_code           = rec->>'locality_code',
        locality_code_system    = rec->>'locality_code_system',
        nationality_iso         = rec->>'nationality_iso',
        country_of_domicile_iso = rec->>'country_of_domicile_iso',
        id_document_type        = rec->>'id_document_type'
      WHERE id = v_pii_id;
      v_pii_status := 'updated';
    END IF;

    -- 3. integration_messages audit row -----------------------------------
    INSERT INTO integration_messages (
      company_id, integration, operation, entity_type, entity_id,
      direction, status, result_code, result_payload, processed_at
    ) VALUES (
      p_company_id, 'reges', 'import_employee', 'employee_pii', v_pii_id,
      'inbound', 'success',
      v_pii_status,
      jsonb_build_object('invite_status', v_invite_status,
                         'source_ref_id', rec->>'source_ref_id',
                         'derived_email_set', (rec->>'derived_email' IS NOT NULL),
                         'matched_user',   v_match_user),
      now()
    );

    -- 4. Per-record outcome ----------------------------------------------
    out_results := out_results || jsonb_build_object(
      'source_ref_id',   rec->>'source_ref_id',
      'status',          v_pii_status,
      'invite_id',       v_invite_id,
      'employee_pii_id', v_pii_id,
      'invite_status',   v_invite_status,
      'matched_user',    v_match_user
    );
  END LOOP;

  RETURN out_results;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ingest_reges_batch(uuid, jsonb) TO service_role;
