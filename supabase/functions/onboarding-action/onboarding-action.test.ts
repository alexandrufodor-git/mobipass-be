// Unit tests for onboarding-action decisions.
// Run with: deno test supabase/functions/onboarding-action/onboarding-action.test.ts
//
// Each expected patch is what the mobile app wrote directly before this function
// (DashboardViewModel / EBikeViewModel / ProfileViewModel). New: copilot stop on
// commit, confirm_test, and the copilot lock.

import { assertEquals } from "jsr:@std/assert"
import { ACTIONS, ActionBenefit, Copilot, decide, isAction } from "./actions.ts"

const NOW = "2026-09-29T10:00:00.000Z"
const BIKE = "11111111-1111-1111-1111-111111111111"

function copilot(over: Partial<Copilot> = {}): Copilot {
  return { enabled: true, live_test_at: null, live_test_label: null, test_confirmable: false, locked: false, ...over }
}

function benefit(over: Partial<ActionBenefit> = {}): ActionBenefit {
  return { step: "choose_bike", live_test_sent_at: null, copilot: null, ...over }
}

const NO_COPILOT = benefit()

// ─── Today's writes (no copilot) ─────────────────────────────────────────────

Deno.test("start → choose_bike", () => {
  assertEquals(decide("start", NO_COPILOT, {}, NOW), { patch: { step: "choose_bike" } })
})

Deno.test("choose_bike_for_test → bike + book_live_test", () => {
  assertEquals(decide("choose_bike_for_test", NO_COPILOT, { bike_id: BIKE }, NOW), { patch: { bike_id: BIKE, step: "book_live_test" } })
})

Deno.test("test_interest → live_test_sent_at only, stays on step 2", () => {
  assertEquals(decide("test_interest", NO_COPILOT, {}, NOW), { patch: { live_test_sent_at: NOW } })
})

Deno.test("commit_from_details → bike + commit_to_bike, no committed_at", () => {
  assertEquals(decide("commit_from_details", NO_COPILOT, { bike_id: BIKE }, NOW), { patch: { bike_id: BIKE, step: "commit_to_bike" } })
})

Deno.test("commit, no copilot → committed_at + sign_contract", () => {
  assertEquals(decide("commit", NO_COPILOT, {}, NOW), { patch: { committed_at: NOW, step: "sign_contract" } })
})

Deno.test("commit, copilot present but disabled → sign_contract", () => {
  const b = benefit({ copilot: copilot({ enabled: false }) })
  assertEquals(decide("commit", b, {}, NOW), { patch: { committed_at: NOW, step: "sign_contract" } })
})

Deno.test("confirm_pickup → delivered_at", () => {
  assertEquals(decide("confirm_pickup", NO_COPILOT, {}, NOW), { patch: { delivered_at: NOW } })
})

Deno.test("reset → choose_bike", () => {
  assertEquals(decide("reset", NO_COPILOT, {}, NOW), { patch: { step: "choose_bike" } })
})

Deno.test("disabled copilot changes no action", () => {
  const off = benefit({ copilot: copilot({ enabled: false }) })
  for (const action of ACTIONS.filter((a) => a !== "confirm_test")) {
    assertEquals(decide(action, off, { bike_id: BIKE }, NOW), decide(action, NO_COPILOT, { bike_id: BIKE }, NOW), action)
  }
})

// ─── Copilot ─────────────────────────────────────────────────────────────────

Deno.test("commit, copilot on → committed_at + copilot_stopped_at, step unchanged", () => {
  const b = benefit({ step: "commit_to_bike", copilot: copilot({ locked: true }) })
  assertEquals(decide("commit", b, {}, NOW), { patch: { committed_at: NOW, copilot_stopped_at: NOW } })
})

Deno.test("copilot lock blocks start, choose_bike_for_test and commit_from_details", () => {
  const b = benefit({ step: "book_live_test", live_test_sent_at: NOW, copilot: copilot({ locked: true }) })
  for (const action of ["start", "choose_bike_for_test", "commit_from_details"] as const) {
    assertEquals(decide(action, b, { bike_id: BIKE }, NOW), { error: "copilot_locked" }, action)
  }
})

Deno.test("copilot lock still allows reset, commit, confirm_pickup", () => {
  const b = benefit({ step: "commit_to_bike", copilot: copilot({ locked: true }) })
  assertEquals(decide("reset", b, {}, NOW), { patch: { step: "choose_bike" } })
  assertEquals("patch" in decide("commit", b, {}, NOW), true)
  assertEquals("patch" in decide("confirm_pickup", b, {}, NOW), true)
})

Deno.test("copilot before the lock: bike can still change", () => {
  const b = benefit({ step: "book_live_test", copilot: copilot() })
  assertEquals(decide("choose_bike_for_test", b, { bike_id: BIKE }, NOW), { patch: { bike_id: BIKE, step: "book_live_test" } })
})

Deno.test("confirm_test once confirmable → checked in + commit_to_bike", () => {
  const b = benefit({ step: "book_live_test", live_test_sent_at: NOW, copilot: copilot({ locked: true, test_confirmable: true }) })
  assertEquals(decide("confirm_test", b, {}, NOW), { patch: { live_test_checked_in_at: NOW, step: "commit_to_bike" } })
})

Deno.test("confirm_test refused before the test time + offset", () => {
  const b = benefit({ step: "book_live_test", live_test_sent_at: NOW, copilot: copilot({ locked: true, test_confirmable: false }) })
  assertEquals(decide("confirm_test", b, {}, NOW), { error: "test_not_confirmable" })
})

Deno.test("confirm_test refused without interest, off step 2, or without copilot", () => {
  const ready = copilot({ locked: true, test_confirmable: true })
  assertEquals(decide("confirm_test", benefit({ step: "book_live_test", copilot: ready }), {}, NOW), { error: "test_not_confirmable" })
  assertEquals(decide("confirm_test", benefit({ step: "commit_to_bike", live_test_sent_at: NOW, copilot: ready }), {}, NOW), { error: "test_not_confirmable" })
  assertEquals(decide("confirm_test", benefit({ step: "book_live_test", live_test_sent_at: NOW }), {}, NOW), { error: "test_not_confirmable" })
})

Deno.test("isAction rejects unknown values", () => {
  assertEquals(isAction("commit"), true)
  assertEquals(isAction("confirm_test"), true)
  assertEquals(isAction("sign_contract"), false)
  assertEquals(isAction(undefined), false)
  assertEquals(isAction(42), false)
})
