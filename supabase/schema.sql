


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."benefit_status" AS ENUM (
    'inactive',
    'searching',
    'testing',
    'active',
    'insurance_claim',
    'terminated'
);


ALTER TYPE "public"."benefit_status" OWNER TO "postgres";


COMMENT ON TYPE "public"."benefit_status" IS 'Benefit status for HR dashboard view. Auto-updated by triggers based on step and timestamps. NULL when step is NULL (benefit not yet started).';



CREATE TYPE "public"."bike_benefit_step" AS ENUM (
    'choose_bike',
    'book_live_test',
    'commit_to_bike',
    'sign_contract',
    'pickup_delivery'
);


ALTER TYPE "public"."bike_benefit_step" OWNER TO "postgres";


COMMENT ON TYPE "public"."bike_benefit_step" IS 'Steps in the bike benefit workflow process';



CREATE TYPE "public"."bike_type" AS ENUM (
    'e_mtb_hardtail_29',
    'e_mtb_hardtail_27_5',
    'e_full_suspension_29',
    'e_full_suspension_27_5',
    'e_city_bike',
    'e_touring',
    'e_road_race',
    'e_cargo_bike',
    'e_kids_24'
);


ALTER TYPE "public"."bike_type" OWNER TO "postgres";


COMMENT ON TYPE "public"."bike_type" IS 'Types of electric bikes available in the system';



CREATE TYPE "public"."contract_status" AS ENUM (
    'pending',
    'viewed_by_employee',
    'signed_by_employee',
    'signed_by_employer',
    'approved',
    'terminated',
    'declined_by_employee'
);


ALTER TYPE "public"."contract_status" OWNER TO "postgres";


COMMENT ON TYPE "public"."contract_status" IS 'Contract signing workflow status. terminated is set manually by HR. declined_by_employee is set via eSignatures webhook.';



CREATE TYPE "public"."currency_type" AS ENUM (
    'EUR',
    'RON'
);


ALTER TYPE "public"."currency_type" OWNER TO "postgres";


COMMENT ON TYPE "public"."currency_type" IS 'Supported currencies. EUR: symbol €  |  RON: symbol RON';



CREATE TYPE "public"."email_pattern_kind" AS ENUM (
    'last_middle_first',
    'first_middle_last',
    'first_last',
    'last_first',
    'first_initial_last'
);


ALTER TYPE "public"."email_pattern_kind" OWNER TO "postgres";


CREATE TYPE "public"."notification_event" AS ENUM (
    'contract_ready',
    'contract_signed_hr',
    'contract_approved'
);


ALTER TYPE "public"."notification_event" OWNER TO "postgres";


CREATE TYPE "public"."tbi_loan_status" AS ENUM (
    'pending',
    'approved',
    'rejected',
    'canceled'
);


ALTER TYPE "public"."tbi_loan_status" OWNER TO "postgres";


CREATE TYPE "public"."user_profile_status" AS ENUM (
    'active',
    'inactive'
);


ALTER TYPE "public"."user_profile_status" OWNER TO "postgres";


CREATE TYPE "public"."user_role" AS ENUM (
    'admin',
    'hr',
    'employee'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


COMMENT ON TYPE "public"."user_role" IS 'Type description for user role';



CREATE TYPE "public"."user_role_permissions" AS ENUM (
    'users.create'
);


ALTER TYPE "public"."user_role_permissions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auth_company_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT company_id
  FROM public.profiles
  WHERE user_id = auth.uid()
$$;


ALTER FUNCTION "public"."auth_company_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  bind_permissions int;
  user_role text;
BEGIN
  -- Fetch user role from JWT claims (injected by custom_access_token_hook)
  user_role := auth.jwt() ->> 'user_role';
  
  -- Check if the role has the requested permission
  SELECT count(*)
  INTO bind_permissions
  FROM public.role_permissions
  WHERE role_permissions.permission = requested_permission
    AND role_permissions.role::text = user_role;
  
  RETURN bind_permissions > 0;
END;
$$;


ALTER FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") IS 'Checks if the current user has the requested permission based on their role. Use in RLS policies: authorize(''users.create'')';



CREATE OR REPLACE FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) RETURNS TABLE("employee_price" numeric, "monthly_employee_price" numeric)
    LANGUAGE "sql" IMMUTABLE
    AS $$
  SELECT
    CASE
      WHEN p_full_price IS NOT NULL
           AND p_monthly_subsidy IS NOT NULL
           AND p_contract_months IS NOT NULL THEN
        GREATEST(0::numeric,
                 p_full_price - (p_monthly_subsidy * p_contract_months::numeric))
      ELSE NULL::numeric
    END                                                        AS employee_price,
    CASE
      WHEN p_full_price IS NOT NULL
           AND p_monthly_subsidy IS NOT NULL
           AND p_contract_months IS NOT NULL
           AND p_contract_months > 0 THEN
        GREATEST(0::numeric,
                 p_full_price - (p_monthly_subsidy * p_contract_months::numeric))
        / p_contract_months::numeric
      ELSE NULL::numeric
    END                                                        AS monthly_employee_price;
$$;


ALTER FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  v_monthly_subsidy DECIMAL;
  v_contract_months INTEGER;
  v_total_subsidy DECIMAL;
  v_employee_price DECIMAL;
BEGIN
  -- Get company benefit details
  SELECT monthly_benefit_subsidy, contract_months
  INTO v_monthly_subsidy, v_contract_months
  FROM public.companies
  WHERE id = p_company_id;
  
  -- Calculate total subsidy over contract period
  v_total_subsidy := v_monthly_subsidy * v_contract_months;
  
  -- Calculate employee price (full price minus company subsidy)
  v_employee_price := p_full_price - v_total_subsidy;
  
  -- Ensure price doesn't go below 0
  IF v_employee_price < 0 THEN
    v_employee_price := 0;
  END IF;
  
  RETURN v_employee_price;
END;
$$;


ALTER FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") IS 'Calculates the employee price for a bike based on company subsidy. Formula: full_price - (monthly_subsidy * contract_months)';



CREATE OR REPLACE FUNCTION "public"."custom_access_token_hook"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  claims jsonb;
  user_role public.user_role;
BEGIN
  -- Get existing claims
  claims := event->'claims';
  
  -- Fetch user role from user_roles table
  SELECT role INTO user_role 
  FROM public.user_roles 
  WHERE user_id = (event->>'user_id')::uuid;
  
  -- Add user_role to JWT claims
  IF user_role IS NOT NULL THEN
    claims := jsonb_set(claims, '{user_role}', to_jsonb(user_role));
  ELSE
    -- No role assigned, set to null
    claims := jsonb_set(claims, '{user_role}', 'null');
  END IF;
  
  -- Update claims in the event
  event := jsonb_set(event, '{claims}', claims);
  
  RETURN event;
END;
$$;


