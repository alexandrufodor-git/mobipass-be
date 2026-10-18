-- Bike photo normalisation as a lease-based queue, 1:1 with the bike sync: a nightly kickoff
-- seeds one unit per due photo, every worker call claims ONE unit (lease + SKIP LOCKED), processes
-- it and fires the next; bike_images_tick re-fires the lane and re-claims expired leases, so a
-- worker killed by the 2s CPU limit can't stall the run. Replaces the 10-photos-per-call cron.

SELECT cron.unschedule('bike-images-tick');

-- Bump in a migration when the normalisation rule or its output changes: every photo decided
-- by an older version is due again.
CREATE OR REPLACE FUNCTION public.bike_images_rule_version() RETURNS integer
    LANGUAGE sql IMMUTABLE AS $$ SELECT 1 $$;

-- Retries now live on the units; a photo that failed all its tries is due again next night.
ALTER TABLE public.bike_images DROP COLUMN attempts, DROP COLUMN next_retry_at;

CREATE OR REPLACE FUNCTION "public"."bike_images_due"("p_limit" integer, "p_rule_version" integer) RETURNS TABLE("source_url" "text", "status" "text", "rule_version" integer, "source_etag" "text", "source_bytes" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT u.url, bi.status, bi.rule_version, bi.source_etag, bi.source_bytes
  FROM (
    SELECT DISTINCT ON (src.url) src.url, b.in_stock
    FROM public.bikes b
    JOIN public.bike_models m ON m.id = b.model_id
    CROSS JOIN LATERAL jsonb_array_elements_text(m.images) AS src(url)
    WHERE b.active
    ORDER BY src.url, b.in_stock DESC
  ) u
  LEFT JOIN public.bike_images bi ON bi.source_url = u.url
  WHERE bi.source_url IS NULL
     OR bi.rule_version < p_rule_version
     OR bi.status = 'failed'
     OR (bi.status <> 'failed' AND bi.checked_at < now() - interval '7 days')
  ORDER BY u.in_stock DESC, bi.checked_at NULLS FIRST
  LIMIT p_limit
$$;

DROP TABLE public.bike_image_runs; -- per-call log, empty: replaced by run + units below

CREATE TABLE public.bike_image_runs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mode             text NOT NULL CHECK (mode IN ('nightly', 'manual')),
  status           text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
  rule_version     integer NOT NULL,
  started_at       timestamptz NOT NULL DEFAULT now(),
  finished_at      timestamptz,
  n_units          integer NOT NULL DEFAULT 0,
  n_normalized     integer NOT NULL DEFAULT 0,
  n_kept           integer NOT NULL DEFAULT 0,
  n_unchanged      integer NOT NULL DEFAULT 0,
  n_failed         integer NOT NULL DEFAULT 0,
  bytes_downloaded bigint NOT NULL DEFAULT 0,
  bytes_stored     bigint NOT NULL DEFAULT 0
);

