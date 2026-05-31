SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: REGES employee bridge
-- Tests:
--   Schema:
--     T01: companies.email_domain column exists, nullable
--     T02: companies_email_domain_unique partial unique blocks duplicate
--     T03: companies.email_pattern column exists, type email_pattern_kind
--     T04: profile_invites.email is nullable
--     T05: profile_invites_email_unique partial unique works
--     T06: profile_invites has source, source_ref_id, birth_date_hash,
--          derived_email, radiat columns
--     T07: profile_invites_source_unique blocks duplicate (company_id,
--          source, source_ref_id)
--     T08: idx_profile_invites_pending_dob index exists
--     T09: idx_profile_invites_derived_email index exists
--     T10: idx_profile_invites_name_trgm index exists
--     T11: pg_trgm extension installed
--     T12: employee_pii_source_unique blocks duplicate
--     T13: employee_pii.profile_invite_id FK exists
--   Trigger backfill:
--     T14: handle_user_registration backfills employee_pii.user_id when
--          profile_invite has linked pending PII
--     T15: trigger is a no-op when no linked pending PII exists
--          (CSV-only flow regression)
--     T16: trigger does not overwrite an already-linked employee_pii.user_id
--   match_pending_invite RPC:
--     T17: exact name + DOB → first_score = 1.0
--     T18: asymmetric REGES "andreea-mihaela" + user "andreea" → 0.95
--     T19: asymmetric reverse REGES "andreea" + user "andreea mihaela" → 0.95
--     T20: token-match REGES "andreea-mihaela" + user "mihaela" → 0.90
--     T21: excludes rows where email IS NOT NULL (claimed)
--     T22: scoped by company_id (no cross-company leakage)
--     T23: email_derived_match=true when derived_email matches
--   ingest_reges_batch RPC:
--     T24: empty array returns '[]'
--     T25: 3 new records → 3 invites + 3 PII + 3 audit rows
--     T26: re-running same payload → pii_status='updated' on every row
--     T27: claimed invite row → invite_status='skipped_claimed'
--     T28: radiat false→true on claimed row fires reges_terminated notification
--     T29: bad record raises (transactional rollback contract)
-- ============================================================

BEGIN;

-- ── Fixtures ───────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co_a    uuid;
  v_co_b    uuid;
  v_hr_a    uuid := gen_random_uuid();
BEGIN
  -- Companies with REGES configuration
  INSERT INTO public.companies (
    name, monthly_benefit_subsidy, contract_months, currency,
    email_domain, email_pattern
  ) VALUES (
    'reges-co-a-' || gen_random_uuid()::text, 80.00, 36, 'RON',
    'reges-a-' || (extract(epoch from clock_timestamp())::bigint) || '.com',
    'first_last'::public.email_pattern_kind
  ) RETURNING id INTO v_co_a;

  INSERT INTO public.companies (
    name, monthly_benefit_subsidy, contract_months, currency,
    email_domain
  ) VALUES (
    'reges-co-b-' || gen_random_uuid()::text, 80.00, 36, 'RON',
    'reges-b-' || (extract(epoch from clock_timestamp())::bigint) || '.com'
  ) RETURNING id INTO v_co_b;

  -- HR user in co_a (used by RLS tests in 00010; here we don't need RLS roles
  -- because the RPC functions are SECURITY DEFINER).
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_hr_a, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated',
    'reges-hr-' || gen_random_uuid()::text || '@test.local',
    '', now(), now(), '', '', '', ''
  );

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (v_hr_a, 'reges-hr@test.local', v_co_a, 'active', 'HR', 'A');

  INSERT INTO public.user_roles (user_id, role) VALUES (v_hr_a, 'hr'::public.user_role);

  PERFORM set_config('test.co_a_id',  v_co_a::text, false);
  PERFORM set_config('test.co_b_id',  v_co_b::text, false);
  PERFORM set_config('test.hr_a_id',  v_hr_a::text, false);
