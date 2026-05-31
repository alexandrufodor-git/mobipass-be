-- REGES employee bridge: candidate scoring for /register
--
-- Returns up to 10 pending (email IS NULL) invites in a company that match
-- the registrant on either DOB hash or derived_email. The edge function
-- applies the final weighted-confidence model on top of these signals.
--
-- First-name match is asymmetric to handle REGES compound prenume vs. a
-- user typing a single given name (and the reverse):
--   GREATEST(
--     pg_trgm similarity,
--     prefix-boost (REGES "ANDREEA-MIHAELA" vs user "Andreea") -> 0.95,
--     token-match (REGES "ANDREEA-MIHAELA" vs user "Mihaela")  -> 0.90,
--     reverse-prefix (REGES "ANDREEA" vs user "Andreea Mihaela") -> 0.95
--   )
-- Last name uses plain trigram similarity.

CREATE OR REPLACE FUNCTION public.match_pending_invite(
  p_company_id    uuid,
  p_dob_hash      text,
  p_first_norm    text,
  p_last_norm     text,
  p_email_lower   text
) RETURNS TABLE (
  id                  uuid,
  radiat              boolean,
  email_derived_match boolean,
  dob_matched         boolean,
  first_score         real,
  last_score          real
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    pi.id,
    pi.radiat,
    (pi.derived_email IS NOT NULL
       AND lower(pi.derived_email) = p_email_lower) AS email_derived_match,
    (pi.birth_date_hash = p_dob_hash)                AS dob_matched,
    GREATEST(
      similarity(lower(pi.first_name), p_first_norm),
      CASE
        WHEN lower(pi.first_name) LIKE p_first_norm || '-%'
          OR lower(pi.first_name) LIKE p_first_norm || ' %' THEN 0.95
        WHEN p_first_norm = ANY(string_to_array(
               regexp_replace(lower(pi.first_name), '[-\s]+', '|', 'g'), '|'))
          THEN 0.90
        ELSE 0
      END,
      CASE
        WHEN p_first_norm LIKE lower(pi.first_name) || ' %'
          OR p_first_norm LIKE lower(pi.first_name) || '-%' THEN 0.95
        ELSE 0
      END
    )::real AS first_score,
    similarity(lower(pi.last_name), p_last_norm)::real AS last_score
  FROM profile_invites pi
  WHERE pi.email IS NULL
    AND pi.company_id = p_company_id
    AND (
      pi.birth_date_hash = p_dob_hash
      OR (pi.derived_email IS NOT NULL AND lower(pi.derived_email) = p_email_lower)
    )
  ORDER BY
    (pi.derived_email IS NOT NULL AND lower(pi.derived_email) = p_email_lower) DESC,
    (pi.birth_date_hash = p_dob_hash) DESC,
    similarity(lower(pi.first_name), p_first_norm) DESC,
    similarity(lower(pi.last_name),  p_last_norm)  DESC
  LIMIT 10;
$$;

GRANT EXECUTE ON FUNCTION public.match_pending_invite(uuid, text, text, text, text) TO service_role;
