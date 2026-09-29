#!/bin/bash
# ============================================================
# onboarding-action — end-to-end against the local stack
# ============================================================
# Walks one employee through every action and checks the bike_benefits row
# after each call matches what the mobile app used to write directly. Runs the
# commit twice: copilot off (→ sign_contract) and copilot on (stays on step 3).
#
# Prereqs: supabase start (edge runtime started after the function existed)
# ============================================================
set -euo pipefail

DB_CONTAINER="supabase_db_mobi-pass-be"
FUNCTIONS_URL="http://127.0.0.1:54321/functions/v1"
JWT_SECRET="super-secret-jwt-token-with-at-least-32-characters-long"

USER_ID="0a0a0a0a-0000-4000-8000-00000000a001"
OTHER_ID="0a0a0a0a-0000-4000-8000-00000000a002"
DOMAIN="onbact.test"

db() { docker exec -i "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -tAc "$1"; }

FAIL=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1 — expected '$2', got '$3'"; FAIL=1; fi
}

# Normal deletes (no replica mode) so FK cascades clear derived rows like company_metrics.
cleanup() {
  db "
  DELETE FROM public.bike_benefits WHERE user_id IN ('${USER_ID}','${OTHER_ID}');
  DELETE FROM auth.users           WHERE id      IN ('${USER_ID}','${OTHER_ID}');
  DELETE FROM public.companies     WHERE email_domain = '${DOMAIN}';" > /dev/null
}

echo "═══ Fixture ═══"
cleanup
db "
BEGIN;
SET LOCAL session_replication_role = replica;
DELETE FROM public.bike_benefits WHERE user_id IN ('${USER_ID}','${OTHER_ID}');
DELETE FROM public.user_roles    WHERE user_id IN ('${USER_ID}','${OTHER_ID}');
DELETE FROM public.profiles      WHERE user_id IN ('${USER_ID}','${OTHER_ID}');
DELETE FROM auth.users           WHERE id      IN ('${USER_ID}','${OTHER_ID}');
INSERT INTO public.companies (id, name, email_domain, contract_months, monthly_benefit_subsidy)
VALUES ('0a0a0a0a-0000-4000-8000-0000000c0001', 'onboarding-action test', '${DOMAIN}', 12, 100);
-- Token columns must be '' not NULL, or GoTrue's admin user listing fails.
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
                        confirmation_token, email_change, email_change_token_new, recovery_token)
VALUES ('00000000-0000-0000-0000-000000000000', '${USER_ID}',  'authenticated', 'authenticated', 'emp@${DOMAIN}',   '', now(), now(), now(), '{}', '{}', '', '', '', ''),
       ('00000000-0000-0000-0000-000000000000', '${OTHER_ID}', 'authenticated', 'authenticated', 'other@${DOMAIN}', '', now(), now(), now(), '{}', '{}', '', '', '', '');
INSERT INTO public.profiles (user_id, email, first_name, last_name, company_id)
VALUES ('${USER_ID}',  'emp@${DOMAIN}',   'Emp',   'Test', '0a0a0a0a-0000-4000-8000-0000000c0001'),
       ('${OTHER_ID}', 'other@${DOMAIN}', 'Other', 'Test', '0a0a0a0a-0000-4000-8000-0000000c0001');
INSERT INTO public.user_roles (user_id, role) VALUES ('${USER_ID}', 'employee'), ('${OTHER_ID}', 'employee');
COMMIT;
INSERT INTO public.bike_benefits (user_id, step) VALUES ('${OTHER_ID}', 'book_live_test');
" > /dev/null
BIKE_ID=$(db "SELECT id FROM public.bikes ORDER BY created_at LIMIT 1")
[ -n "$BIKE_ID" ] || { echo "  no bikes in local DB"; exit 1; }
echo "  ✓ company, 2 employees, bike ${BIKE_ID}"

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mint() {
  local now exp h p s
  now=$(date +%s); exp=$((now + 3600))
  h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64)
  p=$(printf '%s' "{\"sub\":\"$1\",\"role\":\"authenticated\",\"user_role\":\"employee\",\"aud\":\"authenticated\",\"exp\":${exp},\"iat\":${now}}" | b64)
  s=$(printf '%s' "${h}.${p}" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64)
  echo "${h}.${p}.${s}"
}
JWT=$(mint "$USER_ID")
CHOOSE_BODY="{\"action\":\"choose_bike_for_test\",\"bike_id\":\"${BIKE_ID}\"}"
COMMIT_DETAILS_BODY="{\"action\":\"commit_from_details\",\"bike_id\":\"${BIKE_ID}\"}"

call() { # body → prints http status
  curl -s -o /tmp/onbact.json -w "%{http_code}" -X POST "${FUNCTIONS_URL}/onboarding-action" \
    -H "Authorization: Bearer ${JWT}" -H "Content-Type: application/json" -d "$1"
}
row() { db "SELECT $1 FROM public.bike_benefits WHERE user_id = '${USER_ID}'"; }

echo
echo "═══ Guards ═══"
check "no JWT → 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${FUNCTIONS_URL}/onboarding-action" -d '{"action":"start"}')"
check "unknown action → 400" "400" "$(call '{"action":"sign_contract"}')"
check "choose_bike_for_test without bike_id → 400" "400" "$(call '{"action":"choose_bike_for_test"}')"
check "test_interest with no benefit → 400" "400" "$(call '{"action":"test_interest"}')"

