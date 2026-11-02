// Excel branch of bulk-create, no library: an .xlsx is a ZIP of XML parts (DecompressionStream + regex).

import { Errors } from "./constants.ts"
import { type CsvRow, ingestRows } from "./csvIngest.ts"
import type { BulkResult } from "./bulkResult.ts"
import type { RestClient } from "./supabaseRest.ts"

// Caps keep a crafted file (zip bomb, millions of rows, ref="ZZZZZZZ1") from exhausting the function's memory.
export const XLSX_LIMITS = {
  MAX_PART_BYTES:   10 * 1024 * 1024,
  MAX_ROWS:         5_000,
  MAX_COLS:         100,
  HEADER_SCAN_ROWS: 10,
} as const

export const XLSX_HEADERS = {
  // TODO: check whether "nume si prenume" lists are surname-first: "POPESCU Ion Andrei" would split into first "POPESCU Ion", last "Andrei".
  FULL_NAME:  /^(nume|name|nume si prenume|nume complet|full name)$/,
  FIRST_NAME: /^(prenume|first name|given name)$/,
  EMAIL:      /^(e-?mail|adresa (de )?e-?mail)$/,
} as const

export class XlsxError extends Error {
  constructor(public readonly body: { error: string }) {
    super(body.error)
  }
}

export async function ingestXlsx(db: RestClient, companyId: string, bytes: Uint8Array): Promise<BulkResult[]> {
  const sheet = await readFirstSheet(bytes)
  console.info(`[bulk-create] ingestXlsx sheet_rows=${sheet.length}`)
  return ingestRows(db, companyId, employeeRows(sheet))
}

const u16 = (b: Uint8Array, o: number) => b[o] | (b[o + 1] << 8)
const u32 = (b: Uint8Array, o: number) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0

interface ZipEntry { method: number; size: number; rawSize: number; localOffset: number }

function zipEntries(bytes: Uint8Array): Map<string, ZipEntry> {
  let eocd = -1
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) {
    if (u32(bytes, i) === 0x06054b50) { eocd = i; break }
  }
  if (eocd < 0) throw new XlsxError(Errors.UNREADABLE_XLSX)

  const entries = new Map<string, ZipEntry>()
  const names = new TextDecoder()
  let p = u32(bytes, eocd + 16)
  for (let n = u16(bytes, eocd + 10); n > 0; n--) {
    if (u32(bytes, p) !== 0x02014b50) throw new XlsxError(Errors.UNREADABLE_XLSX)
    const nameLen = u16(bytes, p + 28)
    entries.set(names.decode(bytes.subarray(p + 46, p + 46 + nameLen)), {
      method:      u16(bytes, p + 10),
      size:        u32(bytes, p + 20),
      rawSize:     u32(bytes, p + 24),
      localOffset: u32(bytes, p + 42),
    })
    p += 46 + nameLen + u16(bytes, p + 30) + u16(bytes, p + 32)
  }
  return entries
}

// Counts while inflating: the declared size in the ZIP header can lie.
async function inflateCapped(data: Uint8Array<ArrayBuffer>): Promise<Uint8Array> {
  const reader = new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw")).getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  for (let r = await reader.read(); !r.done; r = await reader.read()) {
    total += r.value.length
    if (total > XLSX_LIMITS.MAX_PART_BYTES) {
      await reader.cancel()
      throw new XlsxError(Errors.UNREADABLE_XLSX)
    }
    chunks.push(r.value)
  }
  const out = new Uint8Array(total)
  let at = 0
  for (const c of chunks) { out.set(c, at); at += c.length }
  return out
}

async function readEntry(bytes: Uint8Array, entries: Map<string, ZipEntry>, name: string): Promise<string | null> {
  const e = entries.get(name)
  if (!e) return null
  if (e.rawSize > XLSX_LIMITS.MAX_PART_BYTES) throw new XlsxError(Errors.UNREADABLE_XLSX)
  const lo = e.localOffset
  if (u32(bytes, lo) !== 0x04034b50) throw new XlsxError(Errors.UNREADABLE_XLSX)
  const start = lo + 30 + u16(bytes, lo + 26) + u16(bytes, lo + 28)
  const data = bytes.slice(start, start + e.size)
  if (e.method === 0) return new TextDecoder().decode(data)
  if (e.method !== 8) throw new XlsxError(Errors.UNREADABLE_XLSX)
  return new TextDecoder().decode(await inflateCapped(data))
}

const decodeXml = (s: string) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (_, ent: string) => {
    const e = ent.toLowerCase()
    if (e.startsWith("#x")) return String.fromCodePoint(parseInt(e.slice(2), 16))
    if (e.startsWith("#")) return String.fromCodePoint(parseInt(e.slice(1), 10))
    return { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" }[e]!
  })

// Concatenates every <t> run, skipping phonetic (<rPh>) runs.
const textRuns = (xml: string) =>
  decodeXml([...xml.replace(/<rPh\b[\s\S]*?<\/rPh>/g, "").matchAll(/<t(?:\s[^>]*?)?(?<!\/)>([\s\S]*?)<\/t>/g)].map((m) => m[1]).join(""))