END;
$$;

SELECT plan(31);

-- ============================================================
-- Schema assertions
-- ============================================================

-- ── T01: companies.email_domain exists, nullable ────────────────────────────
SELECT col_is_null(
  'public', 'companies', 'email_domain',
  'T01: companies.email_domain is nullable'
);

-- ── T02: partial unique on lower(email_domain) ──────────────────────────────
DO $$
DECLARE
  v_co_x uuid;
  v_co_y uuid;
BEGIN
  INSERT INTO public.companies (
    name, monthly_benefit_subsidy, contract_months, currency, email_domain
  ) VALUES ('t02-x-' || gen_random_uuid()::text, 1, 12, 'RON', 'dup-domain-t02.example')
  RETURNING id INTO v_co_x;
  PERFORM set_config('test.t02_co_x', v_co_x::text, false);
END;
$$;

SELECT throws_ok(
  $$INSERT INTO public.companies (name, monthly_benefit_subsidy, contract_months, currency, email_domain)
    VALUES ('t02-y-dup', 1, 12, 'RON', 'DUP-DOMAIN-T02.example')$$,
  '23505',
  NULL,
  'T02: companies_email_domain_unique blocks duplicate domain (case-insensitive)'
);

-- ── T03: companies.email_pattern email_pattern_kind ─────────────────────────
SELECT col_type_is(
  'public', 'companies', 'email_pattern', 'email_pattern_kind',
  'T03: companies.email_pattern is email_pattern_kind enum'
);

-- ── T04: profile_invites.email nullable ─────────────────────────────────────
SELECT col_is_null(
  'public', 'profile_invites', 'email',
  'T04: profile_invites.email is nullable'
);

-- ── T05: profile_invites_email_unique partial unique works ──────────────────
DO $$
DECLARE
  v_co_a uuid := current_setting('test.co_a_id')::uuid;
BEGIN
  -- Two NULL-email rows must coexist
  INSERT INTO public.profile_invites (company_id, email, first_name, last_name, source, source_ref_id)
  VALUES (v_co_a, NULL, 'T05a', 'NullA', 'reges', 't05-ref-a');
  INSERT INTO public.profile_invites (company_id, email, first_name, last_name, source, source_ref_id)
  VALUES (v_co_a, NULL, 'T05b', 'NullB', 'reges', 't05-ref-b');

  -- One claimed row with email
  INSERT INTO public.profile_invites (company_id, email, first_name, last_name)
  VALUES (v_co_a, 't05-claim@example.com', 'T05c', 'Claim');
END;
$$;

SELECT throws_ok(
  $$INSERT INTO public.profile_invites (company_id, email, first_name, last_name)
    VALUES ((SELECT current_setting('test.co_a_id'))::uuid, 'T05-CLAIM@example.com', 'Dup', 'Dup')$$,
  '23505',
  NULL,
  'T05: profile_invites_email_unique blocks duplicate non-NULL email (case-insensitive)'
);

-- ── T06: profile_invites has all new columns ───────────────────────────────
SELECT columns_are(
  'public'::name,
  'profile_invites'::name,
  ARRAY[
    'email','status','created_at','company_id','id','user_id',
    'first_name','last_name','description','department','hire_date',
    'source','source_ref_id','birth_date_hash','derived_email','radiat'
  ]::name[],
  'T06: profile_invites has source, source_ref_id, birth_date_hash, derived_email, radiat'
);

-- ── T07: profile_invites_source_unique ──────────────────────────────────────
SELECT throws_ok(
  $$INSERT INTO public.profile_invites (company_id, first_name, last_name, source, source_ref_id)
    VALUES ((SELECT current_setting('test.co_a_id'))::uuid, 'Dup', 'Dup', 'reges', 't05-ref-a')$$,
  '23505',
  NULL,
  'T07: (company_id, source, source_ref_id) unique on profile_invites'
);

