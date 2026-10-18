// BellaBike (Magento 2.4.7) read-only sync — fetch + decode + payload build.
//
// Mirrors the regesIngest / csvIngest precedent: the edge fn prepares a fully
// shaped jsonb payload in the runtime, then one DB call (merge_bike_offers)
// commits it. Read-only against BellaBike — every call here is a GET.
//
// Grain: one bikes OFFER per buyable SKU (configurable child or standalone
// simple), grouped under a bike_models parent. See the locked design in
// llm-agent-assist/plans/bella-bike-integration.md (§2–§4b).
//
// ⚠️ The field mapping below is built from the documented Magento 2 product
// shape + scripts/dev/bellabike.py. Validate it against the first manual run
// with `bellabike.py audit <run_id>` and adjust the small mapping helpers
// (decodeSpecs / mapModel / mapOffer / bikeType) as needed — they are
// deliberately isolated for that.

const REST_BASE  = "https://bellabike.ro/rest/V1"
const GQL_URL    = "https://bellabike.ro/graphql"
const MEDIA_BASE = "https://bellabike.ro/media/catalog/product"
const WEBSITE_STOCK = "2"          // "Stock Bellabike" — the only sales channel
// BellaBike is behind Cloudflare, which 403s non-browser User-Agents. Match the
// exact browser UA that scripts/dev/bellabike.py uses (proven to pass).
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
           "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
// Sent on every BellaBike request so their Cloudflare can allowlist our sync
// past Bot Fight Mode / Managed Challenge (which a server can't solve).
const SYNC_CLIENT_ID = "mobipass-bike-sync"
// Cloudflare Access service token (prod only — absent locally).
export const VAULT_BELLA_CF_ID     = "bike_bella_cf_access_id"
export const VAULT_BELLA_CF_SECRET = "bike_bella_cf_access_secret"

// What gets a server request past BellaBike's Cloudflare: the browser UA, our sync id (they
// allowlist it past the bot challenge a server can't solve) and the Access service token when set.
// Shared by the sync and the photo normaliser.
export function bellaHeaders(cfAccessId: string | null, cfAccessSecret: string | null): Record<string, string> {
  return {
    "User-Agent":      UA,
    "X-MobiPass-Sync": SYNC_CLIENT_ID,
    ...(cfAccessId && cfAccessSecret
      ? { "CF-Access-Client-Id": cfAccessId, "CF-Access-Client-Secret": cfAccessSecret }
      : {}),
  }
}

// Decoded option attributes promoted to raw_specs (and a few to columns).
const SPEC_CODES = [
  "marime", "marime_roata", "color", "manufacturer", "producatori", "material",
  "motorizare", "numar_viteze", "tip_franare", "capacitate_baterie",
  "putere_motor", "gen", "model", "disponibilitate_stocuri",
]

// ─── Magento types (partial — only what we read) ────────────────────────────
interface CustomAttr { attribute_code: string; value: unknown }
interface MediaEntry { file?: string; position?: number; disabled?: boolean; types?: string[] }
export interface MagentoProduct {
  id?: number
  sku?: string
  name?: string
  type_id?: string                 // 'configurable' | 'simple' | 'virtual'
  price?: number
  status?: number                  // 1 enabled, 2 disabled
  visibility?: number              // 1 child, 4 catalog+search
  updated_at?: string
  custom_attributes?: CustomAttr[]
  media_gallery_entries?: MediaEntry[]
  extension_attributes?: {
    configurable_product_links?: number[]
    salable_qty?: number
  }
}

// ─── Payload types (match merge_bike_offers) ────────────────────────────────
export interface OfferPayload {
  sku: string
  full_price: number
  list_price: number | null
  special_price: number | null
  special_from: string | null
  special_to: string | null
  in_stock: boolean | null      // null = couldn't check this run (keep existing)
  frame_size: string | null
  wheel_size: string | null
  frame_material: string | null
  power_wh: number | null
  engine: string | null
  raw_specs: Record<string, unknown>
}
export interface ModelPayload {
  external_parent_sku: string
  mpn: string | null
  ean: string | null
  brand: string | null
  name: string
  type: string | null
  description: string | null
  images: string[]
  raw_specs: Record<string, unknown>
  offers: OfferPayload[]
}

export type OptionMaps = Map<string, Map<string, string>>

