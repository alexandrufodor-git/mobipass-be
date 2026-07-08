// Passwordless registration with REGES-pending-invite claim.
//
// Two paths, chosen by what's already in profile_invites:
//
//   1. email-direct
//      The supplied email already exists on a profile_invites row. This is
//      the legacy CSV flow + the already-claimed REGES re-registration case.
//      We just send the OTP. No extra inputs needed.
//
//   2. confidence-claim
//      The email does NOT exist on any invite. The caller must supply
//      first_name, last_name, date_of_birth. We resolve the company by
//      email_domain, query match_pending_invite, score the candidates with
//      a simple weighted sum, and either:
//        - claim a single pending invite (UPDATE its email + send OTP), or
//        - return 409 ambiguous_match, or
//        - return 403 invite_inactive (radiat=true), or
//        - return 403 not_invited.
//
// Every attempt — success or failure — writes one integration_messages row
// for audit. The audit row contains hashes + normalized names + email
// domain only; no plaintext PII (no full email, no DOB, no CNP).
//
// Tuning notes for future iterations: the weight constants below were
// chosen so that a derived-email + DOB hit caps at 1.0, and a name + DOB
// hit (no derived email) lands around 0.55 — comfortably above the 0.50
// claim threshold but with room to widen. Mobile Maestro flows will surface
// real-user edge cases that should drive tuning, not synthetic tests here.

import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { Errors, badRequest, json } from "../_shared/constants.ts"
import { corsResponse } from "../_shared/ioHelpers.ts"
import { makeRestClient, type RestClient } from "../_shared/supabaseRest.ts"
import { birthDateHash } from "../_shared/piiLookup.ts"
import { normalizeName } from "../_shared/regesMapping.ts"
import { score, CLAIM_THRESHOLD, type MatchCandidate } from "../_shared/regesScoring.ts"

interface RegisterBody {
  email?:         string
  first_name?:    string
  last_name?:     string
  middle_name?:   string
  date_of_birth?: string  // ISO YYYY-MM-DD
}

// A match_pending_invite candidate plus its computed weighted score.
type ScoredCandidate = MatchCandidate & { total: number }

