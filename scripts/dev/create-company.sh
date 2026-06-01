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
#   5. user_roles UPDATE         — flip role 'employee' → 'hr'. JWT
#                                  custom_access_token_hook selects a single
#                                  row from user_roles, so we keep one row
#                                  with role='hr' rather than adding a second
#                                  (non-deterministic which would win otherwise).
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

if [[ -n "$EMAIL_PATTERN" ]]; then
  case "$EMAIL_PATTERN" in
    last_middle_first|first_middle_last|first_last|last_first|first_initial_last) ;;
    *)
      echo "✗ EMAIL_PATTERN '$EMAIL_PATTERN' is not a valid enum value." >&2
      echo "  Allowed: last_middle_first, first_middle_last, first_last, last_first, first_initial_last" >&2
      exit 1
      ;;
  esac
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
    '
    {
      name: $name,
      email_domain: $email_domain,
      currency: $currency,
      monthly_benefit_subsidy: $monthly_benefit_subsidy,
      contract_months: $contract_months,
      days_in_office: $days_in_office,
    }
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

# ── 4. Flip user_role employee → hr ─────────────────────────────────────────

echo "[4/5] Promoting role employee → hr..."
ROLE_PATCH_RESP=$(curl -sS -X PATCH \
  "$SUPABASE_URL/rest/v1/user_roles?user_id=eq.$USER_ID&role=eq.employee" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"role":"hr"}')
if ! echo "$ROLE_PATCH_RESP" | jq -e '.[0].id' > /dev/null 2>&1; then
  echo "✗ role flip failed:" >&2
  echo "$ROLE_PATCH_RESP" >&2
  exit 1
fi
echo "      ✓ role=hr"

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
  Role:        hr
  User ID:     $USER_ID

Save the password — it isn't recoverable from this script.
EOF
