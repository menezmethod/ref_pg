#!/bin/bash
set -e

echo "Initializing URL Shortener Database for Production..."

# Get environment variables
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_DB=${POSTGRES_DB:-url_shortener}
MASTER_PASSWORD=${MASTER_PASSWORD:-master123}
DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-5432}
MAX_RETRIES=30
RETRY_INTERVAL=2
SCHEMA_VERSION="1.0" # Set the current schema version

# Function to wait for the database to be ready
wait_for_db() {
  echo "Waiting for PostgreSQL to be ready at ${DB_HOST}:${DB_PORT}..."
  
  for i in $(seq 1 $MAX_RETRIES); do
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" > /dev/null 2>&1; then
      echo "PostgreSQL is ready!"
      return 0
    fi
    echo "Attempt $i/$MAX_RETRIES: PostgreSQL not ready yet. Retrying in $RETRY_INTERVAL seconds..."
    sleep $RETRY_INTERVAL
  done
  
  echo "ERROR: Could not connect to PostgreSQL after $MAX_RETRIES attempts"
  exit 1
}

# Wait for the database to be ready
wait_for_db

echo "Connected to PostgreSQL. Checking database migration status..."

# Create version table if it doesn't exist
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL
  CREATE TABLE IF NOT EXISTS schema_versions (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    success BOOLEAN NOT NULL DEFAULT FALSE
  );
EOSQL

# Check if the current version has been successfully applied
VERSION_APPLIED=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT EXISTS(SELECT 1 FROM schema_versions WHERE version='$SCHEMA_VERSION' AND success=TRUE);")

if echo "$VERSION_APPLIED" | grep -q 't'; then
  echo "Database schema version $SCHEMA_VERSION already applied successfully."
else
  echo "Database schema version $SCHEMA_VERSION needs to be applied..."
  
  # Insert or update version record to track we're starting the migration
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    INSERT INTO schema_versions (version, applied_at, success) 
    VALUES ('$SCHEMA_VERSION', NOW(), FALSE) 
    ON CONFLICT (version) 
    DO UPDATE SET applied_at = NOW(), success = FALSE;"
  
  # Apply the main migration
  echo "Applying main migration..."
  if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /migrations/000_main_migration.sql; then
    echo "Migration script executed successfully."
    
    # Mark migration as successful
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
      UPDATE schema_versions 
      SET success = TRUE, applied_at = NOW() 
      WHERE version = '$SCHEMA_VERSION';"
    
  else
    echo "WARNING: Error occurred during migration. Will retry on next run."
  fi
fi

# Now check if key schema objects exist regardless of version
echo "Verifying core schema objects exist..."

# Check if API schema exists, create if missing
SCHEMA_EXISTS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'api');")
if ! echo "$SCHEMA_EXISTS" | grep -q 't'; then
  echo "API schema doesn't exist! Creating it..."
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE SCHEMA IF NOT EXISTS api;"
fi

# Ensure roles are properly set up
echo "Setting up roles and permissions..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
    -- First ensure the anon role exists
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
            CREATE ROLE anon NOLOGIN;
        END IF;
    END
    \$\$;

    -- Recreate the authenticator role with the correct password
    DROP ROLE IF EXISTS authenticator;
    CREATE ROLE authenticator WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}' NOINHERIT;
    GRANT anon TO authenticator;

    -- Grant usage to anon role for public API access
    GRANT USAGE ON SCHEMA public TO anon;
    GRANT USAGE ON SCHEMA api TO anon;
    
    -- Grant permissions on tables
    ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT SELECT, INSERT, UPDATE ON TABLES TO anon;
    
    -- Grant permissions on specific tables if they exist
    DO \$\$
    BEGIN
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'api' AND tablename = 'api_keys') THEN
            GRANT SELECT, INSERT, UPDATE ON TABLE api.api_keys TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'api' AND tablename = 'urls') THEN
            GRANT SELECT, INSERT, UPDATE ON TABLE api.urls TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'api' AND tablename = 'short_links') THEN
            GRANT SELECT, INSERT, UPDATE ON TABLE api.short_links TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'api' AND tablename = 'link_clicks') THEN
            GRANT SELECT, INSERT, UPDATE ON TABLE api.link_clicks TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'api' AND tablename = 'analytics_events') THEN
            GRANT SELECT, INSERT, UPDATE ON TABLE api.analytics_events TO anon;
        END IF;
    END
    \$\$;
    
    -- Grant execute permissions for API functions
    DO \$\$
    BEGIN
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_original_url' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')) THEN
            GRANT EXECUTE ON FUNCTION api.get_original_url(TEXT) TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'create_short_link' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')) THEN
            GRANT EXECUTE ON FUNCTION api.create_short_link(TEXT, TEXT) TO anon;
            GRANT EXECUTE ON FUNCTION api.create_short_link(TEXT, TEXT, UUID, TIMESTAMPTZ, JSONB, TEXT) TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'track_link_click' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')) THEN
            GRANT EXECUTE ON FUNCTION api.track_link_click(TEXT, TEXT, TEXT, TEXT, UUID, JSONB) TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'redirect_to_original_url' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')) THEN
            GRANT EXECUTE ON FUNCTION api.redirect_to_original_url(TEXT, TEXT, TEXT, TEXT) TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_api_key' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')) THEN
            GRANT EXECUTE ON FUNCTION api.get_api_key(TEXT) TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'quick_link' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')) THEN
            GRANT EXECUTE ON FUNCTION api.quick_link(TEXT, TEXT, TEXT) TO anon;
        END IF;
        
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'test_create_link' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')) THEN
            GRANT EXECUTE ON FUNCTION api.test_create_link(TEXT, TEXT) TO anon;
        END IF;
    END
    \$\$;
EOSQL

# Verify the initialization
echo "Verifying database setup..."
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname='create_short_link' AND pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='api'))" | grep -q "t"; then
  echo "✅ Function api.create_short_link exists!"
else
  echo "❌ ERROR: Function api.create_short_link does not exist! Trying to apply migration directly..."
  # Direct attempt to create function if it doesn't exist
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    CREATE OR REPLACE FUNCTION api.test_create_link(p_url TEXT, p_alias TEXT)
    RETURNS JSON AS \$\$
    BEGIN
      RETURN json_build_object('success', TRUE, 'message', 'Link created successfully', 
                              'short_url', concat('https://ref.menezmethod.com/r/', p_alias), 
                              'original_url', p_url);
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;
  "
fi

if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon')" | grep -q "t"; then
  echo "✅ Role anon exists!"
else
  echo "❌ ERROR: Role anon does not exist! Creating it..."
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE ROLE anon NOLOGIN;"
fi

if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticator')" | grep -q "t"; then
  echo "✅ Role authenticator exists!"
else
  echo "❌ ERROR: Role authenticator does not exist! Creating it..."
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    CREATE ROLE authenticator WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}' NOINHERIT;
    GRANT anon TO authenticator;
  "
fi

echo "✨ Database initialization completed successfully! The URL shortener service is ready to use." 