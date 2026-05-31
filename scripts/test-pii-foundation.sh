#!/usr/bin/env bash
# ============================================================================
# PII Foundation — Integration Test Script
# ============================================================================
# Prerequisites:
#   supabase start && supabase db reset
#   supabase functions serve --env-file supabase/.env.local  (in another terminal)
# ============================================================================

set -euo pipefail

# ── Preflight checks ────────────────────────────────────────────────────────
echo "╭──────────────────────────────────────────────────────╮"
echo "│ PII Foundation — Integration Tests                   │"
echo "╰──────────────────────────────────────────────────────╯"
echo ""
echo "Setup checklist (run these if starting fresh):"
echo "  1. supabase start"
echo "  2. supabase db reset"
echo "  3. Create supabase/.env.local with:"
echo "     PII_ENCRYPTION_KEY=\$(openssl rand -base64 32)"
echo "  4. supabase functions serve --env-file supabase/.env.local"
echo "     (in a separate terminal)"
echo ""

# Check supabase is running
if ! supabase status -o env > /dev/null 2>&1; then
  echo "✗ Supabase is not running. Run: supabase start && supabase db reset"
  exit 1
fi

# Check .env.local exists
if [ ! -f "supabase/.env.local" ]; then
  echo "✗ supabase/.env.local not found. Create it with:"
  echo "  echo \"PII_ENCRYPTION_KEY=\$(openssl rand -base64 32)\" > supabase/.env.local"
  exit 1
fi

echo "Loading config from supabase status..."

# ── Config (from supabase status) ────────────────────────────────────────────
eval "$(supabase status -o env 2>/dev/null)"

# Use local psql if available, otherwise use Docker container
if command -v psql &> /dev/null; then
  PSQL="psql $DB_URL -qtAX"
else
  DB_CONTAINER=$(docker ps --filter "name=supabase_db_" --format "{{.Names}}" | head -1)
  if [ -z "$DB_CONTAINER" ]; then
    echo "✗ No psql found and no supabase_db container running"
    exit 1
  fi
  PSQL="docker exec $DB_CONTAINER psql -U postgres -qtAX"
fi
PASS=0
FAIL=0
TOTAL=0

# Seed user IDs
EMP_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
HR_ID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
EMP_EMAIL="employee@example.com"
HR_EMAIL="hr@example.com"
COMPANY_ID="11111111-1111-1111-1111-111111111111"

# ── Helpers ──────────────────────────────────────────────────────────────────

