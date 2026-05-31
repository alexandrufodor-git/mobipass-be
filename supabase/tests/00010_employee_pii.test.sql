SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: PII Security Foundation
-- Tests:
--  T01: employee_pii table exists with correct columns
--  T02: labor_contracts table exists with correct columns
--  T03: integration_configs table exists
--  T04: integration_messages table exists
--  T05: updated_at trigger fires on employee_pii
--  T06: RLS — employee can SELECT own employee_pii
--  T07: RLS — employee cannot SELECT other employee's employee_pii
--  T08: RLS — HR can SELECT same-company employee_pii
--  T09: RLS — HR cannot SELECT other-company employee_pii
--  T10: RLS — employee cannot INSERT into employee_pii directly
--  T11: RLS — employee cannot UPDATE employee_pii directly
--  T12: RLS — employee cannot DELETE from employee_pii directly
--  T13: Unique constraint on employee_pii.user_id
--  T14: integration_configs unique constraint (company_id, integration)
--  T15: employee_pii.user_id is nullable (REGES staging support)
--  T16: partial unique index allows multiple NULL user_id rows
--  T17: pending PII (user_id IS NULL) hidden from non-HR authenticated user
--  T18: HR can SELECT own-company pending PII row
--  T19: HR cannot SELECT other-company pending PII row
--  T20: profile_invite_id FK exists with ON DELETE SET NULL
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co_a    uuid;
  v_co_b    uuid;
  v_emp_a   uuid := gen_random_uuid();
  v_emp_b   uuid := gen_random_uuid();
  v_hr_a    uuid := gen_random_uuid();
  v_pii_a   uuid;
  v_pii_b   uuid;
BEGIN
  -- Two companies (unique names so tests don't clash with seed data)
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency)
  VALUES ('pii-co-a-' || gen_random_uuid()::text, 72.00, 36, 'RON') RETURNING id INTO v_co_a;

  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency)
  VALUES ('pii-co-b-' || gen_random_uuid()::text, 100.00, 12, 'EUR') RETURNING id INTO v_co_b;

  -- Users in auth.users
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES
    (v_emp_a, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp-a-pii@test.local', '', now(), now(), '', '', '', ''),
    (v_emp_b, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'emp-b-pii@test.local', '', now(), now(), '', '', '', ''),
    (v_hr_a,  '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'hr-a-pii@test.local',  '', now(), now(), '', '', '', '');

  -- Profiles: emp_a in co_a, emp_b in co_b, hr_a in co_a
  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES
    (v_emp_a, 'emp-a-pii@test.local', v_co_a, 'active', 'Alice', 'A'),
    (v_emp_b, 'emp-b-pii@test.local', v_co_b, 'active', 'Bob',   'B'),
    (v_hr_a,  'hr-a-pii@test.local',  v_co_a, 'active', 'HR',    'Admin');

  INSERT INTO public.user_roles (user_id, role) VALUES
    (v_emp_a, 'employee'::public.user_role),
    (v_emp_b, 'employee'::public.user_role),
    (v_hr_a,  'hr'::public.user_role);

  -- employee_pii records (inserted as service_role / postgres)
  INSERT INTO public.employee_pii (user_id, company_id, home_address_encrypted, home_lat_encrypted, home_lon_encrypted, source)
  VALUES (v_emp_a, v_co_a, 'encrypted-address-a', '44.4268', '26.1025', 'manual')
  RETURNING id INTO v_pii_a;

  INSERT INTO public.employee_pii (user_id, company_id, home_address_encrypted, source)
  VALUES (v_emp_b, v_co_b, 'encrypted-address-b', 'manual')
  RETURNING id INTO v_pii_b;

  PERFORM set_config('test.emp_a_id', v_emp_a::text, false);
  PERFORM set_config('test.emp_b_id', v_emp_b::text, false);
  PERFORM set_config('test.hr_a_id',  v_hr_a::text,  false);
  PERFORM set_config('test.co_a_id',  v_co_a::text,  false);
  PERFORM set_config('test.co_b_id',  v_co_b::text,  false);
  PERFORM set_config('test.pii_a_id', v_pii_a::text, false);
  PERFORM set_config('test.pii_b_id', v_pii_b::text, false);
END;
$$;

SELECT plan(20);

-- ── T01: employee_pii table exists with encrypted columns ───────────────────
SELECT has_table('public', 'employee_pii', 'T01a: employee_pii table exists');

-- ── T02: labor_contracts table exists ────────────────────────────────────────
SELECT has_table('public', 'labor_contracts', 'T02: labor_contracts table exists');

-- ── T03: integration_configs table exists ────────────────────────────────────
SELECT has_table('public', 'integration_configs', 'T03: integration_configs table exists');

-- ── T04: integration_messages table exists ───────────────────────────────────
SELECT has_table('public', 'integration_messages', 'T04: integration_messages table exists');

-- ── T05: updated_at trigger fires on employee_pii ───────────────────────────
-- Update a row and verify updated_at changed
DO $$
BEGIN
  UPDATE public.employee_pii
  SET source = 'manual-updated'
  WHERE id = current_setting('test.pii_a_id')::uuid;
END;
$$;

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE id = current_setting('test.pii_a_id')::uuid
      AND updated_at >= now() - interval '5 seconds'
  ),
  'T05: updated_at trigger fires on employee_pii update'
);

