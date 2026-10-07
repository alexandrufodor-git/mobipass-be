// supabase/functions/issue-report/index.ts
//
// Problem reports from the mobile app (shake or Settings → Report a problem).
// multipart { meta: JSON, file: zip } → bucket issue-reports + public.issue_reports row.
// verify_jwt=true: signed-in users only. The JWT gates the call; the report stores no identity.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { extractUserId, requireJwt } from "../_shared/auth.ts"
import { ISSUE_REPORTS_BUCKET, removeIssueReportFiles } from "../_shared/issueReportStorage.ts"
import { makeRestClient } from "../_shared/supabaseRest.ts"
import { MAX_ZIP_BYTES, isZip, parseMeta, storagePath } from "./report.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)
  try {
    extractUserId(requireJwt(req))
    return await upload(req)
  } catch (err) {
    if (err instanceof Response) return err
    console.error("[issue-report] failed:", err)
    return json({ error: "internal_error" }, 500)
  }
})

async function upload(req: Request): Promise<Response> {
  // Read with a hard cap rather than trusting Content-Length (absent when chunked).
  const body = await readCapped(req, MAX_ZIP_BYTES + 64 * 1024)
  if (!body) return json({ error: "too_large" }, 413)
  const form = await new Response(body, { headers: { "content-type": req.headers.get("content-type") ?? "" } })
    .formData()
    .catch(() => null)
  if (!form) return json({ error: "invalid_body" }, 400)

  let rawMeta: unknown
  try {
    rawMeta = JSON.parse(String(form.get("meta") ?? ""))
  } catch {
    return json({ error: "invalid_meta", field: "meta" }, 400)
  }
  const meta = parseMeta(rawMeta)
  if (!meta.ok) return json({ error: "invalid_meta", field: meta.field }, 400)
  const row = meta.row

  const file = form.get("file")
  if (!(file instanceof File)) return json({ error: "missing_file" }, 400)
  if (file.size > MAX_ZIP_BYTES) return json({ error: "too_large" }, 413)
  const bytes = new Uint8Array(await file.arrayBuffer())
  if (!isZip(bytes)) return json({ error: "not_zip" }, 400)

  if (await db.getOne("issue_reports", `id=eq.${row.id}`, "id")) return json({ error: "duplicate" }, 409)

  const path = storagePath(row, new Date())
  const stored = await fetch(`${SUPABASE_URL}/storage/v1/object/${ISSUE_REPORTS_BUCKET}/${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`,
      apikey: SERVICE_KEY,
      "Content-Type": "application/zip",
      "x-upsert": "false",
    },
    body: bytes,
  })
  if (!stored.ok) {
    console.error("[issue-report] storage upload:", stored.status, await stored.text())
    return json({ error: "storage_failed" }, 500)
  }

  const inserted = await db.post("issue_reports", { ...row, storage_path: path, size_bytes: bytes.length })
  if (!inserted.ok) {
    console.error("[issue-report] insert:", inserted.status, await inserted.text())
    await removeIssueReportFiles(SUPABASE_URL, SERVICE_KEY, [path])
    return inserted.status === 409 ? json({ error: "duplicate" }, 409) : json({ error: "insert_failed" }, 500)
  }
  return json({ id: row.id }, 201)
}

/** The whole body, or null as soon as it passes [limit] bytes. */
async function readCapped(req: Request, limit: number): Promise<Uint8Array<ArrayBuffer> | null> {
  const reader = req.body?.getReader()
  if (!reader) return new Uint8Array()
  const chunks: Uint8Array[] = []
  let size = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.length
    if (size > limit) {
      await reader.cancel()
      return null
    }
    chunks.push(value)
  }
  const body = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    body.set(chunk, offset)
    offset += chunk.length
  }
  return body
}
