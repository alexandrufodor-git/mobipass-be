#!/bin/bash
# One-shot setup for the Maestro E2E test harness.
#
# Usage:
#   ./scripts/setup-e2e-vault.sh                 # default: --target=local
#   ./scripts/setup-e2e-vault.sh --target=local  # local-only, safe
#   ./scripts/setup-e2e-vault.sh --target=prod   # deploy to LINKED REMOTE
#   ./scripts/setup-e2e-vault.sh --no-serve      # skip managing functions serve
#                                                # (use when you're running it
#                                                # yourself in another terminal)
#
# Reuse existing values (local target):
#   E2E_SECRET=<hex> E2E_DEFAULT_PASSWORD=<pw> E2E_BIKE_ID=<uuid> \
#     ./scripts/setup-e2e-vault.sh
#
# What each target does:
#
#   --target=local (default)
#     0. (Re)start `supabase functions serve` in background
#        → logs: .supabase-functions-serve.log
#     1. Generate/upsert local Vault secrets  (docker psql)
#     2. Bootstrap local test accounts        (POST localhost:54321/e2e-seed)
#     3. Write ../mobi-pass/testing/maestro/.env.local-docker
#     → no network calls beyond your local Supabase. Nothing pushed.
#
#   --target=prod
#     1. Deploy e2e-seed + e2e-otp to the LINKED REMOTE PROJECT
#     → prod Vault + bootstrap remain manual (see "Prod recipe" at the end).

set -euo pipefail

TARGET="local"
MANAGE_SERVE=true
for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#--target=}" ;;
    --no-serve) MANAGE_SERVE=false ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

case "$TARGET" in
  local|prod) ;;
  *) echo "unknown target: $TARGET (expected local|prod)" >&2; exit 1 ;;
esac

echo "Target: $TARGET"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVE_LOG="$REPO_DIR/.supabase-functions-serve.log"
SERVE_PID_FILE="$REPO_DIR/.supabase-functions-serve.pid"

# ════════════════════════════════════════════════════════════════════════════
# Phase 0 (local only): (re)start `supabase functions serve` in background.
# Picks up edits to function code (no hot-reload otherwise). Logs go to
# .supabase-functions-serve.log in the repo root; PID is tracked so the next
# run kills the previous instance cleanly.
# ════════════════════════════════════════════════════════════════════════════

if [[ "$TARGET" == "local" && "$MANAGE_SERVE" == "true" ]]; then
  echo "═══ Phase 0: (re)start functions serve ═══"

  # Stop the previous instance we started (if any).
  if [[ -f "$SERVE_PID_FILE" ]]; then
    OLD_PID=$(cat "$SERVE_PID_FILE" 2>/dev/null || true)
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "  stopping previous serve (pid $OLD_PID)"
      kill "$OLD_PID" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$SERVE_PID_FILE"
  fi
  # Also reap any orphaned `supabase functions serve` we didn't track.
  pkill -f "supabase functions serve" 2>/dev/null || true
  sleep 1

  ENV_FLAG=()
  if [[ -f "$REPO_DIR/supabase/.env.local" ]]; then
    ENV_FLAG=(--env-file "supabase/.env.local")
  fi

  echo "  starting functions serve → tail -f $SERVE_LOG"
  ( cd "$REPO_DIR" && nohup supabase functions serve "${ENV_FLAG[@]}" \
      > "$SERVE_LOG" 2>&1 & echo $! > "$SERVE_PID_FILE" )
  disown 2>/dev/null || true

  # Wait for the runtime to be ready. Kong starts answering before the deno
  # module is loaded — during that window we get 502/503 "upstream invalid
  # response" with a gateway body. That window is the ONLY not-ready signal.
  # Once the deno module executes, e2e-seed returns its OWN response: a 503
  # {"error":"e2e_not_configured"} while Vault has no e2e_secret yet (Phase 1
  # below sets it), or 401/400/200 once configured. All of those prove the
  # runtime is up — so a function-level JSON reply counts as ready even when
  # the status is 503. Probing e2e-seed for readiness BEFORE Phase 1 would
  # otherwise deadlock: the 503 it legitimately returns is what Phase 1 fixes.
  echo -n "  waiting for serve to be ready"
  CODE="000"; READY=false; BODY_FILE="$(mktemp)"
  for _ in $(seq 1 30); do
    CODE=$(curl -sS -o "$BODY_FILE" -w "%{http_code}" -m 2 \
      -X POST "http://127.0.0.1:54321/functions/v1/e2e-seed" 2>/dev/null || echo "000")
    if grep -q 'e2e_not_configured' "$BODY_FILE" 2>/dev/null; then
      echo " ✓ ($CODE e2e_not_configured — runtime up; Vault set in Phase 1)"
      READY=true; break
    fi
    case "$CODE" in
      000|502|503|504) echo -n "." ; sleep 1 ;;
      *) echo " ✓ ($CODE)" ; READY=true; break ;;
    esac
  done
  rm -f "$BODY_FILE"
  if [[ "$READY" != "true" ]]; then
    echo " ✗"
    echo "  serve didn't come up — check $SERVE_LOG" >&2
    exit 1
  fi
  echo
