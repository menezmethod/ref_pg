#!/bin/sh
# Runs once, after 000_schema.sql. Sets the password PostgREST logs in with.
set -eu
: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD must be set}"

# :'pw' makes psql quote the value, so any character in the password is safe here.
psql -v ON_ERROR_STOP=1 -v pw="$AUTHENTICATOR_PASSWORD" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
ALTER ROLE authenticator PASSWORD :'pw';
SQL
