import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { NotificationEvent } from "../_shared/constants.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { sendFcm } from "../_shared/fcm.ts"
import { sendNotification } from "../_shared/notifications.ts"
import { rsaChunkDecrypt } from "../_shared/tbiCrypto.ts"
import { loadTbiCallbackPrivateKey, mapTbiStatus, loanStatusMessage } from "../_shared/tbiClient.ts"

// ─── Types ──────────────────────────────────────────────────────────────────
// PDF examples show status_id quoted as a string ("0", "1", "2"); accept both.

interface TbiCallbackData {
  order_id: string
  status_id: number | string
  motiv?: string
}

interface LoanApp {
  id: string
  profile_id: string
  bike_benefit_id: string
}

interface Profile {
  first_name: string
  last_name: string
  company_id: string
}

// ─── Handler ────────────────────────────────────────────────────────────────
// Called by TBI Bank — no JWT auth. Security via RSA encryption (only we can decrypt).

Deno.serve(async (req) => {
  try {
    const db = makeRestClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!)

    // 1. Parse form-encoded body
    const formData = await req.formData()
    const orderData = formData.get("order_data") as string
    if (!orderData) {
      console.error("[tbi-webhook] missing order_data in form body")
      return new Response("Bad Request", { status: 400 })
    }

    // 2. Decrypt with our merchant pair private key
    const privateKey = await loadTbiCallbackPrivateKey(db)
    const decrypted = await rsaChunkDecrypt(orderData, privateKey)
    const data: TbiCallbackData = JSON.parse(decrypted)
    console.log("[tbi-webhook] received callback for order:", data.order_id, "status:", data.status_id)

    // 3. Map status
    const status = mapTbiStatus(data.status_id, data.motiv)

    // 4. Find and update loan application
    const loan = await db.getOne<LoanApp>(
      "tbi_loan_applications",
      `order_id=eq.${encodeURIComponent(data.order_id)}`,
      "id,profile_id,bike_benefit_id"
    )
    if (!loan) {
      console.error("[tbi-webhook] unknown order_id:", data.order_id)
      return new Response("Not Found", { status: 404 })
    }

    await db.patch("tbi_loan_applications", `order_id=eq.${encodeURIComponent(data.order_id)}`, {
      status,
      rejection_reason: data.motiv || null,
      tbi_response: data,
    })

    // 5. Notify employee (fire-and-forget)
    sendFcm(db, loan.profile_id, {
      title: status === "approved" ? "Loan Approved!" : "Loan Update",
      body: loanStatusMessage(status, data.motiv),
      event: NotificationEvent.LOAN_STATUS_UPDATE,
      bikeBenefitId: loan.bike_benefit_id,
    }).catch((err) => console.error("[tbi-webhook] fcm error:", err))

    // 6. Notify HR dashboard (fire-and-forget)
    const profile = await db.getOne<Profile>(
      "profiles",
      `user_id=eq.${encodeURIComponent(loan.profile_id)}`,
      "first_name,last_name,company_id"
    )
    if (profile) {
      sendNotification(db, profile.company_id, "loan_update", status, {
        user_id: loan.profile_id,
        employee_name: `${profile.first_name} ${profile.last_name}`.trim(),
        order_id: data.order_id,
      }).catch((err) => console.error("[tbi-webhook] notification error:", err))
    }

    return new Response("OK", { status: 200 })
  } catch (e) {
    console.error("[tbi-webhook] error:", e)
    return new Response("Internal Server Error", { status: 500 })
  }
})
