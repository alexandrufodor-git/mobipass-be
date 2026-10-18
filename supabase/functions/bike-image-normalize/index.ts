// supabase/functions/bike-image-normalize/index.ts
//
// Normalises bike photos the app would crop (tightly framed studio shots): a copy with even white
// margins goes to the public bike-images bucket and bikes.images shows it; every other photo keeps
// its source URL. Called by bike_images_invoke() (pg_cron, and manual runs), gated by the same
// Vault webhook secret as bike-sync. verify_jwt=false.
//
//   body: { limit?: number }                          — next due source photos (default 10)
//         { bike_ids: string[], dry_run: true }        — those bikes' photos into dry-run/, no DB writes

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { normalizeBikeImage, RULE_VERSION } from "../_shared/bikeImageNormalize.ts"
import { bellaHeaders, VAULT_BELLA_CF_ID, VAULT_BELLA_CF_SECRET } from "../_shared/bikeIngest.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
const VAULT_WEBHOOK_SECRET = "bike_sync_webhook_secret"
const BUCKET = "bike-images"
const RETRY_HOURS = [1, 6, 24, 72] // then every 72h
const SOURCE_GAP_MS = 2_000 // polite pacing towards bellabike.ro

// The source refused us (403/429): stop the run and leave the rest for the next one.
class Throttled extends Error {}

interface Due {
  source_url: string
  status: string | null
  rule_version: number | null
  source_etag: string | null
  source_bytes: number | null
}

interface Outcome {
  source_url: string
  status: "normalized" | "kept" | "failed" | "unchanged"
  url?: string
  error?: string
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })

const authHeaders = { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY }

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)))
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("")
}

