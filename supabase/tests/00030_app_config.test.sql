SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: public.app_config — update-gate minimum versions
--
--  T01-T02 anon / authenticated hold SELECT only
--  T03-T08 anon / authenticated INSERT, UPDATE, DELETE denied
--  T09     seed rows ios/android = 1.0.0
--  T10     anon can read the seed rows through RLS
--  T11     min_version check rejects a malformed version
--  T12     platform check rejects an unknown platform
--  T13     min_version check rejects a 5-digit segment
--  T14     RLS is enabled
--  T15     only the app_config_select policy exists
--  T15b-c  that policy is FOR SELECT TO anon, authenticated
--  T16     UPDATE bumps updated_at
--  T17     min_version check rejects non-ASCII digits
-- ============================================================

BEGIN;
SELECT plan(19);

SELECT table_privs_are('public', 'app_config', 'anon', ARRAY['SELECT'], 'T01: anon has SELECT only');
SELECT table_privs_are('public', 'app_config', 'authenticated', ARRAY['SELECT'], 'T02: authenticated has SELECT only');

SET LOCAL ROLE anon;
SELECT throws_ok($$INSERT INTO public.app_config (platform, min_version) VALUES ('ios', '9.9.9')$$, '42501', NULL, 'T03: anon INSERT denied');
SELECT throws_ok($$UPDATE public.app_config SET min_version = '9.9.9'$$, '42501', NULL, 'T04: anon UPDATE denied');
SELECT throws_ok($$DELETE FROM public.app_config$$, '42501', NULL, 'T05: anon DELETE denied');
SELECT results_eq(
  $$SELECT platform, min_version FROM public.app_config ORDER BY platform$$,
  $$VALUES ('android'::text, '1.0.0'::text), ('ios', '1.0.0')$$,
  'T10: anon reads the seed rows');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT throws_ok($$INSERT INTO public.app_config (platform, min_version) VALUES ('ios', '9.9.9')$$, '42501', NULL, 'T06: authenticated INSERT denied');
SELECT throws_ok($$UPDATE public.app_config SET min_version = '9.9.9'$$, '42501', NULL, 'T07: authenticated UPDATE denied');
SELECT throws_ok($$DELETE FROM public.app_config$$, '42501', NULL, 'T08: authenticated DELETE denied');
RESET ROLE;

SELECT set_eq(
  $$SELECT platform, min_version FROM public.app_config$$,
  $$VALUES ('ios'::text, '1.0.0'::text), ('android', '1.0.0')$$,
  'T09: seed rows present');

SELECT throws_ok($$UPDATE public.app_config SET min_version = '1.2.3-beta' WHERE platform = 'ios'$$, '23514', NULL, 'T11: malformed min_version rejected');
SELECT throws_ok($$INSERT INTO public.app_config (platform, min_version) VALUES ('web', '1.0.0')$$, '23514', NULL, 'T12: unknown platform rejected');

SELECT throws_ok($$UPDATE public.app_config SET min_version = '10000.0.0' WHERE platform = 'ios'$$, '23514', NULL, 'T13: 5-digit segment rejected');

SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.app_config'::regclass), 'T14: RLS enabled');
SELECT policies_are('public', 'app_config', ARRAY['app_config_select'], 'T15: only app_config_select policy');
SELECT policy_cmd_is('public', 'app_config', 'app_config_select', 'select', 'T15b: policy is FOR SELECT');
SELECT policy_roles_are('public', 'app_config', 'app_config_select', ARRAY['anon', 'authenticated'], 'T15c: policy is TO anon, authenticated');

ALTER TABLE public.app_config DISABLE TRIGGER update_app_config_updated_at;
UPDATE public.app_config SET updated_at = '2000-01-01' WHERE platform = 'ios';
ALTER TABLE public.app_config ENABLE TRIGGER update_app_config_updated_at;
UPDATE public.app_config SET min_version = '1.0.1' WHERE platform = 'ios';
SELECT ok((SELECT updated_at > '2000-01-01' FROM public.app_config WHERE platform = 'ios'), 'T16: UPDATE bumps updated_at');

SELECT throws_ok($$UPDATE public.app_config SET min_version = '１.0' WHERE platform = 'ios'$$, '23514', NULL, 'T17: non-ASCII digits rejected');

SELECT * FROM finish();
ROLLBACK;
