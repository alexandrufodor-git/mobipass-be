SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: supabase_realtime publication membership
--
-- Guards the set of tables exposed over Realtime `postgres_changes`. Membership
-- is otherwise invisible at the SQL layer and was historically set by hand in
-- the dashboard (bike_benefits + profiles), which drifted out of the migrations
-- and silently killed FE benefit-change subscriptions on any migration-built DB.
-- Migration 20260628000001 codifies the manual adds; this test pins the contract.
--
--  R01 bike_benefits published   R02 profiles published
--  R03 company_metrics published R04 company_notifications published
-- ============================================================

BEGIN;

SELECT plan(4);

SELECT ok(
  EXISTS (SELECT 1 FROM pg_publication_tables
          WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'bike_benefits'),
  'R01: bike_benefits is in the supabase_realtime publication');

SELECT ok(
  EXISTS (SELECT 1 FROM pg_publication_tables
          WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'profiles'),
  'R02: profiles is in the supabase_realtime publication');

SELECT ok(
  EXISTS (SELECT 1 FROM pg_publication_tables
          WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'company_metrics'),
  'R03: company_metrics is in the supabase_realtime publication');

SELECT ok(
  EXISTS (SELECT 1 FROM pg_publication_tables
          WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'company_notifications'),
  'R04: company_notifications is in the supabase_realtime publication');

SELECT * FROM finish();
ROLLBACK;
