-- Copilot: 4th reminder, the day after the test at 08:00 Bucharest, while the test is still not
-- confirmed. Same live-test-tick cron; reset to choose_bike clears its stamp like the others.

ALTER TABLE public.bike_benefits
  ADD COLUMN live_test_next_day_push_at timestamp with time zone;

COMMENT ON COLUMN public.bike_benefits.live_test_next_day_push_at IS
  'Copilot: when the "still not confirmed" next-day push was sent.';

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
      NEW.live_test_next_day_push_at  := NULL;
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
    IF NEW.live_test_sent_at IS NOT NULL THEN
      NEW.benefit_status := 'testing'::public.benefit_status;
    ELSE
      NEW.benefit_status := 'searching'::public.benefit_status;
    END IF;

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

    IF NEW.committed_at IS NOT NULL THEN
      NEW.benefit_status := 'active'::public.benefit_status;
    ELSIF NEW.live_test_sent_at IS NOT NULL THEN
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
    ('today',    b.live_test_today_push_at IS NULL
                 AND (c.live_test_at AT TIME ZONE 'Europe/Bucharest')::date = (now() AT TIME ZONE 'Europe/Bucharest')::date
                 AND (now() AT TIME ZONE 'Europe/Bucharest')::time >= time '08:00'
                 AND now() < c.live_test_at),
    ('confirm',  b.live_test_confirm_push_at IS NULL
                 AND now() >= c.live_test_at + make_interval(mins => c.live_test_reminder_offset_min)),
    ('next_day', b.live_test_next_day_push_at IS NULL
                 AND (now() AT TIME ZONE 'Europe/Bucharest')::date > (c.live_test_at AT TIME ZONE 'Europe/Bucharest')::date
                 AND (now() AT TIME ZONE 'Europe/Bucharest')::time >= time '08:00')
  ) AS k(kind, due)
  WHERE c.copilot_stop_after_commit
    AND c.live_test_at IS NOT NULL
    AND b.step = 'book_live_test'
    AND b.live_test_sent_at IS NOT NULL
    AND b.live_test_checked_in_at IS NULL
    AND k.due
$$;

COMMENT ON FUNCTION public.live_test_due_pushes() IS
  'Copilot reminders due now: today (08:00 Bucharest on the test day, before the test), confirm (live_test_at + live_test_reminder_offset_min) or next_day (08:00 Bucharest after the test day), all only while the test is not confirmed. Read by live_test_tick() and the live-test-push edge function.';
