// Bike photo normalisation: trim the studio border around the bike, then centre it on its own studio colour
// with the same margin on every bike, so catalog cards show every bike whole and at one size.

import { decode, Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts"
import decodeWebp, { init as initWebp } from "npm:@jsquash/webp@1.5.0/decode.js"
import { decodeBase64 } from "jsr:@std/encoding@1.0.5/base64"

const ASPECT = 3 / 2 // the app's image box
const WHITE_MIN = 240 // r, g and b all at or above this read as studio background
const MIN_BACKGROUND_BORDER = 0.9 // below this the photo has a real background: leave it

const isBackground = (r: number, g: number, b: number, a: number) =>
  a < 16 || (r >= WHITE_MIN && g >= WHITE_MIN && b >= WHITE_MIN)

// Bounding box of the bike and the average studio colour of the border (so the margins don't show
// an off-white box), or null when the photo isn't a studio shot (or is empty).
export function subjectBox(
  img: Image,
): { x: number; y: number; w: number; h: number; background: number } | null {
  const { width, height, bitmap } = img
  const bg = (x: number, y: number) => {
    const i = (y * width + x) * 4
    return isBackground(bitmap[i], bitmap[i + 1], bitmap[i + 2], bitmap[i + 3])
  }

  let border = 0, borderBg = 0, r = 0, g = 0, b = 0
  const visit = (x: number, y: number) => {
    border++
    if (!bg(x, y)) return
    borderBg++
    const i = (y * width + x) * 4
    const opaque = bitmap[i + 3] >= 16
    r += opaque ? bitmap[i] : 255
    g += opaque ? bitmap[i + 1] : 255
    b += opaque ? bitmap[i + 2] : 255
  }
  for (let x = 0; x < width; x++) { visit(x, 0); visit(x, height - 1) }
  for (let y = 0; y < height; y++) { visit(0, y); visit(width - 1, y) }
  if (borderBg / border < MIN_BACKGROUND_BORDER) return null
  const background = Image.rgbaToColor(Math.round(r / borderBg), Math.round(g / borderBg), Math.round(b / borderBg), 255)

  let minX = width, minY = height, maxX = -1, maxY = -1
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (bg(x, y)) continue
      if (x < minX) minX = x
      if (x > maxX) maxX = x
      if (y < minY) minY = y
      if (y > maxY) maxY = y
    }
  }
  if (maxX < 0) return null
  return { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1, background }
}

// Changing the rule or its output? Bump public.bike_images_rule_version() in a migration, so every
// photo decided by the older version is due again.
const APP_BOX_RATIOS = [1.35, 1.5] // the app's image box (width / 220pt) across phone widths
// Closer than this to the visible edge, the card's rounded corners clip the bike.
const MIN_EDGE = 0.03
// Side margin of a copy, from the rule: what the narrowest card crops off each side of 3:2, plus MIN_EDGE
// of what stays visible, plus rounding slack (= 0.08).
const NARROWEST = Math.min(...APP_BOX_RATIOS)
const MARGIN = (1 - NARROWEST / ASPECT) / 2 + MIN_EDGE * NARROWEST / ASPECT + 0.003
// Decoding a bigger photo blows the edge function's 2 s CPU limit per request: keep it as is.
const MAX_PIXELS = 3_000_000

const isWebp = (bytes: Uint8Array) =>
  bytes.length > 30 && String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF" &&
  String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP"

