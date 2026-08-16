#!/usr/bin/env bash
# BellaBike nightly sync — production health audit.
#
# Usage: ./scripts/sync-audit.sh [days]   (default 14)
#
# Read-only. Answers: did the sync fire, did it succeed, did it actually change
# anything, and is the catalog the app reads still well-formed.
set -euo pipefail

DAYS="${1:-14}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

q() { supabase db query --linked "$1" 2>/dev/null | python3 -c '
import sys, json
try:
    rows = json.load(sys.stdin).get("rows", [])
except Exception:
    print("  (query failed)"); sys.exit()
if not rows:
    print("  (no rows)"); sys.exit()
cols = list(rows[0].keys())
w = {c: max(len(c), *(len(str(r.get(c, ""))) for r in rows)) for c in cols}
print("  " + "  ".join(c.ljust(w[c]) for c in cols))
print("  " + "  ".join("-" * w[c] for c in cols))
for r in rows:
    print("  " + "  ".join(str(r.get(c, "")).ljust(w[c]) for c in cols))
'; }

echo "═══ BellaBike sync audit — last $DAYS days ═══"

echo
echo "── 1. Schedule (all must be active) ──"
q "select jobname, schedule, active from cron.job where jobname like 'bike-sync%' order by jobname;"

echo
echo "── 2. Cron dispatch (any 'failed' row is a red flag) ──"
q "select j.jobname, d.status, count(*) as runs, max(d.start_time)::timestamp(0) as last_fire
   from cron.job_run_details d join cron.job j on j.jobid = d.jobid
   where j.jobname like 'bike-sync%' and d.start_time > now() - interval '$DAYS days'
   group by 1,2 order by 1,2;"

echo
echo "── 3. Runs (status must be 'succeeded'; n_failed must be 0) ──"
q "select started_at::timestamp(0) as started, mode, status,
          extract(epoch from (finished_at - started_at))::int as secs,
          n_fetched, n_inserted, n_updated, n_failed, n_delisted,
          left(coalesce(error, ''), 40) as err
   from public.sync_runs
   where started_at > now() - interval '$DAYS days'
   order by started_at desc;"

echo
echo "── 4. Missed nights (expect one run per calendar day) ──"
q "select d::date as missing_day
   from generate_series(now() - interval '$DAYS days', now() - interval '1 day', interval '1 day') d
   where not exists (select 1 from public.sync_runs r where r.started_at::date = d::date)
   order by 1;"

echo
echo "── 5. Failed units (retry exhaustion hides inside a 'partial' run) ──"
q "select r.started_at::timestamp(0) as run, u.branch, u.kind, u.category_id,
          u.attempts, left(coalesce(u.error, ''), 50) as err
   from public.sync_units u join public.sync_runs r on r.id = u.run_id
   where u.status = 'failed' and r.started_at > now() - interval '$DAYS days'
   order by r.started_at desc limit 20;"

echo
echo "── 6. Catalog freshness ──"
q "select max(updated_at)::timestamp(0) as newest_bike_row,
          (now() - max(updated_at))::interval(0) as age,
          count(*) as total_bikes,
          count(*) filter (where in_stock) as in_stock
   from public.bikes;"

echo
echo "── 7. Image health (what the app's carousel renders) ──"
q "select count(*) as bikes,
          count(*) filter (where images is null) as null_images,
          count(*) filter (where jsonb_typeof(images) <> 'array') as not_an_array,
          count(*) filter (where jsonb_array_length(images) = 0) as empty_gallery,
          count(*) filter (where jsonb_array_length(images) >= 2) as multi_image,
          round(100.0 * count(*) filter (where jsonb_array_length(images) >= 2) / nullif(count(*), 0), 1) as pct_multi
   from public.bikes where in_stock;"

echo
echo "── 8. E2E fixture invariant (dashboard-main carousel section) ──"
echo "   Every in-stock 'Sub Tour' must have >=2 images, else the Maestro"
echo "   carousel assertion goes flaky. multi must equal matches."
q "select count(*) as matches,
          count(*) filter (where jsonb_array_length(images) >= 2) as multi
   from public.bikes where in_stock and name ilike '%Sub Tour%';"

echo
echo "── 9. Pricing completeness (nulls break the catalog price card) ──"
q "select count(*) as in_stock,
          count(*) filter (where full_price is null or full_price <= 0) as bad_price,
          count(*) filter (where image_url is null) as no_hero_image
   from public.bikes where in_stock;"

echo
echo "═══ end ═══"
