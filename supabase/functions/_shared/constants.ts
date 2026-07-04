// supabase/functions/_shared/constants.ts

// Allowed origins loaded once from the ALLOWED_ORIGINS env var (comma-separated).
// Set this in supabase/config.toml [functions.*.env] or the Supabase dashboard.
// Example: "https://app.example.com,https://admin.example.com"
const ALLOWED_ORIGINS = new Set(
  (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
)

// Returns CORS headers. Only reflects the request origin if it is in the
// ALLOWED_ORIGINS allowlist — never falls back to "*".
export function getCorsHeaders(origin?: string): Record<string, string> {
  const allowedOrigin = (origin && ALLOWED_ORIGINS.has(origin)) ? origin : ""
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  }
}

// eSignatures.com integration
export const ESIGNATURES_API_URL  = "https://esignatures.com/api/contracts"
export const ESIGNATURES_VAULT_KEY = "esignature_api_key"

// Firebase Cloud Messaging auth is keyless (Workload Identity Federation);
// config + vault keys live in _shared/fcm.ts, no service-account JSON.

export const EsigEvents = {
  VIEWED:          "signer-viewed-the-contract",
  SIGNED:          "signer-signed",
  DECLINED:        "signer-declined",
  WITHDRAWN:       "contract-withdrawn",
  CONTRACT_SIGNED: "contract-signed",
} as const

// Maps eSignatures event → contract_status value sent in broadcast event_type
export const EsigToContractStatus: Partial<Record<string, string>> = {
  [EsigEvents.VIEWED]:   "viewed_by_employee",
  [EsigEvents.SIGNED]:   "signed_by_employee",
  [EsigEvents.DECLINED]: "declined_by_employee",
}

export const UserRoles = {
  ADMIN: "admin",
  HR: "hr",
  EMPLOYEE: "employee",
} as const

export type UserRole = typeof UserRoles[keyof typeof UserRoles]

// Notification event types — mirrors public.notification_event enum in DB.
// Mobile clients use these keys in FCM data payload for localization.
export const NotificationEvent = {
  CONTRACT_READY:     "contract_ready",
  CONTRACT_SIGNED_HR: "contract_signed_hr",
  CONTRACT_APPROVED:  "contract_approved",
  LOAN_STATUS_UPDATE: "loan_status_update",
  // SSO claim review (HR realtime + user FCM when approved/rejected offline)
  SSO_CLAIM_PENDING:  "sso_claim_pending",
  SSO_CLAIM_APPROVED: "sso_claim_approved",
  SSO_CLAIM_REJECTED: "sso_claim_rejected",
} as const

export type NotificationEventType = typeof NotificationEvent[keyof typeof NotificationEvent]

