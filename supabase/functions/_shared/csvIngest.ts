// CSV branch of bulk-create.
//
// Per-row validation, "already_exists" short-circuit on duplicate email,
// optional description/department/hire_date passthrough. `source='manual'`
// distinguishes CSV rows from REGES rows downstream.
//
// Response shape mirrors a `profile_invites_with_details` row plus an outcome
// envelope (`status`, `invited`, `error`). REGES uses the same shape, so the
// FE can render either branch with one row type.

import type { RestClient } from "./supabaseRest.ts"
import { parseCsv } from "./ioHelpers.ts"
import { fetchInviteDetails, type InviteDetails } from "./inviteDetails.ts"
import type { BulkResult } from "./bulkResult.ts"

export interface CsvRow {
  email:        string
  firstName:    string
  lastName:     string
  description?: string
  department?:  string
  hireDate?:    string
}

function parseHireDate(raw: string | undefined): number | null {
  if (!raw || !raw.trim()) return null
  const v = raw.trim()
  const asInt = parseInt(v, 10)
  if (!isNaN(asInt) && asInt > 0 && String(asInt) === v) {
    return asInt
  }
  const asDate = new Date(v)
  return isNaN(asDate.getTime()) ? null : asDate.getTime()
}

// Empty-but-typed view row for failed/rejected rows so the response shape is
// uniform. Caller may still set `email` for invalid_email cases — we copy the
// raw input so the FE can echo the offending value.
function emptyDetails(overrides: Partial<InviteDetails> = {}): InviteDetails {
  return {
    invite_id:          "",
    email:              null,
    invite_status:      null,
    invited_at:         null,
    company_id:         null,
    company_name:       null,
    logo_image_path:    null,
    user_id:            null,
    profile_status:     null,
    registered_at:      null,
    profile_image_path: null,
    first_name:         null,
    last_name:          null,
    description:        null,
    department:         null,
    hire_date:          null,
    bike_benefit_id:    null,
    benefit_status:     null,
    contract_status:    null,
    last_modified_at:   null,
    bike_id:            null,
    order_id:           null,
    source:             null,
    radiat:             null,
    derived_email:      null,
    ...overrides,
  }
}

export async function ingestCsv(
  db: RestClient,
  companyId: string,
  csv: string,
): Promise<BulkResult[]> {
  const rows = parseCsv<CsvRow>(csv, ["email", "firstName", "lastName"])

  // Track per-row intermediate state so we can do one batched view fetch at
  // the end (instead of N round-trips).
  type Stage =
    | { kind: "fail"; status: BulkResult["status"]; error?: string; details: InviteDetails }
    | { kind: "ok";   status: "created" | "already_exists"; inviteId: string; raw: InviteDetails }

  const stages: Stage[] = []

  for (const r of rows) {
    if (!r.email?.includes("@")) {
      stages.push({
        kind:    "fail",
        status:  "invalid_email",
        error:   "invalid_email",
        details: emptyDetails({ email: r.email ?? null }),
      })
      continue
    }
    if (!r.firstName?.trim()) {
      stages.push({
        kind:    "fail",
        status:  "missing_first_name",
        error:   "missing_first_name",
        details: emptyDetails({ email: r.email }),
      })
      continue
    }
    if (!r.lastName?.trim()) {
      stages.push({
        kind:    "fail",
        status:  "missing_last_name",
        error:   "missing_last_name",
        details: emptyDetails({ email: r.email, first_name: r.firstName.trim() }),
      })
      continue
    }

    const existing = await db.getOne<{ id: string }>(
      "profile_invites",
      `email=eq.${encodeURIComponent(r.email)}`,
      "id",
    )
    if (existing) {
      stages.push({
        kind:    "ok",
        status:  "already_exists",
        inviteId: existing.id,
        raw:     emptyDetails({ invite_id: existing.id, email: r.email }),
      })
      continue
    }

    const inviteData: Record<string, unknown> = {
      email:      r.email,
      company_id: companyId,
      first_name: r.firstName.trim(),
      last_name:  r.lastName.trim(),
      source:     "manual",
    }
    if (r.description?.trim()) inviteData.description = r.description.trim()
    if (r.department?.trim())  inviteData.department  = r.department.trim()
    const hireDate = parseHireDate(r.hireDate)
    if (hireDate !== null) inviteData.hire_date = hireDate

    const supabaseUrl = Deno.env.get("SUPABASE_URL")
    const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    const insertRes = await fetch(`${supabaseUrl}/rest/v1/profile_invites`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey:        serviceKey!,
        "Content-Type": "application/json",
        Prefer:        "return=representation",
      },
      body: JSON.stringify(inviteData),
    })
    const inserted = await insertRes.json()
    const newId = Array.isArray(inserted) && inserted[0]?.id ? inserted[0].id as string : ""
    if (!newId) {
      stages.push({
        kind:    "fail",
        status:  "failed",
        error:   "insert_failed",
        details: emptyDetails({ email: r.email, first_name: r.firstName.trim(), last_name: r.lastName.trim() }),
      })
      continue
    }

    stages.push({
      kind:    "ok",
      status:  "created",
      inviteId: newId,
      raw:     emptyDetails({
        invite_id:   newId,
        email:       r.email,
        first_name:  r.firstName.trim(),
        last_name:   r.lastName.trim(),
        description: (r.description?.trim() ?? null) || null,
        department:  (r.department?.trim() ?? null) || null,
        hire_date:   hireDate,
        source:      "manual",
        radiat:      false,
      }),
    })
  }

  // Batch-fetch view rows for everything we touched (created + already_exists).
  const inviteIds = stages
    .filter((s): s is Extract<Stage, { kind: "ok" }> => s.kind === "ok")
    .map((s) => s.inviteId)
  const view = await fetchInviteDetails(db, inviteIds)

  return stages.map<BulkResult>((s) => {
    if (s.kind === "fail") {
      return {
        ...s.details,
        status:  s.status,
        invited: false,
        error:   s.error,
      }
    }
    const details = view.get(s.inviteId) ?? s.raw
    return {
      ...details,
      status:  s.status,
      invited: s.status === "created",
    }
  })
}