fi

# ════════════════════════════════════════════════════════════════════════════
# --target=prod : deploy edge functions to the LINKED REMOTE PROJECT, then exit.
# ════════════════════════════════════════════════════════════════════════════

if [[ "$TARGET" == "prod" ]]; then
  echo "═══ Deploy functions to LINKED REMOTE PROJECT ═══"
  if ! command -v supabase > /dev/null; then
    echo "✗ supabase CLI not found (install: brew install supabase/tap/supabase)" >&2
    exit 1
  fi
  echo "  ⚠ this is a write to PRODUCTION (the linked project)."
  echo "  ⚠ make sure your local function code is in the state you want to ship."
  read -rp "  Proceed? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "  aborted."
    exit 1
  fi
  supabase functions deploy e2e-seed --no-verify-jwt
  supabase functions deploy e2e-otp  --no-verify-jwt
  echo
  echo "✓ deployed. Prod Vault + bootstrap are manual — see the recipe below."
  cat <<EOF

═══ Prod recipe (manual steps after deploy) ═══

1. Dashboard SQL editor (set Vault secrets):
   SELECT vault.create_secret('<E2E_SECRET>',           'e2e_secret');
   SELECT vault.create_secret('<E2E_DEFAULT_PASSWORD>', 'e2e_default_password');
   SELECT vault.create_secret('<E2E_BIKE_ID_UUID>',     'e2e_bike_id');

2. Bootstrap accounts:
   curl -sS -X POST "\$SUPABASE_URL/functions/v1/e2e-seed" \\
     -H "X-E2E-Secret: \$E2E_SECRET" \\
     -H "Content-Type: application/json" \\
     -d '{"command":"bootstrap"}'

To rotate secrets:
   DELETE FROM vault.secrets WHERE name = 'e2e_secret';
   SELECT vault.create_secret('<new>', 'e2e_secret');
EOF
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# --target=local : local Vault + bootstrap + Maestro env file.
# ════════════════════════════════════════════════════════════════════════════

CONTAINER="supabase_db_mobi-pass-be"
LOCAL_FUNCTIONS_URL="http://127.0.0.1:54321/functions/v1"

# ─── Phase 1: Vault secrets ──────────────────────────────────────────────────

echo "═══ Phase 1: Vault secrets (local) ═══"

if [[ -n "${E2E_SECRET:-}" ]]; then
  SECRET="$E2E_SECRET"
  echo "Using supplied E2E_SECRET (${#SECRET} chars)"
else
  SECRET=$(openssl rand -hex 32)
  echo "Generated new E2E_SECRET:"
  echo "  $SECRET"
fi

if [[ -n "${E2E_DEFAULT_PASSWORD:-}" ]]; then
  PASSWORD="$E2E_DEFAULT_PASSWORD"
  echo "Using supplied E2E_DEFAULT_PASSWORD"
else
  PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)
  echo "Generated new E2E_DEFAULT_PASSWORD:"
  echo "  $PASSWORD"
fi

if [[ -n "${E2E_BIKE_ID:-}" ]]; then
  BIKE_ID="$E2E_BIKE_ID"
  echo "Using supplied E2E_BIKE_ID: $BIKE_ID"
else
  echo "Looking up first bike in local DB..."
  BIKE_ID=$(docker exec "$CONTAINER" psql -U postgres -At -c \
    "SELECT id FROM public.bikes ORDER BY created_at LIMIT 1;")
  if [[ -z "$BIKE_ID" ]]; then
    echo "✗ no bikes in DB — run \`supabase db reset\`, then re-run" >&2
    exit 1
  fi
  echo "Using first bike: $BIKE_ID"
fi

upsert_secret() {
  local name=$1 value=$2
  docker exec "$CONTAINER" psql -U postgres -c \
    "DELETE FROM vault.secrets WHERE name = '$name';" > /dev/null
  docker exec "$CONTAINER" psql -U postgres -c \
    "SELECT vault.create_secret('$value', '$name');" > /dev/null
  echo "  ✓ $name"
}

echo
upsert_secret "e2e_secret"           "$SECRET"
upsert_secret "e2e_default_password" "$PASSWORD"
upsert_secret "e2e_bike_id"          "$BIKE_ID"

docker exec "$CONTAINER" psql -U postgres -c \
  "SELECT name, LENGTH(decrypted_secret) AS len
   FROM vault.decrypted_secrets
   WHERE name LIKE 'e2e_%' ORDER BY name;"

# ─── Phase 2: Bootstrap test accounts (local) ────────────────────────────────

echo
echo "═══ Phase 2: Bootstrap accounts (local) ═══"

# The local Supabase gateway requires an Authorization header to route the
# request even when the function itself has verify_jwt = false. The anon key
# is sufficient — verify_jwt = false makes the function ignore the JWT.
ANON_KEY=$(supabase status -o env 2>/dev/null | grep '^ANON_KEY=' | cut -d= -f2- | tr -d '"')
if [[ -z "$ANON_KEY" ]]; then
  echo "✗ couldn't read ANON_KEY from \`supabase status\` — is Supabase running?" >&2
  exit 1
