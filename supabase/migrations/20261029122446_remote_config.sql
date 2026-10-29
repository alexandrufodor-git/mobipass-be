-- Key/value app settings shared by every platform, read by logged-in users only; edit the row, no release.

CREATE TABLE public.remote_config (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE public.remote_config FROM anon, authenticated;
GRANT SELECT ON TABLE public.remote_config TO authenticated;

CREATE TRIGGER update_remote_config_updated_at
  BEFORE UPDATE ON public.remote_config
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.remote_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY remote_config_select ON public.remote_config
  FOR SELECT TO authenticated USING (true);

COMMENT ON TABLE public.remote_config IS
  'App settings shared by iOS and Android. catalog_title_*_words: lowercase words dropped from catalog card titles.';

INSERT INTO public.remote_config (key, value) VALUES
  ('catalog_title_generic_words', '["bicicleta", "bicicletă", "electrica", "electrică", "e-bike", "ebike", "oras", "oraș", "trekking", "mtb", "full", "suspension", "hardtail"]'),
  ('catalog_title_color_words', '["negru", "neagra", "neagră", "alb", "alba", "albă", "gri", "rosu", "roșu", "rosie", "roșie", "albastru", "albastra", "albastră", "verde", "galben", "portocaliu", "maro", "argintiu", "auriu", "roz", "mov", "bej", "turcoaz", "antracit"]');