check() {
  TOTAL=$((TOTAL + 1))
  local label="$1"
  local result="$2"
  if [ "$result" = "true" ] || [ "$result" = "1" ] || [ "$result" = "PASS" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label"
  fi
}

section() {
  echo ""
  echo "── $1 ──"
}

# Generate a JWT for a given user_id and role using the local JWT secret
make_jwt() {
  local user_id="$1"
  local role="$2"
  local header='{"alg":"HS256","typ":"JWT"}'
  local now=$(date +%s)
  local exp=$((now + 3600))
  local payload="{\"sub\":\"$user_id\",\"role\":\"authenticated\",\"user_role\":\"$role\",\"iss\":\"supabase-demo\",\"iat\":$now,\"exp\":$exp}"

  local b64_header=$(printf '%s' "$header" | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  local b64_payload=$(printf '%s' "$payload" | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
  local signature=$(printf '%s.%s' "$b64_header" "$b64_payload" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')

  echo "${b64_header}.${b64_payload}.${signature}"
}

# ════════════════════════════════════════════════════════════════════════════════
# 1. DATABASE VERIFICATION
# ════════════════════════════════════════════════════════════════════════════════

section "Database: Migration verification"

# View is gone
VIEW_GONE=$($PSQL -c "SELECT count(*) FROM information_schema.views WHERE table_schema='public' AND table_name='user_profile_detail';")
check "user_profile_detail view is dropped" "$([ "$VIEW_GONE" = "0" ] && echo true || echo false)"

# home_* columns removed from profiles
HOME_COLS=$($PSQL -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name IN ('home_address','home_lat','home_lon');")
check "home_address/lat/lon removed from profiles" "$([ "$HOME_COLS" = "0" ] && echo true || echo false)"

section "Database: New tables exist"

for TBL in employee_pii labor_contracts integration_configs integration_messages; do
  EXISTS=$($PSQL -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='$TBL';")
  check "$TBL table exists" "$([ "$EXISTS" = "1" ] && echo true || echo false)"
done

section "Database: employee_pii has correct columns"

EXPECTED_COLS="national_id_encrypted date_of_birth_encrypted phone_encrypted home_address_encrypted home_lat_encrypted home_lon_encrypted salary_gross_encrypted country nationality_iso country_of_domicile_iso id_document_type salary_currency education_level source"
for COL in $EXPECTED_COLS; do
  HAS_COL=$($PSQL -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='employee_pii' AND column_name='$COL';")
  check "employee_pii.$COL exists" "$([ "$HAS_COL" = "1" ] && echo true || echo false)"
done

section "Database: RLS enabled on new tables"

for TBL in employee_pii labor_contracts integration_configs integration_messages; do
  RLS=$($PSQL -c "SELECT rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename='$TBL';")
  check "$TBL has RLS enabled" "$([ "$RLS" = "t" ] && echo true || echo false)"
done

section "Database: Constraints"

# Unique guarantee on employee_pii.user_id. After REGES bridge migration this is a
# partial unique INDEX (WHERE user_id IS NOT NULL), not a table constraint —
# allows staged rows with NULL user_id while still preventing duplicates per user.
UNIQUE_PII=$($PSQL -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='employee_pii' AND indexname='employee_pii_user_unique';")
check "employee_pii has UNIQUE index on user_id" "$([ "$UNIQUE_PII" -ge "1" ] && echo true || echo false)"

# Unique constraint on integration_configs (company_id, integration)
UNIQUE_IC=$($PSQL -c "SELECT count(*) FROM information_schema.table_constraints WHERE table_schema='public' AND table_name='integration_configs' AND constraint_type='UNIQUE';")
check "integration_configs has UNIQUE constraint" "$([ "$UNIQUE_IC" -ge "1" ] && echo true || echo false)"

# ════════════════════════════════════════════════════════════════════════════════
# 2. EDGE FUNCTION: get-employee-details
# ════════════════════════════════════════════════════════════════════════════════

section "Edge Function: get-employee-details"

# Check if functions are serving
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/functions/v1/get-employee-details" -H "Authorization: Bearer invalid" 2>/dev/null || echo "000")
if [ "$HEALTH" = "000" ]; then
  echo "  ⚠ Edge functions not running — skipping function tests"
  echo "  ⚠ Start with: supabase functions serve --env-file supabase/.env.local"
else
  # Generate JWTs
  EMP_JWT=$(make_jwt "$EMP_ID" "employee")
  HR_JWT=$(make_jwt "$HR_ID" "hr")

  # Seed via update-employee-pii so values are encrypted with the live key.
  # Direct SQL insert would store plaintext, which strict decrypt rejects.
  curl -s -X POST "$API_URL/functions/v1/update-employee-pii" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json" \
    -d '{"patch":{"home_address":"Str. Republicii Nr. 42, Cluj-Napoca","home_lat":46.770439,"home_lon":23.591423}}' > /dev/null
  $PSQL -c "UPDATE employee_pii SET source = 'test' WHERE user_id = '$EMP_ID';" > /dev/null

  # Test 1: Employee reads own details
  RESP=$(curl -s -X POST "$API_URL/functions/v1/get-employee-details" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json")

  HAS_EMAIL=$(echo "$RESP" | grep -c '"email"' || true)
  check "Employee can call get-employee-details" "$([ "$HAS_EMAIL" -ge "1" ] && echo true || echo false)"

  GOT_NAME=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('first_name',''))" 2>/dev/null || echo "")
  check "Response has first_name='Alice'" "$([ "$GOT_NAME" = "Alice" ] && echo true || echo false)"

  GOT_COMPANY=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('company_name',''))" 2>/dev/null || echo "")
  check "Response has company_name='8x8'" "$([ "$GOT_COMPANY" = "8x8" ] && echo true || echo false)"

  # Check PII block exists
  HAS_PII=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('pii') is not None else 'no')" 2>/dev/null || echo "no")
  check "Response has pii block" "$([ "$HAS_PII" = "yes" ] && echo true || echo false)"

  # Check PII home_address round-trips (encrypted on seed, decrypted on read)
  GOT_ADDR=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pii',{}).get('home_address',''))" 2>/dev/null || echo "")
  check "pii.home_address returned correctly" "$([ "$GOT_ADDR" = "Str. Republicii Nr. 42, Cluj-Napoca" ] && echo true || echo false)"

  # Check PII home_lat is numeric
  GOT_LAT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pii',{}).get('home_lat',0))" 2>/dev/null || echo "0")
  check "pii.home_lat is numeric (46.770439)" "$(python3 -c "print('true' if abs(float('$GOT_LAT') - 46.770439) < 0.001 else 'false')" 2>/dev/null || echo false)"

  # Check route fields present
  HAS_DAYS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'days_in_office' in d else 'no')" 2>/dev/null || echo "no")
  check "Response has days_in_office field" "$([ "$HAS_DAYS" = "yes" ] && echo true || echo false)"

  HAS_CO_LAT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'company_address_lat' in d else 'no')" 2>/dev/null || echo "no")
  check "Response has company_address_lat field" "$([ "$HAS_CO_LAT" = "yes" ] && echo true || echo false)"

  # Test 2: HR reads employee details
  HR_RESP=$(curl -s -X POST "$API_URL/functions/v1/get-employee-details" \
    -H "Authorization: Bearer $HR_JWT" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\": \"$EMP_ID\"}")

  HR_GOT_NAME=$(echo "$HR_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('first_name',''))" 2>/dev/null || echo "")
  check "HR can read employee details (got Alice)" "$([ "$HR_GOT_NAME" = "Alice" ] && echo true || echo false)"

  HR_GOT_PII=$(echo "$HR_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pii',{}).get('home_address',''))" 2>/dev/null || echo "")
  check "HR sees employee PII (home_address)" "$([ "$HR_GOT_PII" = "Str. Republicii Nr. 42, Cluj-Napoca" ] && echo true || echo false)"

  # Test 3: Employee cannot read HR details (employee role can't pass user_id)
  EMP_CROSS=$(curl -s -X POST "$API_URL/functions/v1/get-employee-details" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\": \"$HR_ID\"}")

  EMP_CROSS_ERR=$(echo "$EMP_CROSS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")
  check "Employee blocked from reading other user" "$([ "$EMP_CROSS_ERR" = "forbidden" ] && echo true || echo false)"

  # Test 4: No auth → 401
  NO_AUTH=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/functions/v1/get-employee-details" \
    -H "Content-Type: application/json" 2>/dev/null || echo "000")
  check "No JWT → 401" "$([ "$NO_AUTH" = "401" ] && echo true || echo false)"

  # Cleanup test PII data
  $PSQL -c "DELETE FROM employee_pii WHERE user_id = '$EMP_ID' AND source = 'test';" > /dev/null
fi

# ════════════════════════════════════════════════════════════════════════════════
# 3. EDGE FUNCTION: admin-encrypt-pii (backfill)
# ════════════════════════════════════════════════════════════════════════════════

section "Edge Function: admin-encrypt-pii"

BACKFILL_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/functions/v1/admin-encrypt-pii" -X POST -H "Authorization: Bearer invalid" 2>/dev/null || echo "000")
if [ "$BACKFILL_HEALTH" = "000" ]; then
  echo "  ⚠ Edge functions not running — skipping backfill tests"
else
  # Seed an admin user + row the backfill can convert.
  ADMIN_ID="cccccccc-cccc-cccc-cccc-cccccccccccc"
  $PSQL -c "
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
    VALUES ('$ADMIN_ID', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin-pii@test.local', '', now(), now(), '', '', '', '')
    ON CONFLICT (id) DO NOTHING;
    INSERT INTO profiles (user_id, email, company_id, status, first_name, last_name)
    VALUES ('$ADMIN_ID', 'admin-pii@test.local', '$COMPANY_ID', 'active', 'Admin', 'One')
    ON CONFLICT (user_id) DO NOTHING;
    INSERT INTO user_roles (user_id, role) VALUES ('$ADMIN_ID', 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
    -- employee_pii.user_id has a partial unique index (WHERE user_id IS NOT NULL).
    -- Use the index predicate so ON CONFLICT can target it.
    INSERT INTO employee_pii (user_id, company_id, phone_encrypted, home_address_encrypted, source)
    VALUES ('$EMP_ID', '$COMPANY_ID', '+40700000000', 'Str. Test 1', 'test-backfill')
    ON CONFLICT (user_id) WHERE user_id IS NOT NULL DO UPDATE SET
      phone_encrypted        = EXCLUDED.phone_encrypted,
      home_address_encrypted = EXCLUDED.home_address_encrypted,
      source                 = 'test-backfill';
  " > /dev/null

  ADMIN_JWT=$(make_jwt "$ADMIN_ID" "admin")

  # Non-admin JWT → 403
  EMP_JWT_FOR_BACKFILL=$(make_jwt "$EMP_ID" "employee")
  FORBIDDEN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/functions/v1/admin-encrypt-pii" \
    -H "Authorization: Bearer $EMP_JWT_FOR_BACKFILL" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
  check "backfill blocks non-admin (403)" "$([ "$FORBIDDEN_CODE" = "403" ] && echo true || echo false)"

  # Admin run encrypts
  RUN1=$(curl -s -X POST "$API_URL/functions/v1/admin-encrypt-pii" \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H "Content-Type: application/json" \
    -d '{}')
  RUN1_ENC=$(echo "$RUN1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('encrypted',0))" 2>/dev/null || echo 0)
  check "backfill encrypted at least 1 field" "$([ "$RUN1_ENC" -ge 1 ] && echo true || echo false)"

  # Verify DB row now has enc:v1: prefix
  PHONE_VAL=$($PSQL -c "SELECT phone_encrypted FROM employee_pii WHERE user_id = '$EMP_ID';")
  echo "$PHONE_VAL" | grep -q "^enc:v1:"
  check "phone_encrypted now has enc:v1: prefix" "$([ $? -eq 0 ] && echo true || echo false)"

  # Idempotent second run
  RUN2=$(curl -s -X POST "$API_URL/functions/v1/admin-encrypt-pii" \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H "Content-Type: application/json" \
    -d '{}')
  RUN2_ENC=$(echo "$RUN2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('encrypted',0))" 2>/dev/null || echo 0)
  check "backfill is idempotent (no re-encryption)" "$([ "$RUN2_ENC" = "0" ] && echo true || echo false)"

  # Cleanup the test PII row (admin user stays — harmless)
  $PSQL -c "DELETE FROM employee_pii WHERE user_id = '$EMP_ID' AND source = 'test-backfill';" > /dev/null
fi

# ════════════════════════════════════════════════════════════════════════════════
# 4. EDGE FUNCTION: update-employee-pii
# ════════════════════════════════════════════════════════════════════════════════

section "Edge Function: update-employee-pii"

UPDATE_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/functions/v1/update-employee-pii" -X POST -H "Authorization: Bearer invalid" 2>/dev/null || echo "000")
if [ "$UPDATE_HEALTH" = "000" ]; then
  echo "  ⚠ Edge functions not running — skipping update tests"
else
  EMP_JWT=$(make_jwt "$EMP_ID" "employee")
  HR_JWT=$(make_jwt "$HR_ID" "hr")

  # Self-update encrypts and UPSERTs
  SELF_RESP=$(curl -s -X POST "$API_URL/functions/v1/update-employee-pii" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json" \
    -d '{"patch":{"phone":"+40711223344","home_address":"Str. Test Self 1","home_lat":45.75,"home_lon":21.22}}')
  SELF_OK=$(echo "$SELF_RESP" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('ok') else 'no')" 2>/dev/null || echo no)
  check "self-update succeeded (ok:true)" "$([ "$SELF_OK" = "yes" ] && echo true || echo false)"

  # Verify DB holds enc:v1: prefix
  PHONE_DB=$($PSQL -c "SELECT phone_encrypted FROM employee_pii WHERE user_id = '$EMP_ID';")
  echo "$PHONE_DB" | grep -q "^enc:v1:"
  check "stored phone is enc:v1: ciphertext" "$([ $? -eq 0 ] && echo true || echo false)"

  # Round-trip via get-employee-details
  GED=$(curl -s -X POST "$API_URL/functions/v1/get-employee-details" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json")
  PHONE_BACK=$(echo "$GED" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pii',{}).get('phone',''))" 2>/dev/null || echo "")
  check "get-employee-details decrypts phone round-trip" "$([ "$PHONE_BACK" = "+40711223344" ] && echo true || echo false)"

  # Null clears
  curl -s -X POST "$API_URL/functions/v1/update-employee-pii" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json" \
    -d '{"patch":{"phone":null}}' > /dev/null
  PHONE_CLEARED=$($PSQL -c "SELECT COALESCE(phone_encrypted, 'NULL') FROM employee_pii WHERE user_id = '$EMP_ID';")
  check "null patch clears phone_encrypted" "$([ "$PHONE_CLEARED" = "NULL" ] && echo true || echo false)"

  # Validation: lat out of range → 400
  BAD_LAT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/functions/v1/update-employee-pii" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json" \
    -d '{"patch":{"home_lat":100}}' 2>/dev/null || echo "000")
  check "bad home_lat rejected (400)" "$([ "$BAD_LAT" = "400" ] && echo true || echo false)"

  # Unknown field rejected
  BAD_KEY=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/functions/v1/update-employee-pii" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json" \
    -d '{"patch":{"first_name":"X"}}' 2>/dev/null || echo "000")
  check "unknown field rejected (400)" "$([ "$BAD_KEY" = "400" ] && echo true || echo false)"

  # Employee cannot patch another user
  EMP_CROSS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/functions/v1/update-employee-pii" \
    -H "Authorization: Bearer $EMP_JWT" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$HR_ID\",\"patch\":{\"phone\":\"+40700000000\"}}" 2>/dev/null || echo "000")
  check "employee blocked from updating another user (403)" "$([ "$EMP_CROSS" = "403" ] && echo true || echo false)"

  # HR can patch employee in same company
  HR_PATCH=$(curl -s -X POST "$API_URL/functions/v1/update-employee-pii" \
    -H "Authorization: Bearer $HR_JWT" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$EMP_ID\",\"patch\":{\"national_id\":\"1234567890123\"}}")
  HR_OK=$(echo "$HR_PATCH" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('ok') else 'no')" 2>/dev/null || echo no)
  check "HR patch same-company employee succeeded" "$([ "$HR_OK" = "yes" ] && echo true || echo false)"

  # Cleanup
  $PSQL -c "UPDATE employee_pii SET phone_encrypted = NULL, home_address_encrypted = NULL, home_lat_encrypted = NULL, home_lon_encrypted = NULL, national_id_encrypted = NULL WHERE user_id = '$EMP_ID';" > /dev/null
fi

# ════════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed (of $TOTAL)"
echo "═══════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
