#!/usr/bin/env bash
# ============================================================================
# Bootstrap a new company + matching HR user on a Supabase project.
# ============================================================================
#
# Creates, in order:
#   1. public.companies          — the company row (subject to NOT NULL +
#                                  CHECK constraints on email_domain).
#   2. public.profile_invites    — HR invite (required: handle_user_registration
#                                  reads this when the auth.user is created).
#   3. auth.users                — HR account, email pre-confirmed + password
#                                  set. Supabase Admin API stores a placeholder
#                                  password hash even when no password is sent,
#                                  so the INSERT trigger fires either way —
#                                  hence step 2 has to happen first.
#   4. (trigger creates)         — public.profiles (status='active'),
#                                  public.user_roles (role='employee' default),
#                                  public.bike_benefits (kept — HR can also
#                                  claim a personal benefit; bike_benefits
#                                  RLS keys off user_id=auth.uid(), so this
#                                  works regardless of the role flip below).
#   5. user_roles ADD 'hr'       — add a second row role='hr' while KEEPING the
#                                  trigger's role='employee' row, so the HR user
#                                  holds BOTH roles. This is required: an HR who
#                                  is also an employee must be able to sign their
#                                  own bike contract (send-contract gates on a
#                                  role='employee' row in user_roles). Safe since
#                                  Migration B (20260608000002): the JWT
#                                  custom_access_token_hook now picks the
#                                  highest-priv role deterministically
#                                  (admin>hr>employee) and emits the full
#                                  user_roles array — no longer non-deterministic.
#
# Usage:
#   Option A — edit the local config and just run the script:
#     cp scripts/dev/create-company.env.example scripts/dev/create-company.env
#     # edit scripts/dev/create-company.env (set COMPANY_NAME, EMAIL_DOMAIN, …)
#     ./scripts/dev/create-company.sh
#
#   Option B — pass everything inline (overrides anything in the config file):
#     COMPANY_NAME="Acme Corp" EMAIL_DOMAIN="acme.com" \
#       ./scripts/dev/create-company.sh
#
#   Remote (set TARGET + URL + service role key in the config file or inline):
#     TARGET=prod \
#       SUPABASE_URL="https://xxxxx.supabase.co" \
#       SUPABASE_SERVICE_ROLE_KEY="eyJhbGc..." \
#       COMPANY_NAME="Acme Corp" EMAIL_DOMAIN="acme.com" \
#       ./scripts/dev/create-company.sh
#
# Config file lookup order (first match wins, later sources override earlier
# values for any var not already exported in the caller's environment):
#   1. $CREATE_COMPANY_ENV  (explicit path; useful for "one config per project")
#   2. scripts/dev/create-company.env  (default — gitignored)
#
# Required env vars:
#   COMPANY_NAME            — unique company name
#   EMAIL_DOMAIN            — bare domain (e.g. acme.com). Lowercase only.
#                             Must match companies_email_domain_format CHECK.
#
# Optional env vars (defaults shown):
#   DESCRIPTION             — null
#   MONTHLY_BENEFIT_SUBSIDY — 72.00
#   CONTRACT_MONTHS         — 36
#   CURRENCY                — RON (one of: RON, EUR — extend if needed)
#   EMAIL_PATTERN           — null. Enum: last_middle_first | first_middle_last
#                             | first_last | last_first | first_initial_last
#                             | last | first
#   CONTACT_EMAIL           — contact@$EMAIL_DOMAIN
#   ESIGNATURES_TEMPLATE_ID — null (set per project if you have a template)
#   ADDRESS                 — null
#   ADDRESS_LAT             — null
#   ADDRESS_LON             — null
#   DAYS_IN_OFFICE          — 5
#   HR_EMAIL                — hr@$EMAIL_DOMAIN
#   HR_FIRST_NAME           — HR
#   HR_LAST_NAME            — derived from COMPANY_NAME
#   HR_PASSWORD             — auto-generated (20 chars) if unset. Required —
#                             handle_user_registration trigger only fires when
#                             encrypted_password is set, so a password is
#                             always needed at create time.
#   LOGO_PATH               — path to a local image file. Uploads to the
#                             company-logos bucket as <company_id> and sets
#                             companies.logo_image_path = <company_id>.
#                             Allowed MIME: image/jpeg, image/png, image/webp,
#                             image/svg+xml. Size limit: 2 MiB (bucket-level).
#   TARGET                  — linked (default) | local | prod
#                             linked → auto-derives URL + service-role key from
#                                      the `supabase link` state in
#                                      supabase/.temp/project-ref. One-key
#                                      [y/N] confirmation before writing.
#                             local  → uses `supabase status` (docker stack).
#                             prod   → requires SUPABASE_URL and
#                                      SUPABASE_SERVICE_ROLE_KEY explicitly.
#   AUTO_CONFIRM            — set to "true" to skip the TARGET=linked y/N
#                             prompt. Use in CI; otherwise leave unset.
#   TIME_ZONE               — Europe/Bucharest (IANA name; test-day label + push times)
#   SHOW_FINAL_BUY          — true. false hides the "Final buy" note on bike pages.
#   INSURANCE_PROVIDER      — null. Shown under Addons on bike pages.
#   HELMET_PROVIDER         — null. Shown under Addons on bike pages.
#
# Pilot mode (PILOT=true) — the copilot: steps 1-3 only, stops after commit.
#   Sets copilot_stop_after_commit=true and checks only what the pilot shows.
#   Required, no defaults: MONTHLY_BENEFIT_SUBSIDY, CONTRACT_MONTHS, CURRENCY,
#     INSURANCE_PROVIDER, HELMET_PROVIDER, COPILOT_BIKE_IDS, HR_EMAIL.
#   COPILOT_BIKE_IDS        — comma-separated bikes.id; each must exist, be
#                             active and in stock on the target.
#   LIVE_TEST_AT            — optional ISO time with offset, e.g.
#                             2026-11-12T10:00:00+02:00. Unset → step 2 says
#                             "HR will contact you"; set it later in the DB.
#   Not needed for the pilot (warned if unset, sent if set): ESIGNATURES_TEMPLATE_ID,
#     EMAIL_PATTERN, ADDRESS/ADDRESS_LAT/ADDRESS_LON, DAYS_IN_OFFICE.
#
# Requires: curl, jq, openssl. For TARGET=local, also: supabase CLI running.
# ============================================================================

