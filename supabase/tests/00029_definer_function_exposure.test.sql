SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: no SECURITY DEFINER function in public is callable by anon/authenticated
-- through /rest/v1/rpc unless it is on the allowlist below (each checks auth.uid()/jwt
-- itself). Postgres grants EXECUTE to PUBLIC on every new function, so a new
-- SECURITY DEFINER function fails here until its migration revokes it or it's added below.
-- Trigger functions are skipped: PostgREST can't call them.
--
--  T01 anon can execute only allowlisted definer functions
--  T02 authenticated can execute only allowlisted definer functions
--  T03 get_vault_secret is service_role only
-- ============================================================

BEGIN;
SELECT plan(3);

CREATE TEMP TABLE allowed(name text);
INSERT INTO allowed VALUES
  ('auth_company_id'), ('authorize'), ('current_user_has_password'), ('get_company_metrics'),
  ('get_my_company_user_ids'), ('get_my_role'), ('promote_sso_claim');

CREATE TEMP VIEW exposed AS
  SELECT r.role, p.proname
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated')) r(role)
  WHERE n.nspname = 'public'
    AND p.prosecdef
    AND pg_get_function_result(p.oid) <> 'trigger'
    AND has_function_privilege(r.role, p.oid, 'execute')
    AND p.proname NOT IN (SELECT name FROM allowed);

SELECT is_empty('SELECT proname FROM exposed WHERE role = ''anon''', 'T01: anon reaches no unlisted definer function');
SELECT is_empty('SELECT proname FROM exposed WHERE role = ''authenticated''', 'T02: authenticated reaches no unlisted definer function');

SELECT ok(
  NOT has_function_privilege('anon', 'public.get_vault_secret(text)', 'execute')
  AND NOT has_function_privilege('authenticated', 'public.get_vault_secret(text)', 'execute')
  AND has_function_privilege('service_role', 'public.get_vault_secret(text)', 'execute'),
  'T03: get_vault_secret is service_role only'
);

SELECT * FROM finish();
ROLLBACK;
