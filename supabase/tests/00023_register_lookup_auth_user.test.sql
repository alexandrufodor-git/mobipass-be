SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: public.lookup_auth_user (register stale-orphan detection)
-- Tests:
--  T01: orphan (auth user, no profile) → returns row, has_profile = false
--  T02: onboarded user (auth user + profile) → returns row, has_profile = true
--  T03: unknown email → returns no rows
--  T04: match is case-insensitive on email
--  T05: anon has no EXECUTE (service_role-only, no oracle)
--  T06: authenticated has no EXECUTE
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
CREATE TEMP TABLE _fix23 (
  company_id     uuid,
  orphan_uid     uuid,
  orphan_email   text,
  onboarded_uid  uuid,
  onboarded_email text
) ON COMMIT DROP;

DO $$
DECLARE
  v_co        uuid;
  v_orphan    uuid := gen_random_uuid();
  v_onboarded uuid := gen_random_uuid();
  v_oemail    text := 'pgtap-00023-orphan@test.local';
  v_nemail    text := 'pgtap-00023-onboarded@test.local';
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('lookup-co-' || gen_random_uuid()::text, 50.00, 24, 'EUR', 'test.local')
  RETURNING id INTO v_co;

  -- Orphan: auth user with NO profile. Insert unconfirmed so the registration
  -- trigger's WHEN clause is not satisfied and no profile is created.
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  )
  VALUES (
    v_orphan, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_oemail, '',
    now(), now(), '', '', '', ''
  );

  -- Onboarded: auth user WITH a profile.
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  )
  VALUES (
    v_onboarded, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_nemail, '',
    now(), now(), '', '', '', ''
  );
  INSERT INTO public.profiles (user_id, email, status, company_id, first_name, last_name)
  VALUES (v_onboarded, v_nemail, 'active'::public.user_profile_status, v_co, 'Ona', 'Boarded');

  INSERT INTO _fix23 VALUES (v_co, v_orphan, v_oemail, v_onboarded, v_nemail);
END;
$$;

SELECT plan(6);

-- ── T01: orphan → has_profile = false ─────────────────────────────────────────
SELECT is(
  (SELECT has_profile FROM public.lookup_auth_user((SELECT orphan_email FROM _fix23))),
  false,
  'T01: orphan auth user reported with has_profile = false'
);

-- ── T02: onboarded → has_profile = true ───────────────────────────────────────
SELECT is(
  (SELECT has_profile FROM public.lookup_auth_user((SELECT onboarded_email FROM _fix23))),
  true,
  'T02: onboarded auth user reported with has_profile = true'
);

-- ── T03: unknown email → no rows ──────────────────────────────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.lookup_auth_user('pgtap-00023-nobody@test.local')),
  0,
  'T03: unknown email returns no rows'
);

-- ── T04: case-insensitive email match ─────────────────────────────────────────
SELECT is(
  (SELECT user_id FROM public.lookup_auth_user(upper((SELECT orphan_email FROM _fix23)))),
  (SELECT orphan_uid FROM _fix23),
  'T04: match is case-insensitive on email'
);

-- ── T05: anon cannot execute (no account-existence oracle) ────────────────────
SELECT is(
  has_function_privilege('anon', 'public.lookup_auth_user(text)', 'EXECUTE'),
  false,
  'T05: anon has no EXECUTE on lookup_auth_user'
);

-- ── T06: authenticated cannot execute ─────────────────────────────────────────
SELECT is(
  has_function_privilege('authenticated', 'public.lookup_auth_user(text)', 'EXECUTE'),
  false,
  'T06: authenticated has no EXECUTE on lookup_auth_user'
);

SELECT * FROM finish();
ROLLBACK;
