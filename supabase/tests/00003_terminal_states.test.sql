SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: HR terminal states
-- Verifies that benefit_status=insurance_claim, benefit_status=terminated,
-- and contract_status=terminated are never auto-overwritten by triggers
-- once set by HR.
--
-- Terminal states cannot be reached via normal trigger flow, so each
-- sub-test bootstraps the state by temporarily disabling triggers
-- (SET session_replication_role = replica) — the standard PostgreSQL
-- technique for bypassing triggers in test setups.
-- ============================================================

BEGIN;

-- ── Fixtures ─────────────────────────────────────────────────
CREATE TEMP TABLE _fix03 (
  company_id UUID,
  user_id    UUID,
  benefit_id UUID
) ON COMMIT DROP;

DO $$
DECLARE
  v_co  UUID;
  v_uid UUID := gen_random_uuid();
  v_bb  UUID;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('terminal-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'terminal-' || gen_random_uuid()::text || '.test')
  RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          created_at, updated_at,
                          confirmation_token, email_change,
                          email_change_token_new, recovery_token)
  VALUES (v_uid, '00000000-0000-0000-0000-000000000000'::uuid,
          'authenticated', 'authenticated', 'pgtap-00003@test.local', '',
          now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_uid, 'pgtap-00003@test.local', v_co, 'active', 'Test', 'User');

  INSERT INTO public.bike_benefits (user_id, step, committed_at)
  VALUES (v_uid, 'sign_contract', now())
  RETURNING id INTO v_bb;

  INSERT INTO _fix03 VALUES (v_co, v_uid, v_bb);
END;
$$;

SELECT plan(6);

-- ── T01: insurance_claim is not overwritten by a step change ─
SET session_replication_role = replica;
UPDATE public.bike_benefits
SET benefit_status = 'insurance_claim'::public.benefit_status,
    step           = 'pickup_delivery'
WHERE id = (SELECT benefit_id FROM _fix03);
SET session_replication_role = DEFAULT;

-- Change step — trigger should return early and leave insurance_claim intact.
UPDATE public.bike_benefits
SET step = 'choose_bike'
WHERE id = (SELECT benefit_id FROM _fix03);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix03)),
  'insurance_claim',
  'T01: benefit_status=insurance_claim is not overwritten by step change'
);

-- ── T02: benefit terminated is not overwritten by a step change ─
SET session_replication_role = replica;
UPDATE public.bike_benefits
SET benefit_status = 'terminated'::public.benefit_status,
    step           = 'pickup_delivery'
WHERE id = (SELECT benefit_id FROM _fix03);
SET session_replication_role = DEFAULT;

UPDATE public.bike_benefits
SET step = 'book_live_test'
WHERE id = (SELECT benefit_id FROM _fix03);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix03)),
  'terminated',
  'T02: benefit_status=terminated is not overwritten by step change'
);

-- ── T03: contract terminated is not overwritten by timestamp change ─
SET session_replication_role = replica;
UPDATE public.bike_benefits
SET contract_status = 'terminated'::public.contract_status
WHERE id = (SELECT benefit_id FROM _fix03);
SET session_replication_role = DEFAULT;

-- Set a contract timestamp — trigger should leave contract_status alone.
UPDATE public.bike_benefits
SET contract_requested_at = now()
WHERE id = (SELECT benefit_id FROM _fix03);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix03)),
  'terminated',
  'T03: contract_status=terminated is not overwritten by timestamp change'
);

-- ── T04: benefit terminated persists through multiple step changes ─
-- (benefit_status already 'terminated' from T02; contract_status='terminated' from T03)
UPDATE public.bike_benefits
SET step = 'commit_to_bike'
WHERE id = (SELECT benefit_id FROM _fix03);

UPDATE public.bike_benefits
SET step = 'sign_contract'
WHERE id = (SELECT benefit_id FROM _fix03);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix03)),
  'terminated',
  'T04: benefit_status=terminated persists through multiple step changes'
);

-- ── T05: insurance_claim persists through contract timestamp changes ─
-- Reset to insurance_claim
SET session_replication_role = replica;
UPDATE public.bike_benefits
SET benefit_status = 'insurance_claim'::public.benefit_status,
    contract_status = NULL::public.contract_status,
    contract_requested_at = NULL,
    contract_viewed_at = NULL,
    step = 'pickup_delivery'
WHERE id = (SELECT benefit_id FROM _fix03);
SET session_replication_role = DEFAULT;

-- Set contract timestamps — benefit_status should remain insurance_claim.
UPDATE public.bike_benefits
SET contract_requested_at = now(),
    contract_viewed_at    = now()
WHERE id = (SELECT benefit_id FROM _fix03);

SELECT is(
  (SELECT benefit_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix03)),
  'insurance_claim',
  'T05: benefit_status=insurance_claim persists through contract timestamp changes'
);

-- ── T06: benefit_terminated_at timestamp is preserved after step change ─
-- Bootstrap: set benefit_status=terminated with a benefit_terminated_at timestamp.
SET session_replication_role = replica;
UPDATE public.bike_benefits
SET benefit_status        = 'terminated'::public.benefit_status,
    benefit_terminated_at = '2026-01-15 12:00:00+00'::timestamptz,
    step                  = 'pickup_delivery'
WHERE id = (SELECT benefit_id FROM _fix03);
SET session_replication_role = DEFAULT;

-- Trigger step change — terminated guard fires, NEW is passed through unchanged.
UPDATE public.bike_benefits
SET step = 'choose_bike'
WHERE id = (SELECT benefit_id FROM _fix03);

SELECT is(
  (SELECT benefit_terminated_at FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix03)),
  '2026-01-15 12:00:00+00'::timestamptz,
  'T06: benefit_terminated_at is preserved when trigger guard returns early'
);

SELECT * FROM finish();
ROLLBACK;
