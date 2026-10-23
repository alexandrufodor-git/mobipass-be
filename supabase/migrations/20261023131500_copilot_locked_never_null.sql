-- 'locked' was NULL for a benefit with no step yet (just registered): NULL IN (...) is NULL, and
-- the app's non-null Boolean failed to decode the whole benefit. Always true or false now.

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
                             OR COALESCE($1.step IN ('commit_to_bike', 'sign_contract', 'pickup_delivery'), false))
  )
  FROM public.profiles p
  JOIN public.companies c ON c.id = p.company_id
  WHERE p.user_id = $1.user_id
$_$;
