// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, ESIGNATURES_API_URL, ESIGNATURES_VAULT_KEY, NotificationEvent, badRequest, forbidden, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"
import { makeRestClient, RestClient } from "../_shared/supabaseRest.ts"
import { sendFcm } from "../_shared/fcm.ts"
import { sendNotification } from "../_shared/notifications.ts"

// ─── Types ───────────────────────────────────────────────────────────────────

interface Profile {
  first_name: string
  last_name: string
  email: string
  department: string | null
  hire_date: number | null
  company_id: string
}

interface Company {
  name: string
  esignatures_template_id: string
  address: string | null
  contact_email: string | null
}

interface BikeBenefit {
  id: string
  bike_id: string | null
  contract_requested_at: string | null
  employee_full_price: number | null
  employee_monthly_price: number | null
  employee_contract_months: number | null
  employee_currency: string | null
  step: string | null
}

interface Bike {
  id: string
  name: string
  brand: string | null
  sku: string | null
  full_price: number
}

interface Signer {
  name: string
  email: string
  phone: string
  signing_order: number
}

interface EsigResult {
  contractId: string
  signerId: string | null
  signPageUrl: string | null
  rawResponse: unknown
}

// ─── Data loaders (each throws a Response on missing/invalid data) ────────────

async function loadProfile(db: RestClient, userId: string, origin?: string): Promise<Profile> {
  const profile = await db.getOne<Profile>(
    "profiles",
    `user_id=eq.${encodeURIComponent(userId)}`
  )
  if (!profile)          throw badRequest(Errors.PROFILE_NOT_FOUND, undefined, origin)
  if (!profile.company_id) throw badRequest(Errors.NO_COMPANY, undefined, origin)
  return profile
}

async function loadCompany(db: RestClient, companyId: string, origin?: string): Promise<Company> {
  const company = await db.getOne<Company>(
    "companies",
    `id=eq.${companyId}`,
    "name,esignatures_template_id,address,contact_email"
  )
  if (!company)                         throw badRequest(Errors.NO_COMPANY, undefined, origin)
  if (!company.esignatures_template_id) throw badRequest(Errors.NO_TEMPLATE, undefined, origin)
  return company
}

async function loadHR(db: RestClient, companyId: string, origin?: string): Promise<Profile> {
  const row = await db.getOne<{ profiles: Profile }>(
    "user_roles",
    `role=eq.hr&profiles.company_id=eq.${companyId}`,
    "profiles(first_name,last_name,email)"
  )
  if (!row) throw badRequest(Errors.NO_HR, undefined, origin)
  return row.profiles
}

async function loadBikeBenefit(db: RestClient, userId: string, origin?: string): Promise<BikeBenefit> {
  const benefit = await db.getOne<BikeBenefit>(
    "bike_benefits",
    `user_id=eq.${encodeURIComponent(userId)}`,
    "id,bike_id,contract_requested_at,employee_full_price,employee_monthly_price,employee_contract_months,employee_currency,step"
  )
  if (!benefit)                      throw badRequest(Errors.NO_BIKE_BENEFIT, undefined, origin)
  if (!benefit.bike_id)              throw badRequest(Errors.NO_BIKE_SELECTED, undefined, origin)
  return benefit
}

async function loadBike(db: RestClient, bikeId: string, origin?: string): Promise<Bike> {
  const bike = await db.getOne<Bike>("bikes", `id=eq.${bikeId}`, "id,name,brand,sku,full_price")
  if (!bike) throw badRequest(Errors.BIKE_NOT_FOUND, undefined, origin)
  return bike
}

async function loadApiKey(db: RestClient, origin?: string): Promise<string> {
  const key = await db.rpc<string | null>("get_vault_secret", { secret_name: ESIGNATURES_VAULT_KEY })
  if (!key) throw json({ ...Errors.ESIGNATURES_API_FAILED, reason: "vault_secret_missing" }, 500, origin)
  return key
}

function mapProfileToSigner(...profiles: Profile[]): Signer[] {
  return profiles
    .filter(p => p && p.email && p.first_name) 
    .map((profile, index) => ({
       name: `${profile.first_name} ${profile.last_name}`.trim(),
       email: profile.email,
       phone: "+405505050",
       signing_order: index+1
    }))
}

// ─── eSignatures.com helpers ─────────────────────────────────────────────────

function buildPlaceholders(profile: Profile, company: Company, bike: Bike, benefit: BikeBenefit) {
  const hireDate = profile.hire_date
    ? new Date(profile.hire_date).toISOString().split("T")[0]
    : ""

  return [
    { api_key: "first_name",             value: profile.first_name ?? "" },
    { api_key: "last_name",              value: profile.last_name ?? "" },
    { api_key: "email",                  value: profile.email ?? "" },
    { api_key: "department",             value: profile.department ?? "" },
    { api_key: "hire_date",              value: hireDate },
    { api_key: "company_name",           value: company.name ?? "" },
    { api_key: "company_address",        value: company.address ?? "" },
    { api_key: "company_contact_email",  value: company.contact_email ?? "" },
    { api_key: "bike_name",              value: bike.name ?? "" },
    { api_key: "bike_brand",             value: bike.brand ?? "" },
    { api_key: "bike_full_price",        value: String(bike.full_price ?? "") },
    { api_key: "employee_full_price",    value: String(benefit.employee_full_price ?? "") },
    { api_key: "employee_monthly_price", value: String(benefit.employee_monthly_price ?? "") },
    { api_key: "contract_months",        value: String(benefit.employee_contract_months ?? "") },
    { api_key: "currency",               value: benefit.employee_currency ?? "" },
    { api_key: "begin_date",             value: new Date().toISOString().split("T")[0] },
  ]
}

