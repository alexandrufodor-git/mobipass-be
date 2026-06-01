// Unified per-record response item for `bulk-create` (CSV + REGES branches).
//
// Fields mirror `profile_invites_with_details` (so the FE can reuse its
// dashboard row type) plus an outcome envelope (`status`, `invited`, `error`)
// and REGES-only metadata.
//
// `email` and `derived_email` are both nullable: CSV provides `email` (no
// derivation), REGES provides `derived_email` (`email` stays null until the
// employee claims the invite at `/register`).

import type { InviteDetails } from "./inviteDetails.ts"

export type BulkStatus =
  | "created"            // new invite row
  | "created_linked"     // REGES — invite linked to an existing profile by derived_email
  | "merged"             // REGES — PII merged into an existing employee_pii row
  | "updated"            // re-upload of an existing unclaimed invite
  | "skipped_claimed"    // re-upload of an already-claimed invite (no overwrite)
  | "already_exists"     // CSV duplicate email
  | "invalid_email"      // CSV row with malformed email
  | "missing_first_name" // CSV row missing firstName
  | "missing_last_name"  // CSV row missing lastName
  | "failed"             // REGES per-record validation failure (see error)

export interface BulkResult extends InviteDetails {
  status:  BulkStatus
  invited: boolean
  error?:  string

  // REGES-only — undefined for CSV rows.
  source_ref_id?:    string | null
  employee_pii_id?:  string | null
  matched_user?:     string | null
}
