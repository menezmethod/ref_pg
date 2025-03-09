#!/bin/bash
set -e

echo "=== URL Shortener Production Verification Tool ==="
echo "This script will verify your production setup and fix issues if needed."

# Function to check if the database is properly set up
check_database() {
  echo "Checking database..."
  
  # Check if the database container is running
  DB_CONTAINER=$(docker ps --filter name=url_shortener_db -q)
  if [ -z "$DB_CONTAINER" ]; then
    echo "ERROR: Database container not found. Make sure it's running."
    return 1
  fi
  
  # Check if we can connect to the database
  echo "Testing database connection..."
  if ! docker exec $DB_CONTAINER psql -U postgres -d url_shortener -c "SELECT 1" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to database. Check database logs."
    return 1
  fi
  
  # Check if the key function exists
  echo "Checking for test_create_link function..."
  FUNC_EXISTS=$(docker exec $DB_CONTAINER psql -U postgres -d url_shortener -c "\df api.test_create_link" | grep -c test_create_link || true)
  
  if [ "$FUNC_EXISTS" -eq "0" ]; then
    echo "WARNING: Function api.test_create_link not found. Database might not be properly initialized."
    return 1
  else
    echo "SUCCESS: Function api.test_create_link found. Database seems properly initialized."
    return 0
  fi
}

# Function to fix database issues
fix_database() {
  echo "Attempting to fix database issues..."
  
  DB_CONTAINER=$(docker ps --filter name=url_shortener_db -q)
  if [ -z "$DB_CONTAINER" ]; then
    echo "ERROR: Database container not found. Cannot fix."
    return 1
  fi
  
  # Copy the migration file to the container
  echo "Copying migration file to container..."
  docker cp migrations/000_main_migration.sql $DB_CONTAINER:/tmp/
  
  # Execute the migration
  echo "Executing migration..."
  docker exec $DB_CONTAINER psql -U postgres -d url_shortener -f /tmp/000_main_migration.sql
  
  # Check if the issue is fixed
  if check_database; then
    echo "SUCCESS: Database issues fixed successfully!"
    return 0
  else
    echo "ERROR: Could not fix database issues. Manual intervention required."
    return 1
  fi
}

# Check and fix if needed
if check_database; then
  echo "All database checks passed! Your URL shortener should be fully operational."
else
  echo "Database issues detected. Attempting to fix..."
  if fix_database; then
    echo "SUCCESS: All issues have been fixed automatically!"
  else
    echo "ERROR: Could not fix all issues automatically. Please check the logs."
  fi
fi

# Verify PostgREST can connect to the database
echo "Checking PostgREST connection to database..."
POSTGREST_CONTAINER=$(docker ps --filter name=url_shortener_api -q)
if [ -z "$POSTGREST_CONTAINER" ]; then
  echo "ERROR: PostgREST container not found. Make sure it's running."
else
  # Print connection info from PostgREST logs
  echo "PostgREST connection info:"
  docker logs $POSTGREST_CONTAINER | grep "connection string" | tail -1
  
  # Check if PostgREST is responding
  echo "Testing PostgREST API..."
  if curl -s http://localhost:3000/ > /dev/null; then
    echo "SUCCESS: PostgREST is responding correctly!"
  else
    echo "WARNING: PostgREST is not responding. You may need to restart it."
    echo "Try: docker restart $POSTGREST_CONTAINER"
  fi
fi

echo "=== Verification complete ==="
echo "If issues persist, please check your container logs for more details." 