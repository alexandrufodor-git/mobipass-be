// Bike photo normalisation: trim the studio border around the bike, then centre it on white
// with the same margin on every bike, so catalog cards show every bike whole and at one size.

import { decode, Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts"

const ASPECT = 3 / 2 // the app's image box
const MARGIN = 0.06
const WHITE_MIN = 240 // r, g and b all at or above this read as studio background
const MIN_BACKGROUND_BORDER = 0.9 // below this the photo has a real background: leave it

const isBackground = (r: number, g: number, b: number, a: number) =>
  a < 16 || (r >= WHITE_MIN && g >= WHITE_MIN && b >= WHITE_MIN)

// Bounding box of the bike, or null when the photo isn't a studio shot (or is empty).
export function subjectBox(img: Image): { x: number; y: number; w: number; h: number } | null {
  const { width, height, bitmap } = img
  const bg = (x: number, y: number) => {
    const i = (y * width + x) * 4
    return isBackground(bitmap[i], bitmap[i + 1], bitmap[i + 2], bitmap[i + 3])
  }

  let border = 0, borderBg = 0
  for (let x = 0; x < width; x++) {
    border += 2
    borderBg += (bg(x, 0) ? 1 : 0) + (bg(x, height - 1) ? 1 : 0)
  }
  for (let y = 0; y < height; y++) {
    border += 2
    borderBg += (bg(0, y) ? 1 : 0) + (bg(width - 1, y) ? 1 : 0)
  }
  if (borderBg / border < MIN_BACKGROUND_BORDER) return null

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
  return { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 }
}

// Bump when the rule or the output changes: every older row is re-processed.
export const RULE_VERSION = 1
const APP_BOX_RATIOS = [1.35, 1.5] // the app's image box (width / 220pt) across phone widths

// True when the app's fill-crop into a box of `ratio` would push part of the bike out of view.
export function appCutsSubject(
  width: number, height: number, box: { x: number; y: number; w: number; h: number }, ratio: number,
): boolean {
  if (width / height > ratio) {
    const off = (width - height * ratio) / 2
    return box.x < off || box.x + box.w > width - off
  }
  const off = (height - width / ratio) / 2
  return box.y < off || box.y + box.h > height - off
}

// JPEG bytes of the normalised photo, or null to keep the original: a real background, or a studio
// shot the app already shows whole. The bike is never resampled (that jags thin spokes): only the
// white canvas around it grows to the margin and the 3:2 shape.
export async function normalizeBikeImage(source: Uint8Array): Promise<Uint8Array | null> {
  const decoded = await decode(source)
  if (!(decoded instanceof Image)) return null
  const box = subjectBox(decoded)
  if (!box) return null
  if (!APP_BOX_RATIOS.some((r) => appCutsSubject(decoded.width, decoded.height, box, r))) return null

  const subject = decoded.clone().crop(box.x, box.y, box.w, box.h)
  const width = Math.ceil(Math.max(box.w, box.h * ASPECT) / (1 - 2 * MARGIN))
  const height = Math.ceil(width / ASPECT)
  const canvas = new Image(width, height).fill(0xffffffff)
  canvas.composite(subject, Math.round((width - box.w) / 2), Math.round((height - box.h) / 2))
  return await canvas.encodeJPEG(92)
}