const attr = (attrs: string, name: string) => attrs.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1]

function colIndex(ref: string): number {
  let n = 0
  for (const ch of ref.replace(/\d+$/, "")) n = n * 26 + (ch.charCodeAt(0) - 64)
  return n - 1
}

// Returns the first sheet's non-empty rows as text, in sheet order (column gaps filled with "").
export async function readFirstSheet(bytes: Uint8Array): Promise<string[][]> {
  try {
    return await parseFirstSheet(bytes)
  } catch (e) {
    throw e instanceof XlsxError ? e : new XlsxError(Errors.UNREADABLE_XLSX)
  }
}

async function parseFirstSheet(bytes: Uint8Array): Promise<string[][]> {
  const entries = zipEntries(bytes)

  const shared = [...((await readEntry(bytes, entries, "xl/sharedStrings.xml")) ?? "")
    .matchAll(/<si(?:\s[^>]*)?(?:\/>|>([\s\S]*?)<\/si>)/g)].map((m) => textRuns(m[1] ?? ""))

  let sheetPath = "xl/worksheets/sheet1.xml"
  const relId = attr((await readEntry(bytes, entries, "xl/workbook.xml"))?.match(/<sheet\b[^>]*>/)?.[0] ?? "", "r:id")
  const rels = (await readEntry(bytes, entries, "xl/_rels/workbook.xml.rels")) ?? ""
  const target = [...rels.matchAll(/<Relationship\b([^>]*)>/g)]
    .map((m) => m[1]).find((a) => attr(a, "Id") === relId)
  const targetPath = target ? attr(target, "Target") : undefined
  if (targetPath) sheetPath = targetPath.startsWith("/") ? targetPath.slice(1) : `xl/${targetPath}`

  const sheet = await readEntry(bytes, entries, sheetPath)
  if (sheet === null) throw new XlsxError(Errors.UNREADABLE_XLSX)

  const rows: string[][] = []
  for (const row of sheet.matchAll(/<row\b[^>]*?(?:\/>|>([\s\S]*?)<\/row>)/g)) {
    const cells: string[] = []
    let col = -1
    for (const c of (row[1] ?? "").matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const ref = attr(c[1], "r")
      col = ref ? colIndex(ref) : col + 1
      if (col < 0 || col >= XLSX_LIMITS.MAX_COLS) continue
      const body = c[2] ?? ""
      const v = body.match(/<v>([\s\S]*?)<\/v>/)?.[1]
      const type = attr(c[1], "t")
      cells[col] = type === "s" ? shared[Number(v)] ?? ""
        : type === "inlineStr" ? textRuns(body)
        : decodeXml(v ?? "")
    }
    // Formatting-only rows carry no values; only rows with data count toward the cap.
    if (!cells.some(Boolean)) continue
    if (rows.length >= XLSX_LIMITS.MAX_ROWS) throw new XlsxError(Errors.TOO_MANY_ROWS)
    rows.push(Array.from(cells, (x) => x ?? ""))
  }
  return rows
}

const norm = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").replace(/\s+/g, " ").trim().toLowerCase()
const clean = (v: string | undefined) => (v ?? "").replace(/\s+/g, " ").trim()

// Pilot format: "Nume" = "GivenName(s) Surname" (last word = surname) + "Email"; or "Prenume" + "Nume" + "Email".
export function employeeRows(sheet: string[][]): CsvRow[] {
  const headerIndex = sheet.slice(0, XLSX_LIMITS.HEADER_SCAN_ROWS).findIndex((row) =>
    row.some((t) => XLSX_HEADERS.FULL_NAME.test(norm(t))) && row.some((t) => XLSX_HEADERS.EMAIL.test(norm(t))))
  if (headerIndex < 0) throw new XlsxError(Errors.MISSING_COLUMNS)

  const header = sheet[headerIndex].map(norm)
  const nameCol = header.findIndex((t) => XLSX_HEADERS.FULL_NAME.test(t))
  const emailCol = header.findIndex((t) => XLSX_HEADERS.EMAIL.test(t))
  // With a separate "Prenume" column, "Nume" is only the surname.
  const givenCol = header.findIndex((t) => XLSX_HEADERS.FIRST_NAME.test(t))

  const rows = sheet.slice(headerIndex + 1)
    .map((r) => ({ name: clean(r[nameCol]), given: givenCol >= 0 ? clean(r[givenCol]) : null, email: clean(r[emailCol]).toLowerCase() }))
    .filter((r) => r.name || r.given || r.email)
    .map(({ name, given, email }) => {
      if (given !== null) return { email, firstName: given, lastName: name }
      const words = name.split(" ")
      const lastName = words.length > 1 ? words.pop()! : ""
      return { email, firstName: words.join(" "), lastName }
    })
  console.info(`[bulk-create] employeeRows header_row=${headerIndex} name_col=${nameCol} email_col=${emailCol} given_col=${givenCol} names=${givenCol >= 0 ? "prenume_column" : "split_last_word"} rows=${rows.length}`)
  if (!rows.length) throw new XlsxError(Errors.NO_ROWS)
  return rows
}
