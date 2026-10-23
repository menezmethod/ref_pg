#!/bin/sh
# Load-test GET /r/{code} with wrk from inside the Docker network (from the host,
# Docker Desktop/OrbStack port forwarding dominates the latency). Start the
# stack with rate limiting off, or wrk only measures 503s:
#   RATE_LIMIT_REQUESTS=0 ACCESS_LOG=off docker compose up -d --wait && ./bench.sh
# For a small node, add -f docker-compose.limits.yml (and set COMPOSE_FILE for this script).
set -eu
DURATION=${DURATION:-20s}
sql() { docker compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"; }
clicks() { sql "select count(*) from clicks c join links l on l.id = c.link_id where l.code = '${CODE}1'"; }

docker build -q -t ref_pg-loadgen tests/loadgen >/dev/null
NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(docker compose ps -q openresty)")
wrk() { docker run --rm --network "$NET" -v "$PWD/tests:/t:ro" ref_pg-loadgen wrk "$@"; }

TENANT="bench$(date +%s)" CODE="bench$(date +%s)"
sql "select issue_api_key('$TENANT', 'bench')" >/dev/null
sql "insert into links (tenant_id, code, url) select id, '${CODE}1', 'https://example.com/' from tenants where name = '$TENANT'" >/dev/null

wrk -t2 -c32 -d5s -s /t/chaos.lua http://openresty -- "$CODE" 1 1 >/dev/null  # warm up
sleep 3; before=$(clicks); since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
wrk -t4 -c64 -d"$DURATION" -s /t/chaos.lua http://openresty -- "$CODE" 1 1 | grep RESULT
sleep 20  # let buffered clicks flush
dropped=$(docker compose logs openresty --since "$since" 2>&1 | grep -oE 'dropped [0-9]+ clicks' | awk '{ s += $2 } END { print s + 0 }')
echo "clicks recorded: $(( $(clicks) - before )), dropped and counted: $dropped"
