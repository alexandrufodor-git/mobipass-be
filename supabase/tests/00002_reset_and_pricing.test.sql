SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: choose_bike reset + commit_to_bike pricing snapshot
-- Tests that resetting to choose_bike wipes all downstream fields,
-- deletes bike_orders, and that commit_to_bike correctly computes
-- and stores employee_full_price / employee_monthly_price /
-- employee_contract_months.
-- ============================================================

BEGIN;

-- ── Fixtures ─────────────────────────────────────────────────
CREATE TEMP TABLE _fix02 (
  company_id UUID,
  user_id    UUID,
  bike_id    UUID,
  benefit_id UUID
) ON COMMIT DROP;

DO $$
DECLARE
  v_co  UUID;
  v_uid UUID := gen_random_uuid();
  v_dl  UUID;
  v_bk  UUID;
  v_bb  UUID;
BEGIN
  -- Company: subsidy=100, months=12 → employee_full_price = GREATEST(0, 1500-1200) = 300
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('pricing-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'pricing-' || gen_random_uuid()::text || '.test')
  RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          created_at, updated_at,
                          confirmation_token, email_change,
                          email_change_token_new, recovery_token)
  VALUES (v_uid, '00000000-0000-0000-0000-000000000000'::uuid,
          'authenticated', 'authenticated', 'pgtap-00002@test.local', '',
          now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_uid, 'pgtap-00002@test.local', v_co, 'active', 'Test', 'User');

  INSERT INTO public.dealers (name) VALUES ('Test Dealer 00002')
  RETURNING id INTO v_dl;

  INSERT INTO public.bikes (name, full_price, dealer_id)
  VALUES ('pgTAP Bike 00002', 1500.00, v_dl)
  RETURNING id INTO v_bk;

  -- Benefit: advance to pickup_delivery with all timestamps + bike set
  INSERT INTO public.bike_benefits (user_id)
  VALUES (v_uid)
  RETURNING id INTO v_bb;

  -- Walk forward through the workflow, setting all downstream timestamps
  UPDATE public.bike_benefits
  SET step = 'choose_bike',
      bike_id = v_bk
  WHERE id = v_bb;

  UPDATE public.bike_benefits
  SET step = 'book_live_test',
      live_test_whatsapp_sent_at = now()
  WHERE id = v_bb;

  UPDATE public.bike_benefits
  SET step = 'commit_to_bike'
  WHERE id = v_bb;

  UPDATE public.bike_benefits
  SET step       = 'sign_contract',
      committed_at = now()
  WHERE id = v_bb;

  UPDATE public.bike_benefits
  SET step                        = 'pickup_delivery',
      contract_requested_at       = now(),
      contract_viewed_at          = now(),
      contract_employee_signed_at = now(),
      contract_employer_signed_at = now(),
      contract_approved_at        = now(),
      contract_declined_at        = now(),
      delivered_at                = now()
  WHERE id = v_bb;

  -- Create a bike_order for this benefit
  INSERT INTO public.bike_orders (user_id, bike_benefit_id)
  VALUES (v_uid, v_bb);

  -- Create a contract for this benefit
  INSERT INTO public.contracts (bike_benefit_id, user_id, esignatures_contract_id, esignatures_template_id)
  VALUES (v_bb, v_uid, 'test-esig-reset-' || v_bb, 'tpl-reset-test');

  INSERT INTO _fix02 VALUES (v_co, v_uid, v_bk, v_bb);
END;
$$;

SELECT plan(17);

-- ── T-pre: onboarding_status should be true after delivery (set in fixture) ──
SELECT ok(
  (SELECT onboarding_status FROM public.profiles WHERE user_id = (SELECT user_id FROM _fix02)),
  'T-pre: onboarding_status = true after delivered_at was set'
);

-- ── Reset: step → choose_bike ────────────────────────────────
UPDATE public.bike_benefits
SET step = 'choose_bike'
WHERE id = (SELECT benefit_id FROM _fix02);

-- ── Reset checks ─────────────────────────────────────────────

