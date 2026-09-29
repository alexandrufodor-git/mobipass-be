-- Copilot live-test pushes: "test booked" (sent by onboarding-action on the interest tap),
-- "test is today" (08:00 Bucharest on the test day) and "confirm your test" (live_test_at +
-- live_test_reminder_offset_min). The two reminders come from live_test_tick() every 5 minutes,
-- which only calls the live-test-push edge function when someone is due. Each push has a
-- *_push_at stamp so nobody gets it twice; reset to choose_bike clears them.

ALTER TABLE public.companies
  ADD COLUMN live_test_reminder_offset_min integer NOT NULL DEFAULT 15;

COMMENT ON COLUMN public.companies.live_test_reminder_offset_min IS
  'Copilot: minutes after live_test_at before the "confirm your test" push.';

ALTER TABLE public.bike_benefits
  ADD COLUMN live_test_booked_push_at  timestamp with time zone,
  ADD COLUMN live_test_today_push_at   timestamp with time zone,
  ADD COLUMN live_test_confirm_push_at timestamp with time zone;

COMMENT ON COLUMN public.bike_benefits.live_test_booked_push_at IS 'Copilot: when the "test booked" push was sent.';
COMMENT ON COLUMN public.bike_benefits.live_test_today_push_at IS 'Copilot: when the "test is today" push was sent.';
COMMENT ON COLUMN public.bike_benefits.live_test_confirm_push_at IS 'Copilot: when the "confirm your test" push was sent.';

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
      NEW.live_test_sent_at           := NULL;
      NEW.live_test_checked_in_at     := NULL;
      NEW.committed_at                := NULL;
      NEW.contract_requested_at       := NULL;
      NEW.contract_viewed_at          := NULL;
      NEW.contract_employee_signed_at := NULL;
      NEW.contract_employer_signed_at := NULL;
      NEW.contract_approved_at        := NULL;
      NEW.contract_declined_at        := NULL;
      NEW.delivered_at                := NULL;
      NEW.copilot_stopped_at          := NULL;
      NEW.live_test_booked_push_at    := NULL;
      NEW.live_test_today_push_at     := NULL;
      NEW.live_test_confirm_push_at   := NULL;
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

    IF NEW.live_test_sent_at IS NOT NULL THEN
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

-- Who is due a reminder right now. Only copilot users waiting on step 2 with interest sent and
-- the test not yet confirmed; leaving that state (reset, commit, confirm) cancels by itself.
CREATE OR REPLACE FUNCTION public.live_test_due_pushes()
RETURNS TABLE (benefit_id uuid, user_id uuid, kind text, live_test_time text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT b.id, b.user_id, k.kind, to_char(c.live_test_at AT TIME ZONE 'Europe/Bucharest', 'HH24:MI')
  FROM public.bike_benefits b
  JOIN public.profiles p  ON p.user_id = b.user_id
  JOIN public.companies c ON c.id = p.company_id
  CROSS JOIN LATERAL (VALUES
    ('today',   b.live_test_today_push_at IS NULL
                AND (c.live_test_at AT TIME ZONE 'Europe/Bucharest')::date = (now() AT TIME ZONE 'Europe/Bucharest')::date
                AND (now() AT TIME ZONE 'Europe/Bucharest')::time >= time '08:00'
                AND now() < c.live_test_at),
    ('confirm', b.live_test_confirm_push_at IS NULL
                AND now() >= c.live_test_at + make_interval(mins => c.live_test_reminder_offset_min))
  ) AS k(kind, due)
  WHERE c.copilot_stop_after_commit
    AND c.live_test_at IS NOT NULL
    AND b.step = 'book_live_test'
    AND b.live_test_sent_at IS NOT NULL
    AND b.live_test_checked_in_at IS NULL
    AND k.due
$$;

ALTER FUNCTION public.live_test_due_pushes() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.live_test_due_pushes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_test_due_pushes() TO service_role;

COMMENT ON FUNCTION public.live_test_due_pushes() IS
  'Copilot reminders due now: kind today (08:00 Bucharest on the test day, before the test) or confirm (live_test_at + live_test_reminder_offset_min, test not confirmed). Read by live_test_tick() and the live-test-push edge function.';

-- Cheap no-op unless someone is due; then one fire-and-forget call to live-test-push.
-- Same Vault secrets as bike_sync_invoke(): the webhook secret and the base URL.
CREATE OR REPLACE FUNCTION public.live_test_tick() RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net', 'vault'
    AS $$
DECLARE
  v_secret text;
  v_base   text;
  v_req    bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.live_test_due_pushes()) THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'bike_sync_webhook_secret' LIMIT 1;
  IF v_secret IS NULL THEN
    RAISE WARNING '[live_test_tick] Vault secret "bike_sync_webhook_secret" not found — push skipped';
    RETURN NULL;
  END IF;
  SELECT decrypted_secret INTO v_base FROM vault.decrypted_secrets WHERE name = 'bike_sync_base_url' LIMIT 1;
  v_base := COALESCE(v_base, 'https://xlfkdumbsflqxpezolhl.supabase.co');

  SELECT net.http_post(
    url     := v_base || '/functions/v1/live-test-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) INTO v_req;
  RETURN v_req;
END;
$$;

ALTER FUNCTION public.live_test_tick() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.live_test_tick() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.live_test_tick() IS
  'pg_cron live-test-tick (every 5 min): calls the live-test-push edge function only when live_test_due_pushes() has rows.';

SELECT cron.schedule(
  'live-test-tick',
  '*/5 * * * *',
  $cron$ SELECT public.live_test_tick(); $cron$
);

-- To pause:
--   SELECT cron.unschedule('live-test-tick');
