SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: benefit_status state machine
-- Tests the update_bike_benefit_status() BEFORE trigger.
-- Each step transition is exercised; reset path is covered twice.
-- ============================================================

BEGIN;

-- ── Fixtures ─────────────────────────────────────────────────
CREATE TEMP TABLE _fix00 (
  company_id UUID,
  user_id    UUID,
  bike_id    UUID,
  benefit_id UUID,
  benefit2_id UUID
) ON COMMIT DROP;

DO $$
DECLARE
  v_co  UUID;
  v_uid UUID := gen_random_uuid();
  v_dl  UUID;
  v_bk  UUID;
  v_bb  UUID;
  v_bb2 UUID;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('benefit-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'benefit-' || gen_random_uuid()::text || '.test')
  RETURNING id INTO v_co;

  -- Insert minimal auth.users row to satisfy profiles FK
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          created_at, updated_at,
                          confirmation_token, email_change,
                          email_change_token_new, recovery_token)
  VALUES (v_uid, '00000000-0000-0000-0000-000000000000'::uuid,
          'authenticated', 'authenticated', 'pgtap-00000@test.local', '',
          now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_uid, 'pgtap-00000@test.local', v_co, 'active', 'Test', 'User');

  INSERT INTO public.dealers (name) VALUES ('Test Dealer 00000')
  RETURNING id INTO v_dl;

  INSERT INTO public.bikes (name, full_price, dealer_id)
  VALUES ('pgTAP Bike 00000', 1500.00, v_dl)
  RETURNING id INTO v_bk;

  -- Primary benefit (step=NULL → inactive)
  INSERT INTO public.bike_benefits (user_id)
  VALUES (v_uid)
  RETURNING id INTO v_bb;

  -- Second benefit inserted directly at pickup_delivery (tests INSERT + no OLD)
  INSERT INTO public.bike_benefits (user_id, step)
  VALUES (v_uid, 'pickup_delivery')
  RETURNING id INTO v_bb2;

  INSERT INTO _fix00 VALUES (v_co, v_uid, v_bk, v_bb, v_bb2);
END;
$$;

SELECT plan(16);

-- ── T01: INSERT with step=NULL → inactive ────────────────────
SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'inactive',
  'T01: INSERT with step=NULL → benefit_status=inactive'
);

-- ── T02: INSERT snaps employee_currency from company ─────────
SELECT is(
  (SELECT employee_currency::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'EUR',
  'T02: INSERT snaps employee_currency from company'
);

-- ── T03: INSERT snaps employee_contract_months from company ──
SELECT is(
  (SELECT employee_contract_months FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  12,
  'T03: INSERT snaps employee_contract_months from company'
);

-- ── T04: step=choose_bike → searching ────────────────────────
UPDATE public.bike_benefits
SET step = 'choose_bike'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'searching',
  'T04: step=choose_bike → searching'
);

-- ── T05: step=book_live_test → searching ─────────────────────
UPDATE public.bike_benefits
SET step = 'book_live_test'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'searching',
  'T05: step=book_live_test → searching'
);

-- ── T06: set live_test_whatsapp_sent_at while on book_live_test → still searching
UPDATE public.bike_benefits
SET live_test_whatsapp_sent_at = now()
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'searching',
  'T06: book_live_test + whatsapp set → still searching'
);

-- ── T07: step=commit_to_bike (whatsapp already set) → testing ─
UPDATE public.bike_benefits
SET step = 'commit_to_bike'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'testing',
  'T07: step=commit_to_bike with whatsapp → testing'
);

-- ── T08: set committed_at while on commit_to_bike → stays testing
UPDATE public.bike_benefits
SET committed_at = now()
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'testing',
  'T08: setting committed_at on commit_to_bike does not change testing status'
);

-- ── T09: step=sign_contract (committed_at set) → active ──────
UPDATE public.bike_benefits
SET step = 'sign_contract'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'active',
  'T09: step=sign_contract with committed_at → active'
);

-- ── T10: step=pickup_delivery keeps OLD benefit_status (active) ─
UPDATE public.bike_benefits
SET step = 'pickup_delivery'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'active',
  'T10: step=pickup_delivery inherits OLD benefit_status (active)'
);

-- ── T11: reset to choose_bike → searching ────────────────────
UPDATE public.bike_benefits
SET step = 'choose_bike'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'searching',
  'T11: reset to choose_bike → searching'
);

-- ── T12: second pass — book_live_test (no whatsapp after reset) → searching
UPDATE public.bike_benefits
SET step = 'book_live_test'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'searching',
  'T12: second pass — book_live_test → searching'
);

-- ── T13: second pass — commit_to_bike (no whatsapp, reset cleared it) → searching
UPDATE public.bike_benefits
SET step = 'commit_to_bike'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'searching',
  'T13: second pass — commit_to_bike without whatsapp → searching'
);

-- ── T14: second pass — set whatsapp while on commit_to_bike → testing
UPDATE public.bike_benefits
SET live_test_whatsapp_sent_at = now()
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'testing',
  'T14: second pass — commit_to_bike + whatsapp → testing'
);

-- ── T15: sign_contract WITHOUT committed_at → keeps OLD benefit_status
-- (committed_at was cleared by the reset; no new committed_at set in second pass)
UPDATE public.bike_benefits
SET step = 'sign_contract'
WHERE id = (SELECT benefit_id FROM _fix00);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix00)),
  'testing',
  'T15: sign_contract without committed_at → keeps OLD benefit_status (testing)'
);

-- ── T16: INSERT with step=pickup_delivery and no OLD → defaults to active ─
SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit2_id FROM _fix00)),
  'active',
  'T16: INSERT with step=pickup_delivery and no OLD → defaults to active'
);

SELECT * FROM finish();
ROLLBACK;
