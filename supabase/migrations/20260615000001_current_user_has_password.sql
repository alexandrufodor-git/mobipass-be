-- Lets a signed-in user check whether they have a password set, without exposing the hash.
-- Mobile uses this after Google SSO to skip the optional "set a password" screen for
-- returning users who already have one (GoTrue never exposes encrypted_password to clients,
-- and the identities/JWT are not a reliable signal — an OTP user who skipped password setup
-- still has an `email` identity but no password).
--
-- Reading auth.users requires elevated rights, hence SECURITY DEFINER owned by postgres.
-- Security rests on the in-body auth.uid() self-scope: a caller can only ever learn a single
-- boolean about their OWN account — same guard pattern as get_my_role / promote_sso_claim.
-- (Supabase default privileges also grant EXECUTE to anon/service_role; harmless here since
-- they carry no auth.uid() and always get false. We still REVOKE the PUBLIC grant and grant
-- authenticated explicitly.) Reads auth.users live, so it stays correct even though setting a
-- password via PUT /auth/v1/user fires no trigger — there is no denormalised flag to drift.

CREATE OR REPLACE FUNCTION "public"."current_user_has_password"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM "auth"."users"
    WHERE "id" = "auth"."uid"()
      AND "encrypted_password" IS NOT NULL
      AND length("encrypted_password") > 0
  );
$$;

ALTER FUNCTION "public"."current_user_has_password"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "public"."current_user_has_password"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."current_user_has_password"() TO "authenticated";

COMMENT ON FUNCTION "public"."current_user_has_password"() IS 'True if the calling user (auth.uid()) has a password set in auth.users. SECURITY DEFINER, self-scoped, returns only a boolean — never exposes the hash. Mobile uses it to skip the optional password-setup screen after Google SSO.';
