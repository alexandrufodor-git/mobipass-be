-- Per-platform minimum supported app version for the mobile update gate.
-- Read by the app with the anon key; written only by service_role (scripts/app-config.sh).

CREATE TABLE public.app_config (
  platform    text PRIMARY KEY CHECK (platform IN ('ios', 'android')),
  min_version text NOT NULL CHECK (min_version ~ '^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$'),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE public.app_config FROM anon, authenticated;
GRANT SELECT ON TABLE public.app_config TO anon, authenticated;

CREATE TRIGGER update_app_config_updated_at
  BEFORE UPDATE ON public.app_config
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY app_config_select ON public.app_config
  FOR SELECT TO anon, authenticated USING (true);

INSERT INTO public.app_config (platform, min_version) VALUES
  ('ios', '1.0.0'),
  ('android', '1.0.0');