// Width and height from the file header (PNG IHDR, a JPEG SOF marker or a WebP chunk), without decoding.
export function imageSize(bytes: Uint8Array): { width: number; height: number } | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  if (bytes.length > 24 && bytes[0] === 0x89 && bytes[1] === 0x50) {
    return { width: view.getUint32(16), height: view.getUint32(20) }
  }
  if (isWebp(bytes)) {
    const chunk = String.fromCharCode(...bytes.subarray(12, 16))
    if (chunk === "VP8 ") return { width: view.getUint16(26, true) & 0x3fff, height: view.getUint16(28, true) & 0x3fff }
    if (chunk === "VP8L") {
      const bits = view.getUint32(21, true)
      return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 }
    }
    if (chunk === "VP8X") {
      return {
        width: 1 + (bytes[24] | bytes[25] << 8 | bytes[26] << 16),
        height: 1 + (bytes[27] | bytes[28] << 8 | bytes[29] << 16),
      }
    }
    return null
  }
  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    let i = 2
    while (i + 9 < bytes.length) {
      if (bytes[i] !== 0xff) return null
      const marker = bytes[i + 1]
      const length = view.getUint16(i + 2)
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { width: view.getUint16(i + 7), height: view.getUint16(i + 5) }
      }
      i += 2 + length
    }
  }
  return null
}

// True when the app's fill-crop into a box of `ratio` pushes part of the bike out of view, or
// leaves it touching the box edge.
export function appCutsSubject(
  width: number, height: number, box: { x: number; y: number; w: number; h: number }, ratio: number,
): boolean {
  const visibleW = Math.min(width, height * ratio)
  const visibleH = Math.min(height, width / ratio)
  const left = (width - visibleW) / 2 + visibleW * MIN_EDGE
  const top = (height - visibleH) / 2 + visibleH * MIN_EDGE
  return box.x < left || box.x + box.w > width - left || box.y < top || box.y + box.h > height - top
}

let webpReady: Promise<unknown> | null = null

// BellaBike serves some photos as WebP behind .jpg names, and imagescript can't decode WebP.
async function decodeImage(bytes: Uint8Array): Promise<Image | null> {
  if (!isWebp(bytes)) {
    const decoded = await decode(bytes)
    return decoded instanceof Image ? decoded : null
  }
  // Loaded on the first WebP only, so JPEG/PNG calls don't pay for the 184 KB module.
  webpReady ??= import("./webpDecWasm.ts")
    .then(({ WEBP_DEC_WASM_BASE64 }) => WebAssembly.compile(decodeBase64(WEBP_DEC_WASM_BASE64) as Uint8Array<ArrayBuffer>))
    .then((module) => initWebp(module))
  const whole = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength
  let decoded: ImageData
  try {
    await webpReady
    decoded = await decodeWebp((whole ? bytes : bytes.slice()).buffer as ArrayBuffer)
  } catch (err) {
    // jsquash keeps a failed codec start; the next WebP starts the codec again. A bad file resets it too
    // (reloads the 184 KB wasm): if WebP failures show up, reset only when `await webpReady` throws.
    webpReady = null
    throw err
  }
  const { width, height, data } = decoded
  const image = new Image(width, height)
  image.bitmap.set(data)
  return image
}

// JPEG bytes of the normalised photo, or null to keep the original: a real background, or a studio
// shot the app already shows whole. The bike is never resampled (that jags thin spokes): only the
// studio-coloured canvas around it grows to the margin and the 3:2 shape.
export async function normalizeBikeImage(source: Uint8Array): Promise<Uint8Array | null> {
  const size = imageSize(source)
  if (size && size.width * size.height > MAX_PIXELS) return null
  const decoded = await decodeImage(source)
  if (!decoded) return null
  const box = subjectBox(decoded)
  if (!box) return null
  if (!APP_BOX_RATIOS.some((r) => appCutsSubject(decoded.width, decoded.height, box, r))) return null

  const subject = decoded.clone().crop(box.x, box.y, box.w, box.h)
  const width = Math.ceil(Math.max(box.w, box.h * ASPECT) / (1 - 2 * MARGIN))
  const height = Math.ceil(width / ASPECT)
  const placed = { x: Math.round((width - box.w) / 2), y: Math.round((height - box.h) / 2), w: box.w, h: box.h }
  if (APP_BOX_RATIOS.some((r) => appCutsSubject(width, height, placed, r))) {
    throw new Error(`copy still cut by the rule: ${width}x${height}, bike ${box.w}x${box.h}`)
  }
  const canvas = new Image(width, height).fill(box.background)
  canvas.composite(subject, placed.x, placed.y)
  return await canvas.encodeJPEG(92)
}
