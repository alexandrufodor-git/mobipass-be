SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: employees write onboarding steps only via onboarding-action
--
-- Migration 20260929120000 drops the employee INSERT/UPDATE policies on
-- bike_benefits; the edge function writes with service_role. HR keeps its
-- same-company UPDATE policy, and employees can still read their own row.
--
--  T01 employee still sees own bike_benefit
--  T02 employee UPDATE on own bike_benefit affects 0 rows
--  T03 employee INSERT into bike_benefits is rejected
--  T04 HR can still UPDATE a same-company bike_benefit
--  T05 companies.copilot_stop_after_commit defaults to false
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_co  uuid;
  v_dom text := 'wlock-' || gen_random_uuid()::text || '.test';
  v_hr  uuid := gen_random_uuid();
  v_emp uuid := gen_random_uuid();
  v_new uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('wlock-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', v_dom) RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_hr,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr@'  || v_dom, '', now(), now(), '', '', '', ''),
    (v_emp, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp@' || v_dom, '', now(), now(), '', '', '', ''),
    (v_new, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'new@' || v_dom, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_hr,  'hr@'  || v_dom, v_co, 'active', 'HR',       'W'),
    (v_emp, 'emp@' || v_dom, v_co, 'active', 'Employee', 'W'),
    (v_new, 'new@' || v_dom, v_co, 'active', 'New',      'W');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_hr,  'hr'::public.user_role),
    (v_emp, 'employee'::public.user_role),
    (v_new, 'employee'::public.user_role);

  INSERT INTO public.bike_benefits (user_id, step) VALUES (v_emp, 'choose_bike');

  PERFORM set_config('test.co_id',  v_co::text,  false);
  PERFORM set_config('test.hr_id',  v_hr::text,  false);
  PERFORM set_config('test.emp_id', v_emp::text, false);
  PERFORM set_config('test.new_id', v_new::text, false);
END;
$$;

SELECT plan(5);

-- ── As the employee ───────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.bike_benefits WHERE user_id = current_setting('test.emp_id')::uuid),
  'T01: employee still sees own bike_benefit'
);

WITH upd AS (
  UPDATE public.bike_benefits SET step = 'sign_contract'
  WHERE user_id = current_setting('test.emp_id')::uuid RETURNING 1
)
SELECT is((SELECT count(*)::int FROM upd), 0, 'T02: employee cannot UPDATE own bike_benefit directly');

SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.new_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT throws_ok(
  $$ INSERT INTO public.bike_benefits (user_id, step)
     VALUES (current_setting('test.new_id')::uuid, 'choose_bike') $$,
  '42501',
  NULL,
  'T03: employee cannot INSERT a bike_benefit directly'
);

-- ── As HR of the same company ─────────────────────────────────
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

WITH upd AS (
  UPDATE public.bike_benefits SET delivered_at = now()
  WHERE user_id = current_setting('test.emp_id')::uuid RETURNING 1
)
SELECT is((SELECT count(*)::int FROM upd), 1, 'T04: HR can still UPDATE a same-company bike_benefit');

RESET ROLE;

SELECT is(
  (SELECT copilot_stop_after_commit FROM public.companies WHERE id = current_setting('test.co_id')::uuid),
  false,
  'T05: copilot_stop_after_commit defaults to false'
);

SELECT * FROM finish();
ROLLBACK;
