// Unit tests for REGES → MobiPass mapping helpers.
// Run with: deno test supabase/functions/_shared/regesMapping.test.ts

import { assertEquals } from "jsr:@std/assert"
import {
  firstGivenToken,
  mapCountryName,
  mapIdDocType,
  middleGivenTokens,
  normalizeName,
} from "./regesMapping.ts"

Deno.test("normalizeName lower-cases, strips diacritics, collapses whitespace", () => {
  assertEquals(normalizeName("POP"), "pop")
  // Romanian diacritics: ă â î ș ț
  assertEquals(normalizeName("Andreea-Mihaela"), "andreea-mihaela")
  assertEquals(normalizeName("Ștefan"), "stefan")
  assertEquals(normalizeName("Ioniță"), "ionita")
  assertEquals(normalizeName("Călin"), "calin")
  assertEquals(normalizeName("Râul"), "raul")
  assertEquals(normalizeName("ÎNCEPUT"), "inceput")
  assertEquals(normalizeName("  multi   space  "), "multi space")
})

Deno.test("normalizeName handles null/undefined/empty input", () => {
  assertEquals(normalizeName(null), "")
  assertEquals(normalizeName(undefined), "")
  assertEquals(normalizeName(""), "")
  assertEquals(normalizeName("   "), "")
})

Deno.test("mapCountryName maps Romania variants → RO", () => {
  assertEquals(mapCountryName("România"), "RO")
  assertEquals(mapCountryName("Romania"), "RO")
  assertEquals(mapCountryName("ROMANIA"), "RO")
})

Deno.test("mapCountryName returns null for null/empty", () => {
  assertEquals(mapCountryName(null), null)
  assertEquals(mapCountryName(undefined), null)
  assertEquals(mapCountryName(""), null)
})

Deno.test("mapCountryName returns null for unknown country (and warns)", () => {
  // Don't assert on console output here — coverage of the warn path is
  // visual; we just verify the safety contract (no throw, returns null).
  assertEquals(mapCountryName("Atlantis"), null)
})

Deno.test("mapIdDocType maps known REGES values", () => {
  assertEquals(mapIdDocType("CarteIdentitate"), "national_id_card")
  assertEquals(mapIdDocType("Pasaport"),         "passport")
  assertEquals(mapIdDocType("PermisSedere"),     "residence_permit")
})

Deno.test("mapIdDocType returns null for unknown/empty input", () => {
  assertEquals(mapIdDocType(null), null)
  assertEquals(mapIdDocType(undefined), null)
  assertEquals(mapIdDocType(""), null)
  assertEquals(mapIdDocType("Unknown"), null)
})

Deno.test("firstGivenToken returns first token on hyphen, space, or both", () => {
  assertEquals(firstGivenToken("ANDREEA-MIHAELA"), "ANDREEA")
  assertEquals(firstGivenToken("ANDREEA MIHAELA"), "ANDREEA")
  assertEquals(firstGivenToken("ANDREEA"), "ANDREEA")
  assertEquals(firstGivenToken("ANDREEA - MIHAELA"), "ANDREEA")
  assertEquals(firstGivenToken(""), "")
  assertEquals(firstGivenToken(null), "")
  assertEquals(firstGivenToken(undefined), "")
})

Deno.test("middleGivenTokens returns remaining tokens joined with space", () => {
  assertEquals(middleGivenTokens("ANDREEA-MIHAELA"), "MIHAELA")
  assertEquals(middleGivenTokens("ANDREEA"), "")
  assertEquals(middleGivenTokens("ANDREEA MIHAELA IOANA"), "MIHAELA IOANA")
  assertEquals(middleGivenTokens("ANDREEA-MIHAELA-IOANA"), "MIHAELA IOANA")
  assertEquals(middleGivenTokens(""), "")
  assertEquals(middleGivenTokens(null), "")
})
