// Shared profile_invites upsert used by both CSV (manual) and REGES branches
// of the bulk-create edge function.
//
// CSV path (source='manual'):
//   - Conflict target is the partial unique index on lower(email).
//   - If a row already exists for that email, return action='skipped_claimed'.
//   - Otherwise insert and return 'created'.
//
// REGES path (source='reges'):
//   - Conflict target is (company_id, source, source_ref_id).
//   - If the existing row has email IS NOT NULL the employee already claimed
//     the invite; we never overwrite a claimed invite, so return
//     'skipped_claimed'.
//   - Otherwise update mutable fields and return 'updated'.
//
// Note: the production REGES batch flow runs through the
// ingest_reges_batch() PL/pgSQL function for single-round-trip performance;
// this helper is here for one-off REGES record paths (e.g. reconciliation
// scripts, future webhook handlers) so the semantics stay in one place.

import type { RestClient } from "./supabaseRest.ts"

export interface InviteSeed {
  company_id:       string
  email:            string | null
  first_name:       string
  last_name:        string
  description?:     string | null
  department?:      string | null
  hire_date?:       number | null
  source:           "manual" | "reges"
  source_ref_id?:   string | null
  birth_date_hash?: string | null
  derived_email?:   string | null
  radiat?:          boolean
}

export type UpsertAction = "created" | "updated" | "skipped_claimed"

export interface UpsertResult {
  invite_id: string
  action:    UpsertAction
}

// PostgREST helper — fetch a single row's id by an arbitrary filter.
async function fetchInviteId(
  db: RestClient,
  filter: string,
): Promise<{ id: string; email: string | null } | null> {
  return await db.getOne<{ id: string; email: string | null }>(
    "profile_invites",
    filter,
    "id,email",
  )
}

export async function upsertInvite(
  db: RestClient,
  seed: InviteSeed,
): Promise<UpsertResult> {
  if (seed.source === "manual") {
    if (!seed.email) {
      throw new Error("upsertInvite: manual source requires email")
    }
    const lower = seed.email.toLowerCase()
    const existing = await fetchInviteId(
      db,
      `email=ilike.${encodeURIComponent(lower)}`,
    )
    if (existing) {
      return { invite_id: existing.id, action: "skipped_claimed" }
    }
    const body: Record<string, unknown> = {
      company_id: seed.company_id,
      email:      seed.email,
      first_name: seed.first_name,
      last_name:  seed.last_name,
      source:     "manual",
    }
    if (seed.description) body.description = seed.description
    if (seed.department)  body.department  = seed.department
    if (seed.hire_date != null) body.hire_date = seed.hire_date

    const res = await fetch(
      `${Deno.env.get("SUPABASE_URL")}/rest/v1/profile_invites`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
          apikey:        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
          "Content-Type": "application/json",
          Prefer:        "return=representation",
        },
        body: JSON.stringify(body),
      },
    )
    if (!res.ok) {
      throw new Error(`insert profile_invites failed: ${res.status} ${await res.text()}`)
    }
    const rows = await res.json() as Array<{ id: string }>
    return { invite_id: rows[0].id, action: "created" }
  }

  // REGES path
  if (!seed.source_ref_id) {
    throw new Error("upsertInvite: reges source requires source_ref_id")
  }
  const filter =
    `company_id=eq.${seed.company_id}` +
    `&source=eq.reges` +
    `&source_ref_id=eq.${encodeURIComponent(seed.source_ref_id)}`
  const existing = await fetchInviteId(db, filter)

  if (!existing) {
    const body: Record<string, unknown> = {
      company_id:      seed.company_id,
      email:           null,
      first_name:      seed.first_name,
      last_name:       seed.last_name,
      source:          "reges",
      source_ref_id:   seed.source_ref_id,
      birth_date_hash: seed.birth_date_hash ?? null,
      derived_email:   seed.derived_email   ?? null,
      radiat:          seed.radiat ?? false,
    }
    const res = await fetch(
      `${Deno.env.get("SUPABASE_URL")}/rest/v1/profile_invites`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
          apikey:        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
          "Content-Type": "application/json",
          Prefer:        "return=representation",
        },
        body: JSON.stringify(body),
      },
    )
    if (!res.ok) {
      throw new Error(`insert profile_invites (reges) failed: ${res.status} ${await res.text()}`)
    }
    const rows = await res.json() as Array<{ id: string }>
    return { invite_id: rows[0].id, action: "created" }
  }

  if (existing.email !== null) {
    return { invite_id: existing.id, action: "skipped_claimed" }
  }

  await db.patch(
    "profile_invites",
    `id=eq.${existing.id}`,
    {
      first_name:      seed.first_name,
      last_name:       seed.last_name,
      birth_date_hash: seed.birth_date_hash ?? null,
      derived_email:   seed.derived_email   ?? null,
      radiat:          seed.radiat ?? false,
    },
  )
  return { invite_id: existing.id, action: "updated" }
}
