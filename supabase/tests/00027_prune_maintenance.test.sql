SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: public.prune_maintenance() — daily db-maintenance-prune job
--
--  T01 cache of a finished run older than 7 days is deleted
--  T02 cache of a finished run from yesterday is kept
--  T03 cache of a still-running old run is kept (the sync reads it)
--  T04 the sync_runs rows themselves are kept (run telemetry)
--  T05 authenticated can't execute it
--  T06 the cron job is scheduled daily at 04:00 UTC
--  T07 no issue_reports request when nothing is expired
--  T08 issue_reports: anon/authenticated have no access
--  T09 issue-reports bucket is private
--  T10 anon/authenticated can't execute request_issue_reports_prune
-- ============================================================

BEGIN;
SELECT plan(10);

DO $$
DECLARE
  v_dealer uuid;
  v_old    uuid;
  v_recent uuid;
  v_live   uuid;
BEGIN
  INSERT INTO public.dealers (name) VALUES ('prune-dealer-' || gen_random_uuid()::text) RETURNING id INTO v_dealer;

  INSERT INTO public.sync_runs (dealer_id, mode, status, started_at)
  VALUES (v_dealer, 'daily', 'succeeded', now() - interval '10 days') RETURNING id INTO v_old;
  INSERT INTO public.sync_runs (dealer_id, mode, status, started_at)
  VALUES (v_dealer, 'daily', 'succeeded', now() - interval '1 day') RETURNING id INTO v_recent;
  INSERT INTO public.sync_runs (dealer_id, mode, status, started_at)
  VALUES (v_dealer, 'weekly', 'running', now() - interval '10 days') RETURNING id INTO v_live;

  INSERT INTO public.sync_run_cache (run_id, scope, payload) VALUES
    (v_old, 'option_maps', '{}'), (v_recent, 'option_maps', '{}'), (v_live, 'option_maps', '{}');

  PERFORM set_config('test.old',    v_old::text,    false);
  PERFORM set_config('test.recent', v_recent::text, false);
  PERFORM set_config('test.live',   v_live::text,   false);
END;
$$;

SELECT public.prune_maintenance();

SELECT is(
  (SELECT count(*)::int FROM public.sync_run_cache WHERE run_id = current_setting('test.old')::uuid),
  0, 'T01: old finished run cache deleted'
);
SELECT is(
  (SELECT count(*)::int FROM public.sync_run_cache WHERE run_id = current_setting('test.recent')::uuid),
  1, 'T02: recent run cache kept'
);
SELECT is(
  (SELECT count(*)::int FROM public.sync_run_cache WHERE run_id = current_setting('test.live')::uuid),
  1, 'T03: running run cache kept'
);
SELECT is(
  (SELECT count(*)::int FROM public.sync_runs WHERE id = current_setting('test.old')::uuid),
  1, 'T04: sync_runs row kept'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.prune_maintenance(integer, integer, integer)', 'execute'),
  'T05: authenticated cannot execute'
);
SELECT is(
  (SELECT schedule FROM cron.job WHERE jobname = 'db-maintenance-prune'),
  '0 4 * * *', 'T06: scheduled daily at 04:00 UTC'
);

SELECT is(
  public.prune_maintenance() -> 'issue_reports_request',
  'null'::jsonb, 'T07: no prune request without expired reports'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.issue_reports', 'select')
  AND NOT has_table_privilege('authenticated', 'public.issue_reports', 'insert'),
  'T08: issue_reports is service_role only'
);
SELECT is(
  (SELECT public FROM storage.buckets WHERE id = 'issue-reports'),
  false, 'T09: issue-reports bucket is private'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.request_issue_reports_prune(integer)', 'execute')
  AND NOT has_function_privilege('authenticated', 'public.request_issue_reports_prune(integer)', 'execute'),
  'T10: request_issue_reports_prune is not callable by anon/authenticated'
);

SELECT * FROM finish();
ROLLBACK;
