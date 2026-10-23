#!/bin/sh
# Failure-mode tests: cache stampede, Postgres outage, full click queue.
# Restarts OpenResty with a 1 s cache and a 2,000-click buffer, pauses PostgREST,
# and puts both back on exit. Run against a stack started with
# RATE_LIMIT_REQUESTS=0:  docker compose up -d --wait && tests/resilience.sh
set -eu
BASE=${BASE_URL:-http://localhost:${PORT:-8001}}
sql() { docker compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"; }

fail=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}
check_le() {  # check_le <name> <max> <actual>
  if [ "$3" -le "$2" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: expected at most $2, got $3"; fail=1; fi
}
hit() {  # hit <url>: sets STATUS and MS (response time in milliseconds)
  set -- $(curl -s -o /dev/null -w '%{http_code} %{time_total}' "$1")
  STATUS=$1 MS=$(awk -v t="$2" 'BEGIN { printf "%d", t * 1000 }')
}
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
burst() {  # burst <count> <url>: that many GETs, 64 at a time, sized like browser clicks
  seq "$1" | xargs -P 64 -I{} curl -s -o /dev/null -A "$UA" "$2"
}
lookups() { sql "select coalesce(sum(calls), 0) from pg_stat_user_functions where funcname = 'internal_lookup_link'"; }

restore() {
  docker compose unpause postgrest >/dev/null 2>&1 || true
  { sql "alter system reset track_functions" && sql "select pg_reload_conf()"; } >/dev/null 2>&1 || true
  docker compose up -d --wait openresty >/dev/null 2>&1
}
trap restore EXIT

LINK_CACHE_SECONDS=1 LINK_NEGATIVE_CACHE_SECONDS=1 CLICK_BUFFER=2000 docker compose up -d --wait openresty >/dev/null 2>&1
sql "alter system set track_functions = 'all'" >/dev/null && sql "select pg_reload_conf()" >/dev/null

KEY=$(sql "select issue_api_key('resilience-$(date +%s)', 'k')")
CODE="res$(date +%s)"
curl -sf -o /dev/null -X POST "$BASE/api/rpc/create_short_link" -H 'Content-Type: application/json' \
  -H "X-API-Key: $KEY" -d "{\"p_original_url\":\"https://example.com/\",\"p_custom_alias\":\"$CODE\"}"

echo "# stampede: 64 concurrent clients on one link with a 1 s cache"
sleep 11; before=$(lookups)  # backends report function stats when idle, within 10 s
start=$(date +%s); burst 6000 "$BASE/r/$CODE"; elapsed=$(( $(date +%s) - start + 1 ))
sleep 11; n=$(( $(lookups) - before ))
check_le "at most one lookup per expired second ($elapsed s)" $(( elapsed + 1 )) "$n"

echo "# Postgres unreachable (PostgREST paused)"
docker compose pause postgrest >/dev/null
sleep 2  # let the cached entry expire
hit "$BASE/r/$CODE"
check "expired link still redirects (old URL)"   302 "$STATUS"
check_le "  after one lookup timeout, ms"        3000 "$MS"
hit "$BASE/r/$CODE"
check "next request redirects too"               302 "$STATUS"
check_le "  without waiting for Postgres, ms"    200 "$MS"
hit "$BASE/r/nosuch$(date +%s)"
check "unknown code fails with 502"              502 "$STATUS"
check_le "  fast, not after nginx's 60 s, ms"    3000 "$MS"

echo "# full click queue while Postgres is unreachable"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
burst 6000 "$BASE/r/$CODE"  # the buffer holds 2,000 clicks, plus one batch in flight
sleep 8  # one flush attempt times out (5 s), then drops are reported
logs=$(docker compose logs openresty --since "$since" 2>&1)
check "redirects kept working"                   302 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/r/$CODE")"
check "drops reported in aggregate lines"        yes "$(echo "$logs" | grep -q 'clicks since the last flush' && echo yes || echo no)"
check_le "no log line per dropped click" 0 "$(echo "$logs" | grep -c 'click dropped' || true)"

echo "# recovery"
clicks_before=$(sql "select count(*) from clicks c join links l on l.id = c.link_id where l.code = '$CODE'")
docker compose unpause postgrest >/dev/null
sleep 8  # the next flush delivers what the queue kept
clicks_after=$(sql "select count(*) from clicks c join links l on l.id = c.link_id where l.code = '$CODE'")
check "queued clicks written after recovery"     yes "$([ "$clicks_after" -gt "$clicks_before" ] && echo yes || echo no)"

exit $fail