CREATE TABLE public.bike_image_units (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id           uuid NOT NULL REFERENCES public.bike_image_runs (id) ON DELETE CASCADE,
  source_url       text NOT NULL,
  status           text NOT NULL DEFAULT 'enqueued' CHECK (status IN ('enqueued', 'running', 'succeeded', 'failed')),
  outcome          text CHECK (outcome IN ('normalized', 'kept', 'unchanged')),
  attempts         integer NOT NULL DEFAULT 0,
  next_retry_at    timestamptz,
  leased_until     timestamptz,
  started_at       timestamptz,
  finished_at      timestamptz,
  bytes_downloaded bigint NOT NULL DEFAULT 0,
  bytes_stored     bigint NOT NULL DEFAULT 0,
  error            text,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX bike_image_runs_started_at_idx ON public.bike_image_runs (started_at DESC);
CREATE INDEX bike_image_units_run_status_idx ON public.bike_image_units (run_id, status);
ALTER TABLE public.bike_image_runs ENABLE ROW LEVEL SECURITY;  -- service role only
ALTER TABLE public.bike_image_units ENABLE ROW LEVEL SECURITY; -- service role only

COMMENT ON TABLE public.bike_image_runs IS
  'One bike photo normalisation run (nightly or manual): unit counts by outcome, bytes, status. Pruned with the cron history; units cascade.';
COMMENT ON TABLE public.bike_image_units IS
  'One source photo in a run: lease, attempts (3, then failed), outcome, bytes, error.';

-- Seed a run with one unit per due photo and fire the first worker. A run already in progress
-- is returned instead, so a manual kickoff can't double the lane.
CREATE OR REPLACE FUNCTION public.bike_images_kickoff(p_mode text DEFAULT 'manual') RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_run_id uuid;
  v_units  integer;
BEGIN
  SELECT id INTO v_run_id FROM bike_image_runs WHERE status = 'running' LIMIT 1;
  IF v_run_id IS NOT NULL THEN
    RETURN v_run_id;
  END IF;

  INSERT INTO bike_image_runs (mode, rule_version)
  VALUES (p_mode, public.bike_images_rule_version())
  RETURNING id INTO v_run_id;

  INSERT INTO bike_image_units (run_id, source_url)
  SELECT v_run_id, d.source_url FROM public.bike_images_due(1000000, public.bike_images_rule_version()) d;
  GET DIAGNOSTICS v_units = ROW_COUNT;

  UPDATE bike_image_runs SET n_units = v_units WHERE id = v_run_id;
  IF v_units = 0 THEN
    PERFORM public.finalize_bike_image_run(v_run_id);
  ELSE
    PERFORM public.bike_images_invoke(jsonb_build_object('run_id', v_run_id));
  END IF;
  RETURN v_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_next_bike_image_unit(p_run_id uuid, p_lease_seconds integer DEFAULT 90)
RETURNS public.bike_image_units
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_unit public.bike_image_units;
BEGIN
  UPDATE bike_image_units SET
    status       = 'running',
    attempts     = attempts + 1,
    started_at   = COALESCE(started_at, now()),
    leased_until = now() + (p_lease_seconds * interval '1 second')
  WHERE id = (
    SELECT id FROM bike_image_units
    WHERE run_id = p_run_id
      AND (   (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
           OR (status = 'running'  AND leased_until IS NOT NULL AND leased_until < now()))
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING * INTO v_unit;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN v_unit;
END;
$$;

-- 'retry' (back to the queue), or the final status. Final units add to the run's counts.
CREATE OR REPLACE FUNCTION public.complete_bike_image_unit(
  p_unit_id uuid, p_status text, p_outcome text DEFAULT NULL,
  p_bytes_downloaded bigint DEFAULT 0, p_bytes_stored bigint DEFAULT 0, p_error text DEFAULT NULL
) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_attempts integer;
  v_run_id   uuid;
BEGIN
  SELECT attempts, run_id INTO v_attempts, v_run_id FROM bike_image_units WHERE id = p_unit_id;

  IF p_status = 'failed' AND v_attempts < 3 THEN
    UPDATE bike_image_units SET
      status        = 'enqueued',
      leased_until  = NULL,
      next_retry_at = now() + (v_attempts * interval '20 seconds'),
      error         = p_error
    WHERE id = p_unit_id;
    RETURN 'retry';
  END IF;

  UPDATE bike_image_units SET
    status           = p_status,
    outcome          = p_outcome,
    leased_until     = NULL,
    bytes_downloaded = p_bytes_downloaded,
    bytes_stored     = p_bytes_stored,
    error            = p_error,
    finished_at      = now()
  WHERE id = p_unit_id;

  UPDATE bike_image_runs SET
    n_normalized     = n_normalized + (p_outcome = 'normalized')::int,
    n_kept           = n_kept       + (p_outcome = 'kept')::int,
    n_unchanged      = n_unchanged  + (p_outcome = 'unchanged')::int,
    n_failed         = n_failed     + (p_status = 'failed')::int,
    bytes_downloaded = bytes_downloaded + p_bytes_downloaded,
    bytes_stored     = bytes_stored + p_bytes_stored
  WHERE id = v_run_id;

  RETURN p_status;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_bike_image_run(p_run_id uuid) RETURNS public.bike_image_runs
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_succeeded integer;
  v_failed    integer;
  v_pending   integer;
  v_run       public.bike_image_runs;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'succeeded'),
         count(*) FILTER (WHERE status = 'failed'),
         count(*) FILTER (WHERE status IN ('enqueued', 'running'))
    INTO v_succeeded, v_failed, v_pending
    FROM bike_image_units WHERE run_id = p_run_id;

  IF v_pending > 0 THEN
    SELECT * INTO v_run FROM bike_image_runs WHERE id = p_run_id;
    RETURN v_run;
  END IF;

  UPDATE bike_image_runs SET
    status = CASE WHEN v_failed = 0 THEN 'succeeded' WHEN v_succeeded = 0 THEN 'failed' ELSE 'partial' END,
    finished_at = now()
  WHERE id = p_run_id
  RETURNING * INTO v_run;
  RETURN v_run;
END;
$$;

-- pg_cron heartbeat, 1:1 with bike_sync_tick: keeps the single lane alive (re-fires after a
-- killed worker once its lease expires) and finalizes drained runs.
CREATE OR REPLACE FUNCTION public.bike_images_tick() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  c_max_lanes constant integer := 1;  -- one photo at a time: bellabike.ro is behind Cloudflare
  r           record;
  v_inflight  integer;
  v_claimable integer;
  v_waiting   integer;
  v_fired     integer := 0;
BEGIN
  FOR r IN SELECT id FROM bike_image_runs WHERE status = 'running' LOOP
    SELECT count(*) INTO v_inflight FROM bike_image_units
      WHERE run_id = r.id AND status = 'running' AND leased_until >= now();
    SELECT count(*) INTO v_claimable FROM bike_image_units
      WHERE run_id = r.id
        AND (   (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
             OR (status = 'running'  AND leased_until < now()));
    SELECT count(*) INTO v_waiting FROM bike_image_units
      WHERE run_id = r.id AND status = 'enqueued' AND next_retry_at > now();

    IF v_inflight < c_max_lanes AND v_claimable > 0 THEN
      PERFORM public.bike_images_invoke(jsonb_build_object('run_id', r.id));
      v_fired := v_fired + 1;
    ELSIF v_inflight = 0 AND v_claimable = 0 AND v_waiting = 0 THEN
      PERFORM public.finalize_bike_image_run(r.id);
    END IF;
  END LOOP;
  RETURN v_fired;
END;
$$;

REVOKE ALL ON FUNCTION public.bike_images_kickoff(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_next_bike_image_unit(uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_bike_image_unit(uuid, text, text, bigint, bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_bike_image_run(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bike_images_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_next_bike_image_unit(uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_bike_image_unit(uuid, text, text, bigint, bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_bike_image_run(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.bike_images_invoke(jsonb) TO service_role;

SELECT cron.schedule('bike-images-tick', '* * * * *', $cron$ SELECT public.bike_images_tick(); $cron$);
-- After the nightly bike sync (02:00 UTC): new photos, failed ones, 7-day rechecks, rule bumps.
SELECT cron.schedule('bike-images-nightly', '0 4 * * *', $cron$ SELECT public.bike_images_kickoff('nightly'); $cron$);

-- To pause:
--   SELECT cron.unschedule('bike-images-nightly'); SELECT cron.unschedule('bike-images-tick');
