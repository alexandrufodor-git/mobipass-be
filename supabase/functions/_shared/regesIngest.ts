// REGES JSON branch of bulk-create.
//
// The edge function does per-record validation, normalization, encryption,
// blind-index hashing, and email-pattern derivation in the runtime (so the
// encryption key never leaves the function). Then everything is handed to
// ingest_reges_batch() as a single jsonb array for one transactional DB
// write.
//
// Production batches (1000+ employees) finish well inside the 150 s edge
// function timeout because the round trips are amortized: N crypto ops in
// the runtime + 1 DB call.

import type { RestClient } from "./supabaseRest.ts"
import { encrypt } from "./piiCrypto.ts"
import { birthDateHash } from "./piiLookup.ts"
import { cnpToDob, validateCnp } from "./cnpValidator.ts"
import {
  firstGivenToken,
  mapCountryName,
  mapIdDocType,
  middleGivenTokens,
} from "./regesMapping.ts"
import { derivePatternEmail, type EmailPatternKind } from "./emailPattern.ts"
import { fetchInviteDetails, type InviteDetails } from "./inviteDetails.ts"
import type { BulkResult } from "./bulkResult.ts"

// REGES `info` block as it appears in the JSON export.
export interface RegesInfo {
  cnp?:                  string
  nume?:                 string
  prenume?:              string
  adresa?:               string
  localitate?:           { codSiruta?: number | string }
  nationalitate?:        { nume?: string }
  taraDomiciliu?:        { nume?: string }
  tipActIdentitate?:     string
  radiat?:               boolean
  dataNastereSpecified?: boolean
}

export interface RegesRecord {
  referintaSalariat: { id: string }
  info:              RegesInfo
}

// PII outcome codes returned by ingest_reges_batch (per record):
//   created          — new staged row (user_id=NULL). Trigger backfills on
//                      first OTP signup.
//   created_linked   — new row written with user_id of an already-registered
//                      profile that matched derived_email (no staged state).
//   merged           — matched user already had a PII row (e.g. HR who
//                      filled their own PII first); REGES fields merged in
//                      without overwriting non-null user-entered values.
//   updated          — re-upload of a previously-imported REGES row, still
//                      unclaimed.
//   skipped_claimed  — re-upload of a previously-imported REGES row that has
//                      since been claimed by a registered user; we don't
//                      overwrite live data.
//   failed           — per-record shape/validation error (set by edge code).
export type IngestStatus =
  | "created"
  | "created_linked"
  | "merged"
  | "updated"
  | "skipped_claimed"
  | "failed"

// One fully-prepared record handed to ingest_reges_batch().
interface RegesBatchItem {
  source_ref_id:           string
  first_name:              string
  last_name:               string
  birth_date_hash:         string | null
  derived_email:           string | null
  radiat:                  boolean
  national_id_encrypted:   string
  home_address_encrypted:  string | null
  date_of_birth_encrypted: string
  locality_code:           string | null
  locality_code_system:    string | null
  nationality_iso:         string | null
  country_of_domicile_iso: string | null
  id_document_type:        string | null
}

// Caller-supplied company context. The bulk-create handler resolves these
// fields up front and is responsible for enforcing preconditions (e.g. that
// email_domain is configured before a REGES upload is accepted). Keeping the
// policy check out of this helper avoids the anti-pattern of `throw new
// Error("CODE")` -> string-match-in-catch downstream.
export interface CompanyCtx {
  id:             string
  email_domain:   string
  email_pattern:  EmailPatternKind | null
}

// Failure shape used by `shapeRecord` — minimal info to build a `BulkResult`
// for failed rows in the final response.
interface ShapeFailure {
  source_ref_id: string | null
  error:         string
  first_name?:   string | null
  last_name?:    string | null
}