-- ── T08-T10: partial indexes exist ─────────────────────────────────────────
SELECT has_index(
  'public', 'profile_invites', 'idx_profile_invites_pending_dob',
  'T08: idx_profile_invites_pending_dob exists'
);
SELECT has_index(
  'public', 'profile_invites', 'idx_profile_invites_derived_email',
  'T09: idx_profile_invites_derived_email exists'
);
SELECT has_index(
  'public', 'profile_invites', 'idx_profile_invites_name_trgm',
  'T10: idx_profile_invites_name_trgm exists'
);

-- ── T11: pg_trgm extension installed ────────────────────────────────────────
SELECT ok(
  EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'),
  'T11: pg_trgm extension installed'
);

-- ── T12: employee_pii_source_unique ────────────────────────────────────────
DO $$
DECLARE
  v_co_a uuid := current_setting('test.co_a_id')::uuid;
BEGIN
  INSERT INTO public.employee_pii (user_id, company_id, source, source_ref_id)
  VALUES (NULL, v_co_a, 'reges', 't12-ref');
END;
$$;

SELECT throws_ok(
  $$INSERT INTO public.employee_pii (user_id, company_id, source, source_ref_id)
    VALUES (NULL, (SELECT current_setting('test.co_a_id'))::uuid, 'reges', 't12-ref')$$,
  '23505',
  NULL,
  'T12: employee_pii_source_unique blocks duplicate (company_id, source, source_ref_id)'
);

-- ── T13: profile_invite_id FK exists ───────────────────────────────────────
SELECT ok(
  EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conname = 'employee_pii_profile_invite_id_fkey'
      AND contype = 'f'
  ),
  'T13: employee_pii.profile_invite_id FK exists'
);

-- ============================================================
-- Trigger backfill (handle_user_registration)
-- ============================================================

-- ── T14: trigger backfills employee_pii.user_id on claim ───────────────────
DO $$
DECLARE
  v_co_a    uuid := current_setting('test.co_a_id')::uuid;
  v_invite  uuid;
  v_pii     uuid;
  v_user    uuid := gen_random_uuid();
  v_email   text := 't14-' || gen_random_uuid()::text || '@test.local';
BEGIN
  -- Pending REGES invite with linked PII (email NULL = not yet claimed)
  INSERT INTO public.profile_invites (company_id, first_name, last_name, source, source_ref_id)
  VALUES (v_co_a, 'T14First', 'T14Last', 'reges', 't14-ref')
  RETURNING id INTO v_invite;

  INSERT INTO public.employee_pii (
    user_id, company_id, source, source_ref_id, profile_invite_id
  ) VALUES (NULL, v_co_a, 'reges', 't14-ref', v_invite)
  RETURNING id INTO v_pii;

  -- Simulate the HR "claim by email" step: set the invite's email so the
  -- trigger's lookup-by-email finds it.
  UPDATE public.profile_invites SET email = v_email WHERE id = v_invite;

  -- Create an auth.users row; trigger fires on INSERT with email_confirmed_at
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_user, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_email, '',
    now(), now(), now(), '', '', '', ''
  );

  PERFORM set_config('test.t14_user', v_user::text, false);
  PERFORM set_config('test.t14_pii',  v_pii::text,  false);
END;
$$;

SELECT is(
  (SELECT user_id FROM public.employee_pii WHERE id = current_setting('test.t14_pii')::uuid),
  current_setting('test.t14_user')::uuid,
  'T14: trigger backfills employee_pii.user_id when invite has linked pending PII'
);

-- ── T15: trigger is no-op for CSV-only flow (no linked PII) ────────────────
DO $$
DECLARE
  v_co_a    uuid := current_setting('test.co_a_id')::uuid;
  v_user    uuid := gen_random_uuid();
  v_email   text := 't15-' || gen_random_uuid()::text || '@test.local';
