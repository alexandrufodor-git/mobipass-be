-- ============================================================================
-- Seed Data for Local Development
-- ============================================================================
-- This file contains test data for local development and testing.
-- It will be automatically loaded when you run: supabase db reset
-- ============================================================================

-- Clear existing user-owned data (in correct order to respect foreign keys).
-- Bikes are catalog data inserted by migrations — do not truncate here, or
-- setup-e2e-vault.sh / any flow that looks up a bike will fail.
TRUNCATE TABLE public.bike_orders CASCADE;
TRUNCATE TABLE public.bike_benefits CASCADE;
TRUNCATE TABLE public.user_roles CASCADE;
TRUNCATE TABLE public.profiles CASCADE;
TRUNCATE TABLE public.profile_invites CASCADE;
TRUNCATE TABLE public.companies CASCADE;

-- ============================================================================
-- Companies with benefit pricing
-- ============================================================================
INSERT INTO public.companies (id, name, description, monthly_benefit_subsidy, contract_months, contact_email, email_domain) VALUES
  ('11111111-1111-1111-1111-111111111111'::uuid, '8x8', 'Communications company offering bike benefits', 72.00, 36, 'hr@8x8.com', '8x8.com'),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'BigTech1', 'Large tech company with generous bike subsidy', 100.00, 36, 'hr@bigtech1.com', 'bigtech1.com'),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'SmallTech2', 'Startup with standard bike benefits', 50.00, 24, 'hr@smalltech2.com', 'smalltech2.com');

-- ============================================================================
-- Profile Invites
-- ============================================================================
-- Add test invites so users can register via OTP
INSERT INTO public.profile_invites (email, status, company_id, first_name, last_name) VALUES
  ('test@example.com', 'inactive', '11111111-1111-1111-1111-111111111111'::uuid, 'Test', 'User'),
  ('admin@example.com', 'inactive', '11111111-1111-1111-1111-111111111111'::uuid, 'Admin', 'User'),
  ('hr@example.com', 'inactive', '11111111-1111-1111-1111-111111111111'::uuid, 'HR', 'User'),
  ('someonestolemyyahoo@gmail.com', 'inactive', '22222222-2222-2222-2222-222222222222'::uuid, 'Someone', 'Else');

-- ============================================================================
-- Pre-registered users (auth.users + profiles + roles + bike_benefit)
-- ============================================================================
-- These bypass the OTP flow so local dev is immediately usable after db reset.

-- Auth users
-- encrypted_password = NULL prevents handle_user_registration trigger from firing
-- (trigger condition: email_confirmed_at IS NOT NULL AND encrypted_password IS NOT NULL)
-- so we can insert profiles/user_roles/bike_benefits manually below.
INSERT INTO auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token,
  raw_user_meta_data, raw_app_meta_data
) VALUES
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated',
    'employee@example.com', NULL,
    now(), now(), now(),
    '', '', '', '',
    '{}', '{"provider":"email","providers":["email"]}'
  ),
  (
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
    '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated',
    'hr@example.com', NULL,
    now(), now(), now(),
    '', '', '', '',
    '{}', '{"provider":"email","providers":["email"]}'
  );

-- Mark invites as active for these users
UPDATE public.profile_invites
SET status = 'active'
WHERE email IN ('test@example.com', 'hr@example.com');

-- Profiles
INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name, department) VALUES
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    'employee@example.com',
    '11111111-1111-1111-1111-111111111111'::uuid,
    'active', 'Alice', 'Employee', 'Engineering'
  ),
  (
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
    'hr@example.com',
    '11111111-1111-1111-1111-111111111111'::uuid,
    'active', 'Bob', 'HR', 'Human Resources'
  );

-- Roles
INSERT INTO public.user_roles (user_id, role) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 'employee'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid, 'hr');

-- Bike benefit for the employee (trigger sets benefit_status = inactive)
INSERT INTO public.bike_benefits (user_id)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid);

-- ============================================================================
-- REGES E2E company (local dev only)
-- ============================================================================
-- A company configured to receive REGES JSON uploads. email_domain is set
-- to 'gmail.com' so real personal gmail addresses can be used during mobile
-- E2E (the OTP is captured by the local Mailpit on port 54324 — nothing
-- leaves your machine). email_pattern 'last_middle_first' resolves to
-- "{last}?{.{middle}}.{first}" → fodor.horatiu.alexandru@gmail.com when
-- middle exists, fodor.alexandru@gmail.com when not.

INSERT INTO public.companies (
  id, name, description, monthly_benefit_subsidy, contract_months,
  contact_email, email_domain, email_pattern
) VALUES (
  '44444444-4444-4444-4444-444444444444'::uuid,
  'RegesGmail',
  'Local-dev company wired for REGES JSON uploads via gmail.com email domain.',
  80.00, 36,
  'hr-reges@gmail.com',
  'gmail.com',
  'last_middle_first'::public.email_pattern_kind
);

-- HR user pre-registered for the REGES company so curl-driven uploads can
-- authenticate without OTP. encrypted_password=NULL keeps the registration
-- trigger from firing (same pattern as the existing seed users above).
INSERT INTO auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token,
  raw_user_meta_data, raw_app_meta_data
) VALUES (
  'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated',
  'hr-reges@gmail.com', NULL,
  now(), now(), now(),
  '', '', '', '',
  '{}', '{"provider":"email","providers":["email"]}'
);

INSERT INTO public.profiles (
  user_id, email, company_id, status, first_name, last_name, department
) VALUES (
  'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
  'hr-reges@gmail.com',
  '44444444-4444-4444-4444-444444444444'::uuid,
  'active', 'HR', 'Reges', 'Human Resources'
);

INSERT INTO public.user_roles (user_id, role) VALUES
  ('dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid, 'hr');

-- ============================================================================
-- Notes for Testing
-- ============================================================================
-- To test the register flow locally:
-- 
-- 1. Start Supabase:
--    supabase start
--
-- 2. Reset database (applies migrations + seeds):
--    supabase db reset
--
-- 3. Test register endpoint:
--    curl -X POST http://127.0.0.1:54321/functions/v1/register \
--      -H "Content-Type: application/json" \
--      -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0" \
--      -d '{"email":"test@example.com"}'
--
-- 4. Check Inbucket for OTP email:
--    http://127.0.0.1:54324
--
-- 5. After OTP verification, check that:
--    - profile was created in public.profiles
--    - user_role 'employee' was assigned in public.user_roles
--    - profile_invites status changed to 'active'