// Named by content, so a changed source gets a new URL and phones don't show a cached copy.
async function upload(path: string, jpeg: Uint8Array): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${path}`, {
    method: "POST",
    headers: { ...authHeaders, "Content-Type": "image/jpeg", "x-upsert": "true" },
    body: jpeg,
  })
  if (!res.ok) throw new Error(`upload ${res.status}: ${await res.text().catch(() => "")}`)
  return `${SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${path}`
}

const fingerprint = (res: Response) => ({
  etag: res.headers.get("etag"),
  bytes: Number(res.headers.get("content-length")) || null,
})

async function process(due: Due, dryRun: boolean, sourceHeaders: Record<string, string>): Promise<Outcome & { etag: string | null; bytes: number | null }> {
  // A periodic recheck under the same rule: skip the download when the source is unchanged.
  if (!dryRun && due.status && due.status !== "failed" && due.rule_version === RULE_VERSION) {
    const headRes = await fetch(due.source_url, { method: "HEAD", headers: sourceHeaders })
    if (headRes.status === 403 || headRes.status === 429) throw new Throttled(`source ${headRes.status}`)
    const head = fingerprint(headRes)
    if (head.etag === due.source_etag && head.bytes === due.source_bytes) {
      return { source_url: due.source_url, status: "unchanged", ...head }
    }
  }
  const res = await fetch(due.source_url, { headers: sourceHeaders })
  if (res.status === 403 || res.status === 429) throw new Throttled(`source ${res.status}`)
  if (!res.ok) throw new Error(`source ${res.status}`)
  const { etag } = fingerprint(res)
  const bytes = new Uint8Array(await res.arrayBuffer())
  const jpeg = await normalizeBikeImage(bytes)
  if (!jpeg) return { source_url: due.source_url, status: "kept", etag, bytes: bytes.length }
  const path = `${dryRun ? "dry-run/" : ""}${(await sha256Hex(jpeg)).slice(0, 32)}.jpg`
  return { source_url: due.source_url, status: "normalized", url: await upload(path, jpeg), etag, bytes: bytes.length }
}

async function bikeSources(bikeIds: string[]): Promise<Due[]> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/bikes?id=in.(${bikeIds.join(",")})&select=model:bike_models(images)`,
    { headers: authHeaders },
  )
  const rows: { model: { images: string[] | null } | null }[] = await res.json()
  const urls = [...new Set(rows.flatMap((r) => r.model?.images ?? []))]
  return urls.map((source_url) => ({ source_url, status: null, rule_version: null, source_etag: null, source_bytes: null }))
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)
  const secret = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_WEBHOOK_SECRET })
  if (!secret || req.headers.get("x-webhook-secret") !== secret) return json({ error: "forbidden" }, 401)
  const sourceHeaders = bellaHeaders(
    await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_BELLA_CF_ID }),
    await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_BELLA_CF_SECRET }),
  )

  const body: { limit?: number; bike_ids?: string[]; dry_run?: boolean } = await req.json().catch(() => ({}))
  const dryRun = body.dry_run === true
  if (dryRun && !body.bike_ids?.length) return json({ error: "dry_run_needs_bike_ids" }, 400)

  const due = body.bike_ids?.length
    ? await bikeSources(body.bike_ids)
    : await db.rpc<Due[] | null>("bike_images_due", { p_limit: body.limit ?? 10, p_rule_version: RULE_VERSION }) ?? []

  const outcomes: Outcome[] = []
  for (const [i, d] of due.entries()) {
    if (i > 0) await new Promise((r) => setTimeout(r, SOURCE_GAP_MS))
    try {
      const o = await process(d, dryRun, sourceHeaders)
      outcomes.push({ source_url: o.source_url, status: o.status, url: o.url })
      if (dryRun) continue
      const checkedAt = new Date().toISOString()
      if (o.status === "unchanged") {
        await db.patch("bike_images", `source_url=eq.${encodeURIComponent(d.source_url)}`, { checked_at: checkedAt })
      } else {
        await db.upsert("bike_images", {
          source_url: d.source_url, status: o.status, url: o.url ?? null, source_etag: o.etag,
          source_bytes: o.bytes, rule_version: RULE_VERSION, checked_at: checkedAt, attempts: 0, next_retry_at: null,
        }, "source_url")
      }
    } catch (err) {
      const error = (err as Error).message
      if (err instanceof Throttled) {
        console.warn("[bike-image-normalize] source throttled, stopping:", error)
        outcomes.push({ source_url: d.source_url, status: "failed", error })
        break
      }
      outcomes.push({ source_url: d.source_url, status: "failed", error })
      console.error("[bike-image-normalize] failed:", d.source_url, error)
      if (dryRun) continue
      const attempts = (d.status === "failed" ? await failedAttempts(db, d.source_url) : 0) + 1
      const hours = RETRY_HOURS[Math.min(attempts - 1, RETRY_HOURS.length - 1)]
      // A previously normalized photo keeps its copy until a retry succeeds.
      if (d.status === "normalized") {
        await db.patch("bike_images", `source_url=eq.${encodeURIComponent(d.source_url)}`, {
          checked_at: new Date().toISOString(),
        })
      } else {
        await db.upsert("bike_images", {
          source_url: d.source_url, status: "failed", url: null, rule_version: RULE_VERSION,
          checked_at: new Date().toISOString(), attempts,
          next_retry_at: new Date(Date.now() + hours * 3_600_000).toISOString(),
        }, "source_url")
      }
    }
  }

  const changed = outcomes.filter((o) => o.status === "normalized" || o.status === "kept").map((o) => o.source_url)
  const bikes = !dryRun && changed.length
    ? await db.rpc<number>("refresh_bike_display_images", { p_sources: changed })
    : 0
  console.log(`[bike-image-normalize] ${dryRun ? "dry run " : ""}${outcomes.length} photos, ${bikes} bikes refreshed`)
  return json({ dry_run: dryRun, photos: outcomes, bikes_refreshed: bikes })
})

async function failedAttempts(db: ReturnType<typeof makeRestClient>, sourceUrl: string): Promise<number> {
  const row = await db.getOne<{ attempts: number }>("bike_images", `source_url=eq.${encodeURIComponent(sourceUrl)}`, "attempts")
  return row?.attempts ?? 0
}
