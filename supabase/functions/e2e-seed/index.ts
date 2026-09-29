// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { encrypt } from "../_shared/piiCrypto.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import {
  ingestRegesArray,
  type CompanyCtx,
  type RegesRecord,
} from "../_shared/regesIngest.ts"
import type { EmailPatternKind } from "../_shared/emailPattern.ts"

/**
 * e2e-seed — Test account bootstrap & reset for Maestro flows.
 *
 * Request: POST with X-E2E-Secret header.
 *   Body: { command: "bootstrap" }
 *         { command: "reset", flow: "<flow-name>" }
 *         { command: "copilot_test_due" }  — mid-flow: test day 15 min ago, confirm unlocked
 *
 * Vault secrets (set via scripts/setup-e2e-vault.sh for local, or SQL on prod):
 *   e2e_secret            — required shared secret (matches X-E2E-Secret header)
 *   e2e_default_password  — password set on the account at (re)registration
 *   e2e_bike_id           — bike UUID used for post-choose_bike target states
 *   e2e_reges             — REGES JSON used to seed the staged invite + PII.
 *                           Stored as a JSON ARRAY of RegesRecord (same shape
 *                           as a raport.json export); the first record is used.
 *                           Contains a valid-format Romanian CNP, so the value
 *                           never lives in source — local is loaded from
 *                           scripts/dev/assets/e2e-reges.json (gitignored) via
 *                           setup-e2e-vault.sh, prod is set manually in the
 *                           dashboard SQL editor.
 *
 * REGES-ALWAYS, SINGLE-ACCOUNT MODEL
 * ----------------------------------
 * Every reset re-creates the one account `fodor.horatiu.alexandru@gmail.com` by
 * SIMULATING THE REAL PIPELINE end-to-end, so the seeded state is identical to
 * production rather than hand-faked:
 *
 *   1. seedRegesStaged()   — feed the REGES record loaded from Vault
 *      (`e2e_reges`) through the SAME ingestion path bulk-create uses
 *      (`ingestRegesArray`). Produces the staged invite + encrypted PII
 *      exactly as a real REGES upload would.
 *   2. registerFromStaged() — claim the staged invite (set its email) then
 *      create the confirmed auth user, so handle_user_registration links it for
 *      real: profile (company), employee role, bike_benefit, and
 *      employee_pii.user_id (trigger step 4.5).
 *   3. resetTo<state>()    — change ONLY the dynamic state (bike_benefits step /
 *      contract / order / onboarding_status, and the app-collected PII extras
 *      for the completed dashboard). The REGES identity PII is never rebuilt —
 *      same employee data every time, only status changes per the flow's YAML.
 *
 * The `reges_pending` target stops after step 1 (staged, no auth user) so the
 * Maestro register flow can perform the real claim+OTP itself.
 *
 * Environment-agnostic: the gmail company is resolved by email_domain, so the
 * same function works against the local seed and prod.
 */

// ─── The one company + one account ────────────────────────────────────────────

// Resolved at runtime by this domain (unique per the companies_email_domain
// index). Local seed id is 44444444-…; prod's is DB-generated — never matched.
const COMPANY_DOMAIN        = "gmail.com"
// Named pattern from public.email_pattern_kind. Resolves to
// "{last}?{.{middle}}.{first}" → fodor.horatiu.alexandru@gmail.com.
const COMPANY_EMAIL_PATTERN = "last_middle_first" as EmailPatternKind
const E2E_ESIG_TEMPLATE_ID  = "6c9db750-f9f9-4f63-8a98-ada842cbc5bd"

// Fake HR-set office address used by AddressSetup's Work row and by any
// dashboard route estimation that reads Company.address. Real Cluj coords so
// downstream Mapbox/route calls behave realistically.
const E2E_COMPANY_ADDRESS   = "Strada Avram Iancu 22, Cluj-Napoca 400117"
const E2E_COMPANY_LAT       = 46.7693
const E2E_COMPANY_LON       = 23.5893

