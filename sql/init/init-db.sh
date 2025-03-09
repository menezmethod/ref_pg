#!/bin/bash
set -e

echo "Running init-db.sh..."

# Wait for PostgreSQL to be ready
until pg_isready; do
  echo "Waiting for PostgreSQL to be ready..."
  sleep 1
done

# Get environment variables
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
JWT_SECRET=${JWT_SECRET:-your_jwt_secret_change_me}
MASTER_PASSWORD=${MASTER_PASSWORD:-master123}
POSTGRES_DB=${POSTGRES_DB:-url_shortener}

# Set up authentication - this runs as superuser
psql -v ON_ERROR_STOP=0 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- First ensure the anon role exists
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
            CREATE ROLE anon NOLOGIN;
        END IF;
    END
    \$\$;

    -- Next recreate the authenticator role with the correct password
    DROP ROLE IF EXISTS authenticator;
    CREATE ROLE authenticator WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}' NOINHERIT;
    GRANT anon TO authenticator;

    -- Set custom parameters for JWT in the database (requires custom postgresql.conf setup to work)
    -- These are just informational for our app
    ALTER DATABASE "$POSTGRES_DB" SET app.jwt_secret TO '${JWT_SECRET}';
    ALTER DATABASE "$POSTGRES_DB" SET app.postgres_password TO '${POSTGRES_PASSWORD}';
    ALTER DATABASE "$POSTGRES_DB" SET app.master_password TO '${MASTER_PASSWORD}';

    -- Create the api schema if it doesn't exist
    CREATE SCHEMA IF NOT EXISTS api;

    -- Grant usage to anon role for public API access
    GRANT USAGE ON SCHEMA public TO anon;
    GRANT USAGE ON SCHEMA api TO anon;
    
    -- Grant permissions on tables
    GRANT SELECT, INSERT, UPDATE ON TABLE api_keys TO anon;
    GRANT SELECT, INSERT, UPDATE ON TABLE urls TO anon;
    GRANT SELECT, INSERT, UPDATE ON TABLE short_links TO anon;
    GRANT SELECT, INSERT, UPDATE ON TABLE link_clicks TO anon;
    GRANT SELECT, INSERT, UPDATE ON TABLE analytics_events TO anon;
    
    -- Grant execute permissions for API functions
    GRANT EXECUTE ON FUNCTION api.get_original_url(TEXT) TO anon;
    GRANT EXECUTE ON FUNCTION api.create_short_link(TEXT, TEXT) TO anon;
    GRANT EXECUTE ON FUNCTION api.track_link_click(TEXT, TEXT, TEXT, TEXT, UUID, JSONB) TO anon;
    GRANT EXECUTE ON FUNCTION api.redirect_to_original_url(TEXT, TEXT, TEXT, TEXT) TO anon;
    GRANT EXECUTE ON FUNCTION api.get_api_key(TEXT) TO anon;
    GRANT EXECUTE ON FUNCTION api.quick_link(TEXT, TEXT, TEXT) TO anon;
    GRANT EXECUTE ON FUNCTION api.test_create_link(TEXT, TEXT) TO anon;
EOSQL

echo "Database initialization completed successfully!" 