// supabase/functions/live-test-push/index.ts
//
// Sends the copilot "test is today" / "confirm your test" reminders. Called by
// public.live_test_tick() (pg_cron, every 5 min) only when someone is due.
// verify_jwt=false: gated by the same Vault webhook secret as bike-sync.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { claimAndSendLiveTestPush, type LiveTestPushKind } from "../_shared/liveTestPush.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
const VAULT_WEBHOOK_SECRET = "bike_sync_webhook_secret"

interface DuePush {
  benefit_id: string
  user_id: string
  kind: LiveTestPushKind
  live_test_time: string
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)
  const secret = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_WEBHOOK_SECRET })
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return json({ error: "forbidden" }, 401)
  }

  const due = await db.rpc<DuePush[] | null>("live_test_due_pushes", {}) ?? []
  let sent = 0
  for (const push of due) {
    try {
      if (await claimAndSendLiveTestPush(
        SUPABASE_URL, SERVICE_KEY, db, push.user_id, push.kind, push.live_test_time, push.benefit_id,
      )) sent++
    } catch (err) {
      console.error(`[live-test-push] ${push.kind} for ${push.benefit_id} failed:`, err)
    }
  }
  return json({ due: due.length, sent })
})
