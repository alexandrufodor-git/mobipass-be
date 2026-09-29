-- Copilot test day: one test date per company, and the copilot state the app
-- renders from. Lock and unlock rules live here so the app only displays them.

ALTER TABLE public.companies
  ADD COLUMN live_test_at timestamp with time zone,
  ADD COLUMN live_test_confirm_offset_min integer NOT NULL DEFAULT 15;

COMMENT ON COLUMN public.companies.live_test_at IS
  'Copilot: the company''s single test-ride date and hour. Set directly in the DB for now.';
COMMENT ON COLUMN public.companies.live_test_confirm_offset_min IS
  'Copilot: minutes after live_test_at before the employee can confirm the test.';

-- PostgREST computed column: select=*,copilot on bike_benefits.
CREATE OR REPLACE FUNCTION public.copilot(public.bike_benefits) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  SELECT jsonb_build_object(
    'enabled',          c.copilot_stop_after_commit,
    'live_test_at',     c.live_test_at,
    'live_test_label',  to_char(c.live_test_at AT TIME ZONE 'Europe/Bucharest', 'Dy, FMDD Mon · HH24:MI'),
    'test_confirmable', c.live_test_at IS NOT NULL
                        AND now() >= c.live_test_at + make_interval(mins => c.live_test_confirm_offset_min),
    'locked',           c.copilot_stop_after_commit
                        AND ($1.live_test_sent_at IS NOT NULL
                             OR $1.step IN ('commit_to_bike', 'sign_contract', 'pickup_delivery'))
  )
  FROM public.profiles p
  JOIN public.companies c ON c.id = p.company_id
  WHERE p.user_id = $1.user_id
$$;

COMMENT ON FUNCTION public.copilot(public.bike_benefits) IS
  'Copilot state for a benefit: enabled, test date + label (Europe/Bucharest), whether the test can be confirmed yet, and whether the bike choice is locked.';

GRANT EXECUTE ON FUNCTION public.copilot(public.bike_benefits) TO authenticated, service_role;
