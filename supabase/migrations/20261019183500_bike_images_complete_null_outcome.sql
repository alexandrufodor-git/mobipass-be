-- A unit failing on its last try has no outcome: (NULL = 'normalized')::int is NULL, which broke the
-- run counters' NOT NULL and errored the worker (the claim's dead-unit sweep failed it 90 s later).

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
    n_normalized     = n_normalized + (p_outcome IS NOT DISTINCT FROM 'normalized')::int,
    n_kept           = n_kept       + (p_outcome IS NOT DISTINCT FROM 'kept')::int,
    n_unchanged      = n_unchanged  + (p_outcome IS NOT DISTINCT FROM 'unchanged')::int,
    n_failed         = n_failed     + (p_status = 'failed')::int,
    bytes_downloaded = bytes_downloaded + p_bytes_downloaded,
    bytes_stored     = bytes_stored + p_bytes_stored
  WHERE id = v_run_id;

  RETURN p_status;
END;
$$;
