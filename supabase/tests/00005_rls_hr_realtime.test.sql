SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: RLS — HR broadcast and user_roles access
-- Tests:
--  T01: HR can SELECT user_roles for employees in same company
--  T02: HR cannot SELECT user_roles for employees in a different company
--  T03: Employee cannot SELECT other employees' user_roles
--  T04: realtime.messages policy exists for HR company broadcasts
--  T05: HR can SELECT own profile
--  T06: HR cannot SELECT profiles from a different company
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co_a   uuid;
  v_co_b   uuid;
  v_hr     uuid := gen_random_uuid();
  v_emp    uuid := gen_random_uuid();
  v_out    uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('rls-co-a-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'rls-a-' || gen_random_uuid()::text || '.test') RETURNING id INTO v_co_a;

  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('rls-co-b-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'rls-b-' || gen_random_uuid()::text || '.test') RETURNING id INTO v_co_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_hr,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr-pgtap@test.local',       '', now(), now(), '', '', '', ''),
    (v_emp, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp-pgtap@test.local',      '', now(), now(), '', '', '', ''),
    (v_out, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'outsider-pgtap@test.local', '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_hr,  'hr-pgtap@test.local',      v_co_a, 'active', 'HR',       'User'),
    (v_emp, 'emp-pgtap@test.local',      v_co_a, 'active', 'Employee', 'User'),
    (v_out, 'outsider-pgtap@test.local', v_co_b, 'active', 'Outside',  'User');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_hr,  'hr'::public.user_role),
    (v_emp, 'employee'::public.user_role),
    (v_out, 'employee'::public.user_role);

  -- Store UUIDs in session config so they survive role switches
  -- (temp tables are inaccessible to the authenticated role)
  PERFORM set_config('test.hr_id',      v_hr::text,  false);
  PERFORM set_config('test.emp_id',     v_emp::text, false);
  PERFORM set_config('test.out_id',     v_out::text, false);
  PERFORM set_config('test.co_a_id',    v_co_a::text, false);
END;
$$;

SELECT plan(6);

-- ── T01: HR can SELECT user_roles for same-company employee ──────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.user_roles WHERE user_id = current_setting('test.emp_id')::uuid),
  'T01: HR can SELECT user_roles for same-company employee'
);

-- ── T02: HR cannot SELECT user_roles for employee in different company ────────
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.user_roles WHERE user_id = current_setting('test.out_id')::uuid),
  'T02: HR cannot SELECT user_roles for employee in different company'
);

RESET ROLE;

-- ── T03: Employee cannot SELECT another user's user_roles ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.user_roles WHERE user_id = current_setting('test.hr_id')::uuid),
  'T03: employee cannot SELECT other users'' user_roles'
);

RESET ROLE;

-- ── T04: company_notifications RLS policy exists ──────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'company_notifications'
      AND policyname = 'hr_admin_select_own_company_notifications'
  ),
  'T04: company_notifications policy hr_admin_select_own_company_notifications exists'
);

-- ── T05: HR can SELECT own profile ────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.profiles WHERE user_id = current_setting('test.hr_id')::uuid),
  'T05: HR can SELECT own profile'
);

-- ── T06: HR cannot SELECT profiles from a different company ───────────────────
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.profiles WHERE user_id = current_setting('test.out_id')::uuid),
  'T06: HR cannot SELECT profiles from different company'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