ALTER FUNCTION "public"."custom_access_token_hook"("event" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") IS 'Auth hook that injects user_role (admin/hr/employee) into JWT claims.
No device validation - security enforced via:
1. RLS policies based on user_role
2. Client-side app logic to show/hide features by role';



CREATE OR REPLACE FUNCTION "public"."get_company_terms_for_user"("p_user_id" "uuid") RETURNS TABLE("monthly_benefit_subsidy" numeric, "contract_months" integer, "currency" "public"."currency_type")
    LANGUAGE "sql" STABLE
    AS $$
  SELECT c.monthly_benefit_subsidy,
         c.contract_months,
         c.currency
  FROM   public.profiles pr
  JOIN   public.companies c ON c.id = pr.company_id
  WHERE  pr.user_id = p_user_id;
$$;


ALTER FUNCTION "public"."get_company_terms_for_user"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_company_user_ids"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT p.user_id
  FROM public.profiles p
  WHERE p.company_id = (
    SELECT company_id
    FROM public.profiles
    WHERE user_id = auth.uid()
  )
$$;


ALTER FUNCTION "public"."get_my_company_user_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT COALESCE(auth.jwt() ->> 'user_role', 'null');
$$;


ALTER FUNCTION "public"."get_my_role"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_my_role"() IS 'Returns the current user''s role from JWT claims. Returns ''null'' if no role assigned.';



CREATE OR REPLACE FUNCTION "public"."get_vault_secret"("secret_name" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'vault'
    AS $$
DECLARE
  v_secret text;
BEGIN
  SELECT decrypted_secret
  INTO   v_secret
  FROM   vault.decrypted_secrets
  WHERE  name = secret_name
  LIMIT  1;

  RETURN v_secret;
END;
$$;


ALTER FUNCTION "public"."get_vault_secret"("secret_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_vault_secret"("secret_name" "text") IS 'SECURITY DEFINER wrapper that lets edge functions read a named Vault secret via the REST API (POST /rpc/get_vault_secret). Returns NULL if the secret does not exist.';



CREATE OR REPLACE FUNCTION "public"."handle_user_registration"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_company_id  uuid;
  v_first_name  text;
  v_last_name   text;
  v_description text;
  v_department  text;
  v_hire_date   bigint;
  v_invite_id   uuid;
BEGIN
  IF NEW.email_confirmed_at IS NOT NULL THEN

    -- 1. Resolve company_id and employee fields from profile_invites
    SELECT
      pi.id,
      pi.company_id,
      pi.first_name,
      pi.last_name,
      pi.description,
      pi.department,
      pi.hire_date
    INTO
      v_invite_id,
      v_company_id,
      v_first_name,
      v_last_name,
      v_description,
      v_department,
      v_hire_date
    FROM public.profile_invites pi
    WHERE LOWER(pi.email) = LOWER(NEW.email)
    LIMIT 1;

    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'No active invite found for email %', NEW.email;
    END IF;

    -- 2. Create or update profile (must exist before user_roles FK insert)
    INSERT INTO public.profiles (
      user_id, email, status, company_id,
      first_name, last_name, description, department, hire_date
    )
    VALUES (
      NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id,
      v_first_name, v_last_name, v_description, v_department, v_hire_date
    )
    ON CONFLICT (user_id) DO UPDATE SET
      email       = EXCLUDED.email,
      status      = 'active'::public.user_profile_status,
      company_id  = EXCLUDED.company_id,
      first_name  = EXCLUDED.first_name,
      last_name   = EXCLUDED.last_name,
      description = EXCLUDED.description,
      department  = EXCLUDED.department,
      hire_date   = EXCLUDED.hire_date;

    -- 3. Assign 'employee' role
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    -- 4. Update profile_invites status
    UPDATE public.profile_invites
    SET status = 'active'::public.user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);

    -- 4.5. Link any pending REGES PII to this user
    UPDATE public.employee_pii
       SET user_id    = NEW.id,
           updated_at = now()
     WHERE profile_invite_id = v_invite_id
       AND user_id IS NULL;

    -- 5. Create bike benefit
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;

    -- 6. Insert notification — Realtime postgres_changes delivers it to HR dashboard
    INSERT INTO public.company_notifications (company_id, event, event_type, payload)
    VALUES (
      v_company_id,
      'user_update',
      'created',
      jsonb_build_object(
        'user_id',       NEW.id,
        'employee_name', v_first_name || ' ' || v_last_name
      )
    );

  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_user_registration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") RETURNS TABLE("id" "uuid", "radiat" boolean, "email_derived_match" boolean, "dob_matched" boolean, "first_score" real, "last_score" real)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    pi.id,
    pi.radiat,
    (pi.derived_email IS NOT NULL
       AND lower(pi.derived_email) = p_email_lower) AS email_derived_match,
    (pi.birth_date_hash = p_dob_hash)                AS dob_matched,
    GREATEST(
      similarity(lower(pi.first_name), p_first_norm),
      CASE
        WHEN lower(pi.first_name) LIKE p_first_norm || '-%'
          OR lower(pi.first_name) LIKE p_first_norm || ' %' THEN 0.95
        WHEN p_first_norm = ANY(string_to_array(
               regexp_replace(lower(pi.first_name), '[-\s]+', '|', 'g'), '|'))
          THEN 0.90
        ELSE 0
      END,
      CASE
        WHEN p_first_norm LIKE lower(pi.first_name) || ' %'
          OR p_first_norm LIKE lower(pi.first_name) || '-%' THEN 0.95
        ELSE 0
      END
    )::real AS first_score,
    similarity(lower(pi.last_name), p_last_norm)::real AS last_score
  FROM profile_invites pi
  WHERE pi.email IS NULL
    AND pi.company_id = p_company_id
    AND (
      pi.birth_date_hash = p_dob_hash
      OR (pi.derived_email IS NOT NULL AND lower(pi.derived_email) = p_email_lower)
    )
  ORDER BY
    (pi.derived_email IS NOT NULL AND lower(pi.derived_email) = p_email_lower) DESC,
    (pi.birth_date_hash = p_dob_hash) DESC,
    similarity(lower(pi.first_name), p_first_norm) DESC,
    similarity(lower(pi.last_name),  p_last_norm)  DESC
  LIMIT 10;
$$;


ALTER FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_avatar_to_profile"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF NEW.bucket_id = 'avatars' THEN
    UPDATE public.profiles
    SET profile_image_path = NEW.name
    WHERE user_id = NEW.name::uuid;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_avatar_to_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_profile_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- if email changed, update profile.email
  IF NEW.email IS DISTINCT FROM OLD.email THEN
    UPDATE public.profiles SET email = NEW.email WHERE user_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_profile_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_bike_benefit_status"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- HR terminal states: never overwrite automatically
  IF TG_OP = 'UPDATE'
     AND OLD.benefit_status IN (
       'insurance_claim'::public.benefit_status,
       'terminated'::public.benefit_status
     ) THEN
    RETURN NEW;
  END IF;

  -- Snap currency + contract_months only on new benefit creation
  IF TG_OP = 'INSERT' THEN
    SELECT t.currency, t.contract_months
    INTO   NEW.employee_currency, NEW.employee_contract_months
    FROM   public.get_company_terms_for_user(NEW.user_id) t;
  END IF;

  IF NEW.step IS NULL THEN
    NEW.benefit_status := 'inactive'::public.benefit_status;

  ELSIF NEW.step = 'choose_bike'::public.bike_benefit_step THEN
    IF TG_OP = 'UPDATE'
       AND (OLD.step IS NULL OR OLD.step <> 'choose_bike'::public.bike_benefit_step) THEN
      NEW.live_test_whatsapp_sent_at  := NULL;
      NEW.live_test_checked_in_at     := NULL;
      NEW.committed_at                := NULL;
      NEW.contract_requested_at       := NULL;
      NEW.contract_viewed_at          := NULL;
      NEW.contract_employee_signed_at := NULL;
      NEW.contract_employer_signed_at := NULL;
      NEW.contract_approved_at        := NULL;
      NEW.contract_declined_at        := NULL;
      NEW.delivered_at                := NULL;
      NEW.contract_status             := NULL;
      NEW.employee_full_price         := NULL;
      NEW.employee_monthly_price      := NULL;
      NEW.employee_contract_months    := NULL;
      DELETE FROM public.bike_orders WHERE bike_benefit_id = NEW.id;
      DELETE FROM public.contracts WHERE bike_benefit_id = NEW.id;
      -- Reset onboarding status when going back to choose_bike
      UPDATE public.profiles SET onboarding_status = false WHERE user_id = NEW.user_id;
    END IF;
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'book_live_test'::public.bike_benefit_step THEN
    NEW.benefit_status := 'searching'::public.benefit_status;

  ELSIF NEW.step = 'commit_to_bike'::public.bike_benefit_step THEN
    IF NEW.bike_id IS NOT NULL THEN
      SELECT p.employee_price, p.monthly_employee_price, t.contract_months
      INTO   NEW.employee_full_price, NEW.employee_monthly_price, NEW.employee_contract_months
      FROM         public.bikes b
      JOIN         public.get_company_terms_for_user(NEW.user_id) t ON true
      CROSS JOIN LATERAL public.calc_employee_prices(
                   b.full_price, t.monthly_benefit_subsidy, t.contract_months
                 ) p
      WHERE  b.id = NEW.bike_id;
    END IF;

    IF NEW.live_test_whatsapp_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing'::public.benefit_status;
    ELSE
      NEW.benefit_status := 'searching'::public.benefit_status;
    END IF;

  ELSIF NEW.step = 'sign_contract'::public.bike_benefit_step THEN
    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active'::public.benefit_status;
    ELSE
      NEW.benefit_status := COALESCE(OLD.benefit_status, 'searching'::public.benefit_status);
    END IF;

  ELSIF NEW.step = 'pickup_delivery'::public.bike_benefit_step THEN
    NEW.benefit_status := COALESCE(OLD.benefit_status, 'active'::public.benefit_status);

  END IF;

  -- Mark onboarding complete when delivered_at is set
  IF TG_OP = 'UPDATE'
     AND OLD.delivered_at IS NULL
     AND NEW.delivered_at IS NOT NULL THEN
    UPDATE public.profiles SET onboarding_status = true WHERE user_id = NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_bike_benefit_status"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_bike_benefit_status"() IS 'Auto-updates benefit_status on step / timestamp changes.
Terminal-state guard: once HR sets insurance_claim or terminated, any
subsequent step/timestamp updates are ignored until HR explicitly changes it.
choose_bike resets all downstream timestamps, contract_status, pricing,
deletes related bike_orders and contracts rows, and resets onboarding_status.
Sets onboarding_status = true when delivered_at transitions from NULL to non-NULL.';



CREATE OR REPLACE FUNCTION "public"."update_contract_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Terminal guard: only terminated is permanent (manual HR action).
  -- declined_by_employee is NOT guarded — a new contract can be re-sent.
  IF TG_OP = 'UPDATE'
     AND OLD.contract_status = 'terminated'::public.contract_status THEN
    RETURN NEW;
  END IF;

  -- Priority chain (highest → lowest)
  IF NEW.contract_declined_at IS NOT NULL THEN
    NEW.contract_status := 'declined_by_employee'::public.contract_status;
  ELSIF NEW.contract_employee_signed_at IS NOT NULL
     AND NEW.contract_employer_signed_at IS NOT NULL
     AND NEW.contract_approved_at        IS NOT NULL THEN
    NEW.contract_status := 'approved'::public.contract_status;
  ELSIF NEW.contract_employer_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employer'::public.contract_status;
  ELSIF NEW.contract_employee_signed_at IS NOT NULL THEN
    NEW.contract_status := 'signed_by_employee'::public.contract_status;
  ELSIF NEW.contract_viewed_at IS NOT NULL THEN
    NEW.contract_status := 'viewed_by_employee'::public.contract_status;
  ELSIF NEW.contract_requested_at IS NOT NULL THEN
    NEW.contract_status := 'pending'::public.contract_status;
  ELSE
    NEW.contract_status := NULL;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_contract_status"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_contract_status"() IS 'Trigger function that auto-updates contract_status based on contract timestamp changes.
Sets ''pending'' when contract_requested_at IS NOT NULL (contract requested but not yet viewed).
Falls back to NULL when no contract timestamps are set.
Does not override manually set terminated status.';



CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."bike_benefits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "bike_id" "uuid",
    "live_test_location" "text",
    "live_test_whatsapp_sent_at" timestamp with time zone,
    "live_test_checked_in_at" timestamp with time zone,
    "committed_at" timestamp with time zone,
    "checked_in_at" timestamp with time zone,
    "contract_requested_at" timestamp with time zone,
    "delivered_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "live_test_location_name" "text",
    "benefit_status" "public"."benefit_status",
    "contract_status" "public"."contract_status",
    "contract_viewed_at" timestamp with time zone,
    "contract_employee_signed_at" timestamp with time zone,
    "contract_employer_signed_at" timestamp with time zone,
    "contract_approved_at" timestamp with time zone,
    "contract_terminated_at" timestamp with time zone,
    "benefit_terminated_at" timestamp with time zone,
    "benefit_insurance_claim_at" timestamp with time zone,
    "step" "public"."bike_benefit_step",
    "employee_currency" "public"."currency_type",
    "employee_full_price" numeric(10,2),
    "employee_monthly_price" numeric(10,2),
    "employee_contract_months" integer,
    "contract_declined_at" timestamp with time zone,
    "live_test_lat" double precision,
    "live_test_lon" double precision
);


ALTER TABLE "public"."bike_benefits" OWNER TO "postgres";


COMMENT ON COLUMN "public"."bike_benefits"."live_test_location_name" IS 'Human-readable name of the test location (e.g., "Maros Bike Cluj")';



COMMENT ON COLUMN "public"."bike_benefits"."benefit_status" IS 'Overall benefit status for HR view. Auto-updated by triggers. NULL when employee has not started the benefit process yet.';



COMMENT ON COLUMN "public"."bike_benefits"."contract_status" IS 'Contract signing workflow status. Updated manually or via triggers.';



COMMENT ON COLUMN "public"."bike_benefits"."contract_viewed_at" IS 'Timestamp when employee first viewed the contract';



COMMENT ON COLUMN "public"."bike_benefits"."contract_employee_signed_at" IS 'Timestamp when employee signed the contract';



COMMENT ON COLUMN "public"."bike_benefits"."contract_employer_signed_at" IS 'Timestamp when employer signed the contract';



COMMENT ON COLUMN "public"."bike_benefits"."contract_approved_at" IS 'Timestamp when contract was fully approved (both parties signed)';



COMMENT ON COLUMN "public"."bike_benefits"."contract_terminated_at" IS 'Timestamp when contract was terminated';



COMMENT ON COLUMN "public"."bike_benefits"."benefit_terminated_at" IS 'Timestamp when benefit was terminated';



COMMENT ON COLUMN "public"."bike_benefits"."benefit_insurance_claim_at" IS 'Timestamp when insurance claim was filed';



COMMENT ON COLUMN "public"."bike_benefits"."step" IS 'Current step in the bike benefit workflow. NULL when benefit not yet started.';



COMMENT ON COLUMN "public"."bike_benefits"."employee_currency" IS 'Currency locked for this employee at benefit creation. NULL for legacy records — falls back to companies.currency in views.';



COMMENT ON COLUMN "public"."bike_benefits"."employee_full_price" IS 'Total discounted price: GREATEST(0, full_price - (monthly_subsidy x contract_months)). Computed and stored when step transitions to commit_to_bike. Cleared on choose_bike reset.';



COMMENT ON COLUMN "public"."bike_benefits"."employee_monthly_price" IS 'Monthly employee payment: employee_full_price / contract_months. Computed and stored when step transitions to commit_to_bike. Cleared on choose_bike reset.';



COMMENT ON COLUMN "public"."bike_benefits"."employee_contract_months" IS 'Contract duration (months) locked for this employee at benefit creation. Re-confirmed and stored when step transitions to commit_to_bike. Cleared on choose_bike reset. NULL for legacy records.';



COMMENT ON COLUMN "public"."bike_benefits"."contract_declined_at" IS 'Set by webhook when the employee declines the contract (signer-declined event). Drives contract_status → declined_by_employee via trigger.';



CREATE TABLE IF NOT EXISTS "public"."bike_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "bike_benefit_id" "uuid" NOT NULL,
    "helmet" boolean DEFAULT false NOT NULL,
    "insurance" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "bike_id" "uuid",
    "bike_sku" "text",
    "bike_name" "text",
    "bike_brand" "text",
    "bike_full_price" numeric(10,2),
    "frozen_at" timestamp with time zone
);