BEGIN
  -- CSV-style invite: email present at creation, no associated employee_pii.
  INSERT INTO public.profile_invites (company_id, email, first_name, last_name)
  VALUES (v_co_a, v_email, 'T15First', 'T15Last');

  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_user, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_email, '',
    now(), now(), now(), '', '', '', ''
  );

  PERFORM set_config('test.t15_user', v_user::text, false);
END;
$$;

SELECT ok(
  NOT EXISTS(
    SELECT 1 FROM public.employee_pii
    WHERE user_id = current_setting('test.t15_user')::uuid
  ),
  'T15: CSV-only flow leaves employee_pii untouched (no spurious row)'
);

-- ── T16: trigger does not overwrite already-linked user_id ─────────────────
DO $$
DECLARE
  v_co_a        uuid := current_setting('test.co_a_id')::uuid;
  v_invite      uuid;
  v_pii         uuid;
  v_first_user  uuid := gen_random_uuid();
  v_second_user uuid := gen_random_uuid();
  v_email       text := 't16-' || gen_random_uuid()::text || '@test.local';
BEGIN
  -- v_first_user: auth.users row without email_confirmed_at, so the
  -- registration trigger does NOT fire on this insert. We then manually
  -- link a profile + employee_pii to simulate a previously-claimed state.
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_first_user, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated',
    't16-prev-' || gen_random_uuid()::text || '@test.local', '',
    now(), now(), '', '', '', ''
  );

  INSERT INTO public.profiles (user_id, email, company_id, status, first_name, last_name)
  VALUES (
    v_first_user,
    (SELECT email FROM auth.users WHERE id = v_first_user),
    v_co_a, 'active', 'PrevFirst', 'PrevLast'
  );

  -- Pending invite already linked to v_first_user via employee_pii.
  INSERT INTO public.profile_invites (company_id, email, first_name, last_name, source, source_ref_id)
  VALUES (v_co_a, v_email, 'T16First', 'T16Last', 'reges', 't16-ref')
  RETURNING id INTO v_invite;

  INSERT INTO public.employee_pii (
    user_id, company_id, source, source_ref_id, profile_invite_id
  ) VALUES (v_first_user, v_co_a, 'reges', 't16-ref', v_invite)
  RETURNING id INTO v_pii;

  -- Now v_second_user registers with the invite's email. The trigger fires,
  -- step 4.5 attempts to backfill employee_pii.user_id but the WHERE clause
  -- (user_id IS NULL) matches zero rows because v_first_user already owns it.
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_second_user, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', v_email, '',
    now(), now(), now(), '', '', '', ''
  );

  PERFORM set_config('test.t16_pii',         v_pii::text,        false);
  PERFORM set_config('test.t16_first_user',  v_first_user::text, false);
END;
$$;

SELECT is(
  (SELECT user_id FROM public.employee_pii WHERE id = current_setting('test.t16_pii')::uuid),
  current_setting('test.t16_first_user')::uuid,
  'T16: trigger does not overwrite an already-linked employee_pii.user_id'
);

-- ============================================================
-- match_pending_invite RPC
-- ============================================================

-- Shared fixture: pending REGES invites in co_a with known hashes/names.
DO $$
DECLARE
  v_co_a    uuid := current_setting('test.co_a_id')::uuid;
  v_co_b    uuid := current_setting('test.co_b_id')::uuid;
BEGIN
  -- Compound first name + DOB hash + derived email
  INSERT INTO public.profile_invites (
    company_id, first_name, last_name, source, source_ref_id,
    birth_date_hash, derived_email
  ) VALUES (
    v_co_a, 'andreea-mihaela', 'pop', 'reges', 't-mp-compound',
    'hash-dob-1', 'andreea.pop@reges-a.example'
  );

  -- Single first name (for reverse-asymmetry test)
  INSERT INTO public.profile_invites (
    company_id, first_name, last_name, source, source_ref_id,
    birth_date_hash
  ) VALUES (
    v_co_a, 'andreea', 'ionescu', 'reges', 't-mp-single',
    'hash-dob-2'
  );

  -- Claimed (email present) — should be excluded
  INSERT INTO public.profile_invites (
    company_id, email, first_name, last_name, source, source_ref_id,
    birth_date_hash
  ) VALUES (
    v_co_a, 't-mp-claimed@example.com', 'claimed', 'ghita', 'reges', 't-mp-claimed',
    'hash-dob-claimed'
  );

  -- Other company — should be excluded by company_id scope
  INSERT INTO public.profile_invites (
    company_id, first_name, last_name, source, source_ref_id,
    birth_date_hash
  ) VALUES (
    v_co_b, 'cross', 'company', 'reges', 't-mp-crossco',
    'hash-dob-crossco'
  );
