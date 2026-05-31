#!/usr/bin/env bash
# Capture the OTP delivered by Supabase Auth to the local Mailpit instance
# (port 54324, bundled with `supabase start`). Polls for up to TIMEOUT
# seconds, echoes the 6-digit code to stdout on success, exits 1 with a
# message to stderr on timeout.
#
# Usage:
#   OTP=$(./scripts/lib/fetch-otp.sh user@example.com)
#   OTP=$(./scripts/lib/fetch-otp.sh user@example.com 45)   # custom timeout
#
# Reused by Maestro mobile flows (Phase 5) so a single helper covers both
# shell integration tests and on-device E2E.

set -euo pipefail

EMAIL="${1:?fetch-otp.sh: email required}"
TIMEOUT="${2:-30}"
# Resolution order:
#   1. explicit MAIL_URL env var (e.g. CI override)
#   2. supabase status's MAILPIT_URL or legacy INBUCKET_URL (auto-set by
#      `eval "$(supabase status -o env)"`)
#   3. default for `supabase start` on a single dev machine
MAIL_URL="${MAIL_URL:-${MAILPIT_URL:-${INBUCKET_URL:-http://127.0.0.1:54324}}}"

START=$(date +%s)

while (( $(date +%s) - START < TIMEOUT )); do
  # Newest first. Filter messages addressed to our email.
  LIST=$(curl -fsS "${MAIL_URL}/api/v1/messages?limit=50" 2>/dev/null || echo '{}')
  MSG_ID=$(echo "$LIST" | jq -r --arg e "$EMAIL" '
    .messages // []
    | map(select(.To[]?.Address == $e))
    | sort_by(.Created)
    | reverse
    | .[0].ID // empty
  ')
  if [[ -n "$MSG_ID" && "$MSG_ID" != "null" ]]; then
    BODY=$(curl -fsS "${MAIL_URL}/api/v1/message/${MSG_ID}" 2>/dev/null || echo '{}')
    # The Supabase magic-link template renders the OTP as a 6-digit code in
    # the body alongside the link. Match the FIRST 6-digit run that isn't
    # part of the redirect URL.
    OTP=$(echo "$BODY" | jq -r '.Text // .HTML // ""' \
            | grep -oE '\b[0-9]{6}\b' | head -1)
    if [[ -n "$OTP" ]]; then
      echo "$OTP"
      exit 0
    fi
  fi
  sleep 1
done

echo "fetch-otp.sh: no OTP for $EMAIL after ${TIMEOUT}s" >&2
exit 1