ALTER TABLE "public"."bike_orders" OWNER TO "postgres";


COMMENT ON COLUMN "public"."bike_orders"."bike_id" IS 'Snapshot of bikes.id at contract creation. SET NULL on bike delete so the order audit row survives.';



COMMENT ON COLUMN "public"."bike_orders"."bike_sku" IS 'Frozen bike SKU at contract creation.';



COMMENT ON COLUMN "public"."bike_orders"."bike_name" IS 'Frozen bike name at contract creation.';



COMMENT ON COLUMN "public"."bike_orders"."bike_brand" IS 'Frozen bike brand at contract creation.';



COMMENT ON COLUMN "public"."bike_orders"."bike_full_price" IS 'Frozen full price at contract creation. Decoupled from later bikes.full_price changes.';



COMMENT ON COLUMN "public"."bike_orders"."frozen_at" IS 'When the snapshot was last refreshed by send-contract.';



CREATE TABLE IF NOT EXISTS "public"."bikes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "brand" "text",
    "description" "text",
    "image_url" "text",
    "full_price" numeric(10,2) DEFAULT 0 NOT NULL,
    "employee_price" numeric(10,2),
    "weight_kg" numeric(5,2),
    "charge_time_hours" numeric(4,2),
    "range_max_km" integer,
    "power_wh" integer,
    "engine" "text",
    "supported_features" "text",
    "frame_material" "text",
    "frame_size" "text",
    "wheel_size" "text",
    "wheel_bandwidth" "text",
    "lock_type" "text",
    "sku" "text",
    "available_for_test" boolean DEFAULT true,
    "in_stock" boolean DEFAULT true,
    "type" "public"."bike_type",
    "images" "jsonb",
    "dealer_id" "uuid" NOT NULL
);


