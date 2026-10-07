-- Problem reports sent from the mobile app (shake or Settings → Report a problem).
-- Signed-in users only (issue-report verify_jwt), but the row stores no user id, email or IP.
-- Written only by the issue-report edge function (service_role);
-- the zipped logs live in the private issue-reports bucket at storage_path. Kept 14 days.

CREATE TABLE public.issue_reports (
  id                  uuid PRIMARY KEY,
  created_at          timestamptz NOT NULL DEFAULT now(),
  trigger             text NOT NULL CHECK (trigger IN ('shake', 'settings')),
  platform            text NOT NULL CHECK (platform IN ('ios', 'android')),
  app_version         text NOT NULL,
  build               text NOT NULL,
  os_version          text NOT NULL,
  device_model        text NOT NULL,
  locale              text,
  timezone            text,
  description         text NOT NULL DEFAULT '',
  storage_path        text NOT NULL,
  size_bytes          integer NOT NULL
);

CREATE INDEX issue_reports_created_at_idx ON public.issue_reports (created_at DESC);

ALTER TABLE public.issue_reports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.issue_reports FROM anon, authenticated;

COMMENT ON TABLE public.issue_reports IS
  'Anonymous mobile problem reports. service_role only; logs zip in bucket issue-reports at storage_path. Pruned after 14 days by prune_maintenance().';

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('issue-reports', 'issue-reports', false, 5242880, ARRAY['application/zip']);

-- Storage objects can't be deleted from SQL, so expired reports are removed by the issue-report-prune edge function.
-- Returns the pg_net request id, or NULL when nothing is expired (no call made). Checks files too:
-- a zip whose row never landed is only found there.
CREATE FUNCTION public.request_issue_reports_prune(keep_days integer DEFAULT 14) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO 'public', 'net', 'vault'
    AS $$
DECLARE
  v_secret text;
  v_base   text;
  v_req    bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.issue_reports WHERE created_at < now() - make_interval(days => keep_days))
     AND NOT EXISTS (SELECT 1 FROM storage.objects
                     WHERE bucket_id = 'issue-reports' AND created_at < now() - make_interval(days => keep_days)) THEN
    RETURN NULL;
  END IF;
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'bike_sync_webhook_secret' LIMIT 1;
  SELECT decrypted_secret INTO v_base FROM vault.decrypted_secrets WHERE name = 'bike_sync_base_url' LIMIT 1;
  IF v_secret IS NULL OR v_base IS NULL THEN
    RAISE WARNING 'request_issue_reports_prune: bike_sync_webhook_secret or bike_sync_base_url missing from Vault';
    RETURN NULL;
  END IF;
  SELECT net.http_post(
    url     := v_base || '/functions/v1/issue-report-prune',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret),
    body    := jsonb_build_object('keep_days', keep_days),
    timeout_milliseconds := 60000
  ) INTO v_req;
  RETURN v_req;
END;
$$;

ALTER FUNCTION public.request_issue_reports_prune(integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.request_issue_reports_prune(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_issue_reports_prune(integer) TO service_role;

COMMENT ON FUNCTION public.request_issue_reports_prune(integer) IS
  'Asks the issue-report-prune edge function to delete reports older than keep_days with their files. Called by prune_maintenance() and scripts/cron-audit.sh reports prune.';

DROP FUNCTION public.prune_maintenance(integer, integer);

CREATE FUNCTION public.prune_maintenance(
  cache_keep_days   integer DEFAULT 7,
  history_keep_days integer DEFAULT 14,
  reports_keep_days integer DEFAULT 14
) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  cache_rows   bigint;
  history_rows bigint;
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

  -- A failing reports request must not roll back the two deletes above.
  BEGIN
    reports_req := public.request_issue_reports_prune(reports_keep_days);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'prune_maintenance: issue reports request failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'sync_run_cache', cache_rows,
    'cron_history', history_rows,
    'issue_reports_request', reports_req
  );
END;
$$;

ALTER FUNCTION public.prune_maintenance(integer, integer, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.prune_maintenance(integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_maintenance(integer, integer, integer) TO service_role;

COMMENT ON FUNCTION public.prune_maintenance(integer, integer, integer) IS
  'Deletes sync_run_cache of finished runs older than cache_keep_days and cron.job_run_details older than history_keep_days; issue_reports older than reports_keep_days go through request_issue_reports_prune(). Run daily by the db-maintenance-prune cron job.';
