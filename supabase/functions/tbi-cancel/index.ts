import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, badRequest, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { rsaChunkEncrypt } from "../_shared/tbiCrypto.ts"
import {
  loadTbiCredentials,
  loadTbiOutgoingPublicKey,
  buildTbiCancelPayload,
  submitCancellation,
} from "../_shared/tbiClient.ts"

// ─── Types ──────────────────────────────────────────────────────────────────

interface LoanApp {
  id: string
  profile_id: string
  order_id: string
  status: string
}

// ─── Handler ────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  if (req.method === "OPTIONS") return corsResponse(origin)

  try {
    const db = makeRestClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!)
    const jwt = requireJwt(req, origin)
    const userId = extractUserId(jwt, origin)

    // Parse request body
    const { order_id } = await req.json() as { order_id: string }
    if (!order_id) throw badRequest({ error: "order_id_required" }, undefined, origin)

    // 1. Find loan application — must belong to this user
    const loan = await db.getOne<LoanApp>(
      "tbi_loan_applications",
      `order_id=eq.${encodeURIComponent(order_id)}&profile_id=eq.${encodeURIComponent(userId)}`,
      "id,profile_id,order_id,status"
    )
    if (!loan) throw badRequest(Errors.LOAN_NOT_FOUND, undefined, origin)

    // Only pending loans can be canceled (TBI: "can be used before Approval")
    if (loan.status !== "pending") {
      throw badRequest(Errors.LOAN_NOT_CANCELABLE, { current_status: loan.status }, origin)
    }

    // 2. Load credentials + outgoing public key
    const [creds, publicKey] = await Promise.all([
      loadTbiCredentials(db),
      loadTbiOutgoingPublicKey(db),
    ])

    // 3. Build and encrypt cancel payload (TBI format: orderId, statusId, username, password)
    const cancelPayload = buildTbiCancelPayload(creds, order_id)
    const encrypted = await rsaChunkEncrypt(JSON.stringify(cancelPayload), publicKey)

    // 4. Submit cancellation to TBI (storeId doubles as encryptCode per TBI docs)
    const result = await submitCancellation(encrypted, creds.storeId)
    if (!result.isSuccess) {
      console.error("[tbi-cancel] TBI cancellation failed:", result.error)
      throw json({ ...Errors.TBI_API_FAILED, reason: result.error }, 500, origin)
    }

    // 5. Update DB
    await db.patch("tbi_loan_applications", `order_id=eq.${encodeURIComponent(order_id)}`, {
      status: "canceled",
    })

    return json({ success: true, order_id }, 200, origin)
  } catch (e) {
    if (e instanceof Response) return e
    console.error("[tbi-cancel] unexpected error:", e)
    throw e
  }
})