ALTER TABLE "public"."bikes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."bikes"."type" IS 'Type/category of the bike (e.g., e-MTB, e-city, e-touring)';



CREATE TABLE IF NOT EXISTS "public"."companies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "monthly_benefit_subsidy" numeric(10,2) DEFAULT 72.00,
    "contract_months" integer DEFAULT 36,
    "currency" "public"."currency_type" DEFAULT 'RON'::"public"."currency_type" NOT NULL,
    "esignatures_template_id" "text",
    "logo_image_path" "text",
    "address" "text",
    "address_lat" double precision,
    "address_lon" double precision,
    "contact_email" "text",
    "days_in_office" integer DEFAULT 5,
    "email_domain" "text",
    "email_pattern" "public"."email_pattern_kind"
);


ALTER TABLE "public"."companies" OWNER TO "postgres";


COMMENT ON TABLE "public"."companies" IS 'This represents the companies for which each users adhere to. 1 user can have only 1 company a company can have multiple users.';



COMMENT ON COLUMN "public"."companies"."monthly_benefit_subsidy" IS 'Monthly subsidy amount the company provides for bike benefits (e.g., €72/month)';



COMMENT ON COLUMN "public"."companies"."contract_months" IS 'Standard contract duration in months for bike benefits (e.g., 36 months)';



COMMENT ON COLUMN "public"."companies"."currency" IS 'Currency used for bike benefit pricing. Defaults to RON.';



COMMENT ON COLUMN "public"."companies"."esignatures_template_id" IS 'eSignatures.com template ID used to generate bike benefit contracts for employees of this company. Must be set before send-contract can be called.';



COMMENT ON COLUMN "public"."companies"."days_in_office" IS 'Number of days per week employees commute to the office (1-7). Used for dashboard estimations (distance, calories, CO2, fuel saved).';



COMMENT ON COLUMN "public"."companies"."email_domain" IS 'Primary corporate email domain (e.g. "8x8.com"). Used at registration to scope claim-by-name lookup. Required before REGES upload for that company.';



COMMENT ON COLUMN "public"."companies"."email_pattern" IS 'Optional named email pattern used to derive employee email at REGES ingest. NULL = no derivation (employees self-claim by name/DOB). Template lookup lives in TS (EMAIL_PATTERN_TEMPLATES).';



CREATE TABLE IF NOT EXISTS "public"."dealers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "lat" double precision,
    "lon" double precision
);


ALTER TABLE "public"."dealers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "user_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "public"."user_profile_status" DEFAULT 'inactive'::"public"."user_profile_status" NOT NULL,
    "company_id" "uuid" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "description" "text",
    "department" "text",
    "hire_date" bigint,
    "fcm_token" "text",
    "onboarding_status" boolean DEFAULT false,
    "profile_image_path" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."first_name" IS 'Employee first name';



COMMENT ON COLUMN "public"."profiles"."last_name" IS 'Employee last name';



COMMENT ON COLUMN "public"."profiles"."description" IS 'Employee description or bio';



COMMENT ON COLUMN "public"."profiles"."department" IS 'Employee department or team';



COMMENT ON COLUMN "public"."profiles"."hire_date" IS 'Employee hire date as Unix timestamp in milliseconds';



