-- Bike photo normalisation. Photos the app would crop (tightly framed studio shots) get a copy
-- with even white margins in the public bike-images bucket; every other photo keeps its source
-- URL. bike_models.images stays the feed's source URLs; bikes.images is what the app shows.

INSERT INTO storage.buckets (id, name, public) VALUES ('bike-images', 'bike-images', true)
ON CONFLICT (id) DO NOTHING;

-- One row per source photo: what was decided, the fingerprint it was decided on, and retries.
CREATE TABLE public.bike_images (
  source_url    text PRIMARY KEY,
  status        text NOT NULL CHECK (status IN ('normalized', 'kept', 'failed')),
  url           text CHECK ((status = 'normalized') = (url IS NOT NULL)),
  source_etag   text,
  source_bytes  bigint,
  rule_version  integer NOT NULL,
  checked_at    timestamptz NOT NULL DEFAULT now(),
  attempts      integer NOT NULL DEFAULT 0,
  next_retry_at timestamptz
);

ALTER TABLE public.bike_images ENABLE ROW LEVEL SECURITY; -- service role only

COMMENT ON TABLE public.bike_images IS
  'Bike photo normalisation per source URL: normalized (url = our copy), kept (source shown as is) or failed (retried with backoff). Fingerprint (etag, bytes) and rule_version decide re-processing.';

-- The images the app shows: our copy where one exists, the source otherwise, same order.
CREATE OR REPLACE FUNCTION public.bike_display_images(p_images jsonb) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN p_images IS NULL THEN NULL ELSE COALESCE((
    SELECT jsonb_agg(COALESCE(bi.url, src.value) ORDER BY src.ord)
    FROM jsonb_array_elements_text(p_images) WITH ORDINALITY AS src(value, ord)
    LEFT JOIN public.bike_images bi ON bi.source_url = src.value AND bi.status = 'normalized'
  ), '[]'::jsonb) END
$$;

