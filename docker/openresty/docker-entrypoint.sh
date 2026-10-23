#!/bin/sh
set -e

RATE_LIMIT_REQUESTS=${RATE_LIMIT_REQUESTS:-60}
RATE_LIMIT_WINDOW=${RATE_LIMIT_WINDOW:-60}
LOG_LEVEL=${LOG_LEVEL:-notice}
CORS_ALLOW_ORIGIN=${CORS_ALLOW_ORIGIN:-*}
export LOG_LEVEL CORS_ALLOW_ORIGIN

# RATE_LIMIT_WINDOW is in seconds. nginx limit_req takes a rate per second or
# per minute, so convert "N requests per W seconds" to requests per minute
# (rounded up). Example: 60 requests per 60 seconds -> 60r/m.
case "${RATE_LIMIT_REQUESTS}${RATE_LIMIT_WINDOW}" in
  ''|*[!0-9]*)
    echo "ERROR: RATE_LIMIT_REQUESTS and RATE_LIMIT_WINDOW must be positive integers" >&2
    exit 1
    ;;
esac
if [ "${RATE_LIMIT_REQUESTS}" -lt 1 ] || [ "${RATE_LIMIT_WINDOW}" -lt 1 ]; then
  echo "ERROR: RATE_LIMIT_REQUESTS and RATE_LIMIT_WINDOW must be at least 1" >&2
  exit 1
fi
RATE_LIMIT_PER_MIN=$(( (RATE_LIMIT_REQUESTS * 60 + RATE_LIMIT_WINDOW - 1) / RATE_LIMIT_WINDOW ))
export RATE_LIMIT_PER_MIN

envsubst '${RATE_LIMIT_PER_MIN} ${LOG_LEVEL} ${CORS_ALLOW_ORIGIN}' \
  < /usr/local/openresty/nginx/conf/nginx.conf.template \
  > /usr/local/openresty/nginx/conf/nginx.conf

echo "Rate limit: ${RATE_LIMIT_PER_MIN}r/m per IP, log level: ${LOG_LEVEL}, CORS: ${CORS_ALLOW_ORIGIN}"
exec "$@"
