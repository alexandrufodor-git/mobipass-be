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

export interface IngestResult {
  source_ref_id:   string | null
  status:          IngestStatus
  invite_id?:      string
  employee_pii_id?: string
  invite_status?:  string
  matched_user?:   string | null
  error?:          string
}

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

async function shapeRecord(
  db: RestClient,
  ctx: CompanyCtx,
  rec: RegesRecord,
): Promise<{ ok: true; item: RegesBatchItem } | { ok: false; result: IngestResult }> {
  const sourceRefId = rec?.referintaSalariat?.id ?? null
  if (!sourceRefId) {
    return { ok: false, result: { source_ref_id: null, status: "failed", error: "missing_source_ref_id" } }
  }
  const info = rec.info ?? {}
  if (!info.cnp || !info.nume || !info.prenume) {
    return { ok: false, result: { source_ref_id: sourceRefId, status: "failed", error: "missing_required_fields" } }
  }

  const cnp = info.cnp.trim()
  const validation = validateCnp(cnp)
  if (!validation.valid) {
    return {
      ok: false,
      result: { source_ref_id: sourceRefId, status: "failed", error: `invalid_cnp:${validation.reason}` },
    }
  }
  // Always derive DOB from CNP regardless of dataNastereSpecified.
  const dobIso = validation.dobIso ?? cnpToDob(cnp)
  if (!dobIso) {
    return { ok: false, result: { source_ref_id: sourceRefId, status: "failed", error: "dob_unresolvable" } }
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

export async function ingestRegesArray(
  db: RestClient,
  company: CompanyCtx,
  records: RegesRecord[],
): Promise<IngestResult[]> {
  const failed: IngestResult[] = []
  const batch:  RegesBatchItem[] = []

  for (const rec of records) {
    const shaped = await shapeRecord(db, company, rec)
    if (shaped.ok) batch.push(shaped.item)
    else failed.push(shaped.result)
  }

  if (batch.length === 0) return failed

  const rpcResult = await db.rpc<Array<{
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

  const ok: IngestResult[] = rpcResult.map((r) => ({
    source_ref_id:   r.source_ref_id,
    status:          r.status,
    invite_id:       r.invite_id,
    employee_pii_id: r.employee_pii_id,
    invite_status:   r.invite_status,
    matched_user:    r.matched_user,
  }))

  return [...ok, ...failed]
}