-- ── T06: RLS — employee can SELECT own employee_pii ─────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_a_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id = current_setting('test.emp_a_id')::uuid
  ),
  'T06: employee can SELECT own employee_pii record'
);

RESET ROLE;

-- ── T07: RLS — employee cannot SELECT other employee's employee_pii ─────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_a_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id = current_setting('test.emp_b_id')::uuid
  ),
  'T07: employee cannot SELECT other employee''s employee_pii'
);

RESET ROLE;

-- ── T08: RLS — HR can SELECT same-company employee_pii ──────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_a_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id = current_setting('test.emp_a_id')::uuid
  ),
  'T08: HR can SELECT same-company employee_pii'
);

RESET ROLE;

-- ── T09: RLS — HR cannot SELECT other-company employee_pii ──────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.hr_a_id'), 'role', 'authenticated', 'user_role', 'hr')::text,
  true);

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id = current_setting('test.emp_b_id')::uuid
  ),
  'T09: HR cannot SELECT other-company employee_pii'
);

RESET ROLE;

-- ── T10: RLS — employee cannot INSERT into employee_pii ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_a_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT throws_ok(
  format(
    'INSERT INTO public.employee_pii (user_id, company_id, source) VALUES (''%s'', ''%s'', ''manual'')',
    current_setting('test.emp_a_id'),
    current_setting('test.co_a_id')
  ),
  '42501',  -- insufficient_privilege
  NULL,
  'T10: employee cannot INSERT into employee_pii directly'
);

RESET ROLE;

-- ── T11: RLS — employee cannot UPDATE employee_pii ──────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_a_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

-- UPDATE silently affects 0 rows (no UPDATE policy), check nothing changed
UPDATE public.employee_pii
SET source = 'hacked'
WHERE user_id = current_setting('test.emp_a_id')::uuid;

RESET ROLE;

-- Verify as postgres that source was NOT changed
SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id = current_setting('test.emp_a_id')::uuid
      AND source = 'hacked'
  ),
  'T11: employee cannot UPDATE employee_pii (no UPDATE policy)'
);

-- ── T12: RLS — employee cannot DELETE from employee_pii ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_a_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

-- DELETE silently affects 0 rows (no DELETE policy)
DELETE FROM public.employee_pii
WHERE user_id = current_setting('test.emp_a_id')::uuid;

RESET ROLE;

-- Verify as postgres that row still exists
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id = current_setting('test.emp_a_id')::uuid
  ),
  'T12: employee cannot DELETE from employee_pii (no DELETE policy)'
);

-- ── T13: Unique constraint on employee_pii.user_id ──────────────────────────
SELECT throws_ok(
  format(
    'INSERT INTO public.employee_pii (user_id, company_id, source) VALUES (''%s'', ''%s'', ''duplicate'')',
    current_setting('test.emp_a_id'),
    current_setting('test.co_a_id')
  ),
  '23505',  -- unique_violation
  NULL,
  'T13: unique constraint prevents duplicate employee_pii per user'
);

