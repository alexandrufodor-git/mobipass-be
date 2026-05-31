-- REGES employee bridge: schema foundations
--
-- 1. companies gains email_domain (single canonical domain per company) and
--    email_pattern (optional email_pattern_kind enum — see EMAIL_PATTERN_TEMPLATES
--    in supabase/functions/_shared/emailPattern.ts for the literal template
--    string per enum value).
-- 2. profile_invites.email becomes nullable so REGES-imported records can
--    exist before the employee self-claims via /register. Identity columns
--    (first/last name) remain on profile_invites; all REGES-specific
--    descriptive PII lives on employee_pii.
-- 3. employee_pii.user_id becomes nullable so PII can be staged before the
--    employee registers. profile_invite_id links the staged PII to its invite
--    so the registration trigger can backfill user_id on claim.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 1. companies: email_domain + email_pattern -------------------------------

ALTER TABLE public.companies ADD COLUMN email_domain text;
COMMENT ON COLUMN public.companies.email_domain IS
  'Primary corporate email domain (e.g. "8x8.com"). Used at registration to scope claim-by-name lookup. Required before REGES upload for that company.';

CREATE UNIQUE INDEX companies_email_domain_unique
  ON public.companies (lower(email_domain))
  WHERE email_domain IS NOT NULL;

-- Named email patterns. The template strings live in TS
-- (supabase/functions/_shared/emailPattern.ts → EMAIL_PATTERN_TEMPLATES);
-- this enum is the DB-side source of truth for which pattern a company uses.
-- Add a new value here AND a corresponding entry in EMAIL_PATTERN_TEMPLATES.
CREATE TYPE public.email_pattern_kind AS ENUM (
  'last_middle_first',
  'first_middle_last',
  'first_last',
  'last_first',
  'first_initial_last'
);

ALTER TABLE public.companies ADD COLUMN email_pattern public.email_pattern_kind;
COMMENT ON COLUMN public.companies.email_pattern IS
  'Optional named email pattern used to derive employee email at REGES ingest. NULL = no derivation (employees self-claim by name/DOB). Template lookup lives in TS (EMAIL_PATTERN_TEMPLATES).';

-- 2. profile_invites: relax email + extend ---------------------------------

ALTER TABLE public.profile_invites ALTER COLUMN email DROP NOT NULL;
ALTER TABLE public.profile_invites DROP CONSTRAINT profile_invites_email_key;

CREATE UNIQUE INDEX profile_invites_email_unique
  ON public.profile_invites (lower(email))
  WHERE email IS NOT NULL;

ALTER TABLE public.profile_invites
  ADD COLUMN source          text NOT NULL DEFAULT 'manual',
  ADD COLUMN source_ref_id   text,
  ADD COLUMN birth_date_hash text,
  ADD COLUMN derived_email   text,
  ADD COLUMN radiat          boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.profile_invites.source IS
  'Origin of the invite: ''manual'' (CSV) or ''reges'' (JSON upload).';
COMMENT ON COLUMN public.profile_invites.source_ref_id IS
  'Source-system reference. For REGES: referintaSalariat.id (UUID). Idempotency key.';
COMMENT ON COLUMN public.profile_invites.birth_date_hash IS
  'HMAC-SHA256 blind index of ISO-formatted DOB. Always populated for REGES rows (derived from CNP positions 2-7). NULL for CSV rows.';
COMMENT ON COLUMN public.profile_invites.derived_email IS
  'Email derived from companies.email_pattern at REGES ingest. Used at /register for confident pattern-based claim. NULL when company has no pattern or derivation failed.';
COMMENT ON COLUMN public.profile_invites.radiat IS
  'REGES "radiat" (terminated) flag. true once the employee has been removed from the registry.';

CREATE UNIQUE INDEX profile_invites_source_unique
  ON public.profile_invites (company_id, source, source_ref_id)
  WHERE source_ref_id IS NOT NULL;

CREATE INDEX idx_profile_invites_pending_dob
  ON public.profile_invites (company_id, birth_date_hash)
  WHERE email IS NULL;

CREATE INDEX idx_profile_invites_derived_email
  ON public.profile_invites (company_id, lower(derived_email))
  WHERE email IS NULL AND derived_email IS NOT NULL;

CREATE INDEX idx_profile_invites_name_trgm
  ON public.profile_invites
  USING gin ((lower(first_name) || ' ' || lower(last_name)) gin_trgm_ops)
  WHERE email IS NULL;

-- 3. employee_pii: relax user_id + link to invite --------------------------

ALTER TABLE public.employee_pii ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE public.employee_pii DROP CONSTRAINT employee_pii_user_unique;

CREATE UNIQUE INDEX employee_pii_user_unique
  ON public.employee_pii (user_id) WHERE user_id IS NOT NULL;

ALTER TABLE public.employee_pii
  ADD COLUMN profile_invite_id uuid
    REFERENCES public.profile_invites(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.employee_pii.profile_invite_id IS
  'Links a REGES-staged PII row to its profile_invites row. Lets handle_user_registration backfill employee_pii.user_id when the matching invite is claimed.';

CREATE UNIQUE INDEX employee_pii_source_unique
  ON public.employee_pii (company_id, source, source_ref_id)
  WHERE source_ref_id IS NOT NULL;

CREATE INDEX idx_employee_pii_profile_invite
  ON public.employee_pii (profile_invite_id)
  WHERE profile_invite_id IS NOT NULL;

-- 4. RLS: HR can see pending PII rows in their own company -----------------

CREATE POLICY "HR view pending PII own company"
  ON public.employee_pii FOR SELECT TO authenticated
  USING (
    user_id IS NULL
    AND public.get_my_role() IN ('hr','admin')
    AND company_id = public.auth_company_id()
  );