// ─── Magento REST/GraphQL client (token from Vault) ─────────────────────────
export class Magento {
  // `cfAccessId` / `cfAccessSecret` are a Cloudflare Access service token issued
  // by BellaBike's Bluegento team (stored in Vault as bike_bella_cf_access_id /
  // bike_bella_cf_access_secret). When present they authenticate our server-to-
  // server sync at Cloudflare's edge, bypassing the Bot Fight Mode / Managed
  // Challenge that a non-browser client can't solve. Both null (e.g. local dev,
  // where the secrets aren't set) → headers omitted, same behaviour as before.
  constructor(
    private token: string,
    private cfAccessId: string | null = null,
    private cfAccessSecret: string | null = null,
  ) {}

  async rest<T = unknown>(path: string): Promise<T> {
    const res = await fetch(`${REST_BASE}/${path}`, {
      headers: {
        Authorization:     `Bearer ${this.token}`,
        "Accept":          "application/json, text/plain, */*",
        "Accept-Language": "en-US,en;q=0.9",
        ...bellaHeaders(this.cfAccessId, this.cfAccessSecret),
      },
    })
    if (!res.ok) {
      const body = (await res.text().catch(() => "")).slice(0, 240).replace(/\s+/g, " ")
      const cf = res.headers.get("cf-ray") ? "CF" : "noCF"
      throw new Error(`magento GET ${path.slice(0, 40)} → ${res.status} [${cf}] ${body}`)
    }
    return res.json() as Promise<T>
  }

  // is-product-salable/{sku}/2 — the EXACT online stock signal (website stock).
  // Returns null when the call couldn't be made (network/HTTP error): "unknown",
  // NOT "out of stock". A null is never acted on — merge_bike_offers keeps the
  // existing in_stock flag rather than forcing it false (failure-to-observe must
  // not masquerade as a positive signal).
  async isSalable(sku: string): Promise<boolean | null> {
    try {
      const r = await this.rest<unknown>(`inventory/is-product-salable/${enc(sku)}/${WEBSITE_STOCK}`)
      return r === true
    } catch {
      return null         // couldn't check → unknown
    }
  }

  async gql<T = unknown>(query: string): Promise<T> {
    const res = await fetch(GQL_URL, {
      method: "POST",
      headers: {
        "Content-Type":    "application/json",
        ...bellaHeaders(this.cfAccessId, this.cfAccessSecret),
      },
      body: JSON.stringify({ query }),
    })
    if (!res.ok) throw new Error(`magento graphql → ${res.status}`)
    return res.json() as Promise<T>
  }
}

const enc = (s: string) => encodeURIComponent(s)

// ─── helpers ────────────────────────────────────────────────────────────────
function ca(p: MagentoProduct, code: string): string | null {
  const a = p.custom_attributes?.find((x) => x.attribute_code === code)
  return a == null || a.value == null ? null : String(a.value)
}

function decode(opts: OptionMaps, code: string, raw: string | null): string | null {
  if (raw == null || raw === "") return null
  return opts.get(code)?.get(String(raw)) ?? raw
}

function images(p: MagentoProduct): string[] {
  return (p.media_gallery_entries ?? [])
    .filter((e) => e.file && e.disabled !== true)
    .sort((a, b) => (a.position ?? 0) - (b.position ?? 0))
    .map((e) => `${MEDIA_BASE}${e.file}`)
}

function firstInt(s: string | null): number | null {
  if (!s) return null
  const m = s.match(/\d+/)
  return m ? parseInt(m[0], 10) : null
}

// Effective price = special_price when inside its active window, else list.
// Ports bellabike.py effective_price.
function pricing(p: MagentoProduct): {
  list: number | null; special: number | null; from: string | null; to: string | null; effective: number
} {
  const list = p.price != null ? Number(p.price) : null
  const sp = ca(p, "special_price")
  const special = sp ? Number(sp) : null
  const from = ca(p, "special_from_date")
  const to = ca(p, "special_to_date")
  let effective = list ?? 0
  if (special != null && list != null && special > 0 && special < list) {
    const now = Date.now()
    const f = from ? Date.parse(from.replace(" ", "T")) : NaN
    const t = to ? Date.parse(to.replace(" ", "T")) : NaN
    const afterStart = isNaN(f) || f <= now
    const beforeEnd = isNaN(t) || t >= now
    if (afterStart && beforeEnd) effective = special
  }
  return {
    list,
    special,
    from: from ? from.replace(" ", "T") : null,
    to: to ? to.replace(" ", "T") : null,
    effective,
  }
}

