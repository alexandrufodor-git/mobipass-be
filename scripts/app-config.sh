#!/usr/bin/env bash
# Read or raise the update gate's minimum app version (public.app_config).
#
# Usage:
#   ./scripts/app-config.sh get
#   ./scripts/app-config.sh set-min <ios|android> <version> [--force]
#
# Env:
#   TARGET        — linked (default) | local | prod
#                   prod → requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY
#   AUTO_CONFIRM  — true skips the confirm prompt on a remote write; honoured
#                   only when TARGET is set explicitly
#
# set-min refuses a version above the live store version unless --force.
# iOS: iTunes Lookup by bundle id. Android: Play has no public version API,
# so android always needs --force (check Play Console first).
#
# Requires: curl, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_EXPLICIT=false
[[ -n "${TARGET:-}" ]] && TARGET_EXPLICIT=true
TARGET="${TARGET:-linked}"
VERSION_RE='^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$'
IOS_BUNDLE_ID="com.mobi.pass.MobiPass"
IOS_COUNTRY="ro"

usage() {
  sed -n '4,6p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2
  exit 1
}

for bin in curl jq; do
  command -v "$bin" > /dev/null || { echo "✗ $bin is required" >&2; exit 1; }
done

CMD="${1:-}"; shift || true
PLATFORM=""; VERSION=""; FORCE=false
case "$CMD" in
  get) [[ $# -eq 0 ]] || usage ;;
  set-min)
    for arg in "$@"; do
      case "$arg" in
        --force) FORCE=true ;;
        -*) echo "✗ unknown flag: $arg" >&2; usage ;;
        *) if [[ -z "$PLATFORM" ]]; then PLATFORM="$arg"
           elif [[ -z "$VERSION" ]]; then VERSION="$arg"
           else usage; fi ;;
      esac
    done
    [[ "$PLATFORM" == "ios" || "$PLATFORM" == "android" ]] || { echo "✗ platform must be ios or android" >&2; usage; }
    [[ "$VERSION" =~ $VERSION_RE ]] || { echo "✗ version must look like 1, 1.2 or 1.2.3, max 4 digits per part (got '$VERSION')" >&2; exit 1; }
    ;;
  *) usage ;;
esac

# ── Resolve SUPABASE_URL + SERVICE_ROLE_KEY (no secrets stored) ──────────────

case "$TARGET" in
  local)
    supabase status -o env > /dev/null 2>&1 || { echo "✗ Supabase not running. Start it first: supabase start" >&2; exit 1; }
    eval "$(supabase status -o env 2>/dev/null)"
    SUPABASE_URL="${API_URL:-http://127.0.0.1:54321}"
    SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY:-}"
    [[ -n "$SUPABASE_SERVICE_ROLE_KEY" ]] || { echo "✗ SERVICE_ROLE_KEY missing from supabase status output." >&2; exit 1; }
    ;;
  linked)
    PROJECT_REF_FILE="$SCRIPT_DIR/../supabase/.temp/project-ref"
    [[ -f "$PROJECT_REF_FILE" ]] || { echo "✗ No linked project. Run \`supabase link --project-ref <ref>\` first." >&2; exit 1; }
    PROJECT_REF=$(tr -d '[:space:]' < "$PROJECT_REF_FILE")
    [[ -n "$PROJECT_REF" ]] || { echo "✗ $PROJECT_REF_FILE is empty." >&2; exit 1; }
    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
    KEYS_JSON=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null) || {
      echo "✗ \`supabase projects api-keys\` failed. Try \`supabase login\`." >&2; exit 1; }
    SUPABASE_SERVICE_ROLE_KEY=$(echo "$KEYS_JSON" \
      | jq -r 'map(select(.id == "service_role" or (.name == "service_role" and .type == "legacy"))) | .[0].api_key // empty')
    [[ -n "$SUPABASE_SERVICE_ROLE_KEY" && "$SUPABASE_SERVICE_ROLE_KEY" != "null" ]] || {
      echo "✗ Could not extract service_role key from CLI output." >&2; exit 1; }
    ;;
  prod)
    : "${SUPABASE_URL:?SUPABASE_URL is required for TARGET=prod}"
    : "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY is required for TARGET=prod}"
    ;;
  *) echo "✗ TARGET must be 'local', 'linked', or 'prod' (got '$TARGET')" >&2; exit 1 ;;
