#!/bin/sh
# Adversarial scale test on a CPU- and RAM-limited stack (docker-compose.limits.yml).
# Load comes from wrk inside the Docker network, so host port forwarding does
# not distort latency. Each phase asserts an invariant; see docs/performance.md.
#
#   RATE_LIMIT_REQUESTS=0 docker compose -f docker-compose.yml -f docker-compose.limits.yml up -d --build --wait
#   tests/chaos_bench.sh
#
# Thresholds can be overridden: P99_MS_MAX, COLD_MS_MAX, SCALE_RATIO_MAX, STALL_SECONDS,
# RATE (requests/s for the paced phases).
set -eu
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.limits.yml"
P99_MS_MAX=${P99_MS_MAX:-50}
COLD_MS_MAX=${COLD_MS_MAX:-250}
SCALE_RATIO_MAX=${SCALE_RATIO_MAX:-3}
STALL_SECONDS=${STALL_SECONDS:-3}
RATE=${RATE:-20000}
CONNS=64

sql() { $COMPOSE exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"; }
fail=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}
check_le() {  # check_le <name> <max> <actual>
  if [ "$3" -le "$2" ]; then echo "ok   $1: $3 (max $2)"; else echo "FAIL $1: $3 (max $2)"; fail=1; fi
}
check_between() {  # check_between <name> <min> <max> <actual>
  if [ "$4" -ge "$2" ] && [ "$4" -le "$3" ]; then echo "ok   $1: $4 (expected $2..$3)"
  else echo "FAIL $1: $4 (expected $2..$3)"; fail=1; fi
}
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# Load generator image (wrk + curl), run on the stack's network.
docker build -q -t ref_pg-loadgen tests/loadgen >/dev/null
NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$($COMPOSE ps -q openresty)")
loadgen() { docker run --rm --network "$NET" -v "$PWD/tests:/t:ro" ref_pg-loadgen "$@"; }
hits() {  # hits <count> <url>: GETs 32 at a time, prints how many returned 302
  loadgen sh -c "seq $1 | xargs -P 32 -I{} curl -s -o /dev/null -w '%{http_code}\n' '$2' | grep -c 302 || true"
}
hit_each() {  # hit_each <prefix> <count>: one GET per code <prefix>1..<count>, prints how many got 302
  # 4 at a time: the limited stack allows 4 lookups in flight and sheds the rest with 503.
  loadgen sh -c "seq $2 | xargs -P 4 -I{} curl -s -o /dev/null -w '%{http_code}\n' http://openresty/r/$1{} | grep -c 302 || true"
}
restart_openresty() {  # restart_openresty [VAR=value ...]: fresh caches, given settings
  # Access log off: at full load it is a benchmark of Docker's log pipe.
  env ACCESS_LOG=off "$@" $COMPOSE up -d --force-recreate --wait openresty >/dev/null 2>&1
}
dropped_since() {  # clicks OpenResty reported dropping since <RFC 3339 time>
  $COMPOSE logs openresty --since "$1" 2>&1 | grep -oE 'dropped [0-9]+ clicks' | awk '{ s += $2 } END { print s + 0 }'
}
lookups() {  # internal_lookup_link calls so far. Backends report stats when idle, within 10 s.
  sleep 11
  sql "select coalesce(sum(calls), 0) from pg_stat_user_functions where funcname = 'internal_lookup_link'"
}
clicks_like() { sql "select count(*) from clicks c join links l on l.id = c.link_id where l.code like '$1%'"; }
exec_ms() {  # exec_ms <tenant id> <query>: best of 3 execution times as anon, in whole ms (min 1)
  for _ in 1 2 3; do
    $COMPOSE exec -T db sh -c 'psql -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<SQL | sed -n 's/^Execution Time: \([0-9.]*\) ms$/\1/p'
BEGIN;
SELECT set_config('app.tenant_id', '$1', true) \g /dev/null
SET LOCAL ROLE anon;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) $2;
ROLLBACK;
SQL
  done | sort -n | head -1 | awk '{ v = int($1 + 0.999); print (v < 1 ? 1 : v) }'
}

restore() {
  for svc in db postgrest; do docker unpause "$($COMPOSE ps -q $svc)" >/dev/null 2>&1 || true; done
  { sql "alter system reset track_functions" && sql "select pg_reload_conf()"; } >/dev/null 2>&1 || true
  restart_openresty
}
trap restore EXIT
sql "alter system set track_functions = 'all'" >/dev/null && sql "select pg_reload_conf()" >/dev/null

RUN=$(date +%s)
HOT="hot$RUN" WARM="warm$RUN" ORPHAN="orphan$RUN" N_HOT=20 N_WARM=6000  # a 1 MB cache holds ~8,100 such links
sql "select issue_api_key('chaos$RUN', 'k')" >/dev/null
TID=$(sql "select id from tenants where name = 'chaos$RUN'")
sql "insert into links (tenant_id, code, url)
     select $TID, '$HOT' || g, 'https://example.com/hot/' || g from generate_series(1, $N_HOT) g
     union all select $TID, '$WARM' || g, 'https://example.com/warm/' || g from generate_series(1, $N_WARM) g
     union all select $TID, '$ORPHAN', 'https://example.com/orphan'" >/dev/null

