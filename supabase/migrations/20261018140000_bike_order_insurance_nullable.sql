-- Insurance is unknown until it's chosen: null shows the empty value in the app instead of a fake "No".
ALTER TABLE public.bike_orders
  ALTER COLUMN insurance DROP DEFAULT,
  ALTER COLUMN insurance DROP NOT NULL;