echo
echo "═══ Walk: copilot off ═══"
check "start (creates benefit) → 200" "200" "$(call '{"action":"start"}')"
check "  step" "choose_bike" "$(row step)"
check "  response has bike join key" "true" "$(python3 -c 'import json;print(str("bike" in json.load(open("/tmp/onbact.json"))).lower())')"
check "choose_bike_for_test → 200" "200" "$(call "$CHOOSE_BODY")"
check "  step, bike" "book_live_test|${BIKE_ID}" "$(row "step || '|' || bike_id")"
check "test_interest → 200" "200" "$(call '{"action":"test_interest"}')"
check "  step unchanged, live_test_sent_at set" "book_live_test|true" "$(row "step || '|' || (live_test_sent_at IS NOT NULL)")"
check "commit_from_details → 200" "200" "$(call "$COMMIT_DETAILS_BODY")"
check "  step, no committed_at, status testing" "commit_to_bike|false|testing" "$(row "step || '|' || (committed_at IS NOT NULL) || '|' || benefit_status")"
check "commit → 200" "200" "$(call '{"action":"commit"}')"
check "  step sign_contract, committed, no copilot stamp, active" "sign_contract|true|false|active" "$(row "step || '|' || (committed_at IS NOT NULL) || '|' || (copilot_stopped_at IS NOT NULL) || '|' || benefit_status")"
check "confirm_pickup → 200" "200" "$(call '{"action":"confirm_pickup"}')"
check "  delivered_at set" "t" "$(row "delivered_at IS NOT NULL")"
check "reset → 200" "200" "$(call '{"action":"reset"}')"
check "  step choose_bike, stamps cleared" "choose_bike|false|false|false" "$(row "step || '|' || (live_test_sent_at IS NOT NULL) || '|' || (committed_at IS NOT NULL) || '|' || (delivered_at IS NOT NULL)")"

echo
echo "═══ Walk: copilot on ═══"
db "UPDATE public.companies SET copilot_stop_after_commit = true WHERE email_domain = '${DOMAIN}'" > /dev/null
call "$CHOOSE_BODY" > /dev/null
call "$COMMIT_DETAILS_BODY" > /dev/null
check "commit → 200" "200" "$(call '{"action":"commit"}')"
check "  stays commit_to_bike, committed, copilot stamp set" "commit_to_bike|true|true" "$(row "step || '|' || (committed_at IS NOT NULL) || '|' || (copilot_stopped_at IS NOT NULL)")"
check "reset → 200" "200" "$(call '{"action":"reset"}')"
check "  copilot stamp cleared" "f" "$(row "copilot_stopped_at IS NOT NULL")"

echo
echo "═══ Copilot test day: interest locks, confirm unlocks after the test ═══"
db "UPDATE public.companies SET live_test_at = now() + interval '1 day' WHERE email_domain = '${DOMAIN}'" > /dev/null
check "choose_bike_for_test (before lock) → 200" "200" "$(call "$CHOOSE_BODY")"
check "test_interest → 200" "200" "$(call '{"action":"test_interest"}')"
check "  response: locked, label set, not confirmable" "true|true|false" "$(python3 -c 'import json;c=json.load(open("/tmp/onbact.json"))["copilot"];print(str(c["locked"]).lower()+"|"+str(c["live_test_label"] is not None).lower()+"|"+str(c["test_confirmable"]).lower())')"
check "choose_bike_for_test when locked → 409" "409" "$(call "$CHOOSE_BODY")"
check "commit_from_details when locked → 409" "409" "$(call "$COMMIT_DETAILS_BODY")"
check "start (Choose another ebike) when locked → 409" "409" "$(call '{"action":"start"}')"
check "  still on step 2" "book_live_test" "$(row step)"
check "confirm_test before the test → 409" "409" "$(call '{"action":"confirm_test"}')"
db "UPDATE public.companies SET live_test_at = now() - interval '1 hour' WHERE email_domain = '${DOMAIN}'" > /dev/null
check "confirm_test after test + offset → 200" "200" "$(call '{"action":"confirm_test"}')"
check "  step commit_to_bike, checked in" "commit_to_bike|true" "$(row "step || '|' || (live_test_checked_in_at IS NOT NULL)")"
check "commit → 200" "200" "$(call '{"action":"commit"}')"
check "  stays commit_to_bike, copilot stamp set" "commit_to_bike|true" "$(row "step || '|' || (copilot_stopped_at IS NOT NULL)")"
check "reset (allowed when locked) → 200" "200" "$(call '{"action":"reset"}')"
check "  back to choose_bike, test stamps cleared" "choose_bike|false|false" "$(row "step || '|' || (live_test_sent_at IS NOT NULL) || '|' || (live_test_checked_in_at IS NOT NULL)")"

echo
echo "═══ Isolation ═══"
check "other employee's benefit untouched" "book_live_test" "$(db "SELECT step FROM public.bike_benefits WHERE user_id = '${OTHER_ID}'")"

cleanup

echo
[ "$FAIL" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
