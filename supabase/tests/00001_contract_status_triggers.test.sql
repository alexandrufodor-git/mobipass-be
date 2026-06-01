SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: contract_status state machine
-- Tests the update_contract_status() BEFORE trigger priority chain.
-- Verifies: pending → viewed → signed_by_employee → signed_by_employer
--           → approved, declined_by_employee (not terminal),
--           terminated (terminal).
-- ============================================================

BEGIN;

-- ── Fixtures ─────────────────────────────────────────────────
CREATE TEMP TABLE _fix01 (
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
  VALUES ('contract-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'contract-' || gen_random_uuid()::text || '.test')
  RETURNING id INTO v_co;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          created_at, updated_at,
                          confirmation_token, email_change,
                          email_change_token_new, recovery_token)
  VALUES (v_uid, '00000000-0000-0000-0000-000000000000'::uuid,
          'authenticated', 'authenticated', 'pgtap-00001@test.local', '',
          now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_uid, 'pgtap-00001@test.local', v_co, 'active', 'Test', 'User');

  -- Benefit at sign_contract step (natural home for contract timestamps)
  INSERT INTO public.bike_benefits (user_id, step, committed_at)
  VALUES (v_uid, 'sign_contract', now())
  RETURNING id INTO v_bb;

  INSERT INTO _fix01 VALUES (v_co, v_uid, v_bb);
END;
$$;

SELECT plan(10);

-- ── T01: fresh benefit — no contract timestamps → contract_status IS NULL ─
SELECT is(
  (SELECT contract_status FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  NULL::public.contract_status,
  'T01: no contract timestamps → contract_status IS NULL'
);

-- ── T02: contract_requested_at set → pending ─────────────────
UPDATE public.bike_benefits
SET contract_requested_at = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'pending',
  'T02: contract_requested_at → pending'
);

-- ── T03: contract_viewed_at set → viewed_by_employee ─────────
UPDATE public.bike_benefits
SET contract_viewed_at = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'viewed_by_employee',
  'T03: contract_viewed_at → viewed_by_employee'
);

-- ── T04: contract_employee_signed_at set → signed_by_employee ─
UPDATE public.bike_benefits
SET contract_employee_signed_at = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'signed_by_employee',
  'T04: contract_employee_signed_at → signed_by_employee'
);

-- ── T05: contract_employer_signed_at set (employee already signed) → signed_by_employer ─
UPDATE public.bike_benefits
SET contract_employer_signed_at = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'signed_by_employer',
  'T05: contract_employer_signed_at (+ employee signed) → signed_by_employer'
);

-- ── T06: contract_approved_at set (all three signed) → approved ─
UPDATE public.bike_benefits
SET contract_approved_at = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'approved',
  'T06: all signed + approved → approved'
);

-- ── T07: contract_declined_at set — highest priority → declined_by_employee ─
UPDATE public.bike_benefits
SET contract_declined_at = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'declined_by_employee',
  'T07: contract_declined_at → declined_by_employee (highest priority)'
);

-- ── T08: declined_by_employee is NOT terminal —
--         clearing declined_at (other timestamps still present) → approved ─
UPDATE public.bike_benefits
SET contract_declined_at = NULL
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'approved',
  'T08: declined_by_employee NOT terminal — clearing declined_at reverts to approved'
);

-- ── T09: clear all timestamps, set requested_at → pending (re-send contract flow) ─
UPDATE public.bike_benefits
SET contract_declined_at        = NULL,
    contract_approved_at        = NULL,
    contract_employer_signed_at = NULL,
    contract_employee_signed_at = NULL,
    contract_viewed_at          = NULL,
    contract_requested_at       = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'pending',
  'T09: clear all → set contract_requested_at → pending (re-send flow)'
);

-- ── T10: contract_status=terminated IS terminal —
--         set timestamp does NOT overwrite ─────────────────────
-- Bootstrap terminal state by bypassing triggers.
SET session_replication_role = replica;
UPDATE public.bike_benefits
SET contract_status = 'terminated'::public.contract_status
WHERE id = (SELECT benefit_id FROM _fix01);
SET session_replication_role = DEFAULT;

-- Now set a timestamp — trigger should leave contract_status='terminated' alone.
UPDATE public.bike_benefits
SET contract_viewed_at = now()
WHERE id = (SELECT benefit_id FROM _fix01);

SELECT is(
  (SELECT contract_status::text FROM public.bike_benefits WHERE id = (SELECT benefit_id FROM _fix01)),
  'terminated',
  'T10: contract_status=terminated IS terminal — timestamp change does not overwrite'
);

SELECT * FROM finish();
ROLLBACK;
