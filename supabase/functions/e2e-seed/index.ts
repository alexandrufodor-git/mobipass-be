// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { encrypt } from "../_shared/piiCrypto.ts"
import { birthDateHash } from "../_shared/piiLookup.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"

/**
 * e2e-seed — Test account bootstrap & reset for Maestro flows.
 *
 * Request: POST with X-E2E-Secret header.
 *   Body: { command: "bootstrap" }
 *         { command: "reset", flow: "<flow-name>" }
 *
 * Vault secrets (set via scripts/setup-e2e-vault.sh for local, or SQL on prod):
 *   e2e_secret            — required shared secret (matches X-E2E-Secret header)
 *   e2e_default_password  — password set on bootstrapped accounts
 *   e2e_bike_id           — bike UUID used for post-choose_bike target states
 *
 * Managed accounts (all @mobipass.test, auto-provisioned in the dedicated
 * E2E Test Co company):
 *   e2e-fresh    — step = choose_bike                                       (flow 1)
 *   e2e-signed   — contract fully signed, step = pickup_delivery, HR signed  (flow 2)
 *   e2e-main     — onboarding_status = true, step = pickup_delivery         (flows 3-6)
 *   e2e-register — invite only, no auth user                                (flow 0)
 */

const TEST_DOMAIN           = "mobipass.test"
const E2E_COMPANY_NAME      = "E2E Test Co"
const E2E_ESIG_TEMPLATE_ID  = "6c9db750-f9f9-4f63-8a98-ada842cbc5bd"

// Fake HR-set office address used by AddressSetup's Work row and by any
// dashboard route estimation that reads Company.address. Real-looking
// Cluj coordinates so downstream Mapbox/route calls behave realistically.
const E2E_COMPANY_ADDRESS   = "Strada Avram Iancu 22, Cluj-Napoca 400117"
const E2E_COMPANY_LAT       = 46.7693
const E2E_COMPANY_LON       = 23.5893

// Fake employee home address (also Cluj) used to seed encrypted PII for the
// dashboard-main / ebike-catalog / profile flows. ~2 km from the office so
// distance/route widgets render meaningful values.
const E2E_HOME_ADDRESS      = "Strada Memorandumului 28, Cluj-Napoca 400114"
const E2E_HOME_LAT          = 46.7711
const E2E_HOME_LON          = 23.5712

// Stable PII fixture for `completed_with_address` — populated so
// get-employee-details returns a fully-formed `pii` block.
const E2E_PII_NATIONAL_ID   = "1900101123456"
const E2E_PII_DATE_OF_BIRTH = "1990-01-01"
const REGES_GMAIL_COMPANY_ID = "44444444-4444-4444-4444-444444444444"
const REGES_GMAIL_DOMAIN     = "gmail.com"
// Named pattern from public.email_pattern_kind. Resolves to "{last}?{.{middle}}.{first}".
// HR notation: {last}.{middle?}.{first}@domain — middle + its leading dot are optional.
const REGES_EMAIL_PATTERN    = "last_middle_first"
const E2E_REGES_SOURCE_REF   = "reges-fodor-e2e"
const E2E_REGES_DOB          = "1990-03-15"
const E2E_REGES_DERIVED_EMAIL = "fodor.horatiu.alexandru@gmail.com"
const E2E_REGES_CNP          = "1900315120017"
const E2E_PII_PHONE         = "+40712345678"
const E2E_PII_SALARY_GROSS  = 6000

type AccountKey = "fresh" | "signed" | "main" | "register" | "reges"

const ACCOUNTS: Record<AccountKey, { email: string; firstName: string; lastName: string }> = {
  fresh:    { email: `e2e-fresh@${TEST_DOMAIN}`,    firstName: "E2E", lastName: "Fresh" },
  signed:   { email: `e2e-signed@${TEST_DOMAIN}`,   firstName: "E2E", lastName: "Signed" },
  main:     { email: `e2e-main@${TEST_DOMAIN}`,     firstName: "E2E", lastName: "Main" },
  register: { email: `e2e-register@${TEST_DOMAIN}`, firstName: "E2E", lastName: "Register" },
  reges:    { email: "fodor.horatiu.alexandru@gmail.com", firstName: "Alexandru", lastName: "Fodor" },
}

type FlowTarget =
  | "pre_register"
  | "register"
  | "fresh"
  | "pickup_ready_no_address"
  | "completed_no_address"
  | "completed_with_address"

