


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


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






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
    'first_initial_last',
    'last',
    'first'
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
    'inactive',
    'pending_sso_claim'
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



CREATE OR REPLACE FUNCTION "public"."bike_sync_invoke"("p_run_id" "uuid", "p_branch" "text") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'net', 'vault'
    AS $$
DECLARE
  v_secret     text;
  v_base       text;
  v_request_id bigint;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets WHERE name = 'bike_sync_webhook_secret' LIMIT 1;
  IF v_secret IS NULL THEN
    RAISE WARNING '[bike_sync_invoke] Vault secret "bike_sync_webhook_secret" not found — invocation skipped';
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_base
    FROM vault.decrypted_secrets WHERE name = 'bike_sync_base_url' LIMIT 1;
  v_base := COALESCE(v_base, 'https://xlfkdumbsflqxpezolhl.supabase.co');

  SELECT net.http_post(
    url     := v_base || '/functions/v1/bike-sync',
    headers := jsonb_build_object(
      'Content-Type',     'application/json',
      'x-webhook-secret', v_secret
    ),
    body    := jsonb_build_object('run_id', p_run_id, 'branch', p_branch),
    timeout_milliseconds := 30000
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;


ALTER FUNCTION "public"."bike_sync_invoke"("p_run_id" "uuid", "p_branch" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."bike_sync_invoke"("p_run_id" "uuid", "p_branch" "text") IS 'Fire-and-forget pg_net POST to the bike-sync edge fn for one branch drain. Base URL from Vault secret bike_sync_base_url (falls back to prod). Webhook secret from Vault (bike_sync_webhook_secret).';



CREATE OR REPLACE FUNCTION "public"."bike_sync_kickoff"("p_mode" "text" DEFAULT 'manual'::"text", "p_categories" "text"[] DEFAULT NULL::"text"[]) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  c_dealer    constant uuid   := '099380e6-5991-4acc-b737-9815365bf9d1';  -- Bella Bike
  c_leaves    constant text[] := ARRAY['721', '722', '723', '725', '751'];
  v_cats      text[];
  v_watermark timestamptz;
  v_run_id    uuid;
  v_cat       text;
BEGIN
  v_cats := COALESCE(p_categories, c_leaves);

  SELECT max(watermark_to) INTO v_watermark
    FROM sync_runs WHERE dealer_id = c_dealer AND status = 'succeeded';

  INSERT INTO sync_runs (dealer_id, mode, status, watermark_from, watermark_to)
  VALUES (
    c_dealer, p_mode, 'running',
    CASE WHEN p_mode = 'weekly' THEN NULL ELSE v_watermark END,
    now()
  )
  RETURNING id INTO v_run_id;

  -- One prepare unit per category; each fans out its own rest_page units.
  FOREACH v_cat IN ARRAY v_cats LOOP
    INSERT INTO sync_units (run_id, branch, kind, category_id)
    VALUES (v_run_id, 'sync', 'prepare', v_cat);
  END LOOP;

  PERFORM public.bike_sync_invoke(v_run_id, 'sync');
  RETURN v_run_id;
END;
$$;


ALTER FUNCTION "public"."bike_sync_kickoff"("p_mode" "text", "p_categories" "text"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."bike_sync_kickoff"("p_mode" "text", "p_categories" "text"[]) IS 'Seed a BellaBike sync run + SYNC-branch queue (one unit per leaf category) and fire the first edge-fn invocation. p_categories restricts the run for staged manual rollout.';



CREATE OR REPLACE FUNCTION "public"."bike_sync_tick"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  c_max_lanes constant integer := 2;   -- concurrency cap (vendor rate-limit knob)
  r            record;
  v_inflight   integer;
  v_sync_claim integer;
  v_audit_claim integer;
  v_slots      integer;
  v_fired      integer := 0;
  i            integer;
BEGIN
  FOR r IN SELECT id FROM sync_runs WHERE status = 'running' LOOP
    SELECT count(*) INTO v_inflight FROM sync_units
      WHERE run_id = r.id AND status = 'running'
        AND leased_until IS NOT NULL AND leased_until >= now();

    SELECT count(*) INTO v_sync_claim FROM sync_units
      WHERE run_id = r.id AND branch = 'sync'
        AND ( (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
           OR (status = 'running'  AND leased_until IS NOT NULL AND leased_until < now()) );

    SELECT count(*) INTO v_audit_claim FROM sync_units
      WHERE run_id = r.id AND branch = 'audit'
        AND ( (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
           OR (status = 'running'  AND leased_until IS NOT NULL AND leased_until < now()) );

    v_slots := c_max_lanes - v_inflight;

    IF v_slots > 0 AND v_sync_claim > 0 THEN
      FOR i IN 1..LEAST(v_slots, v_sync_claim) LOOP
        PERFORM public.bike_sync_invoke(r.id, 'sync'); v_fired := v_fired + 1;
      END LOOP;

    ELSIF v_slots > 0 AND v_audit_claim > 0 THEN
      FOR i IN 1..LEAST(v_slots, v_audit_claim) LOOP
        PERFORM public.bike_sync_invoke(r.id, 'audit'); v_fired := v_fired + 1;
      END LOOP;

    ELSIF v_inflight = 0 AND v_sync_claim = 0 AND v_audit_claim = 0 THEN
      -- Truly idle: either sync drained but audit not seeded, or all done.
      IF NOT EXISTS (SELECT 1 FROM sync_units WHERE run_id = r.id AND branch = 'audit')
         AND NOT EXISTS (SELECT 1 FROM sync_units
                          WHERE run_id = r.id AND branch = 'sync'
                            AND status IN ('enqueued', 'running')) THEN
        PERFORM public.seed_audit_units(r.id);
        PERFORM public.bike_sync_invoke(r.id, 'audit'); v_fired := v_fired + 1;
      ELSE
        PERFORM public.finalize_sync_run(r.id);
      END IF;
    END IF;
  END LOOP;

  RETURN v_fired;
END;
$$;


ALTER FUNCTION "public"."bike_sync_tick"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."bike_sync_tick"() IS 'pg_cron heartbeat: drives every running sync_run by firing up to MAX_LANES−inflight bike-sync workers, transitions sync→audit, and finalizes drained runs. Decouples liveness from any single edge isolate.';



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


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."sync_units" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_id" "uuid" NOT NULL,
    "branch" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "category_id" "text",
    "status" "text" DEFAULT 'enqueued'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "next_retry_at" timestamp with time zone,
    "n_fetched" integer DEFAULT 0 NOT NULL,
    "n_upserted" integer DEFAULT 0 NOT NULL,
    "n_models_upserted" integer DEFAULT 0 NOT NULL,
    "n_failed" integer DEFAULT 0 NOT NULL,
    "error" "text",
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "page" integer,
    "page_size" integer,
    "leased_until" timestamp with time zone,
    CONSTRAINT "sync_units_branch_check" CHECK (("branch" = ANY (ARRAY['sync'::"text", 'audit'::"text"]))),
    CONSTRAINT "sync_units_kind_check" CHECK (("kind" = ANY (ARRAY['rest_category'::"text", 'prepare'::"text", 'rest_page'::"text", 'gql_membership'::"text", 'verify'::"text"]))),
    CONSTRAINT "sync_units_status_check" CHECK (("status" = ANY (ARRAY['enqueued'::"text", 'running'::"text", 'succeeded'::"text", 'failed'::"text", 'skipped'::"text"])))
);


ALTER TABLE "public"."sync_units" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_units" IS 'WorkManager-style queue: one unit per category per branch. Drained by the bike-sync edge fn via FOR UPDATE SKIP LOCKED; retried 3x with backoff (next_retry_at).';



CREATE OR REPLACE FUNCTION "public"."claim_next_sync_unit"("p_run_id" "uuid", "p_branch" "text", "p_lease_seconds" integer DEFAULT 90) RETURNS "public"."sync_units"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_unit public.sync_units;
BEGIN
  UPDATE sync_units SET
    status       = 'running',
    attempts     = attempts + 1,
    started_at   = COALESCE(started_at, now()),
    leased_until = now() + (p_lease_seconds * interval '1 second')
  WHERE id = (
    SELECT id FROM sync_units
    WHERE run_id = p_run_id
      AND branch = p_branch
      AND (
            (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
         OR (status = 'running'  AND leased_until IS NOT NULL AND leased_until < now())
      )
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING * INTO v_unit;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN v_unit;
END;
$$;


ALTER FUNCTION "public"."claim_next_sync_unit"("p_run_id" "uuid", "p_branch" "text", "p_lease_seconds" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."claim_next_sync_unit"("p_run_id" "uuid", "p_branch" "text", "p_lease_seconds" integer) IS 'Lease-based queue pop: claims an enqueued unit OR steals one whose lease expired (dead worker). FOR UPDATE SKIP LOCKED. Sets leased_until = now()+p_lease_seconds.';



CREATE OR REPLACE FUNCTION "public"."co2_refresh_on_benefit_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_co2 uuid[];
  v_cnt uuid[];
BEGIN
  SELECT array_agg(DISTINCT ep.company_id) INTO v_co2
  FROM changed_benefits cb JOIN public.employee_pii ep ON ep.user_id = cb.user_id
  WHERE ep.company_id IS NOT NULL;

  SELECT array_agg(DISTINCT p.company_id) INTO v_cnt
  FROM changed_benefits cb JOIN public.profiles p ON p.user_id = cb.user_id
  WHERE p.company_id IS NOT NULL;

  IF v_co2 IS NOT NULL THEN
    PERFORM public.refresh_company_co2_stats(date_trunc('week', now())::date, v_co2);
  END IF;
  IF v_cnt IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_counts(v_cnt);
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."co2_refresh_on_benefit_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_sync_unit"("p_unit_id" "uuid", "p_status" "text", "p_n_fetched" integer DEFAULT 0, "p_n_inserted" integer DEFAULT 0, "p_n_updated" integer DEFAULT 0, "p_n_models" integer DEFAULT 0, "p_n_failed" integer DEFAULT 0, "p_error" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_attempts integer;
  v_run_id   uuid;
BEGIN
  SELECT attempts, run_id INTO v_attempts, v_run_id FROM sync_units WHERE id = p_unit_id;

  IF p_status = 'failed' AND v_attempts < 3 THEN
    UPDATE sync_units SET
      status        = 'enqueued',
      leased_until  = NULL,
      next_retry_at = now() + (v_attempts * interval '20 seconds'),
      error         = p_error
    WHERE id = p_unit_id;
    RETURN 'retry';
  END IF;

  UPDATE sync_units SET
    status            = p_status,
    leased_until      = NULL,
    n_fetched         = p_n_fetched,
    n_upserted        = p_n_inserted + p_n_updated,
    n_models_upserted = p_n_models,
    n_failed          = p_n_failed,
    error             = p_error,
    finished_at       = now()
  WHERE id = p_unit_id;

  UPDATE sync_runs SET
    n_fetched         = n_fetched         + p_n_fetched,
    n_inserted        = n_inserted        + p_n_inserted,
    n_updated         = n_updated         + p_n_updated,
    n_models_upserted = n_models_upserted + p_n_models,
    n_failed          = n_failed          + p_n_failed
  WHERE id = v_run_id;

  RETURN p_status;
END;
$$;


ALTER FUNCTION "public"."complete_sync_unit"("p_unit_id" "uuid", "p_status" "text", "p_n_fetched" integer, "p_n_inserted" integer, "p_n_updated" integer, "p_n_models" integer, "p_n_failed" integer, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_has_password"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM "auth"."users"
    WHERE "id" = "auth"."uid"()
      AND "encrypted_password" IS NOT NULL
      AND length("encrypted_password") > 0
  );
$$;


ALTER FUNCTION "public"."current_user_has_password"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."current_user_has_password"() IS 'True if the calling user (auth.uid()) has a password set in auth.users. SECURITY DEFINER, self-scoped, returns only a boolean — never exposes the hash. Mobile uses it to skip the optional password-setup screen after Google SSO.';



CREATE OR REPLACE FUNCTION "public"."custom_access_token_hook"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  claims    jsonb;
  v_user_id uuid := (event->>'user_id')::uuid;
  v_roles   text[];
BEGIN
  -- Get existing claims
  claims := event->'claims';

  -- All roles for this user, ordered by privilege (admin > hr > employee).
  SELECT array_agg(role::text ORDER BY
           CASE role
             WHEN 'admin'    THEN 1
             WHEN 'hr'       THEN 2
             WHEN 'employee' THEN 3
             ELSE 99
           END)
  INTO v_roles
  FROM public.user_roles
  WHERE user_id = v_user_id;

  IF v_roles IS NULL OR array_length(v_roles, 1) IS NULL THEN
    -- No role assigned
    claims := jsonb_set(claims, '{user_role}',  'null'::jsonb);
    claims := jsonb_set(claims, '{user_roles}', '[]'::jsonb);
  ELSE
    -- Highest-privilege role is first in the priv-ordered array.
    claims := jsonb_set(claims, '{user_role}',  to_jsonb(v_roles[1]));
    claims := jsonb_set(claims, '{user_roles}', to_jsonb(v_roles));
  END IF;

  -- Update claims in the event
  event := jsonb_set(event, '{claims}', claims);

  RETURN event;
END;
$$;


ALTER FUNCTION "public"."custom_access_token_hook"("event" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") IS 'Auth hook that injects role claims into the JWT:
  - user_role  : the deterministic highest-privilege role (admin > hr > employee)
  - user_roles : the full priv-ordered array of the user''s roles (e.g. ["hr","employee"])
Multi-role aware (an HR user can also be an employee). No device validation - security enforced via:
1. RLS policies / edge-function guards based on the role claims
2. Employee-only actions gate on a DB user_roles row, never on the single user_role claim';



CREATE OR REPLACE FUNCTION "public"."enforce_email_matches_company_domain"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_company_domain text;
  v_email_domain   text;
BEGIN
  -- REGES-staged invites carry a NULL email until claim time — nothing to check.
  IF NEW.email IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT lower(c.email_domain)
    INTO v_company_domain
    FROM public.companies c
   WHERE c.id = NEW.company_id;

  -- No company / no domain resolvable yet → let the FK + NOT NULL constraints
  -- be the ones that complain, not this check.
  IF v_company_domain IS NULL THEN
    RETURN NEW;
  END IF;

  v_email_domain := lower(split_part(NEW.email, '@', 2));

  IF v_email_domain IS DISTINCT FROM v_company_domain THEN
    RAISE EXCEPTION
      'EMAIL_DOMAIN_MISMATCH: email % (domain %) does not match company % domain %',
      NEW.email, v_email_domain, NEW.company_id, v_company_domain
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_email_matches_company_domain"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_page_units"("p_run_id" "uuid", "p_category_id" "text", "p_total" integer, "p_page_size" integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_pages integer := CEIL(GREATEST(p_total, 0)::numeric / GREATEST(p_page_size, 1));
  p       integer;
BEGIN
  FOR p IN 1..v_pages LOOP
    INSERT INTO sync_units (run_id, branch, kind, category_id, page, page_size)
    VALUES (p_run_id, 'sync', 'rest_page', p_category_id, p, p_page_size)
    ON CONFLICT (run_id, branch, category_id, page) WHERE kind = 'rest_page'
    DO NOTHING;
  END LOOP;
  RETURN v_pages;
END;
$$;


ALTER FUNCTION "public"."enqueue_page_units"("p_run_id" "uuid", "p_category_id" "text", "p_total" integer, "p_page_size" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."enqueue_page_units"("p_run_id" "uuid", "p_category_id" "text", "p_total" integer, "p_page_size" integer) IS 'Fan out one rest_page unit per page of a category (idempotent via the uq_sync_units_page index).';



CREATE TABLE IF NOT EXISTS "public"."sync_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dealer_id" "uuid" NOT NULL,
    "mode" "text" NOT NULL,
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "watermark_from" timestamp with time zone,
    "watermark_to" timestamp with time zone,
    "n_fetched" integer DEFAULT 0 NOT NULL,
    "n_inserted" integer DEFAULT 0 NOT NULL,
    "n_updated" integer DEFAULT 0 NOT NULL,
    "n_unchanged" integer DEFAULT 0 NOT NULL,
    "n_failed" integer DEFAULT 0 NOT NULL,
    "n_delisted" integer DEFAULT 0 NOT NULL,
    "n_models_upserted" integer DEFAULT 0 NOT NULL,
    "error" "text",
    CONSTRAINT "sync_runs_mode_check" CHECK (("mode" = ANY (ARRAY['daily'::"text", 'weekly'::"text", 'manual'::"text"]))),
    CONSTRAINT "sync_runs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'succeeded'::"text", 'partial'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."sync_runs" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_runs" IS 'One row per BellaBike sync fire. Watermark for the next delta = MAX(watermark_to) WHERE status=''succeeded''.';



CREATE OR REPLACE FUNCTION "public"."finalize_sync_run"("p_run_id" "uuid") RETURNS "public"."sync_runs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_succeeded integer;
  v_failed    integer;
  v_pending   integer;
  v_status    text;
  v_run       public.sync_runs;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'succeeded'),
         count(*) FILTER (WHERE status = 'failed'),
         count(*) FILTER (WHERE status IN ('enqueued', 'running'))
    INTO v_succeeded, v_failed, v_pending
    FROM sync_units WHERE run_id = p_run_id;

  IF v_pending > 0 THEN
    SELECT * INTO v_run FROM sync_runs WHERE id = p_run_id;
    RETURN v_run;
  END IF;

  IF    v_failed = 0    THEN v_status := 'succeeded';
  ELSIF v_succeeded = 0 THEN v_status := 'failed';
  ELSE                       v_status := 'partial';
  END IF;

  UPDATE sync_runs SET status = v_status, finished_at = now()
  WHERE id = p_run_id
  RETURNING * INTO v_run;
  RETURN v_run;
END;
$$;


ALTER FUNCTION "public"."finalize_sync_run"("p_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_company_metrics"("p_from" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_to" timestamp with time zone DEFAULT "now"()) RETURNS TABLE("active_accounts" integer, "total_accounts" integer, "active_benefits" integer, "total_benefits" integer, "co2_kg" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_company uuid := (select public.auth_company_id());
  v_role    text := (auth.jwt() ->> 'user_role');
  v_to      timestamptz := COALESCE(p_to, now());
BEGIN
  IF v_company IS NULL OR v_role NOT IN ('hr', 'admin') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    -- active accounts whose last activity falls in [from,to]
    (SELECT count(*)::int FROM (
       SELECT pi.id,
              max(COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at)) AS last_activity
       FROM public.profile_invites pi
       LEFT JOIN public.profiles      p  ON p.profile_invite_id = pi.id
       LEFT JOIN public.bike_benefits bb ON bb.user_id = p.user_id
       LEFT JOIN public.bike_orders   bo ON bo.bike_benefit_id = bb.id
       WHERE pi.company_id = v_company
         AND pi.status = 'active'::public.user_profile_status
       GROUP BY pi.id
     ) a
     WHERE (p_from IS NULL OR a.last_activity >= p_from) AND a.last_activity <= v_to),
    -- total accounts that existed by the window end (cumulative as of to)
    (SELECT count(*)::int FROM public.profile_invites pi
       WHERE pi.company_id = v_company
         AND pi.created_at <= v_to),
    -- active benefits touched in [from,to]
    (SELECT count(*)::int FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = v_company
         AND bb.benefit_status = 'active'::public.benefit_status
         AND (p_from IS NULL OR bb.updated_at >= p_from) AND bb.updated_at <= v_to),
    -- total benefits that existed by the window end (cumulative as of to)
    (SELECT count(*)::int FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = v_company
         AND bb.created_at <= v_to),
    -- CO₂ saved across weeks whose Monday falls in [from,to]
    (SELECT COALESCE(round(sum(s.kg_co2_saved), 3), 0) FROM public.company_co2_stats s
       WHERE s.company_id = v_company
         AND (p_from IS NULL OR s.period >= p_from::date) AND s.period <= v_to::date);
END;
$$;


ALTER FUNCTION "public"."get_company_metrics"("p_from" timestamp with time zone, "p_to" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_company_metrics"("p_from" timestamp with time zone, "p_to" timestamp with time zone) IS 'HR Reports "at a glance" reader. Returns active_accounts / total_accounts / active_benefits / total_benefits / co2_kg for the calling HR/admin''s own company over [p_from, p_to] (p_from NULL = all-time, p_to defaults now()). Numerators are windowed (touched in range); totals are cumulative as of p_to (existed by window end) so active/total is a coherent same-window ratio. Computed on read — any range, no precomputed windows. PostgREST: POST /rest/v1/rpc/get_company_metrics. FE subscribes to company_metrics realtime as a beacon and refetches this for the selected window. See llm-agent-assist/plans/company-metrics-dashboard.md.';



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
  v_provider        text;
  v_hd              text;
  v_email_domain    text;
  v_company_id      uuid;
  v_sso_kind        text;
  v_sso_hd_required boolean;
  v_matched_via     text;
  v_first_name      text;
  v_last_name       text;
  v_description     text;
  v_department      text;
  v_hire_date       bigint;
  v_invite_id       uuid;
BEGIN
  IF NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  v_provider := COALESCE(NEW.raw_app_meta_data->>'provider', 'email');

  -- ============================================================
  -- Google OIDC user (NEW). Everything else falls through to the
  -- existing email/OTP/password logic below, unchanged.
  -- ============================================================
  IF v_provider = 'google' THEN
    v_hd           := NEW.raw_user_meta_data->>'hd';
    v_email_domain := lower(split_part(NEW.email, '@', 2));

    -- Resolve the SSO-enabled company. Prefer the hd claim (the true Workspace
    -- domain); fall back to the email domain only when hd is absent.
    SELECT id, sso_kind, sso_hd_required
      INTO v_company_id, v_sso_kind, v_sso_hd_required
      FROM public.companies
     WHERE lower(email_domain) = COALESCE(lower(v_hd), v_email_domain)
       AND sso_kind = 'google_oidc'
     LIMIT 1;

    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'SSO_DOMAIN_NOT_AUTHORIZED: % / hd=%', NEW.email, COALESCE(v_hd, '<none>');
    END IF;

    IF v_sso_hd_required AND v_hd IS NULL THEN
      RAISE EXCEPTION 'SSO_HD_REQUIRED: % missing hd claim (personal Google account?)', NEW.email;
    END IF;

    IF v_sso_hd_required AND lower(v_hd) <> v_email_domain THEN
      RAISE EXCEPTION 'SSO_HD_EMAIL_MISMATCH: email domain % does not match hd %', v_email_domain, v_hd;
    END IF;

    -- Match an invite by email OR derived_email, scoped to this company.
    -- Prefer the exact-email invite (deterministic). REGES-staged rows have
    -- email NULL but derived_email set — this is how SSO auto-links them.
    SELECT pi.id, pi.first_name, pi.last_name, pi.description, pi.department, pi.hire_date,
           CASE WHEN LOWER(pi.email) = LOWER(NEW.email) THEN 'email' ELSE 'derived_email' END
      INTO v_invite_id, v_first_name, v_last_name, v_description, v_department, v_hire_date,
           v_matched_via
      FROM public.profile_invites pi
     WHERE pi.company_id = v_company_id
       AND (LOWER(pi.email) = LOWER(NEW.email) OR LOWER(pi.derived_email) = LOWER(NEW.email))
     ORDER BY (LOWER(pi.email) = LOWER(NEW.email)) DESC NULLS LAST
     LIMIT 1;

    IF v_invite_id IS NOT NULL THEN
      -- Matched → full onboarding, mirroring the email branch.
      INSERT INTO public.profiles (
        user_id, email, status, company_id,
        first_name, last_name, description, department, hire_date,
        profile_invite_id
      )
      VALUES (
        NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id,
        v_first_name, v_last_name, v_description, v_department, v_hire_date,
        v_invite_id
      )
      ON CONFLICT (user_id) DO UPDATE SET
        email             = EXCLUDED.email,
        status            = 'active'::public.user_profile_status,
        company_id        = EXCLUDED.company_id,
        first_name        = EXCLUDED.first_name,
        last_name         = EXCLUDED.last_name,
        description       = EXCLUDED.description,
        department        = EXCLUDED.department,
        hire_date         = EXCLUDED.hire_date,
        profile_invite_id = EXCLUDED.profile_invite_id;

      INSERT INTO public.user_roles (user_id, role)
      VALUES (NEW.id, 'employee'::public.user_role)
      ON CONFLICT (user_id, role) DO NOTHING;

      -- Flip invite to active; if matched via derived_email, bind its email to
      -- the verified Google email so the invite is no longer "pending" and
      -- downstream joins are stable.
      UPDATE public.profile_invites
         SET status = 'active'::public.user_profile_status,
             email  = CASE WHEN v_matched_via = 'derived_email' THEN NEW.email ELSE email END
       WHERE id = v_invite_id;

      -- Step 4.5: backfill staged REGES PII (mirrors the email branch).
      UPDATE public.employee_pii
         SET user_id    = NEW.id,
             updated_at = now()
       WHERE profile_invite_id = v_invite_id
         AND user_id IS NULL;

      INSERT INTO public.bike_benefits (user_id)
      VALUES (NEW.id)
      ON CONFLICT DO NOTHING;

      INSERT INTO public.company_notifications (company_id, event, event_type, payload)
      VALUES (
        v_company_id, 'user_update', 'created',
        jsonb_build_object(
          'user_id',       NEW.id,
          'employee_name', v_first_name || ' ' || v_last_name,
          'auth_provider', 'google',
          'matched_via',   v_matched_via
        )
      );

      RETURN NEW;
    END IF;

    -- No invite match → pending claim. NO role, NO benefit, NO PII link.
    -- profiles.first_name/last_name are NOT NULL; a Google user carries their
    -- name in the ID token (given_name/family_name, stored in raw_user_meta_data),
    -- so use that, falling back to the name claim then the email local-part.
    -- These are placeholders only — promote_sso_claim overwrites them from the
    -- matched invite once the claim is approved.
    INSERT INTO public.profiles (user_id, email, status, company_id, first_name, last_name)
    VALUES (
      NEW.id, NEW.email, 'pending_sso_claim'::public.user_profile_status, v_company_id,
      COALESCE(NULLIF(NEW.raw_user_meta_data->>'given_name', ''),
               NULLIF(NEW.raw_user_meta_data->>'name', ''),
               split_part(NEW.email, '@', 1)),
      COALESCE(NULLIF(NEW.raw_user_meta_data->>'family_name', ''), '')
    )
    ON CONFLICT (user_id) DO UPDATE SET
      email      = EXCLUDED.email,
      status     = 'pending_sso_claim'::public.user_profile_status,
      company_id = EXCLUDED.company_id;

    INSERT INTO public.sso_pending_claims (user_id, company_id, email, hd, status)
    VALUES (NEW.id, v_company_id, NEW.email, v_hd, 'awaiting_user_info')
    ON CONFLICT DO NOTHING;

    INSERT INTO public.company_notifications (company_id, event, event_type, payload)
    VALUES (
      v_company_id, 'user_update', 'sso_claim_pending',
      jsonb_build_object('user_id', NEW.id, 'email', NEW.email, 'hd', v_hd)
    );

    RETURN NEW;
  END IF;

  -- ============================================================
  -- email / OTP / password user — VERBATIM from the shipped body.
  -- ============================================================

  -- 1. Resolve company_id and employee fields from profile_invites.
  --    Match on email OR derived_email; prefer the exact-email invite.
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
     OR LOWER(pi.derived_email) = LOWER(NEW.email)
  ORDER BY (LOWER(pi.email) = LOWER(NEW.email)) DESC NULLS LAST
  LIMIT 1;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'No active invite found for email %', NEW.email;
  END IF;

  -- 2. Create or update profile (must exist before user_roles FK insert).
  --    profile_invite_id stamps the canonical person link.
  INSERT INTO public.profiles (
    user_id, email, status, company_id,
    first_name, last_name, description, department, hire_date,
    profile_invite_id
  )
  VALUES (
    NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id,
    v_first_name, v_last_name, v_description, v_department, v_hire_date,
    v_invite_id
  )
  ON CONFLICT (user_id) DO UPDATE SET
    email             = EXCLUDED.email,
    status            = 'active'::public.user_profile_status,
    company_id        = EXCLUDED.company_id,
    first_name        = EXCLUDED.first_name,
    last_name         = EXCLUDED.last_name,
    description       = EXCLUDED.description,
    department        = EXCLUDED.department,
    hire_date         = EXCLUDED.hire_date,
    profile_invite_id = EXCLUDED.profile_invite_id;

  -- 3. Assign 'employee' role
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'employee'::public.user_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- 4. Update profile_invites status (by id — covers derived-email matches
  --    where email may be NULL on the invite).
  UPDATE public.profile_invites
  SET status = 'active'::public.user_profile_status
  WHERE id = v_invite_id;

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

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_user_registration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lookup_auth_user"("p_email" "text") RETURNS TABLE("user_id" "uuid", "has_profile" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT
    u.id,
    EXISTS (SELECT 1 FROM "public"."profiles" p WHERE p."user_id" = u.id)
  FROM "auth"."users" u
  WHERE lower(u.email) = lower("p_email")
  LIMIT 1;
$$;


ALTER FUNCTION "public"."lookup_auth_user"("p_email" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."lookup_auth_user"("p_email" "text") IS 'Service-role only. Given an email, returns the auth.users id and whether a profile exists for it. Used by the register edge function to detect + reset a stale orphaned auth account (auth row with no profile) before sending an OTP. SECURITY DEFINER; granted to service_role only (would be an account-existence oracle if exposed to anon/authenticated).';



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


CREATE OR REPLACE FUNCTION "public"."merge_bike_offers"("p_dealer_id" "uuid", "p_models" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  m           jsonb;
  o           jsonb;
  v_model_id  uuid;
  v_offer_ins boolean;
  n_models    integer := 0;
  n_inserted  integer := 0;
  n_updated   integer := 0;
  n_offers    integer := 0;
BEGIN
  FOR m IN SELECT * FROM jsonb_array_elements(p_models)
  LOOP
    INSERT INTO bike_models (
      dealer_id, external_parent_sku, mpn, ean, brand, name, type,
      description, images, raw_specs
    ) VALUES (
      p_dealer_id,
      m->>'external_parent_sku',
      m->>'mpn', m->>'ean', m->>'brand', m->>'name',
      NULLIF(m->>'type', '')::bike_type,
      m->>'description',
      m->'images',
      m->'raw_specs'
    )
    ON CONFLICT (dealer_id, external_parent_sku) DO UPDATE SET
      mpn         = EXCLUDED.mpn,
      ean         = EXCLUDED.ean,
      brand       = EXCLUDED.brand,
      name        = EXCLUDED.name,
      type        = EXCLUDED.type,
      description = EXCLUDED.description,
      images      = EXCLUDED.images,
      raw_specs   = EXCLUDED.raw_specs
      -- in_catalog deliberately preserved — set by the audit branch.
    RETURNING id INTO v_model_id;
    n_models := n_models + 1;

    FOR o IN SELECT * FROM jsonb_array_elements(COALESCE(m->'offers', '[]'::jsonb))
    LOOP
      INSERT INTO bikes (
        name, brand, description, image_url, images, type,
        full_price, list_price, special_price, special_from, special_to,
        in_stock, frame_size, wheel_size, frame_material, power_wh, engine,
        available_for_test, sku, dealer_id, model_id, source, raw_specs,
        active, first_seen_at, last_seen_at, last_in_stock_at
      ) VALUES (
        m->>'name', m->>'brand', m->>'description',
        m->'images'->>0, m->'images', NULLIF(m->>'type', '')::bike_type,
        COALESCE((o->>'full_price')::numeric, 0),
        (o->>'list_price')::numeric,
        (o->>'special_price')::numeric,
        (o->>'special_from')::timestamptz,
        (o->>'special_to')::timestamptz,
        -- INSERT: a brand-new offer with unknown stock defaults to false.
        COALESCE((o->>'in_stock')::boolean, false),
        o->>'frame_size', o->>'wheel_size', o->>'frame_material',
        (o->>'power_wh')::integer, o->>'engine',
        COALESCE((o->>'available_for_test')::boolean, true),
        o->>'sku', p_dealer_id, v_model_id,
        COALESCE(o->>'source', 'bellabike'),
        o->'raw_specs',
        true, now(), now(),
        CASE WHEN (o->>'in_stock')::boolean IS TRUE THEN now() ELSE NULL END
      )
      ON CONFLICT (dealer_id, sku) DO UPDATE SET
        name               = EXCLUDED.name,
        brand              = EXCLUDED.brand,
        description        = EXCLUDED.description,
        image_url          = EXCLUDED.image_url,
        images             = EXCLUDED.images,
        type               = EXCLUDED.type,
        full_price         = EXCLUDED.full_price,
        list_price         = EXCLUDED.list_price,
        special_price      = EXCLUDED.special_price,
        special_from       = EXCLUDED.special_from,
        special_to         = EXCLUDED.special_to,
        -- UPDATE: unknown stock (null) keeps the existing flag — never forces
        -- false. `o` is in scope, so read the raw nullable value directly
        -- (EXCLUDED.in_stock has already been COALESCEd to false above).
        in_stock           = COALESCE((o->>'in_stock')::boolean, bikes.in_stock),
        frame_size         = EXCLUDED.frame_size,
        wheel_size         = EXCLUDED.wheel_size,
        frame_material     = EXCLUDED.frame_material,
        power_wh           = EXCLUDED.power_wh,
        engine             = EXCLUDED.engine,
        available_for_test = EXCLUDED.available_for_test,
        model_id           = EXCLUDED.model_id,
        source             = EXCLUDED.source,
        raw_specs          = EXCLUDED.raw_specs,
        active             = true,
        delisted_at        = NULL,
        last_seen_at       = now(),
        -- only bump when we actually OBSERVED in-stock this run (null → keep).
        last_in_stock_at   = CASE WHEN (o->>'in_stock')::boolean IS TRUE THEN now()
                                  ELSE bikes.last_in_stock_at END
      RETURNING (xmax::text::bigint = 0) INTO v_offer_ins;

      IF v_offer_ins THEN n_inserted := n_inserted + 1;
      ELSE                n_updated  := n_updated  + 1;
      END IF;
      n_offers := n_offers + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'n_models_upserted', n_models,
    'n_inserted',        n_inserted,
    'n_updated',         n_updated,
    'n_offers',          n_offers
  );
END;
$$;


ALTER FUNCTION "public"."merge_bike_offers"("p_dealer_id" "uuid", "p_models" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."merge_bike_offers"("p_dealer_id" "uuid", "p_models" "jsonb") IS 'Single writer: upserts bike_models (parent, by dealer_id+external_parent_sku) and bikes (offer, by dealer_id+sku) in one pass. Duplicated model columns are copied onto each offer here. in_catalog preserved (audit-owned).';



CREATE OR REPLACE FUNCTION "public"."metrics_co2_on_stats_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_companies uuid[];
BEGIN
  SELECT array_agg(DISTINCT company_id) INTO v_companies
  FROM changed_stats WHERE company_id IS NOT NULL;
  IF v_companies IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_co2(v_companies);
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."metrics_co2_on_stats_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."metrics_counts_on_invite_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_companies uuid[];
BEGIN
  SELECT array_agg(DISTINCT company_id) INTO v_companies
  FROM changed_invites WHERE company_id IS NOT NULL;
  IF v_companies IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_counts(v_companies);
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."metrics_counts_on_invite_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."metrics_counts_on_invite_row"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  PERFORM public.refresh_company_metrics_counts(
    ARRAY(SELECT DISTINCT cid
          FROM unnest(ARRAY[NEW.company_id, OLD.company_id]) AS cid
          WHERE cid IS NOT NULL)
  );
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."metrics_counts_on_invite_row"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."metrics_seed_on_company_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_companies uuid[];
BEGIN
  SELECT array_agg(id) INTO v_companies FROM changed_companies;
  IF v_companies IS NOT NULL THEN
    PERFORM public.refresh_company_metrics_counts(v_companies);
    PERFORM public.refresh_company_metrics_co2(v_companies);
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."metrics_seed_on_company_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."promote_sso_claim"("p_claim_id" "uuid", "p_invite_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_claim  sso_pending_claims%ROWTYPE;
  v_invite profile_invites%ROWTYPE;
BEGIN
  -- Caller must be HR/admin in the claim's company, OR the service_role.
  IF COALESCE(auth.jwt() ->> 'role', '') <> 'service_role'
     AND public.get_my_role() NOT IN ('hr','admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  SELECT * INTO v_claim FROM sso_pending_claims WHERE id = p_claim_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
  IF v_claim.status NOT IN ('awaiting_user_info','pending_review') THEN
    RAISE EXCEPTION 'CLAIM_ALREADY_RESOLVED status=%', v_claim.status;
  END IF;

  SELECT * INTO v_invite FROM profile_invites WHERE id = p_invite_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVITE_NOT_FOUND'; END IF;
  IF v_invite.company_id <> v_claim.company_id THEN
    RAISE EXCEPTION 'INVITE_COMPANY_MISMATCH';
  END IF;
  IF v_invite.email IS NOT NULL AND lower(v_invite.email) <> lower(v_claim.email) THEN
    RAISE EXCEPTION 'INVITE_ALREADY_CLAIMED';
  END IF;

  -- Bind invite to the SSO user's email so its email is no longer NULL.
  UPDATE profile_invites
     SET email  = v_claim.email,
         status = 'active'::user_profile_status
   WHERE id = p_invite_id;

  -- Promote profile to active, fill identity fields from the invite, and set
  -- the canonical back-link (depends on profiles.profile_invite_id).
  UPDATE profiles SET
    status            = 'active'::user_profile_status,
    first_name        = v_invite.first_name,
    last_name         = v_invite.last_name,
    description       = v_invite.description,
    department        = v_invite.department,
    hire_date         = v_invite.hire_date,
    profile_invite_id = p_invite_id
   WHERE user_id = v_claim.user_id;

  -- Assign role + create benefit (idempotent — replays don't error).
  INSERT INTO user_roles (user_id, role)
  VALUES (v_claim.user_id, 'employee'::user_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  INSERT INTO bike_benefits (user_id)
  VALUES (v_claim.user_id)
  ON CONFLICT DO NOTHING;

  -- Link any pending REGES employee_pii row to this user (mirrors REGES bridge).
  UPDATE employee_pii
     SET user_id = v_claim.user_id, updated_at = now()
   WHERE profile_invite_id = p_invite_id AND user_id IS NULL;

  -- Resolve claim.
  UPDATE sso_pending_claims SET
    status = 'approved', approved_invite_id = p_invite_id,
    reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
   WHERE id = p_claim_id;

  -- FCM dispatch happens out-of-band via the company_notifications fan-out.
  INSERT INTO company_notifications (company_id, event, event_type, payload)
  VALUES (v_claim.company_id, 'user_update', 'sso_claim_approved',
          jsonb_build_object('user_id', v_claim.user_id, 'invite_id', p_invite_id));

  RETURN jsonb_build_object('approved', true, 'user_id', v_claim.user_id);
END;
$$;


ALTER FUNCTION "public"."promote_sso_claim"("p_claim_id" "uuid", "p_invite_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_company_co2_stats"("p_period" "date" DEFAULT ("date_trunc"('week'::"text", "now"()))::"date", "p_company_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  -- Avg-car avoided-emissions factor, kg CO₂ per km. Identical to mobile's
  -- RouteEstimations (CO2_KG_PER_LITER 2.31 / AVG_CAR_KM_PER_LITER 14.0).
  v_emission_factor constant numeric := 0.165;
BEGIN
  -- LEFT JOIN LATERAL so EVERY company gets a current-week row: companies with
  -- zero qualifying riders upsert to 0 (corrects a drop to zero), not a
  -- missing/stale row.
  INSERT INTO public.company_co2_stats AS s
    (company_id, period, kg_co2_saved, active_riders, total_km, computed_at)
  SELECT
    c.id,
    p_period,
    COALESCE(round(sum(w.week_km * v_emission_factor)::numeric, 3), 0),
    count(w.user_id),
    COALESCE(round(sum(w.week_km)::numeric, 3), 0),
    now()
  FROM public.companies c
  LEFT JOIN LATERAL (
    SELECT
      ep.user_id,
      ep.commute_distance_km * 2 * COALESCE(c.days_in_office, 5) AS week_km
    FROM public.employee_pii ep
    JOIN public.bike_benefits bb ON bb.user_id = ep.user_id
    WHERE ep.company_id = c.id
      AND ep.user_id IS NOT NULL
      AND ep.commute_distance_km IS NOT NULL
      AND bb.delivered_at IS NOT NULL
      AND bb.benefit_status = 'active'::public.benefit_status
  ) w ON true
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  GROUP BY c.id
  ON CONFLICT (company_id, period) DO UPDATE SET
    kg_co2_saved  = EXCLUDED.kg_co2_saved,
    active_riders = EXCLUDED.active_riders,
    total_km      = EXCLUDED.total_km,
    computed_at   = now();
END;
$$;


ALTER FUNCTION "public"."refresh_company_co2_stats"("p_period" "date", "p_company_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."refresh_company_co2_stats"("p_period" "date", "p_company_ids" "uuid"[]) IS 'Idempotent upsert of per-company commute-CO₂ stats for the given WEEK (default: current ISO week, Monday); p_company_ids restricts to specific companies (NULL = all, used by cron; the bike_benefits trigger passes the affected company for live updates). Pure SQL over employee_pii.commute_distance_km + bike_benefits lifecycle gate; never reads plaintext PII. Months/all-time roll up inline in refresh_company_metrics_co2 (→ company_metrics). See mobipass-backend skill references/co2-commute-engine.md.';



CREATE OR REPLACE FUNCTION "public"."refresh_company_ledger"() RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  INSERT INTO public.company_ledger
    (company_id, period, total_accounts, active_accounts, active_benefits, total_benefits, computed_at)
  SELECT company_id, date_trunc('week', now())::date,
         total_accounts, active_accounts, active_benefits, total_benefits, now()
  FROM public.company_metrics
  ON CONFLICT (company_id, period) DO UPDATE SET
    total_accounts  = EXCLUDED.total_accounts,
    active_accounts = EXCLUDED.active_accounts,
    active_benefits = EXCLUDED.active_benefits,
    total_benefits  = EXCLUDED.total_benefits,
    computed_at     = now();
$$;


ALTER FUNCTION "public"."refresh_company_ledger"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."refresh_company_ledger"() IS 'Idempotent upsert of the current ISO week''s company_ledger row from company_metrics (one row/company/week, re-stamped daily, frozen on rollover). Daily pg_cron job company-ledger-refresh. See llm-agent-assist/plans/company-metrics-dashboard.md.';



CREATE OR REPLACE FUNCTION "public"."refresh_company_metrics_co2"("p_company_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.company_metrics AS m
    (company_id, co2_all_time_kg, co2_updated_at)
  SELECT
    c.id,
    COALESCE(s.all_time_kg, 0),
    now()
  FROM public.companies c
  LEFT JOIN (
    SELECT company_id, round(sum(kg_co2_saved), 3) AS all_time_kg
    FROM public.company_co2_stats
    GROUP BY company_id
  ) s ON s.company_id = c.id
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  ON CONFLICT (company_id) DO UPDATE SET
    co2_all_time_kg = EXCLUDED.co2_all_time_kg,
    co2_updated_at  = now();
END;
$$;


ALTER FUNCTION "public"."refresh_company_metrics_co2"("p_company_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_company_metrics_counts"("p_company_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.company_metrics AS m
    (company_id, total_accounts, active_accounts, active_benefits, total_benefits, counts_updated_at)
  SELECT
    c.id,
    (SELECT count(*) FROM public.profile_invites pi WHERE pi.company_id = c.id),
    (SELECT count(*) FROM public.profile_invites pi
       WHERE pi.company_id = c.id AND pi.status = 'active'::public.user_profile_status),
    (SELECT count(*) FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = c.id AND bb.benefit_status = 'active'::public.benefit_status),
    (SELECT count(*) FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = c.id),
    now()
  FROM public.companies c
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  ON CONFLICT (company_id) DO UPDATE SET
    total_accounts    = EXCLUDED.total_accounts,
    active_accounts   = EXCLUDED.active_accounts,
    active_benefits   = EXCLUDED.active_benefits,
    total_benefits    = EXCLUDED.total_benefits,
    counts_updated_at = now();
END;
$$;


ALTER FUNCTION "public"."refresh_company_metrics_counts"("p_company_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_audit_units"("p_run_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM sync_units WHERE run_id = p_run_id AND branch = 'audit') THEN
    RETURN;   -- already seeded
  END IF;
  INSERT INTO sync_units (run_id, branch, kind) VALUES
    (p_run_id, 'audit', 'gql_membership'),
    (p_run_id, 'audit', 'verify');
END;
$$;


ALTER FUNCTION "public"."seed_audit_units"("p_run_id" "uuid") OWNER TO "postgres";


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
    "dealer_id" "uuid" NOT NULL,
    "model_id" "uuid",
    "source" "text",
    "active" boolean DEFAULT true NOT NULL,
    "delisted_at" timestamp with time zone,
    "first_seen_at" timestamp with time zone,
    "last_seen_at" timestamp with time zone,
    "last_in_stock_at" timestamp with time zone,
    "list_price" numeric(10,2),
    "special_price" numeric(10,2),
    "special_from" timestamp with time zone,
    "special_to" timestamp with time zone,
    "raw_specs" "jsonb"
);


ALTER TABLE "public"."bikes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."bikes"."full_price" IS 'Effective price = LEAST(list_price, special_price when in window). UNCHANGED benefit basis — both pricing fns key off this.';



COMMENT ON COLUMN "public"."bikes"."type" IS 'Type/category of the bike (e.g., e-MTB, e-city, e-touring)';



COMMENT ON COLUMN "public"."bikes"."model_id" IS 'Parent bike_models row (ON DELETE RESTRICT). The selectable/orderable unit stays bikes.';



COMMENT ON COLUMN "public"."bikes"."source" IS 'Provenance vendor key (e.g. ''bellabike''). NULL for legacy Maros rows.';



COMMENT ON COLUMN "public"."bikes"."last_in_stock_at" IS 'Last time this offer was seen in stock (is-product-salable/2 = true). Powers back-in-stock detection.';



COMMENT ON COLUMN "public"."bikes"."list_price" IS 'Vendor list (regular) price.';



COMMENT ON COLUMN "public"."bikes"."special_price" IS 'Vendor promo price; effective only inside [special_from, special_to].';



COMMENT ON COLUMN "public"."bikes"."raw_specs" IS 'Decoded vendor option attributes (jsonb). Marketing prose + component table stay in description (HTML, no parser).';



CREATE OR REPLACE FUNCTION "public"."specifications"("b" "public"."bikes") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('label', s.label, 'value', s.value)
      ORDER BY s.ord
    ) FILTER (WHERE NULLIF(btrim(s.value), '') IS NOT NULL),
    '[]'::jsonb
  )
  FROM (VALUES
    ( 1, 'Supported features', b.supported_features),
    ( 2, 'Motor',           COALESCE(b.raw_specs ->> 'motorizare',   b.engine)),
    ( 3, 'Motor power',     b.raw_specs ->> 'putere_motor'),
    ( 4, 'Gears',           b.raw_specs ->> 'numar_viteze'),
    ( 5, 'Brakes',          b.raw_specs ->> 'tip_franare'),
    ( 6, 'Frame material',  COALESCE(b.raw_specs ->> 'material',      b.frame_material)),
    ( 7, 'Frame size',      COALESCE(b.raw_specs ->> 'marime',        b.frame_size)),
    ( 8, 'Wheel size',      COALESCE(b.raw_specs ->> 'marime_roata',  b.wheel_size)),
    ( 9, 'Wheel bandwidth', b.wheel_bandwidth),
    (10, 'Category',        b.raw_specs ->> 'gen'),
    (11, 'Color',           b.raw_specs ->> 'color'),
    (12, 'Lock',            b.lock_type)
  ) AS s(ord, label, value);
$$;


ALTER FUNCTION "public"."specifications"("b" "public"."bikes") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."specifications"("b" "public"."bikes") IS 'Single source of truth for the dynamic Specifications [{label,value}] list. Prefers decoded vendor attributes in raw_specs (synced bikes), falls back to curated columns (legacy bikes); drops empty rows. Excludes keys shown elsewhere (battery→Power, brand) and the internal stock key. Used by the bikes_with_my_pricing view AND exposed by PostgREST as a computed column on bikes (select it explicitly — not included by select=*).';



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
    "live_test_lon" double precision,
    "prior_commute_mode" "text",
    CONSTRAINT "bike_benefits_prior_commute_mode_check" CHECK ((("prior_commute_mode" IS NULL) OR ("prior_commute_mode" = ANY (ARRAY['car'::"text", 'public_transit'::"text", 'bike'::"text", 'walk'::"text", 'motorcycle'::"text", 'other'::"text", 'unknown'::"text"]))))
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



COMMENT ON COLUMN "public"."bike_benefits"."prior_commute_mode" IS 'Rider''s commute mode before the e-bike, captured once at onboarding. Used to qualify the CSRD avoided-emissions baseline. NULL = unknown → v1 aggregation assumes the average-car baseline.';



CREATE TABLE IF NOT EXISTS "public"."bike_models" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dealer_id" "uuid" NOT NULL,
    "external_parent_sku" "text" NOT NULL,
    "mpn" "text",
    "ean" "text",
    "brand" "text",
    "name" "text" NOT NULL,
    "type" "public"."bike_type",
    "description" "text",
    "images" "jsonb",
    "raw_specs" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bike_models" OWNER TO "postgres";


COMMENT ON TABLE "public"."bike_models" IS 'Shared model facts (parent grain). One row per dealer configurable-parent listing (or standalone-simple singleton). bikes = the per-dealer OFFER under a model. type + in_catalog live here. Phase 1: model columns are duplicated onto bikes and written by the single merge RPC; the join into the catalog view is Phase 2.';



COMMENT ON COLUMN "public"."bike_models"."external_parent_sku" IS 'Vendor parent SKU (BellaBike configurable parent, or the simple''s own SKU for singletons; legacy Maros rows use "legacy:<bike_id>"). Phase-1 merge key with dealer_id.';



COMMENT ON COLUMN "public"."bike_models"."mpn" IS 'Manufacturer part number — stored + indexed as the future cross-dealer model-match seam (matching deferred).';



COMMENT ON COLUMN "public"."bike_models"."ean" IS 'EAN/barcode — stored + indexed as the future cross-dealer model-match seam (matching deferred).';



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
    "email_domain" "text" NOT NULL,
    "email_pattern" "public"."email_pattern_kind",
    "sso_kind" "text" DEFAULT 'none'::"text" NOT NULL,
    "sso_hd_required" boolean DEFAULT true NOT NULL,
    "sso_config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "companies_email_domain_format" CHECK ((("email_domain" = "lower"("email_domain")) AND ("email_domain" ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'::"text"))),
    CONSTRAINT "companies_sso_kind_check" CHECK (("sso_kind" = ANY (ARRAY['none'::"text", 'google_oidc'::"text", 'microsoft_oidc'::"text", 'saml'::"text"])))
);


ALTER TABLE "public"."companies" OWNER TO "postgres";


COMMENT ON TABLE "public"."companies" IS 'This represents the companies for which each users adhere to. 1 user can have only 1 company a company can have multiple users.';



COMMENT ON COLUMN "public"."companies"."monthly_benefit_subsidy" IS 'Monthly subsidy amount the company provides for bike benefits (e.g., €72/month)';



COMMENT ON COLUMN "public"."companies"."contract_months" IS 'Standard contract duration in months for bike benefits (e.g., 36 months)';



COMMENT ON COLUMN "public"."companies"."currency" IS 'Currency used for bike benefit pricing. Defaults to RON.';



COMMENT ON COLUMN "public"."companies"."esignatures_template_id" IS 'eSignatures.com template ID used to generate bike benefit contracts for employees of this company. Must be set before send-contract can be called.';



COMMENT ON COLUMN "public"."companies"."days_in_office" IS 'Number of days per week employees commute to the office (1-7). Used for dashboard estimations (distance, calories, CO2, fuel saved).';



COMMENT ON COLUMN "public"."companies"."email_domain" IS 'Primary corporate email domain (e.g. "8x8.com"). Required. Used at registration to scope claim-by-name lookup and at REGES upload to derive employee emails. Bare hostname only — no scheme, no "@", lowercase.';



COMMENT ON COLUMN "public"."companies"."email_pattern" IS 'Optional named email pattern used to derive employee email at REGES ingest. NULL = no derivation (employees self-claim by name/DOB). Template lookup lives in TS (EMAIL_PATTERN_TEMPLATES).';



COMMENT ON COLUMN "public"."companies"."sso_kind" IS 'SSO method for this tenant. "none" = email+password only. "google_oidc" = Google Workspace via OAuth (implemented). "microsoft_oidc"/"saml" reserved (ADR §5) — config + trigger branch, no re-model.';



COMMENT ON COLUMN "public"."companies"."sso_hd_required" IS 'When true, the Google ID token "hd" claim must be present and equal email_domain. Set false ONLY for testing / Workspace-less Google accounts. (Microsoft will use sso_config.tenant_id instead.)';



COMMENT ON COLUMN "public"."companies"."sso_config" IS 'Provider-specific config. Microsoft-ready keys: { tenant_id?, issuer?, email_claim?, attribute_map?, client_id_override? }. Company resolution = tenant assertion first (tid/issuer), email_domain second. Empty {} = defaults.';



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
    "profile_image_path" "text",
    "profile_invite_id" "uuid"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."first_name" IS 'Employee first name';



COMMENT ON COLUMN "public"."profiles"."last_name" IS 'Employee last name';



COMMENT ON COLUMN "public"."profiles"."description" IS 'Employee description or bio';



COMMENT ON COLUMN "public"."profiles"."department" IS 'Employee department or team';



COMMENT ON COLUMN "public"."profiles"."hire_date" IS 'Employee hire date as Unix timestamp in milliseconds';



COMMENT ON COLUMN "public"."profiles"."profile_invite_id" IS 'Canonical link to the person''s profile_invites row (SSOT person id). Set by handle_user_registration on claim; backfilled here by email match. UNIQUE (one profile per invite) — the cross-provider fork safety net.';



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
    "prices"."monthly_employee_price" AS "employee_monthly_price",
    "public"."specifications"("b".*) AS "specifications"
   FROM (((("public"."bikes" "b"
     JOIN "public"."dealers" "d" ON (("d"."id" = "b"."dealer_id")))
     LEFT JOIN "public"."profiles" "me" ON (("me"."user_id" = "auth"."uid"())))
     LEFT JOIN "public"."companies" "c" ON (("c"."id" = "me"."company_id")))
     LEFT JOIN LATERAL "public"."calc_employee_prices"("b"."full_price", "c"."monthly_benefit_subsidy", "c"."contract_months") "prices"("employee_price", "monthly_employee_price") ON (true));


ALTER VIEW "public"."bikes_with_my_pricing" OWNER TO "postgres";


COMMENT ON VIEW "public"."bikes_with_my_pricing" IS 'Bike catalog with employee-specific pricing and dealer info. Uses auth.uid() to resolve the calling user''s company subsidy and contract terms automatically. Returns all bikes; pricing columns are NULL when the user has no linked company. `specifications` is the dynamic [{label,value}] spec list (public.specifications); General-details columns (weight_kg/charge_time_hours/range_max_km/power_wh) stay separate.';



CREATE TABLE IF NOT EXISTS "public"."company_co2_stats" (
    "company_id" "uuid" NOT NULL,
    "period" "date" NOT NULL,
    "kg_co2_saved" numeric DEFAULT 0 NOT NULL,
    "active_riders" integer DEFAULT 0 NOT NULL,
    "total_km" numeric DEFAULT 0 NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."company_co2_stats" OWNER TO "postgres";


COMMENT ON TABLE "public"."company_co2_stats" IS 'Per-company WEEKLY commute-CO₂ aggregate (period = Monday of the ISO week) for the HR / CSRD dashboard. Populated only by the engine (refresh_company_co2_stats via pg_cron) — no client write path. Months/all-time roll up inline in refresh_company_metrics_co2 (→ company_metrics; clients read that table). kg_co2_saved is ESTIMATED AVOIDED emissions vs. an average-car baseline (NOT a Scope-3 inventory reduction). Methodology: mobipass-backend skill references/co2-commute-engine.md.';



CREATE TABLE IF NOT EXISTS "public"."company_ledger" (
    "company_id" "uuid" NOT NULL,
    "period" "date" NOT NULL,
    "total_accounts" integer DEFAULT 0 NOT NULL,
    "active_accounts" integer DEFAULT 0 NOT NULL,
    "active_benefits" integer DEFAULT 0 NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total_benefits" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."company_ledger" OWNER TO "postgres";


COMMENT ON TABLE "public"."company_ledger" IS 'Per-company WEEKLY point-in-time snapshot (period = Monday) of currently-active account/benefit counts, sampled off company_metrics by refresh_company_ledger (daily cron). Frozen on week rollover. Feeds the HR Reports monthly trend chart via company_metrics_monthly. No client write path. See llm-agent-assist/plans/company-metrics-dashboard.md.';



CREATE TABLE IF NOT EXISTS "public"."company_metrics" (
    "company_id" "uuid" NOT NULL,
    "total_accounts" integer DEFAULT 0 NOT NULL,
    "active_accounts" integer DEFAULT 0 NOT NULL,
    "active_benefits" integer DEFAULT 0 NOT NULL,
    "co2_all_time_kg" numeric DEFAULT 0 NOT NULL,
    "counts_updated_at" timestamp with time zone,
    "co2_updated_at" timestamp with time zone,
    "total_benefits" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."company_metrics" OWNER TO "postgres";


COMMENT ON TABLE "public"."company_metrics" IS 'Per-company HR-console KPI projection (one row/company): account/benefit counts + all-time commute-CO₂. Engine-maintained via triggers; no client write path. Realtime-published → the FE subscribes to it as a beacon and refetches get_company_metrics for windowed ranges (the all-time card reads this row directly). company_co2_stats remains the authoritative weekly time-series. Skill: references/co2-commute-engine.md.';



CREATE OR REPLACE VIEW "public"."company_metrics_monthly" WITH ("security_invoker"='on') AS
 SELECT DISTINCT ON ("company_id", ("date_trunc"('month'::"text", ("period")::timestamp with time zone))) "company_id",
    ("date_trunc"('month'::"text", ("period")::timestamp with time zone))::"date" AS "month",
    "active_accounts",
    "active_benefits",
    "total_accounts",
    "total_benefits"
   FROM "public"."company_ledger"
  ORDER BY "company_id", ("date_trunc"('month'::"text", ("period")::timestamp with time zone)), "period" DESC;


ALTER VIEW "public"."company_metrics_monthly" OWNER TO "postgres";


COMMENT ON VIEW "public"."company_metrics_monthly" IS 'HR Reports monthly trend chart: per (company, month) the END-OF-MONTH balance (last weekly company_ledger snapshot in the month) of currently-active accounts/benefits. security_invoker inherits company_ledger RLS (HR/admin own company). FE: GET /rest/v1/company_metrics_monthly?month=gte.<from>&month=lte.<to>. Frozen history → no realtime.';



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
    "profile_invite_id" "uuid",
    "commute_distance_km" numeric,
    "commute_distance_computed_at" timestamp with time zone,
    "commute_distance_source" "text",
    CONSTRAINT "employee_pii_commute_distance_source_check" CHECK ((("commute_distance_source" IS NULL) OR ("commute_distance_source" = ANY (ARRAY['routed'::"text", 'estimated'::"text"]))))
);


ALTER TABLE "public"."employee_pii" OWNER TO "postgres";


COMMENT ON COLUMN "public"."employee_pii"."profile_invite_id" IS 'Links a REGES-staged PII row to its profile_invites row. Lets handle_user_registration backfill employee_pii.user_id when the matching invite is claimed.';



COMMENT ON COLUMN "public"."employee_pii"."commute_distance_km" IS 'Derived one-way commute distance home→office in km. Computed in the edge runtime (update-employee-pii / recompute-commute-distances) from decrypted home coords + companies.address_lat/lon. NULL when coords are missing. Consumed by the per-company CO₂ aggregation (refresh_company_co2_stats); never exposed per-employee to HR.';



COMMENT ON COLUMN "public"."employee_pii"."commute_distance_source" IS 'Provenance of commute_distance_km (CSRD auditability): ''estimated'' = haversine × 1.3 detour (the v1 default, no external dependency); ''routed'' = OpenRouteService driving-car road distance (opt-in, only when ors_base_url is configured — intended for a self-hosted ORS).';



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
     LEFT JOIN "public"."profiles" "p" ON (("p"."profile_invite_id" = "pi"."id")))
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



CREATE TABLE IF NOT EXISTS "public"."sso_pending_claims" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "company_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "hd" "text",
    "first_name" "text",
    "last_name" "text",
    "date_of_birth_encrypted" "text",
    "birth_date_hash" "text",
    "suggested_invite_ids" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "suggested_scores" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'awaiting_user_info'::"text" NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "approved_invite_id" "uuid",
    "rejected_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sso_pending_claims_status_check" CHECK (("status" = ANY (ARRAY['awaiting_user_info'::"text", 'pending_review'::"text", 'approved'::"text", 'rejected'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."sso_pending_claims" OWNER TO "postgres";


COMMENT ON TABLE "public"."sso_pending_claims" IS 'Review queue for SSO users with no matching profile_invites row. One active row per user (partial unique). Resolved by promote_sso_claim (Migration 4).';



CREATE TABLE IF NOT EXISTS "public"."sync_run_cache" (
    "run_id" "uuid" NOT NULL,
    "scope" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sync_run_cache" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sync_run_summary" AS
SELECT
    NULL::"uuid" AS "id",
    NULL::"uuid" AS "dealer_id",
    NULL::"text" AS "mode",
    NULL::"text" AS "status",
    NULL::timestamp with time zone AS "started_at",
    NULL::timestamp with time zone AS "finished_at",
    NULL::timestamp with time zone AS "watermark_from",
    NULL::timestamp with time zone AS "watermark_to",
    NULL::integer AS "n_fetched",
    NULL::integer AS "n_inserted",
    NULL::integer AS "n_updated",
    NULL::integer AS "n_unchanged",
    NULL::integer AS "n_failed",
    NULL::integer AS "n_delisted",
    NULL::integer AS "n_models_upserted",
    NULL::"text" AS "error",
    NULL::bigint AS "n_units",
    NULL::bigint AS "units_succeeded",
    NULL::bigint AS "units_failed",
    NULL::bigint AS "units_skipped",
    NULL::bigint AS "units_pending";


ALTER VIEW "public"."sync_run_summary" OWNER TO "postgres";


COMMENT ON VIEW "public"."sync_run_summary" IS 'Per-run rollup of BellaBike sync: run counters + unit status tallies. Local verify: select * from sync_run_summary order by started_at desc;';



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



ALTER TABLE ONLY "public"."bike_models"
    ADD CONSTRAINT "bike_models_dealer_parent_sku_key" UNIQUE ("dealer_id", "external_parent_sku");



ALTER TABLE ONLY "public"."bike_models"
    ADD CONSTRAINT "bike_models_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bikes"
    ADD CONSTRAINT "bikes_dealer_id_sku_key" UNIQUE ("dealer_id", "sku");



ALTER TABLE ONLY "public"."bikes"
    ADD CONSTRAINT "bikes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_co2_stats"
    ADD CONSTRAINT "company_co2_stats_pkey" PRIMARY KEY ("company_id", "period");



ALTER TABLE ONLY "public"."company_ledger"
    ADD CONSTRAINT "company_ledger_pkey" PRIMARY KEY ("company_id", "period");



ALTER TABLE ONLY "public"."company_metrics"
    ADD CONSTRAINT "company_metrics_pkey" PRIMARY KEY ("company_id");



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



ALTER TABLE ONLY "public"."sso_pending_claims"
    ADD CONSTRAINT "sso_pending_claims_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sync_run_cache"
    ADD CONSTRAINT "sync_run_cache_pkey" PRIMARY KEY ("run_id", "scope");



ALTER TABLE ONLY "public"."sync_runs"
    ADD CONSTRAINT "sync_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sync_units"
    ADD CONSTRAINT "sync_units_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tbi_loan_applications"
    ADD CONSTRAINT "tbi_loan_applications_order_id_key" UNIQUE ("order_id");



ALTER TABLE ONLY "public"."tbi_loan_applications"
    ADD CONSTRAINT "tbi_loan_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "unique_benefit_order" UNIQUE ("bike_benefit_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "companies_email_domain_unique" ON "public"."companies" USING "btree" ("lower"("email_domain"));



CREATE UNIQUE INDEX "employee_pii_source_unique" ON "public"."employee_pii" USING "btree" ("company_id", "source", "source_ref_id") WHERE ("source_ref_id" IS NOT NULL);



CREATE UNIQUE INDEX "employee_pii_user_unique" ON "public"."employee_pii" USING "btree" ("user_id") WHERE ("user_id" IS NOT NULL);



CREATE INDEX "idx_bike_benefits_benefit_status" ON "public"."bike_benefits" USING "btree" ("benefit_status");



CREATE INDEX "idx_bike_benefits_bike_id" ON "public"."bike_benefits" USING "btree" ("bike_id");



CREATE INDEX "idx_bike_benefits_contract_status" ON "public"."bike_benefits" USING "btree" ("contract_status");



CREATE INDEX "idx_bike_benefits_user_id" ON "public"."bike_benefits" USING "btree" ("user_id");



CREATE INDEX "idx_bike_models_dealer" ON "public"."bike_models" USING "btree" ("dealer_id");



CREATE INDEX "idx_bike_models_ean" ON "public"."bike_models" USING "btree" ("ean") WHERE ("ean" IS NOT NULL);



CREATE INDEX "idx_bike_models_mpn" ON "public"."bike_models" USING "btree" ("mpn") WHERE ("mpn" IS NOT NULL);



CREATE INDEX "idx_bike_orders_bike_benefit_id" ON "public"."bike_orders" USING "btree" ("bike_benefit_id");



CREATE INDEX "idx_bike_orders_user_id" ON "public"."bike_orders" USING "btree" ("user_id");



CREATE INDEX "idx_bikes_model_id" ON "public"."bikes" USING "btree" ("model_id");



CREATE INDEX "idx_bikes_name" ON "public"."bikes" USING "btree" ("name");



CREATE INDEX "idx_bikes_source" ON "public"."bikes" USING "btree" ("source");



CREATE INDEX "idx_bikes_type" ON "public"."bikes" USING "btree" ("type");



CREATE INDEX "idx_companies_email_domain_sso" ON "public"."companies" USING "btree" ("lower"("email_domain"), "sso_kind") WHERE (("email_domain" IS NOT NULL) AND ("sso_kind" <> 'none'::"text"));



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



CREATE INDEX "idx_sso_pending_claims_company_status" ON "public"."sso_pending_claims" USING "btree" ("company_id", "status") WHERE ("status" = ANY (ARRAY['awaiting_user_info'::"text", 'pending_review'::"text"]));



CREATE INDEX "idx_sync_runs_dealer_status" ON "public"."sync_runs" USING "btree" ("dealer_id", "status", "started_at" DESC);



CREATE INDEX "idx_sync_units_claim" ON "public"."sync_units" USING "btree" ("run_id", "branch", "status", "created_at");



CREATE INDEX "idx_sync_units_claimable" ON "public"."sync_units" USING "btree" ("run_id", "branch", "status", "leased_until", "created_at");



CREATE INDEX "idx_tbi_loan_apps_benefit" ON "public"."tbi_loan_applications" USING "btree" ("bike_benefit_id");



CREATE INDEX "idx_tbi_loan_apps_order" ON "public"."tbi_loan_applications" USING "btree" ("order_id");



CREATE INDEX "idx_tbi_loan_apps_profile" ON "public"."tbi_loan_applications" USING "btree" ("profile_id");



CREATE UNIQUE INDEX "profile_invites_email_unique" ON "public"."profile_invites" USING "btree" ("lower"("email")) WHERE ("email" IS NOT NULL);



CREATE UNIQUE INDEX "profile_invites_source_unique" ON "public"."profile_invites" USING "btree" ("company_id", "source", "source_ref_id") WHERE ("source_ref_id" IS NOT NULL);



CREATE UNIQUE INDEX "profiles_profile_invite_unique" ON "public"."profiles" USING "btree" ("profile_invite_id") WHERE ("profile_invite_id" IS NOT NULL);



CREATE UNIQUE INDEX "sso_pending_claims_user_active" ON "public"."sso_pending_claims" USING "btree" ("user_id") WHERE ("status" = ANY (ARRAY['awaiting_user_info'::"text", 'pending_review'::"text"]));



CREATE UNIQUE INDEX "uq_sync_units_page" ON "public"."sync_units" USING "btree" ("run_id", "branch", "category_id", "page") WHERE ("kind" = 'rest_page'::"text");



CREATE UNIQUE INDEX "user_roles_user_role_idx" ON "public"."user_roles" USING "btree" ("user_id", "role");



CREATE OR REPLACE VIEW "public"."sync_run_summary" WITH ("security_invoker"='on') AS
 SELECT "r"."id",
    "r"."dealer_id",
    "r"."mode",
    "r"."status",
    "r"."started_at",
    "r"."finished_at",
    "r"."watermark_from",
    "r"."watermark_to",
    "r"."n_fetched",
    "r"."n_inserted",
    "r"."n_updated",
    "r"."n_unchanged",
    "r"."n_failed",
    "r"."n_delisted",
    "r"."n_models_upserted",
    "r"."error",
    "count"("u"."id") AS "n_units",
    "count"("u"."id") FILTER (WHERE ("u"."status" = 'succeeded'::"text")) AS "units_succeeded",
    "count"("u"."id") FILTER (WHERE ("u"."status" = 'failed'::"text")) AS "units_failed",
    "count"("u"."id") FILTER (WHERE ("u"."status" = 'skipped'::"text")) AS "units_skipped",
    "count"("u"."id") FILTER (WHERE ("u"."status" = ANY (ARRAY['enqueued'::"text", 'running'::"text"]))) AS "units_pending"
   FROM ("public"."sync_runs" "r"
     LEFT JOIN "public"."sync_units" "u" ON (("u"."run_id" = "r"."id")))
  GROUP BY "r"."id";



CREATE OR REPLACE TRIGGER "co2_refresh_benefit_del" AFTER DELETE ON "public"."bike_benefits" REFERENCING OLD TABLE AS "changed_benefits" FOR EACH STATEMENT EXECUTE FUNCTION "public"."co2_refresh_on_benefit_change"();



CREATE OR REPLACE TRIGGER "co2_refresh_benefit_ins" AFTER INSERT ON "public"."bike_benefits" REFERENCING NEW TABLE AS "changed_benefits" FOR EACH STATEMENT EXECUTE FUNCTION "public"."co2_refresh_on_benefit_change"();



CREATE OR REPLACE TRIGGER "co2_refresh_benefit_upd" AFTER UPDATE ON "public"."bike_benefits" REFERENCING NEW TABLE AS "changed_benefits" FOR EACH STATEMENT EXECUTE FUNCTION "public"."co2_refresh_on_benefit_change"();



CREATE OR REPLACE TRIGGER "metrics_co2_stats_del" AFTER DELETE ON "public"."company_co2_stats" REFERENCING OLD TABLE AS "changed_stats" FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_co2_on_stats_change"();



CREATE OR REPLACE TRIGGER "metrics_co2_stats_ins" AFTER INSERT ON "public"."company_co2_stats" REFERENCING NEW TABLE AS "changed_stats" FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_co2_on_stats_change"();



CREATE OR REPLACE TRIGGER "metrics_co2_stats_upd" AFTER UPDATE ON "public"."company_co2_stats" REFERENCING NEW TABLE AS "changed_stats" FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_co2_on_stats_change"();



CREATE OR REPLACE TRIGGER "metrics_counts_invite_del" AFTER DELETE ON "public"."profile_invites" REFERENCING OLD TABLE AS "changed_invites" FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_counts_on_invite_change"();



CREATE OR REPLACE TRIGGER "metrics_counts_invite_ins" AFTER INSERT ON "public"."profile_invites" REFERENCING NEW TABLE AS "changed_invites" FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_counts_on_invite_change"();



CREATE OR REPLACE TRIGGER "metrics_counts_invite_upd" AFTER UPDATE OF "status", "company_id" ON "public"."profile_invites" FOR EACH ROW EXECUTE FUNCTION "public"."metrics_counts_on_invite_row"();



CREATE OR REPLACE TRIGGER "metrics_seed_company_ins" AFTER INSERT ON "public"."companies" REFERENCING NEW TABLE AS "changed_companies" FOR EACH STATEMENT EXECUTE FUNCTION "public"."metrics_seed_on_company_insert"();



CREATE OR REPLACE TRIGGER "set_contracts_updated_at" BEFORE UPDATE ON "public"."contracts" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_profile_invites_email_domain" BEFORE INSERT OR UPDATE OF "email", "company_id" ON "public"."profile_invites" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_email_matches_company_domain"();



CREATE OR REPLACE TRIGGER "trg_profiles_email_domain" BEFORE INSERT OR UPDATE OF "email", "company_id" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_email_matches_company_domain"();



CREATE OR REPLACE TRIGGER "update_benefit_status_on_change" BEFORE INSERT OR UPDATE ON "public"."bike_benefits" FOR EACH ROW EXECUTE FUNCTION "public"."update_bike_benefit_status"();



CREATE OR REPLACE TRIGGER "update_bike_benefits_updated_at" BEFORE UPDATE ON "public"."bike_benefits" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_bike_models_updated_at" BEFORE UPDATE ON "public"."bike_models" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



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



ALTER TABLE ONLY "public"."bike_models"
    ADD CONSTRAINT "bike_models_dealer_id_fkey" FOREIGN KEY ("dealer_id") REFERENCES "public"."dealers"("id");



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_bike_benefit_id_fkey" FOREIGN KEY ("bike_benefit_id") REFERENCES "public"."bike_benefits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_bike_id_fkey" FOREIGN KEY ("bike_id") REFERENCES "public"."bikes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bike_orders"
    ADD CONSTRAINT "bike_orders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bikes"
    ADD CONSTRAINT "bikes_dealer_id_fkey" FOREIGN KEY ("dealer_id") REFERENCES "public"."dealers"("id");



ALTER TABLE ONLY "public"."bikes"
    ADD CONSTRAINT "bikes_model_id_fkey" FOREIGN KEY ("model_id") REFERENCES "public"."bike_models"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."company_co2_stats"
    ADD CONSTRAINT "company_co2_stats_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_ledger"
    ADD CONSTRAINT "company_ledger_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_metrics"
    ADD CONSTRAINT "company_metrics_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



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
    ADD CONSTRAINT "profiles_profile_invite_id_fkey" FOREIGN KEY ("profile_invite_id") REFERENCES "public"."profile_invites"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sso_pending_claims"
    ADD CONSTRAINT "sso_pending_claims_approved_invite_id_fkey" FOREIGN KEY ("approved_invite_id") REFERENCES "public"."profile_invites"("id");



ALTER TABLE ONLY "public"."sso_pending_claims"
    ADD CONSTRAINT "sso_pending_claims_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sso_pending_claims"
    ADD CONSTRAINT "sso_pending_claims_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("user_id");



ALTER TABLE ONLY "public"."sso_pending_claims"
    ADD CONSTRAINT "sso_pending_claims_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_run_cache"
    ADD CONSTRAINT "sync_run_cache_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."sync_runs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_runs"
    ADD CONSTRAINT "sync_runs_dealer_id_fkey" FOREIGN KEY ("dealer_id") REFERENCES "public"."dealers"("id");



ALTER TABLE ONLY "public"."sync_units"
    ADD CONSTRAINT "sync_units_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."sync_runs"("id") ON DELETE CASCADE;



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



CREATE POLICY "HR can assign roles" ON "public"."user_roles" FOR INSERT TO "authenticated" WITH CHECK (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "user_roles"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id")))))));



CREATE POLICY "HR can delete profile invites" ON "public"."profile_invites" FOR DELETE TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))));



CREATE POLICY "HR can update profile invites" ON "public"."profile_invites" FOR UPDATE TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id")))) WITH CHECK (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))));



CREATE POLICY "HR can view profile invites" ON "public"."profile_invites" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))));



CREATE POLICY "HR view pending PII own company" ON "public"."employee_pii" FOR SELECT TO "authenticated" USING ((("user_id" IS NULL) AND ("public"."get_my_role"() = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



CREATE POLICY "Hr can only add profile invites" ON "public"."profile_invites" FOR INSERT TO "authenticated" WITH CHECK (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))));



CREATE POLICY "Users can read own role" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."bike_benefits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bike_benefits_employee_insert" ON "public"."bike_benefits" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_benefits_employee_select" ON "public"."bike_benefits" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_benefits_employee_update" ON "public"."bike_benefits" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_benefits_hr_select" ON "public"."bike_benefits" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "bike_benefits"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id")))))));



CREATE POLICY "bike_benefits_hr_update" ON "public"."bike_benefits" FOR UPDATE TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "bike_benefits"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))))))) WITH CHECK (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "bike_benefits"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id")))))));



ALTER TABLE "public"."bike_models" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bike_models_authenticated_select" ON "public"."bike_models" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."bike_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bike_orders_employee_insert" ON "public"."bike_orders" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_orders_employee_select" ON "public"."bike_orders" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_orders_employee_update" ON "public"."bike_orders" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bike_orders_hr_select" ON "public"."bike_orders" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "bike_orders"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id")))))));



CREATE POLICY "bike_orders_hr_update" ON "public"."bike_orders" FOR UPDATE TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "bike_orders"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))))))) WITH CHECK (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "bike_orders"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id")))))));



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



ALTER TABLE "public"."company_co2_stats" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "company_co2_stats_hr_select" ON "public"."company_co2_stats" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))));



