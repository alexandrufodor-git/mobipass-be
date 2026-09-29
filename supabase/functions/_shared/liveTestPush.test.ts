import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1"
import { liveTestPushCopy } from "./liveTestPush.ts"

Deno.test("booked push names the test date", () => {
  const n = liveTestPushCopy("booked", "Wed, 30 Sep · 10:00", "b1")
  assertEquals(n.event, "live_test_booked")
  assertStringIncludes(n.body, "Wed, 30 Sep · 10:00")
  assertEquals(n.bikeBenefitId, "b1")
})

Deno.test("today push names the hour", () => {
  const n = liveTestPushCopy("today", "10:00", "b1")
  assertEquals(n.event, "live_test_today")
  assertStringIncludes(n.body, "10:00")
})

Deno.test("confirm push asks to confirm, no HR promise", () => {
  const n = liveTestPushCopy("confirm", "", "b1")
  assertEquals(n.event, "live_test_confirm")
  assertStringIncludes(n.body, "Confirm your test")
  assertEquals(n.body.includes("HR"), false)
})
