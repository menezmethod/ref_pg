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

# Wait for PostgreSQL to be ready
wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready at $DB_HOST:$DB_PORT..."
  
  max_attempts=30
  attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Checking PostgreSQL connection..."
    
    if nc -z $DB_HOST $DB_PORT; then
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

# Install netcat for connectivity checks if not present
if ! command -v nc &> /dev/null; then
  echo "Installing netcat for connectivity checks..."
  apt-get update && apt-get install -y netcat
fi

# Install PostgreSQL client for schema checks if not present
if ! command -v psql &> /dev/null; then
  echo "Installing PostgreSQL client for schema checks..."
  apt-get update && apt-get install -y postgresql-client
fi

# Main execution logic
main() {
  # Parse database URL
  parse_db_url
  
  # Wait for PostgreSQL to be ready
  if ! wait_for_postgres; then
    echo "ERROR: Failed to connect to PostgreSQL. PostgREST cannot start."
    exit 1
  fi
  
  # Optional additional checks - might fail if we don't have psql installed
  if command -v psql &> /dev/null; then
    # These are non-fatal as they might fail due to permissions
    check_schema || echo "WARNING: Schema check failed, but continuing anyway..."
    check_role || echo "WARNING: Role check failed, but continuing anyway..."
  else
    echo "WARNING: PostgreSQL client not available, skipping schema and role checks"
  fi
  
  echo "All checks completed. Starting PostgREST..."
  
  # Start PostgREST
  exec postgrest
}

# Run the main function
main
