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

# Kill the health check server when it's no longer needed
stop_health_server() {
  if [ -n "$HEALTH_SERVER_PID" ]; then
    echo "Stopping health check server (PID: $HEALTH_SERVER_PID)..."
    kill $HEALTH_SERVER_PID 2>/dev/null || true
  fi
}

# Handle signals properly for clean shutdown
cleanup() {
  echo "Received signal to shut down..."
  stop_health_server
  
  # Kill PostgREST if it's running
  if [ -n "$POSTGREST_PID" ]; then
    echo "Stopping PostgREST (PID: $POSTGREST_PID)..."
    kill $POSTGREST_PID 2>/dev/null || true
  fi
  
  exit 0
}

# Parse DATABASE_URL to extract components
parse_db_url() {
  # Extract DB connection details from PGRST_DB_URI
  db_uri="${PGRST_DB_URI}"
  
  # Extract host and port
  db_host=$(echo "$db_uri" | sed -n 's|.*@\([^:]*\):\([0-9]*\)/.*|\1|p')
  db_port=$(echo "$db_uri" | sed -n 's|.*@\([^:]*\):\([0-9]*\)/.*|\2|p')
  db_name=$(echo "$db_uri" | sed -n 's|.*/\([^?]*\).*|\1|p')
  
  if [ -z "$db_name" ]; then
    db_name=$(echo "$db_uri" | sed -n 's|.*/\(.*\)|\1|p')
  fi
  
  echo "Database connection details:"
  echo "- Host: $db_host"
  echo "- Port: $db_port"
  echo "- Database: $db_name" 
  
  export DB_HOST="$db_host"
  export DB_PORT="$db_port"
  export DB_NAME="$db_name"
}

# Wait for PostgreSQL to be ready using basic TCP connection check
wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready at $DB_HOST:$DB_PORT..."
  
  max_attempts=60  # 2 minutes total
  attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Checking PostgreSQL connection..."
    
    # Use timeout command with a bash-only approach for compatibility
    (echo > /dev/tcp/$DB_HOST/$DB_PORT) >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
      echo "PostgreSQL is up and accepting connections!"
      return 0
    fi
    
    attempt=$((attempt + 1))
    sleep 2
  done
  
  echo "Failed to connect to PostgreSQL after $max_attempts attempts"
  return 1
}

# Check that the api schema exists
check_schema() {
  echo "Checking if schema '${PGRST_DB_SCHEMA}' exists..."
  
  # We use the environment variables set by parse_db_url
  if PGPASSWORD=${POSTGRES_PASSWORD} psql -h $DB_HOST -p $DB_PORT -U ${POSTGRES_USER:-postgres} -d $DB_NAME -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name = '${PGRST_DB_SCHEMA}';" | grep -q "${PGRST_DB_SCHEMA}"; then
    echo "Schema '${PGRST_DB_SCHEMA}' exists!"
    return 0
  else
    echo "Schema '${PGRST_DB_SCHEMA}' does not exist in the database."
    echo "Please ensure the database migration has been applied correctly."
    return 1
  fi
}

# Check that the authenticator role exists
check_role() {
  echo "Checking if role '${PGRST_DB_ANON_ROLE}' exists..."
  
  if PGPASSWORD=${POSTGRES_PASSWORD} psql -h $DB_HOST -p $DB_PORT -U ${POSTGRES_USER:-postgres} -d $DB_NAME -c "SELECT rolname FROM pg_roles WHERE rolname = '${PGRST_DB_ANON_ROLE}';" | grep -q "${PGRST_DB_ANON_ROLE}"; then
    echo "Role '${PGRST_DB_ANON_ROLE}' exists!"
    return 0
  else
    echo "Role '${PGRST_DB_ANON_ROLE}' does not exist in the database."
    echo "Please ensure the database migration has been applied correctly."
    return 1
  fi
}

# Main execution logic
main() {
  # Start our health check server
  # Check if netcat is available for the health server
  if command -v nc >/dev/null 2>&1; then
    # Start the health check server
    start_health_server
  else
    echo "WARNING: netcat not available, health check server will not be started"
  fi
  
  # Set up basic signal handling - using numbers because some shells don't support names
  # SIGTERM = 15, SIGINT = 2
  trap cleanup 15
  trap cleanup 2
  
  # Parse database URL
  parse_db_url
  
  # Wait for PostgreSQL to be ready - with longer timeout
  wait_for_postgres || echo "WARNING: Database connection check failed, but continuing anyway..."
  
  echo "Starting PostgREST in foreground mode..."
  
  # Start PostgREST in the foreground, but keep script running
  postgrest &
  POSTGREST_PID=$!
  
  # Wait for PostgREST to start or fail
  sleep 5
  
  # Check if PostgREST is running
  if kill -0 $POSTGREST_PID 2>/dev/null; then
    echo "PostgREST started successfully with PID: $POSTGREST_PID"
    
    # Keep the script running to maintain our health check server
    echo "Entrypoint script is now monitoring PostgREST..."
    
    # Wait for PostgreSQL to terminate
    wait $POSTGREST_PID || true
    
    echo "PostgREST has terminated."
  else
    echo "ERROR: PostgREST failed to start properly"
  fi
  
  # Clean up before exiting
  stop_health_server
  
  echo "Entrypoint script is exiting."
}

# Run the main function
main
