// supabase/functions/update-employee-pii/index.ts
//
// Sole write path for employee_pii. Encrypts sensitive fields with the key
// from Vault (pii_encryption_key) before upsert.
//
// Auth: JWT required (verify_jwt = true).
//   - Employee: may patch own row only. Must omit `user_id` or pass own UUID.
//   - HR / admin: may patch any employee within the same company.
//
// Body:
//   {
//     user_id?: string,
//     patch: {
//       // encrypted at rest
//       national_id?:   string | null,
//       date_of_birth?: string | null,   // ISO 8601 "YYYY-MM-DD"
//       phone?:         string | null,
//       home_address?:  string | null,
//       home_lat?:      number | null,
//       home_lon?:      number | null,
//       salary_gross?:  number | null,
//       // plaintext metadata
//       country?:                 string | null,
//       nationality_iso?:         string | null,
//       country_of_domicile_iso?: string | null,
//       id_document_type?:        string | null,
//       locality_code?:           string | null,
//       locality_code_system?:    string | null,
//       salary_currency?:         string | null,
//       education_level?:         string | null,
//     }
//   }
//
// Semantics:
//   - `undefined` field → skip (no change).
//   - `null`           → clear the column.
//   - Every other value is validated and encrypted (for sensitive fields).
//
// Response: { ok: true }. Never echoes PII.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, badRequest, forbidden, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { requireJwt, extractUserId } from "../_shared/auth.ts"
import { makeRestClient, type RestClient } from "../_shared/supabaseRest.ts"
import { encrypt } from "../_shared/piiCrypto.ts"

// ─── Field catalogues ───────────────────────────────────────────────────────

const ENCRYPTED_FIELDS = [
  "national_id",
  "date_of_birth",
  "phone",
  "home_address",
  "home_lat",
  "home_lon",
  "salary_gross",
] as const

const PLAINTEXT_FIELDS = [
  "country",
  "nationality_iso",
  "country_of_domicile_iso",
  "id_document_type",
  "locality_code",
  "locality_code_system",
  "salary_currency",
  "education_level",
] as const

type EncryptedField = typeof ENCRYPTED_FIELDS[number]
type PlaintextField = typeof PLAINTEXT_FIELDS[number]

// ─── Validation ─────────────────────────────────────────────────────────────

const MAX_LEN: Record<string, number> = {
  national_id: 64,
  date_of_birth: 32,
  phone: 32,
  home_address: 500,
  country: 8,
  nationality_iso: 8,
  country_of_domicile_iso: 8,
  id_document_type: 32,
  locality_code: 32,
  locality_code_system: 32,
  salary_currency: 8,
  education_level: 32,
}

const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/

function invalidField(field: string, reason: string, origin?: string): Response {
  return badRequest({ error: "invalid_field" }, { field, reason }, origin)
}

type PatchValue = string | number | null | undefined

interface PatchBody {
  [k: string]: PatchValue
}

function validatePatch(patch: PatchBody, origin?: string): void {
  for (const key of Object.keys(patch)) {
    const val = patch[key]
    if (val === undefined || val === null) continue

    // Length cap for strings
    if (typeof val === "string" && MAX_LEN[key] && val.length > MAX_LEN[key]) {
      throw invalidField(key, `exceeds_max_length_${MAX_LEN[key]}`, origin)
    }

    if (key === "home_lat") {
      if (typeof val !== "number" || val < -90 || val > 90) throw invalidField(key, "out_of_range", origin)
    } else if (key === "home_lon") {
      if (typeof val !== "number" || val < -180 || val > 180) throw invalidField(key, "out_of_range", origin)
    } else if (key === "salary_gross") {
      if (typeof val !== "number" || val < 0) throw invalidField(key, "must_be_non_negative_number", origin)
    } else if (key === "date_of_birth") {
      if (typeof val !== "string" || !ISO_DATE_RE.test(val)) throw invalidField(key, "must_be_iso_date", origin)
      const d = new Date(val)
      if (isNaN(d.getTime())) throw invalidField(key, "invalid_date", origin)
    }
  }
}

// ─── Upsert payload builder ─────────────────────────────────────────────────

