SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: company_metrics projection — refreshers, live triggers, RLS, seed
--
-- Migration 20260627000003. Verifies the denormalised per-company KPI row:
-- disjoint count/CO₂ refreshers, the statement-level triggers that keep it live
-- (invite change → counts; benefit change → counts + CO₂ via company_co2_stats),
-- the companies seed trigger, and the HR-own-company RLS read policy.
--
-- Fixtures (company A, days_in_office = 5):
--   3 profile_invites (2 active, 1 inactive) → total=3, active_accounts=2
--   e1: profile + employee_pii(5.0) + active+delivered benefit (via replica)
--   e2: profile + employee_pii(5.0), benefit added LIVE later to test the trigger
--   e3: profile + a SEARCHING benefit (via replica) — non-active, so total_benefits
--       (any status) diverges from active_benefits. One benefit per profile.
-- Company B: created (seed trigger) but empty.
--
--  M01 total_accounts=3  M02 active_accounts=2  M03 active_benefits=1
--  M03b total_benefits=2 (e1 active + e3 searching)
--  M04 co2_all_time_kg=8.25  M05 invite INSERT live-bumps total→4
--  M06 benefit INSERT live-bumps active_benefits→2  M06b total_benefits→3
--  M07 co2 live→16.5  M08 company B seeded zero row  M09/M10 RLS own vs other
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_co_a  uuid;
  v_co_b  uuid;
  v_dom_a text := 'metr-a-' || gen_random_uuid()::text || '.test';
  v_dom_b text := 'metr-b-' || gen_random_uuid()::text || '.test';
  v_hr    uuid := gen_random_uuid();
  v_e1    uuid := gen_random_uuid();
  v_e2    uuid := gen_random_uuid();
  v_e3    uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('metr-co-a-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_a, 5, 46.77, 23.59) RETURNING id INTO v_co_a;
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain, days_in_office, address_lat, address_lon)
  VALUES ('metr-co-b-' || gen_random_uuid()::text, 72.00, 36, 'EUR', v_dom_b, 5, 44.43, 26.10) RETURNING id INTO v_co_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_hr, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr@' || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e1, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e1@' || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e2, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e2@' || v_dom_a, '', now(), now(), '', '', '', ''),
    (v_e3, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'e3@' || v_dom_a, '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_hr, 'hr@' || v_dom_a, v_co_a, 'active', 'HR', 'A'),
    (v_e1, 'e1@' || v_dom_a, v_co_a, 'active', 'E1', 'A'),
    (v_e2, 'e2@' || v_dom_a, v_co_a, 'active', 'E2', 'A'),
    (v_e3, 'e3@' || v_dom_a, v_co_a, 'active', 'E3', 'A');

  INSERT INTO public.user_roles (user_id, role) VALUES (v_hr, 'hr'::public.user_role);

  -- 3 invites for A: 2 active, 1 inactive
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name, status) VALUES
    ('i1@' || v_dom_a, v_co_a, 'I1', 'A', 'active'::public.user_profile_status),
    ('i2@' || v_dom_a, v_co_a, 'I2', 'A', 'active'::public.user_profile_status),
    ('i3@' || v_dom_a, v_co_a, 'I3', 'A', 'inactive'::public.user_profile_status);

  INSERT INTO public.employee_pii (user_id, company_id, commute_distance_km, commute_distance_computed_at) VALUES
    (v_e1, v_co_a, 5.0, now()),
    (v_e2, v_co_a, 5.0, now());

  -- e1: active+delivered benefit set exactly via replica (no trigger).
  -- e3: a non-active (searching) benefit — one benefit per profile — so
  -- total_benefits (counts any status) diverges from active_benefits.
  SET LOCAL session_replication_role = replica;
  INSERT INTO public.bike_benefits (user_id, step, committed_at, delivered_at, benefit_status)
  VALUES (v_e1, 'sign_contract', now(), now(), 'active'::public.benefit_status);
  INSERT INTO public.bike_benefits (user_id, step, benefit_status)
  VALUES (v_e3, 'choose_bike', 'searching'::public.benefit_status);
  SET LOCAL session_replication_role = DEFAULT;

  PERFORM set_config('test.hr_id',   v_hr::text,   false);
  PERFORM set_config('test.e2_id',   v_e2::text,   false);
  PERFORM set_config('test.co_a_id', v_co_a::text, false);
  PERFORM set_config('test.co_b_id', v_co_b::text, false);
  PERFORM set_config('test.dom_a',   v_dom_a,      false);
END;
$$;

SELECT plan(19);