// Centralized error responses
export const Errors = {
  // Auth errors
  FORBIDDEN: { error: "forbidden", reason: "no_permission_to_access_this_data" },
  INVALID_JWT: { error: "invalid_jwt" },
  ROLE_LOOKUP_FAILED: { error: "role_lookup_failed" },
  // IO/parsing errors
  MISSING_BOUNDARY: { error: "missing_boundary" },
  NO_FILE: { error: "no_file" },
  EMPTY_CSV: { error: "empty_csv" },
  NO_ROWS: { error: "no_rows" },
  MISSING_HEADER: { error: "missing_header" },
  // General
  NOT_FOUND: { error: "not_found" },
  // Registration
  NOT_INVITED: { error: "not_invited" },
  EMAIL_REQUIRED: { error: "email_required" },
  OTP_FAILED: { error: "otp_send_failed" },
  // Profile/Company errors
  PROFILE_FETCH_FAILED: { error: "profile_fetch_failed" },
  PROFILE_NOT_FOUND: { error: "profile_not_found" },
  NO_COMPANY: { error: "no_company_assigned" },
  NO_HR: { error: "no_hr_assigned" },
  // eSignatures / contract errors
  NO_BIKE_BENEFIT: { error: "no_bike_benefit" },
  NO_BIKE_SELECTED: { error: "no_bike_selected" },
  BIKE_NOT_FOUND: { error: "bike_not_found" },
  NO_TEMPLATE: { error: "no_esignatures_template" },
  CONTRACT_ALREADY_REQUESTED: { error: "contract_already_requested" },
  INVALID_BENEFIT_STEP: { error: "invalid_benefit_step", reason: "step_must_be_sign_contract" },
  ESIGNATURES_API_FAILED: { error: "esignatures_api_failed" },
  // Notification errors (non-fatal, logged only)
  FCM_SEND_FAILED: { error: "fcm_send_failed" },
  BROADCAST_FAILED: { error: "broadcast_failed" },
  // TBI loan errors
  TBI_CREDENTIALS_MISSING: { error: "tbi_credentials_missing" },
  TBI_API_FAILED: { error: "tbi_api_failed" },
  LOAN_NOT_FOUND: { error: "loan_not_found" },
  LOAN_NOT_CANCELABLE: { error: "loan_not_cancelable" },
  // PII / employee details errors
  PII_KEY_MISSING: { error: "pii_encryption_key_missing" },
  PII_DECRYPT_FAILED: { error: "pii_decrypt_failed" },
  // REGES JSON ingest errors
  INVALID_REGES_FORMAT: { error: "invalid_reges_format" },
  COMPANY_DOMAIN_NOT_CONFIGURED: { error: "company_domain_not_configured" },
  // Confidence-based registration errors
  AMBIGUOUS_MATCH: { error: "ambiguous_match" },
  INVITE_INACTIVE: { error: "invite_inactive" },
  COMPANY_NOT_FOUND_FOR_DOMAIN: { error: "company_not_found_for_domain" },
  CHECK_DETAILS: { error: "check_details" },
  // SSO claim (sso-claim-record)
  NAME_REQUIRED_FOR_CLAIM: { error: "name_required_for_claim" },
  NO_PENDING_CLAIM: { error: "no_pending_claim" },
} as const

// Server-side log helper. Logs only the short error code (no PII, no request body,
// no stack traces) so logs are safe to keep but still tell you which branch fired.
// The client response body is unchanged — same `{ error, reason? }` shape.
function logError(status: number, code: string, reason?: string): void {
  const tag = reason ? `${code} (${reason})` : code
  console.error(`[${status}] ${tag}`)
}

export function forbidden(error = Errors.FORBIDDEN, origin?: string): Response {
  logError(403, error.error, error.reason)
  return new Response(
    JSON.stringify({ error: error.error, reason: error.reason }),
    { status: 403, headers: { "content-type": "application/json", ...getCorsHeaders(origin) } }
  )
}

export function invalidJwt(error = Errors.INVALID_JWT, origin?: string): Response {
  logError(401, error.error)
  return new Response(
    JSON.stringify({ error: error.error }),
    { status: 401, headers: { "content-type": "application/json", ...getCorsHeaders(origin) } }
  )
}

export function roleLookupFailed(error = Errors.ROLE_LOOKUP_FAILED, origin?: string): Response {
  logError(500, error.error)
  return new Response(
    JSON.stringify({ error: error.error }),
    { status: 500, headers: { "content-type": "application/json", ...getCorsHeaders(origin) } }
  )
}

export function badRequest(error: { error: string }, extra?: Record<string, unknown>, origin?: string): Response {
  logError(400, error.error, (error as { reason?: string }).reason)
  return new Response(
    JSON.stringify({ ...error, ...extra }),
    { status: 400, headers: { "content-type": "application/json", ...getCorsHeaders(origin) } }
  )
}

export function notFound(path?: string, origin?: string): Response {
  logError(404, Errors.NOT_FOUND.error, path)
  return new Response(
    JSON.stringify({ ...Errors.NOT_FOUND, ...(path && { path }) }),
    { status: 404, headers: { "content-type": "application/json", ...getCorsHeaders(origin) } }
  )
}

export function json(obj: unknown, status = 200, origin?: string): Response {
  if (status >= 400) {
    const code = (obj as { error?: string } | null)?.error ?? "unknown_error"
    const reason = (obj as { reason?: string } | null)?.reason
    logError(status, code, reason)
  }
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", ...getCorsHeaders(origin) },
  })
}