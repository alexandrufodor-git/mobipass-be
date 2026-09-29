-- Onboarding step writes move to the onboarding-action edge function.
-- Adds the copilot stop (companies flag + per-benefit stamp) and closes the
-- employee's direct INSERT/UPDATE on bike_benefits. HR policies are untouched.

ALTER TABLE public.companies
  ADD COLUMN copilot_stop_after_commit boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.companies.copilot_stop_after_commit IS
  'Copilot: committing keeps the employee on commit_to_bike instead of moving to sign_contract.';

ALTER TABLE public.bike_benefits
  ADD COLUMN copilot_stopped_at timestamp with time zone;

COMMENT ON COLUMN public.bike_benefits.copilot_stopped_at IS
  'When the employee committed while their company had copilot_stop_after_commit on. Cleared on reset to choose_bike.';

DROP POLICY "bike_benefits_employee_insert" ON public.bike_benefits;
DROP POLICY "bike_benefits_employee_update" ON public.bike_benefits;

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
