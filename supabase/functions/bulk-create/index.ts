console.info("bulk-create starting")

import { requireRole } from "../_shared/guard.ts"
import { Errors, UPLOAD_EXTENSIONS, UploadKind, badRequest, notFound, json } from "../_shared/constants.ts"
import {
  corsResponse,
  getBoundary,
} from "../_shared/ioHelpers.ts"
import { makeRestClient, type RestClient } from "../_shared/supabaseRest.ts"
import { ingestCsv } from "../_shared/csvIngest.ts"
import { XlsxError, ingestXlsx } from "../_shared/xlsxIngest.ts"
import type { BulkResult } from "../_shared/bulkResult.ts"
import {
  ingestRegesArray,
  type CompanyCtx,
  type RegesRecord,
} from "../_shared/regesIngest.ts"
import type { EmailPatternKind } from "../_shared/emailPattern.ts"

// REGES payload: a JSON array of `{ referintaSalariat, info }` objects (the REGES export shape).

type Upload =
  | { kind: typeof UploadKind.CSV; text: string }
  | { kind: typeof UploadKind.XLSX; bytes: Uint8Array }
  | { kind: typeof UploadKind.REGES; records: unknown }

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
      const upload = await readPayload(req, origin)

      let results: BulkResult[]
      switch (upload.kind) {
        case UploadKind.CSV:   results = await ingestCsv(db, companyId, upload.text); break
        case UploadKind.XLSX:  results = await ingestXlsx(db, companyId, upload.bytes); break
        case UploadKind.REGES: results = await ingestReges(db, companyId, upload.records, origin); break
      }
      return json({ created: results.length, results }, 200, origin)
    }

    return notFound(path, origin)
  } catch (err) {
    // Thrown Responses and XlsxErrors carry the user-facing code; anything else is a bug → logged, 500.
    if (err instanceof Response) return err
    if (err instanceof XlsxError) {
      console.error(`[bulk-create] reject=xlsx_${err.body.error}`)
      return badRequest(err.body, undefined, origin)
    }
    console.error("[bulk-create] unhandled_error:", err instanceof Error ? err.stack ?? err.message : String(err))
    throw err
  }
})

async function ingestReges(db: RestClient, companyId: string, records: unknown, origin: string): Promise<BulkResult[]> {
  if (!Array.isArray(records)) {
    console.error(`[bulk-create] reject=not_array typeof=${typeof records} isNull=${records === null}`)
    throw badRequest(Errors.INVALID_REGES_FORMAT, undefined, origin)
  }

  // Defense in depth: the NOT NULL + CHECK on companies.email_domain already makes this unreachable.
  const company = await db.getOne<{
    id: string; email_domain: string | null; email_pattern: EmailPatternKind | null
  }>(
    "companies",
    `id=eq.${companyId}`,
    "id,email_domain,email_pattern",
  )
  if (!company) throw json(Errors.PROFILE_NOT_FOUND, 404, origin)
  if (!company.email_domain) {
    throw badRequest(Errors.COMPANY_DOMAIN_NOT_CONFIGURED, undefined, origin)
  }
  const ctx: CompanyCtx = {
    id:            company.id,
    email_domain:  company.email_domain,
    email_pattern: company.email_pattern,
  }

  return ingestRegesArray(db, ctx, records as RegesRecord[])
}

// Own-property lookup only, so a name like "x.constructor" can't pick up Object.prototype members.
function uploadKindOf(filename: string): UploadKind {
  const dot = filename.lastIndexOf(".")
  const ext = dot < 0 ? "" : filename.slice(dot).toLowerCase()
  return Object.hasOwn(UPLOAD_EXTENSIONS, ext) ? UPLOAD_EXTENSIONS[ext] : UploadKind.CSV
}

function parseRegesJson(text: string, origin: string, rejectToken: string): unknown {
  try {
    return JSON.parse(text)
  } catch (e) {
    console.error(`[bulk-create] readPayload reject=${rejectToken} body_bytes=${text.length} reason="${e instanceof Error ? e.message : String(e)}"`)
    throw badRequest(Errors.INVALID_REGES_FORMAT, undefined, origin)
  }
}

// `origin` is passed so thrown badRequests carry CORS headers and the browser can read the error code.
async function readPayload(req: Request, origin: string): Promise<Upload> {
  const ct = req.headers.get("content-type") || ""
  const cl = req.headers.get("content-length") || "?"
  // Diagnostic log — server-side only, no payload contents, just classifiers.
  console.info(`[bulk-create] readPayload ct="${ct}" content_length=${cl}`)

  if (ct.startsWith("multipart/form-data")) {
    if (!getBoundary(ct)) {
      console.error(`[bulk-create] readPayload reject=missing_boundary ct="${ct}"`)
      throw badRequest(Errors.MISSING_BOUNDARY, undefined, origin)
    }
    // Native formData keeps the upload as bytes, so binary .xlsx files survive.
    const files = [...(await req.formData()).values()].filter((v): v is File => v instanceof File)
    const file = files[0]
    if (!file) {
      console.error(`[bulk-create] readPayload reject=no_file ct="${ct}"`)
      throw badRequest(Errors.NO_FILE, undefined, origin)
    }
    const kind = uploadKindOf(file.name)
    console.info(`[bulk-create] readPayload branch=multipart files=${files.length} kind=${kind} filename="${file.name.toLowerCase()}" file_bytes=${file.size}`)
    switch (kind) {
      case UploadKind.XLSX:  return { kind, bytes: new Uint8Array(await file.arrayBuffer()) }
      case UploadKind.REGES: return { kind, records: parseRegesJson(await file.text(), origin, "multipart_json_parse_failed") }
      case UploadKind.CSV:   return { kind, text: await file.text() }
    }
  }

  if (ct.includes("application/json")) {
    const text = await req.text()
    console.info(`[bulk-create] readPayload branch=application/json body_bytes=${text.length}`)
    return { kind: UploadKind.REGES, records: parseRegesJson(text, origin, "json_body_parse_failed") }
  }

  // Plain text body → CSV (covers text/csv and unspecified content-type).
  const text = await req.text()
  console.info(`[bulk-create] readPayload branch=raw_text ct="${ct}" body_bytes=${text.length}`)
  if (!text.trim()) {
    console.error(`[bulk-create] readPayload reject=empty_csv ct="${ct}"`)
    throw badRequest(Errors.EMPTY_CSV, undefined, origin)
  }
  return { kind: UploadKind.CSV, text }
}
