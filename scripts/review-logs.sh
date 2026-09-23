#!/usr/bin/env bash
# Pulls auth/edge request logs for a date range so an App Review session can be attributed
# by IP + user agent. See mobipass-mobile/app-review-rejection-1.5.2.md.
#
#   ./scripts/review-logs.sh 2026-08-01 2026-08-03            # auth requests in range
#   ./scripts/review-logs.sh 2026-08-01 2026-08-03 --all      # every request, not just /auth
#
# Retention is a PLAN property, not a setting: Free keeps ~1 day, Pro keeps 7. The Jul 23
# review-window logs were already gone because the project was on Free — which is why Pro
# must be active BEFORE a submission, not after a rejection.
#
# Auth: needs a Supabase personal access token (the CLI keeps its own in the macOS keychain
# and will not print it). Create one at https://supabase.com/dashboard/account/tokens then:
#   export SUPABASE_ACCESS_TOKEN=sbp_...
#
# The CLI has no `logs` command; this uses the Management API's analytics endpoint, which
# runs BigQuery SQL over the log buckets.

set -euo pipefail

FROM="${1:-}"
TO="${2:-}"
SCOPE="${3:-}"

if [[ -z "$FROM" || -z "$TO" ]]; then
  echo "usage: $0 <from-date> <to-date> [--all]" >&2
  echo "  dates are inclusive, YYYY-MM-DD (UTC)" >&2
  exit 1
fi

: "${SUPABASE_ACCESS_TOKEN:?set SUPABASE_ACCESS_TOKEN (https://supabase.com/dashboard/account/tokens)}"

PROJECT_REF="$(cat "$(dirname "$0")/../supabase/.temp/project-ref" 2>/dev/null || true)"
: "${PROJECT_REF:?could not read supabase/.temp/project-ref — run 'supabase link' first}"

PATH_FILTER="and request.path like '/auth/v1/%'"
[[ "$SCOPE" == "--all" ]] && PATH_FILTER=""

read -r -d '' SQL <<SQL || true
select
  cast(timestamp as datetime) as ts,
  request.method,
  request.path,
  response.status_code,
  h.cf_connecting_ip,
  h.user_agent
from edge_logs
cross join unnest(metadata) as m
cross join unnest(m.request) as request
cross join unnest(request.headers) as h
cross join unnest(m.response) as response
where timestamp >= '${FROM}T00:00:00Z'
  and timestamp < timestamp_add(timestamp '${TO}T00:00:00Z', interval 1 day)
  ${PATH_FILTER}
order by timestamp desc
limit 500
SQL

echo "→ project=$PROJECT_REF range=$FROM..$TO scope=${SCOPE:---auth-only}"

RESPONSE="$(curl -sS -G \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/analytics/endpoints/logs.all" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  --data-urlencode "sql=$SQL")"

if ! echo "$RESPONSE" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  echo "✗ unexpected response:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

echo "$RESPONSE" | python3 - <<'PY'
import json, sys
body = json.load(sys.stdin)
if isinstance(body, dict) and body.get("error"):
    print(f"✗ API error: {body['error']}", file=sys.stderr)
    sys.exit(1)
rows = body.get("result", body) if isinstance(body, dict) else body
if not rows:
    print("no rows — either no traffic in range, or the range is outside your plan's retention")
    sys.exit(0)
print(f"{'timestamp':<22} {'st':<4} {'method':<7} {'ip':<16} path / user-agent")
print("-" * 110)
for r in rows:
    ua = (r.get("user_agent") or "")[:60]
    print(f"{str(r.get('ts','')):<22} {str(r.get('status_code','')):<4} "
          f"{str(r.get('method','')):<7} {str(r.get('cf_connecting_ip','')):<16} "
          f"{r.get('path','')}")
    if ua:
        print(f"{'':<22} {'':<4} {'':<7} {'':<16} ↳ {ua}")
print(f"\n{len(rows)} rows. A non-Romanian IP or an iPad/CFNetwork user-agent identifies the reviewer.")
PY