async function buildUpsertPayload(
  db: RestClient,
  targetUserId: string,
  companyId: string,
  patch: PatchBody,
): Promise<{ row: Record<string, unknown>; touchedFields: string[] }> {
  const row: Record<string, unknown> = {
    user_id: targetUserId,
    company_id: companyId,
  }
  const touched: string[] = []

  for (const field of ENCRYPTED_FIELDS as readonly EncryptedField[]) {
    const val = patch[field]
    if (val === undefined) continue
    touched.push(field)
    const col = `${field}_encrypted`
    if (val === null) {
      row[col] = null
    } else {
      const asString = typeof val === "number" ? String(val) : (val as string)
      row[col] = await encrypt(db, asString)
    }
  }

  for (const field of PLAINTEXT_FIELDS as readonly PlaintextField[]) {
    const val = patch[field]
    if (val === undefined) continue
    touched.push(field)
    row[field] = val
  }

  return { row, touchedFields: touched }
}

// ─── Handler ────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined

  if (req.method === "OPTIONS") return corsResponse(origin)
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, origin)

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    const db = makeRestClient(supabaseUrl, serviceKey)

    const jwt = requireJwt(req, origin)
    const callerId = extractUserId(jwt, origin)
    const callerRole = jwt.user_role as string | undefined

    const body = await req.json().catch(() => ({})) as {
      user_id?: string
      patch?: PatchBody
    }

    if (!body.patch || typeof body.patch !== "object" || Array.isArray(body.patch)) {
      throw badRequest({ error: "patch_required" }, undefined, origin)
    }

    // Reject unknown keys outright so clients can't smuggle arbitrary columns.
    const knownKeys = new Set<string>([...ENCRYPTED_FIELDS, ...PLAINTEXT_FIELDS])
    for (const key of Object.keys(body.patch)) {
      if (!knownKeys.has(key)) {
        throw badRequest({ error: "unknown_field" }, { field: key }, origin)
      }
    }

    validatePatch(body.patch, origin)

    // Resolve target user + authorization
    let targetUserId = callerId
    if (body.user_id && body.user_id !== callerId) {
      if (callerRole !== "hr" && callerRole !== "admin") {
        throw forbidden(undefined, origin)
      }
      targetUserId = body.user_id
    }

    // Need target's company_id for the upsert (required NOT NULL column on first insert).
    const targetProfile = await db.getOne<{ company_id: string }>(
      "profiles",
      `user_id=eq.${encodeURIComponent(targetUserId)}`,
      "company_id"
    )
    if (!targetProfile) throw badRequest(Errors.PROFILE_NOT_FOUND, undefined, origin)

    // HR/admin cross-user: enforce same-company.
    if (targetUserId !== callerId) {
      const callerProfile = await db.getOne<{ company_id: string }>(
        "profiles",
        `user_id=eq.${encodeURIComponent(callerId)}`,
        "company_id"
      )
      if (!callerProfile || callerProfile.company_id !== targetProfile.company_id) {
        throw forbidden(undefined, origin)
      }
    }

    const { row, touchedFields } = await buildUpsertPayload(
      db,
      targetUserId,
      targetProfile.company_id,
      body.patch
    )

    if (touchedFields.length === 0) {
      // Patch had only undefineds — no-op but still a 200. Don't write a row.
      return json({ ok: true, updated_fields: [] }, 200, origin)
    }

    // employee_pii.user_id has a partial unique index (WHERE user_id IS NOT NULL)
    // to allow REGES-staged rows with user_id=NULL. PostgREST's `on_conflict=`
    // can't target a partial index, so we do the upsert manually: SELECT
    // existing → PATCH, else POST.
    const existing = await db.getOne<{ id: string }>(
      "employee_pii",
      `user_id=eq.${encodeURIComponent(targetUserId)}`,
      "id",
    )

    let res: Response
    if (existing) {
      res = await fetch(`${supabaseUrl}/rest/v1/employee_pii?id=eq.${existing.id}`, {
        method: "PATCH",
        headers: {
          Authorization: `Bearer ${serviceKey}`,
          apikey: serviceKey,
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify(row),
      })
    } else {
      res = await fetch(`${supabaseUrl}/rest/v1/employee_pii`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceKey}`,
          apikey: serviceKey,
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify(row),
      })
    }

    if (!res.ok) {
      const text = await res.text().catch(() => "")
      console.error("[update-employee-pii] write failed:", res.status, text)
      throw json({ error: "upsert_failed" }, 500, origin)
    }

    console.log("[update-employee-pii] updated user", targetUserId, "fields:", touchedFields.join(","))
    return json({ ok: true, updated_fields: touchedFields }, 200, origin)
  } catch (e) {
    if (e instanceof Response) return e
    console.error("[update-employee-pii] unexpected error:", e)
    throw e
  }
})
