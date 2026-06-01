console.info("bulk-create starting")

import { requireRole } from "../_shared/guard.ts"
import { Errors, badRequest, notFound, json } from "../_shared/constants.ts"
import {
  corsResponse,
  getBoundary,
  parseMultipart,
} from "../_shared/ioHelpers.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { ingestCsv } from "../_shared/csvIngest.ts"
import {
  ingestRegesArray,
  type CompanyCtx,
  type RegesRecord,
} from "../_shared/regesIngest.ts"
import type { EmailPatternKind } from "../_shared/emailPattern.ts"

// bulk-create dispatches on Content-Type:
//   - text/csv | multipart with .csv file  → ingestCsv (existing manual flow)
//   - application/json | multipart .json   → ingestRegesArray (REGES branch)
//
// REGES payload contract: a JSON array of `{ referintaSalariat, info }`
// objects matching the REGES export shape.

Deno.serve(async (req: Request) => {
  const url = new URL(req.url)
  const path = url.pathname
  const method = req.method
  const origin = req.headers.get("origin") || ""

  if (method === "OPTIONS") {
    return corsResponse(origin)
  }

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

    const jwt = await requireRole(req, SUPABASE_URL, SERVICE_KEY, undefined, origin)

    const profileRes = await fetch(
      `${SUPABASE_URL}/rest/v1/profiles?user_id=eq.${jwt.sub}&select=company_id`,
      {
        headers: {
          Authorization: `Bearer ${SERVICE_KEY}`,
          apikey: SERVICE_KEY,
        },
      },
    )
    if (!profileRes.ok) return json(Errors.PROFILE_FETCH_FAILED, 500, origin)

    const profiles = await profileRes.json()
    if (!profiles || profiles.length === 0) return json(Errors.PROFILE_NOT_FOUND, 404, origin)

    const companyId = profiles[0].company_id
    if (!companyId) return badRequest(Errors.NO_COMPANY, undefined, origin)

    if ((path === "/bulk-create" || path === "/") && method === "POST") {
      const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)
      const { payload, kind } = await readPayload(req, origin)

      if (kind === "csv") {
        const results = await ingestCsv(db, companyId, payload as string)
        return json({ created: results.length, results }, 200, origin)
      }

      const records = payload as unknown
      if (!Array.isArray(records)) {
        console.error(`[bulk-create] reject=not_array typeof=${typeof records} isNull=${records === null}`)
        return badRequest(Errors.INVALID_REGES_FORMAT, undefined, origin)
      }

      // Precondition for REGES branch: company must have email_domain set.
      // Schema-level NOT NULL + CHECK constraint (see migration
      // 20260601000001_companies_email_domain_required.sql) makes this
      // unreachable in practice — kept as defense-in-depth in case the
      // constraint is ever relaxed.
      const company = await db.getOne<{
        id: string; email_domain: string | null; email_pattern: EmailPatternKind | null
      }>(
        "companies",
        `id=eq.${companyId}`,
        "id,email_domain,email_pattern",
      )
      if (!company) return json(Errors.PROFILE_NOT_FOUND, 404, origin)
      if (!company.email_domain) {
        return badRequest(Errors.COMPANY_DOMAIN_NOT_CONFIGURED, undefined, origin)
      }
      const ctx: CompanyCtx = {
        id:            company.id,
        email_domain:  company.email_domain,
        email_pattern: company.email_pattern,
      }

      const results = await ingestRegesArray(db, ctx, records as RegesRecord[])
      return json({ created: results.length, results }, 200, origin)
    }

    return notFound(path, origin)
  } catch (err) {
    // Some helpers (requireRole, readPayload) throw a pre-built Response on
    // policy / validation failures; those carry the user-facing error code
    // already. Anything else is a real bug — log it (server-side only, no
    // leak to client) and let it propagate to a 500.
    if (err instanceof Response) return err
    console.error("[bulk-create] unhandled_error:", err instanceof Error ? err.stack ?? err.message : String(err))
    throw err
  }
})

// Resolve the upload payload + kind. Supports:
//   - multipart/form-data with a single .csv, .json, or .txt file
//     (.txt is treated as JSON because REGES exports may use that extension)
//   - text/csv raw body
//   - application/json raw body
//
// `origin` is threaded through so the badRequest Response we throw carries
// proper CORS headers — otherwise the browser blocks the response body and
// the frontend can't read the error code.
async function readPayload(
  req: Request,
  origin: string,
): Promise<{ payload: string | unknown; kind: "csv" | "json" }> {
  const ct = req.headers.get("content-type") || ""
  const cl = req.headers.get("content-length") || "?"
  // Diagnostic log — server-side only, no payload contents, just classifiers.
  console.info(`[bulk-create] readPayload ct="${ct}" content_length=${cl}`)

  if (ct.startsWith("multipart/form-data")) {
    const boundary = getBoundary(ct)
    if (!boundary) {
      console.error(`[bulk-create] readPayload reject=missing_boundary ct="${ct}"`)
      throw badRequest(Errors.MISSING_BOUNDARY, undefined, origin)
    }
    const { files } = await parseMultipart(req)
    const file = files[0]
    const fname = (file?.filename || "").toLowerCase()
    const fsize = file?.content?.length ?? 0
    console.info(`[bulk-create] readPayload branch=multipart files=${files.length} filename="${fname}" file_bytes=${fsize}`)
    // REGES (Romanian gov platform) sometimes exports JSON with a .txt
    // extension, so treat .txt the same as .json. If the body isn't valid
    // JSON we reject — .txt is reserved for REGES payloads here.
    // To revert: drop the `|| fname.endsWith(".txt")` clause.
    if (fname.endsWith(".json") || fname.endsWith(".txt")) {
      try {
        return { payload: JSON.parse(file.content), kind: "json" }
      } catch (e) {
        console.error(`[bulk-create] readPayload reject=multipart_json_parse_failed filename="${fname}" reason="${e instanceof Error ? e.message : String(e)}"`)
        throw badRequest(Errors.INVALID_REGES_FORMAT, undefined, origin)
      }
    }
    // Default to CSV for any other extension (.csv, no extension).
    return { payload: file.content, kind: "csv" }
  }

  if (ct.includes("application/json")) {
    const text = await req.text()
    console.info(`[bulk-create] readPayload branch=application/json body_bytes=${text.length}`)
    try {
      return { payload: JSON.parse(text), kind: "json" }
    } catch (e) {
      console.error(`[bulk-create] readPayload reject=json_body_parse_failed body_bytes=${text.length} reason="${e instanceof Error ? e.message : String(e)}"`)
      throw badRequest(Errors.INVALID_REGES_FORMAT, undefined, origin)
    }
  }

  // Plain text body → CSV (covers text/csv and unspecified content-type).
  const text = await req.text()
  console.info(`[bulk-create] readPayload branch=raw_text ct="${ct}" body_bytes=${text.length}`)
  if (!text.trim()) {
    console.error(`[bulk-create] readPayload reject=empty_csv ct="${ct}"`)
    throw badRequest(Errors.EMPTY_CSV, undefined, origin)
  }
  return { payload: text, kind: "csv" }
}
