// supabase/functions/issue-report-prune/index.ts
//
// Deletes problem reports older than keep_days with their zips. Storage rejects SQL deletes, so
// public.request_issue_reports_prune() (prune_maintenance cron, cron-audit.sh) calls this via pg_net.
// verify_jwt=false: gated by the same Vault webhook secret as bike-sync.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { removeIssueReportFiles } from "../_shared/issueReportStorage.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
const VAULT_WEBHOOK_SECRET = "bike_sync_webhook_secret"
const BATCH = 500

const auth = { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY }

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)
  const secret = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_WEBHOOK_SECRET })
  if (!secret || req.headers.get("x-webhook-secret") !== secret) return json({ error: "forbidden" }, 401)

  const body = await req.json().catch(() => null)
  const keepDays = body?.keep_days
  if (!Number.isInteger(keepDays) || keepDays < 0) return json({ error: "invalid_body" }, 400)

  try {
    const cutoff = new Date(Date.now() - keepDays * 86400_000).toISOString()
    let deleted = 0
    while (true) {
      const res = await fetch(
        `${SUPABASE_URL}/rest/v1/issue_reports?select=id,storage_path&created_at=lt.${cutoff}&order=created_at&limit=${BATCH}`,
        { headers: auth },
      )
      if (!res.ok) throw new Error(`select rows: ${res.status} ${await res.text()}`)
      const rows: { id: string; storage_path: string }[] = await res.json()
      if (rows.length === 0) break

      // Files first: a row without its file is harmless, a file without its row is never found again.
      await removeIssueReportFiles(SUPABASE_URL, SERVICE_KEY, rows.map((r) => r.storage_path))
      const del = await fetch(`${SUPABASE_URL}/rest/v1/issue_reports?id=in.(${rows.map((r) => r.id).join(",")})`, {
        method: "DELETE",
        headers: auth,
      })
      if (!del.ok) throw new Error(`delete rows: ${del.status} ${await del.text()}`)
      deleted += rows.length
      if (rows.length < BATCH) break
    }
    return json({ deleted })
  } catch (err) {
    console.error("[issue-report-prune] failed:", err)
    return json({ error: "internal_error" }, 500)
  }
})