// Leaf category → bike_type enum. 29 vs 27.5 split by wheel-size label.
function bikeType(leaf: string, wheelLabel: string | null): string | null {
  const is275 = !!wheelLabel && /27[.,]?5/.test(wheelLabel)
  switch (leaf) {
    case "721": return is275 ? "e_full_suspension_27_5" : "e_full_suspension_29"
    case "722": return is275 ? "e_mtb_hardtail_27_5"    : "e_mtb_hardtail_29"
    case "723": return "e_touring"
    case "725": return "e_road_race"
    case "751": return "e_kids_24"
    default:    return null
  }
}

function decodeSpecs(p: MagentoProduct, opts: OptionMaps): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const code of SPEC_CODES) {
    const v = decode(opts, code, ca(p, code))
    if (v != null) out[code] = v
  }
  return out
}

// ─── attribute option maps (decode option-IDs → labels) ─────────────────────
export async function fetchOptionMaps(mag: Magento): Promise<OptionMaps> {
  const maps: OptionMaps = new Map()
  for (const code of SPEC_CODES) {
    try {
      const opts = await mag.rest<Array<{ label?: string; value?: string }>>(`products/attributes/${enc(code)}/options`)
      const m = new Map<string, string>()
      for (const o of opts) if (o.value != null && o.label != null) m.set(String(o.value), o.label)
      maps.set(code, m)
    } catch {
      // attribute may not exist / be option-typed — skip; raw value passes through.
    }
  }
  return maps
}

// ─── category fetch (paged, optional delta) ─────────────────────────────────
interface ProductsResponse { items?: MagentoProduct[]; total_count?: number }

// Base searchCriteria for a leaf category (+ optional delta on child updated_at).
// Delta keys on the child/variant updated_at (a price/stock change bumps the
// child). Magento wants 'YYYY-MM-DD HH:MM:SS'.
function categoryQs(catId: string, updatedAfter?: string | null): string {
  let qs =
    "searchCriteria[filter_groups][0][filters][0][field]=category_id" +
    `&searchCriteria[filter_groups][0][filters][0][value]=${catId}` +
    "&searchCriteria[filter_groups][0][filters][0][condition_type]=in"
  if (updatedAfter) {
    const ts = updatedAfter.replace("T", " ").slice(0, 19)
    qs +=
      "&searchCriteria[filter_groups][1][filters][0][field]=updated_at" +
      `&searchCriteria[filter_groups][1][filters][0][value]=${enc(ts)}` +
      "&searchCriteria[filter_groups][1][filters][0][condition_type]=gt"
  }
  return qs
}

// total_count for a category (one cheap call) — used by the prepare unit to
// decide how many rest_page units to fan out.
export async function fetchCategoryCount(
  mag: Magento,
  catId: string,
  updatedAfter?: string | null,
): Promise<number> {
  const qs = categoryQs(catId, updatedAfter) +
    "&searchCriteria[pageSize]=1&searchCriteria[currentPage]=1"
  const resp = await mag.rest<ProductsResponse>(`products?${qs}`)
  return resp.total_count ?? (resp.items?.length ?? 0)
}

// One page of a category — the unit of work for a rest_page unit.
export async function fetchCategoryPage(
  mag: Magento,
  catId: string,
  page: number,
  pageSize: number,
  updatedAfter?: string | null,
): Promise<MagentoProduct[]> {
  const qs = categoryQs(catId, updatedAfter) +
    `&searchCriteria[pageSize]=${pageSize}&searchCriteria[currentPage]=${page}`
  const resp = await mag.rest<ProductsResponse>(`products?${qs}`)
  return resp.items ?? []
}

// Full category sweep (all pages) — kept for ad-hoc/offline use; the edge fn
// now pages via fetchCategoryPage so each invocation stays inside budget.
export async function fetchCategory(
  mag: Magento,
  catId: string,
  updatedAfter?: string | null,
): Promise<MagentoProduct[]> {
  const all: MagentoProduct[] = []
  const pageSize = 100
  let page = 1
  for (;;) {
    const items = await fetchCategoryPage(mag, catId, page, pageSize, updatedAfter)
    all.push(...items)
    const total = all.length + (items.length === pageSize ? pageSize : 0)
    if (items.length < pageSize) break
    page++
    void total
  }
  return all
}

