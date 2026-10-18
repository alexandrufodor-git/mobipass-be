// bike-sync — BellaBike sync worker (lease-based page queue).
//
// Driven by pg_cron → bike_sync_tick → bike_sync_invoke (pg_net), gated by the
// Vault webhook secret. Each invocation claims ONE small unit (lease + FOR
// UPDATE SKIP LOCKED), processes it, then self-fires the next for throughput.
// Liveness does NOT depend on this isolate surviving: the tick re-fires workers
// every minute and re-claims any unit whose lease expired (crash recovery), and
// merge_bike_offers is idempotent so re-processing a page is safe. See the
// page-queue redesign migrations 20260606000001–3.
//
//   body: { run_id: uuid, branch: 'sync' | 'audit' }
//
//   SYNC  prepare unit    → cache option maps + category parents, count, fan out
//                           one rest_page unit per page.
//         rest_page unit  → fetch ONE page, decode (parallel salable), merge.
//   AUDIT (removed 2026-06-08) — membership/in_catalog/delist were dropped; the
//         audit branch is now a no-op (catalog = the REST sweep). Migr 20260608000004.
// When a branch drains: sync → seed + start audit; audit → finalize the run.

console.info("bike-sync starting")

import { makeRestClient, type RestClient } from "../_shared/supabaseRest.ts"
import {
  Magento,
  VAULT_BELLA_CF_ID,
  VAULT_BELLA_CF_SECRET,
  type MagentoProduct,
  type OptionMaps,
  fetchOptionMaps,
  fetchCategoryCount,
  fetchCategoryPage,
  fetchParents,
  buildModels,
  serializeOptionMaps,
  deserializeOptionMaps,
} from "../_shared/bikeIngest.ts"

const VAULT_WEBHOOK_SECRET = "bike_sync_webhook_secret"
const VAULT_BELLA_TOKEN    = "vendor_bela_access"

const PAGE_SIZE     = 50    // SKUs per rest_page unit — sized to finish in budget
const SALABLE_POOL  = 8     // concurrent is-product-salable calls per page
const LEASE_SECONDS = 90    // a claimed unit is re-claimable after this if unfinished

interface RunRow {
  id: string
  dealer_id: string
  mode: "daily" | "weekly" | "manual"
  watermark_from: string | null
  started_at: string
}
interface UnitRow {
  id: string
  kind: "prepare" | "rest_page" | "gql_membership" | "verify" | "rest_category"
  category_id: string | null
  page: number | null
  page_size: number | null
}
interface MergeResult {
  n_models_upserted: number
  n_inserted: number
  n_updated: number
  n_offers: number
}
interface CacheRow { payload: unknown }

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

function jsonResp(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return jsonResp({ error: "method_not_allowed" }, 405)

  const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)

  // ── Gate: Vault webhook secret (this fn runs verify_jwt=false) ────────────
  const secret = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_WEBHOOK_SECRET })
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return jsonResp({ error: "forbidden" }, 401)
  }

  let body: { run_id?: string; branch?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResp({ error: "invalid_body" }, 400)
  }
  const runId = body.run_id
  const branch = body.branch
  if (!runId || (branch !== "sync" && branch !== "audit")) {
    return jsonResp({ error: "missing_run_id_or_branch" }, 400)
  }

  const run = await db.getOne<RunRow>("sync_runs", `id=eq.${runId}`, "id,dealer_id,mode,watermark_from,started_at")
  if (!run) return jsonResp({ error: "run_not_found" }, 404)

  // ── Claim one unit (lease) ────────────────────────────────────────────────
  const unit = await db.rpc<UnitRow | null>("claim_next_sync_unit", {
    p_run_id: runId, p_branch: branch, p_lease_seconds: LEASE_SECONDS,
  })
  if (!unit || !unit.id) {
    return await advance(db, run, branch)
  }

  try {
    if (branch === "sync") await processSyncUnit(db, run, unit)
    else                   await processAuditUnit(db, run, unit)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error(`[bike-sync] unit ${unit.id} (${unit.kind}) failed: ${msg}`)
    await db.rpc("complete_sync_unit", { p_unit_id: unit.id, p_status: "failed", p_error: msg.slice(0, 500) })
  }

  // Keep this lane alive (the tick tops up to MAX_LANES; this is throughput).
  await db.rpc("bike_sync_invoke", { p_run_id: runId, p_branch: branch })
  return jsonResp({ ok: true, claimed: unit.id, kind: unit.kind })
})

