-- Bike details Addons card shows the company's insurer and helmet brand. Plain strings for now.

ALTER TABLE public.companies
  ADD COLUMN insurance_provider text,
  ADD COLUMN helmet_provider    text;

COMMENT ON COLUMN public.companies.insurance_provider IS 'Insurer shown under Addons → Insurance on bike details, e.g. Generali. Null hides the name.';
COMMENT ON COLUMN public.companies.helmet_provider    IS 'Helmet brand shown under Addons → Helmet on bike details, e.g. Giro. Null hides the name.';
