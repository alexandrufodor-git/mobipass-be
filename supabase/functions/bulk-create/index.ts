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
      const { payload, kind } = await readPayload(req)

      if (kind === "csv") {
        const results = await ingestCsv(db, companyId, payload as string)
        return json({ created: results.length, results }, 200, origin)
      }

      const records = payload as unknown
      if (!Array.isArray(records)) {
        return badRequest(Errors.INVALID_REGES_FORMAT, undefined, origin)
      }

      // Precondition for REGES branch: company must have email_domain set.
      // This is the only branch that needs it, so we check it here (close to
      // the policy) rather than inside the helper.
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
    // Some helpers (requireRole) throw a pre-built Response on policy
    // failures; convert those into return values. Anything else is a real
    // bug — let it propagate to a 500.
    if (err instanceof Response) return err
    throw err
  }
})

// Resolve the upload payload + kind. Supports:
//   - multipart/form-data with a single .csv, .json, or .txt file
//     (.txt is treated as JSON because REGES exports may use that extension)
//   - text/csv raw body
//   - application/json raw body
async function readPayload(req: Request): Promise<{ payload: string | unknown; kind: "csv" | "json" }> {
  const ct = req.headers.get("content-type") || ""

  if (ct.startsWith("multipart/form-data")) {
    const boundary = getBoundary(ct)
    if (!boundary) throw badRequest(Errors.MISSING_BOUNDARY)
    const { files } = await parseMultipart(req)
    const file = files[0]
    const fname = (file.filename || "").toLowerCase()
    // REGES (Romanian gov platform) sometimes exports JSON with a .txt
    // extension, so treat .txt the same as .json. If the body isn't valid
    // JSON we reject — .txt is reserved for REGES payloads here.
    // To revert: drop the `|| fname.endsWith(".txt")` clause.
    if (fname.endsWith(".json") || fname.endsWith(".txt")) {
      try {
        return { payload: JSON.parse(file.content), kind: "json" }
      } catch {
        throw badRequest(Errors.INVALID_REGES_FORMAT)
      }
    }
    // Default to CSV for any other extension (.csv, no extension).
    return { payload: file.content, kind: "csv" }
  }

  if (ct.includes("application/json")) {
    const text = await req.text()
    try {
      return { payload: JSON.parse(text), kind: "json" }
    } catch {
      throw badRequest(Errors.INVALID_REGES_FORMAT)
    }
  }

  // Plain text body → CSV (covers text/csv and unspecified content-type).
  const text = await req.text()
  if (!text.trim()) throw badRequest(Errors.EMPTY_CSV)
  return { payload: text, kind: "csv" }
}
