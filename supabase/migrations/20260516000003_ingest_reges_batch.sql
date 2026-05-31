-- REGES employee bridge: single-RPC batch ingest
--
-- The edge function does all crypto in the runtime (the key stays out of the
-- database) and then hands a fully-prepared jsonb array to this PL/pgSQL
-- function for one round-trip DB write. Per-record FOR UPDATE locks keep
-- two concurrent uploads of the same source_ref_id from racing. Production
-- batches (1000+ rows) finish well inside the 150s edge-function budget.
--
-- Per-record skip semantics:
--   profile_invites: skip update when email IS NOT NULL  -> 'skipped_claimed'
--   employee_pii:    skip update when user_id IS NOT NULL -> 'skipped_claimed'
-- A radiat=false -> true transition on an already-claimed invite raises a
-- company_notifications event so HR sees the termination in the dashboard.

CREATE OR REPLACE FUNCTION public.ingest_reges_batch(
  p_company_id uuid,
  p_records    jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  rec               jsonb;
  v_invite_id       uuid;
  v_pii_id          uuid;
  v_invite_status   text;
  v_pii_status      text;
  v_was_radiat      boolean;
  v_existing_email  text;
  v_existing_user   uuid;
  out_results       jsonb := '[]'::jsonb;
BEGIN
  FOR rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    -- 1. profile_invites upsert (claim-aware) -----------------------------
    SELECT id, email, radiat
      INTO v_invite_id, v_existing_email, v_was_radiat
      FROM profile_invites
     WHERE company_id    = p_company_id
       AND source        = 'reges'
       AND source_ref_id = rec->>'source_ref_id'
     FOR UPDATE;

    IF v_invite_id IS NULL THEN
      INSERT INTO profile_invites (
        company_id, email, source, source_ref_id,
        first_name, last_name,
        birth_date_hash, derived_email, radiat
      ) VALUES (
        p_company_id, NULL, 'reges', rec->>'source_ref_id',
        rec->>'first_name', rec->>'last_name',
        rec->>'birth_date_hash', rec->>'derived_email',
        COALESCE((rec->>'radiat')::boolean, false)
      ) RETURNING id INTO v_invite_id;
      v_invite_status := 'created';

    ELSIF v_existing_email IS NOT NULL THEN
      -- Already claimed by a human. Surface radiat transition if it flipped.
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
      INSERT INTO employee_pii (
        company_id, profile_invite_id, source, source_ref_id, country,
        national_id_encrypted, home_address_encrypted, date_of_birth_encrypted,
        locality_code, locality_code_system,
        nationality_iso, country_of_domicile_iso, id_document_type
      ) VALUES (
        p_company_id, v_invite_id, 'reges', rec->>'source_ref_id', 'RO',
        rec->>'national_id_encrypted',
        rec->>'home_address_encrypted',
        rec->>'date_of_birth_encrypted',
        rec->>'locality_code', rec->>'locality_code_system',
        rec->>'nationality_iso', rec->>'country_of_domicile_iso',
        rec->>'id_document_type'
      ) RETURNING id INTO v_pii_id;
      v_pii_status := 'created';

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
                         'derived_email_set', (rec->>'derived_email' IS NOT NULL)),
      now()
    );

    -- 4. Per-record outcome ----------------------------------------------
    out_results := out_results || jsonb_build_object(
      'source_ref_id',   rec->>'source_ref_id',
      'status',          v_pii_status,
      'invite_id',       v_invite_id,
      'employee_pii_id', v_pii_id,
      'invite_status',   v_invite_status
    );
  END LOOP;

  RETURN out_results;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ingest_reges_batch(uuid, jsonb) TO service_role;
