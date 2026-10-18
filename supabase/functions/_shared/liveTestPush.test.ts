import { assertEquals } from "jsr:@std/assert@1"
import { LIVE_TEST_EVENT, liveTestDayMonth } from "./liveTestPush.ts"

Deno.test("each live-test kind has its own push code", () => {
  assertEquals(LIVE_TEST_EVENT.booked, "live_test_booked")
  assertEquals(LIVE_TEST_EVENT.today, "live_test_today")
  assertEquals(LIVE_TEST_EVENT.confirm, "live_test_confirm")
  assertEquals(LIVE_TEST_EVENT.next_day, "live_test_next_day")
})

Deno.test("booked date arg is dd.MM in the company's time zone", () => {
  assertEquals(liveTestDayMonth("2026-09-30T07:00:00Z", "Europe/Bucharest"), "30.09")
  // 22:30 UTC on 30 Sep is already 1 Oct in Bucharest, still 30 Sep in Lisbon.
  assertEquals(liveTestDayMonth("2026-09-30T22:30:00Z", "Europe/Bucharest"), "01.10")
  assertEquals(liveTestDayMonth("2026-09-30T22:30:00Z", "Europe/Lisbon"), "30.09")
})
