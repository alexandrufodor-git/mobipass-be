-- Realtime: codify the manual dashboard adds of bike_benefits + profiles.
--
-- These two tables were toggled into the `supabase_realtime` publication by hand
-- in the prod dashboard early on, and that membership was never captured as a
-- migration. Result: any DB rebuilt purely from migrations (local, preview /
-- branch envs, a fresh prod restore) has them ABSENT from the publication, so
-- `postgres_changes` subscriptions on bike_benefits / profiles never fire — the
-- "benefit changes no longer signaled to the FE" regression.
--
-- This makes migrations 1:1 with prod. Idempotent: a guarded ADD so it is a
-- no-op in prod (where they are already members) and only does work where the
-- manual add is missing. Replica identity is intentionally left at the prod
-- default (PK) — schema.sql shows no REPLICA IDENTITY FULL on these, so we match.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bike_benefits', 'profiles'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END
$$;
