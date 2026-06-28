SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: company_ledger + company_metrics_monthly — snapshot, roll-up, RLS
--
-- Migration 20260627000006. The frozen weekly snapshot feeding the HR Reports
-- monthly trend chart.
--
-- Fixtures (company A):
--   2 active + 1 inactive invite → company_metrics total=3, active=2 (triggers)
--   refresh_company_ledger() → current-week ledger row mirrors company_metrics
--   2 synthetic Jan-2026 ledger rows (different weeks) test last-per-month roll-up
--   company B: 1 ledger row (must NOT be visible to A's HR)
--
--  L01 ledger current-week total=3  L02 active=2
--  L03 monthly view = last snapshot in month (active=20)  L04 (total_accounts=22)
--  L04b monthly view total_benefits=12 (last week of month)
--  L05 RLS HR sees own ledger  L06 RLS HR cannot see B's ledger
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_co_a  uuid;
  v_co_b  uuid;
  v_dom_a text := 'led-a-' || gen_random_uuid()::text || '.test';
  v_dom_b text := 'led-b-' || gen_random_uuid()::text || '.test';
  v_hr    uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('led-co-a-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_a, 5, 46.77, 23.59) RETURNING id INTO v_co_a;
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('led-co-b-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_b, 5, 44.43, 26.10) RETURNING id INTO v_co_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES (v_hr, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr@' || v_dom_a, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_hr, 'hr@' || v_dom_a, v_co_a, 'active', 'HR', 'A');

  INSERT INTO public.user_roles (user_id, role) VALUES (v_hr, 'hr'::public.user_role);

  INSERT INTO public.profile_invites (email, company_id, first_name, last_name, status) VALUES
    ('i1@' || v_dom_a, v_co_a, 'I1', 'A', 'active'::public.user_profile_status),
    ('i2@' || v_dom_a, v_co_a, 'I2', 'A', 'active'::public.user_profile_status),
    ('i3@' || v_dom_a, v_co_a, 'I3', 'A', 'inactive'::public.user_profile_status);

  -- Synthetic Jan-2026 snapshots (two distinct weeks, same month) for company A.
  INSERT INTO public.company_ledger (company_id, period, total_accounts, active_accounts, active_benefits, total_benefits) VALUES
    (v_co_a, date '2026-01-05', 10, 10, 4,  6),   -- earlier week in Jan
    (v_co_a, date '2026-01-26', 22, 20, 9, 12);   -- later week in Jan → wins the month

  -- Company B ledger row (RLS isolation target).
  INSERT INTO public.company_ledger (company_id, period, total_accounts, active_accounts, active_benefits, total_benefits)
  VALUES (v_co_b, date '2026-01-05', 5, 5, 1, 2);

  PERFORM set_config('test.hr_id',   v_hr::text,   false);
  PERFORM set_config('test.co_a_id', v_co_a::text, false);
  PERFORM set_config('test.co_b_id', v_co_b::text, false);
END;
$$;

SELECT plan(7);

-- ── refresh_company_ledger snapshots company_metrics into the current week ────
SELECT public.refresh_company_ledger();

SELECT is(
  (SELECT total_accounts FROM public.company_ledger
   WHERE company_id = current_setting('test.co_a_id')::uuid AND period = date_trunc('week', now())::date),
  3, 'L01: current-week ledger total_accounts = 3 (mirrors company_metrics)');
SELECT is(
  (SELECT active_accounts FROM public.company_ledger
   WHERE company_id = current_setting('test.co_a_id')::uuid AND period = date_trunc('week', now())::date),
  2, 'L02: current-week ledger active_accounts = 2');

-- ── Monthly view: last snapshot per month wins ────────────────────────────────
SELECT is(
  (SELECT active_accounts FROM public.company_metrics_monthly
   WHERE company_id = current_setting('test.co_a_id')::uuid AND month = date '2026-01-01'),
  20, 'L03: monthly view Jan-2026 active_accounts = 20 (last week of month)');
SELECT is(
  (SELECT total_accounts FROM public.company_metrics_monthly
   WHERE company_id = current_setting('test.co_a_id')::uuid AND month = date '2026-01-01'),
  22, 'L04: monthly view Jan-2026 total_accounts = 22 (last week of month)');
SELECT is(
  (SELECT total_benefits FROM public.company_metrics_monthly
   WHERE company_id = current_setting('test.co_a_id')::uuid AND month = date '2026-01-01'),
  12, 'L04b: monthly view Jan-2026 total_benefits = 12 (last week of month)');

-- ── RLS: HR of A reads only their own company's ledger ────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text, true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.company_ledger WHERE company_id = current_setting('test.co_a_id')::uuid),
  'L05: HR sees own-company ledger rows');
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.company_ledger WHERE company_id = current_setting('test.co_b_id')::uuid),
  'L06: HR cannot see another company''s ledger rows');

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
