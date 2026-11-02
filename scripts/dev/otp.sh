#!/usr/bin/env bash
# Prints a fresh login OTP for a TEST account on the linked project; it replaces the code already emailed.
# Usage: ./scripts/dev/otp.sh hr.cadran@cadran.eu   (run after tapping Register in the app)
set -euo pipefail

EMAIL="${1:?usage: $0 <test-account-email>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_REF=$(tr -d '[:space:]' < "$SCRIPT_DIR/../../supabase/.temp/project-ref")

read -rp "New OTP for $EMAIL on $PROJECT_REF — never use this on a real employee. Continue? [y/N] " OK
[[ "$OK" == "y" || "$OK" == "Y" ]] || { echo "aborted." >&2; exit 1; }

KEY=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null \
  | jq -r 'map(select(.id == "service_role" or (.name == "service_role" and .type == "legacy"))) | .[0].api_key // empty')
[[ -n "$KEY" ]] || { echo "✗ could not get the service key (supabase login?)" >&2; exit 1; }

RESP=$(curl -sS -X POST "https://$PROJECT_REF.supabase.co/auth/v1/admin/generate_link" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "$(jq -nc --arg e "$EMAIL" '{type: "magiclink", email: $e}')")
OTP=$(echo "$RESP" | jq -r '.email_otp // .properties.email_otp // empty')
[[ -n "$OTP" ]] || { echo "✗ generate_link failed: $(echo "$RESP" | jq -c '{code, msg, error_code}' 2>/dev/null || echo "$RESP")" >&2; exit 1; }

echo "OTP for $EMAIL: $OTP"
