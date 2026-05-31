#!/bin/bash
# ============================================================
# MobiPass Local Test Script — PII + TBI Loan Flows
# ============================================================
#
# Prerequisites:
#   supabase start
#   supabase functions serve
#   bash scripts/setup-tbi-vault.sh   (Vault RSA keys)
#   supabase secrets set ...           (env var secrets)
#
# Usage:
#   bash scripts/test-flows.sh [test_name]
#
# Examples:
#   bash scripts/test-flows.sh          # run all tests
#   bash scripts/test-flows.sh seed     # seed only
#   bash scripts/test-flows.sh pii      # PII tests only
#   bash scripts/test-flows.sh tbi      # TBI loan tests only
# ============================================================

set -euo pipefail

BASE_URL="http://127.0.0.1:54321"
FUNCTIONS_URL="${BASE_URL}/functions/v1"
DB_CONTAINER="supabase_db_mobi-pass-be"
JWT_SECRET="super-secret-jwt-token-with-at-least-32-characters-long"

# ── Fixed test IDs ──────────────────────────────────────────────────────────
EMPLOYEE_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
HR_ID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
COMPANY_ID="11111111-1111-1111-1111-111111111111"

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()  { echo -e "${CYAN}[TEST]${NC} $1"; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
sep()  { echo "────────────────────────────────────────────────────────────"; }

# ── JWT generation ──────────────────────────────────────────────────────────
# Generates a signed HS256 JWT matching Supabase Auth format.
generate_jwt() {
  local user_id="$1"
  local role="$2"       # employee | hr | admin
  local exp=$(( $(date +%s) + 3600 ))

  local header='{"alg":"HS256","typ":"JWT"}'
  local payload="{\"sub\":\"${user_id}\",\"role\":\"authenticated\",\"user_role\":\"${role}\",\"aud\":\"authenticated\",\"exp\":${exp},\"iat\":$(date +%s)}"

  local b64_header=$(echo -n "$header" | base64 | tr '+/' '-_' | tr -d '=')
  local b64_payload=$(echo -n "$payload" | base64 | tr '+/' '-_' | tr -d '=')

  local signature=$(echo -n "${b64_header}.${b64_payload}" \
    | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary \
    | base64 | tr '+/' '-_' | tr -d '=')

  echo "${b64_header}.${b64_payload}.${signature}"
}

# ── DB helper ───────────────────────────────────────────────────────────────
db() {
  docker exec "$DB_CONTAINER" psql -U postgres -tAc "$1"
}

# ============================================================
# SEED — ensure test data exists
# ============================================================
seed_test_data() {
  sep
  log "Seeding test data..."

  # Ensure a bike exists
  local bike_id
  bike_id=$(db "SELECT id FROM bikes LIMIT 1;")
  if [ -z "$bike_id" ]; then
    log "Creating test dealer + bike..."
    local dealer_id
    dealer_id=$(db "INSERT INTO dealers (name, address, lat, lon, phone)
      VALUES ('Test Dealer', 'Str. Bicicletelor 1, Bucuresti', 44.4268, 26.1025, '+40700000001')
      RETURNING id;")
    bike_id=$(db "INSERT INTO bikes (name, brand, type, full_price, dealer_id)
      VALUES ('Cube Reaction Hybrid', 'Cube', 'e_mtb_hardtail_29', 4500.00, '${dealer_id}')
      RETURNING id;")
    pass "Created bike: $bike_id"
  else
    pass "Bike exists: $bike_id"
  fi

  # Assign bike to employee's bike_benefit
  local bb_id
  bb_id=$(db "SELECT id FROM bike_benefits WHERE user_id = '${EMPLOYEE_ID}';")
  if [ -n "$bb_id" ]; then
    db "UPDATE bike_benefits SET bike_id = '${bike_id}', benefit_status = 'active',
        employee_full_price = 3200.00, employee_contract_months = 36,
        employee_monthly_price = 88.89, employee_currency = 'RON'
      WHERE id = '${bb_id}';" > /dev/null
    pass "Updated bike_benefit: $bb_id (bike=$bike_id, price=3200 RON)"
  else
    bb_id=$(db "INSERT INTO bike_benefits (user_id, bike_id, benefit_status,
        employee_full_price, employee_contract_months, employee_monthly_price, employee_currency)
      VALUES ('${EMPLOYEE_ID}', '${bike_id}', 'active', 3200.00, 36, 88.89, 'RON')
      RETURNING id;")
    pass "Created bike_benefit: $bb_id"
  fi

  # Ensure employee_pii record exists with CNP + phone (required for TBI)
  local pii_exists
  pii_exists=$(db "SELECT count(*) FROM employee_pii WHERE user_id = '${EMPLOYEE_ID}';")
  if [ "$pii_exists" = "0" ]; then
    db "INSERT INTO employee_pii (user_id, company_id, phone_encrypted, national_id_encrypted,
        home_address_encrypted, home_lat_encrypted, home_lon_encrypted, source)
      VALUES ('${EMPLOYEE_ID}', '${COMPANY_ID}',
        '+40722123456', '1900101123456',
        'Str. Exemplu Nr. 42, Bucuresti', '44.4500', '26.0800',
        'manual');" > /dev/null
    pass "Created employee_pii (plaintext — encrypted below)"
  else
    # Make sure CNP + phone are populated
    db "UPDATE employee_pii SET
        phone_encrypted = COALESCE(NULLIF(phone_encrypted, ''), '+40722123456'),
        national_id_encrypted = COALESCE(NULLIF(national_id_encrypted, ''), '1900101123456'),
        home_address_encrypted = COALESCE(NULLIF(home_address_encrypted, ''), 'Str. Exemplu Nr. 42, Bucuresti'),
        home_lat_encrypted = COALESCE(NULLIF(home_lat_encrypted, ''), '44.4500'),
        home_lon_encrypted = COALESCE(NULLIF(home_lon_encrypted, ''), '26.0800')
      WHERE user_id = '${EMPLOYEE_ID}';" > /dev/null
    pass "employee_pii exists, ensured CNP + phone populated"
  fi

  # Ensure profile_invite exists for the employee (get-employee-details joins on it)
  local invite_exists
  invite_exists=$(db "SELECT count(*) FROM profile_invites WHERE email = 'employee@example.com';")
  if [ "$invite_exists" = "0" ]; then
    db "INSERT INTO profile_invites (email, company_id, first_name, last_name, status)
      VALUES ('employee@example.com', '${COMPANY_ID}', 'Alice', 'Employee', 'active');" > /dev/null
    pass "Created profile_invite for employee"
  else
    pass "profile_invite exists for employee"
  fi

  encrypt_seeded_pii

  sep
  log "Seed complete."
  echo ""
}

# ── Encrypt seeded PII via admin-encrypt-pii ────────────────────────────────
# tbi-loan-request and other consumers use strict decrypt() which requires the
# enc:v1: marker. Without this step they 500 with "Value is not encrypted".
# Idempotent: skipped on rows already encrypted. Temporarily promotes the
# employee to admin to call the gated endpoint, then reverts.
encrypt_seeded_pii() {
  log "Encrypting seeded PII (admin-encrypt-pii)..."

  # Skip if already encrypted (no work to do).
  local enc_count
  enc_count=$(db "SELECT count(*) FROM employee_pii
                  WHERE user_id = '${EMPLOYEE_ID}'
                    AND phone_encrypted LIKE 'enc:v1:%'
                    AND national_id_encrypted LIKE 'enc:v1:%';")
  if [ "$enc_count" = "1" ]; then
    pass "PII already encrypted — skipping"
    return
  fi

  db "UPDATE user_roles SET role='admin' WHERE user_id='${EMPLOYEE_ID}';" > /dev/null
  local admin_jwt
  admin_jwt=$(generate_jwt "$EMPLOYEE_ID" "admin")

  local resp
  resp=$(curl -sS -X POST "${FUNCTIONS_URL}/admin-encrypt-pii" \
    -H "Authorization: Bearer ${admin_jwt}" \
    -H "Content-Type: application/json" \
    -d '{}')

  db "UPDATE user_roles SET role='employee' WHERE user_id='${EMPLOYEE_ID}';" > /dev/null

  if echo "$resp" | grep -q '"updated_rows"'; then
    pass "PII encrypted: $resp"
  else
    fail "admin-encrypt-pii failed: $resp"
    return 1
  fi
}

# ============================================================
# PII TESTS — get-employee-details
# ============================================================
test_pii() {
  sep
  log "PII Flow Tests"
  sep

  local emp_jwt
  emp_jwt=$(generate_jwt "$EMPLOYEE_ID" "employee")
  local hr_jwt
  hr_jwt=$(generate_jwt "$HR_ID" "hr")

  # ── 1. Employee reads own details ─────────────────────────────────────────
  log "1. GET employee details (own profile)..."
  local resp
  resp=$(curl -s -w "\n%{http_code}" -X POST "${FUNCTIONS_URL}/get-employee-details" \
    -H "Authorization: Bearer ${emp_jwt}" \
    -H "Content-Type: application/json" \
    -d '{}')
  local status=$(echo "$resp" | tail -1)
  local body=$(echo "$resp" | sed '$d')

  if [ "$status" = "200" ]; then
    pass "Employee details returned (HTTP $status)"
    echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
  else
    fail "HTTP $status"
    echo "$body"
  fi
  echo ""

  # ── 2. Verify PII block is present ───────────────────────────────────────
  log "2. Checking PII block in response..."
  local has_pii
  has_pii=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('pii') else 'no')" 2>/dev/null || echo "parse_error")
  if [ "$has_pii" = "yes" ]; then
    pass "PII block present in response"
    echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d['pii'], indent=2))" 2>/dev/null
  else
    fail "PII block missing (has_pii=$has_pii)"
  fi
  echo ""

  # ── 3. HR reads employee details (cross-read, same company) ──────────────
  log "3. HR reads employee details (same company)..."
  resp=$(curl -s -w "\n%{http_code}" -X POST "${FUNCTIONS_URL}/get-employee-details" \
    -H "Authorization: Bearer ${hr_jwt}" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\": \"${EMPLOYEE_ID}\"}")
  status=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')

  if [ "$status" = "200" ]; then
    pass "HR cross-read succeeded (HTTP $status)"
  else
    fail "HTTP $status"
    echo "$body"
  fi
  echo ""

  # ── 4. No JWT → 401 ──────────────────────────────────────────────────────
  log "4. No JWT → expect 401..."
  status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${FUNCTIONS_URL}/get-employee-details" \
    -H "Content-Type: application/json")

  if [ "$status" = "401" ]; then
    pass "Unauthenticated request rejected (HTTP $status)"
  else
    fail "Expected 401, got $status"
  fi
  echo ""

  # ── 5. Verify DB has plaintext (not yet encrypted by edge func) ──────────
  log "5. Checking DB values (should be plaintext from seed)..."
  local db_cnp
  db_cnp=$(db "SELECT national_id_encrypted FROM employee_pii WHERE user_id = '${EMPLOYEE_ID}';")
  if echo "$db_cnp" | grep -qE '^[0-9]+$'; then
    pass "DB has plaintext CNP: $db_cnp (safeDecrypt handles this)"
  else
    warn "DB value: $db_cnp (may be encrypted or empty)"
  fi
  echo ""
}