ALTER TABLE "public"."company_ledger" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "company_ledger_hr_select" ON "public"."company_ledger" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))));



ALTER TABLE "public"."company_metrics" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "company_metrics_hr_select" ON "public"."company_metrics" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id"))));



ALTER TABLE "public"."company_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."contracts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "contracts_employee_select_own" ON "public"."contracts" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "contracts_hr_admin_select" ON "public"."contracts" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_roles" "ur"
  WHERE (("ur"."user_id" = "auth"."uid"()) AND ("ur"."role" = ANY (ARRAY['hr'::"public"."user_role", 'admin'::"public"."user_role"]))))) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "contracts"."user_id") AND ("p"."company_id" = ( SELECT "public"."auth_company_id"() AS "auth_company_id")))))));



ALTER TABLE "public"."dealers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employee_pii" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employee_pii_hr_select" ON "public"."employee_pii" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



CREATE POLICY "employee_pii_self_select" ON "public"."employee_pii" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "hr manages sso_pending_claims in own company" ON "public"."sso_pending_claims" TO "authenticated" USING ((("public"."get_my_role"() = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"()))) WITH CHECK ((("public"."get_my_role"() = ANY (ARRAY['hr'::"text", 'admin'::"text"])) AND ("company_id" = "public"."auth_company_id"())));



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


ALTER TABLE "public"."sso_pending_claims" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_run_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sync_runs_authenticated_select" ON "public"."sync_runs" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."sync_units" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sync_units_authenticated_select" ON "public"."sync_units" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."tbi_loan_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tbi_loan_employee_select" ON "public"."tbi_loan_applications" FOR SELECT TO "authenticated" USING (("profile_id" = "auth"."uid"()));



CREATE POLICY "tbi_loan_hr_select" ON "public"."tbi_loan_applications" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_roles" "ur"
  WHERE (("ur"."user_id" = "auth"."uid"()) AND ("ur"."role" = ANY (ARRAY['hr'::"public"."user_role", 'admin'::"public"."user_role"]))))) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "tbi_loan_applications"."profile_id") AND ("p"."company_id" = "public"."auth_company_id"()))))));



