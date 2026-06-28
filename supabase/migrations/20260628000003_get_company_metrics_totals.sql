-- HR Reports — make get_company_metrics windowed-COMPLETE.
--
-- The "at a glance" RPC returned only the windowed NUMERATORS
-- (active_accounts / active_benefits / co2_kg). The FE date picker
-- (ALL TIME / LAST MONTH / LAST WEEK / LAST DAY) also needs the
-- DENOMINATORS (total_accounts / total_benefits) for the same window,
-- and stitching them off the always-"now" company_metrics row mixes two
-- time bases (windowed numerator vs. all-time denominator) → wrong ratios.
--
-- Fix: the RPC now returns ALL FIVE numbers, each a pure function of
-- [p_from, p_to], computed on read. No client-side stitching.
--
--   Numerators  (touched IN the window):
--     active_accounts  — profile_invites currently 'active' whose last activity ∈ [from,to]
--     active_benefits  — bike_benefits   currently 'active' whose updated_at  ∈ [from,to]
--     co2_kg           — Σ company_co2_stats.kg_co2_saved for weeks whose Monday ∈ [from,to]
--   Denominators (CUMULATIVE as of the window END = p_to):
--     total_accounts   — profile_invites created on/before to (existed by window end)
--     total_benefits   — bike_benefits   created on/before to (existed by window end)
--
-- "Cumulative-as-of-to" is the correct denominator: active/total = "of everyone
-- who existed by the end of the period, how many were active in it". For ALL TIME
-- (p_from NULL, p_to now) created_at <= to ⇒ every row, so totals == the
-- company_metrics all-time snapshot. The two surfaces agree by construction.
--
-- company_metrics stays the realtime BEACON: FE subscribes to it for "something
-- changed" and refetches get_company_metrics for the selected window. The all-time
-- card can read either (the row directly, or this RPC with p_from = NULL).

DROP FUNCTION IF EXISTS "public"."get_company_metrics"(timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION "public"."get_company_metrics"(
  "p_from" timestamptz DEFAULT NULL,
  "p_to"   timestamptz DEFAULT now()
) RETURNS TABLE(
  "active_accounts" integer,
  "total_accounts"  integer,
  "active_benefits" integer,
  "total_benefits"  integer,
  "co2_kg"          numeric
)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_company uuid := (select public.auth_company_id());
  v_role    text := (auth.jwt() ->> 'user_role');
  v_to      timestamptz := COALESCE(p_to, now());
BEGIN
  IF v_company IS NULL OR v_role NOT IN ('hr', 'admin') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    -- active accounts whose last activity falls in [from,to]
    (SELECT count(*)::int FROM (
       SELECT pi.id,
              max(COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at)) AS last_activity
       FROM public.profile_invites pi
       LEFT JOIN public.profiles      p  ON p.profile_invite_id = pi.id
       LEFT JOIN public.bike_benefits bb ON bb.user_id = p.user_id
       LEFT JOIN public.bike_orders   bo ON bo.bike_benefit_id = bb.id
       WHERE pi.company_id = v_company
         AND pi.status = 'active'::public.user_profile_status
       GROUP BY pi.id
     ) a
     WHERE (p_from IS NULL OR a.last_activity >= p_from) AND a.last_activity <= v_to),
    -- total accounts that existed by the window end (cumulative as of to)
    (SELECT count(*)::int FROM public.profile_invites pi
       WHERE pi.company_id = v_company
         AND pi.created_at <= v_to),
    -- active benefits touched in [from,to]
    (SELECT count(*)::int FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = v_company
         AND bb.benefit_status = 'active'::public.benefit_status
         AND (p_from IS NULL OR bb.updated_at >= p_from) AND bb.updated_at <= v_to),
    -- total benefits that existed by the window end (cumulative as of to)
    (SELECT count(*)::int FROM public.bike_benefits bb
       JOIN public.profiles p ON p.user_id = bb.user_id
       WHERE p.company_id = v_company
         AND bb.created_at <= v_to),
    -- CO₂ saved across weeks whose Monday falls in [from,to]
    (SELECT COALESCE(round(sum(s.kg_co2_saved), 3), 0) FROM public.company_co2_stats s
       WHERE s.company_id = v_company
         AND (p_from IS NULL OR s.period >= p_from::date) AND s.period <= v_to::date);
END;
$$;

ALTER FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) FROM PUBLIC;
GRANT  ALL ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) TO "anon";
GRANT  ALL ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) TO "authenticated";
GRANT  ALL ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) TO "service_role";

COMMENT ON FUNCTION "public"."get_company_metrics"(timestamptz, timestamptz) IS
'HR Reports "at a glance" reader. Returns active_accounts / total_accounts / active_benefits / total_benefits / co2_kg for the calling HR/admin''s own company over [p_from, p_to] (p_from NULL = all-time, p_to defaults now()). Numerators are windowed (touched in range); totals are cumulative as of p_to (existed by window end) so active/total is a coherent same-window ratio. Computed on read — any range, no precomputed windows. PostgREST: POST /rest/v1/rpc/get_company_metrics. FE subscribes to company_metrics realtime as a beacon and refetches this for the selected window. See llm-agent-assist/plans/company-metrics-dashboard.md.';
