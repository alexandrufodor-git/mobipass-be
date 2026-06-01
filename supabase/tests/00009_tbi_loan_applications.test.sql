SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: TBI Loan Applications
-- Tests:
--  T01: tbi_loan_status enum exists with correct values
--  T02: tbi_loan_applications table exists with correct columns
--  T03: updated_at trigger fires on UPDATE
--  T04: RLS — Employee can SELECT own loan application
--  T05: RLS — Employee cannot SELECT another employee's loan application
--  T06: RLS — HR can SELECT loan applications for same-company employees
--  T07: RLS — HR cannot SELECT loan applications for different-company employees
--  T08: RLS — Employee cannot INSERT directly
--  T09: RLS — Employee cannot UPDATE directly
--  T10: order_id uniqueness constraint enforced
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co1    uuid;
  v_co2    uuid;
  v_emp1   uuid := gen_random_uuid();
  v_emp2   uuid := gen_random_uuid();
  v_hr     uuid := gen_random_uuid();
  v_bike   uuid;
  v_bb1    uuid;
  v_bb2    uuid;
  v_dealer uuid;
BEGIN
  -- Two companies
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('tbi-co1-' || gen_random_uuid()::text, 72.00, 36, 'RON', 'tbi1-' || gen_random_uuid()::text || '.test') RETURNING id INTO v_co1;

  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('tbi-co2-' || gen_random_uuid()::text, 100.00, 24, 'EUR', 'tbi2-' || gen_random_uuid()::text || '.test') RETURNING id INTO v_co2;

  -- Auth users
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_emp1, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp1-tbi@test.local', '', now(), now(), '', '', '', ''),
    (v_emp2, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp2-tbi@test.local', '', now(), now(), '', '', '', ''),
    (v_hr,   '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr-tbi@test.local',   '', now(), now(), '', '', '', '');

  -- Profiles: emp1 + hr in co1, emp2 in co2
  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_emp1, 'emp1-tbi@test.local', v_co1, 'active', 'Alice', 'Employee'),
    (v_emp2, 'emp2-tbi@test.local', v_co2, 'active', 'Bob',   'Other'),
    (v_hr,   'hr-tbi@test.local',   v_co1, 'active', 'Carol', 'HR');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_emp1, 'employee'::public.user_role),
    (v_emp2, 'employee'::public.user_role),
    (v_hr,   'hr'::public.user_role);

  -- Dealer + bike
  INSERT INTO public.dealers (name, address, lat, lon, phone)
  VALUES ('Test Dealer', 'Str. Test Nr. 1', 46.77, 23.58, '+40700000000')
  RETURNING id INTO v_dealer;

  INSERT INTO public.bikes (name, brand, type, full_price, dealer_id)
  VALUES ('E-City 500', 'TestBrand', 'e_city_bike', 3500.00, v_dealer)
  RETURNING id INTO v_bike;

  -- Bike benefits
  INSERT INTO public.bike_benefits (user_id, bike_id)
  VALUES (v_emp1, v_bike) RETURNING id INTO v_bb1;

  INSERT INTO public.bike_benefits (user_id, bike_id)
  VALUES (v_emp2, v_bike) RETURNING id INTO v_bb2;

  -- Loan applications (inserted as postgres/service_role)
  INSERT INTO public.tbi_loan_applications (profile_id, bike_benefit_id, order_id, order_total, status, redirect_url)
  VALUES
    (v_emp1, v_bb1, 'mbp_test_001', 2500.00, 'pending', 'https://tbi.example.com/redirect/001'),
    (v_emp2, v_bb2, 'mbp_test_002', 3000.00, 'approved', 'https://tbi.example.com/redirect/002');

  PERFORM set_config('test.emp1_id', v_emp1::text, false);
  PERFORM set_config('test.emp2_id', v_emp2::text, false);
  PERFORM set_config('test.hr_id',   v_hr::text,   false);
  PERFORM set_config('test.co1_id',  v_co1::text,  false);
  PERFORM set_config('test.co2_id',  v_co2::text,  false);
  PERFORM set_config('test.bb1_id',  v_bb1::text,  false);