-- Compute CO₂ stats (also cascades to metrics CO₂ via the stats trigger) + counts.
SELECT public.refresh_company_co2_stats();
SELECT public.refresh_company_metrics_counts();

SELECT is((SELECT total_accounts  FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  3, 'M01: total_accounts = 3 invites');
SELECT is((SELECT active_accounts FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  2, 'M02: active_accounts = 2 active invites');
SELECT is((SELECT active_benefits FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  1, 'M03: active_benefits = 1 (e1)');
SELECT is((SELECT total_benefits FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  2, 'M03b: total_benefits = 2 (e1 active + e3 searching) — counts any status');
SELECT is((SELECT co2_all_time_kg FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  8.25::numeric, 'M04: co2_all_time_kg = 8.25 (e1 this week)');

-- ── Live: a new active invite bumps the counts via the trigger (no manual refresh)
INSERT INTO public.profile_invites (email, company_id, first_name, last_name, status)
VALUES ('i4@' || current_setting('test.dom_a'), current_setting('test.co_a_id')::uuid, 'I4', 'A', 'active'::public.user_profile_status);
SELECT is((SELECT total_accounts FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  4, 'M05: invite INSERT live-bumps total_accounts to 4 (trigger)');

-- ── Live: flipping an invite's status fires the row-level (column-scoped) UPDATE
-- trigger. i4 is active, so active_accounts is 3; flipping i3 inactive→active → 4.
UPDATE public.profile_invites SET status = 'active'::public.user_profile_status
WHERE email = 'i3@' || current_setting('test.dom_a');
SELECT is((SELECT active_accounts FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  4, 'M5b: invite status flip live-bumps active_accounts to 4 (row-level UPDATE OF status)');

-- ── Live: a new active+delivered benefit (normal path) bumps benefits + CO₂
INSERT INTO public.bike_benefits (user_id, step, committed_at, delivered_at)
VALUES (current_setting('test.e2_id')::uuid, 'sign_contract', now(), now());
SELECT is((SELECT active_benefits FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  2, 'M06: benefit INSERT live-bumps active_benefits to 2 (trigger)');
SELECT is((SELECT total_benefits FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  3, 'M06b: benefit INSERT live-bumps total_benefits to 3 (e1+e2 active, e3 searching)');
SELECT is((SELECT co2_all_time_kg FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  16.5::numeric, 'M07: CO₂ live-recomputed to 16.5 (e1+e2) via stats→metrics cascade');

-- ── Companies seed trigger created a zero row for B ───────────────────────────
SELECT is((SELECT total_accounts FROM public.company_metrics WHERE company_id = current_setting('test.co_b_id')::uuid),
  0, 'M08: company B got a seeded zero metrics row on INSERT');

-- ── RLS: HR of A reads only their own metrics row ─────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_id'), 'role', 'authenticated', 'user_role', 'hr')::text, true);

SELECT ok(
  EXISTS(SELECT 1 FROM public.company_metrics WHERE company_id = current_setting('test.co_a_id')::uuid),
  'M09: HR sees own-company metrics');
SELECT ok(
  NOT EXISTS(SELECT 1 FROM public.company_metrics WHERE company_id = current_setting('test.co_b_id')::uuid),
  'M10: HR cannot see another company''s metrics');

-- ── RPC returns ALL FIVE numbers, all-time (p_from NULL), matching the live table ─
SELECT is((SELECT active_accounts FROM public.get_company_metrics(NULL, now())),
  4, 'M11: RPC all-time active_accounts = 4');
SELECT is((SELECT total_accounts  FROM public.get_company_metrics(NULL, now())),
  4, 'M12: RPC all-time total_accounts = 4');
SELECT is((SELECT active_benefits FROM public.get_company_metrics(NULL, now())),
  2, 'M13: RPC all-time active_benefits = 2');
SELECT is((SELECT total_benefits  FROM public.get_company_metrics(NULL, now())),
  3, 'M14: RPC all-time total_benefits = 3 (any status) — matches company_metrics');
SELECT is((SELECT co2_kg          FROM public.get_company_metrics(NULL, now())),
  16.5::numeric, 'M15: RPC all-time co2_kg = 16.5');

-- ── Windowed denominator is CUMULATIVE as of p_to (ignores p_from) ───────────────
-- A LAST-DAY window narrows nothing here (all rows just created), but the key proof
-- is that total_benefits is NOT filtered by p_from — it stays the full denominator.
SELECT is((SELECT total_benefits FROM public.get_company_metrics(now() - interval '1 day', now())),
  3, 'M16: RPC windowed total_benefits stays cumulative-as-of-to (3, ignores p_from)');

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
