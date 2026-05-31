// Unit tests for the company email-pattern derivation grammar.
// Run with: deno test supabase/functions/_shared/emailPattern.test.ts

import { assertEquals } from "jsr:@std/assert"
import { derivePatternEmail } from "./emailPattern.ts"

const ACME = "acme.example"

Deno.test("first_last — simple pattern", () => {
  const got = derivePatternEmail("first_last", {
    first: "Andreea", middle: "", last: "Pop", domain: ACME,
  })
  assertEquals(got, "andreea.pop@acme.example")
})

Deno.test("first_initial_last", () => {
  const got = derivePatternEmail("first_initial_last", {
    first: "Andreea", middle: "", last: "Pop", domain: ACME,
  })
  assertEquals(got, "apop@acme.example")
})

Deno.test("first_middle_last — middle present", () => {
  const got = derivePatternEmail("first_middle_last", {
    first: "Andreea", middle: "Mihaela", last: "Pop", domain: ACME,
  })
  assertEquals(got, "andreea.mihaela.pop@acme.example")
})

Deno.test("first_middle_last — middle empty drops cleanly", () => {
  const got = derivePatternEmail("first_middle_last", {
    first: "Andreea", middle: "", last: "Pop", domain: ACME,
  })
  assertEquals(got, "andreea.pop@acme.example")
})

Deno.test("null kind returns null", () => {
  const got = derivePatternEmail(null, {
    first: "Andreea", middle: "", last: "Pop", domain: ACME,
  })
  assertEquals(got, null)
})

Deno.test("empty domain returns null", () => {
  const got = derivePatternEmail("first_last", {
    first: "x", middle: "", last: "y", domain: "",
  })
  assertEquals(got, null)
})

Deno.test("diacritics in input are normalized in output", () => {
  const got = derivePatternEmail("first_last", {
    first: "Ștefan", middle: "", last: "Ioniță", domain: ACME,
  })
  assertEquals(got, "stefan.ionita@acme.example")
})

Deno.test("domain is lowercased", () => {
  const got = derivePatternEmail("first_last", {
    first: "Andreea", middle: "", last: "Pop", domain: "ACME.EXAMPLE",
  })
  assertEquals(got, "andreea.pop@acme.example")
})

Deno.test("last_middle_first — REGES Gmail E2E", () => {
  const got = derivePatternEmail("last_middle_first", {
    first: "Alexandru", middle: "Horatiu", last: "Fodor", domain: "gmail.com",
  })
  assertEquals(got, "fodor.horatiu.alexandru@gmail.com")
})

Deno.test("last_middle_first — middle empty collapses dots", () => {
  const got = derivePatternEmail("last_middle_first", {
    first: "A", middle: "", last: "B", domain: ACME,
  })
  assertEquals(got, "b.a@acme.example")
})

Deno.test("last_first", () => {
  const got = derivePatternEmail("last_first", {
    first: "Andreea", middle: "", last: "Pop", domain: ACME,
  })
  assertEquals(got, "pop.andreea@acme.example")
})
