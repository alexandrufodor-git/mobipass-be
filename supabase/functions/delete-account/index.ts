// supabase/functions/delete-account/index.ts
//
// Self-service account deletion (App Store 5.1.1(v) / Play Data-safety).
//
// Auth: JWT required (verify_jwt = true). A caller can only ever delete THEIR
// OWN account — the target user id is taken from the JWT sub, never the body.
//
// What it does:
//   1. Best-effort delete of the caller's avatar object (avatars/{user_id}).
//      The DB cascade does NOT reach Storage, so we clean it up here.
//   2. Delete the auth.users row via the service_role Admin API. Every user
//      table hangs off profiles.user_id / auth.users(id) with ON DELETE CASCADE
//      (profiles, bike_benefits → orders/contracts/loans, employee_pii,
//      labor_contracts, user_roles, sso_pending_claims), so this single delete
//      erases the account and all personal data, and drops all sessions.
//
// profile_invites is intentionally NOT touched: it is the employer-owned roster
// SSOT (user_id → SET NULL on delete). Re-registration re-claims the same invite.
//
// Response: { success: true }. Never echoes PII.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  if (req.method === "OPTIONS") return corsResponse(origin)
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, origin)

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

    const jwt = requireJwt(req, origin)
    const userId = extractUserId(jwt, origin)

    const adminHeaders = {
      Authorization: `Bearer ${serviceKey}`,
      apikey: serviceKey,
      "Content-Type": "application/json",
    }

    // 1. Best-effort avatar cleanup — a missing object (404) is fine.
    const avatarRes = await fetch(
      `${supabaseUrl}/storage/v1/object/avatars/${userId}`,
      { method: "DELETE", headers: adminHeaders },
    )
    if (!avatarRes.ok && avatarRes.status !== 404) {
      console.warn("[delete-account] avatar cleanup non-fatal:", avatarRes.status)
    }

    // 2. Delete the auth user → triggers the ON DELETE CASCADE chain.
    const delRes = await fetch(
      `${supabaseUrl}/auth/v1/admin/users/${userId}`,
      { method: "DELETE", headers: adminHeaders },
    )
    if (!delRes.ok) {
      const text = await delRes.text().catch(() => "")
      console.error("[delete-account] auth delete failed:", delRes.status, text)
      return json({ error: "delete_failed" }, 500, origin)
    }

    console.log("[delete-account] deleted user", userId)
    return json({ success: true }, 200, origin)
  } catch (e) {
    if (e instanceof Response) return e
    console.error("[delete-account] unexpected error:", e)
    throw e
  }
})
