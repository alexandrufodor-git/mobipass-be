// REGES → MobiPass mapping helpers.
//
// REGES uses Romanian-language values and a permissive structure; this module
// normalizes those into the shapes the rest of the system expects.

const COMBINING_MARKS = /[̀-ͯ]/g

export function normalizeName(s: string | null | undefined): string {
  if (!s) return ""
  return s
    .normalize("NFD")
    .replace(COMBINING_MARKS, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase()
}

// Romanian country names → ISO 3166-1 alpha-2.
// REGES emits 'România' (with diacritic) and occasionally bare 'Romania'.
// Unknown values return null and warn — we never fail the row over country.
export function mapCountryName(name?: string | null): string | null {
  if (!name) return null
  const norm = normalizeName(name)
  if (norm === "romania") return "RO"
  console.warn(`regesMapping: unknown country "${name}"`)
  return null
}

// REGES tipActIdentitate → our id_document_type taxonomy.
export function mapIdDocType(s?: string | null): string | null {
  if (!s) return null
  switch (s) {
    case "CarteIdentitate":
      return "national_id_card"
    case "Pasaport":
      return "passport"
    case "PermisSedere":
      return "residence_permit"
    default:
      return null
  }
}

// First given-name token (split on hyphen or whitespace).
// "ANDREEA-MIHAELA" → "ANDREEA"; "ANDREEA" → "ANDREEA"; "" → "".
export function firstGivenToken(prenume: string | null | undefined): string {
  if (!prenume) return ""
  const trimmed = prenume.trim()
  if (!trimmed) return ""
  const parts = trimmed.split(/[\s-]+/).filter(Boolean)
  return parts[0] ?? ""
}

// Second+ tokens joined with a space — the "middle name" equivalent.
// "ANDREEA-MIHAELA" → "MIHAELA"; "ANDREEA-MIHAELA-IOANA" → "MIHAELA IOANA";
// single-token input → "".
export function middleGivenTokens(prenume: string | null | undefined): string {
  if (!prenume) return ""
  const trimmed = prenume.trim()
  if (!trimmed) return ""
  const parts = trimmed.split(/[\s-]+/).filter(Boolean)
  return parts.slice(1).join(" ")
}