const ACCOUNT_EMAIL         = "fodor.horatiu.alexandru@gmail.com"

// Home coords for the REGES `adresa`. The record itself only carries a string
// address; these are real Cluj coords near Strada Eroilor so distance/route
// widgets render meaningful values once the address is set during onboarding.
const E2E_HOME_LAT          = 46.7691
const E2E_HOME_LON          = 23.5847

// App-collected extras (not in REGES; entered by the employee during
// onboarding). Added to the completed dashboard state only.
const E2E_PII_PHONE         = "+40712345678"
const E2E_PII_SALARY_GROSS  = 6000

type FlowTarget =
  | "reges_pending"
  | "fresh"
  | "fresh_copilot"
  | "pickup_ready_no_address"
  | "completed_no_address"
  | "completed_with_address"

const FLOWS: Record<string, FlowTarget> = {
  "registration":                    "reges_pending",
  "reges-claim-register":            "reges_pending",
  "reges-claim-bad-email":           "reges_pending",
  "onboarding-1-to-4":               "fresh",
  "onboarding-copilot":              "fresh_copilot",
  "onboarding-step-5":               "pickup_ready_no_address",
  "onboarding-step-5-to-dashboard":  "pickup_ready_no_address",
  "address-to-dashboard":            "completed_no_address",
  "dashboard-main":                  "completed_with_address",
  "ebike-catalog":                   "completed_with_address",
  "profile":                         "completed_with_address",
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
let REGES_RECORD: RegesRecord | null = null
let REGES_SOURCE_REF = ""

// Vault-first, Edge-Function-env fallback. Local sets Postgres Vault secrets
// (scripts/setup-e2e-vault.sh via docker psql); prod can instead use
// `supabase secrets set E2E_SECRET=… E2E_DEFAULT_PASSWORD=… E2E_BIKE_ID=…`,
// which needs only the access token (no prod DB credentials).
//
// e2e_reges is a JSON ARRAY string (matches a raport.json export); we use the
// first record. Kept out of code/env to avoid leaking the CNP via source — the
// env fallback exists only so tests can inject a synthetic record.
async function loadSecrets(): Promise<void> {
  E2E_SECRET       = (await getVaultSecret("e2e_secret"))           ?? Deno.env.get("E2E_SECRET")           ?? ""
  DEFAULT_PASSWORD = (await getVaultSecret("e2e_default_password")) ?? Deno.env.get("E2E_DEFAULT_PASSWORD") ?? ""
  BIKE_ID          = (await getVaultSecret("e2e_bike_id"))          ?? Deno.env.get("E2E_BIKE_ID")          ?? ""

  const regesJson = (await getVaultSecret("e2e_reges")) ?? Deno.env.get("E2E_REGES") ?? ""
  if (regesJson) {
    let parsed: unknown
    try {
      parsed = JSON.parse(regesJson)
    } catch (err) {
      throw new Error(`e2e_reges is not valid JSON: ${(err as Error).message}`)
    }
    const record = Array.isArray(parsed) ? parsed[0] : parsed
    if (!record || typeof record !== "object") {
      throw new Error("e2e_reges must be a RegesRecord (or array with one)")
    }
    REGES_RECORD     = record as RegesRecord
    REGES_SOURCE_REF = REGES_RECORD.referintaSalariat?.id ?? ""
    if (!REGES_SOURCE_REF) {
      throw new Error("e2e_reges record missing referintaSalariat.id")
    }
  } else {
    REGES_RECORD     = null
    REGES_SOURCE_REF = ""
  }
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

// ─── Auth admin helpers ──────────────────────────────────────────────────────

type AuthUser = { id: string; email: string }

async function getAuthUserByEmail(email: string): Promise<AuthUser | null> {
  // GoTrue admin list endpoint does NOT support server-side email filtering —
  // paginate and match client-side. Safe for E2E usage (test account only).
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
  // (which creates profile + user_roles + bike_benefit, and links REGES PII).
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

// ─── Company setup ────────────────────────────────────────────────────────────

/**
 * Ensure the gmail company exists and carries every field the E2E flows need.
 * Resolved by email_domain (unique), so it works on local seed + prod alike.
 */
async function ensureCompany(): Promise<string> {
  const existing = await getOne<{
    id: string
    email_domain: string | null
    email_pattern: string | null
    esignatures_template_id: string | null
    address: string | null
    address_lat: number | null
    address_lon: number | null
  }>(
    "companies",
    `email_domain=eq.${COMPANY_DOMAIN}`,
    "id,email_domain,email_pattern,esignatures_template_id,address,address_lat,address_lon",
  )
  if (!existing) {
    throw new Error(
      `No company with email_domain=${COMPANY_DOMAIN} found — ` +
        `run supabase db reset (local) or create the gmail company (prod)`,
    )
  }
  // Backfill any field missing on rows created before it was added here.
  const backfill: Record<string, unknown> = {}
  if (existing.email_domain  !== COMPANY_DOMAIN)        backfill.email_domain  = COMPANY_DOMAIN
  if (existing.email_pattern !== COMPANY_EMAIL_PATTERN) backfill.email_pattern = COMPANY_EMAIL_PATTERN
  if (existing.esignatures_template_id !== E2E_ESIG_TEMPLATE_ID) {
    backfill.esignatures_template_id = E2E_ESIG_TEMPLATE_ID
  }
  if (existing.address     !== E2E_COMPANY_ADDRESS) backfill.address     = E2E_COMPANY_ADDRESS
  if (existing.address_lat !== E2E_COMPANY_LAT)     backfill.address_lat = E2E_COMPANY_LAT
  if (existing.address_lon !== E2E_COMPANY_LON)     backfill.address_lon = E2E_COMPANY_LON
  if (Object.keys(backfill).length > 0) {
    await patch("companies", `id=eq.${existing.id}`, backfill)
  }
  return existing.id
}

// ─── Teardown ─────────────────────────────────────────────────────────────────

/**
 * Full teardown of the auth user + everything it owns, the claimed invite, and
 * the staged REGES invite/PII for the fodor source ref. Run at the start of
 * every reset so each flow re-simulates from a clean slate: a fresh REGES
 * upload, then (for non-register targets) a fresh registration.
 */
async function deleteAccount(companyId: string): Promise<void> {
  const user = await getAuthUserByEmail(ACCOUNT_EMAIL)
  if (user) {
    await del("contracts",     `user_id=eq.${user.id}`)
    await del("bike_orders",   `user_id=eq.${user.id}`)
    await del("bike_benefits", `user_id=eq.${user.id}`)
    await del("employee_pii",  `user_id=eq.${user.id}`)
    await del("user_roles",    `user_id=eq.${user.id}`)
    await del("profiles",      `user_id=eq.${user.id}`)
    await deleteAuthUser(user.id)
  }
  // The staged/claimed REGES invite (and its PII) are keyed by source_ref; the
  // invite's email may be NULL (staged) or set (claimed) — clear by source_ref.
  await del("employee_pii",
    `company_id=eq.${companyId}&source=eq.reges&source_ref_id=eq.${REGES_SOURCE_REF}`)
  await del("profile_invites",
    `company_id=eq.${companyId}&source=eq.reges&source_ref_id=eq.${REGES_SOURCE_REF}`)
  // Also drop any invite already holding this email (a claimed REGES invite, or
  // a stale manual one from a prior run) so re-claiming it can't collide with
  // the partial unique index on lower(email).
  await del("profile_invites", `email=eq.${encodeURIComponent(ACCOUNT_EMAIL)}`)
}

// ─── REGES seed + simulated registration ───────────────────────────────────────

/**
 * Seed the staged REGES record (invite + encrypted PII, email NULL, user_id
 * NULL) by running the fodor record through the SAME ingestion bulk-create
 * uses. Guarantees parity with a real REGES upload.
 */
async function seedRegesStaged(companyId: string): Promise<void> {
  if (!REGES_RECORD) throw new Error("e2e_reges not set (Vault or env)")
  const db = makeRestClient(SUPABASE_URL, SERVICE_ROLE_KEY)
  const ctx: CompanyCtx = {
    id:            companyId,
    email_domain:  COMPANY_DOMAIN,
    email_pattern: COMPANY_EMAIL_PATTERN,
  }
  const results = await ingestRegesArray(db, ctx, [REGES_RECORD])
  const r = results[0]
  if (!r || r.status === "failed") {
    throw new Error(`seedRegesStaged: ingest failed: ${JSON.stringify(r)}`)
  }
}

/**
 * Simulate the real /register claim + OTP signup against the staged record:
 * claim the staged invite (set its email) then create the confirmed auth user.
 * handle_user_registration then does the real linking — profile (company),
 * employee role, bike_benefit, and employee_pii.user_id (trigger step 4.5).
 * Returns the new user id.
 */
async function registerFromStaged(companyId: string): Promise<string> {
  // Claim: the /register edge function sets the staged invite's email before
  // signup; the registration trigger resolves the invite by email.
  await patch("profile_invites",
    `company_id=eq.${companyId}&source=eq.reges&source_ref_id=eq.${REGES_SOURCE_REF}`,
    { email: ACCOUNT_EMAIL })
  if (!DEFAULT_PASSWORD) throw new Error("e2e_default_password not set (Vault or env)")
  const user = await createAuthUser(ACCOUNT_EMAIL, DEFAULT_PASSWORD)
  if (!user?.id) throw new Error(`createAuthUser returned no id for ${ACCOUNT_EMAIL}`)
  return user.id
}

/**
 * Grant the `hr` role on top of the `employee` role the registration trigger
 * already created — the test account exercises the multi-role "HR is also an
 * employee" use case, so it must hold both. The custom_access_token_hook then
 * emits user_role="hr" (highest privilege) and user_roles=["hr","employee"].
 * Safe as a plain insert: deleteAccount wipes user_roles each reset and
 * registration only re-adds the employee row, so hr is always absent here.
 */
async function grantHrRole(userId: string): Promise<void> {
  await rest("POST", `/rest/v1/user_roles`,
    { user_id: userId, role: "hr" }, "return=minimal")
}

// ─── Target state appliers ──────────────────────────────────────────────────
// These change ONLY the dynamic state. The REGES identity PII linked at
// registration is preserved (never deleted) — same employee data every reset.

async function resetToFresh(userId: string): Promise<void> {
  await del("contracts",     `user_id=eq.${userId}`)
  await del("bike_orders",   `user_id=eq.${userId}`)
  await del("bike_benefits", `user_id=eq.${userId}`)
  await rest("POST", `/rest/v1/bike_benefits`,
    { user_id: userId, step: "choose_bike" }, "return=minimal")
  await patch("profiles", `user_id=eq.${userId}`, { onboarding_status: false })
}

/**
 * Step 5 (pickup_delivery) ready to confirm — both parties have signed,
 * contract is approved, delivered_at is NULL.
 *
 * UI expectations:
 *   - contract_employer_signed_at non-null → PickupDeliveryCard's
 *     "Confirm eBike pickup" button is enabled (isHrSigned == true).
 *   - delivered_at null + onboarding_status false → user stays on the
 *     OnboardingDashboard at step 5 on launch.
 *   - employee_pii has the REGES home address but home_lat/home_lon are NULL →
 *     after tapping confirm, refreshProfileAndNavigateHome() routes to
 *     Screen.AddressSetup (getHomeScreen guard fires on null lat/lon).
 */
async function resetToPickupReadyNoAddress(userId: string, companyId: string): Promise<void> {
  if (!BIKE_ID) throw new Error("E2E_BIKE_ID not set")
  await del("contracts",     `user_id=eq.${userId}`)
  await del("bike_orders",   `user_id=eq.${userId}`)
  await del("bike_benefits", `user_id=eq.${userId}`)

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
    // Enrich the REGES-linked PII row with the app-collected fields the
    // employee would enter during onboarding (home coords for routing, phone,
    // salary). Identity fields (CNP/DOB/home address/country/id doc) are
    // already present from the REGES ingest — we only add the extras here.
    const db = makeRestClient(SUPABASE_URL, SERVICE_ROLE_KEY)
    const [phoneEnc, homeLatEnc, homeLonEnc, salaryGrossEnc] = await Promise.all([
      encrypt(db, E2E_PII_PHONE),
      encrypt(db, String(E2E_HOME_LAT)),
      encrypt(db, String(E2E_HOME_LON)),
      encrypt(db, String(E2E_PII_SALARY_GROSS)),
    ])
    await patch("employee_pii", `user_id=eq.${userId}`, {
      phone_encrypted:        phoneEnc,
      home_lat_encrypted:     homeLatEnc,
      home_lon_encrypted:     homeLonEnc,
      salary_gross_encrypted: salaryGrossEnc,
      salary_currency:        "RON",
      education_level:        "bachelor",
    })
    void companyId
  }
}

// ─── Commands ────────────────────────────────────────────────────────────────

/** Apply one flow target to the single account. Shared by reset() + bootstrap(). */
async function applyTarget(target: FlowTarget, companyId: string): Promise<void> {
  await deleteAccount(companyId)
  await seedRegesStaged(companyId)
  // Company-wide copilot settings: every target sets them so a copilot run can't
  // leak into the next flow. Test day is tomorrow (confirm locked); copilotTestDue() unlocks it.
  const copilot = target === "fresh_copilot"
  await patch("companies", `id=eq.${companyId}`, {
    copilot_stop_after_commit: copilot,
    live_test_at: copilot ? new Date(Date.now() + 24 * 3_600_000).toISOString() : null,
  })
  // reges_pending stops here — staged invite + PII, no auth user — so the
  // Maestro register flow performs the real claim + OTP signup itself.
  if (target === "reges_pending") return

  const uid = await registerFromStaged(companyId)
  // Every registered E2E state holds hr+employee (multi-role use case).
  await grantHrRole(uid)
  switch (target) {
    case "fresh":
    case "fresh_copilot":            await resetToFresh(uid); break
    case "pickup_ready_no_address":  await resetToPickupReadyNoAddress(uid, companyId); break
    case "completed_no_address":     await resetToCompleted(uid, companyId, false); break
    case "completed_with_address":   await resetToCompleted(uid, companyId, true); break
  }
}

async function bootstrap(): Promise<Record<string, unknown>> {
  // Ensure the company exists and leave the account in the reges_pending state
  // so a fresh bootstrap is immediately ready for the register flow; every
  // other flow resets it to its own target on run.
  const companyId = await ensureCompany()
  await applyTarget("reges_pending", companyId)
  return { ok: true, company_id: companyId, account: ACCOUNT_EMAIL, state: "reges_pending" }
}

async function reset(flowName: string): Promise<Record<string, unknown>> {
  const target = FLOWS[flowName]
  if (!target) {
    return { ok: false, error: `unknown flow`, known: Object.keys(FLOWS) }
  }
  const companyId = await ensureCompany()
  await applyTarget(target, companyId)
  return { ok: true, flow: flowName, target, account: ACCOUNT_EMAIL }
}

async function copilotTestDue(): Promise<Record<string, unknown>> {
  const companyId = await ensureCompany()
  const liveTestAt = new Date(Date.now() - 15 * 60_000).toISOString()
  await patch("companies", `id=eq.${companyId}`, { live_test_at: liveTestAt, live_test_confirm_offset_min: 15 })
  return { ok: true, live_test_at: liveTestAt }
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
    if (body.command === "copilot_test_due") {
      return json(await copilotTestDue())
    }
    return json({ error: "unknown_command", known: ["bootstrap", "reset", "copilot_test_due"] }, 400)
  } catch (err) {
    console.error("[e2e-seed] error:", err)
    return json({ error: "internal_error", message: (err as Error).message }, 500)
  }
})