# ============================================================
# TBI LOAN TESTS — loan-request, cancel, webhook
# ============================================================
test_tbi() {
  sep
  log "TBI Loan Flow Tests"
  sep

  local emp_jwt
  emp_jwt=$(generate_jwt "$EMPLOYEE_ID" "employee")

  # ── 1. Submit loan application ────────────────────────────────────────────
  log "1. Submit TBI loan application..."
  local resp
  resp=$(curl -s -w "\n%{http_code}" -X POST "${FUNCTIONS_URL}/tbi-loan-request" \
    -H "Authorization: Bearer ${emp_jwt}" \
    -H "Content-Type: application/json" \
    -d '{}')
  local status=$(echo "$resp" | tail -1)
  local body=$(echo "$resp" | sed '$d')

  if [ "$status" = "200" ]; then
    pass "Loan application submitted (HTTP $status)"
    echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
  else
    fail "HTTP $status"
    echo "$body"
    if [ "$status" = "500" ]; then
      warn "If TBI staging is unreachable, this is expected. Check the error above."
    fi
  fi
  echo ""

  # Extract order_id for subsequent tests
  local order_id
  order_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('order_id',''))" 2>/dev/null || echo "")

  # ── 2. Verify loan saved in DB ───────────────────────────────────────────
  log "2. Checking tbi_loan_applications table..."
  if [ -n "$order_id" ]; then
    local db_status
    db_status=$(db "SELECT status FROM tbi_loan_applications WHERE order_id = '${order_id}';")
    if [ "$db_status" = "pending" ]; then
      pass "Loan record found: order_id=$order_id, status=$db_status"
    else
      warn "Loan status: '$db_status' (expected 'pending')"
    fi
  else
    warn "No order_id from step 1, skipping DB check"
  fi
  echo ""

  # ── 3. Cancel loan ───────────────────────────────────────────────────────
  if [ -n "$order_id" ]; then
    log "3. Cancel loan application (order_id=$order_id)..."
    resp=$(curl -s -w "\n%{http_code}" -X POST "${FUNCTIONS_URL}/tbi-cancel" \
      -H "Authorization: Bearer ${emp_jwt}" \
      -H "Content-Type: application/json" \
      -d "{\"order_id\": \"${order_id}\"}")
    body=$(echo "$resp" | head -n -1)
    status=$(echo "$resp" | tail -n 1)

    if [ "$status" = "200" ]; then
      pass "Loan canceled (HTTP $status)"
      echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
    else
      fail "HTTP $status"
      echo "$body"
      if echo "$body" | grep -q "tbi_api_failed"; then
        warn "TBI cancel API failed — staging may reject cancels for test orders"
      fi
    fi
  else
    warn "3. Skipping cancel — no order_id from step 1"
  fi
  echo ""

  # ── 4. Simulate TBI webhook callback ─────────────────────────────────────
  log "4. Simulate TBI webhook (approved callback)..."
  warn "Webhook expects RSA-encrypted form data from TBI."
  warn "To test locally, use the DB directly:"
  echo ""
  echo "  # Simulate approved callback by updating DB directly:"
  echo "  docker exec $DB_CONTAINER psql -U postgres -c \\"
  echo "    \"UPDATE tbi_loan_applications SET status = 'approved' WHERE order_id = '<order_id>';\""
  echo ""

  # ── 5. No JWT on loan-request → 401 ─────────────────────────────────────
  log "5. No JWT on tbi-loan-request → expect 401..."
  status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${FUNCTIONS_URL}/tbi-loan-request" \
    -H "Content-Type: application/json")

  if [ "$status" = "401" ]; then
    pass "Unauthenticated loan request rejected (HTTP $status)"
  else
    fail "Expected 401, got $status"
  fi
  echo ""

  # ── 6. Cancel non-existent order → 400 ───────────────────────────────────
  log "6. Cancel non-existent order → expect 400..."
  resp=$(curl -s -w "\n%{http_code}" -X POST "${FUNCTIONS_URL}/tbi-cancel" \
    -H "Authorization: Bearer ${emp_jwt}" \
    -H "Content-Type: application/json" \
    -d '{"order_id": "mbp_fake_999"}')
  status=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')

  if [ "$status" = "400" ]; then
    pass "Non-existent order rejected (HTTP $status)"
  else
    fail "Expected 400, got $status"
    echo "$body"
  fi
  echo ""
}

# ============================================================
# MAIN
# ============================================================
echo ""
echo "============================================================"
echo "  MobiPass Local Test — PII + TBI Loan Flows"
echo "============================================================"
echo ""

case "${1:-all}" in
  seed) seed_test_data ;;
  pii)  seed_test_data; test_pii ;;
  tbi)  seed_test_data; test_tbi ;;
  all)  seed_test_data; test_pii; test_tbi ;;
  *)    echo "Usage: $0 [seed|pii|tbi|all]"; exit 1 ;;
esac

sep
log "Done."
