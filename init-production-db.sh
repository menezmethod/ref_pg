#!/bin/bash
set -e

echo "Initializing URL Shortener Database for Production..."

# Get environment variables
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_DB=${POSTGRES_DB:-url_shortener}
MASTER_PASSWORD=${MASTER_PASSWORD:-master123}

# Apply the main migration
echo "Applying main migration..."
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /migrations/000_main_migration.sql

# Ensure roles are properly set up
echo "Setting up roles and permissions..."
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
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