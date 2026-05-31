#!/usr/bin/env bash
# Upload a REGES JSON file to /functions/v1/bulk-create as the seeded HR
# user for the RegesGmail company (see supabase/seed.sql).
#
# Usage:
#   ./scripts/dev/upload-reges.sh /Users/machita/Downloads/raport.txt
#   ./scripts/dev/upload-reges.sh raport.txt | jq .       # pretty-print
#
# Pre-reqs:
#   supabase start && supabase db reset
#   scripts/setup-pii-vault.sh
#   supabase functions serve --env-file supabase/.env.local   (separate terminal)
#
# This bypasses the Angular HR UI entirely — the seeded HR user is wired up
# specifically so curl-driven uploads work without OTP. Useful for Phase 3
# manual verification and Phase 5 mobile E2E setup.

set -euo pipefail

FILE="${1:?usage: upload-reges.sh <path/to/raport.txt>}"
[ -f "$FILE" ] || { echo "✗ file not found: $FILE" >&2; exit 1; }

if ! supabase status -o env > /dev/null 2>&1; then
  echo "✗ Supabase not running. Run: supabase start && supabase db reset" >&2
  exit 1
fi
eval "$(supabase status -o env 2>/dev/null)"

# Seeded HR user for the RegesGmail company (supabase/seed.sql).
HR_USER_ID="dddddddd-dddd-dddd-dddd-dddddddddddd"

# Sign an HR JWT with the local JWT_SECRET.
make_jwt() {
  local sub="$1"; local role="$2"
  local now exp h p s
  now=$(date +%s); exp=$((now + 3600))
  h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  p=$(printf '%s' "{\"sub\":\"$sub\",\"role\":\"authenticated\",\"user_role\":\"$role\",\"iss\":\"supabase-demo\",\"iat\":$now,\"exp\":$exp}" \
        | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary \
        | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  echo "${h}.${p}.${s}"
}

JWT=$(make_jwt "$HR_USER_ID" "hr")

echo "→ Uploading $FILE to $API_URL/functions/v1/bulk-create" >&2
echo "  as HR user $HR_USER_ID (RegesGmail company, gmail.com domain)" >&2
echo >&2

curl -sS -X POST "$API_URL/functions/v1/bulk-create" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  --data-binary "@$FILE"
echo