async function callEsignaturesApi(
  apiKey: string,
  templateId: string,
  signers: Signer[],
  placeholders: ReturnType<typeof buildPlaceholders>,
  origin?: string,
  test: boolean = true
): Promise<EsigResult> {
  const res = await fetch(`${ESIGNATURES_API_URL}?token=${apiKey}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      template_id: templateId,
      signers: signers,
      placeholder_fields: placeholders,
      test: test
    }),
  })

  if (!res.ok) {
    const details = await res.json().catch(() => ({}))
    throw json({ ...Errors.ESIGNATURES_API_FAILED, details }, 500, origin)
  }

  const data = await res.json()
  return {
    contractId:  data?.data?.contract?.id,
    signerId:    data?.data?.contract?.signers?.[0]?.id    ?? null,
    signPageUrl: data?.data?.contract?.signers?.[0]?.sign_page_url ?? null,
    rawResponse: data,
  }
}

async function saveContract(
  db: RestClient,
  benefitId: string,
  userId: string,
  templateId: string,
  result: EsigResult,
  origin?: string
): Promise<void> {
  const res = await db.post("contracts", {
    bike_benefit_id:         benefitId,
    user_id:                 userId,
    esignatures_contract_id: result.contractId,
    esignatures_signer_id:   result.signerId,
    esignatures_template_id: templateId,
    sign_page_url:           result.signPageUrl,
    api_response:            result.rawResponse,
  })
  if (!res.ok) {
    const details = await res.json().catch(() => ({}))
    throw json({ ...Errors.ESIGNATURES_API_FAILED, reason: "contract_insert_failed", details }, 500, origin)
  }
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  if (req.method === "OPTIONS") return corsResponse(origin)

  try {
    const db     = makeRestClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!)
    const jwt    = requireJwt(req, origin)
    const userId = extractUserId(jwt, origin)

    // Verify caller has employee role
    const role = await db.getOne<{ role: string }>(
      "user_roles",
      `user_id=eq.${userId}&role=eq.employee`,
      "role"
    )
    if (!role) throw forbidden(undefined, origin)

    const profile = await loadProfile(db, userId, origin)
    const company = await loadCompany(db, profile.company_id, origin)
    const hr = await loadHR(db, profile.company_id, origin)
    const benefit = await loadBikeBenefit(db, userId, origin)

    // Guard: prevent duplicate contract requests
    if (benefit.contract_requested_at) {
      throw badRequest(Errors.CONTRACT_ALREADY_REQUESTED, undefined, origin)
    }

    // Guard: benefit must be at sign_contract step
    if (benefit.step !== "sign_contract") {
      throw badRequest(Errors.INVALID_BENEFIT_STEP, undefined, origin)
    }

    const bike    = await loadBike(db, benefit.bike_id!, origin)
    const apiKey  = await loadApiKey(db, origin)

    const placeholders = buildPlaceholders(profile, company, bike, benefit)
    const esigResult   = await callEsignaturesApi(
      apiKey,
      company.esignatures_template_id,
      mapProfileToSigner(profile, hr),
      placeholders,
      origin
    )

    await saveContract(db, benefit.id, userId, company.esignatures_template_id!, esigResult, origin)

    // Upsert bike_orders with a frozen snapshot of the bike. UPSERT (not
    // DELETE+INSERT) on the unique_benefit_order constraint preserves any
    // helmet/insurance flags an HR user may have set on a prior call. Only
    // snapshot fields are written — helmet/insurance and audit fields are
    // intentionally absent from the body.
    const orderRes = await db.upsert("bike_orders", {
      user_id:         userId,
      bike_benefit_id: benefit.id,
      bike_id:         bike.id,
      bike_sku:        bike.sku,
      bike_name:       bike.name,
      bike_brand:      bike.brand,
      bike_full_price: bike.full_price,
      frozen_at:       new Date().toISOString(),
    }, "bike_benefit_id")
    if (!orderRes.ok) {
      const details = await orderRes.text().catch(() => "")
      throw json({ ...Errors.ESIGNATURES_API_FAILED, reason: "bike_order_upsert_failed", details }, 500, origin)
    }

    await db.patch("bike_benefits", `id=eq.${benefit.id}`, {
      contract_requested_at: new Date().toISOString(),
      step: "pickup_delivery",
    })

    // Fire-and-forget notification insert — Realtime delivers it to HR dashboard
    sendNotification(db, profile.company_id, "contract_update", "created", {
      user_id: userId,
      employee_name: `${profile.first_name} ${profile.last_name}`.trim(),
      contract_id: esigResult.contractId,
    }).catch((err) => console.error("[send-contract] notification error:", err))

    // Fire-and-forget FCM push to employee
    sendFcm(db, userId, {
      title: "Contract Ready",
      body: "Your contract is ready. Check your email to view and sign.",
      event: NotificationEvent.CONTRACT_READY,
      bikeBenefitId: benefit.id,
    }).catch((err) => console.error("[send-contract] fcm error:", err))

    return json({ success: true, contract_id: esigResult.contractId, sign_page_url: esigResult.signPageUrl }, 200, origin)
  } catch (e) {
    if (e instanceof Response) return e
    throw e
  }
})
