#!/bin/sh
# Smoke test against a running stack: docker compose up -d && ./test.sh
# It sends ~20 requests at once, so set RATE_LIMIT_REQUESTS=6000 in .env first,
# or the burst limit answers some of them with 503.
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

KEY=$(sql "select issue_api_key('smoke-test')")
ALIAS="t$(date +%s)"
URL="https://example.com/path?q=1"
# Bodies are built here: macOS /bin/sh (bash 3.2) brace-expands "{a,b}" nested in "$(...)".
WITH_URL="{\"p_original_url\":\"$URL\"}"
WITH_ALIAS="{\"p_original_url\":\"$URL\",\"p_custom_alias\":\"$ALIAS\"}"
WITH_DASH="{\"p_original_url\":\"$URL\",\"p_custom_alias\":\"a-b\"}"

check "create without key -> 401"       401 "$(post create_short_link "$WITH_URL")"
check "create with bad key -> 401"      401 "$(post create_short_link "$WITH_URL" nope)"
check "create javascript: URL -> 400"   400 "$(post create_short_link '{"p_original_url":"javascript:alert(1)"}' "$KEY")"
check "create with alias -> 200"        200 "$(post create_short_link "$WITH_ALIAS" "$KEY")"
check "duplicate alias -> 409"          409 "$(post create_short_link "$WITH_ALIAS" "$KEY")"
check "alias with a dash -> 400"        400 "$(post create_short_link "$WITH_DASH" "$KEY")"
check "generated code -> 200"           200 "$(post create_short_link "$WITH_URL" "$KEY")"
check "generated code is 7 chars"       7   "$(sed 's/.*"code" *: *"\([A-Za-z0-9]*\)".*/\1/' /tmp/ref_pg_body | tr -d '\n' | wc -c | tr -d ' ')"

check "redirect -> 302"                 302 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/r/$ALIAS")"
check "redirect Location"               "$URL" "$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/r/$ALIAS")"
check "unknown code -> 404"             404 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/r/nosuchcode")"
check "two redirects -> 2 clicks"       2   "$(sql "select count(*) from clicks c join links l on l.id = c.link_id where l.code = '$ALIAS'")"

check "direct resolve_link -> 404"      404 "$(post resolve_link "{\"p_code\":\"$ALIAS\"}")"
check "non-admin create_api_key -> 401" 401 "$(post create_api_key '{"p_name":"x"}' "$KEY")"
for old in get_api_key quick_link test_create_link; do
  check "removed $old -> 404"           404 "$(post $old '{}')"
done

sql "update api_keys set is_active = false where name = 'smoke-test'" >/dev/null
exit $fail
