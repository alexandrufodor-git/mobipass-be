// bike-image-normalize — bike photo normalisation worker (lease-based queue, 1:1 with bike-sync).
//
// Driven by bike_images_kickoff (pg_cron bike-images-nightly, after the bike sync) and
// bike_images_tick (every minute), via bike_images_invoke (pg_net), gated by the Vault webhook
// secret. Each call claims ONE photo (lease + FOR UPDATE SKIP LOCKED), so it stays far inside the
// 2 s CPU limit per request, then fires the next. A call killed mid-photo leaves its lease to
// expire and the tick re-fires the lane; a photo failing 3 times is marked failed and is due again
// next night. Photos the app would crop get a copy with even white margins in the public
// bike-images bucket; every other photo keeps its source URL.
//
//   body: { run_id: uuid }                         — worker: one unit of that run
//         { bike_ids: string[], dry_run: true }    — those bikes' photos into dry-run/, no DB writes

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { makeRestClient, type RestClient } from "../_shared/supabaseRest.ts"
import { normalizeBikeImage } from "../_shared/bikeImageNormalize.ts"
import { bellaHeaders, VAULT_BELLA_CF_ID, VAULT_BELLA_CF_SECRET } from "../_shared/bikeIngest.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
const VAULT_WEBHOOK_SECRET = "bike_sync_webhook_secret"
const BUCKET = "bike-images"
const LEASE_SECONDS = 90 // a claimed unit is re-claimable after this if unfinished
const SOURCE_GAP_MS = 2_000 // polite pacing towards bellabike.ro before firing the next unit

// The source refused us (Cloudflare 403/429): requeue the photo and end the lane.
class Throttled extends Error {}
const refused = (res: Response) => res.status === 403 || res.status === 429

interface Unit {
  id: string
  run_id: string
  source_url: string
}

interface Known {
  status: string
  rule_version: number
  source_etag: string | null
  source_bytes: number | null
}

