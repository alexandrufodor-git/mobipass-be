SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: companies.name is plain text (enum removed)
-- Tests:
--  T01: Arbitrary company names can be inserted (enum is gone)
--  T02: Duplicate company names are rejected by UNIQUE constraint
--  T03: The company_name enum type no longer exists
-- ============================================================

BEGIN;

SELECT plan(3);

-- T01: arbitrary name works
SELECT lives_ok(
  $$INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
    VALUES ('BrandNewCo 2026', 72.00, 36, 'RON', 'brandnewco-2026.test')$$,
  'T01: arbitrary company name accepted'
);

-- T02: duplicate rejected
SELECT throws_ok(
  $$INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
    VALUES ('BrandNewCo 2026', 50.00, 24, 'EUR', 'brandnewco-2026-dup.test')$$,
  '23505',
  NULL,
  'T02: duplicate company name violates UNIQUE'
);

-- T03: enum type was dropped
SELECT is(
  (SELECT COUNT(*)::int
     FROM pg_type t
     JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'company_name' AND n.nspname = 'public'),
  0,
  'T03: public.company_name enum no longer exists'
);

SELECT * FROM finish();
ROLLBACK;
