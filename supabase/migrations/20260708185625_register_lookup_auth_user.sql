-- Service-role lookup used by the `register` edge function to detect a stale
-- orphaned auth account before it sends an OTP.
--
-- Background: onboarding (public.handle_user_registration) only runs on an
-- auth.users INSERT or the first email_confirmed_at NULL→non-NULL transition.
-- An auth account that was created + confirmed under an earlier flow, but whose
-- public-side profile was later cleared, is "orphaned": it can log in via OTP
-- but never re-fires onboarding, so it has a session with no profile/role. The
-- register function deletes such an account (admin API) before sending the OTP
-- so the OTP-verify creates a fresh row that fires the trigger.
--
-- This function is the detection primitive: given an email, return the auth
-- user id (if any) and whether a profile already hangs off it. "No profile" is
-- the orphan signal — an orphan has zero app-side data, so deleting it is safe.
--
-- Reading auth.users requires elevated rights, hence SECURITY DEFINER owned by
-- postgres (same pattern as public.current_user_has_password). Unlike that
-- self-scoped function, this one takes an arbitrary email and would be an
-- "does this address have an account?" oracle if exposed — so it is granted to
-- service_role ONLY (REVOKE from PUBLIC; no anon/authenticated grant). It is
-- never called from a client, only from the register function's service key.

CREATE OR REPLACE FUNCTION "public"."lookup_auth_user"("p_email" "text")
    RETURNS TABLE ("user_id" "uuid", "has_profile" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT
    u.id,
    EXISTS (SELECT 1 FROM "public"."profiles" p WHERE p."user_id" = u.id)
  FROM "auth"."users" u
  WHERE lower(u.email) = lower("p_email")
  LIMIT 1;
$$;

ALTER FUNCTION "public"."lookup_auth_user"("text") OWNER TO "postgres";

-- Revoke PUBLIC *and* the anon/authenticated roles explicitly: Supabase's
-- default privileges grant EXECUTE on new public functions to anon/authenticated
-- directly, so a bare `REVOKE ... FROM PUBLIC` would leave them able to call it
-- (and turn it into an account-existence oracle). service_role only.
REVOKE ALL ON FUNCTION "public"."lookup_auth_user"("text") FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION "public"."lookup_auth_user"("text") TO "service_role";

COMMENT ON FUNCTION "public"."lookup_auth_user"("text") IS 'Service-role only. Given an email, returns the auth.users id and whether a profile exists for it. Used by the register edge function to detect + reset a stale orphaned auth account (auth row with no profile) before sending an OTP. SECURITY DEFINER; granted to service_role only (would be an account-existence oracle if exposed to anon/authenticated).';
