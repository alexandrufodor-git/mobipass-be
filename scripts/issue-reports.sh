#!/usr/bin/env bash
# List and download anonymous problem reports sent from the mobile app.
#
# Usage:
#   ./scripts/issue-reports.sh list [filters]
#   ./scripts/issue-reports.sh get <id-or-prefix>... [--out DIR]
#   ./scripts/issue-reports.sh get [filters] [--out DIR]       everything matching the filters
#
# Filters: --since 2d|12h|2026-10-05  --platform android|ios  --model Pixel
#          --version 1.6.0
#
# Env:
#   TARGET — linked (default) | local
#
# get unpacks each report to DIR/{date}_{platform}_{model}_{id8}/ (default ./issue-reports)
# and prints meta.json plus the session log files. Read-only: pruning lives in cron-audit.sh.
#
# Requires: curl, jq, unzip, python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-linked}"

usage() {
  sed -n '4,10p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2
  exit 1
}

for bin in curl jq unzip python3; do
  command -v "$bin" > /dev/null || { echo "✗ $bin is required" >&2; exit 1; }
done

CMD="${1:-}"; shift || true
[[ "$CMD" == list || "$CMD" == get ]] || usage

SINCE=""; PLATFORM=""; MODEL=""; VERSION=""; OUT="./issue-reports"; IDS=()
while (( $# )); do
  case "$1" in
    --since)     SINCE="$2"; shift 2 ;;
    --platform)  PLATFORM="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --version)   VERSION="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    -*) echo "✗ unknown flag: $1" >&2; usage ;;
    *) [[ "$1" =~ ^[0-9a-fA-F-]{4,36}$ ]] || { echo "✗ not a report id: $1" >&2; exit 1; }
       IDS+=("$(echo "$1" | tr 'A-F' 'a-f')"); shift ;;
  esac
done
[[ "$CMD" == list && ${#IDS[@]} -gt 0 ]] && usage
[[ -z "$PLATFORM" || "$PLATFORM" =~ ^(android|ios)$ ]] || { echo "✗ --platform must be android or ios" >&2; exit 1; }

# ── Resolve SUPABASE_URL + SERVICE_ROLE_KEY (no secrets stored) ──────────────

case "$TARGET" in
  local)
    supabase status -o env > /dev/null 2>&1 || { echo "✗ Supabase not running. Start it first: supabase start" >&2; exit 1; }
    eval "$(supabase status -o env 2>/dev/null)"
    SUPABASE_URL="${API_URL:-http://127.0.0.1:54321}"
    KEY="${SERVICE_ROLE_KEY:-}"
    ;;
  linked)
    PROJECT_REF=$(tr -d '[:space:]' < "$SCRIPT_DIR/../supabase/.temp/project-ref" 2>/dev/null) || true
    [[ -n "${PROJECT_REF:-}" ]] || { echo "✗ No linked project. Run \`supabase link --project-ref <ref>\` first." >&2; exit 1; }
    SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
    KEY=$(supabase projects api-keys --project-ref "$PROJECT_REF" --output json 2>/dev/null \
      | jq -r 'map(select(.id == "service_role" or (.name == "service_role" and .type == "legacy"))) | .[0].api_key // empty') || true
    ;;
  *) echo "✗ TARGET must be 'local' or 'linked' (got '$TARGET')" >&2; exit 1 ;;
esac
[[ -n "${KEY:-}" && "$KEY" != "null" ]] || { echo "✗ Could not resolve the service_role key." >&2; exit 1; }

api() { curl -sf -H "Authorization: Bearer ${KEY}" -H "apikey: ${KEY}" "$@"; }

# ── Query ────────────────────────────────────────────────────────────────────

since_iso() { # 2d | 12h | 2026-10-05 → ISO timestamp (UTC)
  python3 - "$1" <<'PY'
import sys, re, datetime as dt
v = sys.argv[1]; now = dt.datetime.now(dt.timezone.utc)
m = re.fullmatch(r"(\d+)([dhm])", v)
if m:
    n, unit = int(m[1]), m[2]
    unit = {"d": "days", "h": "hours", "m": "minutes"}[unit]
    print((now - dt.timedelta(**{unit: n})).strftime("%Y-%m-%dT%H:%M:%SZ"))
elif re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
    print(v + "T00:00:00Z")
else:
    sys.exit("✗ --since must look like 2d, 12h, 30m or 2026-10-05")
PY
}

FILTER="select=*&order=created_at.desc&limit=500"
[[ -n "$SINCE" ]]     && FILTER+="&created_at=gte.$(since_iso "$SINCE")"
[[ -n "$PLATFORM" ]]  && FILTER+="&platform=eq.${PLATFORM}"
[[ -n "$MODEL" ]]     && FILTER+="&device_model=ilike.*$(jq -rn --arg v "$MODEL" '$v|@uri')*"
[[ -n "$VERSION" ]]   && FILTER+="&app_version=eq.$(jq -rn --arg v "$VERSION" '$v|@uri')"

ROWS=$(api "${SUPABASE_URL}/rest/v1/issue_reports?${FILTER}") || { echo "✗ query failed" >&2; exit 1; }
if (( ${#IDS[@]} )); then
  ROWS=$(echo "$ROWS" | jq --args '[.[] | select(.id as $id | any($ARGS.positional[]; . as $p | $id | startswith($p)))]' "${IDS[@]}")
fi

if [[ "$CMD" == list ]]; then
  [[ "$(echo "$ROWS" | jq length)" == 0 ]] && { echo "(no reports)"; exit 0; }
  echo "$ROWS" | jq -r '
    ["id", "created (UTC)", "plat", "app/build", "device", "description"],
    (.[] | [.id[0:8], (.created_at[0:16] | sub("T"; " ")), .platform, "\(.app_version)/\(.build)",
            .device_model, (if .description == "" then "-" else .description[0:40] end)]) | @tsv' \
    | column -t -s $'\t'
  exit 0
fi

# ── get ──────────────────────────────────────────────────────────────────────

COUNT=$(echo "$ROWS" | jq length)
(( COUNT )) || { echo "✗ no matching reports" >&2; exit 1; }
mkdir -p "$OUT"
echo "$ROWS" | jq -c '.[]' | while read -r row; do
  id=$(jq -r .id <<< "$row")
  model=$(jq -r '.device_model | gsub("[^A-Za-z0-9,.-]"; "-")' <<< "$row")
  dir="$OUT/$(jq -r '.created_at[0:10]' <<< "$row")_$(jq -r .platform <<< "$row")_${model}_${id:0:8}"
  mkdir -p "$dir"
  api -o "$dir/report.zip" "${SUPABASE_URL}/storage/v1/object/issue-reports/$(jq -r .storage_path <<< "$row")" \
    || { echo "✗ ${id:0:8}: download failed (file pruned?)" >&2; continue; }
  unzip -qo "$dir/report.zip" -d "$dir" && rm "$dir/report.zip"
  # The app zips a diagnostics/ folder (meta.json + logs/); flatten it.
  if [[ -d "$dir/diagnostics" ]]; then cp -R "$dir/diagnostics/." "$dir/" && rm -rf "$dir/diagnostics"; fi
  echo "═══ ${id:0:8} → $dir ═══"
  [[ -f "$dir/meta.json" ]] && jq . "$dir/meta.json"
  echo "── sessions ──"
  ls -l "$dir/logs" 2>/dev/null | awk 'NR > 1 { printf "  %-40s %8d B\n", $9, $5 }'
done