END;
$$;

-- ── T17: exact match → first_score = 1.0 ───────────────────────────────────
SELECT is(
  (SELECT first_score::numeric FROM public.match_pending_invite(
     current_setting('test.co_a_id')::uuid,
     'hash-dob-2',           -- matches the single-name row
     'andreea',
     'ionescu',
     'unused@example.com'
   ) LIMIT 1),
  1.0::numeric,
  'T17: exact-name match → first_score = 1.0'
);

-- ── T18: asymmetric — user "andreea" vs REGES "andreea-mihaela" → 0.95 ─────
SELECT is(
  (SELECT first_score::numeric FROM public.match_pending_invite(
     current_setting('test.co_a_id')::uuid,
     'hash-dob-1',
     'andreea',
     'pop',
     'unused@example.com'
   ) LIMIT 1),
  0.95::numeric,
  'T18: asymmetric prefix REGES compound vs user single token → 0.95'
);

-- ── T19: asymmetric reverse — user "andreea mihaela" vs REGES "andreea" ─────
SELECT is(
  (SELECT first_score::numeric FROM public.match_pending_invite(
     current_setting('test.co_a_id')::uuid,
     'hash-dob-2',
     'andreea mihaela',
     'ionescu',
     'unused@example.com'
   ) LIMIT 1),
  0.95::numeric,
  'T19: asymmetric reverse user compound vs REGES single token → 0.95'
);

-- ── T20: token-match — user "mihaela" vs REGES "andreea-mihaela" → 0.90 ─────
SELECT is(
  (SELECT first_score::numeric FROM public.match_pending_invite(
     current_setting('test.co_a_id')::uuid,
     'hash-dob-1',
     'mihaela',
     'pop',
     'unused@example.com'
   ) LIMIT 1),
  0.90::numeric,
  'T20: token-match REGES compound contains user token → 0.90'
);

-- ── T21: excludes claimed (email IS NOT NULL) ──────────────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.co_a_id')::uuid,
     'hash-dob-claimed',
     'claimed',
     'ghita',
     'unused@example.com'
   )),
  0,
  'T21: match_pending_invite excludes rows where email IS NOT NULL'
);

-- ── T22: scoped by company_id ──────────────────────────────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.co_a_id')::uuid,
     'hash-dob-crossco',  -- exists in co_b only
     'cross',
     'company',
     'unused@example.com'
   )),
  0,
  'T22: match_pending_invite is scoped to the given company_id'
);

-- ── T23: derived_email match ──────────────────────────────────────────────
SELECT is(
  (SELECT email_derived_match FROM public.match_pending_invite(
     current_setting('test.co_a_id')::uuid,
     'no-match-hash',
     'andreea',
     'pop',
     'andreea.pop@reges-a.example'
   ) LIMIT 1),
  true,
  'T23: match_pending_invite returns email_derived_match=true on derived_email hit'
);

-- ============================================================
-- ingest_reges_batch RPC
-- ============================================================

-- ── T24: empty array → empty result ────────────────────────────────────────
SELECT is(
  public.ingest_reges_batch(current_setting('test.co_a_id')::uuid, '[]'::jsonb),
  '[]'::jsonb,
  'T24: ingest_reges_batch on empty array returns empty result'
);

