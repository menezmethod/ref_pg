-- This file is automatically executed by Postgres on initialization
-- No need for complex scripts or permissions issues

-- Create necessary schemas
CREATE SCHEMA IF NOT EXISTS api;

-- Create roles needed by PostgREST
DO $$
BEGIN
    -- Create anonymous role if it doesn't exist
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
    END IF;
    
    -- Create authenticator role if it doesn't exist
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
        CREATE ROLE authenticator WITH LOGIN PASSWORD current_setting('POSTGRES_PASSWORD') NOINHERIT;
        GRANT anon TO authenticator;
    END IF;
END
$$;

-- Grant permissions
GRANT USAGE ON SCHEMA api TO anon;

-- Import the main migration file
\i /docker-entrypoint-initdb.d/000_main_migration.sql

-- Grant additional permissions after migration
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO anon;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA api TO anon;
GRANT SELECT ON ALL TABLES IN SCHEMA api TO anon; 