-- T01: live_test_whatsapp_sent_at cleared
SELECT ok(
  (SELECT live_test_whatsapp_sent_at IS NULL FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T01: reset clears live_test_whatsapp_sent_at'
);

-- T02: committed_at cleared
SELECT ok(
  (SELECT committed_at IS NULL FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T02: reset clears committed_at'
);

-- T03: contract_requested_at cleared
SELECT ok(
  (SELECT contract_requested_at IS NULL FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T03: reset clears contract_requested_at'
);

-- T04: contract_viewed_at cleared
SELECT ok(
  (SELECT contract_viewed_at IS NULL FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T04: reset clears contract_viewed_at'
);

-- T05: contract_employee_signed_at cleared
SELECT ok(
  (SELECT contract_employee_signed_at IS NULL FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T05: reset clears contract_employee_signed_at'
);

-- T06: contract_employer_signed_at, contract_approved_at, contract_declined_at all cleared
SELECT ok(
  (SELECT contract_employer_signed_at IS NULL
      AND contract_approved_at        IS NULL
      AND contract_declined_at        IS NULL
   FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T06: reset clears contract_employer_signed_at / approved_at / declined_at'
);

-- T07: delivered_at cleared
SELECT ok(
  (SELECT delivered_at IS NULL FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T07: reset clears delivered_at'
);

-- T08: contract_status set to NULL
SELECT is(
  (SELECT contract_status FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  NULL::public.contract_status,
  'T08: reset sets contract_status to NULL'
);

-- T09: employee_full_price, employee_monthly_price, employee_contract_months all cleared
SELECT ok(
  (SELECT employee_full_price         IS NULL
      AND employee_monthly_price      IS NULL
      AND employee_contract_months    IS NULL
   FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  'T09: reset clears employee_full_price / monthly_price / contract_months'
);

-- T10: related bike_orders deleted
SELECT is(
  (SELECT count(*)::int FROM public.bike_orders
   WHERE bike_benefit_id = (SELECT benefit_id FROM _fix02)),
  0,
  'T10: reset deletes related bike_orders'
);

-- T11: related contracts deleted
SELECT is(
  (SELECT count(*)::int FROM public.contracts
   WHERE bike_benefit_id = (SELECT benefit_id FROM _fix02)),
  0,
  'T11: reset deletes related contracts'
);

-- T-onb: onboarding_status reset to false on choose_bike
SELECT ok(
  NOT (SELECT onboarding_status FROM public.profiles WHERE user_id = (SELECT user_id FROM _fix02)),
  'T-onb: reset to choose_bike sets onboarding_status = false'
);

-- ── Pricing at commit_to_bike ─────────────────────────────────
-- Re-advance to commit_to_bike with bike set; trigger should compute prices.
UPDATE public.bike_benefits
SET step    = 'book_live_test',
    bike_id = (SELECT bike_id FROM _fix02)
WHERE id = (SELECT benefit_id FROM _fix02);

UPDATE public.bike_benefits
SET step = 'commit_to_bike'
WHERE id = (SELECT benefit_id FROM _fix02);

-- T12: employee_full_price = GREATEST(0, 1500 - 100*12) = 300.00
SELECT is(
  (SELECT employee_full_price FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  300.00::numeric(10,2),
  'T12: commit_to_bike computes employee_full_price = 300.00'
);

-- T13: employee_monthly_price = 300 / 12 = 25.00
SELECT is(
  (SELECT employee_monthly_price FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  25.00::numeric(10,2),
  'T13: commit_to_bike computes employee_monthly_price = 25.00'
);

-- T14: employee_contract_months matches company contract_months
SELECT is(
  (SELECT employee_contract_months FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix02)),
  12,
  'T14: commit_to_bike stores employee_contract_months = 12'
);

-- ── Onboarding via delivery ─────────────────────────────────
-- Re-advance to pickup_delivery with delivered_at to confirm onboarding triggers again
UPDATE public.bike_benefits
SET step       = 'sign_contract',
    committed_at = now()
WHERE id = (SELECT benefit_id FROM _fix02);

UPDATE public.bike_benefits
SET step         = 'pickup_delivery',
    delivered_at = now()
WHERE id = (SELECT benefit_id FROM _fix02);

-- T15: onboarding_status = true after second delivery
SELECT ok(
  (SELECT onboarding_status FROM public.profiles WHERE user_id = (SELECT user_id FROM _fix02)),
  'T15: onboarding_status = true after delivered_at set again'
);

SELECT * FROM finish();
ROLLBACK;
