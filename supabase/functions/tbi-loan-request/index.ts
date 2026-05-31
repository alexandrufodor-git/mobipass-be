import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, badRequest, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"
import { makeRestClient, RestClient } from "../_shared/supabaseRest.ts"
import { decrypt } from "../_shared/piiCrypto.ts"
import { rsaChunkEncrypt } from "../_shared/tbiCrypto.ts"
import {
  loadTbiCredentials,
  loadTbiOutgoingPublicKey,
  buildTbiPayload,
  submitLoanApplication,
  type TbiProfileData,
} from "../_shared/tbiClient.ts"

// ─── Types ──────────────────────────────────────────────────────────────────

interface Profile {
  first_name: string
  last_name: string
  email: string
  company_id: string
}

interface BikeBenefit {
  id: string
  bike_id: string | null
  step: string | null
  employee_full_price: number | null
  employee_contract_months: number | null
}

interface Bike {
  id: string
  name: string
  brand: string | null
  sku: string | null
  full_price: number
}

interface EmployeePii {
  phone_encrypted: string | null
  national_id_encrypted: string | null
  home_address_encrypted: string | null
}

// ─── Data loaders ───────────────────────────────────────────────────────────

async function loadProfile(db: RestClient, userId: string, origin?: string): Promise<Profile> {
  const profile = await db.getOne<Profile>(
    "profiles",
    `user_id=eq.${encodeURIComponent(userId)}`,
    "first_name,last_name,email,company_id"
  )
  if (!profile) throw badRequest(Errors.PROFILE_NOT_FOUND, undefined, origin)
  if (!profile.company_id) throw badRequest(Errors.NO_COMPANY, undefined, origin)
  return profile
}

async function loadBikeBenefit(db: RestClient, userId: string, origin?: string): Promise<BikeBenefit> {
  const benefit = await db.getOne<BikeBenefit>(
    "bike_benefits",
    `user_id=eq.${encodeURIComponent(userId)}`,
    "id,bike_id,step,employee_full_price,employee_contract_months"
  )
  if (!benefit) throw badRequest(Errors.NO_BIKE_BENEFIT, undefined, origin)
  if (!benefit.bike_id) throw badRequest(Errors.NO_BIKE_SELECTED, undefined, origin)
  return benefit
}

async function loadBike(db: RestClient, bikeId: string, origin?: string): Promise<Bike> {
  const bike = await db.getOne<Bike>("bikes", `id=eq.${bikeId}`, "id,name,brand,sku,full_price")
  if (!bike) throw badRequest(Errors.BIKE_NOT_FOUND, undefined, origin)
  return bike
}

async function loadPii(db: RestClient, userId: string): Promise<EmployeePii | null> {
  return db.getOne<EmployeePii>(
    "employee_pii",
    `user_id=eq.${encodeURIComponent(userId)}`,
    "phone_encrypted,national_id_encrypted,home_address_encrypted"
  )
}

// ─── Handler ────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  if (req.method === "OPTIONS") return corsResponse(origin)

  try {
    const db = makeRestClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!)
    const jwt = requireJwt(req, origin)
    const userId = extractUserId(jwt, origin)

    // 1. Load employee data in parallel
    const [profile, benefit, pii] = await Promise.all([
      loadProfile(db, userId, origin),
      loadBikeBenefit(db, userId, origin),
      loadPii(db, userId),
    ])
    const bike = await loadBike(db, benefit.bike_id!, origin)

    // 2. Decrypt PII fields needed for TBI payload
    const decryptNullable = (v: string | null | undefined) =>
      v == null || v === "" ? Promise.resolve(null) : decrypt(db, v)
    const [phone, cnp, homeAddress] = await Promise.all([
      decryptNullable(pii?.phone_encrypted),
      decryptNullable(pii?.national_id_encrypted),
      decryptNullable(pii?.home_address_encrypted),
    ])

    if (!cnp) {
      throw badRequest({ error: "cnp_required", reason: "National ID (CNP) is required for TBI loan application" }, undefined, origin)
    }
    if (!phone) {
      throw badRequest({ error: "phone_required", reason: "Phone number is required for TBI loan application" }, undefined, origin)
    }

    // 3. Load TBI credentials + outgoing public key
    const [creds, publicKey] = await Promise.all([
      loadTbiCredentials(db),
      loadTbiOutgoingPublicKey(db),
    ]).catch(() => {
      throw json({ ...Errors.TBI_CREDENTIALS_MISSING }, 500, origin)
    })

    // 4. Build payload matching TBI API spec
    const orderId = `mbp_${Date.now()}_${benefit.id.slice(0, 8)}`
    const webhookUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/tbi-webhook`
    const orderTotal = benefit.employee_full_price ?? bike.full_price
    const instalments = benefit.employee_contract_months ?? 24
    const bikeName = bike.brand ? `${bike.brand} ${bike.name}` : bike.name
    const bikeSku = bike.sku ?? bike.id
    // TODO: once bike_orders is created at the sign_contract step (see
    // send-contract/index.ts), read the frozen SKU + add-ons from there
    // instead of re-deriving from bikes, and expand items[] to include
    // helmet/insurance as separate line items when present.

    const tbiProfile: TbiProfileData = {
      first_name: profile.first_name,
      last_name: profile.last_name,
      email: profile.email,
      phone,
      cnp,
      home_address: homeAddress ?? undefined,
    }

    const payload = buildTbiPayload(creds, tbiProfile, bikeName, bikeSku, orderTotal, orderId, instalments, webhookUrl)

    // 5. Encrypt
    const encrypted = await rsaChunkEncrypt(JSON.stringify(payload), publicKey)

    // 6. Submit to TBI (storeId doubles as providerCode per TBI docs)
    const { redirectUrl } = await submitLoanApplication(encrypted, creds.storeId)
      .catch((err) => {
        console.error("[tbi-loan-request] TBI API error:", err)
        throw json({ ...Errors.TBI_API_FAILED, reason: err.message }, 500, origin)
      })

    // 7. Save to DB
    await db.post("tbi_loan_applications", {
      profile_id: userId,
      bike_benefit_id: benefit.id,
      order_id: orderId,
      order_total: orderTotal,
      status: "pending",
      redirect_url: redirectUrl,
    })

    return json({ success: true, redirect_url: redirectUrl, order_id: orderId }, 200, origin)
  } catch (e) {
    if (e instanceof Response) return e
    console.error("[tbi-loan-request] unexpected error:", e)
    throw e
  }
})
