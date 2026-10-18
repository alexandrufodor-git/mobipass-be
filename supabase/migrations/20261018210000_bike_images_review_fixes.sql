-- Code review fixes for the photo queue: a unit whose worker is killed on all 3 tries is failed by
-- the claim (it never reaches complete, so the run could never finish), and a Cloudflare refusal
-- requeues the photo for 10 minutes without using a try (the worker then ends its lane).

CREATE OR REPLACE FUNCTION public.claim_next_bike_image_unit(p_run_id uuid, p_lease_seconds integer DEFAULT 90)
RETURNS public.bike_image_units
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_unit public.bike_image_units;
BEGIN
  -- One lane: a claim within 1.5 s of the last one comes from a duplicate lane, which then ends.
  UPDATE bike_image_runs SET last_claim_at = now()
  WHERE id = p_run_id AND (last_claim_at IS NULL OR last_claim_at < now() - interval '1.5 seconds');
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- A unit whose worker was killed (CPU / memory limit) on all 3 tries never reaches
  -- complete_bike_image_unit: fail it here so the run can finish. A normalized copy stays.
  WITH dead AS (
    UPDATE bike_image_units SET status = 'failed', leased_until = NULL, finished_at = now(),
           error = COALESCE(error, 'worker killed on every try (CPU or memory limit)')
    WHERE run_id = p_run_id AND status = 'running' AND leased_until < now() AND attempts >= 3
    RETURNING source_url
  ), runs AS (
    UPDATE bike_image_runs SET n_failed = n_failed + (SELECT count(*) FROM dead) WHERE id = p_run_id
  )
  INSERT INTO bike_images (source_url, status, url, rule_version)
  SELECT source_url, 'failed', NULL, public.bike_images_rule_version() FROM dead
  ON CONFLICT (source_url) DO UPDATE SET checked_at = now(),
    status = CASE WHEN bike_images.status = 'normalized' THEN 'normalized' ELSE 'failed' END,
    url    = CASE WHEN bike_images.status = 'normalized' THEN bike_images.url ELSE NULL END;

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

  -- The source refused us (Cloudflare 403/429): back off 10 min without using up a try.
  IF p_status = 'throttled' THEN
    UPDATE bike_image_units SET
      status        = 'enqueued',
      attempts      = attempts - 1,
      leased_until  = NULL,
      next_retry_at = now() + interval '10 minutes',
      error         = p_error
    WHERE id = p_unit_id;
    RETURN 'throttled';
  END IF;

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
