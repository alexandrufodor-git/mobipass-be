#!/usr/bin/env bash
# BellaBike nightly sync — production health audit.
#
# Usage: ./scripts/sync-audit.sh [days]   (default 14)
#
# Read-only. Answers: did the sync fire, did it succeed, did it actually change
# anything, and is the catalog the app reads still well-formed.
# Sections 10-17 cover bike photo normalisation (bike-images-nightly + bike-images-tick, a lease
# queue like the sync): runs, live progress, calls killed by the CPU limit, coverage, failed
# photos and storage.
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
echo "── 10. Images · Schedule (both must be active) ──"
q "select jobname, schedule, active from cron.job where jobname like 'bike-images%' order by jobname;"

echo
echo "── 11. Images · Cron dispatch (any 'failed' row is a red flag) ──"
q "select j.jobname, d.status, count(*) as fires, max(d.start_time)::timestamp(0) as last_fire
   from cron.job_run_details d join cron.job j on j.jobid = d.jobid
   where j.jobname like 'bike-images%' and d.start_time > now() - interval '$DAYS days'
   group by 1,2 order by 1,2;"

echo
echo "── 12. Images · Runs (status must be 'succeeded'; 'partial' = some photos failed 3 times) ──"
q "select started_at::timestamp(0) as started, mode, status, n_units as units, n_normalized as normalized,
          n_kept as kept, n_unchanged as unchanged, n_failed as failed,
          round(bytes_downloaded / 1048576.0, 1) as mb_down, round(bytes_stored / 1048576.0, 1) as mb_stored,
          round(extract(epoch from coalesce(finished_at, now()) - started_at) / 60)::int as minutes
   from public.bike_image_runs where started_at > now() - interval '$DAYS days' order by started_at desc;"

echo
echo "── 13. Images · Live progress of a running run ──"
q "select r.started_at::timestamp(0) as run, u.status, count(*) as units, sum(u.attempts) as attempts
   from public.bike_image_runs r join public.bike_image_units u on u.run_id = r.id
   where r.status = 'running' group by 1,2 order by 1,2;"

echo
echo "── 14. Images · Edge calls (546 = killed by the 2 s CPU limit; pg_net keeps ~6 h) ──"
q "select date_trunc('hour', created)::timestamp(0) as hour, status_code, count(*) as calls
   from net._http_response
   where created > now() - interval '6 hours' and (content like '%claimed%' or content like '%finalized%'
         or content like '%WORKER_RESOURCE_LIMIT%' or content like '%dry_run%')
   group by 1,2 order by 1 desc, 2;"

echo
echo "── 15. Images · Coverage: photos in the feed vs decided ──"
q "with feed as (
     select distinct src.url from public.bikes b join public.bike_models m on m.id = b.model_id
     cross join lateral jsonb_array_elements_text(m.images) as src(url) where b.active)
   select (select count(*) from feed) as photos_in_feed,
          (select count(*) from public.bike_images where status = 'normalized') as normalized,
          (select count(*) from public.bike_images where status = 'kept') as kept,
          (select count(*) from public.bike_images where status = 'failed') as failed,
          (select count(*) from public.bike_images_due(1000000, public.bike_images_rule_version())) as due_now,
          (select count(*) from public.bikes where images::text like '%/bike-images/%') as bikes_showing_copies;"

echo
echo "── 16. Images · Failed units (3 tries; the app shows the original; due again next night) ──"
q "select u.finished_at::timestamp(0) as failed_at, u.attempts, left(coalesce(u.error, ''), 50) as error,
          right(u.source_url, 60) as source
   from public.bike_image_units u
   where u.status = 'failed' and u.finished_at > now() - interval '$DAYS days'
   order by u.finished_at desc limit 15;"

echo
echo "── 17. Images · Storage: our copies in the bike-images bucket ──"
q "select count(*) as files, round(sum((metadata->>'size')::bigint) / 1048576.0, 1) as mb,
          count(*) filter (where name like 'dry-run/%') as dry_run_files
   from storage.objects where bucket_id = 'bike-images';"

echo
echo "═══ end ═══"
