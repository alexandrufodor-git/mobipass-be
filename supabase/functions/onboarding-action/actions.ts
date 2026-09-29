// Onboarding step writes. Each patch mirrors what the mobile app wrote directly
// to bike_benefits before this function existed. New: the copilot stop on
// commit, confirm_test, and the copilot lock on changing the bike.

export const ACTIONS = [
  "start",
  "choose_bike_for_test",
  "test_interest",
  "confirm_test",
  "commit_from_details",
  "commit",
  "confirm_pickup",
  "reset",
] as const

export type Action = typeof ACTIONS[number]

// Output of the public.copilot(bike_benefits) computed column.
export interface Copilot {
  enabled: boolean
  live_test_at: string | null
  live_test_label: string | null
  test_confirmable: boolean
  locked: boolean
}

export interface ActionBenefit {
  step: string | null
  live_test_sent_at: string | null
  copilot: Copilot | null
}

export interface ActionBody {
  bike_id?: string
}

export type Patch = Record<string, string>

export type Decision = { patch: Patch } | { error: "copilot_locked" | "test_not_confirmable" }

export const ACTIONS_NEEDING_BIKE: readonly Action[] = ["choose_bike_for_test", "commit_from_details"]

// Once the copilot user asked for a test or committed, the bike can't change.
const LOCKED_ACTIONS: readonly Action[] = ["start", "choose_bike_for_test", "commit_from_details"]

export function isAction(value: unknown): value is Action {
  return typeof value === "string" && (ACTIONS as readonly string[]).includes(value)
}

export function decide(action: Action, benefit: ActionBenefit, body: ActionBody, now: string): Decision {
  const copilot = benefit.copilot
  if (copilot?.locked && LOCKED_ACTIONS.includes(action)) return { error: "copilot_locked" }

  switch (action) {
    case "start":
    case "reset":
      return { patch: { step: "choose_bike" } }
    case "choose_bike_for_test":
      return { patch: { bike_id: body.bike_id!, step: "book_live_test" } }
    case "test_interest":
      return { patch: { live_test_sent_at: now } }
    case "confirm_test":
      if (benefit.step !== "book_live_test" || !benefit.live_test_sent_at || !copilot?.test_confirmable) {
        return { error: "test_not_confirmable" }
      }
      return { patch: { live_test_checked_in_at: now, step: "commit_to_bike" } }
    case "commit_from_details":
      return { patch: { bike_id: body.bike_id!, step: "commit_to_bike" } }
    case "commit":
      return copilot?.enabled
        ? { patch: { committed_at: now, copilot_stopped_at: now } }
        : { patch: { committed_at: now, step: "sign_contract" } }
    case "confirm_pickup":
      return { patch: { delivered_at: now } }
  }
}
