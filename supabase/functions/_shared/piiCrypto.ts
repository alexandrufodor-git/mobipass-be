// supabase/functions/_shared/piiCrypto.ts
//
// AES-256-GCM application-level encryption for PII fields.
// Key is loaded from Supabase Vault (`pii_encryption_key`) — falls back to
// the PII_ENCRYPTION_KEY env var for local dev without a running Vault.
//
// Ciphertext format:
//   "enc:v1:" || base64( 12-byte IV || ciphertext || 16-byte GCM auth tag )
//
// The `enc:v1:` prefix is a self-identifying marker: it lets us distinguish
// encrypted values from plaintext (migration) deterministically, and reserves
// a version slot for future key/algorithm rotation.

import type { RestClient } from "./supabaseRest.ts"

const IV_BYTES = 12
const CIPHERTEXT_PREFIX = "enc:v1:"
const VAULT_KEY_NAME = "pii_encryption_key"

// Cached values for the lifetime of the edge function invocation.
let _cachedKey: CryptoKey | null = null
let _cachedKeyBytes: Uint8Array<ArrayBuffer> | null = null

/**
 * Load the raw 32-byte PII key from Vault (preferred) or PII_ENCRYPTION_KEY
 * env var (local dev fallback). Cached per instance.
 *
 * Exposed for callers that need the raw bytes for a different WebCrypto
 * algorithm (e.g. HMAC-SHA256 for blind indexes — see piiLookup.ts).
 * AES-GCM encrypt/decrypt callers should use getEncryptionKey() instead.
 */
export async function loadPiiKey(db: RestClient): Promise<Uint8Array<ArrayBuffer>> {
  if (_cachedKeyBytes) return _cachedKeyBytes

  // Prefer Vault (production). Fall back to env var for local dev where
  // vault.create_secret may not be set up.
  let keyB64 = await db.rpc<string | null>("get_vault_secret", { secret_name: VAULT_KEY_NAME })
  if (!keyB64) {
    keyB64 = Deno.env.get("PII_ENCRYPTION_KEY") ?? null
  }
  if (!keyB64) {
    throw new Error("PII encryption key not found in Vault (pii_encryption_key) or env (PII_ENCRYPTION_KEY)")
  }

  const decoded = atob(keyB64)
  if (decoded.length !== 32) {
    throw new Error(`PII encryption key must be exactly 32 bytes (got ${decoded.length})`)
  }

  // Build on an explicit ArrayBuffer so WebCrypto's importKey accepts the
  // BufferSource without needing a cast (Uint8Array<ArrayBufferLike> is too
  // wide for the BufferSource overload under strict lib types).
  const buf = new ArrayBuffer(32)
  const keyBytes = new Uint8Array(buf)
  for (let i = 0; i < 32; i++) keyBytes[i] = decoded.charCodeAt(i)

  _cachedKeyBytes = keyBytes
  return _cachedKeyBytes
}

/** Load the AES-256-GCM key: Vault first, env var fallback. Cached per instance. */
export async function getEncryptionKey(db: RestClient): Promise<CryptoKey> {
  if (_cachedKey) return _cachedKey

  const keyBytes = await loadPiiKey(db)

  _cachedKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "AES-GCM" },
    false, // not extractable
    ["encrypt", "decrypt"]
  )

  return _cachedKey
}

/** True iff the value starts with the ciphertext marker (i.e. it's encrypted). */
export function isEncrypted(value: string): boolean {
  return value.startsWith(CIPHERTEXT_PREFIX)
}

/** Encrypt a plaintext string → "enc:v1:<base64>" blob suitable for a TEXT column. */
export async function encrypt(db: RestClient, plaintext: string): Promise<string> {
  const key = await getEncryptionKey(db)
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES))
  const encoded = new TextEncoder().encode(plaintext)

  const ciphertextBuf = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    encoded
  )

  // IV || ciphertext+authTag
  const combined = new Uint8Array(iv.length + ciphertextBuf.byteLength)
  combined.set(iv)
  combined.set(new Uint8Array(ciphertextBuf), iv.length)

  return CIPHERTEXT_PREFIX + btoa(String.fromCharCode(...combined))
}

/** Decrypt a "enc:v1:<base64>" blob back to the original plaintext. Throws if the marker is missing. */
export async function decrypt(db: RestClient, ciphertext: string): Promise<string> {
  if (!isEncrypted(ciphertext)) {
    throw new Error("Value is not encrypted (missing enc:v1: marker)")
  }

  const body = ciphertext.slice(CIPHERTEXT_PREFIX.length)
  const key = await getEncryptionKey(db)
  const combined = Uint8Array.from(atob(body), (c) => c.charCodeAt(0))

  if (combined.length < IV_BYTES + 16) {
    throw new Error("Ciphertext too short to be valid AES-256-GCM")
  }

  const iv = combined.slice(0, IV_BYTES)
  const data = combined.slice(IV_BYTES)

  const decryptedBuf = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv },
    key,
    data
  )

  return new TextDecoder().decode(decryptedBuf)
}

/**
 * Encrypt specified fields of an object, returning a new object with the
 * destination keys renamed to `${field}_encrypted`. Skips null/undefined/empty.
 * `null` is preserved to allow explicit clears by the write endpoint.
 */
export async function encryptFields<T extends Record<string, unknown>>(
  db: RestClient,
  obj: T,
  fields: (keyof T & string)[]
): Promise<Record<string, unknown>> {
  const result: Record<string, unknown> = {}
  for (const field of fields) {
    const value = obj[field]
    if (value === undefined) continue
    const destKey = `${field}_encrypted`
    if (value === null) {
      result[destKey] = null
    } else if (typeof value === "string" && value !== "") {
      result[destKey] = await encrypt(db, value)
    } else if (typeof value === "number") {
      result[destKey] = await encrypt(db, String(value))
    }
  }
  return result
}

/**
 * Decrypt specified `${field}_encrypted` columns on a DB row, returning an
 * object keyed by the plain field names. Null/empty stay null; everything
 * else must carry the `enc:v1:` marker or `decrypt` will throw.
 */
export async function decryptFields<T extends Record<string, unknown>>(
  db: RestClient,
  row: T,
  fields: string[]
): Promise<Record<string, string | null>> {
  const result: Record<string, string | null> = {}
  for (const field of fields) {
    const src = row[`${field}_encrypted` as keyof T] as string | null | undefined
    result[field] = src == null || src === "" ? null : await decrypt(db, src)
  }
  return result
}