REVOKE ALL ON FUNCTION public.bike_display_images(jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION "public"."merge_bike_offers"("p_dealer_id" "uuid", "p_models" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  m           jsonb;
  o           jsonb;
  v_model_id  uuid;
  v_offer_ins boolean;
  n_models    integer := 0;
  n_inserted  integer := 0;
  n_updated   integer := 0;
  n_offers    integer := 0;
BEGIN
  FOR m IN SELECT * FROM jsonb_array_elements(p_models)
  LOOP
    INSERT INTO bike_models (
      dealer_id, external_parent_sku, mpn, ean, brand, name, type,
      description, images, raw_specs
    ) VALUES (
      p_dealer_id,
      m->>'external_parent_sku',
      m->>'mpn', m->>'ean', m->>'brand', m->>'name',
      NULLIF(m->>'type', '')::bike_type,
      m->>'description',
      m->'images',
      m->'raw_specs'
    )
    ON CONFLICT (dealer_id, external_parent_sku) DO UPDATE SET
      mpn         = EXCLUDED.mpn,
      ean         = EXCLUDED.ean,
      brand       = EXCLUDED.brand,
      name        = EXCLUDED.name,
      type        = EXCLUDED.type,
      description = EXCLUDED.description,
      images      = EXCLUDED.images,
      raw_specs   = EXCLUDED.raw_specs
      -- in_catalog deliberately preserved — set by the audit branch.
    RETURNING id INTO v_model_id;
    n_models := n_models + 1;

    FOR o IN SELECT * FROM jsonb_array_elements(COALESCE(m->'offers', '[]'::jsonb))
    LOOP
      INSERT INTO bikes (
        name, brand, description, image_url, images, type,
        full_price, list_price, special_price, special_from, special_to,
        in_stock, frame_size, wheel_size, frame_material, power_wh, engine,
        available_for_test, sku, dealer_id, model_id, source, raw_specs,
        active, first_seen_at, last_seen_at, last_in_stock_at
      ) VALUES (
        m->>'name', m->>'brand', m->>'description',
        public.bike_display_images(m->'images')->>0, public.bike_display_images(m->'images'), NULLIF(m->>'type', '')::bike_type,
        COALESCE((o->>'full_price')::numeric, 0),
        (o->>'list_price')::numeric,
        (o->>'special_price')::numeric,
        (o->>'special_from')::timestamptz,
        (o->>'special_to')::timestamptz,
        -- INSERT: a brand-new offer with unknown stock defaults to false.
        COALESCE((o->>'in_stock')::boolean, false),
        o->>'frame_size', o->>'wheel_size', o->>'frame_material',
        (o->>'power_wh')::integer, o->>'engine',
        COALESCE((o->>'available_for_test')::boolean, true),
        o->>'sku', p_dealer_id, v_model_id,
        COALESCE(o->>'source', 'bellabike'),
        o->'raw_specs',
        true, now(), now(),
        CASE WHEN (o->>'in_stock')::boolean IS TRUE THEN now() ELSE NULL END
      )
      ON CONFLICT (dealer_id, sku) DO UPDATE SET
        name               = EXCLUDED.name,
        brand              = EXCLUDED.brand,
        description        = EXCLUDED.description,
        image_url          = EXCLUDED.image_url,
        images             = EXCLUDED.images,
        type               = EXCLUDED.type,
        full_price         = EXCLUDED.full_price,
        list_price         = EXCLUDED.list_price,
        special_price      = EXCLUDED.special_price,
        special_from       = EXCLUDED.special_from,
        special_to         = EXCLUDED.special_to,
        -- UPDATE: unknown stock (null) keeps the existing flag — never forces
        -- false. `o` is in scope, so read the raw nullable value directly
        -- (EXCLUDED.in_stock has already been COALESCEd to false above).
        in_stock           = COALESCE((o->>'in_stock')::boolean, bikes.in_stock),
        frame_size         = EXCLUDED.frame_size,
        wheel_size         = EXCLUDED.wheel_size,
        frame_material     = EXCLUDED.frame_material,
        power_wh           = EXCLUDED.power_wh,
        engine             = EXCLUDED.engine,
        available_for_test = EXCLUDED.available_for_test,
        model_id           = EXCLUDED.model_id,
        source             = EXCLUDED.source,
        raw_specs          = EXCLUDED.raw_specs,
        active             = true,
        delisted_at        = NULL,
        last_seen_at       = now(),
        -- only bump when we actually OBSERVED in-stock this run (null → keep).
        last_in_stock_at   = CASE WHEN (o->>'in_stock')::boolean IS TRUE THEN now()
                                  ELSE bikes.last_in_stock_at END
      RETURNING (xmax::text::bigint = 0) INTO v_offer_ins;

      IF v_offer_ins THEN n_inserted := n_inserted + 1;
      ELSE                n_updated  := n_updated  + 1;
      END IF;
      n_offers := n_offers + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'n_models_upserted', n_models,
    'n_inserted',        n_inserted,
    'n_updated',         n_updated,
    'n_offers',          n_offers
  );
END;
$$;

-- Source photos due for a decision: never seen, decided by an older rule, failed and due a retry,
-- or not checked for 7 days (the edge function then compares the fingerprint before downloading).
-- Photos of in-stock bikes first.
CREATE OR REPLACE FUNCTION public.bike_images_due(p_limit integer, p_rule_version integer)
RETURNS TABLE (source_url text, status text, rule_version integer, source_etag text, source_bytes bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
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
     OR (bi.status = 'failed' AND bi.next_retry_at <= now())
     OR (bi.status <> 'failed' AND bi.checked_at < now() - interval '7 days')
  ORDER BY u.in_stock DESC, bi.checked_at NULLS FIRST
  LIMIT p_limit
$$;

REVOKE ALL ON FUNCTION public.bike_images_due(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bike_images_due(integer, integer) TO service_role;

-- Rewrites bikes.images / image_url for every bike that shows one of these source photos.
CREATE OR REPLACE FUNCTION public.refresh_bike_display_images(p_sources text[]) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  WITH upd AS (
    UPDATE public.bikes b
    SET images = public.bike_display_images(m.images),
        image_url = public.bike_display_images(m.images)->>0
    FROM public.bike_models m
    WHERE b.model_id = m.id AND m.images ?| p_sources
    RETURNING 1
  )
  SELECT count(*)::integer FROM upd
$$;

REVOKE ALL ON FUNCTION public.refresh_bike_display_images(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_bike_display_images(text[]) TO service_role;

-- Fire-and-forget call to the bike-image-normalize edge function, gated by the same Vault webhook
-- secret as bike-sync. Used by the cron (added once verified) and for manual runs.
CREATE OR REPLACE FUNCTION public.bike_images_invoke(p_body jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net', 'vault'
    AS $$
DECLARE
  v_secret text;
  v_base   text;
  v_req    bigint;
BEGIN
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'bike_sync_webhook_secret' LIMIT 1;
  IF v_secret IS NULL THEN
    RAISE WARNING '[bike_images_invoke] Vault secret "bike_sync_webhook_secret" not found';
    RETURN NULL;
  END IF;
  SELECT decrypted_secret INTO v_base FROM vault.decrypted_secrets WHERE name = 'bike_sync_base_url' LIMIT 1;
  v_base := COALESCE(v_base, 'https://xlfkdumbsflqxpezolhl.supabase.co');

  SELECT net.http_post(
    url     := v_base || '/functions/v1/bike-image-normalize',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret),
    body    := p_body,
    timeout_milliseconds := 120000
  ) INTO v_req;
  RETURN v_req;
END;
$$;

REVOKE ALL ON FUNCTION public.bike_images_invoke(jsonb) FROM PUBLIC, anon, authenticated;