interface Processed {
  outcome: "normalized" | "kept" | "unchanged"
  url?: string
  etag: string | null
  bytes: number | null
  downloaded: number
  stored: number
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

async function process(
  sourceUrl: string,
  known: Known | null,
  ruleVersion: number,
  sourceHeaders: Record<string, string>,
  dryRun: boolean,
): Promise<Processed> {
  // A recheck under the same rule: skip the download when the source is unchanged.
  if (known && known.status !== "failed" && known.rule_version === ruleVersion) {
    const headRes = await fetch(sourceUrl, { method: "HEAD", headers: sourceHeaders })
    if (refused(headRes)) throw new Throttled(`source ${headRes.status}`)
    const head = fingerprint(headRes)
    // A source that rejects HEAD (405/501) falls through to the full download.
    if (headRes.ok && head.etag === known.source_etag && head.bytes === known.source_bytes) {
      return { outcome: "unchanged", ...head, downloaded: 0, stored: 0 }
    }
  }
  const res = await fetch(sourceUrl, { headers: sourceHeaders })
  if (refused(res)) throw new Throttled(`source ${res.status}`)
  if (!res.ok) throw new Error(`source ${res.status}`)
  const { etag } = fingerprint(res)
  const bytes = new Uint8Array(await res.arrayBuffer())
  const downloaded = bytes.length
  const jpeg = await normalizeBikeImage(bytes)
  if (!jpeg) return { outcome: "kept", etag, bytes: downloaded, downloaded, stored: 0 }
  const path = `${dryRun ? "dry-run/" : ""}${(await sha256Hex(jpeg)).slice(0, 32)}.jpg`
  return { outcome: "normalized", url: await upload(path, jpeg), etag, bytes: downloaded, downloaded, stored: jpeg.length }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)
  const secret = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_WEBHOOK_SECRET })
  if (!secret || req.headers.get("x-webhook-secret") !== secret) return json({ error: "forbidden" }, 401)

  const body: { run_id?: string; bike_ids?: string[]; dry_run?: boolean } = await req.json().catch(() => ({}))
  const sourceHeaders = bellaHeaders(
    await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_BELLA_CF_ID }),
    await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_BELLA_CF_SECRET }),
  )
  const ruleVersion = await db.rpc<number>("bike_images_rule_version", {})

  if (body.dry_run) {
    if (!body.bike_ids?.length) return json({ error: "dry_run_needs_bike_ids" }, 400)
    return json(await dryRun(body.bike_ids, ruleVersion, sourceHeaders))
  }
  if (!body.run_id) return json({ error: "missing_run_id" }, 400)
  const runId = body.run_id

  // ── Claim one unit (lease) ────────────────────────────────────────────────
  const unit = await db.rpc<Unit | null>("claim_next_bike_image_unit", {
    p_run_id: runId,
    p_lease_seconds: LEASE_SECONDS,
  })
  if (!unit || !unit.id) {
    // Nothing claimable: units waiting on retry backoff are left to the tick.
    const finalized = await db.rpc<{ status?: string }>("finalize_bike_image_run", { p_run_id: runId })
    return json({ ok: true, finalized: finalized?.status ?? "unknown" })
  }

  try {
    const known = await db.getOne<Known>(
      "bike_images",
      `source_url=eq.${encodeURIComponent(unit.source_url)}`,
      "status,rule_version,source_etag,source_bytes",
    )
    const o = await process(unit.source_url, known, ruleVersion, sourceHeaders, false)
    const checkedAt = new Date().toISOString()
    if (o.outcome === "unchanged") {
      await db.patch("bike_images", `source_url=eq.${encodeURIComponent(unit.source_url)}`, { checked_at: checkedAt })
    } else {
      const res = await db.upsert("bike_images", {
        source_url: unit.source_url,
        status: o.outcome,
        url: o.url ?? null,
        source_etag: o.etag,
        source_bytes: o.bytes,
        rule_version: ruleVersion,
        checked_at: checkedAt,
      }, "source_url")
      if (!res.ok) throw new Error(`bike_images write ${res.status}: ${await res.text().catch(() => "")}`)
      await db.rpc("refresh_bike_display_images", { p_sources: [unit.source_url] })
    }
    await db.rpc("complete_bike_image_unit", {
      p_unit_id: unit.id,
      p_status: "succeeded",
      p_outcome: o.outcome,
      p_bytes_downloaded: o.downloaded,
      p_bytes_stored: o.stored,
    })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (err instanceof Throttled) {
      console.warn(`[bike-image-normalize] source throttled, ending lane: ${msg}`)
      await db.rpc("complete_bike_image_unit", { p_unit_id: unit.id, p_status: "throttled", p_error: msg })
      return json({ ok: true, throttled: unit.id })
    }
    console.error(`[bike-image-normalize] unit ${unit.id} failed: ${msg}`)
    const result = await db.rpc<string>("complete_bike_image_unit", {
      p_unit_id: unit.id,
      p_status: "failed",
      p_error: msg.slice(0, 500),
    })
    // Out of tries: the app keeps the source (or an earlier copy); due again next night.
    if (result === "failed") await markFailed(db, unit.source_url, ruleVersion)
  }

  // Keep the lane alive (the tick re-fires it if this call dies); pace towards the source.
  await new Promise((r) => setTimeout(r, SOURCE_GAP_MS))
  await db.rpc("bike_images_invoke", { p_body: { run_id: runId } })
  return json({ ok: true, claimed: unit.id })
})

// A previously normalized photo keeps its copy; anything else is recorded as failed.
async function markFailed(db: RestClient, sourceUrl: string, ruleVersion: number): Promise<void> {
  const filter = `source_url=eq.${encodeURIComponent(sourceUrl)}`
  const known = await db.getOne<{ status: string }>("bike_images", filter, "status")
  if (known?.status === "normalized") {
    await db.patch("bike_images", filter, { checked_at: new Date().toISOString() })
    return
  }
  await db.upsert("bike_images", {
    source_url: sourceUrl,
    status: "failed",
    url: null,
    rule_version: ruleVersion,
    checked_at: new Date().toISOString(),
  }, "source_url")
}

async function dryRun(bikeIds: string[], ruleVersion: number, sourceHeaders: Record<string, string>) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/bikes?id=in.(${bikeIds.join(",")})&select=model:bike_models(images)`,
    { headers: authHeaders },
  )
  const rows: { model: { images: string[] | null } | null }[] = await res.json()
  const urls = [...new Set(rows.flatMap((r) => r.model?.images ?? []))]
  const photos = []
  for (const [i, url] of urls.entries()) {
    if (i > 0) await new Promise((r) => setTimeout(r, SOURCE_GAP_MS))
    try {
      const o = await process(url, null, ruleVersion, sourceHeaders, true)
      photos.push({ source_url: url, outcome: o.outcome, url: o.url })
    } catch (err) {
      photos.push({ source_url: url, error: (err as Error).message })
    }
  }
  return { dry_run: true, photos }
}
