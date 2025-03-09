#!/bin/sh
set -e

echo "Starting PostgREST..."

# Sleep to allow PostgreSQL to start
sleep 10

# Start PostgREST
exec postgrest
