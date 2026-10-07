#!/bin/bash
# ============================================================
# issue-report — end-to-end against the local stack
# ============================================================
# No/forged JWT → 401; upload → row + file exist → duplicate/validation rejects →
# issue-report-prune → prune_maintenance() via pg_net → both gone.
#
# Creates the local Vault webhook secret + base URL if missing (local only).
# Prereqs: supabase start (edge runtime started after the function existed)
# ============================================================
set -euo pipefail

DB_CONTAINER="supabase_db_mobi-pass-be"
URL="http://127.0.0.1:54321/functions/v1/issue-report"
PRUNE_URL="http://127.0.0.1:54321/functions/v1/issue-report-prune"
JWT_SECRET="super-secret-jwt-token-with-at-least-32-characters-long"
ID1="0e0e0e0e-0000-4000-8000-00000000e001"
ID2="0e0e0e0e-0000-4000-8000-00000000e002"
ORPHAN="android/2020-01-01/0e0e0e0e-0000-4000-8000-00000000e003.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

db() { docker exec -i "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -tAc "$1"; }

FAIL=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1 — expected '$2', got '$3'"; FAIL=1; fi
}

meta() { # id [description]
  printf '{"report_id":"%s","trigger":"settings","platform":"android","app_version":"1.6.0","build":"39","os_version":"Android 14","device_manufacturer":"Google","device_model":"Pixel 7","description":"%s"}' "$1" "${2:-}"
}

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mint() {
  local now exp h p s
  now=$(date +%s); exp=$((now + 3600))
  h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64)
  p=$(printf '%s' "{\"sub\":\"$1\",\"role\":\"authenticated\",\"aud\":\"authenticated\",\"exp\":${exp},\"iat\":${now}}" | b64)
  s=$(printf '%s' "${h}.${p}" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64)
  printf '%s' "${h}.${p}.${s}"
}
JWT=$(mint "0e0e0e0e-0000-4000-8000-0000000000aa")

post() { # meta file [auth header] [extra curl args…] → http status
  curl -s -o "$TMP/out.json" -w '%{http_code}' -X POST "$URL" -H "${3:-Authorization: Bearer ${JWT}}" \
    -F "meta=$1" -F "file=@$2;type=application/zip" "${@:4}"
}

SERVICE_KEY=$(supabase status -o env 2>/dev/null | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')

# Storage rejects SQL deletes, so files go through the Storage API.
cleanup() {
  local paths
  paths=$(db "SELECT coalesce(json_agg(name), '[]') FROM storage.objects
              WHERE bucket_id = 'issue-reports' AND name ~ '0e0e0e0e-0000-4000-8000-00000000e00[123]'")
  curl -s -o /dev/null -X DELETE "http://127.0.0.1:54321/storage/v1/object/issue-reports" \
    -H "Authorization: Bearer ${SERVICE_KEY}" -H "apikey: ${SERVICE_KEY}" \
    -H 'Content-Type: application/json' -d "{\"prefixes\":${paths}}"
  db "DELETE FROM public.issue_reports WHERE id IN ('${ID1}','${ID2}')" > /dev/null
}

echo "═══ Fixture ═══"
cleanup
db "SELECT vault.create_secret('local-issue-report-test', 'bike_sync_webhook_secret')
    WHERE NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'bike_sync_webhook_secret');
    SELECT vault.create_secret('http://supabase_kong_mobi-pass-be:8000', 'bike_sync_base_url')
    WHERE NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'bike_sync_base_url');" > /dev/null
SECRET=$(db "SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'bike_sync_webhook_secret'")
echo "2026-10-07T09:41:12.381Z D/Settings: test line" > "$TMP/s_01.log"
(cd "$TMP" && zip -q report.zip s_01.log)
printf 'not a zip' > "$TMP/fake.zip"
echo "  ✓ secret + zip ready"

echo "═══ Upload ═══"
check "no JWT → 401" 401 "$(post "$(meta "$ID1")" "$TMP/report.zip" "X-None: 1")"
check "forged JWT signature → 401" 401 "$(post "$(meta "$ID1")" "$TMP/report.zip" "Authorization: Bearer ${JWT%.*}.forged")"
check "valid report → 201" 201 "$(post "$(meta "$ID1" 'blurred for me@firm.ro')" "$TMP/report.zip")"
check "row written, description scrubbed" "android|<redacted:email>" \
  "$(db "SELECT platform || '|' || split_part(description, ' ', 3) FROM public.issue_reports WHERE id = '${ID1}'")"
