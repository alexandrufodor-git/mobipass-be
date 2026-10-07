// supabase/functions/issue-report-prune/index.ts
//
// Deletes problem reports older than keep_days with their zips, then sweeps whole day folders
// older than the cutoff for zips whose row never landed. Storage rejects SQL deletes, so
// public.request_issue_reports_prune() (prune_maintenance cron, cron-audit.sh) calls this via pg_net.
// verify_jwt=false: gated by the same Vault webhook secret as bike-sync.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { listIssueReportEntries, removeIssueReportFiles } from "../_shared/issueReportStorage.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
const VAULT_WEBHOOK_SECRET = "bike_sync_webhook_secret"
// 100 UUIDs keep the id=in.(…) delete URL well under gateway limits.
const BATCH = 100

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
    return json({ deleted, orphans: await sweepOrphans(cutoff.slice(0, 10)) })
  } catch (err) {
    console.error("[issue-report-prune] failed:", err)
    return json({ error: "internal_error" }, 500)
  }
})

// A zip whose insert and cleanup both failed has no row, so only its day folder finds it.
// One page per folder per run: orphans are rare, and the next daily run takes any rest.
async function sweepOrphans(cutoffDay: string): Promise<number> {
  let removed = 0
  for (const platform of ["android", "ios"]) {
    const days = await listIssueReportEntries(SUPABASE_URL, SERVICE_KEY, `${platform}/`)
    for (const day of days.filter((e) => e.id === null && e.name < cutoffDay)) {
      const files = await listIssueReportEntries(SUPABASE_URL, SERVICE_KEY, `${platform}/${day.name}/`)
      const paths = files.filter((f) => f.id !== null).map((f) => `${platform}/${day.name}/${f.name}`)
      if (paths.length === 0) continue
      await removeIssueReportFiles(SUPABASE_URL, SERVICE_KEY, paths)
      removed += paths.length
    }
  }
  return removed
}