fi

# Retry on transient gateway errors (502/503 during deno cold-start). Each
# attempt has a 30s timeout so a genuinely broken function can't hang forever.
for attempt in 1 2 3; do
  BOOTSTRAP=$(curl -sS -m 30 -X POST "$LOCAL_FUNCTIONS_URL/e2e-seed" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "X-E2E-Secret: $SECRET" \
    -H "Content-Type: application/json" \
    -d '{"command":"bootstrap"}')
  if [[ "$BOOTSTRAP" == *'"ok":true'* ]]; then
    break
  fi
  if [[ "$BOOTSTRAP" == *"upstream"* || "$BOOTSTRAP" == *"upstream server"* ]] && [[ $attempt -lt 3 ]]; then
    echo "  attempt $attempt: gateway 502 (cold start) — retrying in 2s"
    sleep 2
    continue
  fi
  break
done
echo "$BOOTSTRAP"
if [[ "$BOOTSTRAP" != *'"ok":true'* ]]; then
  echo "✗ bootstrap failed — see $SERVE_LOG for the function error" >&2
  exit 1
fi

# ─── Phase 3: Cross-repo Maestro env file ────────────────────────────────────

echo
echo "═══ Phase 3: Write Maestro env file ═══"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAESTRO_DIR="$SCRIPT_DIR/../../mobi-pass/testing/maestro"
if [[ -d "$MAESTRO_DIR" ]]; then
  ENV_FILE="$MAESTRO_DIR/.env.local-docker"
  cat > "$ENV_FILE" <<EOF
# Auto-generated by mobi-pass-be/scripts/setup-e2e-vault.sh.
# Values match the LOCAL Supabase Vault. Re-run the script to refresh.
export SUPABASE_URL=http://127.0.0.1:54321
export E2E_SECRET=$SECRET
export E2E_DEFAULT_PASSWORD=$PASSWORD
# Local gateway requires an Authorization header even for verify_jwt=false
# functions. The anon key satisfies the gateway; the function itself ignores
# the JWT. Not set in the hosted env file because the hosted functions were
# deployed with --no-verify-jwt which skips the gateway check entirely.
export SUPABASE_ANON_KEY=$ANON_KEY
EOF
  echo "  ✓ wrote $ENV_FILE"
else
  echo "  (skipped — mobi-pass not found at $MAESTRO_DIR)"
fi

# ─── Phase 4: Sync local publishable key into mobi-pass local.properties ────
#
# The local Supabase publishable key rotates on every `supabase start` cycle,
# which would silently break the mobile app's `supabase_env=local` build. Keep
# the `supabase_api_key_local` slot in sync automatically. Other env slots
# (staging, prod) are never touched.
#
# We sync the PUBLISHABLE_KEY (sb_publishable_*), not the legacy ANON_KEY
# (eyJ... JWT). The legacy JWT requires both `apikey` AND `Authorization:
# Bearer` headers on the same request to satisfy the gateway, but the mobile's
# HttpClientFactory only attaches Authorization when a user token is present
# (e.g. not on /functions/v1/register). The publishable key is accepted with
# just the `apikey` header, so it works for both authenticated and public
# endpoints from the mobile client.

PUBLISHABLE_KEY=$(supabase status -o env 2>/dev/null | grep '^PUBLISHABLE_KEY=' | cut -d= -f2- | tr -d '"')
MOBI_LOCAL_PROPS="$SCRIPT_DIR/../../mobi-pass/local.properties"
if [[ -z "$PUBLISHABLE_KEY" ]]; then
  echo "  (skipped — couldn't read PUBLISHABLE_KEY from \`supabase status\`)" >&2
elif [[ -f "$MOBI_LOCAL_PROPS" ]]; then
  if grep -q '^supabase_api_key_local=' "$MOBI_LOCAL_PROPS"; then
    # Portable in-place edit (BSD/GNU sed differ on -i).
    tmp="$(mktemp)"
    awk -v key="$PUBLISHABLE_KEY" '
      /^supabase_api_key_local=/ { print "supabase_api_key_local=" key; next }
      { print }
    ' "$MOBI_LOCAL_PROPS" > "$tmp" && mv "$tmp" "$MOBI_LOCAL_PROPS"
    echo "  ✓ synced supabase_api_key_local in $MOBI_LOCAL_PROPS"
  else
    echo "  (skipped — no supabase_api_key_local= line in $MOBI_LOCAL_PROPS;" >&2
    echo "   add it manually then re-run this script to keep it auto-synced)" >&2
  fi
else
  echo "  (skipped — $MOBI_LOCAL_PROPS not found)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo
echo "═══ Done — local E2E loop ═══"
echo
echo "1. Set supabase_env=local in mobi-pass/local.properties and rebuild the app"
echo "   (the local key was just synced for you — no manual edit needed)"
echo "2. cd ../mobi-pass && ./testing/maestro/run.sh <flow> --target=local --platform=android"
echo
echo "To ship function code to prod when ready:"
echo "   ./scripts/setup-e2e-vault.sh --target=prod"
echo