esac
SUPABASE_URL="${SUPABASE_URL%/}"

# On HTTP error the PostgREST body goes to stderr, not into the caller's jq.
rest() {
  local body
  body=$(curl -sS --fail-with-body "$@" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY") || {
    echo "✗ PostgREST request failed: $body" >&2; return 1; }
  printf '%s\n' "$body"
}

# Prints -1, 0 or 1 for a <, =, > b; missing parts count as 0.
semver_cmp() {
  local IFS=.
  local -a a=($1) b=($2)
  local i x y
  for i in 0 1 2; do
    x=$((10#${a[i]:-0})); y=$((10#${b[i]:-0}))
    (( x < y )) && { echo -1; return; }
    (( x > y )) && { echo 1; return; }
  done
  echo 0
}

if [[ "$CMD" == "get" ]]; then
  echo "Target: $TARGET ($SUPABASE_URL)"
  rest "$SUPABASE_URL/rest/v1/app_config?select=platform,min_version,updated_at&order=platform" \
    | jq -r '(["platform","min_version","updated_at"] | @tsv), (.[] | [.platform, .min_version, .updated_at] | @tsv)' \
    | column -t
  exit 0
fi

# ── set-min: check against the live store version ───────────────────────────

if [[ "$PLATFORM" == "ios" ]]; then
  STORE_VERSION=$(curl -fsS "https://itunes.apple.com/lookup?bundleId=$IOS_BUNDLE_ID&country=$IOS_COUNTRY" \
    | jq -r '.results[0].version // empty') || STORE_VERSION=""
  [[ "$STORE_VERSION" =~ $VERSION_RE ]] || STORE_VERSION=""
  if [[ -z "$STORE_VERSION" ]]; then
    echo "✗ Could not read a valid live App Store version for $IOS_BUNDLE_ID ($IOS_COUNTRY)." >&2
    $FORCE || { echo "  Re-run with --force to write anyway." >&2; exit 1; }
    echo "  --force given: writing without a store check." >&2
  else
    echo "Live App Store version: $STORE_VERSION"
    CMP=$(semver_cmp "$VERSION" "$STORE_VERSION") || CMP=""
    [[ "$CMP" =~ ^(-1|0|1)$ ]] || { echo "✗ Could not compare $VERSION with store version $STORE_VERSION." >&2; exit 1; }
    if [[ "$CMP" == "1" ]]; then
      if $FORCE; then
        echo "⚠ $VERSION is above the live store version $STORE_VERSION — writing anyway (--force)." >&2
      else
        echo "✗ $VERSION is above the live store version $STORE_VERSION; every iOS user would be locked out." >&2
        echo "  Wait for the release to go live, or re-run with --force." >&2
        exit 1
      fi
    fi
  fi
else
  if ! $FORCE; then
    echo "✗ Android: Google Play has no reliable public API for the live version, so this can't be checked." >&2
    echo "  Confirm in Play Console that $VERSION is live (production, 100% rollout), then re-run with --force." >&2
    exit 1
  fi
  echo "⚠ Android live version not checked (no public Play API) — trusting --force." >&2
fi

CURRENT=$(rest "$SUPABASE_URL/rest/v1/app_config?platform=eq.$PLATFORM&select=min_version" | jq -r '.[0].min_version // "none"')

echo "Target:  $TARGET ($SUPABASE_URL)"
echo "Change:  $PLATFORM min_version $CURRENT → $VERSION"

if [[ "$TARGET" != "local" ]] && ! { $TARGET_EXPLICIT && [[ "${AUTO_CONFIRM:-false}" == "true" ]]; }; then
  read -rp "Apply on '$TARGET'? [y/N] " CONFIRM || CONFIRM=""
  [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "  aborted." >&2; exit 1; }
fi

BODY=$(jq -nc --arg p "$PLATFORM" --arg v "$VERSION" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{platform: $p, min_version: $v, updated_at: $t}')

RESP=$(rest -X POST "$SUPABASE_URL/rest/v1/app_config?on_conflict=platform" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates,return=representation" \
  -d "$BODY")

echo "✓ $(echo "$RESP" | jq -r '.[0] | "\(.platform) min_version = \(.min_version) (updated \(.updated_at))"')"
