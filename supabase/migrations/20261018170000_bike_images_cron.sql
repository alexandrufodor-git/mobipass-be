-- Bike photo normalisation runs alongside the nightly sync: every 5 minutes the edge function takes
-- the next 10 due photos (new ones after a sync, retries, 7-day rechecks) and returns at once when
-- none are due. The decision logic and RULE_VERSION live in the function, not here.
SELECT cron.schedule(
  'bike-images-tick',
  '*/5 * * * *',
  $cron$ SELECT public.bike_images_invoke('{"limit": 10}'::jsonb); $cron$
);

-- To pause:
--   SELECT cron.unschedule('bike-images-tick');
