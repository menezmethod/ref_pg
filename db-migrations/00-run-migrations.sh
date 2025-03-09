#!/bin/bash
set -e

echo "=== Running URL Shortener Migrations ==="

# The Postgres docker image automatically runs scripts in alphabetical order
# This script runs first and ensures roles and schemas exist before migrations

# Create necessary schemas
echo "Setting up schemas..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE SCHEMA IF NOT EXISTS auth;
    CREATE SCHEMA IF NOT EXISTS api;
EOSQL

# Create required roles
echo "Setting up roles..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        -- Create anonymous role if it doesn't exist
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
            CREATE ROLE anon NOLOGIN;
        END IF;
        
        -- Create authenticator role if it doesn't exist
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
            CREATE ROLE authenticator WITH LOGIN PASSWORD '$POSTGRES_PASSWORD' NOINHERIT;
        ELSE
            -- Update authenticator password to match the current POSTGRES_PASSWORD
            ALTER ROLE authenticator WITH PASSWORD '$POSTGRES_PASSWORD';
        END IF;
        
        -- Ensure anon role is granted to authenticator
        GRANT anon TO authenticator;
    END
    \$\$;
    
    -- Grant schema permissions immediately
    GRANT USAGE ON SCHEMA api TO anon;
    GRANT USAGE ON SCHEMA auth TO anon;
EOSQL

# Run the main migration file explicitly
echo "Applying main migration..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/migrations/000_main_migration.sql

# Grant permissions after all migrations run
echo "Setting up permissions..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Grant permissions for API access
    GRANT USAGE ON SCHEMA api TO anon;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO anon;
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA api TO anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA api TO anon;
    
    -- For tables in public schema if any exist
    GRANT USAGE ON SCHEMA public TO anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
    
    -- Show all roles and their memberships
    SELECT r.rolname, r.rolsuper, r.rolinherit,
           r.rolcreaterole, r.rolcreatedb, r.rolcanlogin,
           r.rolconnlimit, r.rolvaliduntil,
           ARRAY(SELECT b.rolname
                 FROM pg_catalog.pg_auth_members m
                 JOIN pg_catalog.pg_roles b ON (m.roleid = b.oid)
                 WHERE m.member = r.oid) as memberof
    FROM pg_catalog.pg_roles r
    WHERE r.rolname !~ '^pg_'
    ORDER BY 1;
    
    -- Show function permissions
    SELECT n.nspname AS schema,
           p.proname AS name,
           pg_catalog.pg_get_userbyid(p.proowner) AS owner,
           pg_catalog.array_to_string(p.proacl, E'\n') AS access_privileges
    FROM pg_catalog.pg_proc p
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api'
    ORDER BY 1, 2;
EOSQL

echo "✅ Migration completed successfully!" 