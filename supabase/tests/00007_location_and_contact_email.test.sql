SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: Location columns + contact_email
-- Tests:
--  T01: Employee can read company address + contact_email
--  T02: HR can update company address + contact_email
--  T03: Employee cannot update company fields
--  T04: Dealers have lat/lon (not location_coords)
--  T05: bikes_with_my_pricing exposes dealer_lat and dealer_lon
--  T06: bike_benefits has live_test_lat/lon columns
--  T07: Company has days_in_office with default value 5
--  T08: HR can update days_in_office
--
-- NOTE: T01/T02 from the original version (employee home address on profiles)
-- were removed — home_address/home_lat/home_lon moved to employee_pii table.
-- See 00010_employee_pii.test.sql for those tests.
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co     uuid;
  v_emp    uuid := gen_random_uuid();
  v_hr     uuid := gen_random_uuid();
  v_dealer uuid;
  v_bike   uuid;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('loc-co-' || gen_random_uuid()::text, 72.00, 36, 'RON', 'loc-' || gen_random_uuid()::text || '.test') RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_emp, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp-loc@test.local', '', now(), now(), '', '', '', ''),
    (v_hr,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr-loc@test.local',  '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_emp, 'emp-loc@test.local', v_co, 'active', 'Test', 'Employee'),
    (v_hr,  'hr-loc@test.local',  v_co, 'active', 'Test', 'HR');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_emp, 'employee'::public.user_role),
    (v_hr,  'hr'::public.user_role);

  -- Dealer with lat/lon
  INSERT INTO public.dealers (name, address, lat, lon, phone)
  VALUES ('Test Dealer', 'Str. Test Nr. 1', 46.7712101, 23.5880556, '+40700000000')
  RETURNING id INTO v_dealer;

  -- Bike linked to dealer
  INSERT INTO public.bikes (name, brand, type, full_price, dealer_id)
  VALUES ('Test Bike 500', 'TestBrand', 'e_city_bike', 2500.00, v_dealer)
  RETURNING id INTO v_bike;

  -- Bike benefit with live_test lat/lon
  INSERT INTO public.bike_benefits (user_id, bike_id, live_test_lat, live_test_lon, live_test_location_name)
  VALUES (v_emp, v_bike, 46.7712101, 23.5880556, 'Test Dealer');

  PERFORM set_config('test.emp_id', v_emp::text, false);
  PERFORM set_config('test.hr_id',  v_hr::text,  false);
  PERFORM set_config('test.co_id',  v_co::text,  false);
  PERFORM set_config('test.dealer_id', v_dealer::text, false);
END;
$$;

SELECT plan(8);

-- ── T01: Employee can read company address + contact_email ───────────────────
-- Seed company address as postgres first
UPDATE public.companies
SET address = 'Blvd 21 Dec. 180, Cluj-Napoca',
    address_lat = 46.773,
    address_lon = 23.589,
    contact_email = 'hr@8x8.com'
WHERE id = current_setting('test.co_id')::uuid;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.companies
    WHERE id = current_setting('test.co_id')::uuid
      AND address = 'Blvd 21 Dec. 180, Cluj-Napoca'
      AND address_lat = 46.773
      AND contact_email = 'hr@8x8.com'
  ),
  'T01: employee can read company address and contact_email'
);

RESET ROLE;

-- ── T02: HR can update company address + contact_email ───────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

UPDATE public.companies
SET address = 'Str. Updated Nr. 99',
    address_lat = 46.800,
    address_lon = 23.610,
    contact_email = 'new-hr@8x8.com'
WHERE id = current_setting('test.co_id')::uuid;

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.companies
    WHERE id = current_setting('test.co_id')::uuid
      AND address = 'Str. Updated Nr. 99'
      AND contact_email = 'new-hr@8x8.com'
  ),
  'T02: HR can update company address and contact_email'
);

RESET ROLE;

-- ── T03: Employee cannot update company fields ───────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

UPDATE public.companies
SET contact_email = 'hacked@evil.com'
WHERE id = current_setting('test.co_id')::uuid;

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.companies
    WHERE id = current_setting('test.co_id')::uuid
      AND contact_email = 'new-hr@8x8.com'
  ),
  'T03: employee cannot update company contact_email'
);

RESET ROLE;

-- ── T04: Dealers have lat/lon columns ────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.dealers
    WHERE id = current_setting('test.dealer_id')::uuid
      AND lat = 46.7712101
      AND lon = 23.5880556
  ),
  'T04: dealer has lat/lon double precision columns'
);

-- ── T05: bikes_with_my_pricing exposes dealer_lat and dealer_lon ─────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.bikes_with_my_pricing
    WHERE dealer_lat = 46.7712101
      AND dealer_lon = 23.5880556
  ),
  'T05: bikes_with_my_pricing exposes dealer_lat and dealer_lon'
);

RESET ROLE;

-- ── T06: bike_benefits has live_test_lat/lon ─────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.bike_benefits
    WHERE user_id = current_setting('test.emp_id')::uuid
      AND live_test_lat = 46.7712101
      AND live_test_lon = 23.5880556
  ),
  'T06: bike_benefits has live_test_lat/lon columns'
);

-- ── T07: Company has days_in_office with default 5 ───────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.companies
    WHERE id = current_setting('test.co_id')::uuid
      AND days_in_office = 5
  ),
  'T07: company days_in_office defaults to 5'
);

-- ── T08: HR can update days_in_office ────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

UPDATE public.companies
SET days_in_office = 3
WHERE id = current_setting('test.co_id')::uuid;

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.companies
    WHERE id = current_setting('test.co_id')::uuid
      AND days_in_office = 3
  ),
  'T08: HR can update days_in_office'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
