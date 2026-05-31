// Romanian CNP (Cod Numeric Personal) validation + DOB derivation.
//
// CNP layout (13 digits):
//   1  : sex + century (1,2 → 1900s; 3,4 → 1800s; 5,6 → 2000s; 7,8,9 → foreigners)
//   2-3: year (YY within the century)
//   4-5: month
//   6-7: day
//   8-9: county code (01..52)
//   10-12: sequential
//   13 : checksum
//
// Checksum: sum( CNP[i] * W[i] ) mod 11, where W = [2,7,9,1,4,6,3,5,8,2,7,9].
// If the result is 10, the check digit is 1; otherwise the digit itself.

const CHECKSUM_WEIGHTS = [2, 7, 9, 1, 4, 6, 3, 5, 8, 2, 7, 9] as const

export interface CnpValidation {
  valid: boolean
  dobIso?: string
  century?: 19 | 20 | 21
  reason?: string
}

function centuryFromFirst(d: number): 19 | 20 | 21 | null {
  // 1,2 → 1900; 3,4 → 1800; 5,6 → 2000; 7,8,9 → foreigner (assume current era)
  if (d === 1 || d === 2) return 20
  if (d === 3 || d === 4) return 19
  if (d === 5 || d === 6) return 21
  if (d === 7 || d === 8 || d === 9) return 21
  return null
}

function buildDob(century: 19 | 20 | 21, yy: number, mm: number, dd: number): string | null {
  const base = century === 19 ? 1800 : century === 20 ? 1900 : 2000
  const year = base + yy
  const date = new Date(Date.UTC(year, mm - 1, dd))
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== mm - 1 ||
    date.getUTCDate() !== dd
  ) {
    return null
  }
  const m = String(mm).padStart(2, "0")
  const d = String(dd).padStart(2, "0")
  return `${year}-${m}-${d}`
}

export function validateCnp(raw: string): CnpValidation {
  if (typeof raw !== "string") return { valid: false, reason: "not_a_string" }
  const cnp = raw.trim()
  if (!/^\d{13}$/.test(cnp)) return { valid: false, reason: "not_13_digits" }

  const digits = cnp.split("").map((c) => Number(c))
  const century = centuryFromFirst(digits[0])
  if (!century) return { valid: false, reason: "invalid_century_digit" }

  const yy = digits[1] * 10 + digits[2]
  const mm = digits[3] * 10 + digits[4]
  const dd = digits[5] * 10 + digits[6]
  const dobIso = buildDob(century, yy, mm, dd)
  if (!dobIso) return { valid: false, reason: "invalid_dob_components" }

  let sum = 0
  for (let i = 0; i < 12; i++) sum += digits[i] * CHECKSUM_WEIGHTS[i]
  let check = sum % 11
  if (check === 10) check = 1
  if (check !== digits[12]) return { valid: false, reason: "checksum_mismatch" }

  return { valid: true, dobIso, century }
}

// Best-effort DOB derivation without full validation. Returns null if the
// date components can't be parsed. Used at REGES ingest where we trust the
// source enough to extract the birth date even when the upstream record
// has dataNastereSpecified=false.
export function cnpToDob(cnp: string): string | null {
  if (typeof cnp !== "string" || !/^\d{13}$/.test(cnp.trim())) return null
  const digits = cnp.trim().split("").map((c) => Number(c))
  const century = centuryFromFirst(digits[0])
  if (!century) return null
  return buildDob(
    century,
    digits[1] * 10 + digits[2],
    digits[3] * 10 + digits[4],
    digits[5] * 10 + digits[6],
  )
}
