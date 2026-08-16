// Unit tests for the REGES claim-confidence model.
// Run with: deno test supabase/functions/_shared/regesScoring.test.ts
//
// The load-bearing case here is "no date of birth". Apple guideline 5.1.1(v)
// requires DOB to be optional at registration, so these tests pin the fact
// that a claim clears CLAIM_THRESHOLD on derived-email + name alone.

import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert"
import { CLAIM_THRESHOLD, score, type MatchCandidate } from "./regesScoring.ts"

function candidate(over: Partial<MatchCandidate> = {}): MatchCandidate {
  return {
    id: "00000000-0000-0000-0000-000000000000",
    radiat: false,
    email_derived_match: false,
    dob_matched: false,
    first_score: 0,
    last_score: 0,
    ...over,
  }
}

Deno.test("derived email + exact names clears the threshold without DOB", () => {
  const s = score(candidate({ email_derived_match: true, first_score: 1, last_score: 1 }))
  assertEquals(s, 0.7)
  assert(s >= CLAIM_THRESHOLD)
})

Deno.test("derived email + weak trigram names still clears the threshold without DOB", () => {
  const s = score(candidate({ email_derived_match: true, first_score: 0.5, last_score: 0.5 }))
  assertAlmostEquals(s, 0.575)
  assert(s >= CLAIM_THRESHOLD)
})

Deno.test("DOB only widens the margin, it does not decide the claim", () => {
  const withoutDob = score(candidate({ email_derived_match: true, first_score: 1, last_score: 1 }))
  const withDob = score(candidate({
    email_derived_match: true,
    dob_matched: true,
    first_score: 1,
    last_score: 1,
  }))
  assertEquals(withDob, 1)
  assert(withoutDob >= CLAIM_THRESHOLD)
  assert(withDob >= CLAIM_THRESHOLD)
})

Deno.test("derived email alone does not clear the threshold — names still carry weight", () => {
  const s = score(candidate({ email_derived_match: true }))
  assertEquals(s, 0.45)
  assert(s < CLAIM_THRESHOLD)
})

Deno.test("name + DOB without derived email scores above threshold but cannot claim", () => {
  // register/index.ts rejects any winner with email_derived_match=false
  // (422 check_details), so this score never converts into a claim. It is the
  // only thing DOB buys on this path: a better error message.
  const s = score(candidate({ dob_matched: true, first_score: 1, last_score: 1 }))
  assertAlmostEquals(s, 0.55)
  assert(s >= CLAIM_THRESHOLD)
})

Deno.test("score clamps sub-scores into [0, 1]", () => {
  assertEquals(score(candidate({ first_score: 5, last_score: 5 })), 0.25)
  assertEquals(score(candidate({ first_score: -3, last_score: -3 })), 0)
  assertEquals(
    score(candidate({
      email_derived_match: true,
      dob_matched: true,
      first_score: 9,
      last_score: 9,
    })),
    1,
  )
})
