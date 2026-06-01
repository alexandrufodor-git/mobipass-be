SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: bike_orders snapshot + UPSERT semantics
-- Tests the snapshot columns added by 20260430000001 and verifies
-- UPSERT on (bike_benefit_id) refreshes snapshot fields while
-- preserving helmet/insurance flags set between calls.
-- ============================================================

BEGIN;

-- ── Fixtures ─────────────────────────────────────────────────
CREATE TEMP TABLE _fix12 (
  company_id UUID,
  user_id    UUID,
  bike_a_id  UUID,
  bike_b_id  UUID,
  benefit_id UUID
) ON COMMIT DROP;

DO $$
DECLARE
  v_co  UUID;
  v_uid UUID := gen_random_uuid();
  v_dl  UUID;
  v_ba  UUID;
  v_bb  UUID;
  v_bid UUID;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('snapshot-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'snapshot-' || gen_random_uuid()::text || '.test')
  RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          created_at, updated_at,
                          confirmation_token, email_change,
                          email_change_token_new, recovery_token)
  VALUES (v_uid, '00000000-0000-0000-0000-000000000000'::uuid,
          'authenticated', 'authenticated', 'pgtap-00012@test.local', '',
          now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_uid, 'pgtap-00012@test.local', v_co, 'active', 'Test', 'User');

  INSERT INTO public.dealers (name) VALUES ('Test Dealer 00012')
  RETURNING id INTO v_dl;

  INSERT INTO public.bikes (name, brand, sku, full_price, dealer_id)
  VALUES ('Snapshot Bike A', 'BrandA', 'SKU-A-001', 1500.00, v_dl)
  RETURNING id INTO v_ba;

  INSERT INTO public.bikes (name, brand, sku, full_price, dealer_id)
  VALUES ('Snapshot Bike B', 'BrandB', 'SKU-B-002', 1800.00, v_dl)
  RETURNING id INTO v_bid;

  INSERT INTO public.bike_benefits (user_id, bike_id)
  VALUES (v_uid, v_ba)
  RETURNING id INTO v_bb;

  INSERT INTO _fix12 VALUES (v_co, v_uid, v_ba, v_bid, v_bb);
END;
$$;

SELECT plan(9);

-- ── T01: schema — new snapshot columns exist on bike_orders ──
SELECT has_column('public', 'bike_orders', 'bike_id',         'T01a: bike_orders.bike_id exists');
SELECT has_column('public', 'bike_orders', 'bike_sku',        'T01b: bike_orders.bike_sku exists');
SELECT has_column('public', 'bike_orders', 'bike_full_price', 'T01c: bike_orders.bike_full_price exists');
SELECT has_column('public', 'bike_orders', 'frozen_at',       'T01d: bike_orders.frozen_at exists');

-- ── T02: fresh INSERT populates snapshot fields ──────────────
INSERT INTO public.bike_orders (
  user_id, bike_benefit_id,
  bike_id, bike_sku, bike_name, bike_brand, bike_full_price, frozen_at
)
SELECT user_id, benefit_id,
       bike_a_id, 'SKU-A-001', 'Snapshot Bike A', 'BrandA', 1500.00, now()
FROM _fix12;

SELECT is(
  (SELECT bike_sku FROM public.bike_orders WHERE bike_benefit_id = (SELECT benefit_id FROM _fix12)),
  'SKU-A-001',
  'T02: fresh insert sets bike_sku to snapshot value'
);

-- ── T03: HR sets helmet/insurance flags on the row (no snapshot change) ──
UPDATE public.bike_orders
SET helmet = true, insurance = true
WHERE bike_benefit_id = (SELECT benefit_id FROM _fix12);

-- ── T04: re-UPSERT with new snapshot data (simulates re-sent contract
--        targeting a different bike). helmet/insurance must survive. ──
INSERT INTO public.bike_orders (
  user_id, bike_benefit_id,
  bike_id, bike_sku, bike_name, bike_brand, bike_full_price, frozen_at
)
SELECT user_id, benefit_id,
       bike_b_id, 'SKU-B-002', 'Snapshot Bike B', 'BrandB', 1800.00, now() + interval '1 minute'
FROM _fix12
ON CONFLICT (bike_benefit_id) DO UPDATE SET
  user_id         = EXCLUDED.user_id,
  bike_id         = EXCLUDED.bike_id,
  bike_sku        = EXCLUDED.bike_sku,
  bike_name       = EXCLUDED.bike_name,
  bike_brand      = EXCLUDED.bike_brand,
  bike_full_price = EXCLUDED.bike_full_price,
  frozen_at       = EXCLUDED.frozen_at;

SELECT is(
  (SELECT bike_sku FROM public.bike_orders WHERE bike_benefit_id = (SELECT benefit_id FROM _fix12)),
  'SKU-B-002',
  'T04a: re-upsert refreshes bike_sku to new snapshot'
);

SELECT is(
  (SELECT bike_full_price FROM public.bike_orders WHERE bike_benefit_id = (SELECT benefit_id FROM _fix12)),
  1800.00::numeric(10,2),
  'T04b: re-upsert refreshes bike_full_price'
);

-- ── T05: UPSERT must NOT touch helmet/insurance (those columns are
--        intentionally absent from the body that send-contract sends) ──
SELECT is(
  (SELECT (helmet AND insurance) FROM public.bike_orders WHERE bike_benefit_id = (SELECT benefit_id FROM _fix12)),
  true,
  'T05: helmet/insurance flags survive snapshot refresh'
);

-- ── T06: choose_bike reset still wipes the bike_orders row ──
UPDATE public.bike_benefits
SET step = 'choose_bike'
WHERE id = (SELECT benefit_id FROM _fix12);

SELECT is(
  (SELECT count(*)::int FROM public.bike_orders WHERE bike_benefit_id = (SELECT benefit_id FROM _fix12)),
  0,
  'T06: choose_bike reset deletes bike_orders row (existing trigger behaviour preserved)'
);

SELECT * FROM finish();
ROLLBACK;
