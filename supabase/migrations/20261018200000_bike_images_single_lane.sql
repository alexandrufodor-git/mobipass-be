-- One lane for real: the tick fired a new lane in the gap between a worker finishing and its
-- successor claiming, so lanes piled up (4 seen). Claims now stamp the run; a second claim within
-- 1.5 s is refused (that lane ends), and the tick only re-fires a lane silent for 30 s.
ALTER TABLE public.bike_image_runs ADD COLUMN last_claim_at timestamptz;

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
  FOR r IN SELECT id, last_claim_at FROM bike_image_runs WHERE status = 'running' LOOP
    SELECT count(*) INTO v_inflight FROM bike_image_units
      WHERE run_id = r.id AND status = 'running' AND leased_until >= now();
    SELECT count(*) INTO v_claimable FROM bike_image_units
      WHERE run_id = r.id
        AND (   (status = 'enqueued' AND (next_retry_at IS NULL OR next_retry_at <= now()))
             OR (status = 'running'  AND leased_until < now()));
    SELECT count(*) INTO v_waiting FROM bike_image_units
      WHERE run_id = r.id AND status = 'enqueued' AND next_retry_at > now();

    -- Re-fire only a dead lane: no claim for 30 s (a live lane claims every ~3 s).
    IF v_inflight < c_max_lanes AND v_claimable > 0
       AND (r.last_claim_at IS NULL OR r.last_claim_at < now() - interval '30 seconds') THEN
      PERFORM public.bike_images_invoke(jsonb_build_object('run_id', r.id));
      v_fired := v_fired + 1;
    ELSIF v_inflight = 0 AND v_claimable = 0 AND v_waiting = 0 THEN
      PERFORM public.finalize_bike_image_run(r.id);
    END IF;
  END LOOP;
  RETURN v_fired;
END;
$$;