// Fetch the configurable PARENTS of a leaf category (lightweight — parents are
// few and carry the configurable_product_links needed to group children). Used
// in delta mode so a changed child still resolves to its (unchanged) parent.
export async function fetchParents(mag: Magento, catId: string): Promise<MagentoProduct[]> {
  const all: MagentoProduct[] = []
  const pageSize = 100
  let page = 1
  for (;;) {
    const qs =
      "searchCriteria[filter_groups][0][filters][0][field]=category_id" +
      `&searchCriteria[filter_groups][0][filters][0][value]=${catId}` +
      "&searchCriteria[filter_groups][0][filters][0][condition_type]=in" +
      "&searchCriteria[filter_groups][1][filters][0][field]=type_id" +
      "&searchCriteria[filter_groups][1][filters][0][value]=configurable" +
      "&searchCriteria[filter_groups][1][filters][0][condition_type]=eq" +
      `&searchCriteria[pageSize]=${pageSize}&searchCriteria[currentPage]=${page}`
    const resp = await mag.rest<ProductsResponse>(`products?${qs}`)
    const items = resp.items ?? []
    all.push(...items)
    const total = resp.total_count ?? all.length
    if (items.length === 0 || page * pageSize >= total) break
    page++
  }
  return all
}

// ─── bounded-concurrency pool ───────────────────────────────────────────────
// Runs `fn` over `items` with at most `concurrency` in flight. The per-SKU
// is-product-salable calls are the cost driver; a small pool cuts a page's wall
// time from O(n) serial round-trips to O(n / concurrency) while staying gentle
// on the vendor's rate limit. Never throws — failures come back as `rejected`.
async function pool<T, R>(
  items: T[],
  concurrency: number,
  fn: (item: T) => Promise<R>,
): Promise<PromiseSettledResult<R>[]> {
  const results = new Array<PromiseSettledResult<R>>(items.length)
  let idx = 0
  async function worker(): Promise<void> {
    while (idx < items.length) {
      const cur = idx++
      try { results[cur] = { status: "fulfilled", value: await fn(items[cur]) } }
      catch (reason) { results[cur] = { status: "rejected", reason } }
    }
  }
  const n = Math.max(1, Math.min(concurrency, items.length))
  await Promise.all(Array.from({ length: n }, () => worker()))
  return results
}

// ─── build the model+offer payload for one PAGE of a leaf category ──────────
export interface BuildResult { models: ModelPayload[]; nFetched: number; nFailed: number }

// `products` = ONE page of the category. `extraParents` = the category's full
// configurable-parent list (cached by the prepare unit) so children on this
// page group under parents that may live on another page. A configurable whose
// children fall on other pages yields a model with [] offers here; those pages
// add the offers (merge_bike_offers upserts each offer independently, so the
// model is assembled correctly across pages).
export async function buildModels(
  mag: Magento,
  products: MagentoProduct[],
  leaf: string,
  opts: OptionMaps,
  extraParents: MagentoProduct[] = [],
  concurrency = 8,
): Promise<BuildResult> {
  const enabled = products.filter((p) => p.status === 1 && p.sku)

  // Parent index from in-page parents + the cached category parents.
  const allParents = new Map<number, MagentoProduct>()
  for (const p of [...enabled.filter((p) => p.type_id === "configurable"), ...extraParents]) {
    if (p.id != null) allParents.set(p.id, p)
  }
  const parentByChildId = new Map<number, MagentoProduct>()
  for (const par of allParents.values()) {
    for (const cid of par.extension_attributes?.configurable_product_links ?? []) {
      parentByChildId.set(cid, par)
    }
  }

  // Children on this page, grouped by parent.
  const childrenByParentId = new Map<number, MagentoProduct[]>()
  for (const p of enabled) {
    if (p.type_id !== "simple" || p.id == null) continue
    const par = parentByChildId.get(p.id)
    if (!par || par.id == null) continue            // orphan child → unreachable, skip
    const list = childrenByParentId.get(par.id) ?? []
    list.push(p)
    childrenByParentId.set(par.id, list)
  }

  // Models to emit from this page: configurables present on the page OR with a
  // child on the page; plus standalone simples.
  const parentIdsToProcess = new Set<number>()
  for (const p of enabled) if (p.type_id === "configurable" && p.id != null) parentIdsToProcess.add(p.id)
  for (const pid of childrenByParentId.keys()) parentIdsToProcess.add(pid)

  const standalone = enabled.filter(
    (p) => p.type_id === "simple" && p.visibility === 4 && p.price &&
           !(p.id != null && parentByChildId.has(p.id)),
  )

  // Flat offer jobs keyed by their model's parent sku → bounded-parallel salable.
  interface Job { key: string; product: MagentoProduct }
  const jobs: Job[] = []
  const modelByKey = new Map<string, { par: MagentoProduct; standalone: boolean }>()
  for (const pid of parentIdsToProcess) {
    const par = allParents.get(pid)
    if (!par || !par.sku) continue
    modelByKey.set(par.sku, { par, standalone: false })
    for (const c of childrenByParentId.get(pid) ?? []) jobs.push({ key: par.sku, product: c })
  }
  for (const s of standalone) {
    modelByKey.set(s.sku!, { par: s, standalone: true })
    jobs.push({ key: s.sku!, product: s })
  }

  const settled = await pool(jobs, concurrency, (j) => mapOffer(mag, j.product, opts))

  const offersByKey = new Map<string, OfferPayload[]>()
  let nFailed = 0
  settled.forEach((res, i) => {
    if (res.status === "fulfilled") {
      const arr = offersByKey.get(jobs[i].key) ?? []
      arr.push(res.value)
      offersByKey.set(jobs[i].key, arr)
    } else {
      nFailed++
    }
  })

  const models: ModelPayload[] = []
  for (const [key, info] of modelByKey) {
    const offers = offersByKey.get(key) ?? []
    const model = mapModel(info.par, leaf, opts, offers)
    models.push(info.standalone ? { ...model, external_parent_sku: info.par.sku! } : model)
  }

  return { models, nFetched: enabled.length, nFailed }
}