CREATE OR REPLACE VIEW "public"."bikes_with_my_pricing" WITH ("security_invoker"='on') AS
 SELECT "b"."id",
    "b"."name",
    "b"."created_at",
    "b"."updated_at",
    "b"."brand",
    "b"."description",
    "b"."image_url",
    "b"."full_price",
    "b"."employee_price",
    "b"."weight_kg",
    "b"."charge_time_hours",
    "b"."range_max_km",
    "b"."power_wh",
    "b"."engine",
    "b"."supported_features",
    "b"."frame_material",
    "b"."frame_size",
    "b"."wheel_size",
    "b"."wheel_bandwidth",
    "b"."lock_type",
    "b"."sku",
    "d"."name" AS "dealer_name",
    "d"."address" AS "dealer_address",
    "d"."lat" AS "dealer_lat",
    "d"."lon" AS "dealer_lon",
    "d"."phone" AS "dealer_phone",
    "b"."available_for_test",
    "b"."in_stock",
    "b"."type",
    "b"."images",
    "c"."monthly_benefit_subsidy",
    "c"."contract_months",
    "c"."contract_months" AS "employee_contract_month",
    "c"."currency",
    "prices"."employee_price" AS "employee_full_price",
    "prices"."monthly_employee_price" AS "employee_monthly_price"
   FROM (((("public"."bikes" "b"
     JOIN "public"."dealers" "d" ON (("d"."id" = "b"."dealer_id")))
     LEFT JOIN "public"."profiles" "me" ON (("me"."user_id" = "auth"."uid"())))
     LEFT JOIN "public"."companies" "c" ON (("c"."id" = "me"."company_id")))
     LEFT JOIN LATERAL "public"."calc_employee_prices"("b"."full_price", "c"."monthly_benefit_subsidy", "c"."contract_months") "prices"("employee_price", "monthly_employee_price") ON (true));


ALTER VIEW "public"."bikes_with_my_pricing" OWNER TO "postgres";


COMMENT ON VIEW "public"."bikes_with_my_pricing" IS 'Bike catalog with employee-specific pricing and dealer info. Uses auth.uid() to resolve the calling user''s company subsidy and contract terms automatically. Returns all bikes; pricing columns are NULL when the user has no linked company.';



CREATE TABLE IF NOT EXISTS "public"."company_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "event" "text" NOT NULL,
    "event_type" "text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."company_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contracts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bike_benefit_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "esignatures_contract_id" "text" NOT NULL,
    "esignatures_signer_id" "text",
    "esignatures_template_id" "text" NOT NULL,
    "sign_page_url" "text",
    "api_response" "jsonb",
    "last_webhook_payload" "jsonb",
    "last_webhook_event" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."contracts" OWNER TO "postgres";


COMMENT ON TABLE "public"."contracts" IS 'Tracks eSignatures.com contract lifecycle for each bike benefit. One row per contract request.';



COMMENT ON COLUMN "public"."contracts"."esignatures_contract_id" IS 'Contract ID returned by eSignatures.com API';



COMMENT ON COLUMN "public"."contracts"."esignatures_signer_id" IS 'Signer ID for the employee returned by eSignatures.com API';



COMMENT ON COLUMN "public"."contracts"."esignatures_template_id" IS 'Template ID used to create this contract (snapshotted from company at request time)';



COMMENT ON COLUMN "public"."contracts"."sign_page_url" IS 'URL the employee visits to sign the contract';



COMMENT ON COLUMN "public"."contracts"."api_response" IS 'Full eSignatures.com API response (audit trail)';



COMMENT ON COLUMN "public"."contracts"."last_webhook_payload" IS 'Latest webhook payload received from eSignatures.com (debug)';



COMMENT ON COLUMN "public"."contracts"."last_webhook_event" IS 'Event string from the latest webhook (e.g. signer-signed)';



CREATE TABLE IF NOT EXISTS "public"."employee_pii" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "company_id" "uuid" NOT NULL,
    "national_id_encrypted" "text",
    "date_of_birth_encrypted" "text",
    "phone_encrypted" "text",
    "home_address_encrypted" "text",
    "home_lat_encrypted" "text",
    "home_lon_encrypted" "text",
    "salary_gross_encrypted" "text",
    "country" "text" DEFAULT 'RO'::"text" NOT NULL,
    "nationality_iso" "text",
    "country_of_domicile_iso" "text",
    "id_document_type" "text",
    "locality_code" "text",
    "locality_code_system" "text",
    "salary_currency" "text" DEFAULT 'RON'::"text",
    "education_level" "text",
    "source" "text",
    "source_ref_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "profile_invite_id" "uuid"
);


ALTER TABLE "public"."employee_pii" OWNER TO "postgres";


COMMENT ON COLUMN "public"."employee_pii"."profile_invite_id" IS 'Links a REGES-staged PII row to its profile_invites row. Lets handle_user_registration backfill employee_pii.user_id when the matching invite is claimed.';



CREATE TABLE IF NOT EXISTS "public"."integration_configs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "integration" "text" NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb",
    "enabled" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."integration_configs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integration_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "integration" "text" NOT NULL,
    "message_id" "uuid",
    "operation" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "uuid",
    "direction" "text" DEFAULT 'outbound'::"text" NOT NULL,
    "request_payload" "jsonb",
    "response_id" "text",
    "result_code" "text",
    "result_payload" "jsonb",
    "status" "text" DEFAULT 'pending'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp with time zone
);


ALTER TABLE "public"."integration_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."labor_contracts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "company_id" "uuid" NOT NULL,
    "employee_pii_id" "uuid" NOT NULL,
    "contract_number" "text",
    "contract_date" "date",
    "start_date" "date",
    "end_date" "date",
    "contract_type" "text",
    "duration_type" "text",
    "norm_type" "text",
    "work_schedule" "jsonb",
    "work_location_type" "text",
    "work_county" "text",
    "work_locality_code" "text",
    "occupation_code" "text",
    "occupation_code_system" "text",
    "occupation_code_version" integer,
    "status" "text" DEFAULT 'active'::"text",
    "source" "text",
    "source_ref_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."labor_contracts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profile_invites" (
    "email" "text",
    "status" "public"."user_profile_status" DEFAULT 'inactive'::"public"."user_profile_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "description" "text",
    "department" "text",
    "hire_date" bigint,
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "source_ref_id" "text",
    "birth_date_hash" "text",
    "derived_email" "text",
    "radiat" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."profile_invites" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profile_invites"."user_id" IS 'Links to the user profile after they complete registration';



COMMENT ON COLUMN "public"."profile_invites"."first_name" IS 'Employee first name';



COMMENT ON COLUMN "public"."profile_invites"."last_name" IS 'Employee last name';



COMMENT ON COLUMN "public"."profile_invites"."description" IS 'Employee description or bio';



COMMENT ON COLUMN "public"."profile_invites"."department" IS 'Employee department or team';



COMMENT ON COLUMN "public"."profile_invites"."hire_date" IS 'Employee hire date as Unix timestamp in milliseconds';



COMMENT ON COLUMN "public"."profile_invites"."source" IS 'Origin of the invite: ''manual'' (CSV) or ''reges'' (JSON upload).';



COMMENT ON COLUMN "public"."profile_invites"."source_ref_id" IS 'Source-system reference. For REGES: referintaSalariat.id (UUID). Idempotency key.';



COMMENT ON COLUMN "public"."profile_invites"."birth_date_hash" IS 'HMAC-SHA256 blind index of ISO-formatted DOB. Always populated for REGES rows (derived from CNP positions 2-7). NULL for CSV rows.';



COMMENT ON COLUMN "public"."profile_invites"."derived_email" IS 'Email derived from companies.email_pattern at REGES ingest. Used at /register for confident pattern-based claim. NULL when company has no pattern or derivation failed.';



