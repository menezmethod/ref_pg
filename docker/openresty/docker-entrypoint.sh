#!/bin/sh
set -e

: "${RATE_LIMIT_REQUESTS:=60}" "${RATE_LIMIT_WINDOW:=60}"
: "${LINK_CACHE_SECONDS:=60}" "${LINK_NEGATIVE_CACHE_SECONDS:=10}" "${CLICK_FLUSH_SECONDS:=1}"
: "${LOG_LEVEL:=notice}" "${ACCESS_LOG:=/dev/stdout}" "${CORS_ALLOW_ORIGIN:=*}" "${TRUSTED_PROXIES:=}"

for name in RATE_LIMIT_REQUESTS RATE_LIMIT_WINDOW LINK_CACHE_SECONDS LINK_NEGATIVE_CACHE_SECONDS CLICK_FLUSH_SECONDS; do
  eval "value=\$$name"
  case "$value" in
    ''|*[!0-9]*) echo "ERROR: $name must be a non-negative integer, got '$value'" >&2; exit 1 ;;
  esac
done
if [ "$RATE_LIMIT_WINDOW" -lt 1 ] || [ "$CLICK_FLUSH_SECONDS" -lt 1 ]; then
  echo "ERROR: RATE_LIMIT_WINDOW and CLICK_FLUSH_SECONDS must be at least 1" >&2
  exit 1
fi

# nginx limit_req takes a rate per second or per minute, so convert
# "N requests per W seconds" to requests per minute (rounded up).
# RATE_LIMIT_REQUESTS=0 turns limiting off: nginx skips requests whose zone key
# is empty. Load tests need that: limit_req counts in whole milliseconds, so one
# client sending more than burst+1 requests in the same millisecond is rejected
# at any rate.
if [ "$RATE_LIMIT_REQUESTS" -eq 0 ]; then
  RATE_LIMIT_PER_MIN=1 RATE_LIMIT_KEY='""'
else
  RATE_LIMIT_PER_MIN=$(( (RATE_LIMIT_REQUESTS * 60 + RATE_LIMIT_WINDOW - 1) / RATE_LIMIT_WINDOW ))
  RATE_LIMIT_KEY='$binary_remote_addr'
fi

export RATE_LIMIT_PER_MIN RATE_LIMIT_KEY LINK_CACHE_SECONDS LINK_NEGATIVE_CACHE_SECONDS CLICK_FLUSH_SECONDS \
       LOG_LEVEL ACCESS_LOG CORS_ALLOW_ORIGIN

CONF=/usr/local/openresty/nginx/conf
envsubst '${RATE_LIMIT_PER_MIN} ${RATE_LIMIT_KEY} ${LINK_CACHE_SECONDS} ${LINK_NEGATIVE_CACHE_SECONDS} ${CLICK_FLUSH_SECONDS} ${LOG_LEVEL} ${ACCESS_LOG} ${CORS_ALLOW_ORIGIN}' \
  < "$CONF/nginx.conf.template" > "$CONF/nginx.conf"

# TRUSTED_PROXIES: CIDRs of reverse proxies in front of this container
# (space or comma separated). Their X-Forwarded-For is used as the client IP
# for rate limits and click stats. Leave empty when clients connect directly.
: > "$CONF/real_ip.conf"
for cidr in $(echo "$TRUSTED_PROXIES" | tr ',' ' '); do
  case "$cidr" in
    *[!0-9a-fA-F.:/]*) echo "ERROR: TRUSTED_PROXIES entry '$cidr' is not an IP or CIDR" >&2; exit 1 ;;
  esac
  echo "set_real_ip_from $cidr;" >> "$CONF/real_ip.conf"
done
if [ -s "$CONF/real_ip.conf" ]; then
  printf 'real_ip_header X-Forwarded-For;\nreal_ip_recursive on;\n' >> "$CONF/real_ip.conf"
fi

echo "Rate limit ${RATE_LIMIT_PER_MIN}r/m per IP (key: ${RATE_LIMIT_KEY}), link cache ${LINK_CACHE_SECONDS}s (miss ${LINK_NEGATIVE_CACHE_SECONDS}s)," \
     "click flush every ${CLICK_FLUSH_SECONDS}s, trusted proxies: ${TRUSTED_PROXIES:-none}"
exec "$@"
