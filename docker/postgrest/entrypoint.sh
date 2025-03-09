#!/bin/bash
set -e

# Wait for PostgreSQL to be available
echo "Waiting for PostgreSQL to be available..."
timeout=60
counter=0
while ! pg_isready -h db -p 5432 -U ${PGRST_DB_ANON_ROLE:-postgres}; do
    sleep 1
    counter=$((counter + 1))
    if [ $counter -eq $timeout ]; then
        echo "Timed out waiting for PostgreSQL to become available. Starting PostgREST anyway..."
        break
    fi
    echo "Waiting for PostgreSQL... ($counter/$timeout)"
done

# Try to connect to the specific database
echo "Checking database connection..."
counter=0
while ! PGPASSWORD=${POSTGRES_PASSWORD:-postgres} psql -h db -p 5432 -U ${PGRST_DB_ANON_ROLE:-postgres} -d ${POSTGRES_DB:-url_shortener} -c "SELECT 1" >/dev/null 2>&1; do
    sleep 1
    counter=$((counter + 1))
    if [ $counter -eq $timeout ]; then
        echo "Timed out waiting for database connection. Starting PostgREST anyway..."
        break
    fi
    echo "Waiting for database connection... ($counter/$timeout)"
done

# Print connection info
echo "PostgREST is connecting to: ${PGRST_DB_URI}"
echo "Using anon role: ${PGRST_DB_ANON_ROLE}"
echo "Using schema: ${PGRST_DB_SCHEMA}"

# Start PostgREST
echo "Starting PostgREST..."
exec postgrest 