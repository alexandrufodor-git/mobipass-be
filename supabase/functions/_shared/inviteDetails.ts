// Batch-fetch helper for `profile_invites_with_details`.
//
// Used by `bulk-create` (both CSV and REGES branches) so the per-record
// response item mirrors a row of the HR-dashboard view exactly. Keeping the
// shape aligned means the FE can reuse the same row type.
//
// One round-trip per upload: PostgREST `id=in.(<csv>)` → up to N rows.

import type { RestClient } from "./supabaseRest.ts"

// Mirrors `public.profile_invites_with_details` (security_invoker on).
// All fields are nullable on a freshly-created invite (no profile / bike
// rows joined yet), except `invite_id` which is the row PK.
export interface InviteDetails {
  invite_id:           string
  email:               string | null
  invite_status:       string | null
  invited_at:          string | null
  company_id:          string | null
  company_name:        string | null
  logo_image_path:     string | null
  user_id:             string | null
  profile_status:      string | null
  registered_at:       string | null
  profile_image_path:  string | null
  first_name:          string | null
  last_name:           string | null
  description:         string | null
  department:          string | null
  hire_date:           number | null
  bike_benefit_id:     string | null
  benefit_status:      string | null
  contract_status:     string | null
  last_modified_at:    string | null
  bike_id:             string | null
  order_id:            string | null
  source:              string | null
  radiat:              boolean | null
  derived_email:       string | null
}

// Returns an `invite_id → InviteDetails` map. Missing ids are simply absent
// from the map; callers handle that branch (e.g. failed CSV rows that never
// produced an invite).
export async function fetchInviteDetails(
  db: RestClient,
  inviteIds: string[],
): Promise<Map<string, InviteDetails>> {
  const map = new Map<string, InviteDetails>()
  const ids = inviteIds.filter((id): id is string => Boolean(id))
  if (ids.length === 0) return map

  // PostgREST `in.()` syntax — UUIDs are safe (no commas, parens, quotes).
  const filter = `invite_id=in.(${ids.join(",")})`
  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  const res = await fetch(
    `${supabaseUrl}/rest/v1/profile_invites_with_details?${filter}&select=*`,
    {
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey:        serviceKey!,
      },
    },
  )
  if (!res.ok) {
    console.error(`[inviteDetails] fetch_failed status=${res.status}`)
    return map
  }
  const rows = await res.json() as InviteDetails[]
  for (const row of rows) {
    if (row.invite_id) map.set(row.invite_id, row)
  }
  // Quiet fallback warning — we want to know if the view ever drops rows.
  if (map.size !== ids.length) {
    console.warn(`[inviteDetails] view_returned_fewer requested=${ids.length} got=${map.size}`)
  }
  // Suppress unused warning; db is reserved for a future direct-call refactor.
  void db
  return map
}
