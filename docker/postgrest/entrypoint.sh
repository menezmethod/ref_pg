#!/bin/bash
set -e

# Extract host and port from PGRST_DB_URI
echo "Extracting connection details from ${PGRST_DB_URI}..."
DB_HOST="db"
DB_PORT="5432"

# Handle the case where PGRST_DB_URI might be in different formats
if [[ "${PGRST_DB_URI}" =~ postgres://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+) ]]; then
    # This regex extracts parts from postgres://user:password@host:port/dbname
    DB_HOST="${BASH_REMATCH[3]}"
    DB_PORT="${BASH_REMATCH[4]}"
    echo "Extracted host: ${DB_HOST}, port: ${DB_PORT} from URI"
else
    echo "Could not parse connection URI, using defaults - host: db, port: 5432"
fi

# Increase timeout for development environments
TIMEOUT=120
INTERVAL=2
MAX_ATTEMPTS=$((TIMEOUT / INTERVAL))

echo "===== PostgREST Startup ====="
echo "Database Host: ${DB_HOST}"
echo "Database Port: ${DB_PORT}"
echo "Database Name: ${POSTGRES_DB:-url_shortener}"
echo "Anonymous Role: ${PGRST_DB_ANON_ROLE:-postgres}"
echo "Schema: ${PGRST_DB_SCHEMA:-public}"
echo "Max connection attempts: ${MAX_ATTEMPTS}"

# Wait for PostgreSQL to be available
echo "Waiting for PostgreSQL to be available..."
counter=0
connected=false

echo "Trying pg_isready checks..."
while [ $counter -lt $MAX_ATTEMPTS ]; do
    if pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${PGRST_DB_ANON_ROLE:-postgres}"; then
        connected=true
        echo "PostgreSQL server is ready!"
        break
    fi
    
    counter=$((counter + 1))
    echo "Waiting for PostgreSQL... (Attempt $counter/$MAX_ATTEMPTS)"
    sleep $INTERVAL
done

# If pg_isready didn't succeed, try direct connection
if [ "$connected" != true ]; then
    echo "pg_isready checks failed, trying direct connection..."
    counter=0
    
    while [ $counter -lt $MAX_ATTEMPTS ]; do
        if PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" psql -h "${DB_HOST}" -p "${DB_PORT}" \
           -U "${PGRST_DB_ANON_ROLE:-postgres}" -d "${POSTGRES_DB:-url_shortener}" \
           -c "SELECT 1" > /dev/null 2>&1; then
            connected=true
            echo "Direct database connection successful!"
            break
        fi
        
        counter=$((counter + 1))
        echo "Waiting for database connection... (Attempt $counter/$MAX_ATTEMPTS)"
        sleep $INTERVAL
    done
fi

# Print database connection status and parameters
if [ "$connected" = true ]; then
    echo "✅ Successfully connected to PostgreSQL"
else
    echo "⚠️ WARNING: Could not establish connection to PostgreSQL after ${TIMEOUT} seconds"
    echo "PostgREST will still attempt to start, but may fail if database is unavailable"
fi

# Print detailed connection information for debugging
echo "Connection Parameters:"
echo "- PGRST_DB_URI: ${PGRST_DB_URI}"
echo "- PGRST_DB_SCHEMA: ${PGRST_DB_SCHEMA:-public}"
echo "- PGRST_DB_ANON_ROLE: ${PGRST_DB_ANON_ROLE:-postgres}"
echo "- PGRST_DB_POOL: ${PGRST_DB_POOL:-10}"
echo "- PGRST_SERVER_PORT: ${PGRST_SERVER_PORT:-3000}"

# Start PostgREST with appropriate error handling
echo "Starting PostgREST..."
exec postgrest || {
    exit_code=$?
    echo "❌ PostgREST failed to start with exit code ${exit_code}"
    echo "Please check your configuration and database connection"
    exit $exit_code
} 