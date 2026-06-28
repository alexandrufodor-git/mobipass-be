-- HR Reports — total_benefits: make the benefit metric 1:1 with accounts.
--
-- The metrics surfaces carried total_accounts + active_accounts but only
-- active_benefits (no denominator). That asymmetry meant the FE could render
-- "active / total" for accounts but never for benefits. This adds total_benefits
-- across the three STOCK surfaces, mirroring total_accounts exactly:
--   total_accounts  = count(*) of profile_invites for the company (any status).
--   total_benefits  = count(*) of bike_benefits  for the company (any status).
-- With one benefit per profile, total_benefits = number of employees who have a
-- benefit at all; active_benefits / total_benefits = "of those who started a
-- benefit, how many are currently active". total_benefits >= active_benefits.
--
-- Touched (kept symmetric with total_accounts):
--   * company_metrics            (realtime beacon + all-time snapshot) — new column.
--   * company_ledger             (weekly point-in-time snapshot)       — new column.
--   * company_metrics_monthly    (chart view)                          — new column.
--   * refresh_company_metrics_counts / refresh_company_ledger          — compute/copy it.
-- Untouched on purpose:
--   * get_company_metrics RPC — windowed-NUMERATOR-only by design; the denominator
--     is a "now" value read off company_metrics (see company-metrics-dashboard.md).
--   * the company-ledger-refresh pg_cron job — it calls refresh_company_ledger()
--     BY NAME, so this CREATE OR REPLACE makes the cron carry total_benefits with
--     no schedule change.

-- ── Columns (default 0; the re-seed below backfills real counts) ───────────────
ALTER TABLE "public"."company_metrics"
  ADD COLUMN IF NOT EXISTS "total_benefits" integer NOT NULL DEFAULT 0;
ALTER TABLE "public"."company_ledger"
  ADD COLUMN IF NOT EXISTS "total_benefits" integer NOT NULL DEFAULT 0;

-- ── Counts refresher: compute total_benefits alongside the rest ───────────────
CREATE OR REPLACE FUNCTION "public"."refresh_company_metrics_counts"(
  "p_company_ids" uuid[] DEFAULT NULL
) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.company_metrics AS m
    (company_id, total_accounts, active_accounts, active_benefits, total_benefits, counts_updated_at)
  SELECT
    c.id,
    (SELECT count(*) FROM public.profile_invites pi WHERE pi.company_id = c.id),
    (SELECT count(*) FROM public.profile_invites pi
       WHERE pi.company_id = c.id AND pi.status = 'active'::public.user_profile_status),
    (SELECT count(*) FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = c.id AND bb.benefit_status = 'active'::public.benefit_status),
    (SELECT count(*) FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = c.id),
    now()
  FROM public.companies c
  WHERE (p_company_ids IS NULL OR c.id = ANY (p_company_ids))
  ON CONFLICT (company_id) DO UPDATE SET
    total_accounts    = EXCLUDED.total_accounts,
    active_accounts   = EXCLUDED.active_accounts,
    active_benefits   = EXCLUDED.active_benefits,
    total_benefits    = EXCLUDED.total_benefits,
    counts_updated_at = now();
END;
$$;

-- ── Ledger refresher: copy total_benefits into the weekly snapshot ────────────
CREATE OR REPLACE FUNCTION "public"."refresh_company_ledger"() RETURNS void
  LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $$
  INSERT INTO public.company_ledger
    (company_id, period, total_accounts, active_accounts, active_benefits, total_benefits, computed_at)
  SELECT company_id, date_trunc('week', now())::date,
         total_accounts, active_accounts, active_benefits, total_benefits, now()
  FROM public.company_metrics
  ON CONFLICT (company_id, period) DO UPDATE SET
    total_accounts  = EXCLUDED.total_accounts,
    active_accounts = EXCLUDED.active_accounts,
    active_benefits = EXCLUDED.active_benefits,
    total_benefits  = EXCLUDED.total_benefits,
    computed_at     = now();
$$;

-- ── Chart view: expose total_benefits (appended → CREATE OR REPLACE is legal) ─
CREATE OR REPLACE VIEW "public"."company_metrics_monthly" WITH ("security_invoker"='on') AS
SELECT DISTINCT ON (company_id, date_trunc('month', period))
  company_id,
  date_trunc('month', period)::date AS month,
  active_accounts,
  active_benefits,
  total_accounts,
  total_benefits
FROM public.company_ledger
ORDER BY company_id, date_trunc('month', period), period DESC;   -- last snapshot per month

-- ── Backfill: recompute every company's counts, then re-stamp this week's ledger
SELECT public.refresh_company_metrics_counts();
SELECT public.refresh_company_ledger();
