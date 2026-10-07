// Pure rules for issue-report: metadata validation, zip check, scrubbing, storage path.

export const MAX_ZIP_BYTES = 5 * 1024 * 1024
export const MAX_DESCRIPTION = 500
export const MAX_FIELD = 100

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const TRIGGERS = ["shake", "settings"]
const PLATFORMS = ["ios", "android"]

export interface IssueReportRow {
  id: string
  trigger: string
  platform: string
  app_version: string
  build: string
  os_version: string
  device_model: string
  locale: string | null
  timezone: string | null
  description: string
}

export type MetaResult = { ok: true; row: IssueReportRow } | { ok: false; field: string }

/** Validates the client's meta.json; unknown keys are ignored (they stay in the zip). */
export function parseMeta(raw: unknown): MetaResult {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return { ok: false, field: "meta" }
  const m = raw as Record<string, unknown>

  const required = (key: string) => {
    const v = m[key]
    return typeof v === "string" && v.trim() !== "" && v.length <= MAX_FIELD ? v.trim() : undefined
  }
  const optional = (key: string) => {
    const v = m[key]
    if (v === undefined || v === null || v === "") return null
    return typeof v === "string" && v.length <= MAX_FIELD ? v.trim() : undefined
  }

  const id = typeof m.report_id === "string" && UUID_RE.test(m.report_id) ? m.report_id.toLowerCase() : undefined
  if (!id) return { ok: false, field: "report_id" }
  if (!TRIGGERS.includes(m.trigger as string)) return { ok: false, field: "trigger" }
  if (!PLATFORMS.includes(m.platform as string)) return { ok: false, field: "platform" }

  const description = m.description ?? ""
  if (typeof description !== "string" || description.length > MAX_DESCRIPTION) {
    return { ok: false, field: "description" }
  }

  const row: Partial<IssueReportRow> = {
    id,
    trigger: m.trigger as string,
    platform: m.platform as string,
    description: scrub(description.trim()),
  }
  for (const key of ["app_version", "build", "os_version", "device_model"] as const) {
    const v = required(key)
    if (v === undefined) return { ok: false, field: key }
    row[key] = v
  }
  for (const key of ["locale", "timezone"] as const) {
    const v = optional(key)
    if (v === undefined) return { ok: false, field: key }
    row[key] = v
  }
  return { ok: true, row: row as IssueReportRow }
}

/** Local file header magic "PK\x03\x04". */
export function isZip(bytes: Uint8Array): boolean {
  return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 0x03 && bytes[3] === 0x04
}

export function storagePath(row: IssueReportRow, now: Date): string {
  return `${row.platform}/${now.toISOString().slice(0, 10)}/${row.id}.zip`
}

// Same rules as the app's TelemetrySanitizer; bearer must run before sensitiveParam.
const BEARER = /\bbearer\s+[A-Za-z0-9._~+/=-]{8,}/gi
const SENSITIVE_PARAM =
  /\b(access_token|refresh_token|provider_token|provider_refresh_token|id_token|token|apikey|api_key|password|secret|authorization|user_id|lat|lon|lng|latitude|longitude)["')]*\s*[=:]\s*["'(]?([^&\s"',})]+)/gi
const JWT = /\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}/g
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g
const COORDINATE_PAIR = /-?\d{1,3}\.\d{4,}\s*,\s*-?\d{1,3}\.\d{4,}/g

export function scrub(text: string): string {
  return text
    .replace(BEARER, "Bearer <redacted:token>")
    .replace(SENSITIVE_PARAM, (_, key: string) => `${key}=<redacted:${key.toLowerCase()}>`)
    .replace(JWT, "<redacted:jwt>")
    .replace(EMAIL, "<redacted:email>")
    .replace(COORDINATE_PAIR, "<redacted:coords>")
}
