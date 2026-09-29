// Copilot live-test pushes: copy + claim-then-send. The claim stamps the benefit's
// *_push_at column only while it's still empty, so overlapping callers can't send twice.

import { NotificationEvent } from "./constants.ts"
import { sendFcm, type FcmNotification } from "./fcm.ts"
import { type RestClient } from "./supabaseRest.ts"

export type LiveTestPushKind = "booked" | "today" | "confirm"

const STAMP: Record<LiveTestPushKind, string> = {
  booked:  "live_test_booked_push_at",
  today:   "live_test_today_push_at",
  confirm: "live_test_confirm_push_at",
}

// when: "Wed, 30 Sep · 10:00" for booked, "10:00" for today, unused for confirm.
export function liveTestPushCopy(kind: LiveTestPushKind, when: string, bikeBenefitId: string): FcmNotification {
  switch (kind) {
    case "booked":
      return {
        title: "Test ride booked",
        body: `Your test ride is on ${when}. We'll remind you on the day.`,
        event: NotificationEvent.LIVE_TEST_BOOKED,
        bikeBenefitId,
      }
    case "today":
      return {
        title: "Your test ride is today",
        body: `See you at ${when}. Afterwards, confirm your test in the app.`,
        event: NotificationEvent.LIVE_TEST_TODAY,
        bikeBenefitId,
      }
    case "confirm":
      return {
        title: "How was your test ride?",
        body: "Confirm your test in the app to move on.",
        event: NotificationEvent.LIVE_TEST_CONFIRM,
        bikeBenefitId,
      }
  }
}

// Returns true when this caller claimed the push and sent it.
export async function claimAndSendLiveTestPush(
  supabaseUrl: string,
  serviceKey: string,
  db: RestClient,
  userId: string,
  kind: LiveTestPushKind,
  when: string,
  bikeBenefitId: string,
): Promise<boolean> {
  const col = STAMP[kind]
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

  await sendFcm(db, userId, liveTestPushCopy(kind, when, bikeBenefitId))
  return true
}
