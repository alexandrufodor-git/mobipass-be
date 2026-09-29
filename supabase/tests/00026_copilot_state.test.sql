SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: public.copilot(bike_benefits) computed column
--
--  T01 copilot off → enabled false, never locked
--  T02 copilot on, step 1 → not locked
--  T03 copilot on, interest tapped → locked
--  T04 copilot on, step commit_to_bike without interest → locked
--  T05 label is Europe/Bucharest time, "Dy, D Mon · HH:MI"
--  T06 test not confirmable before live_test_at + offset
--  T07 test confirmable after live_test_at + offset
--  T08 no test date → not confirmable, label null
--  T09 employee can read the column on own benefit (RLS)
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_co  uuid;
  v_dom text := 'copst-' || gen_random_uuid()::text || '.test';
  v_emp uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('copst-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', v_dom) RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES (v_emp, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp@' || v_dom, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_emp, 'emp@' || v_dom, v_co, 'active', 'Employee', 'C');

  INSERT INTO public.user_roles (user_id, role) VALUES (v_emp, 'employee'::public.user_role);

  INSERT INTO public.bike_benefits (user_id, step) VALUES (v_emp, 'choose_bike');

  PERFORM set_config('test.co_id',  v_co::text,  false);
  PERFORM set_config('test.emp_id', v_emp::text, false);
END;
$$;

CREATE TEMP VIEW _cp AS
  SELECT public.copilot(b) AS c FROM public.bike_benefits b
  WHERE b.user_id = current_setting('test.emp_id')::uuid;

SELECT plan(9);

SELECT is((SELECT (c->>'enabled')::boolean AND NOT (c->>'locked')::boolean FROM _cp), false,
  'T01: copilot off → enabled false');

UPDATE public.companies SET copilot_stop_after_commit = true WHERE id = current_setting('test.co_id')::uuid;

SELECT is((SELECT (c->>'locked')::boolean FROM _cp), false, 'T02: copilot on, step 1 → not locked');

UPDATE public.bike_benefits SET step = 'book_live_test', live_test_sent_at = now()
WHERE user_id = current_setting('test.emp_id')::uuid;
SELECT is((SELECT (c->>'locked')::boolean FROM _cp), true, 'T03: interest tapped → locked');

UPDATE public.bike_benefits SET step = 'choose_bike' WHERE user_id = current_setting('test.emp_id')::uuid;
UPDATE public.bike_benefits SET step = 'commit_to_bike' WHERE user_id = current_setting('test.emp_id')::uuid;
SELECT is((SELECT (c->>'locked')::boolean FROM _cp), true, 'T04: commit_to_bike without interest → locked');

-- 07:00 UTC in October is 10:00 in Bucharest (EEST, UTC+3).
UPDATE public.companies SET live_test_at = '2026-10-08 07:00:00+00' WHERE id = current_setting('test.co_id')::uuid;
SELECT is((SELECT c->>'live_test_label' FROM _cp), 'Thu, 8 Oct · 10:00', 'T05: label in Bucharest time');

UPDATE public.companies SET live_test_at = now() - interval '10 minutes', live_test_confirm_offset_min = 15
WHERE id = current_setting('test.co_id')::uuid;
SELECT is((SELECT (c->>'test_confirmable')::boolean FROM _cp), false, 'T06: 10 min after start, offset 15 → not confirmable');

UPDATE public.companies SET live_test_at = now() - interval '20 minutes' WHERE id = current_setting('test.co_id')::uuid;
SELECT is((SELECT (c->>'test_confirmable')::boolean FROM _cp), true, 'T07: 20 min after start, offset 15 → confirmable');

UPDATE public.companies SET live_test_at = NULL WHERE id = current_setting('test.co_id')::uuid;
SELECT is((SELECT (c->>'test_confirmable')::boolean AND c->>'live_test_label' IS NULL FROM _cp), false,
  'T08: no test date → not confirmable');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);
SELECT is(
  (SELECT (public.copilot(b)->>'enabled')::boolean FROM public.bike_benefits b WHERE b.user_id = current_setting('test.emp_id')::uuid),
  true,
  'T09: employee reads copilot on own benefit'
);

SELECT * FROM finish();
ROLLBACK;
