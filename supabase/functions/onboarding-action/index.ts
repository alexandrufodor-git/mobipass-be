// supabase/functions/onboarding-action/index.ts
//
// Single write path for the employee's onboarding steps on bike_benefits.
// POST { action, bike_id? } → the updated benefit row (same select the app used).

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, badRequest, forbidden, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { claimAndSendLiveTestPush } from "../_shared/liveTestPush.ts"
import { ACTIONS_NEEDING_BIKE, ActionBenefit, decide, isAction } from "./actions.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

const BENEFIT_SELECT = "*,bike:bikes(id,name,images,image_url),copilot"
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

async function writeBenefit(
  method: "POST" | "PATCH",
  filter: string,
  body: Record<string, unknown>,
  origin?: string,
): Promise<Response> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/bike_benefits?${filter}${filter ? "&" : ""}select=${encodeURIComponent(BENEFIT_SELECT)}`,
    {
      method,
      headers: {
        Authorization: `Bearer ${SERVICE_KEY}`,
        apikey: SERVICE_KEY,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify(body),
    },
  )
  if (!res.ok) {
    const details = await res.json().catch(() => ({}))
    return json({ ...Errors.BENEFIT_WRITE_FAILED, details }, res.status, origin)
  }
  const rows: unknown[] = await res.json()
  if (!rows.length) return badRequest(Errors.NO_BIKE_BENEFIT, undefined, origin)
  return json(rows[0], 200, origin)
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  if (req.method === "OPTIONS") return corsResponse(origin)

  try {
    const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)
    const userId = extractUserId(requireJwt(req, origin), origin)

    const role = await db.getOne<{ role: string }>("user_roles", `user_id=eq.${userId}&role=eq.employee`, "role")
    if (!role) throw forbidden(undefined, origin)

    const body = await req.json().catch(() => null)
    const action = body?.action
    if (!isAction(action)) throw badRequest(Errors.UNKNOWN_ACTION, undefined, origin)

    const bikeId = body?.bike_id
    if (ACTIONS_NEEDING_BIKE.includes(action) && !(typeof bikeId === "string" && UUID_REGEX.test(bikeId))) {
      throw badRequest(Errors.BIKE_ID_REQUIRED, undefined, origin)
    }

    const benefit = await db.getOne<ActionBenefit & { id: string }>(
      "bike_benefits", `user_id=eq.${userId}`, "id,step,live_test_sent_at,copilot"
    )

    if (action === "start" && !benefit) {
      return await writeBenefit("POST", "", { user_id: userId, step: "choose_bike" }, origin)
    }
    if (!benefit) throw badRequest(Errors.NO_BIKE_BENEFIT, undefined, origin)

    const decision = decide(action, benefit, { bike_id: bikeId }, new Date().toISOString())
    if ("error" in decision) {
      throw json(decision.error === "copilot_locked" ? Errors.COPILOT_LOCKED : Errors.TEST_NOT_CONFIRMABLE, 409, origin)
    }

    const res = await writeBenefit("PATCH", `id=eq.${benefit.id}&user_id=eq.${userId}`, decision.patch, origin)

    // Copilot: the test date is already set, so the interest tap books it.
    const label = benefit.copilot?.live_test_label
    if (res.ok && action === "test_interest" && benefit.copilot?.enabled && label) {
      claimAndSendLiveTestPush(SUPABASE_URL, SERVICE_KEY, db, userId, "booked", label, benefit.id)
        .catch((err) => console.error("[onboarding-action] booked push error:", err))
    }
    return res
  } catch (e) {
    if (e instanceof Response) return e
    throw e
  }
})
