-- Review fixes for the live-test pushes and company time zones.

-- Only IANA names: Postgres also takes POSIX forms like 'UTC+3' (sign inverted) that Intl rejects.
CREATE OR REPLACE FUNCTION public.is_iana_time_zone(p_zone text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$ SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_zone) $$;

ALTER TABLE public.companies
  DROP CONSTRAINT companies_time_zone_valid,
  ADD CONSTRAINT companies_time_zone_valid CHECK (public.is_iana_time_zone(time_zone));

-- next_day: only after the confirm push went out, and only within 2 days of the test, so the two
-- never go out in the same tick and an old test never gets a "next day" push.
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
                 AND b.live_test_confirm_push_at IS NOT NULL
                 AND (now() AT TIME ZONE c.time_zone)::date > (c.live_test_at AT TIME ZONE c.time_zone)::date
                 AND (now() AT TIME ZONE c.time_zone)::date <= (c.live_test_at AT TIME ZONE c.time_zone)::date + 2
                 AND (now() AT TIME ZONE c.time_zone)::time >= time '08:00')
  ) AS k(kind, due)
  WHERE c.copilot_stop_after_commit
    AND c.live_test_at IS NOT NULL
    AND b.step = 'book_live_test'
    AND b.live_test_sent_at IS NOT NULL
    AND b.live_test_checked_in_at IS NULL
    AND k.due
$$;


-- A moved test day gets its own today / confirm / next_day reminders; the booked push stays sent.
CREATE OR REPLACE FUNCTION public.reset_live_test_reminders() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.bike_benefits b
  SET live_test_today_push_at = NULL, live_test_confirm_push_at = NULL, live_test_next_day_push_at = NULL
  FROM public.profiles p
  WHERE p.user_id = b.user_id AND p.company_id = NEW.id AND b.step = 'book_live_test';
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_live_test_reminders() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER companies_live_test_at_changed
  AFTER UPDATE OF live_test_at ON public.companies
  FOR EACH ROW WHEN (OLD.live_test_at IS DISTINCT FROM NEW.live_test_at)
  EXECUTE FUNCTION public.reset_live_test_reminders();
