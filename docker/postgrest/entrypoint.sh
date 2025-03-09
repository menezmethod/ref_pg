#!/bin/sh
set -e

echo "Starting PostgREST entrypoint script..."

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
  
  max_attempts=60  # Increased from 30 to 60 (2 minutes total)
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

# Start PostgREST in the background
start_postgrest_bg() {
  echo "Starting PostgREST in background mode..."
  postgrest &
  POSTGREST_PID=$!
  echo "PostgREST started with PID: $POSTGREST_PID"
  
  # Give it a moment to initialize
  sleep 3
  
  # Check if process is still running
  if kill -0 $POSTGREST_PID 2>/dev/null; then
    echo "PostgREST is running successfully"
    return 0
  else
    echo "PostgREST failed to start properly"
    return 1
  fi
}

# Main execution logic
main() {
  # Parse database URL
  parse_db_url
  
  # Wait for PostgreSQL to be ready - with longer timeout
  if ! wait_for_postgres; then
    echo "ERROR: Failed to connect to PostgreSQL. Continuing anyway since the DB might still be initializing..."
    # Don't exit here, try to start PostgREST anyway
  fi
  
  echo "All checks completed. Starting PostgREST..."
  
  # Start PostgREST - don't use exec so our script can continue running
  # This ensures the container stays alive even if initial health checks fail
  postgrest
}

# Run the main function
main
