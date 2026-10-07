// Unit tests for issue-report rules.
// Run with: deno test supabase/functions/issue-report/issue-report.test.ts

import { assert, assertEquals } from "jsr:@std/assert"
import { MAX_DESCRIPTION, isZip, parseMeta, scrub, storagePath } from "./report.ts"

const ID = "3f9c2a7e-1b2c-4d5e-8f90-123456789abc"

function meta(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    report_id: ID,
    created_at: "2026-10-07T09:41:30Z",
    trigger: "settings",
    platform: "android",
    app_version: "1.6.0",
    build: "39",
    os_version: "Android 14",
    device_manufacturer: "Google",
    device_model: "Pixel 7",
    locale: "ro-RO",
    timezone: "Europe/Bucharest",
    screen: "Settings",
    session_id: "s3f9c",
    update_state: "none",
    description: "Catalog stays blurred",
    ...over,
  }
}

function field(over: Record<string, unknown>): string | undefined {
  const r = parseMeta(meta(over))
  return r.ok ? undefined : r.field
}

Deno.test("valid meta → row with table columns only", () => {
  const r = parseMeta(meta())
  assert(r.ok)
  assertEquals(r.row.id, ID)
  assertEquals(r.row.description, "Catalog stays blurred")
  assertEquals("session_id" in r.row, false)
  assertEquals("device_manufacturer" in r.row, false)
})

Deno.test("optional fields may be missing, description defaults to empty", () => {
  const r = parseMeta(meta({ locale: null, timezone: "", description: undefined }))
  assert(r.ok)
  assertEquals([r.row.locale, r.row.timezone, r.row.description], [null, null, ""])
})

Deno.test("rejects bad enums, ids, types and lengths", () => {
  assertEquals(field({ report_id: "nope" }), "report_id")
  assertEquals(field({ trigger: "button" }), "trigger")
  assertEquals(field({ platform: "web" }), "platform")
  assertEquals(field({ device_model: "" }), "device_model")
  assertEquals(field({ build: 39 }), "build")
  assertEquals(field({ locale: "x".repeat(101) }), "locale")
  assertEquals(field({ description: "x".repeat(MAX_DESCRIPTION + 1) }), "description")
  assertEquals(parseMeta([]).ok, false)
})

Deno.test("description is scrubbed", () => {
  const r = parseMeta(meta({ description: "  me@firm.ro sees token=abc123  " }))
  assert(r.ok)
  assertEquals(r.row.description, "<redacted:email> sees token=<redacted:token>")
})

Deno.test("scrub matches the app's TelemetrySanitizer", () => {
  assertEquals(scrub("Authorization: Bearer abcdefgh12345"), "Authorization=<redacted:authorization> <redacted:token>")
  assertEquals(scrub("jwt eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl"), "jwt <redacted:jwt>")
  assertEquals(scrub("password: hunter22"), "password=<redacted:password>")
  assertEquals(scrub("user_id=eq.abc-123"), "user_id=<redacted:user_id>")
  assertEquals(scrub('{"user_id":"abc-123"}'), '{"user_id=<redacted:user_id>"}')
  assertEquals(scrub("Key (user_id)=(abc-123) exists"), "Key (user_id=<redacted:user_id>) exists")
})

Deno.test("isZip checks the local file header", () => {
  assertEquals(isZip(new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0x00])), true)
  assertEquals(isZip(new Uint8Array([0x1f, 0x8b, 0x08, 0x00])), false)
  assertEquals(isZip(new Uint8Array([0x50, 0x4b])), false)
})

Deno.test("storage path is platform/date/id.zip", () => {
  const r = parseMeta(meta())
  assert(r.ok)
  assertEquals(storagePath(r.row, new Date("2026-10-07T23:59:00Z")), `android/2026-10-07/${ID}.zip`)
})
