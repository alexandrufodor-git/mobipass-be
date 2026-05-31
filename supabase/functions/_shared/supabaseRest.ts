// Thin REST client factory for Supabase PostgREST + RPC calls.
// Keeps fetch boilerplate in one place so edge functions stay readable.

export interface RestClient {
  getOne<T>(table: string, filter: string, select?: string): Promise<T | null>
  post(table: string, body: unknown): Promise<Response>
  upsert(table: string, body: unknown, onConflict?: string): Promise<Response>
  patch(table: string, filter: string, body: unknown): Promise<void>
  rpc<T>(funcName: string, args: unknown): Promise<T>
}

export function makeRestClient(supabaseUrl: string, serviceKey: string): RestClient {
  const baseHeaders = {
    Authorization: `Bearer ${serviceKey}`,
    apikey: serviceKey,
    "Content-Type": "application/json",
  }

  async function getOne<T>(table: string, filter: string, select = "*"): Promise<T | null> {
    const res = await fetch(
      `${supabaseUrl}/rest/v1/${table}?${filter}&select=${select}`,
      { headers: baseHeaders }
    )
    const rows: T[] = await res.json()
    return rows[0] ?? null
  }

  async function post(table: string, body: unknown): Promise<Response> {
    return fetch(`${supabaseUrl}/rest/v1/${table}`, {
      method: "POST",
      headers: { ...baseHeaders, Prefer: "return=minimal" },
      body: JSON.stringify(body),
    })
  }

  async function upsert(table: string, body: unknown, onConflict?: string): Promise<Response> {
    const url = onConflict
      ? `${supabaseUrl}/rest/v1/${table}?on_conflict=${encodeURIComponent(onConflict)}`
      : `${supabaseUrl}/rest/v1/${table}`
    return fetch(url, {
      method: "POST",
      headers: { ...baseHeaders, Prefer: "return=minimal,resolution=merge-duplicates" },
      body: JSON.stringify(body),
    })
  }

  async function patch(table: string, filter: string, body: unknown): Promise<void> {
    await fetch(`${supabaseUrl}/rest/v1/${table}?${filter}`, {
      method: "PATCH",
      headers: { ...baseHeaders, Prefer: "return=minimal" },
      body: JSON.stringify(body),
    })
  }

  async function rpc<T>(funcName: string, args: unknown): Promise<T> {
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${funcName}`, {
      method: "POST",
      headers: baseHeaders,
      body: JSON.stringify(args),
    })
    return res.json()
  }

  return { getOne, post, upsert, patch, rpc }
}
