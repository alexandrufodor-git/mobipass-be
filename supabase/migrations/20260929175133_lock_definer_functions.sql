-- SECURITY DEFINER functions with no caller check were executable by anon/authenticated via
-- /rest/v1/rpc with the app's anon key (Postgres grants EXECUTE to PUBLIC by default; Supabase
-- advisor anon_security_definer_function_executable). Worst: get_vault_secret returned any
-- Vault secret by name. Callers are edge functions (service key), pg_cron (postgres) and the
-- auth hook (supabase_auth_admin), none of which these revokes touch.
-- pgTAP 00029 fails if a new unguarded SECURITY DEFINER function is left open.

REVOKE EXECUTE ON FUNCTION public.get_vault_secret(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_vault_secret(text) TO service_role;

DO $$
DECLARE
  f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'bike_sync_invoke', 'bike_sync_kickoff', 'bike_sync_tick', 'claim_next_sync_unit',
        'complete_sync_unit', 'enqueue_page_units', 'finalize_sync_run', 'seed_audit_units',
        'merge_bike_offers', 'ingest_reges_batch', 'match_pending_invite',
        'refresh_company_co2_stats', 'refresh_company_ledger',
        'refresh_company_metrics_co2', 'refresh_company_metrics_counts',
        'custom_access_token_hook'
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END;
$$;
