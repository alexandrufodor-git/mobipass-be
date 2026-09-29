SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: copilot live-test reminders — public.live_test_due_pushes()
--
--  T01 confirm due once live_test_at + reminder offset has passed
--  T02 confirm not due before the offset
--  T03 nothing due once the test is confirmed
--  T04 confirm not due again once its push stamp is set
--  T05 today due when the test is later today (Bucharest) and it's past 08:00
--  T06 nothing due when the company has the copilot off
--  T07 reset to choose_bike clears the push stamps
--  T08 authenticated can't read the due list or fire the tick
--  T09 live-test-tick is scheduled every 5 minutes
-- ============================================================

BEGIN;
SELECT plan(9);

DO $$
DECLARE
  v_co  uuid;
  v_dom text := 'ltp-' || gen_random_uuid()::text || '.test';
  v_emp uuid := gen_random_uuid();
  v_ben uuid;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain,
                                copilot_stop_after_commit, live_test_at, live_test_reminder_offset_min)
  VALUES ('ltp-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', v_dom, true, now() - interval '20 minutes', 15)
  RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES (v_emp, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp@' || v_dom, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_emp, 'emp@' || v_dom, v_co, 'active', 'Employee', 'L');

  INSERT INTO public.bike_benefits (user_id, step, live_test_sent_at)
  VALUES (v_emp, 'book_live_test', now() - interval '1 day') RETURNING id INTO v_ben;

  PERFORM set_config('test.co_id',  v_co::text,  false);
  PERFORM set_config('test.ben_id', v_ben::text, false);
END;
$$;

CREATE TEMP VIEW due AS
  SELECT kind FROM public.live_test_due_pushes() WHERE benefit_id = current_setting('test.ben_id')::uuid;

-- T01: test 20 min ago, offset 15
SELECT is((SELECT count(*)::int FROM due WHERE kind = 'confirm'), 1, 'T01: confirm due after test + offset');

-- T02: test 10 min ago, offset 15
UPDATE public.companies SET live_test_at = now() - interval '10 minutes' WHERE id = current_setting('test.co_id')::uuid;
SELECT is((SELECT count(*)::int FROM due WHERE kind = 'confirm'), 0, 'T02: confirm not due before offset');

-- T03: confirmed test
UPDATE public.companies SET live_test_at = now() - interval '20 minutes' WHERE id = current_setting('test.co_id')::uuid;
UPDATE public.bike_benefits SET live_test_checked_in_at = now() WHERE id = current_setting('test.ben_id')::uuid;
SELECT is((SELECT count(*)::int FROM due), 0, 'T03: nothing due once confirmed');
UPDATE public.bike_benefits SET live_test_checked_in_at = NULL WHERE id = current_setting('test.ben_id')::uuid;

-- T04: already sent
UPDATE public.bike_benefits SET live_test_confirm_push_at = now() WHERE id = current_setting('test.ben_id')::uuid;
SELECT is((SELECT count(*)::int FROM due WHERE kind = 'confirm'), 0, 'T04: confirm not sent twice');

-- T05: test in 1 minute. Due only if it's past 08:00 Bucharest and still the same local day.
UPDATE public.companies SET live_test_at = now() + interval '1 minute' WHERE id = current_setting('test.co_id')::uuid;
SELECT is(
  (SELECT count(*)::int FROM due WHERE kind = 'today'),
  CASE WHEN (now() AT TIME ZONE 'Europe/Bucharest')::time >= time '08:00'
        AND ((now() + interval '1 minute') AT TIME ZONE 'Europe/Bucharest')::date = (now() AT TIME ZONE 'Europe/Bucharest')::date
       THEN 1 ELSE 0 END,
  'T05: today due after 08:00 on the test day'
);

-- T06: copilot off
UPDATE public.companies SET copilot_stop_after_commit = false, live_test_at = now() - interval '1 hour'
WHERE id = current_setting('test.co_id')::uuid;
UPDATE public.bike_benefits SET live_test_confirm_push_at = NULL WHERE id = current_setting('test.ben_id')::uuid;
SELECT is((SELECT count(*)::int FROM due), 0, 'T06: nothing due with copilot off');

-- T07: reset clears the stamps
UPDATE public.bike_benefits
SET live_test_booked_push_at = now(), live_test_today_push_at = now(), live_test_confirm_push_at = now()
WHERE id = current_setting('test.ben_id')::uuid;
UPDATE public.bike_benefits SET step = 'choose_bike' WHERE id = current_setting('test.ben_id')::uuid;
SELECT ok(
  (SELECT live_test_booked_push_at IS NULL AND live_test_today_push_at IS NULL AND live_test_confirm_push_at IS NULL
   FROM public.bike_benefits WHERE id = current_setting('test.ben_id')::uuid),
  'T07: reset clears push stamps'
);

SELECT ok(
  NOT has_function_privilege('authenticated', 'public.live_test_due_pushes()', 'execute')
  AND NOT has_function_privilege('authenticated', 'public.live_test_tick()', 'execute'),
  'T08: authenticated cannot read due pushes or fire the tick'
);

SELECT is((SELECT schedule FROM cron.job WHERE jobname = 'live-test-tick'), '*/5 * * * *', 'T09: tick every 5 minutes');

SELECT * FROM finish();
ROLLBACK;
