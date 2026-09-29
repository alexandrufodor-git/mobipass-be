-- Daily cleanup of the two tables that only grow:
--   sync_run_cache      working copy of vendor data per bike-sync run, only needed while the run is going
--                       (reached 343 MB of a 425 MB database by Sep 2026). Run stats in sync_runs stay.
--   cron.job_run_details  one row per cron run (~1,440/day from bike-sync-tick alone).
-- Same retention as scripts/cron-audit.sh (cache 7 days, history 14 days), which can also prune by hand.

CREATE OR REPLACE FUNCTION public.prune_maintenance(
  cache_keep_days   integer DEFAULT 7,
  history_keep_days integer DEFAULT 14
) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  cache_rows   bigint;
  history_rows bigint;
BEGIN
  -- Finished runs only: a running sync still reads its cache.
  DELETE FROM public.sync_run_cache c
  USING public.sync_runs r
  WHERE r.id = c.run_id
    AND r.status <> 'running'
    AND r.started_at < now() - make_interval(days => cache_keep_days);
  GET DIAGNOSTICS cache_rows = ROW_COUNT;

  DELETE FROM cron.job_run_details
  WHERE start_time < now() - make_interval(days => history_keep_days);
  GET DIAGNOSTICS history_rows = ROW_COUNT;

  RETURN jsonb_build_object('sync_run_cache', cache_rows, 'cron_history', history_rows);
END;
$$;

ALTER FUNCTION public.prune_maintenance(integer, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.prune_maintenance(integer, integer) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.prune_maintenance(integer, integer) IS
  'Deletes sync_run_cache of finished runs older than cache_keep_days and cron.job_run_details older than history_keep_days. Run daily by the db-maintenance-prune cron job.';

-- 04:00 UTC: after the 02:00 sync and the 03:00 refresh jobs.
SELECT cron.schedule(
  'db-maintenance-prune',
  '0 4 * * *',
  $$ SELECT public.prune_maintenance(); $$
);

-- To pause later:
--   SELECT cron.unschedule('db-maintenance-prune');
