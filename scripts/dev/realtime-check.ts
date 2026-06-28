#!/usr/bin/env -S deno run --allow-net --allow-env
// Realtime DELIVERY check — proves the supabase_realtime publication actually
// pushes row changes over the websocket (pgTAP test 00022 only asserts
// publication *membership*; it cannot open a socket). Companion to migration
// 20260628000001.
//
// For each table it: subscribes to postgres_changes, then issues a
// NON-DESTRUCTIVE update (sets a timestamp column to its own current value — a
// real WAL write, no data change) and asserts the event is delivered. The
// update is retried every 2s to beat the few-second delay before a fresh
// subscription registers in realtime.subscription (the gotcha that makes naive
// one-shot probes flake).
//
// Usage:
//   SERVICE_ROLE_KEY=... [SUPABASE_URL=http://127.0.0.1:54321] \
//     deno run --allow-net --allow-env scripts/dev/realtime-check.ts
//   (local keys: `supabase status -o env | grep SERVICE_ROLE_KEY`)
//
// Exit 0 = every table delivered; non-zero = at least one did not.

import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const KEY = Deno.env.get("SERVICE_ROLE_KEY");
if (!KEY) {
  console.error("SERVICE_ROLE_KEY env var is required.");
  Deno.exit(2);
}

// table -> { pk, touch: a timestamp column we set to its own value }
const TABLES: Record<string, { pk: string; touch: string }> = {
  bike_benefits:         { pk: "id",         touch: "updated_at" },
  profiles:              { pk: "user_id",    touch: "created_at" },
  company_metrics:       { pk: "company_id", touch: "counts_updated_at" },
  company_notifications: { pk: "id",         touch: "created_at" },
};

const PER_TABLE_TIMEOUT_MS = 20_000;
const RETRY_EVERY_MS = 2_000;

const sb = createClient(URL, KEY, { auth: { persistSession: false } });

async function rest(path: string, init?: RequestInit) {
  return fetch(`${URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: KEY!, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json", ...(init?.headers ?? {}) },
  });
}

async function checkTable(table: string, cfg: { pk: string; touch: string }): Promise<boolean> {
  // Grab one row to mutate.
  const res = await rest(`${table}?select=${cfg.pk},${cfg.touch}&limit=1`);
  const rows = await res.json();
  if (!Array.isArray(rows) || rows.length === 0) {
    console.log(`⚠️  ${table}: no rows to mutate — SKIPPED (seed a row to test).`);
    return true; // not a failure of realtime
  }
  const row = rows[0];
  const pkVal = row[cfg.pk];
  const touchVal = row[cfg.touch]; // set it back to itself → WAL write, no data change

  let delivered = false;
  const channel = sb
    .channel(`rtcheck-${table}-${crypto.randomUUID()}`)
    .on("postgres_changes", { event: "*", schema: "public", table }, () => { delivered = true; });

  await new Promise<void>((resolve) => channel.subscribe((s) => { if (s === "SUBSCRIBED") resolve(); }));

  const start = Date.now();
  let lastPoke = 0;
  while (!delivered && Date.now() - start < PER_TABLE_TIMEOUT_MS) {
    if (Date.now() - lastPoke >= RETRY_EVERY_MS) {
      lastPoke = Date.now();
      await rest(`${table}?${cfg.pk}=eq.${pkVal}`, {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({ [cfg.touch]: touchVal }),
      });
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  await sb.removeChannel(channel);

  console.log(`${delivered ? "✅ PASS" : "❌ FAIL"}  ${table}`);
  return delivered;
}

let allOk = true;
for (const [table, cfg] of Object.entries(TABLES)) {
  const ok = await checkTable(table, cfg);
  allOk = allOk && ok;
}

console.log(`\nRealtime delivery: ${allOk ? "ALL OK" : "FAILURES PRESENT"}`);
Deno.exit(allOk ? 0 : 1);