-- ── T25: 3 new records → 3 invites + 3 PII + 3 audit rows ──────────────────
DO $$
DECLARE
  v_co_a       uuid := current_setting('test.co_a_id')::uuid;
  v_result     jsonb;
  v_payload    jsonb := jsonb_build_array(
    jsonb_build_object(
      'source_ref_id',           't25-a',
      'first_name',              'TwentyfiveA',
      'last_name',               'Surname',
      'birth_date_hash',         't25-hash-a',
      'derived_email',           'twentyfivea.surname@reges-a.example',
      'radiat',                  false,
      'national_id_encrypted',   'enc:v1:fake-cnp-a',
      'home_address_encrypted',  'enc:v1:fake-addr-a',
      'date_of_birth_encrypted', 'enc:v1:fake-dob-a',
      'locality_code',           '54984',
      'locality_code_system',    'siruta',
      'nationality_iso',         'RO',
      'country_of_domicile_iso', 'RO',
      'id_document_type',        'national_id_card'
    ),
    jsonb_build_object(
      'source_ref_id',           't25-b',
      'first_name',              'TwentyfiveB',
      'last_name',               'Surname',
      'birth_date_hash',         't25-hash-b',
      'derived_email',           NULL,
      'radiat',                  false,
      'national_id_encrypted',   'enc:v1:fake-cnp-b',
      'home_address_encrypted',  NULL,
      'date_of_birth_encrypted', 'enc:v1:fake-dob-b',
      'locality_code',           NULL,
      'locality_code_system',    NULL,
      'nationality_iso',         'RO',
      'country_of_domicile_iso', 'RO',
      'id_document_type',        'national_id_card'
    ),
    jsonb_build_object(
      'source_ref_id',           't25-c',
      'first_name',              'TwentyfiveC',
      'last_name',               'Surname',
      'birth_date_hash',         't25-hash-c',
      'derived_email',           NULL,
      'radiat',                  false,
      'national_id_encrypted',   'enc:v1:fake-cnp-c',
      'home_address_encrypted',  NULL,
      'date_of_birth_encrypted', 'enc:v1:fake-dob-c',
      'locality_code',           NULL,
      'locality_code_system',    NULL,
      'nationality_iso',         'RO',
      'country_of_domicile_iso', 'RO',
      'id_document_type',        'national_id_card'
    )
  );
BEGIN
  v_result := public.ingest_reges_batch(v_co_a, v_payload);
  PERFORM set_config('test.t25_result',  v_result::text, false);
  PERFORM set_config('test.t25_payload', v_payload::text, false);
END;
$$;

SELECT is(
  (SELECT count(*)::int FROM public.profile_invites
    WHERE company_id = current_setting('test.co_a_id')::uuid
      AND source = 'reges'
      AND source_ref_id LIKE 't25-%'),
  3,
  'T25a: ingest created 3 profile_invites rows'
);

SELECT is(
  (SELECT count(*)::int FROM public.employee_pii
    WHERE company_id = current_setting('test.co_a_id')::uuid
      AND source = 'reges'
      AND source_ref_id LIKE 't25-%'),
  3,
  'T25b: ingest created 3 employee_pii rows'
);

SELECT is(
  (SELECT count(*)::int FROM public.integration_messages
    WHERE company_id = current_setting('test.co_a_id')::uuid
      AND integration = 'reges'
      AND operation = 'import_employee'
      AND (result_payload->>'source_ref_id') LIKE 't25-%'),
  3,
  'T25c: ingest wrote 3 integration_messages audit rows'
);

-- ── T26: re-running same payload → pii_status='updated' for every row ───────
DO $$
DECLARE
  v_co_a    uuid := current_setting('test.co_a_id')::uuid;
  v_payload jsonb := current_setting('test.t25_payload')::jsonb;
  v_result  jsonb;
BEGIN
  v_result := public.ingest_reges_batch(v_co_a, v_payload);
  PERFORM set_config('test.t26_result', v_result::text, false);
END;
$$;