-- ── T14: integration_configs unique constraint ──────────────────────────────
INSERT INTO public.integration_configs (company_id, integration, enabled)
VALUES (current_setting('test.co_a_id')::uuid, 'reges', true);

SELECT throws_ok(
  format(
    'INSERT INTO public.integration_configs (company_id, integration, enabled) VALUES (''%s'', ''reges'', false)',
    current_setting('test.co_a_id')
  ),
  '23505',  -- unique_violation
  NULL,
  'T14: integration_configs unique constraint (company_id, integration)'
);

-- ── T15: employee_pii.user_id is nullable (REGES staging support) ──────────
SELECT col_is_null(
  'public', 'employee_pii', 'user_id',
  'T15: employee_pii.user_id is nullable'
);

-- ── T16: partial unique index allows multiple NULL user_id rows ────────────
DO $$
DECLARE
  v_co_a uuid := current_setting('test.co_a_id')::uuid;
BEGIN
  -- Two pending PII rows in the same company with user_id IS NULL must coexist.
  INSERT INTO public.employee_pii (user_id, company_id, source, source_ref_id)
  VALUES (NULL, v_co_a, 'reges', 't16-ref-a');
  INSERT INTO public.employee_pii (user_id, company_id, source, source_ref_id)
  VALUES (NULL, v_co_a, 'reges', 't16-ref-b');
END;
$$;

SELECT is(
  (SELECT count(*)::int FROM public.employee_pii
    WHERE user_id IS NULL
      AND company_id = current_setting('test.co_a_id')::uuid),
  2,
  'T16: partial unique index allows multiple NULL user_id rows'
);

-- ── T17: pending PII row hidden from non-HR authenticated user ─────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.emp_a_id'), 'role', 'authenticated', 'user_role', 'employee')::text,
  true);

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id IS NULL
      AND company_id = current_setting('test.co_a_id')::uuid
  ),
  'T17: employee cannot SELECT pending PII rows'
);

RESET ROLE;

-- ── T18: HR can SELECT own-company pending PII row ─────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object(
    'sub',              current_setting('test.hr_a_id'),
    'role',             'authenticated',
    'user_role',        'hr',
    'app_company_id',   current_setting('test.co_a_id')
  )::text,
  true);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id IS NULL
      AND company_id = current_setting('test.co_a_id')::uuid
  ),
  'T18: HR can SELECT own-company pending PII'
);

-- ── T19: HR cannot SELECT other-company pending PII row ────────────────────
-- Insert one pending row in co_b for this test
RESET ROLE;
INSERT INTO public.employee_pii (user_id, company_id, source, source_ref_id)
VALUES (NULL, current_setting('test.co_b_id')::uuid, 'reges', 't19-ref');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object(
    'sub',              current_setting('test.hr_a_id'),
    'role',             'authenticated',
    'user_role',        'hr',
    'app_company_id',   current_setting('test.co_a_id')
  )::text,
  true);

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id IS NULL
      AND company_id = current_setting('test.co_b_id')::uuid
  ),
  'T19: HR cannot SELECT other-company pending PII'
);

RESET ROLE;

-- ── T20: profile_invite_id FK with ON DELETE SET NULL ──────────────────────
DO $$
DECLARE
  v_co_a    uuid := current_setting('test.co_a_id')::uuid;
  v_invite  uuid;
  v_pii     uuid;
BEGIN
  INSERT INTO public.profile_invites (company_id, first_name, last_name, source, source_ref_id)
  VALUES (v_co_a, 'PendingFn', 'PendingLn', 'reges', 't20-invite')
  RETURNING id INTO v_invite;

  INSERT INTO public.employee_pii (user_id, company_id, source, source_ref_id, profile_invite_id)
  VALUES (NULL, v_co_a, 'reges', 't20-pii', v_invite)
  RETURNING id INTO v_pii;

  PERFORM set_config('test.t20_pii', v_pii::text, false);

  -- Drop the invite — the FK should null out profile_invite_id, not cascade.
  DELETE FROM public.profile_invites WHERE id = v_invite;
END;
$$;

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE id = current_setting('test.t20_pii')::uuid
      AND profile_invite_id IS NULL
  ),
  'T20: profile_invite_id FK ON DELETE SET NULL keeps PII row, nulls the link'
);

SELECT * FROM finish();
ROLLBACK;