PATH1=$(db "SELECT storage_path FROM public.issue_reports WHERE id = '${ID1}'")
check "file stored at the row's path" 1 "$(db "SELECT count(*) FROM storage.objects WHERE bucket_id = 'issue-reports' AND name = '${PATH1}'")"
check "same report_id → 409" 409 "$(post "$(meta "$ID1")" "$TMP/report.zip")"
check "not a zip → 400" 400 "$(post "$(meta "$ID2")" "$TMP/fake.zip")"
check "bad platform → 400" 400 "$(post "$(meta "$ID2" | sed 's/android/web/')" "$TMP/report.zip")"
head -c 6000000 /dev/zero > "$TMP/big.bin"
check "oversized chunked body → 413" 413 "$(post "$(meta "$ID2")" "$TMP/big.bin" "Authorization: Bearer ${JWT}" -H 'Transfer-Encoding: chunked')"
check "nothing stored for rejects" 0 "$(db "SELECT count(*) FROM public.issue_reports WHERE id = '${ID2}'")"

echo "═══ Prune (issue-report-prune) ═══"
check "no secret → 401" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PRUNE_URL" \
  -H 'Content-Type: application/json' -d '{"keep_days":14}')"
db "UPDATE public.issue_reports SET created_at = now() - interval '20 days' WHERE id = '${ID1}'" > /dev/null
curl -s -X POST "$PRUNE_URL" -H 'Content-Type: application/json' -H "x-webhook-secret: ${SECRET}" \
  -d '{"keep_days":14}' > "$TMP/prune.json"
check "prune reports deleted ≥ 1" true "$(python3 -c "import json;print(str(json.load(open('$TMP/prune.json'))['deleted']>=1).lower())")"
check "row gone" 0 "$(db "SELECT count(*) FROM public.issue_reports WHERE id = '${ID1}'")"
check "file gone" 0 "$(db "SELECT count(*) FROM storage.objects WHERE bucket_id = 'issue-reports' AND name = '${PATH1}'")"

echo "═══ Prune sweeps a zip that has no row ═══"
orphan() { # upload a row-less zip in an old day folder; prints how many exist
  curl -s -o /dev/null -X POST "http://127.0.0.1:54321/storage/v1/object/issue-reports/${ORPHAN}" \
    -H "Authorization: Bearer ${SERVICE_KEY}" -H "apikey: ${SERVICE_KEY}" -H 'Content-Type: application/zip' \
    --data-binary "@$TMP/report.zip"
  db "UPDATE storage.objects SET created_at = now() - interval '20 days' WHERE bucket_id = 'issue-reports' AND name = '${ORPHAN}'" > /dev/null
  orphans
}
orphans() { db "SELECT count(*) FROM storage.objects WHERE bucket_id = 'issue-reports' AND name = '${ORPHAN}'"; }
check "orphan zip stored" 1 "$(orphan)"
curl -s -X POST "$PRUNE_URL" -H 'Content-Type: application/json' -H "x-webhook-secret: ${SECRET}" \
  -d '{"keep_days":14}' > "$TMP/prune.json"
check "prune reports orphans ≥ 1" true "$(python3 -c "import json;print(str(json.load(open('$TMP/prune.json'))['orphans']>=1).lower())")"
check "orphan zip gone" 0 "$(orphans)"
check "orphan stored again" 1 "$(orphan)"
check "an orphan alone triggers the cron request" t "$(db "SELECT public.request_issue_reports_prune(14) IS NOT NULL")"
for _ in $(seq 1 20); do [ "$(orphans)" = 0 ] && break; sleep 0.5; done
check "cron request swept it" 0 "$(orphans)"

echo "═══ Prune (prune_maintenance → pg_net) ═══"
check "second report → 201" 201 "$(post "$(meta "$ID2")" "$TMP/report.zip")"
PATH2=$(db "SELECT storage_path FROM public.issue_reports WHERE id = '${ID2}'")
db "UPDATE public.issue_reports SET created_at = now() - interval '20 days' WHERE id = '${ID2}'" > /dev/null
check "prune_maintenance queues a request" t \
  "$(db "SELECT (public.prune_maintenance() ->> 'issue_reports_request') IS NOT NULL")"
for _ in $(seq 1 20); do
  [ "$(db "SELECT count(*) FROM public.issue_reports WHERE id = '${ID2}'")" = 0 ] && break
  sleep 0.5
done
check "row gone" 0 "$(db "SELECT count(*) FROM public.issue_reports WHERE id = '${ID2}'")"
check "file gone" 0 "$(db "SELECT count(*) FROM storage.objects WHERE bucket_id = 'issue-reports' AND name = '${PATH2}'")"

cleanup
echo
[ "$FAIL" = 0 ] && echo "All issue-report checks passed." || { echo "Some checks FAILED."; exit 1; }
