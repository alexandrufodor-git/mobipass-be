#!/usr/bin/env bash
# Focused audit of the REGES bridge state. Read-only.
#
# Usage:
#   ./scripts/dev/show-audit.sh [view]                    # local dev (dev company)
#   ./scripts/dev/show-audit.sh --prod [view]             # production, all companies
#   ./scripts/dev/show-audit.sh --prod <uuid> [view]      # production, one company
#
# view: all (default) | imports | registers | invites | pii | notifications | follow
#
# --prod requires the project to be linked: supabase link --project-ref <ref>

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

PROD=false
COMPANY_ID=""
VIEW="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod)
      PROD=true
      shift
      if [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        COMPANY_ID="$1"
        shift
      fi
      ;;
    all|imports|registers|invites|pii|notifications|follow)
      VIEW="$1"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Connection setup ─────────────────────────────────────────────────────────

if $PROD; then
  RUN_SQL() {
    supabase db query --linked -f /dev/stdin
  }
  FOLLOW_INTERVAL=5
  MODE="prod"
else
  COMPANY_ID="${COMPANY_ID:-44444444-4444-4444-4444-444444444444}"
  if ! supabase status -o env > /dev/null 2>&1; then
    echo "✗ Supabase not running. Use --prod to target production." >&2; exit 1
  fi
  eval "$(supabase status -o env 2>/dev/null)"
  if command -v psql > /dev/null 2>&1; then
    RUN_SQL() { psql "$DB_URL" -X; }
  else
    DB_CONTAINER=$(docker ps --filter "name=supabase_db_" --format "{{.Names}}" | head -1)
    RUN_SQL() { docker exec -i "$DB_CONTAINER" psql -U postgres -X; }
  fi
  FOLLOW_INTERVAL=2
  MODE="local"
fi

# ── Company filter ───────────────────────────────────────────────────────────

if [[ -n "$COMPANY_ID" ]]; then
  CFILTER="company_id = '$COMPANY_ID'"
  EP_CFILTER="ep.company_id = '$COMPANY_ID'"
else
  CFILTER="TRUE"
  EP_CFILTER="TRUE"
fi

bar() { printf '\n%s\n' "── $1 ──────────────────────────────────────────────────"; }

# ── Views ────────────────────────────────────────────────────────────────────

show_imports() {
  bar "REGES imports (operation='import_employee')"
  RUN_SQL <<SQL
SELECT
  to_char(processed_at, 'HH24:MI:SS') AS time,
  company_id,
  result_payload->>'source_ref_id'    AS source_ref,
  result_code                          AS status,
  result_payload->>'invite_status'     AS invite,
  result_payload->>'derived_email_set' AS pattern_used
FROM public.integration_messages
WHERE $CFILTER
  AND integration = 'reges'
  AND operation   = 'import_employee'
ORDER BY processed_at DESC
LIMIT 20;
SQL
}

show_registers() {
  bar "Register attempts (operation='register_attempt')"
  RUN_SQL <<SQL
SELECT
  to_char(processed_at, 'HH24:MI:SS') AS time,
  company_id,
  status,
  result_code                          AS decision,
  result_payload->>'claim_type'        AS claim_type,
  result_payload->>'email_domain'      AS domain,
  result_payload->>'first_norm'        AS first_norm,
  result_payload->>'last_norm'         AS last_norm,
  jsonb_array_length(COALESCE(result_payload->'candidates', '[]'::jsonb)) AS candidates
FROM public.integration_messages
WHERE $CFILTER
  AND integration = 'reges'
  AND operation   = 'register_attempt'
ORDER BY processed_at DESC
LIMIT 20;
SQL

  printf '\nTop candidates for most recent register attempt:\n'
  RUN_SQL <<SQL
SELECT jsonb_pretty(result_payload->'candidates') AS candidates
FROM public.integration_messages
WHERE $CFILTER
  AND operation = 'register_attempt'
ORDER BY processed_at DESC
LIMIT 1;
SQL
}

show_invites() {
  bar "profile_invites (state)"
  RUN_SQL <<SQL
SELECT
  company_id,
  source,
  source_ref_id,
  first_name || ' ' || last_name       AS name,
  CASE WHEN email IS NULL THEN 'pending' ELSE 'claimed' END AS state,
  COALESCE(email, '-')                 AS email,
  COALESCE(derived_email, '-')         AS derived,
  radiat,
  CASE WHEN birth_date_hash IS NULL THEN '-' ELSE left(birth_date_hash, 12) || '…' END AS dob_hash
FROM public.profile_invites
WHERE $CFILTER
ORDER BY company_id, created_at;
SQL
}

show_pii() {
  bar "employee_pii (staged vs linked)"
  RUN_SQL <<SQL
SELECT
  ep.company_id,
  ep.source_ref_id,
  CASE WHEN ep.user_id IS NULL THEN 'staged' ELSE 'linked' END AS state,
  COALESCE(p.email, '-')               AS bound_email,
  CASE WHEN ep.national_id_encrypted   IS NOT NULL THEN '✓' ELSE '-' END AS cnp_enc,
  CASE WHEN ep.home_address_encrypted  IS NOT NULL THEN '✓' ELSE '-' END AS addr_enc,
  CASE WHEN ep.date_of_birth_encrypted IS NOT NULL THEN '✓' ELSE '-' END AS dob_enc,
  CASE WHEN ep.profile_invite_id IS NULL THEN '-' ELSE 'linked' END AS invite_link
FROM public.employee_pii ep
LEFT JOIN public.profiles p ON p.user_id = ep.user_id
WHERE $EP_CFILTER
ORDER BY ep.company_id, ep.created_at;
SQL
}

show_notifications() {
  bar "company_notifications (HR-visible events)"
  RUN_SQL <<SQL
SELECT
  to_char(created_at, 'HH24:MI:SS') AS time,
  company_id,
  event,
  event_type,
  payload->>'employee_name'          AS who,
  payload->>'invite_id'              AS invite_id,
  payload->>'email'                  AS email
FROM public.company_notifications
WHERE $CFILTER
ORDER BY created_at DESC
LIMIT 20;
SQL
}

show_all() {
  show_imports
  show_registers
  show_invites
  show_pii
  show_notifications
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$VIEW" in
  all)            show_all ;;
  imports)        show_imports ;;
  registers)      show_registers ;;
  invites)        show_invites ;;
  pii)            show_pii ;;
  notifications)  show_notifications ;;
  follow)
    while :; do
      clear
      echo "REGES audit [$MODE] — $(date +%H:%M:%S) (Ctrl-C to exit)"
      show_all
      sleep "$FOLLOW_INTERVAL"
    done ;;
esac