COMMENT ON COLUMN "public"."profile_invites"."radiat" IS 'REGES "radiat" (terminated) flag. true once the employee has been removed from the registry.';



CREATE OR REPLACE VIEW "public"."profile_invites_with_details" WITH ("security_invoker"='on') AS
 SELECT "pi"."id" AS "invite_id",
    "pi"."email",
    "pi"."status" AS "invite_status",
    "pi"."created_at" AS "invited_at",
    "pi"."company_id",
    "c"."name" AS "company_name",
    "c"."logo_image_path",
    "p"."user_id",
    "p"."status" AS "profile_status",
    "p"."created_at" AS "registered_at",
    "p"."profile_image_path",
    COALESCE("p"."first_name", "pi"."first_name") AS "first_name",
    COALESCE("p"."last_name", "pi"."last_name") AS "last_name",
    COALESCE("p"."description", "pi"."description") AS "description",
    COALESCE("p"."department", "pi"."department") AS "department",
    COALESCE("p"."hire_date", "pi"."hire_date") AS "hire_date",
    "bb"."id" AS "bike_benefit_id",
    "bb"."benefit_status",
    "bb"."contract_status",
    COALESCE("bb"."updated_at", "bo"."updated_at", "p"."created_at", "pi"."created_at") AS "last_modified_at",
    "bb"."bike_id",
    "bo"."id" AS "order_id",
    "pi"."source",
    "pi"."radiat",
    "pi"."derived_email"
   FROM ((((("public"."profile_invites" "pi"
     LEFT JOIN "public"."companies" "c" ON (("pi"."company_id" = "c"."id")))
     LEFT JOIN "public"."profiles" "p" ON (("pi"."email" = "p"."email")))
     LEFT JOIN "public"."bike_benefits" "bb" ON (("p"."user_id" = "bb"."user_id")))
     LEFT JOIN "public"."bikes" "b" ON (("bb"."bike_id" = "b"."id")))
     LEFT JOIN "public"."bike_orders" "bo" ON (("bb"."id" = "bo"."bike_benefit_id")))
  ORDER BY COALESCE("bb"."updated_at", "bo"."updated_at", "p"."created_at", "pi"."created_at") DESC;


ALTER VIEW "public"."profile_invites_with_details" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_permissions" (
    "id" bigint NOT NULL,
    "role" "public"."user_role" NOT NULL,
    "permission" "public"."user_role_permissions" NOT NULL
);


ALTER TABLE "public"."role_permissions" OWNER TO "postgres";


COMMENT ON TABLE "public"."role_permissions" IS 'Permissions for each role. Use authorize() function in RLS policies to check permissions.';



ALTER TABLE "public"."role_permissions" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."role_permissions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tbi_loan_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "bike_benefit_id" "uuid" NOT NULL,
    "order_id" "text" NOT NULL,
    "order_total" numeric(10,2) NOT NULL,
    "status" "public"."tbi_loan_status" DEFAULT 'pending'::"public"."tbi_loan_status" NOT NULL,
    "rejection_reason" "text",
    "redirect_url" "text",
    "tbi_response" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tbi_loan_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "id" bigint NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "role" "public"."user_role" NOT NULL
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_roles" IS 'User roles for RBAC. Roles are injected into JWT via custom_access_token_hook.';



ALTER TABLE "public"."user_roles" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."user_roles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."bike_benefits"
    ADD CONSTRAINT "bike_benefits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bikes"
    ADD CONSTRAINT "bikes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_notifications"
    ADD CONSTRAINT "company_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_esignatures_contract_id_key" UNIQUE ("esignatures_contract_id");



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dealers"
    ADD CONSTRAINT "dealers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_pii"
    ADD CONSTRAINT "employee_pii_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_configs"
    ADD CONSTRAINT "integration_configs_company_integration_unique" UNIQUE ("company_id", "integration");



ALTER TABLE ONLY "public"."integration_configs"
    ADD CONSTRAINT "integration_configs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_messages"
    ADD CONSTRAINT "integration_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."labor_contracts"
    ADD CONSTRAINT "labor_contracts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profile_invites"
    ADD CONSTRAINT "profile_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_permission_key" UNIQUE ("permission");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_key" UNIQUE ("role");



ALTER TABLE ONLY "public"."tbi_loan_applications"
    ADD CONSTRAINT "tbi_loan_applications_order_id_key" UNIQUE ("order_id");



ALTER TABLE ONLY "public"."tbi_loan_applications"
    ADD CONSTRAINT "tbi_loan_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "unique_benefit_order" UNIQUE ("bike_benefit_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "companies_email_domain_unique" ON "public"."companies" USING "btree" ("lower"("email_domain")) WHERE ("email_domain" IS NOT NULL);



CREATE UNIQUE INDEX "employee_pii_source_unique" ON "public"."employee_pii" USING "btree" ("company_id", "source", "source_ref_id") WHERE ("source_ref_id" IS NOT NULL);



CREATE UNIQUE INDEX "employee_pii_user_unique" ON "public"."employee_pii" USING "btree" ("user_id") WHERE ("user_id" IS NOT NULL);



CREATE INDEX "idx_bike_benefits_benefit_status" ON "public"."bike_benefits" USING "btree" ("benefit_status");



CREATE INDEX "idx_bike_benefits_bike_id" ON "public"."bike_benefits" USING "btree" ("bike_id");



CREATE INDEX "idx_bike_benefits_contract_status" ON "public"."bike_benefits" USING "btree" ("contract_status");



CREATE INDEX "idx_bike_benefits_user_id" ON "public"."bike_benefits" USING "btree" ("user_id");



CREATE INDEX "idx_bike_orders_bike_benefit_id" ON "public"."bike_orders" USING "btree" ("bike_benefit_id");



CREATE INDEX "idx_bike_orders_user_id" ON "public"."bike_orders" USING "btree" ("user_id");



CREATE INDEX "idx_bikes_name" ON "public"."bikes" USING "btree" ("name");



CREATE INDEX "idx_bikes_type" ON "public"."bikes" USING "btree" ("type");



CREATE INDEX "idx_company_notifications_company_id" ON "public"."company_notifications" USING "btree" ("company_id");



CREATE INDEX "idx_company_notifications_created_at" ON "public"."company_notifications" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_contracts_bike_benefit_id" ON "public"."contracts" USING "btree" ("bike_benefit_id");



CREATE INDEX "idx_contracts_esignatures_contract_id" ON "public"."contracts" USING "btree" ("esignatures_contract_id");



CREATE INDEX "idx_contracts_user_id" ON "public"."contracts" USING "btree" ("user_id");



CREATE INDEX "idx_employee_pii_company" ON "public"."employee_pii" USING "btree" ("company_id");



CREATE INDEX "idx_employee_pii_profile_invite" ON "public"."employee_pii" USING "btree" ("profile_invite_id") WHERE ("profile_invite_id" IS NOT NULL);



CREATE INDEX "idx_integration_messages_company" ON "public"."integration_messages" USING "btree" ("company_id");



CREATE INDEX "idx_integration_messages_entity" ON "public"."integration_messages" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_integration_messages_integration" ON "public"."integration_messages" USING "btree" ("integration");



CREATE INDEX "idx_labor_contracts_company" ON "public"."labor_contracts" USING "btree" ("company_id");



