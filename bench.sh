#!/bin/sh
# Load-test GET /r/{code} with wrk against a running stack.
# Start the stack with a rate limit wrk cannot hit, or every response is a 503:
#   RATE_LIMIT_REQUESTS=0 docker compose up -d --wait && ./bench.sh
set -eu
BASE=${BASE_URL:-http://localhost:${PORT:-8001}}
DURATION=${DURATION:-20s}
sql() { docker compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"; }

KEY=$(sql "select issue_api_key('bench', 'bench')")
CODE="bench$(date +%s)"
curl -sf -o /dev/null -X POST "$BASE/api/rpc/create_short_link" -H 'Content-Type: application/json' \
  -H "X-API-Key: $KEY" -d "{\"p_original_url\":\"https://example.com/\",\"p_custom_alias\":\"$CODE\"}"

clicks() { sql "select count(*) from clicks c join links l on l.id = c.link_id where l.code = '$CODE'"; }

wrk -t2 -c32 -d5s "$BASE/r/$CODE" >/dev/null  # warm up
sleep 2; before=$(clicks)
wrk -t4 -c64 -d"$DURATION" --latency "$BASE/r/$CODE" | tee /tmp/ref_pg_wrk \
  | grep -E 'Requests/sec|Latency  |  (50|99)%|Non-2xx|Socket errors'
sleep 3  # let buffered clicks flush
echo "redirects served: $(awk '/requests in/ {print $1}' /tmp/ref_pg_wrk), clicks recorded: $(( $(clicks) - before ))"
