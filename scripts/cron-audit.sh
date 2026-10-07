#!/usr/bin/env bash
# pg_cron + database size — production audit and cleanup.
#
# Usage:
#   ./scripts/cron-audit.sh                              read-only report
#   ./scripts/cron-audit.sh cache list                   sync cache per run: date, status, size
#   ./scripts/cron-audit.sh cache show <run_id> [scope]  peek inside a run's cache (no scope = list its scopes)
#   ./scripts/cron-audit.sh cache prune [--keep-days N] [--apply]    default 7 days
#   ./scripts/cron-audit.sh history prune [--keep-days N] [--apply]  default 14 days
#   ./scripts/cron-audit.sh reports prune [--keep-days N] [--apply]  default 14 days
#
# Prunes are dry runs unless --apply is given. Deleted space is reused by Postgres;
# the reported database size may only drop after VACUUM FULL on that table.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The CLI sorts columns alphabetically; returning the rows as JSON text keeps the query's order.
# DELETE ... RETURNING can't sit in a subquery, so the prunes pass raw=1 (single-column results).
q() {
  local sql="${1%;*}"
  [[ "${2:-}" == raw ]] || sql="select coalesce(json_agg(t), '[]')::text as j from ($sql) t"
  local err; err=$(mktemp)
  supabase db query --linked -o json --agent no "$sql" 2>"$err" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    rows = data if isinstance(data, list) else data.get("rows", [])
    if rows and list(rows[0]) == ["j"]:
        rows = json.loads(rows[0]["j"])
except Exception:
    print("  (query failed)")
    for l in open(sys.argv[1]).read().splitlines():
        if l.strip() and "new version" not in l and "updating regularly" not in l:
            print("    " + l)
    sys.exit()
if not rows:
    print("  (no rows)"); sys.exit()
cols = list(rows[0].keys())
w = {c: max(len(c), *(len(str(r.get(c, ""))) for r in rows)) for c in cols}
print("  " + "  ".join(c.ljust(w[c]) for c in cols))
print("  " + "  ".join("-" * w[c] for c in cols))
for r in rows:
    print("  " + "  ".join(str(r.get(c, "")).ljust(w[c]) for c in cols))
' "$err"
  rm -f "$err"
}

