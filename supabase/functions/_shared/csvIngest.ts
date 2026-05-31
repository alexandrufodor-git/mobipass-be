// CSV branch of bulk-create, extracted into a reusable helper so the edge
// function can dispatch on content type while CSV and REGES paths share the
// same return shape.
//
// Behavior is intentionally identical to the original bulk-create body:
// per-row validation, "already_exists" short-circuit on duplicate email,
// optional description/department/hire_date passthrough. Adds source='manual'
// on insert so REGES rows can be distinguished downstream.

import type { RestClient } from "./supabaseRest.ts"
import { parseCsv } from "./ioHelpers.ts"

export interface CsvRow {
  email:        string
  firstName:    string
  lastName:     string
  description?: string
  department?:  string
  hireDate?:    string
}

export interface CsvResult {
  email:    string
  invited:  boolean
  status?:  string
  error?:   string
  body?:    unknown
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

export async function ingestCsv(
  db: RestClient,
  companyId: string,
  csv: string,
): Promise<CsvResult[]> {
  const rows = parseCsv<CsvRow>(csv, ["email", "firstName", "lastName"])
  const results: CsvResult[] = []

  for (const r of rows) {
    if (!r.email?.includes("@")) {
      results.push({ email: r.email, invited: false, error: "invalid_email" })
      continue
    }
    if (!r.firstName?.trim()) {
      results.push({ email: r.email, invited: false, error: "missing_first_name" })
      continue
    }
    if (!r.lastName?.trim()) {
      results.push({ email: r.email, invited: false, error: "missing_last_name" })
      continue
    }

    const existing = await db.getOne<{ id: string }>(
      "profile_invites",
      `email=eq.${encodeURIComponent(r.email)}`,
      "id",
    )
    if (existing) {
      results.push({ email: r.email, invited: false, status: "already_exists" })
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

    const body = await insertRes.json()
    results.push({ email: r.email, invited: true, body })
  }

  return results
}
