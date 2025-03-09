#!/bin/sh
set -e

echo "Starting PostgREST with simplified entrypoint..."

# Try to resolve the database host and wait for it to be available
wait_for_database() {
  echo "Checking database connection..."
  
  # Extract connection details from PGRST_DB_URI
  db_uri="${PGRST_DB_URI}"
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
  
  # Use basic connection check with /dev/tcp
  timeout=60
  counter=0
  echo "Waiting for PostgreSQL at $db_host:$db_port (timeout: $timeout seconds)..."
  
  while [ $counter -lt $timeout ]; do
    if (echo > /dev/tcp/$db_host/$db_port) 2>/dev/null; then
      echo "Successfully connected to PostgreSQL!"
      return 0
    fi
    
    counter=$((counter + 1))
    echo "Attempt $counter/$timeout: Waiting for PostgreSQL... (sleeping 1s)"
    sleep 1
  done
  
  echo "WARNING: Could not connect to PostgreSQL after $timeout attempts"
  echo "Continuing anyway, PostgREST will retry connecting..."
  return 1
}

# Try to connect to the database before starting PostgREST
wait_for_database

# Log environment for debugging
echo "Environment variables:"
env | grep -v -E 'PASSWORD|PASS|SECRET|KEY' | sort || true

# Start PostgREST in the foreground
echo "Starting PostgREST..."
exec postgrest
