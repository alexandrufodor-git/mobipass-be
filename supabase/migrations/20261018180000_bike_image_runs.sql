-- Audit log for bike photo normalisation: one row per bike-image-normalize run, written by the
-- function itself (cron runs, manual runs and dry runs), read by scripts/image-audit.sh.
CREATE TABLE public.bike_image_runs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at       timestamptz NOT NULL,
  finished_at      timestamptz NOT NULL DEFAULT now(),
  dry_run          boolean NOT NULL DEFAULT false,
  rule_version     integer NOT NULL,
  due              integer NOT NULL,
  normalized       integer NOT NULL DEFAULT 0,
  kept             integer NOT NULL DEFAULT 0,
  unchanged        integer NOT NULL DEFAULT 0,
  failed           integer NOT NULL DEFAULT 0,
  throttled        boolean NOT NULL DEFAULT false,
  bikes_refreshed  integer NOT NULL DEFAULT 0,
  bytes_downloaded bigint NOT NULL DEFAULT 0,
  bytes_stored     bigint NOT NULL DEFAULT 0,
  error            text
);

ALTER TABLE public.bike_image_runs ENABLE ROW LEVEL SECURITY; -- service role only
CREATE INDEX bike_image_runs_started_at_idx ON public.bike_image_runs (started_at DESC);

COMMENT ON TABLE public.bike_image_runs IS
  'One row per bike-image-normalize run: photos due and their outcomes, Cloudflare throttling (the run stopped early), bytes downloaded / stored, error. Pruned by prune_maintenance with the cron history.';

CREATE OR REPLACE FUNCTION "public"."prune_maintenance"("cache_keep_days" integer DEFAULT 7, "history_keep_days" integer DEFAULT 14, "reports_keep_days" integer DEFAULT 14) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  cache_rows   bigint;
  history_rows bigint;
  image_rows   bigint;
  reports_req  bigint;
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

  DELETE FROM public.bike_image_runs
  WHERE started_at < now() - make_interval(days => history_keep_days);
  GET DIAGNOSTICS image_rows = ROW_COUNT;

  -- A failing reports request must not roll back the two deletes above.
  BEGIN
    reports_req := public.request_issue_reports_prune(reports_keep_days);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'prune_maintenance: issue reports request failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'sync_run_cache', cache_rows,
    'cron_history', history_rows,
    'bike_image_runs', image_rows,
    'issue_reports_request', reports_req
  );
END;
$$;