set -euo pipefail

# ── Load config file (if present) ───────────────────────────────────────────
# Lets you edit one file and just run `./scripts/dev/create-company.sh`
# instead of passing every var on the command line. Already-exported env
# vars win over file values, so inline overrides still work.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CREATE_COMPANY_ENV:-$SCRIPT_DIR/create-company.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  echo "Loading config: $CONFIG_FILE"
  # `set -a` exports every var defined in the sourced file; `set +a` restores
  # the previous behaviour. This way the file can use plain `FOO=bar` syntax.
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

# ── Inputs / defaults ───────────────────────────────────────────────────────

: "${COMPANY_NAME:?COMPANY_NAME is required (set it in $CONFIG_FILE or inline)}"
: "${EMAIL_DOMAIN:?EMAIL_DOMAIN is required (set it in $CONFIG_FILE or inline)}"

TARGET="${TARGET:-linked}"
PILOT="${PILOT:-false}"

# Pilot mode must not fall back to the defaults below: every value here is on screen.
PILOT_MISSING=()
if [[ "$PILOT" == "true" ]]; then
  for v in MONTHLY_BENEFIT_SUBSIDY CONTRACT_MONTHS CURRENCY INSURANCE_PROVIDER HELMET_PROVIDER COPILOT_BIKE_IDS HR_EMAIL; do
    [[ -z "${!v:-}" ]] && PILOT_MISSING+=("$v")
  done
  if (( ${#PILOT_MISSING[@]} > 0 )); then
    echo "✗ PILOT=true but these are not set (set them in $CONFIG_FILE or inline):" >&2
    printf '    %s\n' "${PILOT_MISSING[@]}" >&2
    exit 1
  fi
elif [[ "$PILOT" != "false" ]]; then
  echo "✗ PILOT must be 'true' or 'false' (got '$PILOT')" >&2; exit 1
fi

DESCRIPTION="${DESCRIPTION:-}"
MONTHLY_BENEFIT_SUBSIDY="${MONTHLY_BENEFIT_SUBSIDY:-72.00}"
CONTRACT_MONTHS="${CONTRACT_MONTHS:-36}"
CURRENCY="${CURRENCY:-RON}"
EMAIL_PATTERN="${EMAIL_PATTERN:-}"
CONTACT_EMAIL="${CONTACT_EMAIL:-contact@$EMAIL_DOMAIN}"
ESIGNATURES_TEMPLATE_ID="${ESIGNATURES_TEMPLATE_ID:-}"
ADDRESS="${ADDRESS:-}"
ADDRESS_LAT="${ADDRESS_LAT:-}"
ADDRESS_LON="${ADDRESS_LON:-}"
DAYS_IN_OFFICE="${DAYS_IN_OFFICE:-5}"
LOGO_PATH="${LOGO_PATH:-}"
TIME_ZONE="${TIME_ZONE:-Europe/Bucharest}"
SHOW_FINAL_BUY="${SHOW_FINAL_BUY:-true}"
INSURANCE_PROVIDER="${INSURANCE_PROVIDER:-}"
HELMET_PROVIDER="${HELMET_PROVIDER:-}"
COPILOT_BIKE_IDS="${COPILOT_BIKE_IDS:-}"
LIVE_TEST_AT="${LIVE_TEST_AT:-}"

HR_EMAIL="${HR_EMAIL:-hr@$EMAIL_DOMAIN}"
HR_FIRST_NAME="${HR_FIRST_NAME:-HR}"
# Default last name = company slug (alphanumerics only, capitalized roughly).
HR_LAST_NAME_DEFAULT=$(echo "$COMPANY_NAME" | tr -cd '[:alnum:]')
HR_LAST_NAME="${HR_LAST_NAME:-${HR_LAST_NAME_DEFAULT:-Admin}}"
# HR_PASSWORD must be set (trigger needs encrypted_password to fire). Auto-
# generate one if the caller didn't supply it. Empty string is treated the
# same as unset.
if [[ -z "${HR_PASSWORD:-}" ]]; then
  HR_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)
fi

# ── Sanity checks ───────────────────────────────────────────────────────────

if ! command -v jq > /dev/null; then
  echo "✗ jq is required (brew install jq)" >&2; exit 1
fi
if ! command -v curl > /dev/null; then
  echo "✗ curl is required" >&2; exit 1
fi

# Validate EMAIL_DOMAIN against the same regex the DB CHECK uses.
if ! [[ "$EMAIL_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
  echo "✗ EMAIL_DOMAIN '$EMAIL_DOMAIN' fails the format check." >&2
  echo "  Must be lowercase, no '@' or scheme, must contain a dot." >&2
  echo "  Examples: acme.com, mobi-pass.com, sub.example.co.uk" >&2
  exit 1
fi

# The HR login account MUST live on the company domain. A mismatch here (almost
# always a typo) produces an account that can never log in, so fail loud and
# early — before touching the DB. The DB also enforces this via the
# enforce_email_matches_company_domain trigger on profile_invites/profiles, but
# catching it here gives a precise, pre-flight error. (lowercase for the
# case-insensitive domain compare; bash 3.2-safe via tr.)
HR_EMAIL_DOMAIN="$(printf '%s' "${HR_EMAIL##*@}" | tr '[:upper:]' '[:lower:]')"
if [[ "$HR_EMAIL_DOMAIN" != "$EMAIL_DOMAIN" ]]; then
  echo "✗ HR_EMAIL '$HR_EMAIL' is not on the company domain." >&2
  echo "  HR email domain: '$HR_EMAIL_DOMAIN'" >&2
  echo "  Company domain:  '$EMAIL_DOMAIN'" >&2
  echo "  The HR account email must end with '@$EMAIL_DOMAIN'." >&2
  exit 1
fi

if [[ -n "$EMAIL_PATTERN" ]]; then
  case "$EMAIL_PATTERN" in
    last_middle_first|first_middle_last|first_last|last_first|first_initial_last|last|first) ;;
    *)
      echo "✗ EMAIL_PATTERN '$EMAIL_PATTERN' is not a valid enum value." >&2
      echo "  Allowed: last_middle_first, first_middle_last, first_last, last_first, first_initial_last, last, first" >&2
      exit 1
      ;;
  esac
fi

FAILS=()
WARNS=()
[[ "$MONTHLY_BENEFIT_SUBSIDY" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || FAILS+=("MONTHLY_BENEFIT_SUBSIDY '$MONTHLY_BENEFIT_SUBSIDY' is not a number like 72 or 72.50")
[[ "$CONTRACT_MONTHS" =~ ^[1-9][0-9]*$ ]] || FAILS+=("CONTRACT_MONTHS '$CONTRACT_MONTHS' is not a whole number of months")
[[ "$DAYS_IN_OFFICE" =~ ^[0-7]$ ]] || FAILS+=("DAYS_IN_OFFICE '$DAYS_IN_OFFICE' must be 0-7")
case "$CURRENCY" in RON|EUR) ;; *) FAILS+=("CURRENCY '$CURRENCY' must be RON or EUR") ;; esac
case "$SHOW_FINAL_BUY" in true|false) ;; *) FAILS+=("SHOW_FINAL_BUY '$SHOW_FINAL_BUY' must be true or false") ;; esac
[[ "$TIME_ZONE" == */* ]] || FAILS+=("TIME_ZONE '$TIME_ZONE' is not an IANA name like Europe/Bucharest")

BIKE_IDS_JSON="null"
if [[ -n "$COPILOT_BIKE_IDS" ]]; then
  BIKE_IDS_JSON=$(printf '%s' "$COPILOT_BIKE_IDS" | jq -Rc 'split(",") | map(gsub("\\s"; "")) | map(select(. != "")) | unique')
  for id in $(echo "$BIKE_IDS_JSON" | jq -r '.[]'); do
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || FAILS+=("COPILOT_BIKE_IDS: '$id' is not a lowercase uuid")
  done
  [[ "$(echo "$BIKE_IDS_JSON" | jq 'length')" -gt 0 ]] || FAILS+=("COPILOT_BIKE_IDS has no ids")
fi

if [[ -n "$LIVE_TEST_AT" ]]; then
  [[ "$LIVE_TEST_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] \
    || FAILS+=("LIVE_TEST_AT '$LIVE_TEST_AT' must be ISO with an offset, e.g. 2026-11-12T10:00:00+02:00")
  [[ "$PILOT" == "true" ]] || WARNS+=("LIVE_TEST_AT is set but PILOT=false: the app only uses it for the copilot")
fi

if [[ "$PILOT" == "true" ]]; then
  [[ -n "$LIVE_TEST_AT" ]] || WARNS+=("LIVE_TEST_AT unset: step 2 shows \"HR will contact you\" until companies.live_test_at is set")
  [[ -n "$LOGO_PATH" ]] || WARNS+=("LOGO_PATH unset: no company logo in the app or the HR dashboard")
else
  [[ -n "$ESIGNATURES_TEMPLATE_ID" ]] || WARNS+=("ESIGNATURES_TEMPLATE_ID unset: send-contract fails at step 4")
  [[ -n "$ADDRESS" && -n "$ADDRESS_LAT" && -n "$ADDRESS_LON" ]] || WARNS+=("ADDRESS/ADDRESS_LAT/ADDRESS_LON incomplete: no work address for address setup and commute numbers")
  [[ -n "$INSURANCE_PROVIDER" && -n "$HELMET_PROVIDER" ]] || WARNS+=("INSURANCE_PROVIDER/HELMET_PROVIDER unset: empty Addons rows on bike pages")
  [[ -z "$COPILOT_BIKE_IDS" ]] || WARNS+=("COPILOT_BIKE_IDS set without PILOT=true: the catalog is limited but the flow does not stop after commit")
fi

if (( ${#FAILS[@]} > 0 )); then
  echo "✗ invalid config:" >&2
  printf '    %s\n' "${FAILS[@]}" >&2
  exit 1
fi
if (( ${#WARNS[@]} > 0 )); then
  echo "⚠ warnings (not blocking):"
  printf '    %s\n' "${WARNS[@]}"
  echo
fi

# Validate LOGO_PATH up front so we fail before mutating the DB.
LOGO_MIME=""
if [[ -n "$LOGO_PATH" ]]; then
  if [[ ! -f "$LOGO_PATH" ]]; then
    echo "✗ LOGO_PATH '$LOGO_PATH' is not a readable file" >&2; exit 1
  fi
  case "$(echo "$LOGO_PATH" | tr '[:upper:]' '[:lower:]')" in
    *.jpg|*.jpeg) LOGO_MIME="image/jpeg" ;;
    *.png)        LOGO_MIME="image/png"  ;;
    *.webp)       LOGO_MIME="image/webp" ;;
    *.svg)        LOGO_MIME="image/svg+xml" ;;
    *)
      echo "✗ unsupported LOGO_PATH extension (allowed: .jpg, .jpeg, .png, .webp, .svg)" >&2
      exit 1
      ;;
  esac
  LOGO_BYTES=$(wc -c < "$LOGO_PATH" | tr -d ' ')
  if (( LOGO_BYTES > 2097152 )); then
    echo "✗ LOGO_PATH exceeds bucket size limit (2 MiB). file=${LOGO_BYTES}B" >&2
    exit 1
  fi
fi

# ── Resolve SUPABASE_URL + SERVICE_ROLE_KEY ─────────────────────────────────

case "$TARGET" in
  local)
    if ! supabase status -o env > /dev/null 2>&1; then
      echo "✗ Supabase not running. Start it first: supabase start" >&2; exit 1
    fi
    eval "$(supabase status -o env 2>/dev/null)"
    SUPABASE_URL="${API_URL:-http://127.0.0.1:54321}"
    SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY:-}"
    if [[ -z "$SUPABASE_SERVICE_ROLE_KEY" ]]; then
      echo "✗ SERVICE_ROLE_KEY missing from supabase status output." >&2; exit 1
    fi
    ;;
  linked)
    # Auto-derive URL + service-role key from the `supabase link` state.
    # The CLI stores the linked project ref in supabase/.temp/project-ref.
    PROJECT_REF_FILE="$(cd "$SCRIPT_DIR/../.." && pwd)/supabase/.temp/project-ref"
    if [[ ! -f "$PROJECT_REF_FILE" ]]; then
      echo "✗ TARGET=linked but no linked project found." >&2
      echo "  Run \`supabase link --project-ref <ref>\` first, then retry." >&2
      exit 1
    fi
    PROJECT_REF=$(tr -d '[:space:]' < "$PROJECT_REF_FILE")
    if [[ -z "$PROJECT_REF" ]]; then
      echo "✗ $PROJECT_REF_FILE is empty." >&2; exit 1
    fi

    # Derive URL.
    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

    # Fetch the legacy service_role key (the Admin API expects a JWT-shaped
    # key in the Authorization header; the new sb_secret_* keys also work,
    # but the legacy one is universally available across project ages).
    echo "Fetching service-role key for linked project '$PROJECT_REF'..."
    KEYS_JSON=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null) || {
      echo "✗ \`supabase projects api-keys\` failed." >&2
      echo "  Are you logged in? Try \`supabase login\` and retry." >&2
      exit 1
    }
    SUPABASE_SERVICE_ROLE_KEY=$(echo "$KEYS_JSON" \
      | jq -r 'map(select(.id == "service_role" or (.name == "service_role" and .type == "legacy"))) | .[0].api_key // empty')
    if [[ -z "$SUPABASE_SERVICE_ROLE_KEY" || "$SUPABASE_SERVICE_ROLE_KEY" == "null" ]]; then
      echo "✗ Could not extract service_role key from CLI output." >&2
      exit 1
    fi

    # Brief sanity prompt — one keystroke, defaults to no.
    echo "Writing to linked project $PROJECT_REF ($SUPABASE_URL)"
    echo "  company:  ${COMPANY_NAME:-<unset>} (${EMAIL_DOMAIN:-<unset>})"
    echo "  HR email: ${HR_EMAIL:-hr@${EMAIL_DOMAIN:-<unset>}}"
    if [[ "${AUTO_CONFIRM:-false}" != "true" ]]; then
      read -rp "Proceed? [y/N] " CONFIRM
      if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "  aborted." >&2
        exit 1
      fi
    fi
    echo
    ;;
  prod)
    : "${SUPABASE_URL:?SUPABASE_URL is required for TARGET=prod}"
    : "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY is required for TARGET=prod}"
    ;;
  *)
    echo "✗ TARGET must be 'local', 'linked', or 'prod' (got '$TARGET')" >&2; exit 1
    ;;
esac

# Strip any trailing slash from URL so concatenation is clean.
SUPABASE_URL="${SUPABASE_URL%/}"

echo "Target:       $TARGET"
echo "Supabase URL: $SUPABASE_URL"
echo "Company:      $COMPANY_NAME ($EMAIL_DOMAIN)"
echo "HR account:   $HR_EMAIL"
echo "Mode:         $([[ "$PILOT" == "true" ]] && echo "pilot (stops after commit)" || echo "full rollout")"
echo

# ── Helpers ─────────────────────────────────────────────────────────────────

# Build a JSON body from named env vars, skipping empty ones. Numeric and
# special-typed fields are passed without quoting; everything else is a
# JSON string. Done in jq so escaping is correct.
build_company_body() {
  jq -nc \
    --arg name "$COMPANY_NAME" \
    --arg email_domain "$EMAIL_DOMAIN" \
    --arg currency "$CURRENCY" \
    --arg description "$DESCRIPTION" \
    --arg contact_email "$CONTACT_EMAIL" \
    --arg esignatures_template_id "$ESIGNATURES_TEMPLATE_ID" \
    --arg email_pattern "$EMAIL_PATTERN" \
    --arg address "$ADDRESS" \
    --argjson monthly_benefit_subsidy "$MONTHLY_BENEFIT_SUBSIDY" \
    --argjson contract_months "$CONTRACT_MONTHS" \
    --argjson days_in_office "$DAYS_IN_OFFICE" \
    --arg address_lat "$ADDRESS_LAT" \
    --arg address_lon "$ADDRESS_LON" \
    --arg time_zone "$TIME_ZONE" \
    --argjson show_final_buy "$SHOW_FINAL_BUY" \
    --argjson pilot "$PILOT" \
    --arg insurance_provider "$INSURANCE_PROVIDER" \
    --arg helmet_provider "$HELMET_PROVIDER" \
    --arg live_test_at "$LIVE_TEST_AT" \
    --argjson copilot_bike_ids "$BIKE_IDS_JSON" \
    '
    {
      name: $name,
      email_domain: $email_domain,
      currency: $currency,
      monthly_benefit_subsidy: $monthly_benefit_subsidy,
      contract_months: $contract_months,
      days_in_office: $days_in_office,
      time_zone: $time_zone,
      show_final_buy: $show_final_buy,
      copilot_stop_after_commit: $pilot,
    }
    + (if $insurance_provider      != "" then {insurance_provider: $insurance_provider} else {} end)
    + (if $helmet_provider         != "" then {helmet_provider: $helmet_provider} else {} end)
    + (if $live_test_at            != "" then {live_test_at: $live_test_at} else {} end)
    + (if $copilot_bike_ids        != null then {copilot_bike_ids: $copilot_bike_ids} else {} end)
    + (if $description             != "" then {description: $description} else {} end)
    + (if $contact_email           != "" then {contact_email: $contact_email} else {} end)
    + (if $esignatures_template_id != "" then {esignatures_template_id: $esignatures_template_id} else {} end)
    + (if $email_pattern           != "" then {email_pattern: $email_pattern} else {} end)
    + (if $address                 != "" then {address: $address} else {} end)
    + (if $address_lat             != "" then {address_lat: ($address_lat|tonumber)} else {} end)
    + (if $address_lon             != "" then {address_lon: ($address_lon|tonumber)} else {} end)
    '
}

rest_post() {
  local path="$1"; local body="$2"
  curl -sS -X POST "$SUPABASE_URL/rest/v1$path" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "$body"
}

admin_post_user() {
  local body="$1"
  curl -sS -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
}

admin_delete_user() {
  local user_id="$1"
  curl -sS -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$user_id" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" > /dev/null || true
}

rest_get() {
  curl -sS "$SUPABASE_URL/rest/v1$1" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
}

# ── 0. Checks against the target, before any write ──────────────────────────

echo "[0/5] Checking the target..."
REMOTE_FAILS=()
for filter in "email_domain=eq.$EMAIL_DOMAIN" "name=eq.$(jq -rn --arg n "$COMPANY_NAME" '$n|@uri')"; do
  EXISTING=$(rest_get "/companies?$filter&select=name,email_domain")
  if ! echo "$EXISTING" | jq -e 'type == "array"' > /dev/null; then
    echo "✗ could not read companies: $EXISTING" >&2; exit 1
  fi
  [[ "$(echo "$EXISTING" | jq 'length')" == "0" ]] \
    || REMOTE_FAILS+=("a company already has ${filter%%=*} from this config: $(echo "$EXISTING" | jq -c '.[0]')")
done
HR_INVITES=$(rest_get "/profile_invites?email=eq.$(jq -rn --arg e "$HR_EMAIL" '$e|ascii_downcase|@uri')&select=id")
if ! echo "$HR_INVITES" | jq -e 'type == "array"' > /dev/null; then
  echo "✗ could not read profile_invites: $HR_INVITES" >&2; exit 1
fi
[[ "$(echo "$HR_INVITES" | jq 'length')" == "0" ]] || REMOTE_FAILS+=("HR_EMAIL $HR_EMAIL is already on an invite")

if [[ "$BIKE_IDS_JSON" != "null" ]]; then
  IDS_CSV=$(echo "$BIKE_IDS_JSON" | jq -r 'join(",")')
  BIKES=$(rest_get "/bikes?id=in.($IDS_CSV)&select=id,name,active,in_stock,available_for_test")
  if ! echo "$BIKES" | jq -e 'type == "array"' > /dev/null; then
    echo "✗ could not read bikes: $BIKES" >&2; exit 1
  fi
  for id in $(echo "$BIKE_IDS_JSON" | jq -r '.[]'); do
    ROW=$(echo "$BIKES" | jq -c --arg id "$id" 'map(select(.id == $id)) | .[0] // empty')
    if [[ -z "$ROW" ]]; then
      REMOTE_FAILS+=("bike $id does not exist")
    elif [[ "$(echo "$ROW" | jq '.active and (.in_stock == true)')" != "true" ]]; then
      REMOTE_FAILS+=("bike $(echo "$ROW" | jq -r '.name') ($id) is not active and in stock: the catalog would not show it")
    else
      echo "      ✓ $(echo "$ROW" | jq -r '.name')$(echo "$ROW" | jq -r 'if .available_for_test == false then "  ⚠ available_for_test=false" else "" end')"
    fi
  done
fi

if (( ${#REMOTE_FAILS[@]} > 0 )); then
  echo "✗ nothing written:" >&2
  printf '    %s\n' "${REMOTE_FAILS[@]}" >&2
  exit 1
fi
echo "      ✓ name, domain and HR email are free"

# ── 1. Create company ───────────────────────────────────────────────────────

echo "[1/5] Creating company..."
COMPANY_BODY="$(build_company_body)"
COMPANY_RESP=$(rest_post "/companies" "$COMPANY_BODY")
COMPANY_ID=$(echo "$COMPANY_RESP" | jq -r '.[0].id // empty')
if [[ -z "$COMPANY_ID" ]]; then
  echo "✗ company insert failed:" >&2
  echo "$COMPANY_RESP" >&2
  exit 1
fi
echo "      ✓ company_id=$COMPANY_ID"

# ── 2. Pre-create profile_invite (so handle_user_registration can resolve it) ─

echo "[2/5] Creating HR profile_invite..."
INVITE_BODY=$(jq -nc \
  --arg email "$HR_EMAIL" \
  --arg company_id "$COMPANY_ID" \
  --arg first_name "$HR_FIRST_NAME" \
  --arg last_name "$HR_LAST_NAME" \
  '{
    email: $email,
    status: "inactive",
    company_id: $company_id,
    first_name: $first_name,
    last_name: $last_name
  }')
INVITE_RESP=$(rest_post "/profile_invites" "$INVITE_BODY")
INVITE_ID=$(echo "$INVITE_RESP" | jq -r '.[0].id // empty')
if [[ -z "$INVITE_ID" ]]; then
  echo "✗ profile_invites insert failed:" >&2
  echo "$INVITE_RESP" >&2
  # Roll back the company so we don't leave it dangling.
  echo "  rolling back company $COMPANY_ID..." >&2
  curl -sS -X DELETE "$SUPABASE_URL/rest/v1/companies?id=eq.$COMPANY_ID" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" > /dev/null || true
  exit 1
fi
echo "      ✓ invite_id=$INVITE_ID"

# Rollback helper for subsequent steps.
cleanup_invite_and_company() {
  curl -sS -X DELETE "$SUPABASE_URL/rest/v1/profile_invites?id=eq.$INVITE_ID" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" > /dev/null || true
  curl -sS -X DELETE "$SUPABASE_URL/rest/v1/companies?id=eq.$COMPANY_ID" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" > /dev/null || true
}

# ── 3. Create auth user (trigger fires → profile + role='employee' + benefit) ─

echo "[3/5] Creating auth user..."
USER_BODY=$(jq -nc --arg email "$HR_EMAIL" --arg password "${HR_PASSWORD:-changeme-temp-pw}" \
  '{ email: $email, email_confirm: true, password: $password }')
USER_RESP=$(admin_post_user "$USER_BODY")
USER_ID=$(echo "$USER_RESP" | jq -r '.id // empty')
if [[ -z "$USER_ID" || "$USER_ID" == "null" ]]; then
  echo "✗ auth.users insert failed:" >&2
  echo "$USER_RESP" >&2
  echo "  rolling back (invite + company)..." >&2
  cleanup_invite_and_company
  exit 1
fi
echo "      ✓ user_id=$USER_ID (trigger created profile + role + bike_benefit)"

cleanup_on_error() {
  echo "  rolling back (auth.user + invite + company)..." >&2
  admin_delete_user "$USER_ID"
  cleanup_invite_and_company
}
trap cleanup_on_error ERR

# ── 4. Add 'hr' role (keep the trigger's 'employee' row) ────────────────────
# The user ends up with BOTH user_roles rows: 'employee' (from the trigger) and
# 'hr' (added here). send-contract requires a role='employee' row, so an HR who
# also claims a personal bike benefit can sign their own contract. The JWT hook
# (Migration B) reports highest-priv ('hr') as user_role and the full set as the
# user_roles array. Use Prefer: resolution=merge-duplicates so re-runs against a
# re-created user are idempotent against the (user_id, role) unique index.

echo "[4/5] Adding 'hr' role (keeping 'employee')..."
ROLE_POST_RESP=$(curl -sS -X POST \
  "$SUPABASE_URL/rest/v1/user_roles" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation,resolution=merge-duplicates" \
  -d "$(jq -nc --arg uid "$USER_ID" '{user_id: $uid, role: "hr"}')")
if ! echo "$ROLE_POST_RESP" | jq -e '.[0].id' > /dev/null 2>&1; then
  echo "✗ hr role insert failed:" >&2
  echo "$ROLE_POST_RESP" >&2
  exit 1
fi
echo "      ✓ roles: employee + hr"

# ── 5. Patch HR's profile (department, names) ───────────────────────────────
# The trigger copies first/last from the invite, so this is just to set the
# department to "Human Resources" (the trigger doesn't fill it).

echo "[5/5] Setting HR profile department..."
curl -sS -X PATCH "$SUPABASE_URL/rest/v1/profiles?user_id=eq.$USER_ID" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"department":"Human Resources"}' > /dev/null
echo "      ✓ department=Human Resources"

# ── 6 (optional). Upload company logo + set logo_image_path ─────────────────

if [[ -n "$LOGO_PATH" ]]; then
  echo "[+] Uploading company logo..."
  # POST creates a new object; if the run is re-applied on a re-created
  # company id we'd hit 409 from storage. Use PUT to be idempotent.
  LOGO_RESP=$(curl -sS -X PUT \
    "$SUPABASE_URL/storage/v1/object/company-logos/$COMPANY_ID" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: $LOGO_MIME" \
    -H "x-upsert: true" \
    --data-binary "@$LOGO_PATH")
  if ! echo "$LOGO_RESP" | jq -e '.Key // .key' > /dev/null 2>&1; then
    echo "      ⚠ logo upload failed — leaving logo_image_path NULL." >&2
    echo "        response: $LOGO_RESP" >&2
  else
    curl -sS -X PATCH "$SUPABASE_URL/rest/v1/companies?id=eq.$COMPANY_ID" \
      -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg p "$COMPANY_ID" '{logo_image_path: $p}')" > /dev/null
    echo "      ✓ logo uploaded ($LOGO_MIME, ${LOGO_BYTES}B) → companies.logo_image_path=$COMPANY_ID"
  fi
fi

# Disarm the rollback trap — everything succeeded.
trap - ERR

# ── Summary ─────────────────────────────────────────────────────────────────

cat <<EOF

═══ Done ═══
Target:        $TARGET
Company ID:    $COMPANY_ID
Company name:  $COMPANY_NAME
Email domain:  $EMAIL_DOMAIN

HR account:
  Email:       $HR_EMAIL
  Password:    $HR_PASSWORD
  Roles:       employee + hr (can sign own contract via send-contract)
  User ID:     $USER_ID

Save the password — it isn't recoverable from this script.
EOF

if [[ "$PILOT" == "true" ]]; then
  echo
  echo "Pilot settings as saved:"
  rest_get "/companies?id=eq.$COMPANY_ID&select=copilot_stop_after_commit,copilot_bike_ids,live_test_at,time_zone,monthly_benefit_subsidy,contract_months,currency,insurance_provider,helmet_provider,show_final_buy,logo_image_path" \
    | jq '.[0]'
fi
