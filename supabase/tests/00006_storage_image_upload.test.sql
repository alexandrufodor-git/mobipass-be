SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: Image upload support — storage buckets, columns, RLS, view, trigger
-- Tests:
--  T01: profiles.profile_image_path column exists
--  T02: companies.logo_image_path column exists
--  T03: avatars bucket exists and is public
--  T04: avatars bucket has correct file_size_limit (2 MB)
--  T05: avatars bucket has correct MIME types
--  T06: company-logos bucket exists and is public
--  T07: company-logos bucket has correct file_size_limit (2 MB)
--  T08: company-logos bucket allows SVG
--  T09: avatars storage RLS policies exist
--  T10: company-logos storage RLS policies exist
--  T11: profile_invites_with_details view includes profile_image_path
--  T12: profile_invites_with_details view includes logo_image_path
--  T13: on_avatar_upload trigger exists on storage.objects
--  T14: avatar upload auto-updates profiles.profile_image_path
-- ============================================================

BEGIN;

SELECT plan(14);

-- ── T01: profiles.profile_image_path column exists ───────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'profiles'
      AND column_name  = 'profile_image_path'
  ),
  'T01: profiles.profile_image_path column exists'
);

-- ── T02: companies.logo_image_path column exists ─────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'companies'
      AND column_name  = 'logo_image_path'
  ),
  'T02: companies.logo_image_path column exists'
);

-- ── T03: avatars bucket exists and is public ─────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM storage.buckets
    WHERE id     = 'avatars'
      AND public = true
  ),
  'T03: avatars bucket exists and is public'
);

-- ── T04: avatars bucket has 2 MB file size limit ─────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM storage.buckets
    WHERE id              = 'avatars'
      AND file_size_limit = 2097152
  ),
  'T04: avatars bucket has 2 MB file size limit'
);

-- ── T05: avatars bucket allows jpeg, png, webp ───────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM storage.buckets
    WHERE id                = 'avatars'
      AND allowed_mime_types @> ARRAY['image/jpeg', 'image/png', 'image/webp']
  ),
  'T05: avatars bucket allows image/jpeg, image/png, image/webp'
);

-- ── T06: company-logos bucket exists and is public ───────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM storage.buckets
    WHERE id     = 'company-logos'
      AND public = true
  ),
  'T06: company-logos bucket exists and is public'
);

-- ── T07: company-logos bucket has 2 MB file size limit ───────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM storage.buckets
    WHERE id              = 'company-logos'
      AND file_size_limit = 2097152
  ),
  'T07: company-logos bucket has 2 MB file size limit'
);

-- ── T08: company-logos bucket allows SVG ─────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM storage.buckets
    WHERE id                = 'company-logos'
      AND allowed_mime_types @> ARRAY['image/svg+xml']
  ),
  'T08: company-logos bucket allows image/svg+xml'
);

-- ── T09: avatars storage RLS policies exist ──────────────────────────────
SELECT ok(
  (
    SELECT COUNT(*) FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename  = 'objects'
      AND policyname IN (
        'avatars_public_select',
        'avatars_owner_insert',
        'avatars_owner_update',
        'avatars_owner_delete'
      )
  ) = 4,
  'T09: all 4 avatars storage RLS policies exist'
);

-- ── T10: company-logos storage RLS policies exist ────────────────────────
SELECT ok(
  (
    SELECT COUNT(*) FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename  = 'objects'
      AND policyname IN (
        'company_logos_public_select',
        'company_logos_hr_insert',
        'company_logos_hr_update',
        'company_logos_hr_delete'
      )
  ) = 4,
  'T10: all 4 company-logos storage RLS policies exist'
);

-- ── T11: profile_invites_with_details view includes profile_image_path ───
SELECT ok(
  EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'profile_invites_with_details'
      AND column_name  = 'profile_image_path'
  ),
  'T11: profile_invites_with_details view includes profile_image_path'
);

-- ── T12: profile_invites_with_details view includes logo_image_path ──────
SELECT ok(
  EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'profile_invites_with_details'
      AND column_name  = 'logo_image_path'
  ),
  'T12: profile_invites_with_details view includes logo_image_path'
);

-- ── T13: on_avatar_upload trigger exists on storage.objects ──────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM information_schema.triggers
    WHERE event_object_schema = 'storage'
      AND event_object_table  = 'objects'
      AND trigger_name        = 'on_avatar_upload'
  ),
  'T13: on_avatar_upload trigger exists on storage.objects'
);

-- ── T14: avatar upload auto-updates profiles.profile_image_path ──────────
DO $$
DECLARE
  v_user_id uuid := gen_random_uuid();
  v_co_id   uuid;
BEGIN
  INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
  VALUES ('storage-co-' || gen_random_uuid()::text, 100.00, 12, 'EUR', 'storage-' || gen_random_uuid()::text || '.test') RETURNING id INTO v_co_id;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  VALUES (v_user_id, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'trigger-test@test.local', '', now(), now(), '', '', '', '');

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_user_id, 'trigger-test@test.local', v_co_id, 'active', 'Trigger', 'Test');

  PERFORM set_config('test.trigger_user_id', v_user_id::text, false);
END;
$$;

-- Simulate a storage upload by inserting into storage.objects
INSERT INTO storage.objects (id, bucket_id, name, owner, created_at, updated_at, last_accessed_at, metadata)
VALUES (
  gen_random_uuid(),
  'avatars',
  current_setting('test.trigger_user_id'),
  current_setting('test.trigger_user_id')::uuid,
  now(), now(), now(),
  '{}'::jsonb
);

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.profiles
    WHERE user_id           = current_setting('test.trigger_user_id')::uuid
      AND profile_image_path = current_setting('test.trigger_user_id')
  ),
  'T14: avatar upload auto-updates profiles.profile_image_path via trigger'
);

SELECT * FROM finish();
ROLLBACK;
