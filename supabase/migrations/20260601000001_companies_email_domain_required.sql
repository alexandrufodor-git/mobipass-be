-- companies.email_domain becomes a required, format-validated column.
--
-- Why:
--   - REGES bulk-create hard-requires it (precondition checked in the edge
--     function today; better surfaced at the schema level so a company can
--     never exist in a "can't onboard new employees" state).
--   - register's confidence-claim flow (claim-by-name + DOB) resolves the
--     company by email_domain. Without a domain, the path silently 403s as
--     "not_invited", which is misleading.
--   - Future SSO will key tenant resolution on email domain — making this
--     optional is borrowing future tech debt.
--
-- Backfill strategy: derive from contact_email when present. Any row that
-- still lacks a domain after backfill blocks the migration loudly — that is
-- a data-quality issue worth surfacing rather than papering over.
--
-- Format CHECK: enforces lowercase + DNS-label-shaped domain (one or more
-- labels separated by dots, each label starts/ends with [a-z0-9], inner
-- chars may include hyphens). Rejects '@foo.com', 'https://foo.com',
-- 'foo', '.com', 'foo.', 'FOO.com'.

-- 1a. Normalize: treat empty / whitespace-only email_domain as NULL so the
--     backfill below picks them up. Prod has at least one row with '' which
--     would otherwise survive the NULL backfill and then fail the CHECK.
UPDATE public.companies
SET email_domain = NULL
WHERE email_domain IS NOT NULL
  AND btrim(email_domain) = '';

-- 1b. Backfill from contact_email when we can.
UPDATE public.companies
SET email_domain = lower(split_part(contact_email, '@', 2))
WHERE email_domain IS NULL
  AND contact_email IS NOT NULL
  AND position('@' IN contact_email) > 0
  AND split_part(contact_email, '@', 2) <> '';

-- 2. Refuse to proceed if any company still lacks email_domain.
--    In dev this should be zero rows; in prod it's a manual data fix first.
DO $$
DECLARE
  v_missing int;
BEGIN
  SELECT count(*) INTO v_missing
  FROM public.companies
  WHERE email_domain IS NULL;

  IF v_missing > 0 THEN
    RAISE EXCEPTION
      'companies.email_domain backfill incomplete: % row(s) still NULL. Set them manually before re-running this migration.',
      v_missing;
  END IF;
END $$;

-- 3. Enforce NOT NULL.
ALTER TABLE public.companies
  ALTER COLUMN email_domain SET NOT NULL;

COMMENT ON COLUMN public.companies.email_domain IS
  'Primary corporate email domain (e.g. "8x8.com"). Required. Used at registration to scope claim-by-name lookup and at REGES upload to derive employee emails. Bare hostname only — no scheme, no "@", lowercase.';

-- 4. Format check. Mirrors the implicit expectations of the TS code
--    (derivePatternEmail does `${local}@${domain.toLowerCase()}`).
ALTER TABLE public.companies
  ADD CONSTRAINT companies_email_domain_format CHECK (
    email_domain = lower(email_domain)
    AND email_domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  );

-- 5. The unique index was partial (`WHERE email_domain IS NOT NULL`) to allow
--    NULLs. Now that NULLs are impossible, recreate it as a full index for
--    consistency.
DROP INDEX IF EXISTS public.companies_email_domain_unique;
CREATE UNIQUE INDEX companies_email_domain_unique
  ON public.companies (lower(email_domain));