CREATE INDEX "idx_labor_contracts_pii" ON "public"."labor_contracts" USING "btree" ("employee_pii_id");



CREATE INDEX "idx_labor_contracts_user" ON "public"."labor_contracts" USING "btree" ("user_id");



CREATE INDEX "idx_profile_invites_company_id" ON "public"."profile_invites" USING "btree" ("company_id");



CREATE INDEX "idx_profile_invites_derived_email" ON "public"."profile_invites" USING "btree" ("company_id", "lower"("derived_email")) WHERE (("email" IS NULL) AND ("derived_email" IS NOT NULL));



CREATE INDEX "idx_profile_invites_name_trgm" ON "public"."profile_invites" USING "gin" (((("lower"("first_name") || ' '::"text") || "lower"("last_name"))) "public"."gin_trgm_ops") WHERE ("email" IS NULL);



CREATE INDEX "idx_profile_invites_pending_dob" ON "public"."profile_invites" USING "btree" ("company_id", "birth_date_hash") WHERE ("email" IS NULL);



CREATE INDEX "idx_profile_invites_user_id" ON "public"."profile_invites" USING "btree" ("user_id");



CREATE INDEX "idx_profiles_company_id" ON "public"."profiles" USING "btree" ("company_id");



CREATE INDEX "idx_profiles_department" ON "public"."profiles" USING "btree" ("department") WHERE ("department" IS NOT NULL);



CREATE UNIQUE INDEX "idx_profiles_email_unique" ON "public"."profiles" USING "btree" ("lower"("email")) WHERE ("email" IS NOT NULL);



CREATE INDEX "idx_profiles_hire_date" ON "public"."profiles" USING "btree" ("hire_date") WHERE ("hire_date" IS NOT NULL);



CREATE INDEX "idx_profiles_last_name" ON "public"."profiles" USING "btree" ("last_name");



CREATE INDEX "idx_tbi_loan_apps_benefit" ON "public"."tbi_loan_applications" USING "btree" ("bike_benefit_id");



CREATE INDEX "idx_tbi_loan_apps_order" ON "public"."tbi_loan_applications" USING "btree" ("order_id");



CREATE INDEX "idx_tbi_loan_apps_profile" ON "public"."tbi_loan_applications" USING "btree" ("profile_id");



CREATE UNIQUE INDEX "profile_invites_email_unique" ON "public"."profile_invites" USING "btree" ("lower"("email")) WHERE ("email" IS NOT NULL);



CREATE UNIQUE INDEX "profile_invites_source_unique" ON "public"."profile_invites" USING "btree" ("company_id", "source", "source_ref_id") WHERE ("source_ref_id" IS NOT NULL);



CREATE UNIQUE INDEX "user_roles_user_role_idx" ON "public"."user_roles" USING "btree" ("user_id", "role");



CREATE OR REPLACE TRIGGER "set_contracts_updated_at" BEFORE UPDATE ON "public"."contracts" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_benefit_status_on_change" BEFORE INSERT OR UPDATE ON "public"."bike_benefits" FOR EACH ROW EXECUTE FUNCTION "public"."update_bike_benefit_status"();



CREATE OR REPLACE TRIGGER "update_bike_benefits_updated_at" BEFORE UPDATE ON "public"."bike_benefits" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_bike_orders_updated_at" BEFORE UPDATE ON "public"."bike_orders" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_bikes_updated_at" BEFORE UPDATE ON "public"."bikes" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_contract_status_on_change" BEFORE INSERT OR UPDATE ON "public"."bike_benefits" FOR EACH ROW EXECUTE FUNCTION "public"."update_contract_status"();



CREATE OR REPLACE TRIGGER "update_employee_pii_updated_at" BEFORE UPDATE ON "public"."employee_pii" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_integration_configs_updated_at" BEFORE UPDATE ON "public"."integration_configs" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_labor_contracts_updated_at" BEFORE UPDATE ON "public"."labor_contracts" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_tbi_loan_apps_updated_at" BEFORE UPDATE ON "public"."tbi_loan_applications" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."bike_benefits"
    ADD CONSTRAINT "bike_benefits_bike_id_fkey" FOREIGN KEY ("bike_id") REFERENCES "public"."bikes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bike_benefits"
    ADD CONSTRAINT "bike_benefits_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_bike_benefit_id_fkey" FOREIGN KEY ("bike_benefit_id") REFERENCES "public"."bike_benefits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_bike_id_fkey" FOREIGN KEY ("bike_id") REFERENCES "public"."bikes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bikes"
    ADD CONSTRAINT "bikes_dealer_id_fkey" FOREIGN KEY ("dealer_id") REFERENCES "public"."dealers"("id");



ALTER TABLE ONLY "public"."company_notifications"
    ADD CONSTRAINT "company_notifications_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_bike_benefit_id_fkey" FOREIGN KEY ("bike_benefit_id") REFERENCES "public"."bike_benefits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_pii"
    ADD CONSTRAINT "employee_pii_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."employee_pii"
    ADD CONSTRAINT "employee_pii_profile_invite_id_fkey" FOREIGN KEY ("profile_invite_id") REFERENCES "public"."profile_invites"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."employee_pii"
    ADD CONSTRAINT "employee_pii_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."integration_configs"
    ADD CONSTRAINT "integration_configs_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."integration_messages"
    ADD CONSTRAINT "integration_messages_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."labor_contracts"
    ADD CONSTRAINT "labor_contracts_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."labor_contracts"
    ADD CONSTRAINT "labor_contracts_employee_pii_id_fkey" FOREIGN KEY ("employee_pii_id") REFERENCES "public"."employee_pii"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."labor_contracts"
    ADD CONSTRAINT "labor_contracts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profile_invites"
    ADD CONSTRAINT "profile_invites_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."profile_invites"
    ADD CONSTRAINT "profile_invites_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tbi_loan_applications"
    ADD CONSTRAINT "tbi_loan_applications_bike_benefit_id_fkey" FOREIGN KEY ("bike_benefit_id") REFERENCES "public"."bike_benefits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tbi_loan_applications"
    ADD CONSTRAINT "tbi_loan_applications_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_profiles_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "Allow auth admin to read user roles" ON "public"."user_roles" FOR SELECT TO "supabase_auth_admin" USING (true);



CREATE POLICY "Authenticated users can read permissions" ON "public"."role_permissions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can view dealers" ON "public"."dealers" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Employees can view own invite" ON "public"."profile_invites" FOR SELECT TO "authenticated" USING (("email" = ( SELECT "p"."email"
   FROM "public"."profiles" "p"
  WHERE ("p"."user_id" = "auth"."uid"()))));



CREATE POLICY "Enable read access for user own roles" ON "public"."user_roles" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "HR can assign roles" ON "public"."user_roles" FOR INSERT TO "authenticated" WITH CHECK (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") OR (("auth"."jwt"() ->> 'user_role'::"text") = 'admin'::"text")));



CREATE POLICY "HR can delete profile invites" ON "public"."profile_invites" FOR DELETE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "HR can update profile invites" ON "public"."profile_invites" FOR UPDATE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "HR can view profile invites" ON "public"."profile_invites" FOR SELECT TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "HR view pending PII own company" ON "public"."employee_pii" FOR SELECT TO "authenticated" USING ((("user_id" IS NULL) AND ("public"."get_my_role"() = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



CREATE POLICY "Hr can only add profile invites" ON "public"."profile_invites" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "Users can read own role" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."bike_benefits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bike_benefits_employee_insert" ON "public"."bike_benefits" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_benefits_employee_select" ON "public"."bike_benefits" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_benefits_employee_update" ON "public"."bike_benefits" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_benefits_hr_select" ON "public"."bike_benefits" FOR SELECT TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])));



CREATE POLICY "bike_benefits_hr_update" ON "public"."bike_benefits" FOR UPDATE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])));



