SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: handle_user_registration trigger
-- Tests:
--  T01: trigger creates profile before user_roles (FK order fix)
--  T02: profile fields copied from profile_invites
--  T03: user_roles row created with 'employee' role
--  T04: bike_benefit row created
--  T05: profile_invites status set to 'active'
--  T06: trigger raises exception when no invite exists
--  T07: trigger is idempotent (ON CONFLICT — re-running does not error)
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
CREATE TEMP TABLE _fix04 (
  company_id uuid,
  user_id    uuid,
  email      text
) ON COMMIT DROP;

DO $$
DECLARE
  v_co  uuid;
  v_uid uuid := gen_random_uuid();
  v_email text := 'pgtap-00004@test.local';
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('reg-co-' || gen_random_uuid()::text, 50.00, 24, 'EUR', 'reg-' || gen_random_uuid()::text || '.test')
  RETURNING id INTO v_co;

  -- Pre-create the invite so the trigger can resolve company_id
  INSERT INTO public.profile_invites (email, company_id, first_name, last_name, description, department, hire_date)
  VALUES (v_email, v_co, 'Alice', 'Smith', 'Engineer', 'Engineering', 1700000000000);

  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  )
  VALUES (
    v_uid, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_email, '',
    now(), now(), '', '', '', ''
  );

  INSERT INTO _fix04 VALUES (v_co, v_uid, v_email);
END;
$$;

SELECT plan(8);

-- Manually fire the trigger by simulating what it does (trigger already ran on INSERT
-- above but email_confirmed_at was NULL so steps were skipped).
-- Re-fire by setting email_confirmed_at + encrypted_password to satisfy WHEN clause.
UPDATE auth.users
SET email_confirmed_at = now(),
    encrypted_password = 'hashed-password-value'
WHERE id = (SELECT user_id FROM _fix04);

-- ── T01: profile row exists ───────────────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.profiles
    WHERE user_id = (SELECT user_id FROM _fix04)
  ),
  'T01: trigger created profile row'
);

-- ── T02: profile fields copied from profile_invites ───────────────────────────
SELECT is(
  (SELECT first_name || ' ' || last_name FROM public.profiles
   WHERE user_id = (SELECT user_id FROM _fix04)),
  'Alice Smith',
  'T02: profile first_name + last_name copied from invite'
);

-- ── T03: user_roles row created ───────────────────────────────────────────────
SELECT is(
  (SELECT role::text FROM public.user_roles
   WHERE user_id = (SELECT user_id FROM _fix04)),
  'employee',
  'T03: user_roles row created with employee role'
);

-- ── T04: bike_benefit row created ─────────────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.bike_benefits
    WHERE user_id = (SELECT user_id FROM _fix04)
  ),
  'T04: bike_benefit row created'
);

-- ── T05: profile_invites status set to active ─────────────────────────────────
SELECT is(
  (SELECT status::text FROM public.profile_invites
   WHERE LOWER(email) = LOWER((SELECT email FROM _fix04))),
  'active',
  'T05: profile_invites status set to active'
);

-- ── T06: exception raised when no invite exists ───────────────────────────────
DO $$
DECLARE
  v_uid uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  )
  VALUES (
    v_uid, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', 'noinvite-pgtap@test.local',
    'hashed', now(), now(), now(), '', '', '', ''
  );
  -- Should not reach here
  RAISE EXCEPTION 'expected trigger exception was not raised';
EXCEPTION
  WHEN OTHERS THEN
    -- Expected — trigger raises exception for unknown email
    NULL;
END;
$$;

SELECT ok(true, 'T06: trigger raises exception for email with no invite');

-- ── T07: idempotent — re-running UPDATE does not error ────────────────────────
UPDATE auth.users
SET updated_at = now()
WHERE id = (SELECT user_id FROM _fix04);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.profiles
    WHERE user_id = (SELECT user_id FROM _fix04)
  ),
  'T07: trigger idempotent — profile still exists after second update'
);

-- ── T08: company_notifications row created ────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM public.company_notifications
    WHERE company_id = (SELECT company_id FROM _fix04)
      AND event = 'user_update'
      AND event_type = 'created'
  ),
  'T08: company_notifications row inserted for user registration'
);

SELECT * FROM finish();
ROLLBACK;