// ─── option-map (de)serialization for the run cache ─────────────────────────
// OptionMaps is Map<code, Map<optionId, label>>; jsonb wants plain objects.
export function serializeOptionMaps(maps: OptionMaps): Record<string, Record<string, string>> {
  const out: Record<string, Record<string, string>> = {}
  for (const [code, m] of maps) {
    const o: Record<string, string> = {}
    for (const [k, v] of m) o[k] = v
    out[code] = o
  }
  return out
}

export function deserializeOptionMaps(obj: Record<string, Record<string, string>>): OptionMaps {
  const maps: OptionMaps = new Map()
  for (const code of Object.keys(obj ?? {})) {
    const m = new Map<string, string>()
    for (const k of Object.keys(obj[code] ?? {})) m.set(k, obj[code][k])
    maps.set(code, m)
  }
  return maps
}

function mapModel(p: MagentoProduct, leaf: string, opts: OptionMaps, offers: OfferPayload[]): ModelPayload {
  const specs = decodeSpecs(p, opts)
  const wheel = decode(opts, "marime_roata", ca(p, "marime_roata"))
  const brand = decode(opts, "producatori", ca(p, "producatori")) ??
                decode(opts, "manufacturer", ca(p, "manufacturer"))
  return {
    external_parent_sku: p.sku!,
    mpn: ca(p, "mpn") ?? ca(p, "manufacturer_part_number"),
    ean: ca(p, "ean") ?? ca(p, "barcode"),
    brand,
    name: p.name ?? p.sku!,
    type: bikeType(leaf, wheel),
    description: ca(p, "description"),
    images: images(p),
    raw_specs: specs,
    offers,
  }
}

async function mapOffer(mag: Magento, p: MagentoProduct, opts: OptionMaps): Promise<OfferPayload> {
  const pr = pricing(p)
  return {
    sku: p.sku!,
    full_price: pr.effective,
    list_price: pr.list,
    special_price: pr.special,
    special_from: pr.from,
    special_to: pr.to,
    in_stock: await mag.isSalable(p.sku!),
    frame_size: decode(opts, "marime", ca(p, "marime")),
    wheel_size: decode(opts, "marime_roata", ca(p, "marime_roata")),
    frame_material: decode(opts, "material", ca(p, "material")),
    power_wh: firstInt(decode(opts, "capacitate_baterie", ca(p, "capacitate_baterie"))),
    engine: decode(opts, "motorizare", ca(p, "motorizare")),
    raw_specs: decodeSpecs(p, opts),
  }
}

// ─── membership (REMOVED 2026-06-08) ─────────────────────────────────────────
// fetchMembership + the GraphQL catalog-membership signal were removed: a
// storefront audit proved products(filter:{sku:{in:[parentSku]}}) under-reports
// live configurable parents (19/20 "absent" parents were live + buyable), so it
// could not drive in_catalog or delisting. Catalog membership = presence in the
// REST /products sweep; stock = per-offer is-salable. See migration
// 20260608000004 and llm-agent-assist/plans/bella-bike-integration.md.
