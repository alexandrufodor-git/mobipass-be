// Company email-pattern derivation.
//
// Grammar:
//   {first}, {last}, {middle}, {first_initial}, {last_initial}
//   literals: . _ - +
//   optional segment: ?{ ... }
//     The contents of an optional segment are dropped entirely if any token
//     inside it resolves to empty. This is the right behavior for compound-
//     name handling: "?{.{middle}}" yields ".mihaela" when a middle name
//     exists, "" when it doesn't.
//
// Companies pick ONE named pattern (companies.email_pattern, a Postgres enum
// of type email_pattern_kind). The literal template string for each enum
// value lives in EMAIL_PATTERN_TEMPLATES below — this map is the only place
// pattern text exists. Add a new pattern by adding a value to the enum
// (via migration) AND an entry here, in lockstep.
//
// derivePatternEmail resolves a single pattern → local part + "@" + domain.
// Local part is normalized (diacritics stripped, lowercased, surrounding /
// duplicate separators collapsed). Returns null if resolution fails or the
// pattern kind is null.

import { normalizeName } from "./regesMapping.ts"

// Mirrors public.email_pattern_kind in Postgres.
export type EmailPatternKind =
  | "last_middle_first"
  | "first_middle_last"
  | "first_last"
  | "last_first"
  | "first_initial_last"

export const EMAIL_PATTERN_TEMPLATES: Record<EmailPatternKind, string> = {
  last_middle_first:  "{last}?{.{middle}}.{first}",
  first_middle_last:  "{first}?{.{middle}}.{last}",
  first_last:         "{first}.{last}",
  last_first:         "{last}.{first}",
  first_initial_last: "{first_initial}{last}",
}

export interface PatternInput {
  first:  string
  middle: string
  last:   string
  domain: string
}

type Token = keyof Omit<PatternInput, "domain"> | "first_initial" | "last_initial"

function resolveToken(token: Token, input: PatternInput): string {
  switch (token) {
    case "first":         return normalizeName(input.first)
    case "middle":        return normalizeName(input.middle)
    case "last":          return normalizeName(input.last)
    case "first_initial": return normalizeName(input.first).slice(0, 1)
    case "last_initial":  return normalizeName(input.last).slice(0, 1)
  }
}

// Expand a flat (non-optional) segment. Returns null if any {token} inside
// resolves to empty — caller decides whether that aborts the whole pattern
// (top level) or just drops this optional segment.
function expandSegment(src: string, input: PatternInput): string | null {
  let out = ""
  let i = 0
  while (i < src.length) {
    const ch = src[i]
    if (ch === "{") {
      const end = src.indexOf("}", i + 1)
      if (end === -1) return null
      const token = src.slice(i + 1, end) as Token
      const value = resolveToken(token, input)
      if (!value) return null
      out += value
      i = end + 1
    } else if (ch === "." || ch === "_" || ch === "-" || ch === "+") {
      out += ch
      i++
    } else {
      // Unknown literal character — be strict; patterns should not include
      // arbitrary text. Returning null surfaces the misconfiguration.
      return null
    }
  }
  return out
}

function expandPattern(pattern: string, input: PatternInput): string | null {
  let out = ""
  let i = 0
  while (i < pattern.length) {
    if (pattern[i] === "?" && pattern[i + 1] === "{") {
      // Find matching closing brace for the optional segment.
      let depth = 1
      let j = i + 2
      while (j < pattern.length && depth > 0) {
        if (pattern[j] === "{") depth++
        else if (pattern[j] === "}") depth--
        if (depth > 0) j++
      }
      if (depth !== 0) return null
      const inner = pattern.slice(i + 2, j)
      const expanded = expandSegment(inner, input)
      if (expanded !== null) out += expanded
      i = j + 1
    } else if (pattern[i] === "{") {
      const end = pattern.indexOf("}", i + 1)
      if (end === -1) return null
      const token = pattern.slice(i + 1, end) as Token
      const value = resolveToken(token, input)
      if (!value) return null
      out += value
      i = end + 1
    } else if (pattern[i] === "." || pattern[i] === "_" || pattern[i] === "-" || pattern[i] === "+") {
      out += pattern[i]
      i++
    } else {
      return null
    }
  }
  // Collapse accidental duplicates from an optional segment dropping out.
  return out.replace(/[._\-+]{2,}/g, (m) => m[0]).replace(/^[._\-+]+|[._\-+]+$/g, "")
}

export function derivePatternEmail(
  kind: EmailPatternKind | null,
  input: PatternInput,
): string | null {
  if (!kind) return null
  if (!input.domain) return null
  const template = EMAIL_PATTERN_TEMPLATES[kind]
  const local = expandPattern(template, input)
  return local ? `${local}@${input.domain.toLowerCase()}` : null
}
