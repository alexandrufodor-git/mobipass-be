// Blind index for PII lookup.
//
// HMAC-SHA256 keyed with the same pii_encryption_key the application uses
// for AES-GCM encryption. A domain-separator prefix prevents the HMAC from
// being confusable with anything in the encryption space, and reserves a
// version slot ("v1") for future re-keying.
//
// Output is base64url (URL-safe, no padding) so it can travel in JSON,
// query strings, and SQL text columns without encoding hassles.

import type { RestClient } from "./supabaseRest.ts"
import { loadPiiKey } from "./piiCrypto.ts"

const DOB_DOMAIN = "pii_lookup:dob:v1:"

let _cachedHmacKey: CryptoKey | null = null

async function getHmacKey(db: RestClient): Promise<CryptoKey> {
  if (_cachedHmacKey) return _cachedHmacKey
  const bytes = await loadPiiKey(db)
  _cachedHmacKey = await crypto.subtle.importKey(
    "raw",
    bytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  )
  return _cachedHmacKey
}

function toBase64Url(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf)
  let bin = ""
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/**
 * HMAC-SHA256(pii_encryption_key, "pii_lookup:dob:v1:" + isoDob) → base64url.
 * Returns null when iso is null/empty so callers can pass through optional
 * DOB fields without branching.
 */
export async function birthDateHash(
  db: RestClient,
  iso: string | null | undefined,
): Promise<string | null> {
  if (!iso) return null
  const key = await getHmacKey(db)
  const data = new TextEncoder().encode(DOB_DOMAIN + iso)
  const sig = await crypto.subtle.sign("HMAC", key, data)
  return toBase64Url(sig)
}
