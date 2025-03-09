#!/bin/bash
set -e

echo "=== URL Shortener Emergency Migration Fix ==="
echo "This script will manually apply the migration to your Coolify deployment."
echo "WARNING: Only use this if the normal migration process has failed."

# Check if docker is available
if ! command -v docker &> /dev/null; then
  echo "ERROR: Docker is required but not installed."
  exit 1
fi

# Find the database container
DB_CONTAINER=$(docker ps --filter name=url_shortener_db -q)
if [ -z "$DB_CONTAINER" ]; then
  echo "ERROR: Could not find the database container."
  echo "Make sure your application is running in Coolify."
  exit 1
fi

echo "Found database container: $DB_CONTAINER"

# Check if the migration file exists
if [ ! -f "migrations/000_main_migration.sql" ]; then
  echo "ERROR: Migration file not found at migrations/000_main_migration.sql"
  exit 1
fi

# Copy migration file to container
echo "Copying migration file to container..."
docker cp migrations/000_main_migration.sql $DB_CONTAINER:/tmp/000_main_migration.sql

# Apply migration
echo "Applying migration..."
docker exec $DB_CONTAINER bash -c "
  export PGPASSWORD=\$(grep POSTGRES_PASSWORD /etc/environment | cut -d= -f2 || echo 'postgres');
  psql -U postgres -d url_shortener -f /tmp/000_main_migration.sql
"

# Set permissions
echo "Setting up permissions..."
docker exec $DB_CONTAINER bash -c "
  export PGPASSWORD=\$(grep POSTGRES_PASSWORD /etc/environment | cut -d= -f2 || echo 'postgres');
  psql -U postgres -d url_shortener -c '
    DO \$\$
    BEGIN
        -- Ensure roles exist
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = \"anon\") THEN
            CREATE ROLE anon NOLOGIN;
        END IF;
        
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = \"authenticator\") THEN
            CREATE ROLE authenticator WITH LOGIN PASSWORD '\"\$PGPASSWORD\"' NOINHERIT;
            GRANT anon TO authenticator;
        END IF;
        
        -- Grant permissions
        GRANT USAGE ON SCHEMA api TO anon;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO anon;
        GRANT USAGE ON ALL SEQUENCES IN SCHEMA api TO anon;
        GRANT SELECT ON ALL TABLES IN SCHEMA api TO anon;
    END
    \$\$;
  '
"

echo "Migration applied. Restarting PostgREST to refresh schema cache..."
POSTGREST_CONTAINER=$(docker ps --filter name=url_shortener_api -q)
if [ -n "$POSTGREST_CONTAINER" ]; then
  docker restart $POSTGREST_CONTAINER
  echo "PostgREST restarted successfully."
else
  echo "WARNING: Could not find the PostgREST container to restart."
fi

echo "✅ Emergency migration fix completed!"
echo "Please run ./verify-migration.sh to verify the migration was successful." 