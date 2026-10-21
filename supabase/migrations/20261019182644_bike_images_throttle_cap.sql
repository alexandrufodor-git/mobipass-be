-- A photo whose source keeps answering as if throttled (any 403/429 we read as Cloudflare) is
-- requeued at most 3 times without using a try; after that a throttle counts as a failed try, so a
-- run can't hang on one photo.

ALTER TABLE public.bike_image_units ADD COLUMN throttles integer NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.finish_bike_image_unit(
  p_unit_id uuid, p_attempts integer, p_status text, p_outcome text DEFAULT NULL,
  p_url text DEFAULT NULL, p_etag text DEFAULT NULL, p_source_bytes bigint DEFAULT NULL,
  p_bytes_downloaded bigint DEFAULT 0, p_bytes_stored bigint DEFAULT 0, p_error text DEFAULT NULL
) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_source    text;
  v_throttles integer;
  v_rule   integer := public.bike_images_rule_version();
  v_result text;
BEGIN
  SELECT source_url, throttles INTO v_source, v_throttles FROM bike_image_units
  WHERE id = p_unit_id AND status = 'running' AND attempts = p_attempts
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 'stale';
  END IF;

  -- A source that keeps refusing us uses up tries after 3 throttles, so the run always finishes.
  IF p_status = 'throttled' AND v_throttles >= 3 THEN
    p_status := 'failed';
    p_error  := 'throttled 3 times: ' || COALESCE(p_error, '');
  ELSIF p_status = 'throttled' THEN
    UPDATE bike_image_units SET throttles = throttles + 1 WHERE id = p_unit_id;
  END IF;

  IF p_status = 'succeeded' AND p_outcome = 'unchanged' THEN
    UPDATE bike_images SET checked_at = now() WHERE source_url = v_source;
  ELSIF p_status = 'succeeded' THEN
    INSERT INTO bike_images (source_url, status, url, source_etag, source_bytes, rule_version, checked_at)
    VALUES (v_source, p_outcome, p_url, p_etag, p_source_bytes, v_rule, now())
    ON CONFLICT (source_url) DO UPDATE SET
      status = EXCLUDED.status, url = EXCLUDED.url, source_etag = EXCLUDED.source_etag,
      source_bytes = EXCLUDED.source_bytes, rule_version = EXCLUDED.rule_version, checked_at = now();
    PERFORM public.refresh_bike_display_images(ARRAY[v_source]);
  END IF;

  v_result := public.complete_bike_image_unit(
    p_unit_id, p_status, p_outcome, COALESCE(p_bytes_downloaded, 0), COALESCE(p_bytes_stored, 0), p_error
  );

  -- Out of tries: the app keeps the source, or an earlier copy; due again next night.
  IF v_result = 'failed' THEN
    INSERT INTO bike_images (source_url, status, url, rule_version)
    VALUES (v_source, 'failed', NULL, v_rule)
    ON CONFLICT (source_url) DO UPDATE SET checked_at = now(),
      status       = CASE WHEN bike_images.status = 'normalized' THEN 'normalized' ELSE 'failed' END,
      url          = CASE WHEN bike_images.status = 'normalized' THEN bike_images.url ELSE NULL END,
      rule_version = CASE WHEN bike_images.status = 'normalized' THEN bike_images.rule_version ELSE EXCLUDED.rule_version END;
  END IF;

  RETURN v_result;
END;
$$;