SELECT is(
  (SELECT count(*)::int
     FROM jsonb_array_elements(current_setting('test.t26_result')::jsonb) r
    WHERE r->>'status' = 'updated'),
  3,
  'T26: re-running same payload → 3 PII rows with status=updated'
);

-- ── T27: claimed invite row → invite_status='skipped_claimed' ──────────────
DO $$
DECLARE
  v_co_a    uuid := current_setting('test.co_a_id')::uuid;
  v_payload jsonb;
  v_result  jsonb;
BEGIN
  -- Manually claim t25-a so the next ingest finds email IS NOT NULL.
  UPDATE public.profile_invites
     SET email = 't27-claim@example.com'
   WHERE company_id = v_co_a
     AND source = 'reges'
     AND source_ref_id = 't25-a';

  v_payload := jsonb_build_array(
    jsonb_build_object(
      'source_ref_id',           't25-a',
      'first_name',              'NewFirst',
      'last_name',               'NewLast',
      'birth_date_hash',         't25-hash-a',
      'derived_email',           NULL,
      'radiat',                  false,
      'national_id_encrypted',   'enc:v1:overwrite-attempt',
      'home_address_encrypted',  NULL,
      'date_of_birth_encrypted', 'enc:v1:overwrite-attempt',
      'locality_code',           NULL,
      'locality_code_system',    NULL,
      'nationality_iso',         'RO',
      'country_of_domicile_iso', 'RO',
      'id_document_type',        'national_id_card'
    )
  );
  v_result := public.ingest_reges_batch(v_co_a, v_payload);
  PERFORM set_config('test.t27_result', v_result::text, false);
END;
$$;

SELECT is(
  (current_setting('test.t27_result')::jsonb)->0->>'invite_status',
  'skipped_claimed',
  'T27: claimed invite → invite_status=skipped_claimed (no PII overwrite)'
);

-- ── T28: radiat false→true on claimed row fires reges_terminated event ─────
DO $$
DECLARE
  v_co_a    uuid := current_setting('test.co_a_id')::uuid;
  v_payload jsonb;
BEGIN
  v_payload := jsonb_build_array(
    jsonb_build_object(
      'source_ref_id',           't25-a',
      'first_name',              'NewFirst',
      'last_name',               'NewLast',
      'birth_date_hash',         't25-hash-a',
      'derived_email',           NULL,
      'radiat',                  true,  -- the transition
      'national_id_encrypted',   'enc:v1:overwrite-attempt',
      'home_address_encrypted',  NULL,
      'date_of_birth_encrypted', 'enc:v1:overwrite-attempt',
      'locality_code',           NULL,
      'locality_code_system',    NULL,
      'nationality_iso',         'RO',
      'country_of_domicile_iso', 'RO',
      'id_document_type',        'national_id_card'
    )
  );
  PERFORM public.ingest_reges_batch(v_co_a, v_payload);
END;
$$;

SELECT ok(
  EXISTS(
    SELECT 1 FROM public.company_notifications
    WHERE company_id = current_setting('test.co_a_id')::uuid
      AND event_type = 'reges_terminated'
  ),
  'T28: radiat false→true on claimed row inserts reges_terminated notification'
);

-- ── T29: bad record raises (transactional rollback contract) ───────────────
-- A record missing first_name (NULL) violates profile_invites.first_name NOT NULL.
SELECT throws_ok(
  $$SELECT public.ingest_reges_batch(
      (SELECT current_setting('test.co_a_id'))::uuid,
      jsonb_build_array(
        jsonb_build_object(
          'source_ref_id', 't29-bad',
          'first_name',    NULL,
          'last_name',     'OnlyLast',
          'birth_date_hash', 'h',
          'radiat', false
        )
      )
    )$$,
  '23502',  -- not_null_violation
  NULL,
  'T29: ingest_reges_batch raises NOT NULL violation on missing required field (transactional contract)'
);

SELECT * FROM finish();
ROLLBACK;
