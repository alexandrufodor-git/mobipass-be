import { assertEquals, assertRejects } from "jsr:@std/assert"
import { Errors } from "./constants.ts"
import { XLSX_LIMITS, XlsxError, employeeRows, readFirstSheet } from "./xlsxIngest.ts"

const enc = new TextEncoder()

async function deflateRaw(data: Uint8Array<ArrayBuffer>): Promise<Uint8Array> {
  return new Uint8Array(await new Response(new Blob([data]).stream().pipeThrough(new CompressionStream("deflate-raw"))).arrayBuffer())
}

// Minimal deflate ZIP writer (CRC left 0: the reader doesn't check it).
async function zip(files: Record<string, string>, declaredRawSize?: number): Promise<Uint8Array> {
  const parts: Uint8Array[] = []
  const central: Uint8Array[] = []
  let offset = 0
  for (const [name, text] of Object.entries(files)) {
    const nameBytes = enc.encode(name)
    const raw = enc.encode(text)
    const data = await deflateRaw(raw)
    const local = new DataView(new ArrayBuffer(30))
    local.setUint32(0, 0x04034b50, true)
    local.setUint16(8, 8, true)
    local.setUint32(18, data.length, true)
    local.setUint32(22, raw.length, true)
    local.setUint16(26, nameBytes.length, true)
    const cd = new DataView(new ArrayBuffer(46))
    cd.setUint32(0, 0x02014b50, true)
    cd.setUint16(10, 8, true)
    cd.setUint32(20, data.length, true)
    cd.setUint32(24, declaredRawSize ?? raw.length, true)
    cd.setUint16(28, nameBytes.length, true)
    cd.setUint32(42, offset, true)
    parts.push(new Uint8Array(local.buffer), nameBytes, data)
    central.push(new Uint8Array(cd.buffer), nameBytes)
    offset += 30 + nameBytes.length + data.length
  }
  const cdSize = central.reduce((n, p) => n + p.length, 0)
  const eocd = new DataView(new ArrayBuffer(22))
  eocd.setUint32(0, 0x06054b50, true)
  eocd.setUint16(8, Object.keys(files).length, true)
  eocd.setUint16(10, Object.keys(files).length, true)
  eocd.setUint32(12, cdSize, true)
  eocd.setUint32(16, offset, true)
  const all = [...parts, ...central, new Uint8Array(eocd.buffer)]
  const out = new Uint8Array(all.reduce((n, p) => n + p.length, 0))
  let p = 0
  for (const part of all) { out.set(part, p); p += part.length }
  return out
}

const inline = (ref: string, text: string) => `<c r="${ref}" t="inlineStr"><is><t>${text}</t></is></c>`
const sheet = (rowsXml: string) => ({ "xl/worksheets/sheet1.xml": `<worksheet><sheetData>${rowsXml}</sheetData></worksheet>` })
const header = `<row r="1">${inline("A1", "Nume")}${inline("B1", "Email")}</row>`

async function rejectsWith(bytes: Uint8Array, expected: { error: string }) {
  const err = await assertRejects(() => readFirstSheet(bytes), XlsxError)
  assertEquals(err.body, expected)
}

Deno.test("zip bomb with honest size → unreadable_xlsx before inflating", async () => {
  await rejectsWith(await zip({ "xl/worksheets/sheet1.xml": "a".repeat(XLSX_LIMITS.MAX_PART_BYTES + 1) }), Errors.UNREADABLE_XLSX)
})

Deno.test("zip bomb lying about its size → stopped while inflating", async () => {
  await rejectsWith(await zip({ "xl/worksheets/sheet1.xml": "a".repeat(XLSX_LIMITS.MAX_PART_BYTES + 1) }, 100), Errors.UNREADABLE_XLSX)
})

Deno.test("more data rows than the cap → too_many_rows", async () => {
  const rows = Array.from({ length: XLSX_LIMITS.MAX_ROWS }, (_, i) => `<row r="${i + 2}">${inline(`A${i + 2}`, "Ion Pop")}</row>`).join("")
  await rejectsWith(await zip(sheet(header + rows)), Errors.TOO_MANY_ROWS)
})

Deno.test("formatting-only rows and a huge row number don't count toward the cap", async () => {
  const styled = Array.from({ length: XLSX_LIMITS.MAX_ROWS + 10 }, (_, i) => `<row r="${i + 3}"><c r="A${i + 3}" s="1"/></row>`).join("")
  const bytes = await zip(sheet(`${header}<row r="2">${inline("A2", "Ion Pop")}${inline("B2", "ion@cadran.eu")}</row>${styled}<row r="1000000000">${inline("A1000000000", "Ana Pop")}${inline("B1000000000", "ana@cadran.eu")}</row>`))
  assertEquals(employeeRows(await readFirstSheet(bytes)), [
    { email: "ion@cadran.eu", firstName: "Ion", lastName: "Pop" },
    { email: "ana@cadran.eu", firstName: "Ana", lastName: "Pop" },
  ])
})

Deno.test("huge column reference is ignored", async () => {
  const bytes = await zip(sheet(`<row r="1">${inline("A1", "Nume")}${inline("B1", "Email")}${inline("ZZZZZZZ1", "x")}</row>`))
  assertEquals((await readFirstSheet(bytes))[0].length, 2)
})

Deno.test("corrupt deflate data and bad entities → unreadable_xlsx, not a crash", async () => {
  await rejectsWith(await zip(sheet(`<row r="1">${inline("A1", "&#99999999;")}</row>`)), Errors.UNREADABLE_XLSX)
  const corrupt = await zip(sheet(header))
  corrupt.fill(0xff, 40, 60)
  await rejectsWith(corrupt, Errors.UNREADABLE_XLSX)
})
