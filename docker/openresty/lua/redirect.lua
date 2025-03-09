#!/bin/sh
set -e

# Default values for environment variables
RATE_LIMIT_REQUESTS=${RATE_LIMIT_REQUESTS:-60}
RATE_LIMIT_WINDOW=${RATE_LIMIT_WINDOW:-60}
LOG_LEVEL=${LOG_LEVEL:-notice}

# Process the nginx.conf template
envsubst '${RATE_LIMIT_REQUESTS} ${RATE_LIMIT_WINDOW} ${LOG_LEVEL}' \
  < /usr/local/openresty/nginx/conf/nginx.conf.template \
  > /usr/local/openresty/nginx/conf/nginx.conf

# Display config values (debug)
echo "Configuration:"
echo "- Rate limit: ${RATE_LIMIT_REQUESTS} requests per ${RATE_LIMIT_WINDOW} minutes"
echo "- Log level: ${LOG_LEVEL}"

# Execute the CMD
exec "$@" 