echo "# 1. Cold wakeup: empty cache after a restart, then 5 s idle"
restart_openresty
sleep 5
cold=$(loadgen curl -s -o /dev/null -w '%{time_total}' "http://openresty/r/${HOT}1" | awk '{ print int($1 * 1000 + 0.5) }')
warm=$(loadgen curl -s -o /dev/null -w '%{time_total}' "http://openresty/r/${HOT}1" | awk '{ printf "%.2f", $1 * 1000 }')
check_le "first request after idle, ms (then cached: $warm ms)" "$COLD_MS_MAX" "$cold"

echo "# 2a. TTL stampede under a 404 scan: ${RATE}/s, 90% hot keys with a 2 s cache, 10% unique codes, 20 s"
restart_openresty LINK_CACHE_SECONDS=2 LINK_NEGATIVE_CACHE_SECONDS=10 LINK_CACHE_MB=1
l0=$(lookups); c0=$(clicks_like "$HOT")
r=$(loadgen wrk -t2 -c$CONNS -d20s -s /t/chaos.lua http://openresty -- "$HOT" $N_HOT 0.9 "$RATE" $CONNS | grep RESULT)
echo "     $r"
ok302=$(field "$r" ok302) nf404=$(field "$r" nf404) p99=$(( $(field "$r" p99_us) / 1000 ))
l1=$(lookups); c1=$(clicks_like "$HOT")
# Each 404 answered is one lookup of a unique code; the rest are hot-key refreshes.
check_le "hot-key lookups coalesce to ~1 per key per expiry" $(( N_HOT * (20 / 2 + 2) )) $(( l1 - l0 - nf404 ))
check_le "redirect p99 ms during flushes and expiries" "$P99_MS_MAX" "$p99"
check_between "clicks recorded = 302s served (+ requests in flight)" "$ok302" $(( ok302 + CONNS )) $(( c1 - c0 ))

echo "# 2b. Sushi belt: 6,000 links fill 74% of a 1 MB cache, then 25 s of unique 404s"
restart_openresty LINK_CACHE_MB=1
check "all warm links cached before the flood" $N_WARM "$(hit_each "$WARM" $N_WARM)"
r=$(loadgen wrk -t2 -c$CONNS -d25s -s /t/chaos.lua http://openresty -- "$WARM" 1 0 | grep RESULT)
echo "     flood: $(field "$r" scans) unique codes, $(field "$r" nf404) answered 404, $(field "$r" other) shed"
l0=$(lookups)
hit_each "$WARM" $N_WARM >/dev/null
l1=$(lookups)
check_le "warm links re-fetched from Postgres after the flood" $(( N_WARM / 20 )) $(( l1 - l0 ))

echo "# 3a. Downstream stall: Postgres paused for ${STALL_SECONDS} s in 15 s of load at ${RATE}/s"
restart_openresty
hit_each "$HOT" $N_HOT >/dev/null
sleep 2; c0=$(clicks_like "$HOT")
loadgen wrk -t2 -c$CONNS -d15s -s /t/chaos.lua http://openresty -- "$HOT" $N_HOT 1 "$RATE" $CONNS > /tmp/ref_pg_chaos_stall &
sleep 5; docker pause "$($COMPOSE ps -q db)" >/dev/null
sleep "$STALL_SECONDS"; docker unpause "$($COMPOSE ps -q db)" >/dev/null
wait
r=$(grep RESULT /tmp/ref_pg_chaos_stall); echo "     $r"
ok302=$(field "$r" ok302) p99=$(( $(field "$r" p99_us) / 1000 ))
sleep 15  # a flush stuck on the paused database times out, then retries
c1=$(clicks_like "$HOT")
check_le "redirect p99 ms while Postgres is paused" "$P99_MS_MAX" "$p99"
check_between "no clicks lost or duplicated across the stall" "$ok302" $(( ok302 + CONNS )) $(( c1 - c0 ))

echo "# 3c. Ingest capacity: unpaced load; clicks past capacity must be counted, never lost silently"
restart_openresty
hit_each "$HOT" $N_HOT >/dev/null
sleep 2; c0=$(clicks_like "$HOT"); since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
r=$(loadgen wrk -t2 -c$CONNS -d15s -s /t/chaos.lua http://openresty -- "$HOT" $N_HOT 1 | grep RESULT)
echo "     $r"
ok302=$(field "$r" ok302)
sleep 20
recorded=$(( $(clicks_like "$HOT") - c0 )); dropped=$(dropped_since "$since")
echo "     recorded $recorded ($(( recorded / 15 ))/s while loaded), dropped and counted $dropped"
check_between "recorded + counted drops = 302s served (+ in flight)" "$ok302" $(( ok302 + CONNS )) $(( recorded + dropped ))

echo "# 3b. Poison record: clicks for a link deleted while they wait in the queue"
c0=$(clicks_like "$HOT")
docker pause "$($COMPOSE ps -q postgrest)" >/dev/null
orphan_ok=$(hits 200 "http://openresty/r/$ORPHAN")
hot_ok=$(hits 1000 "http://openresty/r/${HOT}1")
sql "delete from links where code = '$ORPHAN'" >/dev/null
docker unpause "$($COMPOSE ps -q postgrest)" >/dev/null
sleep 15
check "clicks for the other links in the same batches are all recorded ($orphan_ok orphaned)" "$hot_ok" $(( $(clicks_like "$HOT") - c0 ))

echo "# 4. Analytics scaling: 10x the clicks should not mean 10x the query time"
sql "select issue_api_key('scale$RUN', 'k')" >/dev/null
SID=$(sql "select id from tenants where name = 'scale$RUN'")
sql "insert into links (tenant_id, code, url) select $SID, 'scale$RUN' || g, 'https://example.com/' || g from generate_series(1, 100) g" >/dev/null
add_clicks() {
  sql "with ids as (select array_agg(id order by id) a from links where tenant_id = $SID)
       insert into clicks (tenant_id, link_id, clicked_at, referrer)
       select $SID, (select a from ids)[1 + g % 100], now() - random() * interval '30 days',
              (array['https://news.ycombinator.com/', 'https://t.co/', null])[1 + g % 3]
       from generate_series(1, $1) g" >/dev/null
  sql "analyze clicks" >/dev/null
}
sql "select create_click_partitions((now() at time zone 'UTC')::date - 31, (now() at time zone 'UTC')::date)" >/dev/null
add_clicks 100000
s1=$(exec_ms "$SID" "select * from api.link_stats") t1=$(exec_ms "$SID" "select * from api.top_referrers")
add_clicks 900000
s10=$(exec_ms "$SID" "select * from api.link_stats") t10=$(exec_ms "$SID" "select * from api.top_referrers")
echo "     link_stats ${s1} ms -> ${s10} ms, top_referrers ${t1} ms -> ${t10} ms (100k -> 1M clicks)"
# Allowed: SCALE_RATIO_MAX times the small-table time, or +10 ms, whichever is more
# (ratios of 1-3 ms timings are noise). A full scan grows ~10x and fails either way.
check_le "link_stats ms at 10x clicks" $(( s1 * SCALE_RATIO_MAX > s1 + 10 ? s1 * SCALE_RATIO_MAX : s1 + 10 )) "$s10"
check_le "top_referrers ms at 10x clicks" $(( t1 * SCALE_RATIO_MAX > t1 + 10 ? t1 * SCALE_RATIO_MAX : t1 + 10 )) "$t10"

echo "# 5. Retention under load: drop raw clicks older than 7 days while clicks arrive at ${RATE}/s"
total0=$(sql "select sum(clicks) from link_totals where tenant_id = $SID")
restart_openresty
hit_each "$HOT" $N_HOT >/dev/null
sleep 2; c0=$(clicks_like "$HOT")
loadgen wrk -t2 -c$CONNS -d15s -s /t/chaos.lua http://openresty -- "$HOT" $N_HOT 1 "$RATE" $CONNS > /tmp/ref_pg_chaos_retention &
sleep 5
m=$(sql "select json_array_length(m->'dropped') || ' ' || json_array_length(m->'skipped') || ' ' ||
            round(extract(epoch from clock_timestamp() - statement_timestamp()) * 1000)
         from (select api.internal_maintain_clicks(7) m) x")
wait
r=$(grep RESULT /tmp/ref_pg_chaos_retention); echo "     $r"
set -- $m; dropped_parts=$1 skipped_parts=$2 maint_ms=$3
echo "     maintenance: dropped $dropped_parts partitions, skipped $skipped_parts, in $maint_ms ms"
ok302=$(field "$r" ok302) p99=$(( $(field "$r" p99_us) / 1000 ))
sleep 15
c1=$(clicks_like "$HOT")
check "partitions older than 7 days dropped (days -31 to -8)" 24 "$dropped_parts"
check "none skipped on a lock timeout" 0 "$skipped_parts"
check "raw clicks older than 7 days left" 0 "$(sql "select count(*) from clicks where clicked_at < (now() at time zone 'UTC')::date - 7")"
check "link_stats totals unchanged (rollups keep dropped days)" "$total0" "$(sql "select sum(clicks) from link_totals where tenant_id = $SID")"
check_le "redirect p99 ms while partitions are dropped" "$P99_MS_MAX" "$p99"
check_between "no clicks lost while partitions are dropped" "$ok302" $(( ok302 + CONNS )) $(( c1 - c0 ))

exit $fail