CREATE POLICY "user reads own sso_pending_claim" ON "public"."sso_pending_claims" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_roles_hr_select" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() ->> 'user_role'::"text") = 'hr'::"text") AND ("user_id" IN ( SELECT "p"."user_id"
   FROM "public"."profiles" "p"
  WHERE ("p"."company_id" = "public"."auth_company_id"())))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."bike_benefits";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."company_metrics";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."company_notifications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."profiles";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";











































































































































































GRANT ALL ON FUNCTION "public"."auth_company_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."auth_company_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auth_company_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "anon";
GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "authenticated";
GRANT ALL ON FUNCTION "public"."authorize"("requested_permission" "public"."user_role_permissions") TO "service_role";



GRANT ALL ON FUNCTION "public"."bike_sync_invoke"("p_run_id" "uuid", "p_branch" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."bike_sync_invoke"("p_run_id" "uuid", "p_branch" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bike_sync_invoke"("p_run_id" "uuid", "p_branch" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."bike_sync_kickoff"("p_mode" "text", "p_categories" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."bike_sync_kickoff"("p_mode" "text", "p_categories" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bike_sync_kickoff"("p_mode" "text", "p_categories" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."bike_sync_tick"() TO "anon";
GRANT ALL ON FUNCTION "public"."bike_sync_tick"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bike_sync_tick"() TO "service_role";



GRANT ALL ON FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_employee_prices"("p_full_price" numeric, "p_monthly_subsidy" numeric, "p_contract_months" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_employee_bike_price"("p_full_price" numeric, "p_company_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."sync_units" TO "anon";
GRANT ALL ON TABLE "public"."sync_units" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_units" TO "service_role";



GRANT ALL ON FUNCTION "public"."claim_next_sync_unit"("p_run_id" "uuid", "p_branch" "text", "p_lease_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."claim_next_sync_unit"("p_run_id" "uuid", "p_branch" "text", "p_lease_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_next_sync_unit"("p_run_id" "uuid", "p_branch" "text", "p_lease_seconds" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."co2_refresh_on_benefit_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."co2_refresh_on_benefit_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."co2_refresh_on_benefit_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."co2_refresh_on_benefit_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_sync_unit"("p_unit_id" "uuid", "p_status" "text", "p_n_fetched" integer, "p_n_inserted" integer, "p_n_updated" integer, "p_n_models" integer, "p_n_failed" integer, "p_error" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_sync_unit"("p_unit_id" "uuid", "p_status" "text", "p_n_fetched" integer, "p_n_inserted" integer, "p_n_updated" integer, "p_n_models" integer, "p_n_failed" integer, "p_error" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_sync_unit"("p_unit_id" "uuid", "p_status" "text", "p_n_fetched" integer, "p_n_inserted" integer, "p_n_updated" integer, "p_n_models" integer, "p_n_failed" integer, "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."current_user_has_password"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_user_has_password"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_has_password"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_has_password"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."enforce_email_matches_company_domain"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_email_matches_company_domain"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_email_matches_company_domain"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_page_units"("p_run_id" "uuid", "p_category_id" "text", "p_total" integer, "p_page_size" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_page_units"("p_run_id" "uuid", "p_category_id" "text", "p_total" integer, "p_page_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_page_units"("p_run_id" "uuid", "p_category_id" "text", "p_total" integer, "p_page_size" integer) TO "service_role";



GRANT ALL ON TABLE "public"."sync_runs" TO "anon";
GRANT ALL ON TABLE "public"."sync_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_runs" TO "service_role";



GRANT ALL ON FUNCTION "public"."finalize_sync_run"("p_run_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."finalize_sync_run"("p_run_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."finalize_sync_run"("p_run_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_company_metrics"("p_from" timestamp with time zone, "p_to" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_company_metrics"("p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_company_metrics"("p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_company_metrics"("p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "service_role";



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



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_user_registration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ingest_reges_batch"("p_company_id" "uuid", "p_records" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."lookup_auth_user"("p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lookup_auth_user"("p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_pending_invite"("p_company_id" "uuid", "p_dob_hash" "text", "p_first_norm" "text", "p_last_norm" "text", "p_email_lower" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."merge_bike_offers"("p_dealer_id" "uuid", "p_models" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_bike_offers"("p_dealer_id" "uuid", "p_models" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_bike_offers"("p_dealer_id" "uuid", "p_models" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."metrics_co2_on_stats_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."metrics_co2_on_stats_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."metrics_co2_on_stats_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."metrics_co2_on_stats_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."metrics_counts_on_invite_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."metrics_counts_on_invite_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."metrics_counts_on_invite_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."metrics_counts_on_invite_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."metrics_counts_on_invite_row"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."metrics_counts_on_invite_row"() TO "anon";
GRANT ALL ON FUNCTION "public"."metrics_counts_on_invite_row"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."metrics_counts_on_invite_row"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."metrics_seed_on_company_insert"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."metrics_seed_on_company_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."metrics_seed_on_company_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."metrics_seed_on_company_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."promote_sso_claim"("p_claim_id" "uuid", "p_invite_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."promote_sso_claim"("p_claim_id" "uuid", "p_invite_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."promote_sso_claim"("p_claim_id" "uuid", "p_invite_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_company_co2_stats"("p_period" "date", "p_company_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_company_co2_stats"("p_period" "date", "p_company_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_company_co2_stats"("p_period" "date", "p_company_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_company_co2_stats"("p_period" "date", "p_company_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_company_ledger"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_company_ledger"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_company_ledger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_company_ledger"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_company_metrics_co2"("p_company_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_company_metrics_co2"("p_company_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_company_metrics_co2"("p_company_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_company_metrics_co2"("p_company_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_company_metrics_counts"("p_company_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_company_metrics_counts"("p_company_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_company_metrics_counts"("p_company_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_company_metrics_counts"("p_company_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."seed_audit_units"("p_run_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."seed_audit_units"("p_run_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."seed_audit_units"("p_run_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON TABLE "public"."bikes" TO "anon";
GRANT ALL ON TABLE "public"."bikes" TO "authenticated";
GRANT ALL ON TABLE "public"."bikes" TO "service_role";



GRANT ALL ON FUNCTION "public"."specifications"("b" "public"."bikes") TO "anon";
GRANT ALL ON FUNCTION "public"."specifications"("b" "public"."bikes") TO "authenticated";
GRANT ALL ON FUNCTION "public"."specifications"("b" "public"."bikes") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";
























GRANT ALL ON TABLE "public"."bike_benefits" TO "anon";
GRANT ALL ON TABLE "public"."bike_benefits" TO "authenticated";
GRANT ALL ON TABLE "public"."bike_benefits" TO "service_role";



GRANT ALL ON TABLE "public"."bike_models" TO "anon";
GRANT ALL ON TABLE "public"."bike_models" TO "authenticated";
GRANT ALL ON TABLE "public"."bike_models" TO "service_role";



GRANT ALL ON TABLE "public"."bike_orders" TO "anon";
GRANT ALL ON TABLE "public"."bike_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."bike_orders" TO "service_role";



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



GRANT ALL ON TABLE "public"."company_co2_stats" TO "anon";
GRANT ALL ON TABLE "public"."company_co2_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."company_co2_stats" TO "service_role";



GRANT ALL ON TABLE "public"."company_ledger" TO "anon";
GRANT ALL ON TABLE "public"."company_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."company_ledger" TO "service_role";



GRANT ALL ON TABLE "public"."company_metrics" TO "anon";
GRANT ALL ON TABLE "public"."company_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."company_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."company_metrics_monthly" TO "anon";
GRANT ALL ON TABLE "public"."company_metrics_monthly" TO "authenticated";
GRANT ALL ON TABLE "public"."company_metrics_monthly" TO "service_role";



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



GRANT ALL ON TABLE "public"."sso_pending_claims" TO "anon";
GRANT ALL ON TABLE "public"."sso_pending_claims" TO "authenticated";
GRANT ALL ON TABLE "public"."sso_pending_claims" TO "service_role";



GRANT ALL ON TABLE "public"."sync_run_cache" TO "anon";
GRANT ALL ON TABLE "public"."sync_run_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_run_cache" TO "service_role";



GRANT ALL ON TABLE "public"."sync_run_summary" TO "anon";
GRANT ALL ON TABLE "public"."sync_run_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_run_summary" TO "service_role";



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































