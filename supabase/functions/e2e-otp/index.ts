// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"

/**
 * e2e-otp — Returns a usable OTP for the E2E test account.
 *
 * Request: POST with X-E2E-Secret header.
 *   Body: { email: "<the e2e_email account>" }
 *
 * Implementation: calls Supabase admin `generate_link` (type: magiclink),
 * which returns a fresh `email_otp` the client can verify with verifyOtp().
 * This invalidates any previous OTP issued for the same email — which is
 * fine for tests that only care about the last-issued code. It is also why the
 * allowlist below is an EXACT match rather than a domain suffix: pointing this
 * at an arbitrary address would silently invalidate that user's pending code.
 *
 * Allowlist: email must equal Vault `e2e_email` (the single test account, same
 * value e2e-seed drives). Any other email → 403. Sourced from Vault rather than
 * hardcoded so local and prod share one definition of "the test account" and
 * rotating it never needs a redeploy.
 *
 * Vault secrets: e2e_secret (matches X-E2E-Secret header), e2e_email.
 */

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

async function getVaultSecret(name: string): Promise<string | null> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_vault_secret`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ secret_name: name }),
  })
  if (!res.ok) return null
  return (await res.json()) as string | null
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  const E2E_SECRET = (await getVaultSecret("e2e_secret")) ?? ""
  if (!E2E_SECRET) return json({ error: "e2e_not_configured" }, 503)
  if (req.headers.get("X-E2E-Secret") !== E2E_SECRET) {
    return json({ error: "forbidden" }, 403)
  }

  let body: { email?: string }
  try { body = await req.json() } catch { return json({ error: "invalid_json" }, 400) }

  // Fail closed: a missing/blank e2e_email must never degrade into "allow any
  // address" — without it there is no allowlist to enforce.
  const ACCOUNT_EMAIL = (await getVaultSecret("e2e_email"))?.trim().toLowerCase() ?? ""
  if (!ACCOUNT_EMAIL) return json({ error: "e2e_email_not_configured" }, 503)

  const email = body.email?.trim().toLowerCase()
  if (!email) return json({ error: "email_required" }, 400)
  if (email !== ACCOUNT_EMAIL) {
    return json({ error: "email_not_allowlisted" }, 403)
  }

  // Generate a fresh OTP via admin API. The response includes email_otp as plaintext.
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ type: "magiclink", email }),
  })

  if (!res.ok) {
    const details = await res.text()
    console.error("[e2e-otp] generate_link failed:", res.status, details)
    return json({ error: "generate_link_failed", status: res.status }, 500)
  }

  // GoTrue's REST response puts email_otp / hashed_token / action_link at the TOP
  // level. The nested `properties` object is something supabase-js builds on the
  // client — reading only that shape is why this function returned
  // otp_not_returned on every real call.
  const data = await res.json() as {
    email_otp?: string
    properties?: { email_otp?: string; hashed_token?: string; action_link?: string }
  }
  const otp = data.email_otp ?? data.properties?.email_otp
  if (!otp) {
    console.error("[e2e-otp] no email_otp in response:", data)
    // Echo the keys (never the values — the payload carries tokens) so a future
    // GoTrue shape change is diagnosable from the Maestro failure alone.
    return json({ error: "otp_not_returned", keys: Object.keys(data ?? {}) }, 500)
  }

  return json({ email, otp })
})