const FLOWS: Record<string, { accounts: AccountKey[]; target: FlowTarget }> = {
  "registration":                    { accounts: ["register"], target: "pre_register" },
  "reges-claim-register":            { accounts: ["reges"],    target: "register" },
  "onboarding-1-to-4":               { accounts: ["fresh"],    target: "fresh" },
  "onboarding-step-5":               { accounts: ["signed"],   target: "pickup_ready_no_address" },
  "onboarding-step-5-to-dashboard":  { accounts: ["signed"],   target: "pickup_ready_no_address" },
  "address-to-dashboard":            { accounts: ["main"],     target: "completed_no_address" },
  "dashboard-main":                  { accounts: ["main"],     target: "completed_with_address" },
  "ebike-catalog":                   { accounts: ["main"],     target: "completed_with_address" },
  "profile":                         { accounts: ["main"],     target: "completed_with_address" },
}

// ─── Server-side env & Vault ────────────────────────────────────────────────

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

const baseHeaders = {
  Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  apikey:        SERVICE_ROLE_KEY,
  "Content-Type": "application/json",
}

async function getVaultSecret(name: string): Promise<string | null> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_vault_secret`, {
    method: "POST",
    headers: baseHeaders,
    body: JSON.stringify({ secret_name: name }),
  })
  if (!res.ok) return null
  const value = await res.json() as string | null
  return value
}

// Loaded at request time (not top-level) so unit/test envs don't crash on missing Vault.
let E2E_SECRET       = ""
let DEFAULT_PASSWORD = ""
let BIKE_ID          = ""

async function loadSecrets(): Promise<void> {
  E2E_SECRET       = (await getVaultSecret("e2e_secret")) ?? ""
  DEFAULT_PASSWORD = (await getVaultSecret("e2e_default_password")) ?? ""
  BIKE_ID          = (await getVaultSecret("e2e_bike_id")) ?? ""
}

// ─── HTTP helpers ────────────────────────────────────────────────────────────

async function rest(method: string, path: string, body?: unknown, prefer?: string): Promise<Response> {
  const headers: Record<string, string> = { ...baseHeaders }
  if (prefer) headers.Prefer = prefer
  const res = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  // 404/406 are acceptable only on GETs (no-row). Any write error must surface.
  const softOk = method === "GET" && (res.status === 404 || res.status === 406)
  if (!res.ok && !softOk) {
    const txt = await res.text()
    throw new Error(`${method} ${path} → ${res.status}: ${txt}`)
  }
  return res
}

async function getOne<T>(table: string, filter: string, select = "*"): Promise<T | null> {
  const res = await rest("GET", `/rest/v1/${table}?${filter}&select=${select}&limit=1`)
  const rows = await res.json() as T[]
  return rows[0] ?? null
}

async function del(table: string, filter: string): Promise<void> {
  await rest("DELETE", `/rest/v1/${table}?${filter}`, undefined, "return=minimal")
}

async function patch(table: string, filter: string, row: Record<string, unknown>): Promise<void> {
  await rest("PATCH", `/rest/v1/${table}?${filter}`, row, "return=minimal")
}

async function upsertInvite(email: string, companyId: string, firstName: string, lastName: string): Promise<void> {
  // Can't use PostgREST's on_conflict=email — the unique constraint was
  // replaced with a partial unique index on lower(email) (REGES bridge
  // migration) so emails can be NULL. PostgREST's on_conflict only targets
  // real unique constraints, not partial indexes. Lookup-then-write instead.
  const row = { email, company_id: companyId, first_name: firstName, last_name: lastName, status: "active" }
  const existing = await rest("GET",
    `/rest/v1/profile_invites?email=eq.${encodeURIComponent(email)}&select=id`)
  const rows = await existing.json() as { id: string }[]
  if (rows.length > 0) {
    await patch("profile_invites", `id=eq.${rows[0].id}`, row)
  } else {
    await rest("POST", `/rest/v1/profile_invites`, row, "return=minimal")
  }
}

// ─── Auth admin helpers ──────────────────────────────────────────────────────

type AuthUser = { id: string; email: string }

async function getAuthUserByEmail(email: string): Promise<AuthUser | null> {
  // GoTrue admin list endpoint does NOT support server-side email filtering —
  // paginate and match client-side. Safe for E2E usage (test accounts only).
  const target = email.toLowerCase()
  const per = 1000
  for (let page = 1; page <= 100; page++) {
    const res = await rest("GET", `/auth/v1/admin/users?page=${page}&per_page=${per}`)
    const json = await res.json() as { users?: Array<{ id: string; email?: string | null }> }
    const users = json.users ?? []
    const found = users.find((u) => (u.email ?? "").toLowerCase() === target)
    if (found) return { id: found.id, email: found.email ?? email }
    if (users.length < per) return null
  }
  return null
}

async function createAuthUser(email: string, password: string): Promise<AuthUser> {
  // Two-phase to mirror real OTP → CompleteRegister flow, so the
  // handle_user_registration trigger's on_auth_user_updated branch fires
  // (which creates profile + user_roles + bike_benefit).
  //
  // Phase 1: create confirmed user without password.
  const createRes = await rest("POST", `/auth/v1/admin/users`, {
    email, email_confirm: true,
  })
  const user = await createRes.json() as AuthUser
  if (!user?.id) throw new Error(`admin/users POST returned no id: ${JSON.stringify(user)}`)

  // Phase 2: set password via admin PUT — triggers UPDATE on auth.users.
  await rest("PUT", `/auth/v1/admin/users/${user.id}`, { password })
  return user
}

async function deleteAuthUser(userId: string): Promise<void> {
  await rest("DELETE", `/auth/v1/admin/users/${userId}`)
}

// ─── Company & account setup ────────────────────────────────────────────────

async function ensureCompany(): Promise<string> {
  const existing = await getOne<{
    id: string
    esignatures_template_id: string | null
    address: string | null
    address_lat: number | null
    address_lon: number | null
  }>(
    "companies",
    `name=eq.${encodeURIComponent(E2E_COMPANY_NAME)}`,
    "id,esignatures_template_id,address,address_lat,address_lon",
  )
  if (existing) {
    // Backfill any fields missing on rows created before they were added here.
    const backfill: Record<string, unknown> = {}
    if (existing.esignatures_template_id !== E2E_ESIG_TEMPLATE_ID) {
      backfill.esignatures_template_id = E2E_ESIG_TEMPLATE_ID
    }
    if (existing.address !== E2E_COMPANY_ADDRESS) backfill.address     = E2E_COMPANY_ADDRESS
    if (existing.address_lat !== E2E_COMPANY_LAT) backfill.address_lat = E2E_COMPANY_LAT
    if (existing.address_lon !== E2E_COMPANY_LON) backfill.address_lon = E2E_COMPANY_LON
    if (Object.keys(backfill).length > 0) {
      await patch("companies", `id=eq.${existing.id}`, backfill)
    }
    console.log(`[e2e-seed] using existing company id=${existing.id}`)
    return existing.id
  }

  const res = await rest("POST", `/rest/v1/companies`, {
    name: E2E_COMPANY_NAME,
    description: "Dedicated company for Maestro E2E flows — do not attach real users.",
    monthly_benefit_subsidy: 72.00,
    contract_months: 36,
    currency: "RON",
    days_in_office: 5,
    esignatures_template_id: E2E_ESIG_TEMPLATE_ID,
    address:     E2E_COMPANY_ADDRESS,
    address_lat: E2E_COMPANY_LAT,
    address_lon: E2E_COMPANY_LON,
  }, "return=representation")
  const rows = await res.json() as { id: string }[]
  if (!rows[0]?.id) throw new Error(`companies insert returned no row: ${JSON.stringify(rows)}`)
  console.log(`[e2e-seed] created company id=${rows[0].id}`)
  return rows[0].id
}

async function ensureAccount(acct: AccountKey, companyId: string): Promise<string> {
  const { email, firstName, lastName } = ACCOUNTS[acct]
  await upsertInvite(email, companyId, firstName, lastName)

  let user = await getAuthUserByEmail(email)
  if (user) {
    console.log(`[e2e-seed] reused auth user ${email} id=${user.id}`)
  } else {
    if (!DEFAULT_PASSWORD) throw new Error("e2e_default_password Vault secret not set")
    user = await createAuthUser(email, DEFAULT_PASSWORD)
    if (!user?.id) throw new Error(`createAuthUser returned no id for ${email}`)
    console.log(`[e2e-seed] created auth user ${email} id=${user.id}`)
    // handle_user_registration trigger fires here — creates profile, user_roles, bike_benefit.
  }
  return user.id
}

async function deleteAccountIfExists(acct: AccountKey): Promise<void> {
  const { email } = ACCOUNTS[acct]
  const user = await getAuthUserByEmail(email)
  if (!user) return
  await del("contracts",     `user_id=eq.${user.id}`)
  await del("bike_orders",   `user_id=eq.${user.id}`)
  await del("bike_benefits", `user_id=eq.${user.id}`)
  await del("employee_pii",  `user_id=eq.${user.id}`)
  await del("user_roles",    `user_id=eq.${user.id}`)
  await del("profiles",      `user_id=eq.${user.id}`)
  await patch("profile_invites", `email=eq.${encodeURIComponent(email)}`, { user_id: null })
  await deleteAuthUser(user.id)
}

// ─── Target state appliers ──────────────────────────────────────────────────

async function ensureRegesGmailCompany(): Promise<string> {
  const existing = await getOne<{ id: string }>(
    "companies",
    `id=eq.${REGES_GMAIL_COMPANY_ID}`,
    "id",
  )
  if (existing?.id) {
    await patch("companies", `id=eq.${existing.id}`, {
      email_domain:  REGES_GMAIL_DOMAIN,
      email_pattern: REGES_EMAIL_PATTERN,
    })
    return existing.id
  }
  throw new Error(
    `RegesGmail company ${REGES_GMAIL_COMPANY_ID} not found — run supabase db reset`,
  )
}

/** Pending REGES invite + PII for Maestro reges-claim-register (no auth user). */
async function resetToRegesPending(companyId: string): Promise<void> {
  const db = makeRestClient(SUPABASE_URL, SERVICE_ROLE_KEY)

  await patch("companies", `id=eq.${companyId}`, {
    email_domain:  REGES_GMAIL_DOMAIN,
    email_pattern: REGES_EMAIL_PATTERN,
  })

  await del("employee_pii",
    `company_id=eq.${companyId}&source=eq.reges&source_ref_id=eq.${E2E_REGES_SOURCE_REF}`)
  await del("profile_invites",
    `company_id=eq.${companyId}&source=eq.reges&source_ref_id=eq.${E2E_REGES_SOURCE_REF}`)

  const dobHash = await birthDateHash(db, E2E_REGES_DOB)
  const [nationalIdEnc, dobEnc] = await Promise.all([
    encrypt(db, E2E_REGES_CNP),
    encrypt(db, E2E_REGES_DOB),
  ])

  const inviteRes = await rest("POST", `/rest/v1/profile_invites`, {
    company_id:      companyId,
    email:           null,
    source:          "reges",
    source_ref_id:   E2E_REGES_SOURCE_REF,
    first_name:      "ALEXANDRU-HORATIU",
    last_name:       "FODOR",
    birth_date_hash: dobHash,
    derived_email:   E2E_REGES_DERIVED_EMAIL,
    radiat:          false,
    status:          "active",
  }, "return=representation")
  const invite = (await inviteRes.json() as { id: string }[])[0]
  if (!invite?.id) throw new Error("profile_invites insert returned no row")

  await rest("POST", `/rest/v1/employee_pii`, {
    company_id:              companyId,
    profile_invite_id:       invite.id,
    source:                  "reges",
    source_ref_id:           E2E_REGES_SOURCE_REF,
    user_id:                 null,
    national_id_encrypted:   nationalIdEnc,
    date_of_birth_encrypted: dobEnc,
    country:                 "RO",
    nationality_iso:         "RO",
    country_of_domicile_iso: "RO",
    id_document_type:        "national_id",
  }, "return=minimal")
}

async function resetToFresh(userId: string): Promise<void> {
  await del("contracts",     `user_id=eq.${userId}`)
  await del("bike_orders",   `user_id=eq.${userId}`)
  await del("bike_benefits", `user_id=eq.${userId}`)
  await del("employee_pii",  `user_id=eq.${userId}`)
  await rest("POST", `/rest/v1/bike_benefits`,
    { user_id: userId, step: "choose_bike" }, "return=minimal")
  await patch("profiles", `user_id=eq.${userId}`, { onboarding_status: false })
}

/**
 * Step 5 (pickup_delivery) ready to confirm — both parties have signed,
 * contract is approved, but delivered_at is NULL and employee_pii is missing.
 *
 * UI expectations:
 *   - contract_employer_signed_at non-null → PickupDeliveryCard's
 *     "Confirm eBike pickup" button is enabled (isHrSigned == true).
 *   - delivered_at null + onboarding_status false → user stays on the
 *     OnboardingDashboard at step 5 on launch.
 *   - No employee_pii row → after tapping confirm, performStepAction runs
 *     refreshProfileAndNavigateHome() which routes to Screen.AddressSetup
 *     (getHomeScreen guard: homeAddress null || homeLat null || homeLon null).
 */
async function resetToPickupReadyNoAddress(userId: string, companyId: string): Promise<void> {
  if (!BIKE_ID) throw new Error("E2E_BIKE_ID not set")
  await del("contracts",     `user_id=eq.${userId}`)
  await del("bike_orders",   `user_id=eq.${userId}`)
  await del("bike_benefits", `user_id=eq.${userId}`)
  await del("employee_pii",  `user_id=eq.${userId}`)

  const now = new Date().toISOString()
  const benefitRes = await rest("POST", `/rest/v1/bike_benefits`, {
    user_id: userId,
    bike_id: BIKE_ID,
    step: "pickup_delivery",
    benefit_status: "active",
    contract_status: "approved",
    committed_at: now,
    contract_requested_at: now,
    contract_employee_signed_at: now,
    contract_employer_signed_at: now,
    contract_approved_at: now,
    // delivered_at intentionally null — tapping "Confirm eBike pickup"
    // is what sets it; flow 2 exercises that transition.
  }, "return=representation")
  const benefit = (await benefitRes.json() as { id: string }[])[0]

  await rest("POST", `/rest/v1/bike_orders`,
    { user_id: userId, bike_benefit_id: benefit.id, helmet: false, insurance: false },
    "return=minimal")

  await rest("POST", `/rest/v1/contracts`, {
    user_id: userId,
    bike_benefit_id: benefit.id,
    esignatures_contract_id: `e2e-fake-${benefit.id}`,
    esignatures_template_id: "e2e-fake-template",
    sign_page_url: "https://example.com/e2e-stub",
  }, "return=minimal")

  await patch("profiles", `user_id=eq.${userId}`, { onboarding_status: false })
  void companyId
}

async function resetToCompleted(userId: string, companyId: string, withAddress: boolean): Promise<void> {
  if (!BIKE_ID) throw new Error("E2E_BIKE_ID not set")
  await del("contracts",     `user_id=eq.${userId}`)
  await del("bike_orders",   `user_id=eq.${userId}`)
  await del("bike_benefits", `user_id=eq.${userId}`)
  await del("employee_pii",  `user_id=eq.${userId}`)

  const now = new Date().toISOString()
  const benefitRes = await rest("POST", `/rest/v1/bike_benefits`, {
    user_id: userId,
    bike_id: BIKE_ID,
    step: "pickup_delivery",
    benefit_status: "active",
    contract_status: "approved",
    committed_at: now,
    contract_requested_at: now,
    contract_employee_signed_at: now,
    contract_employer_signed_at: now,
    contract_approved_at: now,
    delivered_at: now,
  }, "return=representation")
  const benefit = (await benefitRes.json() as { id: string }[])[0]

  await rest("POST", `/rest/v1/bike_orders`,
    { user_id: userId, bike_benefit_id: benefit.id, helmet: false, insurance: false },
    "return=minimal")

  // Stub contracts row so get-employee-details returns a sign_page_url and
  // any code path that joins on contracts.bike_benefit_id finds a match.
  await rest("POST", `/rest/v1/contracts`, {
    user_id: userId,
    bike_benefit_id: benefit.id,
    esignatures_contract_id: `e2e-fake-${benefit.id}`,
    esignatures_template_id: "e2e-fake-template",
    sign_page_url: "https://example.com/e2e-stub",
  }, "return=minimal")

  await patch("profiles", `user_id=eq.${userId}`, { onboarding_status: true })

  if (withAddress) {
    // Encrypt the Cluj-Napoca fixture with the same Vault/env key
    // update-employee-pii uses, so get-employee-details can decrypt it back.
    const db = makeRestClient(SUPABASE_URL, SERVICE_ROLE_KEY)
    const [
      nationalIdEnc,
      dobEnc,
      phoneEnc,
      homeAddressEnc,
      homeLatEnc,
      homeLonEnc,
      salaryGrossEnc,
    ] = await Promise.all([
      encrypt(db, E2E_PII_NATIONAL_ID),
      encrypt(db, E2E_PII_DATE_OF_BIRTH),
      encrypt(db, E2E_PII_PHONE),
      encrypt(db, E2E_HOME_ADDRESS),
      encrypt(db, String(E2E_HOME_LAT)),
      encrypt(db, String(E2E_HOME_LON)),
      encrypt(db, String(E2E_PII_SALARY_GROSS)),
    ])

    await rest("POST", `/rest/v1/employee_pii`, {
      user_id: userId,
      company_id: companyId,
      national_id_encrypted:   nationalIdEnc,
      date_of_birth_encrypted: dobEnc,
      phone_encrypted:         phoneEnc,
      home_address_encrypted:  homeAddressEnc,
      home_lat_encrypted:      homeLatEnc,
      home_lon_encrypted:      homeLonEnc,
      salary_gross_encrypted:  salaryGrossEnc,
      country:                 "RO",
      nationality_iso:         "RO",
      country_of_domicile_iso: "RO",
      id_document_type:        "national_id",
      salary_currency:         "RON",
      education_level:         "bachelor",
    }, "return=minimal")
  }
}

// ─── Commands ────────────────────────────────────────────────────────────────

async function bootstrap(): Promise<Record<string, unknown>> {
  const companyId = await ensureCompany()
  const result: Record<string, string> = { company_id: companyId }
  for (const acct of Object.keys(ACCOUNTS) as AccountKey[]) {
    if (acct === "register") {
      await upsertInvite(ACCOUNTS[acct].email, companyId, ACCOUNTS[acct].firstName, ACCOUNTS[acct].lastName)
      result[ACCOUNTS[acct].email] = "invite-only"
      continue
    }
    const uid = await ensureAccount(acct, companyId)
    result[ACCOUNTS[acct].email] = uid
  }
  return { ok: true, bootstrap: result }
}

async function reset(flowName: string): Promise<Record<string, unknown>> {
  const spec = FLOWS[flowName]
  if (!spec) {
    return { ok: false, error: `unknown flow`, known: Object.keys(FLOWS) }
  }
  const companyId = await ensureCompany()
  const result: Record<string, string> = {}

  for (const acct of spec.accounts) {
    if (spec.target === "pre_register") {
      await deleteAccountIfExists(acct)
      await upsertInvite(ACCOUNTS[acct].email, companyId, ACCOUNTS[acct].firstName, ACCOUNTS[acct].lastName)
      result[ACCOUNTS[acct].email] = "pre_register"
      continue
    }
    if (spec.target === "register") {
      const regesCompanyId = await ensureRegesGmailCompany()
      await deleteAccountIfExists(acct)
      await del("profile_invites", `email=eq.${encodeURIComponent(ACCOUNTS[acct].email)}`)
      await resetToRegesPending(regesCompanyId)
      result[ACCOUNTS[acct].email] = "register"
      continue
    }
    const uid = await ensureAccount(acct, companyId)
    switch (spec.target) {
      case "fresh":                    await resetToFresh(uid); break
      case "pickup_ready_no_address":  await resetToPickupReadyNoAddress(uid, companyId); break
      case "completed_no_address":     await resetToCompleted(uid, companyId, false); break
      case "completed_with_address":   await resetToCompleted(uid, companyId, true); break
    }
    result[ACCOUNTS[acct].email] = spec.target
  }
  return { ok: true, flow: flowName, target: spec.target, accounts: result }
}

// ─── Handler ─────────────────────────────────────────────────────────────────

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  await loadSecrets()
  if (!E2E_SECRET) return json({ error: "e2e_not_configured" }, 503)
  if (req.headers.get("X-E2E-Secret") !== E2E_SECRET) {
    return json({ error: "forbidden" }, 403)
  }

  let body: { command?: string; flow?: string }
  try {
    body = await req.json()
  } catch {
    return json({ error: "invalid_json" }, 400)
  }

  try {
    if (body.command === "bootstrap") {
      return json(await bootstrap())
    }
    if (body.command === "reset") {
      if (!body.flow) return json({ error: "flow_required" }, 400)
      return json(await reset(body.flow))
    }
    return json({ error: "unknown_command", known: ["bootstrap", "reset"] }, 400)
  } catch (err) {
    console.error("[e2e-seed] error:", err)
    return json({ error: "internal_error", message: (err as Error).message }, 500)
  }
})
