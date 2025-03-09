#!/bin/sh
set -e

# Default values for environment variables
RATE_LIMIT_REQUESTS=${RATE_LIMIT_REQUESTS:-60}
RATE_LIMIT_WINDOW=${RATE_LIMIT_WINDOW:-60}
LOG_LEVEL=${LOG_LEVEL:-notice}
CORS_ALLOW_ORIGIN=${CORS_ALLOW_ORIGIN:-'*'}

# Create a temporary config file in a location that should be writable
TEMP_CONF="/tmp/nginx.conf"

# Process the nginx.conf template to a temporary location first
echo "Generating config file from template..."
envsubst '${RATE_LIMIT_REQUESTS} ${RATE_LIMIT_WINDOW} ${LOG_LEVEL} ${CORS_ALLOW_ORIGIN}' \
  < /usr/local/openresty/nginx/conf/nginx.conf.template \
  > "${TEMP_CONF}"

# Try to copy the processed config to the target location
echo "Moving config file to final location..."
if cp "${TEMP_CONF}" /usr/local/openresty/nginx/conf/nginx.conf; then
  echo "Successfully wrote nginx.conf"
else
  echo "WARNING: Could not write to /usr/local/openresty/nginx/conf/nginx.conf"
  echo "Using temporary config file instead"
  # Use the -c option to specify the temporary config location
  export NGINX_OPTS="-c ${TEMP_CONF}"
fi

# Display config values
echo "Configuration:"
echo "- Rate limit: ${RATE_LIMIT_REQUESTS} requests per ${RATE_LIMIT_WINDOW} minutes"
echo "- Log level: ${LOG_LEVEL}"
echo "- CORS allow origin: ${CORS_ALLOW_ORIGIN}"

# Execute the CMD with the possibly modified options
if [ -n "${NGINX_OPTS}" ]; then
  echo "Using custom nginx options: ${NGINX_OPTS}"
  exec /usr/local/openresty/bin/openresty ${NGINX_OPTS} -g "daemon off;"
else
  # Execute the original CMD
  exec "$@"
fi 