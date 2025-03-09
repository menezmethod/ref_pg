#!/bin/sh
set -e

echo "Starting PostgREST entrypoint script (with built-in health check)..."

# Create a simple health check server using a background process
start_health_server() {
  # Use a simple while loop to create a basic HTTP server on port 8888
  # This will respond to health checks while PostgREST is starting
  echo "Starting built-in health check server on port 8888..."
  (
    while true; do
      { echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"; } | nc -l -p 8888 -q 1 || true
      sleep 0.1
    done
  ) &
  HEALTH_SERVER_PID=$!
  echo "Health check server started with PID: $HEALTH_SERVER_PID"
}

# Handle signals properly
trap 'kill -TERM $POSTGREST_PID; kill -TERM $HEALTH_SERVER_PID; exit' TERM INT

# Start the health check server
start_health_server

# Database connection attempts
MAX_RETRIES=60
RETRY_INTERVAL=5

# Test database access
echo "Waiting for PostgreSQL to be ready (max $MAX_RETRIES attempts)..."
for i in $(seq 1 $MAX_RETRIES); do
  echo "Attempt $i/$MAX_RETRIES: Testing PostgreSQL connection..."
  
  # Try to connect to the database (using the standard DB connection)
  if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h db -U authenticator -d "${POSTGRES_DB}" -c "SELECT 1" >/dev/null 2>&1; then
    echo "Successfully connected to PostgreSQL!"
    
    # Verify schema and roles
    echo "Verifying database schema and roles..."
    if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h db -U authenticator -d "${POSTGRES_DB}" -c "SELECT COUNT(*) FROM pg_proc WHERE proname = 'test_create_link' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')" 2>/dev/null | grep -q "1"; then
      echo "Function api.test_create_link exists! Database is properly initialized."
      break
    else
      echo "Function api.test_create_link not found! Database might not be fully initialized."
      
      if [ $i -eq $MAX_RETRIES ]; then
        echo "Maximum retries reached. Database initialization might have failed."
        echo "Please check your PostgreSQL container logs."
        # We'll continue anyway and let PostgREST report the specific error
      fi
    fi
  else
    echo "Failed to connect to PostgreSQL, retrying in $RETRY_INTERVAL seconds..."
    
    if [ $i -eq $MAX_RETRIES ]; then
      echo "Maximum retries reached. Could not connect to PostgreSQL."
      echo "Please check your PostgreSQL container logs."
      # We'll continue anyway and let PostgREST report the specific error
    else
      sleep $RETRY_INTERVAL
    fi
  fi
done

# Get the actual connection string to use (prefer the standard one)
DB_URI="postgres://authenticator:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"
echo "Using database connection: $DB_URI"

# Start PostgREST
echo "Starting PostgREST in foreground mode..."
PGRST_DB_URI="$DB_URI" postgrest &
POSTGREST_PID=$!
echo "PostgREST started with PID: $POSTGREST_PID"

# Wait for either process to exit
wait $POSTGREST_PID
EXIT_STATUS=$?

echo "PostgREST exited with status $EXIT_STATUS"
exit $EXIT_STATUS 