#!/bin/sh
# HTTP smoke test against a running stack: docker compose up -d --wait && tests/smoke.sh
# It sends ~30 requests at once, so set RATE_LIMIT_REQUESTS=0 (limiting off)
# in .env first, or the burst limit answers some of them with 503.
set -eu
BASE=${BASE_URL:-http://localhost:${PORT:-8001}}
sql() { docker compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"; }

fail=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}
post() {  # post <rpc> <json> [api key] -> prints HTTP status, body in /tmp/ref_pg_body
  curl -s -o /tmp/ref_pg_body -w '%{http_code}' -X POST "$BASE/api/rpc/$1" \
    -H 'Content-Type: application/json' ${3:+-H "X-API-Key: $3"} -d "$2"
}
get() {  # get <path> [api key] -> prints the body
  curl -s ${2:+-H "X-API-Key: $2"} "$BASE$1"
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

RUN=$(date +%s)
KEY=$(sql "select issue_api_key('smoke-$RUN', 'smoke')")
OTHER=$(sql "select issue_api_key('smoke-other-$RUN', 'smoke')")
ALIAS="t$RUN"
URL="https://example.com/path?q=1"
# Bodies are built here: macOS /bin/sh (bash 3.2) brace-expands "{a,b}" nested in "$(...)".
WITH_URL="{\"p_original_url\":\"$URL\"}"
WITH_ALIAS="{\"p_original_url\":\"$URL\",\"p_custom_alias\":\"$ALIAS\"}"
WITH_DASH="{\"p_original_url\":\"$URL\",\"p_custom_alias\":\"a-b\"}"

echo "# auth and validation"
check "create without key -> 401"       401 "$(post create_short_link "$WITH_URL")"
check "create with bad key -> 401"      401 "$(post create_short_link "$WITH_URL" nope)"
check "create javascript: URL -> 400"   400 "$(post create_short_link '{"p_original_url":"javascript:alert(1)"}' "$KEY")"
check "create with alias -> 200"        200 "$(post create_short_link "$WITH_ALIAS" "$KEY")"
check "duplicate alias -> 409"          409 "$(post create_short_link "$WITH_ALIAS" "$KEY")"
check "alias taken by other tenant -> 409" 409 "$(post create_short_link "$WITH_ALIAS" "$OTHER")"
check "alias with a dash -> 400"        400 "$(post create_short_link "$WITH_DASH" "$KEY")"
check "generated code -> 200"           200 "$(post create_short_link "$WITH_URL" "$KEY")"
check "generated code is 7 chars"       7   "$(sed 's/.*"code" *: *"\([A-Za-z0-9]*\)".*/\1/' /tmp/ref_pg_body | tr -d '\n' | wc -c | tr -d ' ')"
check "non-admin create_api_key -> 403" 403 "$(post create_api_key '{"p_name":"x"}' "$KEY")"

echo "# redirects and clicks"
check "redirect -> 302"                 302 "$(status "$BASE/r/$ALIAS")"
check "redirect Location"               "$URL" "$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/r/$ALIAS")"
check "unknown code -> 404"             404 "$(status "$BASE/r/nosuchcode")"
check "invalid UTF-8 User-Agent -> 302" 302 "$(status -H "$(printf 'User-Agent: \377\376bot')" "$BASE/r/$ALIAS")"
sleep 2  # clicks are flushed to Postgres once per second
check "three redirects -> 3 clicks"     3   "$(sql "select count(*) from clicks c join links l on l.id = c.link_id where l.code = '$ALIAS'")"
check "bad bytes stripped from UA"      bot "$(sql "select user_agent from clicks c join links l on l.id = c.link_id where l.code = '$ALIAS' and user_agent = 'bot'")"
check "click IP stored as /24 network"  24  "$(sql "select distinct masklen(c.ip) from clicks c join links l on l.id = c.link_id where l.code = '$ALIAS'")"

echo "# stats and tenant isolation"
check "link_stats shows 3 clicks"       '[{"clicks":3}]' "$(get "/api/link_stats?code=eq.$ALIAS&select=clicks" "$KEY")"
check "top_referrers counts direct"     '[{"referrer":"(direct)","clicks":3}]' "$(get "/api/top_referrers?code=eq.$ALIAS&select=referrer,clicks" "$KEY")"
check "other tenant sees none of it"    '[]' "$(get "/api/link_stats?code=eq.$ALIAS" "$OTHER")"
check "no key sees nothing"             '[]' "$(get "/api/link_stats")"
check "stats with bad key -> 401"       401 "$(status -H 'X-API-Key: nope' "$BASE/api/link_stats")"

echo "# internal and removed functions are unreachable"
for fn in internal_lookup_link internal_record_clicks resolve_link get_api_key quick_link test_create_link; do
  check "$fn -> 404"                    404 "$(post $fn '{}')"
done

sql "update api_keys set is_active = false where name = 'smoke'" >/dev/null
exit $fail
