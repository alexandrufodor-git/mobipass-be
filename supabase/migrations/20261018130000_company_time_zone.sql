-- Each company's IANA time zone: dates in pushes, the step 2 label and the 08:00 reminder rules
-- use it, so a company in another country needs only its row set. Existing companies are Romanian.

ALTER TABLE public.companies
  ADD COLUMN time_zone text NOT NULL DEFAULT 'Europe/Bucharest'
  -- AT TIME ZONE raises on an unknown name, so a bad value can't be saved.
  CONSTRAINT companies_time_zone_valid CHECK (('2000-01-01 00:00:00+00'::timestamptz AT TIME ZONE time_zone) IS NOT NULL);

COMMENT ON COLUMN public.companies.time_zone IS
  'IANA time zone of the company, e.g. Europe/Bucharest. Used for push dates, the copilot test label and reminder times.';

CREATE OR REPLACE FUNCTION "public"."copilot"("public"."bike_benefits") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $_$
  SELECT jsonb_build_object(
    'enabled',          c.copilot_stop_after_commit,
    'live_test_at',     c.live_test_at,
    'live_test_label',  to_char(c.live_test_at AT TIME ZONE c.time_zone, 'Dy, FMDD Mon · HH24:MI'),
    'time_zone',        c.time_zone,
    'test_confirmable', c.live_test_at IS NOT NULL
                        AND now() >= c.live_test_at + make_interval(mins => c.live_test_confirm_offset_min),
    'locked',           c.copilot_stop_after_commit
                        AND ($1.live_test_sent_at IS NOT NULL
                             OR $1.step IN ('commit_to_bike', 'sign_contract', 'pickup_delivery'))
  )
  FROM public.profiles p
  JOIN public.companies c ON c.id = p.company_id
  WHERE p.user_id = $1.user_id
$_$;

COMMENT ON FUNCTION public.copilot(public.bike_benefits) IS
  'Copilot state for a benefit: enabled, test date + label and time_zone (the company''s), whether the test can be confirmed yet, and whether the bike choice is locked.';

CREATE OR REPLACE FUNCTION "public"."live_test_due_pushes"() RETURNS TABLE("benefit_id" "uuid", "user_id" "uuid", "kind" "text", "live_test_time" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT b.id, b.user_id, k.kind, to_char(c.live_test_at AT TIME ZONE c.time_zone, 'HH24:MI')
  FROM public.bike_benefits b
  JOIN public.profiles p  ON p.user_id = b.user_id
  JOIN public.companies c ON c.id = p.company_id
  CROSS JOIN LATERAL (VALUES
    ('today',    b.live_test_today_push_at IS NULL
                 AND (c.live_test_at AT TIME ZONE c.time_zone)::date = (now() AT TIME ZONE c.time_zone)::date
                 AND (now() AT TIME ZONE c.time_zone)::time >= time '08:00'
                 AND now() < c.live_test_at),
    ('confirm',  b.live_test_confirm_push_at IS NULL
                 AND now() >= c.live_test_at + make_interval(mins => c.live_test_reminder_offset_min)),
    ('next_day', b.live_test_next_day_push_at IS NULL
                 AND (now() AT TIME ZONE c.time_zone)::date > (c.live_test_at AT TIME ZONE c.time_zone)::date
                 AND (now() AT TIME ZONE c.time_zone)::time >= time '08:00')
  ) AS k(kind, due)
  WHERE c.copilot_stop_after_commit
    AND c.live_test_at IS NOT NULL
    AND b.step = 'book_live_test'
    AND b.live_test_sent_at IS NOT NULL
    AND b.live_test_checked_in_at IS NULL
    AND k.due
$$;

COMMENT ON FUNCTION public.live_test_due_pushes() IS
  'Copilot reminders due now, in the company''s time_zone: today (08:00 on the test day, before the test), confirm (live_test_at + live_test_reminder_offset_min) or next_day (08:00 after the test day), all only while the test is not confirmed. Read by live_test_tick() and the live-test-push edge function.';