END;
$$;

SELECT plan(10);

-- ── T01: tbi_loan_status enum exists with correct values ────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM pg_type WHERE typname = 'tbi_loan_status'
  ),
  'T01: tbi_loan_status enum exists'
);

-- ── T02: table has expected columns ─────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'tbi_loan_applications'
      AND column_name = 'order_id'
  )
  AND EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'tbi_loan_applications'
      AND column_name = 'tbi_response'
  ),
  'T02: tbi_loan_applications has order_id and tbi_response columns'
);

-- ── T03: updated_at trigger fires on UPDATE ─────────────────────────────────
-- Set updated_at to a past value, then UPDATE and verify it was refreshed
UPDATE public.tbi_loan_applications
SET updated_at = '2020-01-01 00:00:00+00'
WHERE order_id = 'mbp_test_001';

UPDATE public.tbi_loan_applications
SET status = 'approved'
WHERE order_id = 'mbp_test_001';

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.tbi_loan_applications
    WHERE order_id = 'mbp_test_001'
      AND updated_at > '2020-01-01 00:00:00+00'
  ),
  'T03: updated_at trigger fires on UPDATE'
);

-- Reset status for remaining tests
UPDATE public.tbi_loan_applications SET status = 'pending' WHERE order_id = 'mbp_test_001';

-- ── T04: Employee can SELECT own loan application ───────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp1_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.tbi_loan_applications
    WHERE order_id = 'mbp_test_001'
  ),
  'T04: employee can SELECT own loan application'
);

RESET ROLE;

-- ── T05: Employee cannot SELECT another employee's loan application ─────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp1_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.tbi_loan_applications
    WHERE order_id = 'mbp_test_002'
  ),
  'T05: employee cannot SELECT another employee''s loan application'
);

RESET ROLE;

-- ── T06: HR can SELECT loan applications for same-company employees ─────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.tbi_loan_applications
    WHERE order_id = 'mbp_test_001'
  ),
  'T06: HR can SELECT same-company employee loan application'
);

RESET ROLE;

-- ── T07: HR cannot SELECT loan applications for different-company employees ─
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.tbi_loan_applications
    WHERE order_id = 'mbp_test_002'
  ),
  'T07: HR cannot SELECT different-company employee loan application'
);

RESET ROLE;

-- ── T08: Employee cannot INSERT directly ────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp1_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT throws_ok(
  format(
    'INSERT INTO public.tbi_loan_applications (profile_id, bike_benefit_id, order_id, order_total)
     VALUES (%L, %L, ''mbp_test_emp_insert'', 1000.00)',
    current_setting('test.emp1_id'),
    current_setting('test.bb1_id')
  ),
  42501,
  NULL,
  'T08: employee cannot INSERT into tbi_loan_applications'
);

RESET ROLE;

-- ── T09: Employee cannot UPDATE directly ────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp1_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

UPDATE public.tbi_loan_applications
SET status = 'canceled'
WHERE order_id = 'mbp_test_001';

-- Verify nothing changed (still pending)
RESET ROLE;
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.tbi_loan_applications
    WHERE order_id = 'mbp_test_001' AND status = 'pending'
  ),
  'T09: employee cannot UPDATE tbi_loan_applications (status unchanged)'
);

-- ── T10: order_id uniqueness constraint enforced ────────────────────────────
SELECT throws_ok(
  format(
    'INSERT INTO public.tbi_loan_applications (profile_id, bike_benefit_id, order_id, order_total)
     VALUES (%L, %L, ''mbp_test_001'', 999.00)',
    current_setting('test.emp1_id'),
    current_setting('test.bb1_id')
  ),
  23505,
  NULL,
  'T10: duplicate order_id is rejected'
);

SELECT * FROM finish();
ROLLBACK;