async function shapeRecord(
  db: RestClient,
  ctx: CompanyCtx,
  rec: RegesRecord,
): Promise<{ ok: true; item: RegesBatchItem } | { ok: false; result: ShapeFailure }> {
  const sourceRefId = rec?.referintaSalariat?.id ?? null
  if (!sourceRefId) {
    return { ok: false, result: { source_ref_id: null, error: "missing_source_ref_id" } }
  }
  const info = rec.info ?? {}
  if (!info.cnp || !info.nume || !info.prenume) {
    return {
      ok: false,
      result: {
        source_ref_id: sourceRefId,
        error:         "missing_required_fields",
        first_name:    info.prenume?.trim() ?? null,
        last_name:     info.nume?.trim()    ?? null,
      },
    }
  }

  const cnp = info.cnp.trim()
  const validation = validateCnp(cnp)
  if (!validation.valid) {
    return {
      ok: false,
      result: {
        source_ref_id: sourceRefId,
        error:         `invalid_cnp:${validation.reason}`,
        first_name:    info.prenume.trim(),
        last_name:     info.nume.trim(),
      },
    }
  }
  // Always derive DOB from CNP regardless of dataNastereSpecified.
  const dobIso = validation.dobIso ?? cnpToDob(cnp)
  if (!dobIso) {
    return {
      ok: false,
      result: {
        source_ref_id: sourceRefId,
        error:         "dob_unresolvable",
        first_name:    info.prenume.trim(),
        last_name:     info.nume.trim(),
      },
    }
  }

  const first = info.prenume.trim()
  const last  = info.nume.trim()

  const derivedEmail = derivePatternEmail(ctx.email_pattern, {
    first:  firstGivenToken(first),
    middle: middleGivenTokens(first),
    last,
    domain: ctx.email_domain,
  })

  const dobHash = await birthDateHash(db, dobIso)

  const nationalIdEnc = await encrypt(db, cnp)
  const dobEnc        = await encrypt(db, dobIso)
  const addrEnc       = info.adresa && info.adresa.trim()
    ? await encrypt(db, info.adresa.trim())
    : null

  const localityCode = info.localitate?.codSiruta != null
    ? String(info.localitate.codSiruta)
    : null

  const item: RegesBatchItem = {
    source_ref_id:           sourceRefId,
    first_name:              first,
    last_name:               last,
    birth_date_hash:         dobHash,
    derived_email:           derivedEmail,
    radiat:                  info.radiat === true,
    national_id_encrypted:   nationalIdEnc,
    home_address_encrypted:  addrEnc,
    date_of_birth_encrypted: dobEnc,
    locality_code:           localityCode,
    locality_code_system:    localityCode ? "siruta" : null,
    nationality_iso:         mapCountryName(info.nationalitate?.nume),
    country_of_domicile_iso: mapCountryName(info.taraDomiciliu?.nume),
    id_document_type:        mapIdDocType(info.tipActIdentitate),
  }
  return { ok: true, item }
}

// Empty view-shaped row used as a fallback for failed records (no invite was
// created → nothing to fetch from the view) and for the rare case where the
// view returns fewer rows than requested.
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

// Outcomes that imply we wrote (or kept) an invite row — used to set
// `invited: true` in the unified response.
const INVITED_STATUSES: ReadonlySet<IngestStatus> = new Set([
  "created",
  "created_linked",
  "merged",
  "updated",
])

export async function ingestRegesArray(
  db: RestClient,
  company: CompanyCtx,
  records: RegesRecord[],
): Promise<BulkResult[]> {
  const failed: ShapeFailure[]    = []
  const batch:  RegesBatchItem[]  = []

  for (const rec of records) {
    const shaped = await shapeRecord(db, company, rec)
    if (shaped.ok) batch.push(shaped.item)
    else failed.push(shaped.result)
  }

  // RPC outputs aligned 1:1 with the batch input. `invite_status` is the
  // RPC's invite-operation outcome (created/updated/skipped_claimed/...) —
  // distinct from the view's `invite_status` column (DB enum
  // 'inactive'/'active'). We only surface the view's value in the response
  // to avoid the name collision.
  const rpcResult = batch.length === 0 ? [] : await db.rpc<Array<{
    source_ref_id:   string
    status:          IngestStatus
    invite_id:       string
    employee_pii_id: string
    invite_status:   string
    matched_user:    string | null
  }>>("ingest_reges_batch", {
    p_company_id: company.id,
    p_records:    batch,
  })

  // Batch-fetch one view row per created/updated/merged invite. Ordering is
  // preserved by mapping back via source_ref_id below.
  const inviteIds = rpcResult.map((r) => r.invite_id).filter((id) => Boolean(id))
  const view      = await fetchInviteDetails(db, inviteIds)

  // Map source_ref_id → batch item so we can fall back on locally-prepared
  // values (first/last/derived_email) if the view ever drops a row.
  const localBySourceRef = new Map<string, RegesBatchItem>()
  for (const item of batch) localBySourceRef.set(item.source_ref_id, item)

  const ok: BulkResult[] = rpcResult.map((r) => {
    const local   = localBySourceRef.get(r.source_ref_id)
    const details = view.get(r.invite_id) ?? emptyDetails({
      invite_id:     r.invite_id,
      first_name:    local?.first_name    ?? null,
      last_name:     local?.last_name     ?? null,
      derived_email: local?.derived_email ?? null,
      radiat:        local?.radiat        ?? null,
      source:        "reges",
      company_id:    company.id,
    })
    return {
      ...details,
      status:           r.status,
      invited:          INVITED_STATUSES.has(r.status),
      source_ref_id:    r.source_ref_id,
      employee_pii_id:  r.employee_pii_id,
      matched_user:     r.matched_user,
    }
  })

  const failures: BulkResult[] = failed.map((f) => ({
    ...emptyDetails({
      first_name: f.first_name ?? null,
      last_name:  f.last_name  ?? null,
      source:     "reges",
      company_id: company.id,
    }),
    status:        "failed",
    invited:       false,
    error:         f.error,
    source_ref_id: f.source_ref_id,
  }))

  return [...ok, ...failures]
}
