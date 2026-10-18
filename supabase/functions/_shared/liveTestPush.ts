// Copilot live-test pushes: claim-then-send. The claim stamps the benefit's *_push_at column
// only while it's still empty, so overlapping callers can't send twice.

import { NotificationEvent } from "./constants.ts"
import { sendFcm } from "./fcm.ts"
import { type RestClient } from "./supabaseRest.ts"

export type LiveTestPushKind = "booked" | "today" | "confirm" | "next_day"

export const LIVE_TEST_PUSH = {
  booked:   { stamp: "live_test_booked_push_at",   event: NotificationEvent.LIVE_TEST_BOOKED },
  today:    { stamp: "live_test_today_push_at",    event: NotificationEvent.LIVE_TEST_TODAY },
  confirm:  { stamp: "live_test_confirm_push_at",  event: NotificationEvent.LIVE_TEST_CONFIRM },
  next_day: { stamp: "live_test_next_day_push_at", event: NotificationEvent.LIVE_TEST_NEXT_DAY },
} as const satisfies Record<LiveTestPushKind, { stamp: string; event: string }>

// "30.09" in the company's time zone: the booked push's date arg, numbers only so it reads
// the same in every language.
export function liveTestDayMonth(liveTestAt: string, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "2-digit", timeZone })
    .formatToParts(new Date(liveTestAt))
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? ""
  return `${get("day")}.${get("month")}`
}

// Returns true when this caller claimed the push and sent it.
export async function claimAndSendLiveTestPush(
  supabaseUrl: string,
  serviceKey: string,
  db: RestClient,
  userId: string,
  kind: LiveTestPushKind,
  args: string[],
  bikeBenefitId: string,
): Promise<boolean> {
  const col = LIVE_TEST_PUSH[kind].stamp
  const res = await fetch(
    `${supabaseUrl}/rest/v1/bike_benefits?id=eq.${bikeBenefitId}&${col}=is.null&select=id`,
    {
      method: "PATCH",
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify({ [col]: new Date().toISOString() }),
    },
  )
  if (!res.ok) {
    console.error(`[live-test-push] claim ${kind} failed:`, res.status, await res.text().catch(() => ""))
    return false
  }
  const claimed: unknown[] = await res.json()
  if (!claimed.length) return false

  await sendFcm(db, userId, { event: LIVE_TEST_PUSH[kind].event, bikeBenefitId, args })
  return true
}