# Parses --keep-days N and --apply from the remaining args.
KEEP=""; APPLY=0
parse_prune_args() {
  while (( $# )); do
    case "$1" in
      --keep-days) KEEP="$2"; shift 2 ;;
      --apply)     APPLY=1; shift ;;
      *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
  done
  [[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "--keep-days must be a number" >&2; exit 1; }
}

# Finished runs only: a running sync still reads its cache.
CACHE_OLD="from public.sync_run_cache c join public.sync_runs r on r.id = c.run_id
           where r.status <> 'running' and r.started_at < now() - interval '%s days'"

report() {
  echo "═══ Cron + database audit ═══"

  echo
  echo "── 1. Jobs ──"
  q "select jobid, jobname, schedule, active,
            left(regexp_replace(command, '\s+', ' ', 'g'), 60) as command
     from cron.job order by jobid;"

  echo
  echo "── 2. Runs per job (failed must be 0; last_run age should match the schedule) ──"
  q "select coalesce(j.jobname, '(deleted job)') as job, count(*) as runs,
            count(*) filter (where d.status <> 'succeeded') as failed,
            round(avg(extract(epoch from d.end_time - d.start_time) * 1000)) as avg_ms,
            max(d.start_time)::timestamp(0) as last_run,
            (now() - max(d.start_time))::interval(0) as age
     from cron.job_run_details d left join cron.job j using (jobid)
     group by 1 order by 2 desc;"

  echo
  echo "── 3. Recent failures (last 7 days) ──"
  q "select coalesce(j.jobname, '(deleted job)') as job, d.start_time::timestamp(0) as at,
            left(coalesce(d.return_message, ''), 70) as message
     from cron.job_run_details d left join cron.job j using (jobid)
     where d.status <> 'succeeded' and d.start_time > now() - interval '7 days'
     order by d.start_time desc limit 20;"

  echo
  echo "── 4. Database size + largest tables ──"
  q "select pg_size_pretty(pg_database_size(current_database())) as database;"
  q "select n.nspname || '.' || c.relname as table_name,
            pg_size_pretty(pg_total_relation_size(c.oid)) as size
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r'
     order by pg_total_relation_size(c.oid) desc limit 10;"

  echo
  echo "── 5. Growth candidates (what the prunes would remove) ──"
  q "select 'sync_run_cache > 7 days' as what, count(*) as rows,
            pg_size_pretty(coalesce(sum(pg_column_size(c.payload)), 0)) as payload
     $(printf "$CACHE_OLD" 7)
     union all
     select 'cron history > 14 days', count(*), '-'
     from cron.job_run_details where start_time < now() - interval '14 days'
     union all
     select 'reports > 14 days', count(*), pg_size_pretty(coalesce(sum(size_bytes), 0))
     from public.issue_reports where created_at < now() - interval '14 days';"

  echo
  echo "═══ end ═══"
}

cache_summary() {
  q "select pg_size_pretty(pg_database_size(current_database())) as database,
            pg_size_pretty(pg_total_relation_size('public.sync_run_cache')) as cache_table,
            (select count(*) from public.sync_run_cache) as rows,
            (select count(distinct run_id) from public.sync_run_cache) as runs,
            (select min(r.started_at)::date from public.sync_run_cache c join public.sync_runs r on r.id = c.run_id) as oldest,
            (select max(r.started_at)::date from public.sync_run_cache c join public.sync_runs r on r.id = c.run_id) as newest,
            pg_size_pretty((select coalesce(sum(pg_column_size(payload)), 0) from public.sync_run_cache)) as live_payload;"
}

cache_list() {
  q "select r.id as run_id, r.started_at::timestamp(0) as started, r.mode, r.status,
            count(c.*) as scopes, pg_size_pretty(sum(pg_column_size(c.payload))) as size
     from public.sync_run_cache c join public.sync_runs r on r.id = c.run_id
     group by r.id order by r.started_at desc;"
}

cache_show() {
  local run="${1:?run_id required}" scope="${2:-}"
  [[ "$run" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "run_id must be a UUID" >&2; exit 1; }
  if [[ -z "$scope" ]]; then
    q "select scope, jsonb_typeof(payload) as type,
              case jsonb_typeof(payload) when 'array' then jsonb_array_length(payload) end as items,
              pg_size_pretty(pg_column_size(payload)::bigint) as size
       from public.sync_run_cache where run_id = '$run' order by scope;"
  else
    [[ "$scope" =~ ^[a-z_]+(:[0-9]+)?$ ]] || { echo "scope looks wrong: $scope" >&2; exit 1; }
    # Arrays: first 3 items, trimmed. Objects: keys with value sizes.
    q "select case jsonb_typeof(payload)
                when 'array' then left((select jsonb_agg(e) from (select e from jsonb_array_elements(payload) e limit 3) s)::text, 1500)
                else (select string_agg(k || ' (' || pg_column_size(payload->k) || ' B)', ', ') from jsonb_object_keys(payload) k)
              end as preview
       from public.sync_run_cache where run_id = '$run' and scope = '$scope';"
  fi
}

cache_prune() {
  KEEP=7; parse_prune_args "$@"
  echo "── Sync cache of finished runs older than $KEEP days ──"
  q "select count(*) as rows, count(distinct c.run_id) as runs,
            pg_size_pretty(coalesce(sum(pg_column_size(c.payload)), 0)) as payload
     $(printf "$CACHE_OLD" "$KEEP");"
  if (( APPLY )); then
    q "with d as (delete from public.sync_run_cache c using public.sync_runs r
                  where r.id = c.run_id and r.status <> 'running'
                    and r.started_at < now() - interval '$KEEP days' returning 1)
       select count(*) as deleted from d;" raw
    q "select pg_size_pretty(pg_total_relation_size('public.sync_run_cache')) as table_size_now;"
  else
    echo "  Dry run. Add --apply to delete."
  fi
}

history_prune() {
  KEEP=14; parse_prune_args "$@"
  echo "── Cron run history older than $KEEP days ──"
  q "select count(*) as rows from cron.job_run_details where start_time < now() - interval '$KEEP days';"
  if (( APPLY )); then
    q "with d as (delete from cron.job_run_details where start_time < now() - interval '$KEEP days' returning 1)
       select count(*) as deleted from d;" raw
  else
    echo "  Dry run. Add --apply to delete."
  fi
}

# Files live in Storage, which rejects SQL deletes: --apply asks the issue-report-prune edge function (async).
reports_prune() {
  KEEP=14; parse_prune_args "$@"
  echo "── Problem reports older than $KEEP days ──"
  q "select count(*) as rows, pg_size_pretty(coalesce(sum(size_bytes), 0)) as files
     from public.issue_reports where created_at < now() - interval '$KEEP days';"
  if (( APPLY )); then
    q "select public.request_issue_reports_prune($KEEP) as net_request_id;"
    echo "  Requested. Rows and files are deleted by the edge function; re-run without --apply to confirm."
  else
    echo "  Dry run. Add --apply to delete."
  fi
}

usage() { cat <<'EOF'
cron-audit.sh — pg_cron jobs and database size, PRODUCTION (supabase db query --linked).
Needs an existing `supabase link`. Nothing is deleted without --apply.

COMMANDS
  (none)                                 Read-only report, sections below.
  cache                                  Sizes: database, cache table, live payload, oldest/newest run.
  cache list                             One line per sync run still in the cache: date, mode, status, size.
  cache show <run_id>                    The scopes stored for that run, with item counts and sizes.
  cache show <run_id> <scope>            Peek inside one scope (arrays: first 3 items; objects: keys + sizes).
  cache prune [--keep-days N] [--apply]  Delete the cache of FINISHED sync runs older than N days (default 7).
  history prune [--keep-days N] [--apply]  Delete cron run history older than N days (default 14).
  reports prune [--keep-days N] [--apply]  Delete problem reports + their zips older than N days (default 14).
  -h, --help                             This text.

REPORT SECTIONS
  1 Jobs        Every pg_cron job. All should be active.
  2 Runs        Per job: runs, failed (must be 0), avg time, last run, age.
                age should match the schedule: ~minutes for every-minute jobs, <1 day for daily ones.
                "(deleted job)" = history left by jobs that were unscheduled.
  3 Failures    Failed runs in the last 7 days, with the error message.
  4 Size        Database size and the 10 largest tables.
  5 Growth      What the three prunes would remove right now.

WHAT THE BIG TABLES ARE
  public.sync_run_cache  Working copy the bike sync fetches from the vendor (BellaBike) during a run:
                         parents:<category> = full product listings, option_maps = attribute id -> label.
                         Only needed while the run is going. Not telemetry: run stats live in
                         sync_runs / sync_units (small, never pruned), the catalog lives in bikes.
                         Old copies only show what the vendor catalog looked like on that date.
  cron.job_run_details   One row per cron run. bike-sync-tick alone adds ~1,440 rows a day.

AFTER A PRUNE
  Postgres reuses the freed space, but the database size Supabase reports may only drop after
  VACUUM FULL on that table (it locks the table while it runs; do it outside the 02:00-03:00 UTC sync window).

EXAMPLES
  ./scripts/cron-audit.sh
  ./scripts/cron-audit.sh cache list
  ./scripts/cron-audit.sh cache show 1b2c...-uuid parents:725
  ./scripts/cron-audit.sh cache prune                 # dry run, 7 days
  ./scripts/cron-audit.sh cache prune --apply
  ./scripts/cron-audit.sh history prune --keep-days 30 --apply
EOF
}

case "${1:-}" in
  -h|--help|help) usage ;;
  "")      report ;;
  cache)   shift; case "${1:-}" in
             "")    cache_summary ;;
             list)  cache_list ;;
             show)  shift; cache_show "$@" ;;
             prune) shift; cache_prune "$@" ;;
             *) echo "usage: $0 cache [list|show|prune]" >&2; exit 1 ;;
           esac ;;
  history) shift; [[ "${1:-}" == prune ]] || { echo "usage: $0 history prune" >&2; exit 1; }
           shift; history_prune "$@" ;;
  reports) shift; [[ "${1:-}" == prune ]] || { echo "usage: $0 reports prune" >&2; exit 1; }
           shift; reports_prune "$@" ;;
  *) usage >&2; exit 1 ;;
esac