ALTER TABLE "public"."bike_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bike_orders_employee_insert" ON "public"."bike_orders" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_orders_employee_select" ON "public"."bike_orders" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_orders_employee_update" ON "public"."bike_orders" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_orders_hr_select" ON "public"."bike_orders" FOR SELECT TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])));



CREATE POLICY "bike_orders_hr_update" ON "public"."bike_orders" FOR UPDATE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])));



ALTER TABLE "public"."bikes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bikes_authenticated_select" ON "public"."bikes" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "bikes_hr_insert" ON "public"."bikes" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])));



CREATE POLICY "bikes_hr_update" ON "public"."bikes" FOR UPDATE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])));



ALTER TABLE "public"."companies" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "companies_employee_select" ON "public"."companies" FOR SELECT TO "authenticated" USING (("id" IN ( SELECT "profiles"."company_id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "companies_hr_update" ON "public"."companies" FOR UPDATE TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("id" IN ( SELECT "profiles"."company_id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."company_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."contracts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "contracts_employee_select_own" ON "public"."contracts" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "contracts_hr_admin_select" ON "public"."contracts" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_roles" "ur"
  WHERE (("ur"."user_id" = "auth"."uid"()) AND ("ur"."role" = ANY (ARRAY['hr'::"public"."user_role", 'admin'::"public"."user_role"]))))));



ALTER TABLE "public"."dealers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employee_pii" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employee_pii_hr_select" ON "public"."employee_pii" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



CREATE POLICY "employee_pii_self_select" ON "public"."employee_pii" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "hr_admin_select_own_company_notifications" ON "public"."company_notifications" FOR SELECT TO "authenticated" USING ((("company_id" = "public"."auth_company_id"()) AND (("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"]))));



CREATE POLICY "hr_select_own_company_profiles" ON "public"."profiles" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("company_id" = "public"."auth_company_id"())));



ALTER TABLE "public"."integration_configs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "integration_configs_hr_select" ON "public"."integration_configs" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



ALTER TABLE "public"."integration_messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "integration_messages_hr_select" ON "public"."integration_messages" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



ALTER TABLE "public"."labor_contracts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "labor_contracts_hr_select" ON "public"."labor_contracts" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



CREATE POLICY "labor_contracts_self_select" ON "public"."labor_contracts" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."profile_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_hr_insert" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text"));



CREATE POLICY "profiles_self_select" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "profiles_self_update" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."role_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tbi_loan_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tbi_loan_employee_select" ON "public"."tbi_loan_applications" FOR SELECT TO "authenticated" USING (("profile_id" = "auth"."uid"()));



CREATE POLICY "tbi_loan_hr_select" ON "public"."tbi_loan_applications" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_roles" "ur"
  WHERE (("ur"."user_id" = "auth"."uid"()) AND ("ur"."role" = ANY (ARRAY['hr'::"public"."user_role", 'admin'::"public"."user_role"]))))) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "tbi_loan_applications"."profile_id") AND ("p"."company_id" = "public"."auth_company_id"()))))));



ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_roles_hr_select" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("user_id" IN ( SELECT "p"."user_id"
   FROM "public"."profiles" "p"
  WHERE ("p"."company_id" = "public"."auth_company_id"())))));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."auth_company_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."auth_company_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auth_company_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "anon";
GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "authenticated";
GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "service_role";



GRANT ALL ON FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."get_company_terms_for_user"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_company_terms_for_user"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_company_terms_for_user"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_company_user_ids"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_company_user_ids"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_company_user_ids"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_vault_secret"("secret_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_vault_secret"("secret_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_vault_secret"("secret_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_avatar_to_profile"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_avatar_to_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_avatar_to_profile"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_bike_benefit_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_bike_benefit_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_bike_benefit_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_contract_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_contract_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_contract_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON TABLE "public"."bike_benefits" TO "anon";
GRANT ALL ON TABLE "public"."bike_benefits" TO "authenticated";
GRANT ALL ON TABLE "public"."bike_benefits" TO "service_role";



GRANT ALL ON TABLE "public"."bike_orders" TO "anon";
GRANT ALL ON TABLE "public"."bike_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."bike_orders" TO "service_role";



GRANT ALL ON TABLE "public"."bikes" TO "anon";
GRANT ALL ON TABLE "public"."bikes" TO "authenticated";
GRANT ALL ON TABLE "public"."bikes" TO "service_role";



GRANT ALL ON TABLE "public"."companies" TO "anon";
GRANT ALL ON TABLE "public"."companies" TO "authenticated";
GRANT ALL ON TABLE "public"."companies" TO "service_role";



GRANT ALL ON TABLE "public"."dealers" TO "anon";
GRANT ALL ON TABLE "public"."dealers" TO "authenticated";
GRANT ALL ON TABLE "public"."dealers" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."bikes_with_my_pricing" TO "anon";
GRANT ALL ON TABLE "public"."bikes_with_my_pricing" TO "authenticated";
GRANT ALL ON TABLE "public"."bikes_with_my_pricing" TO "service_role";



GRANT ALL ON TABLE "public"."company_notifications" TO "anon";
GRANT ALL ON TABLE "public"."company_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."company_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."contracts" TO "anon";
GRANT ALL ON TABLE "public"."contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."contracts" TO "service_role";



GRANT ALL ON TABLE "public"."employee_pii" TO "anon";
GRANT ALL ON TABLE "public"."employee_pii" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_pii" TO "service_role";



GRANT ALL ON TABLE "public"."integration_configs" TO "anon";
GRANT ALL ON TABLE "public"."integration_configs" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_configs" TO "service_role";



GRANT ALL ON TABLE "public"."integration_messages" TO "anon";
GRANT ALL ON TABLE "public"."integration_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_messages" TO "service_role";



GRANT ALL ON TABLE "public"."labor_contracts" TO "anon";
GRANT ALL ON TABLE "public"."labor_contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."labor_contracts" TO "service_role";



GRANT ALL ON TABLE "public"."profile_invites" TO "anon";
GRANT ALL ON TABLE "public"."profile_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_invites" TO "service_role";



GRANT ALL ON TABLE "public"."profile_invites_with_details" TO "anon";
GRANT ALL ON TABLE "public"."profile_invites_with_details" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_invites_with_details" TO "service_role";



GRANT ALL ON TABLE "public"."role_permissions" TO "anon";
GRANT ALL ON TABLE "public"."role_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permissions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."role_permissions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."role_permissions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."role_permissions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tbi_loan_applications" TO "anon";
GRANT ALL ON TABLE "public"."tbi_loan_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."tbi_loan_applications" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "service_role";
GRANT ALL ON TABLE "public"."user_roles" TO "supabase_auth_admin";
GRANT SELECT ON TABLE "public"."user_roles" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."user_roles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_roles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_roles_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