// ── Branch transitions when no unit is claimable ──────────────────────────────
async function advance(db: RestClient, run: RunRow, branch: string): Promise<Response> {
  const pending = await countPending(db, run.id, branch)
  if (pending > 0) {
    // Units waiting on retry backoff — let the tick re-fire them.
    return jsonResp({ ok: true, waiting: pending, branch })
  }

  if (branch === "sync") {
    await db.rpc("seed_audit_units", { p_run_id: run.id })   // idempotent
    await db.rpc("bike_sync_invoke", { p_run_id: run.id, p_branch: "audit" })
    return jsonResp({ ok: true, transition: "sync_drained_started_audit" })
  }

  const finalized = await db.rpc<{ status?: string }>("finalize_sync_run", { p_run_id: run.id })
  return jsonResp({ ok: true, finalized: finalized?.status ?? "unknown" })
}

async function countPending(db: RestClient, runId: string, branch: string): Promise<number> {
  void db
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/sync_units?run_id=eq.${runId}&branch=eq.${branch}` +
      `&status=in.(enqueued,running)&select=id`,
    { headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY, Prefer: "count=exact" } },
  )
  const range = res.headers.get("content-range") // e.g. "0-4/5" or "*/0"
  const total = range?.split("/")[1]
  return total ? parseInt(total, 10) : 0
}

// ── SYNC dispatch ─────────────────────────────────────────────────────────────
async function processSyncUnit(db: RestClient, run: RunRow, unit: UnitRow): Promise<void> {
  if (unit.kind === "prepare")   return await processPrepareUnit(db, run, unit)
  if (unit.kind === "rest_page") return await processPageUnit(db, run, unit)
  throw new Error(`unexpected sync unit kind ${unit.kind}`)
}

// PREPARE: cache the run-stable bits (option maps + category parents), count the
// category, fan out one rest_page unit per page. Cheap + bounded.
async function processPrepareUnit(db: RestClient, run: RunRow, unit: UnitRow): Promise<void> {
  const catId = unit.category_id
  if (!catId) throw new Error("prepare unit has no category_id")
  const mag = await makeMagento(db, true)

  // Option maps: fetched once per run, cached for all pages.
  const cachedOpts = await getCache(db, run.id, "option_maps")
  if (!cachedOpts) {
    const opts = await fetchOptionMaps(mag)
    await putCache(db, run.id, "option_maps", serializeOptionMaps(opts))
  }

  // Parents for this category (children on any page group under these).
  const parents = await fetchParents(mag, catId)
  await putCache(db, run.id, `parents:${catId}`, parents)

  const delta = run.watermark_from           // null on weekly/first run → full
  const total = await fetchCategoryCount(mag, catId, delta)
  const pages = await db.rpc<number>("enqueue_page_units", {
    p_run_id: run.id, p_category_id: catId, p_total: total, p_page_size: PAGE_SIZE,
  })

  await db.rpc("complete_sync_unit", { p_unit_id: unit.id, p_status: "succeeded", p_n_fetched: total })
  console.info(`[bike-sync] prepare cat ${catId}: total=${total} pages=${pages}`)
}

// PAGE: fetch ONE page, decode it (parallel salable), merge. Idempotent.
async function processPageUnit(db: RestClient, run: RunRow, unit: UnitRow): Promise<void> {
  const catId = unit.category_id
  const page = unit.page
  const pageSize = unit.page_size ?? PAGE_SIZE
  if (!catId || !page) throw new Error("rest_page unit missing category_id/page")
  const mag = await makeMagento(db, true)

  const optsRaw = await getCache(db, run.id, "option_maps")
  const opts: OptionMaps = optsRaw
    ? deserializeOptionMaps(optsRaw as Record<string, Record<string, string>>)
    : await fetchOptionMaps(mag)

  const parentsRaw = await getCache(db, run.id, `parents:${catId}`)
  const parents = (parentsRaw as MagentoProduct[] | null) ?? await fetchParents(mag, catId)

  const delta = run.watermark_from
  const products = await fetchCategoryPage(mag, catId, page, pageSize, delta)
  const { models, nFetched, nFailed } = await buildModels(mag, products, catId, opts, parents, SALABLE_POOL)

  const merged = await db.rpc<MergeResult>("merge_bike_offers", {
    p_dealer_id: run.dealer_id,
    p_models: models,
  })

  await db.rpc("complete_sync_unit", {
    p_unit_id:    unit.id,
    p_status:     "succeeded",
    p_n_fetched:  nFetched,
    p_n_inserted: merged?.n_inserted ?? 0,
    p_n_updated:  merged?.n_updated ?? 0,
    p_n_models:   merged?.n_models_upserted ?? 0,
    p_n_failed:   nFailed,
  })
  console.info(
    `[bike-sync] cat ${catId} p${page}: fetched=${nFetched} models=${merged?.n_models_upserted ?? 0} ` +
    `ins=${merged?.n_inserted ?? 0} upd=${merged?.n_updated ?? 0} failed=${nFailed}`,
  )
}

// ── AUDIT branch — NO-OP (membership/in_catalog/delist removed 2026-06-08) ───
// A storefront audit proved the GraphQL membership signal under-reports live
// configurable parents (19/20 "absent" parents were live + buyable), so it can't
// drive in_catalog or delisting. Catalog = the REST sweep; stock = per-offer
// is-salable. Audit units are still seeded but do nothing — the branch drains
// immediately and the run finalizes. See migration 20260608000004 + the plan.
async function processAuditUnit(db: RestClient, _run: RunRow, unit: UnitRow): Promise<void> {
  await db.rpc("complete_sync_unit", { p_unit_id: unit.id, p_status: "skipped" })
}

// ── helpers ───────────────────────────────────────────────────────────────────
async function bellaToken(db: RestClient): Promise<string> {
  const token = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_BELLA_TOKEN })
  if (!token) throw new Error(`vault secret ${VAULT_BELLA_TOKEN} missing`)
  return token
}

// Build a Magento client wired with the Cloudflare Access service token (read
// from Vault — null locally, where the secrets aren't set). `withToken=false`
// is for the public GraphQL membership branch, which still goes through the
// same Cloudflare Access policy and so still needs the CF headers.
async function makeMagento(db: RestClient, withToken: boolean): Promise<Magento> {
  const token     = withToken ? await bellaToken(db) : ""
  const cfId      = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_BELLA_CF_ID })
  const cfSecret  = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_BELLA_CF_SECRET })
  return new Magento(token, cfId, cfSecret)
}

async function getCache(db: RestClient, runId: string, scope: string): Promise<unknown | null> {
  const row = await db.getOne<CacheRow>(
    "sync_run_cache",
    `run_id=eq.${runId}&scope=eq.${encodeURIComponent(scope)}`,
    "payload",
  )
  return row?.payload ?? null
}

async function putCache(db: RestClient, runId: string, scope: string, payload: unknown): Promise<void> {
  await db.upsert("sync_run_cache", { run_id: runId, scope, payload }, "run_id,scope")
}

// (listParentSkus removed with the membership branch — see migration 20260608000004)
