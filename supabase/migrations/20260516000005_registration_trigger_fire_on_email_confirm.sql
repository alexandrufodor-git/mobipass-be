-- Fix: handle_user_registration must fire on OTP / magic-link confirmation,
-- not only on password-based signup.
--
-- The original triggers (from 20260303000002 / 20260128080000) gated on
-- `encrypted_password` being set or changed. In Supabase Auth's OTP flow
-- the encrypted_password column is set to a placeholder hash at user
-- creation and never changes, so the UPDATE trigger's "password changed"
-- WHEN clause was never satisfied on /auth/v1/verify. Result: profile,
-- user_roles, bike_benefits, and (post-REGES) employee_pii backfill never
-- happen automatically — pgTAP `00004_registration_trigger` documents the
-- workaround in a comment.
--
-- This migration re-arms both triggers to fire when `email_confirmed_at`
-- transitions from NULL → non-NULL. That's the real "user just confirmed"
-- event and is the only signal we actually need. Behaviour is unchanged
-- for password signups (the INSERT case still fires on the same condition
-- and the UPDATE case still fires when confirmation happens). Adds OTP
-- coverage as a strict superset.

-- INSERT trigger: unchanged condition. Seed data deliberately sets
-- encrypted_password=NULL to skip this trigger, so we preserve that escape
-- hatch. Real Supabase Auth password signups have both fields set at INSERT
-- time and still fire here.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
WHEN (
  NEW.email_confirmed_at IS NOT NULL
  AND NEW.encrypted_password IS NOT NULL
)
EXECUTE FUNCTION public.handle_user_registration();

-- UPDATE trigger: NEW behaviour. Fires when email_confirmed_at transitions
-- from NULL to non-NULL — the real "user just confirmed" event. This is the
-- only signal we need; previous condition gated on encrypted_password
-- changing, which never happens in an OTP-only signup flow.
DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;
CREATE TRIGGER on_auth_user_updated
AFTER UPDATE ON auth.users
FOR EACH ROW
WHEN (
  NEW.email_confirmed_at IS NOT NULL
  AND OLD.email_confirmed_at IS DISTINCT FROM NEW.email_confirmed_at
)
EXECUTE FUNCTION public.handle_user_registration();
