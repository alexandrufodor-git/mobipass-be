-- Rule v2: a bike touching the visible edge counts as cut (the card's rounded corners clip it),
-- WebP sources are decoded, and margins take the photo's own studio colour. Every photo decided by
-- v1 is due again.
CREATE OR REPLACE FUNCTION public.bike_images_rule_version() RETURNS integer
    LANGUAGE sql IMMUTABLE AS $$ SELECT 2 $$;
