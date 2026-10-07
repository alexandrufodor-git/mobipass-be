#!/usr/bin/env bash
# Deploy all edge functions listed in config.toml, honoring each one's
# verify_jwt setting. Works around the CLI bug where `supabase functions
# deploy` (bulk) ignores `verify_jwt = false` from config.toml.
#
# Usage: ./scripts/deploy-functions.sh [function_name ...]
#   - No args: deploy every [functions.X] block in config.toml
#   - With args: deploy only the named functions (still reads their flag from config.toml)

set -euo pipefail

CONFIG="${CONFIG:-supabase/config.toml}"

if [[ ! -f "$CONFIG" ]]; then
  echo "error: $CONFIG not found (run from repo root)" >&2
  exit 1
fi

# Extract: "<name>|<verify_jwt>" for every [functions.X] block.
# (while-read loop for bash 3.2 compatibility — macOS default.)
ENTRIES=()
while IFS= read -r line; do
  ENTRIES+=("$line")
done < <(
  awk '
    /^\[/ {
      if (name != "") { print name "|" jwt; name = "" }
      if ($0 ~ /^\[functions\./) {
        n = $0
        sub(/^\[functions\./, "", n)
        sub(/\].*$/, "", n)
        name = n
        jwt = "true"
      }
      next
    }
    /^verify_jwt[[:space:]]*=/ && name != "" {
      v = $0
      sub(/^[^=]*=[[:space:]]*/, "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      jwt = v
    }
    END {
      if (name != "") print name "|" jwt
    }
  ' "$CONFIG"
)

if (( $# > 0 )); then
  FILTER=" $* "
else
  FILTER=""
fi

for entry in "${ENTRIES[@]}"; do
  name="${entry%%|*}"
  jwt="${entry##*|}"

  if [[ -n "$FILTER" && "$FILTER" != *" $name "* ]]; then
    continue
  fi

  if [[ "$jwt" == "false" ]]; then
    echo "→ $name (verify_jwt=false)"
    supabase functions deploy "$name" --no-verify-jwt
  else
    echo "→ $name (verify_jwt=true)"
    supabase functions deploy "$name"
  fi
done
