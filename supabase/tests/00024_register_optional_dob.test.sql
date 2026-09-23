SET search_path TO extensions, public;

-- ============================================================
-- pgTAP: match_pending_invite with NO date of birth
--
-- Apple guideline 5.1.1(v) requires date of birth to be optional at
-- registration. /register therefore has to be able to call this RPC with a
-- NULL dob hash. These tests pin what that does, so a future edit to the
-- WHERE clause cannot silently break the no-DOB path.
--
--   N01: NULL dob hash still returns the derived-email candidate
--   N02: ...with email_derived_match = true
--   N03: ...with dob_matched = NULL (register/index.ts relies on JS falsiness)
--   N04: ...with name sub-scores still computed
--   N05: NULL dob hash excludes rows that only ever matched on DOB
--   N06: NULL dob hash still excludes claimed invites (email IS NOT NULL)
--   N07: NULL dob hash is still scoped by company_id
--   N08: two invites sharing a derived_email are ambiguous without DOB
--   N09: ...and DOB is what separates them
-- ============================================================

BEGIN;

-- ── Fixtures ───────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_co_a uuid;
  v_co_b uuid;
  v_dom_a text := 'dob-a-' || (extract(epoch from clock_timestamp())::bigint) || '.example';
BEGIN
  INSERT INTO public.companies (
    name, monthly_benefit_subsidy, contract_months, currency, email_domain
  ) VALUES (
    'dob-co-a-' || gen_random_uuid()::text, 80.00, 36, 'RON', v_dom_a
  ) RETURNING id INTO v_co_a;

  INSERT INTO public.companies (
    name, monthly_benefit_subsidy, contract_months, currency, email_domain
  ) VALUES (
    'dob-co-b-' || gen_random_uuid()::text, 80.00, 36, 'RON',
    'dob-b-' || (extract(epoch from clock_timestamp())::bigint) || '.example'
  ) RETURNING id INTO v_co_b;

  -- The happy path: a pending invite whose derived_email is what the user types.
  INSERT INTO public.profile_invites (
    company_id, first_name, last_name, source, source_ref_id,
    birth_date_hash, derived_email
  ) VALUES (
    v_co_a, 'ion', 'popescu', 'reges', 't-dob-derived',
    'hash-dob-derived', 'ion.popescu@dob-a.example'
  );

  -- DOB-only row: a different derived_email, so it can only ever enter the
  -- candidate set via the birth_date_hash branch.
  INSERT INTO public.profile_invites (
    company_id, first_name, last_name, source, source_ref_id,
    birth_date_hash, derived_email
  ) VALUES (
    v_co_a, 'maria', 'ionescu', 'reges', 't-dob-only',
    'hash-dob-only', 'maria.ionescu@dob-a.example'
  );

  -- Already claimed (email IS NOT NULL) — must never be returned.
  INSERT INTO public.profile_invites (
    company_id, email, first_name, last_name, source, source_ref_id,
    birth_date_hash, derived_email
  ) VALUES (
    -- email must match the company domain (enforce_email_matches_company_domain)
    v_co_a, 'claimed@' || v_dom_a, 'vlad', 'stan', 'reges', 't-dob-claimed',
    'hash-dob-claimed', 'vlad.stan@dob-a.example'
  );

  -- Cross-company row with the same derived_email as the happy path.
  INSERT INTO public.profile_invites (
    company_id, first_name, last_name, source, source_ref_id,
    birth_date_hash, derived_email
  ) VALUES (
    v_co_b, 'ion', 'popescu', 'reges', 't-dob-crossco',
    'hash-dob-crossco', 'ion.popescu@dob-a.example'
  );

  -- Same-name twins: identical derived_email, different DOB hashes. This is
  -- the one case where DOB does real work.
  INSERT INTO public.profile_invites (
    company_id, first_name, last_name, source, source_ref_id,
    birth_date_hash, derived_email
  ) VALUES
    (v_co_a, 'radu', 'muresan', 'reges', 't-dob-twin-1',
     'hash-twin-1', 'radu.muresan@dob-a.example'),
    (v_co_a, 'radu', 'muresan', 'reges', 't-dob-twin-2',
     'hash-twin-2', 'radu.muresan@dob-a.example');

  PERFORM set_config('test.dob_co_a', v_co_a::text, false);
  PERFORM set_config('test.dob_co_b', v_co_b::text, false);
END;
$$;

SELECT plan(9);

-- ── N01: NULL dob hash still finds the derived-email candidate ─────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     NULL,
     'ion',
     'popescu',
     'ion.popescu@dob-a.example'
   )),
  1,
  'N01: NULL dob hash returns exactly the derived-email candidate'
);

-- ── N02: it is flagged as a derived-email match ────────────────────────────
SELECT is(
  (SELECT email_derived_match FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     NULL, 'ion', 'popescu', 'ion.popescu@dob-a.example'
   ) LIMIT 1),
  true,
  'N02: NULL dob hash still yields email_derived_match = true'
);

-- ── N03: dob_matched degrades to NULL, not false ───────────────────────────
-- register/index.ts does `if (c.dob_matched) s += W_DOB`, so NULL is safely
-- falsy in JS. Pinned here because the TS interface declares it `boolean`.
SELECT ok(
  (SELECT dob_matched IS NULL FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     NULL, 'ion', 'popescu', 'ion.popescu@dob-a.example'
   ) LIMIT 1),
  'N03: NULL dob hash makes dob_matched NULL (falsy in the scorer)'
);

-- ── N04: name sub-scores are unaffected by the missing DOB ─────────────────
SELECT is(
  (SELECT (first_score::numeric + last_score::numeric) FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     NULL, 'ion', 'popescu', 'ion.popescu@dob-a.example'
   ) LIMIT 1),
  2.0::numeric,
  'N04: NULL dob hash still computes exact name scores (1.0 + 1.0)'
);

-- ── N05: DOB-only rows drop out of the candidate set ───────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     NULL, 'maria', 'ionescu', 'someone.else@dob-a.example'
   )),
  0,
  'N05: NULL dob hash excludes rows reachable only via birth_date_hash'
);

-- ── N06: claimed invites stay excluded ─────────────────────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     NULL, 'vlad', 'stan', 'vlad.stan@dob-a.example'
   )),
  0,
  'N06: NULL dob hash still excludes already-claimed invites'
);

-- ── N07: company scoping survives ──────────────────────────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.dob_co_b')::uuid,
     NULL, 'ion', 'popescu', 'ion.popescu@dob-a.example'
   )),
  1,
  'N07: NULL dob hash stays scoped to the requested company'
);

-- ── N08: same derived_email twins are ambiguous without DOB ────────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     NULL, 'radu', 'muresan', 'radu.muresan@dob-a.example'
   )),
  2,
  'N08: without DOB, same-derived-email twins both surface (409 ambiguous)'
);

-- ── N09: DOB is what separates the twins ───────────────────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.match_pending_invite(
     current_setting('test.dob_co_a')::uuid,
     'hash-twin-2', 'radu', 'muresan', 'radu.muresan@dob-a.example'
   ) WHERE dob_matched),
  1,
  'N09: supplying DOB marks exactly one twin as dob_matched'
);

SELECT * FROM finish();
ROLLBACK;
