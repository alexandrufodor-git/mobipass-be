// Firebase Cloud Messaging HTTP v1 helper.
// Auth via GCP Workload Identity Federation (keyless — no service-account key).
// We sign a short-lived RS256 JWT with our OWN OIDC key (Vault: fcm_wif_private_key,
// public JWK registered in the WIF provider `supabase-fcm` on mobipass-a9056),
// exchange it at Google STS for a federated token, then impersonate the Firebase
// Admin SDK service account to get an FCM-scoped access token used as the bearer.

import { type NotificationEventType } from "./constants.ts"
import type { RestClient } from "./supabaseRest.ts"

// ─── Workload Identity Federation config (non-secret) ────────────────────────

const WIF_PRIVATE_KEY_VAULT = "fcm_wif_private_key"
const FIREBASE_PROJECT_ID = "mobipass-a9056"
const SA_EMAIL = "firebase-adminsdk-fbsvc@mobipass-a9056.iam.gserviceaccount.com"

const JWT_ISS = "https://securetoken.mobipass.eu"
const JWT_SUB = "mobipass-fcm-sender"
const JWT_AUD = "mobipass-fcm"
const JWT_KID = "mobipass-fcm-1"
const STS_AUDIENCE =
  "//iam.googleapis.com/projects/364973126807/locations/global/workloadIdentityPools/supabase-pool/providers/supabase-fcm"

const STS_URL = "https://sts.googleapis.com/v1/token"
const IAM_CREDENTIALS_URL =
  `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SA_EMAIL}:generateAccessToken`
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

// ─── Google access token via WIF ─────────────────────────────────────────────

function base64url(input: Uint8Array): string {
  let binary = ""
  for (const byte of input) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

async function getAccessToken(db: RestClient): Promise<string | null> {
  const pem = await db.rpc<string | null>("get_vault_secret", { secret_name: WIF_PRIVATE_KEY_VAULT })
  if (!pem) {
    console.error("[fcm] vault secret not found:", WIF_PRIVATE_KEY_VAULT)
    return null
  }

  // Import our RS256 OIDC signing key (PKCS8 PEM).
  let cryptoKey: CryptoKey
  try {
    const pemBody = pem
      .replace(/-----BEGIN PRIVATE KEY-----/, "")
      .replace(/-----END PRIVATE KEY-----/, "")
      .replace(/\s/g, "")
    const keyBytes = Uint8Array.from(atob(pemBody), (c: string) => c.charCodeAt(0))
    cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      keyBytes,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    )
  } catch (e) {
    console.error("[fcm] failed to import WIF private key (expected a PKCS8 PEM):", e)
    return null
  }

  // 1. Self-issued OIDC JWT, signed with our key.
  const now = Math.floor(Date.now() / 1000)
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT", kid: JWT_KID })))
  const claims = base64url(new TextEncoder().encode(JSON.stringify({
    iss: JWT_ISS,
    sub: JWT_SUB,
    aud: JWT_AUD,
    iat: now,
    exp: now + 3600,
  })))
  const sigInput = new TextEncoder().encode(`${header}.${claims}`)
  const sig = base64url(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", cryptoKey, sigInput)))
  const assertion = `${header}.${claims}.${sig}`

  // 2. STS token exchange → short-lived federated access token.
  const stsRes = await fetch(STS_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
      audience: STS_AUDIENCE,
      scope: "https://www.googleapis.com/auth/cloud-platform",
      requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
      subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
      subject_token: assertion,
    }),
  })
  if (!stsRes.ok) {
    console.error("[fcm] STS token exchange failed:", stsRes.status, await stsRes.text().catch(() => ""))
    return null
  }
  const federatedToken = (await stsRes.json()).access_token as string

  // 3. Impersonate the Firebase Admin SDK SA → FCM-scoped access token.
  const impRes = await fetch(IAM_CREDENTIALS_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${federatedToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ scope: [FCM_SCOPE] }),
  })
  if (!impRes.ok) {
    console.error("[fcm] SA impersonation failed:", impRes.status, await impRes.text().catch(() => ""))
    return null
  }
  return (await impRes.json()).accessToken as string
}

// ─── Send FCM push ──────────────────────────────────────────────────────────

export interface FcmNotification {
  title: string
  body: string
  event: NotificationEventType
  bikeBenefitId: string
}

export async function sendFcm(
  db: RestClient,
  userId: string,
  notification: FcmNotification,
): Promise<void> {
  // Look up FCM token
  const profile = await db.getOne<{ fcm_token: string | null }>(
    "profiles",
    `user_id=eq.${encodeURIComponent(userId)}`,
    "fcm_token",
  )
  if (!profile?.fcm_token) {
    console.log("[fcm] no fcm_token for user:", userId)
    return
  }

  const accessToken = await getAccessToken(db)
  if (!accessToken) return

  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token: profile.fcm_token,
          notification: { title: notification.title, body: notification.body },
          data: { event: notification.event, bike_benefit_id: notification.bikeBenefitId },
        },
      }),
    },
  )

  if (!res.ok) {
    const detail = await res.text().catch(() => "")
    console.error("[fcm] send failed:", res.status, detail)
  } else {
    console.log("[fcm] sent to user:", userId)
  }
}