async function sendOtp(supabaseUrl: string, serviceKey: string, email: string): Promise<Response> {
  return await fetch(`${supabaseUrl}/auth/v1/otp`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceKey}`,
      apikey: serviceKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ email, create_user: true }),
  })
}

// Onboarding (handle_user_registration) only fires on an auth.users INSERT or
// the first email_confirmed_at NULL→confirmed transition. A pre-existing,
// already-confirmed auth account with NO profile is "orphaned": an OTP login
// against it just mints a session and never re-runs onboarding, leaving a
// profile-less user the app can't use. Before sending the OTP, delete such an
// account so the OTP-verify creates a fresh row that fires the trigger.
//
// Only accounts with NO profile are deleted — an orphan has zero app-side data,
// so this is safe; returning users (has_profile=true) and brand-new emails
// (no auth row) are left untouched. Best-effort + fail-open: any failure here
// is logged and swallowed so the OTP still goes out — this guard can never make
// registration worse than it is today.
// Returns true iff a stale orphan was found and deleted — the caller stamps
// this into the audit row (result_payload.orphan_reset) so "was this user
// orphaned and auto-healed?" is answerable from integration_messages.
async function resetStaleOrphan(
  db: RestClient,
  supabaseUrl: string,
  serviceKey: string,
  email: string,
): Promise<boolean> {
  try {
    const hits = await db.rpc<Array<{ user_id: string; has_profile: boolean }>>(
      "lookup_auth_user",
      { p_email: email },
    )
    const existing = hits?.[0]
    if (!existing || existing.has_profile) return false

    const res = await fetch(`${supabaseUrl}/auth/v1/admin/users/${existing.user_id}`, {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
        "Content-Type": "application/json",
      },
    })
    if (!res.ok) {
      console.error("[register] stale-orphan delete failed:", res.status, await res.text().catch(() => ""))
      return false
    }
    console.log(`[register] reset stale orphan auth user ${existing.user_id}`)
    return true
  } catch (err) {
    console.error("[register] stale-orphan reset skipped (non-fatal):", err)
    return false
  }
}

async function auditAttempt(
  db: RestClient,
  payload: {
    company_id:    string | null
    decision:      string
    claim_type:    string | null
    invite_id:     string | null
    email_domain:  string | null
    dob_hash:      string | null
    first_norm:    string | null
    last_norm:     string | null
    orphan_reset?: boolean
    candidates:    Array<{
      invite_id:           string
      first_score:         number
      last_score:          number
      dob_matched:         boolean
      email_derived_match: boolean
      total:               number
    }>
  },
) {
  // company_id may legitimately be null when the email domain doesn't map
  // to any company — skip the audit row in that case rather than violate
  // integration_messages.company_id NOT NULL. The HTTP response still tells
  // the caller what happened.
  if (!payload.company_id) return
  try {
    await db.post("integration_messages", {
      company_id:     payload.company_id,
      integration:    "reges",
      operation:      "register_attempt",
      entity_type:    "profile_invites",
      entity_id:      payload.invite_id,
      direction:      "inbound",
      status:         payload.decision === "claim" ? "success" : "failure",
      result_code:    payload.decision,
      result_payload: {
        claim_type:   payload.claim_type,
        email_domain: payload.email_domain,
        dob_hash:     payload.dob_hash,
        first_norm:   payload.first_norm,
        last_norm:    payload.last_norm,
        orphan_reset: payload.orphan_reset ?? false,
        candidates:   payload.candidates.slice(0, 5),
      },
      processed_at:   new Date().toISOString(),
    })
  } catch (err) {
    console.error("[register] audit write failed:", err)
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || undefined
  if (req.method === "OPTIONS") return corsResponse(origin)

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
  const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  const db = makeRestClient(SUPABASE_URL, SERVICE_KEY)

  const body = await req.json().catch(() => ({})) as RegisterBody
  const email = (body.email || "").trim()
  if (!email || !email.includes("@")) {
    return badRequest(Errors.EMAIL_REQUIRED, undefined, origin)
  }
  const emailLower = email.toLowerCase()
  const emailDomain = emailLower.split("@")[1] || null

  // ──────────────────────────────────────────────────────────────────────
  // Path 1: email-direct (CSV invite or already-claimed REGES)
  // ──────────────────────────────────────────────────────────────────────
  const direct = await db.getOne<{ id: string; company_id: string; radiat: boolean }>(
    "profile_invites",
    `email=ilike.${encodeURIComponent(emailLower)}`,
    "id,company_id,radiat",
  )
  if (direct) {
    if (direct.radiat) {
      await auditAttempt(db, {
        company_id: direct.company_id, decision: "inactive", claim_type: null,
        invite_id: direct.id, email_domain: emailDomain,
        dob_hash: null, first_norm: null, last_norm: null, candidates: [],
      })
      return json(Errors.INVITE_INACTIVE, 403, origin)
    }

    const orphanReset = await resetStaleOrphan(db, SUPABASE_URL, SERVICE_KEY, email)
    const otp = await sendOtp(SUPABASE_URL, SERVICE_KEY, email)
    if (!otp.ok) {
      const details = await otp.json().catch(() => ({}))
      return json({ ...Errors.OTP_FAILED, details }, 500, origin)
    }
    await auditAttempt(db, {
      company_id: direct.company_id, decision: "claim", claim_type: "email_direct",
      invite_id: direct.id, email_domain: emailDomain,
      dob_hash: null, first_norm: null, last_norm: null, orphan_reset: orphanReset, candidates: [],
    })
    return json({ success: true, claim: "email_direct" }, 200, origin)
  }

  // ──────────────────────────────────────────────────────────────────────
  // Path 2: confidence-claim against pending REGES invites
  // ──────────────────────────────────────────────────────────────────────
  const firstNorm = normalizeName(body.first_name)
  const lastNorm  = normalizeName(body.last_name)
  const dob       = (body.date_of_birth || "").trim() || null

  if (!firstNorm || !lastNorm || !dob) {
    // Without the supplemental identity fields we have nothing to match
    // against. Treat as not-invited rather than 400 — the legacy mobile
    // client (email only) gets a clear "not_invited" instead of a confusing
    // validation error.
    await auditAttempt(db, {
      company_id: null, decision: "not_invited", claim_type: null,
      invite_id: null, email_domain: emailDomain,
      dob_hash: null, first_norm: null, last_norm: null, candidates: [],
    })
    return json(Errors.NOT_INVITED, 403, origin)
  }

  // Resolve company by email_domain (case-insensitive).
  if (!emailDomain) {
    return json(Errors.NOT_INVITED, 403, origin)
  }
  const company = await db.getOne<{ id: string }>(
    "companies",
    `email_domain=ilike.${encodeURIComponent(emailDomain)}`,
    "id",
  )
  if (!company) {
    await auditAttempt(db, {
      company_id: null, decision: "company_not_found", claim_type: null,
      invite_id: null, email_domain: emailDomain,
      dob_hash: null, first_norm: firstNorm, last_norm: lastNorm, candidates: [],
    })
    return json(Errors.COMPANY_NOT_FOUND_FOR_DOMAIN, 404, origin)
  }

  const dobHash = await birthDateHash(db, dob)

  const raw = await db.rpc<MatchCandidate[]>("match_pending_invite", {
    p_company_id:  company.id,
    p_dob_hash:    dobHash,
    p_first_norm:  firstNorm,
    p_last_norm:   lastNorm,
    p_email_lower: emailLower,
  })

  const scored: ScoredCandidate[] = raw.map((c) => ({ ...c, total: score(c) }))
  const above = scored.filter((c) => c.total >= CLAIM_THRESHOLD)

  const auditCandidates = scored.map((c) => ({
    invite_id:           c.id,
    first_score:         c.first_score,
    last_score:          c.last_score,
    dob_matched:         c.dob_matched,
    email_derived_match: c.email_derived_match,
    total:               c.total,
  }))

  if (above.length === 0) {
    await auditAttempt(db, {
      company_id: company.id, decision: "not_invited", claim_type: null,
      invite_id: null, email_domain: emailDomain,
      dob_hash: dobHash, first_norm: firstNorm, last_norm: lastNorm,
      candidates: auditCandidates,
    })
    return json(Errors.NOT_INVITED, 403, origin)
  }

  if (above.length > 1) {
    await auditAttempt(db, {
      company_id: company.id, decision: "ambiguous", claim_type: null,
      invite_id: null, email_domain: emailDomain,
      dob_hash: dobHash, first_norm: firstNorm, last_norm: lastNorm,
      candidates: auditCandidates,
    })
    return json(Errors.AMBIGUOUS_MATCH, 409, origin)
  }

  const winner = above[0]
  if (winner.radiat) {
    await auditAttempt(db, {
      company_id: company.id, decision: "inactive", claim_type: null,
      invite_id: winner.id, email_domain: emailDomain,
      dob_hash: dobHash, first_norm: firstNorm, last_norm: lastNorm,
      candidates: auditCandidates,
    })
    return json(Errors.INVITE_INACTIVE, 403, origin)
  }

  // The email is both a match signal AND the OTP delivery target. When the
  // claim rode on name + DOB but the typed email doesn't match the derived
  // pattern (email_derived_match=false), sending the OTP to that address would
  // deliver it somewhere the user can't reach — and patching the invite to it
  // would overwrite the good derived email. Stop and ask the user to recheck.
  // The response stays generic (no email echoed): revealing the expected
  // address would confirm a person with this name + DOB exists.
  if (!winner.email_derived_match) {
    await auditAttempt(db, {
      company_id: company.id, decision: "check_details", claim_type: null,
      invite_id: winner.id, email_domain: emailDomain,
      dob_hash: dobHash, first_norm: firstNorm, last_norm: lastNorm,
      candidates: auditCandidates,
    })
    return json(Errors.CHECK_DETAILS, 422, origin)
  }

  // Claim: set the email on the chosen invite so the registration trigger
  // picks it up on OTP verify.
  await db.patch("profile_invites", `id=eq.${winner.id}`, { email })

  const orphanReset = await resetStaleOrphan(db, SUPABASE_URL, SERVICE_KEY, email)
  const otp = await sendOtp(SUPABASE_URL, SERVICE_KEY, email)
  if (!otp.ok) {
    const details = await otp.json().catch(() => ({}))
    return json({ ...Errors.OTP_FAILED, details }, 500, origin)
  }

  const claimType = winner.email_derived_match ? "derived" : "name"
  await auditAttempt(db, {
    company_id: company.id, decision: "claim", claim_type: claimType,
    invite_id: winner.id, email_domain: emailDomain,
    dob_hash: dobHash, first_norm: firstNorm, last_norm: lastNorm,
    orphan_reset: orphanReset, candidates: auditCandidates,
  })
  return json({ success: true, claim: claimType, confidence: winner.total }, 200, origin)
})
