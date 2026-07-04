// Unit tests for the FCM helper (supabase/functions/_shared/fcm.ts).
// Run with: deno test --allow-env supabase/functions/_shared/fcm.test.ts
//
// Auth is keyless (Workload Identity Federation): getAccessToken() signs an RS256
// JWT with the Vault key `fcm_wif_private_key`, exchanges it at Google STS, then
// impersonates the Firebase Admin SDK SA. The mocks below stub those two hops.

import { assertEquals } from "jsr:@std/assert"
import { stub } from "jsr:@std/testing/mock"
import { sendFcm, type FcmNotification } from "./fcm.ts"
import type { RestClient } from "./supabaseRest.ts"

const STS_HOST = "sts.googleapis.com"
const IAM_HOST = "iamcredentials.googleapis.com"
const FCM_HOST = "fcm.googleapis.com"

// ─── Test helpers ────────────────────────────────────────────────────────────

/** A real RSA-2048 PKCS8 PEM so the JWT signing path in getAccessToken() runs. */
async function makePrivateKeyPem(): Promise<string> {
  const kp = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
    true,
    ["sign", "verify"],
  )
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", kp.privateKey)
  const b64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)))
  return `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`
}

/**
 * Mock RestClient. rpc() returns values in call order:
 *   call 0 → fcm_wif_private_key vault secret (PEM or null)
 */
function makeMockDb(rpcReturns: (string | null)[], getOneReturn: unknown = null): RestClient {
  let rpcCall = 0
  return {
    getOne: () => Promise.resolve(getOneReturn as never),
    post: () => Promise.resolve(new Response(null, { status: 201 })),
    upsert: () => Promise.resolve(new Response(null, { status: 201 })),
    patch: () => Promise.resolve(),
    rpc: () => Promise.resolve((rpcReturns[rpcCall++] ?? null) as never),
  }
}

const NOTIFICATION: FcmNotification = {
  title: "Contract Ready",
  body: "Your contract is ready to sign.",
  event: "contract_ready",
  bikeBenefitId: "benefit-uuid-001",
}

/** Stub fetch: STS + impersonation succeed; FCM handled by `onFcm`. */
function stubHappyAuth(onFcm: (url: string, init?: RequestInit) => Response) {
  return stub(globalThis, "fetch", (input: unknown, init?: unknown): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input)
    if (url.includes(STS_HOST)) {
      return Promise.resolve(new Response(JSON.stringify({ access_token: "fed-token" }), { status: 200 }))
    }
    if (url.includes(IAM_HOST)) {
      return Promise.resolve(new Response(JSON.stringify({ accessToken: "ya29.imp-token" }), { status: 200 }))
    }
    if (url.includes(FCM_HOST)) return Promise.resolve(onFcm(url, init as RequestInit | undefined))
    throw new Error(`Unexpected fetch call: ${url}`)
  })
}

const noFetch = () => { throw new Error("fetch must not be called") }

// ─── Tests ───────────────────────────────────────────────────────────────────

Deno.test("sendFcm: returns early when profile is not found", async () => {
  const fetchStub = stub(globalThis, "fetch", noFetch)
  try {
    await sendFcm(makeMockDb([await makePrivateKeyPem()], null), "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when fcm_token is null", async () => {
  const fetchStub = stub(globalThis, "fetch", noFetch)
  try {
    await sendFcm(makeMockDb([await makePrivateKeyPem()], { fcm_token: null }), "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when WIF private key vault secret is missing", async () => {
  const fetchStub = stub(globalThis, "fetch", noFetch)
  try {
    // profile has a token, but the vault key is absent → no token exchange attempted
    await sendFcm(makeMockDb([null], { fcm_token: "device-token" }), "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when WIF private key is not a valid PEM", async () => {
  const fetchStub = stub(globalThis, "fetch", noFetch)
  try {
    const db = makeMockDb(["-----BEGIN PRIVATE KEY-----\nnot-base64-!!!\n-----END PRIVATE KEY-----"], { fcm_token: "device-token" })
    await sendFcm(db, "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when STS token exchange fails", async () => {
  let fcmCalled = false
  const fetchStub = stub(globalThis, "fetch", (input: unknown): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input)
    if (url.includes(STS_HOST)) return Promise.resolve(new Response("Unauthorized", { status: 401 }))
    if (url.includes(FCM_HOST)) { fcmCalled = true }
    return Promise.resolve(new Response("{}", { status: 200 }))
  })
  try {
    await sendFcm(makeMockDb([await makePrivateKeyPem()], { fcm_token: "device-token" }), "user-uuid", NOTIFICATION)
    assertEquals(fcmCalled, false, "FCM must not be called when STS fails")
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: returns early when SA impersonation fails", async () => {
  let fcmCalled = false
  const fetchStub = stub(globalThis, "fetch", (input: unknown): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input)
    if (url.includes(STS_HOST)) return Promise.resolve(new Response(JSON.stringify({ access_token: "fed-token" }), { status: 200 }))
    if (url.includes(IAM_HOST)) return Promise.resolve(new Response("PERMISSION_DENIED", { status: 403 }))
    if (url.includes(FCM_HOST)) { fcmCalled = true }
    return Promise.resolve(new Response("{}", { status: 200 }))
  })
  try {
    await sendFcm(makeMockDb([await makePrivateKeyPem()], { fcm_token: "device-token" }), "user-uuid", NOTIFICATION)
    assertEquals(fcmCalled, false, "FCM must not be called when impersonation fails")
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: sends push with correct payload on happy path", async () => {
  const fcmCalls: { url: string; headers: Record<string, string>; body: unknown }[] = []
  const fetchStub = stubHappyAuth((url, init) => {
    fcmCalls.push({
      url,
      headers: Object.fromEntries(new Headers(init?.headers as HeadersInit).entries()),
      body: init?.body ? JSON.parse(init.body as string) : null,
    })
    return new Response("{}", { status: 200 })
  })
  try {
    await sendFcm(makeMockDb([await makePrivateKeyPem()], { fcm_token: "device-token-xyz" }), "user-uuid", NOTIFICATION)

    assertEquals(fcmCalls.length, 1, "FCM must be called exactly once")
    assertEquals(fcmCalls[0].url, "https://fcm.googleapis.com/v1/projects/mobipass-a9056/messages:send")
    assertEquals(fcmCalls[0].headers["authorization"], "Bearer ya29.imp-token")

    const msg = (fcmCalls[0].body as { message: Record<string, unknown> }).message
    assertEquals(msg.token, "device-token-xyz")
    assertEquals((msg.notification as Record<string, string>).title, NOTIFICATION.title)
    assertEquals((msg.notification as Record<string, string>).body, NOTIFICATION.body)
    assertEquals((msg.data as Record<string, string>).event, "contract_ready")
    assertEquals((msg.data as Record<string, string>).bike_benefit_id, "benefit-uuid-001")
  } finally {
    fetchStub.restore()
  }
})

Deno.test("sendFcm: handles FCM API error gracefully without throwing", async () => {
  const fetchStub = stubHappyAuth(() => new Response("UNREGISTERED", { status: 404 }))
  try {
    // Must complete without throwing
    await sendFcm(makeMockDb([await makePrivateKeyPem()], { fcm_token: "stale-token" }), "user-uuid", NOTIFICATION)
  } finally {
    fetchStub.restore()
  }
})
