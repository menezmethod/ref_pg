-- Migration verification script
-- This script checks if all expected database objects from 000_main_migration.sql exist
-- It will raise clear errors if anything is missing

-- First, create a migrations tracking table if it doesn't exist
CREATE TABLE IF NOT EXISTS migration_history (
    id SERIAL PRIMARY KEY,
    migration_name TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    success BOOLEAN NOT NULL
);

-- Function to log migration status
CREATE OR REPLACE FUNCTION log_migration(
    p_migration_name TEXT,
    p_success BOOLEAN
) RETURNS void AS $$
BEGIN
    INSERT INTO migration_history (migration_name, success)
    VALUES (p_migration_name, p_success);
END;
$$ LANGUAGE plpgsql;

-- Begin verification
DO $$
DECLARE
    missing_objects TEXT := '';
    schema_exists BOOLEAN;
    table_exists BOOLEAN;
    function_exists BOOLEAN;
    role_exists BOOLEAN;
BEGIN
    -- Check for required schemas
    SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'api') INTO schema_exists;
    IF NOT schema_exists THEN
        missing_objects := missing_objects || 'Schema "api" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') INTO schema_exists;
    IF NOT schema_exists THEN
        missing_objects := missing_objects || 'Schema "auth" is missing.' || E'\n';
    END IF;
    
    -- Check for required tables
    SELECT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE tablename = 'users'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Table "users" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE tablename = 'urls'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Table "urls" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE tablename = 'short_links'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Table "short_links" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE tablename = 'link_clicks'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Table "link_clicks" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE tablename = 'analytics_events'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Table "analytics_events" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE tablename = 'api_keys'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Table "api_keys" is missing.' || E'\n';
    END IF;
    
    -- Check for required functions
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'update_timestamp'
    ) INTO function_exists;
    IF NOT function_exists THEN
        missing_objects := missing_objects || 'Function "update_timestamp" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'check_jwt' AND n.nspname = 'auth'
    ) INTO function_exists;
    IF NOT function_exists THEN
        missing_objects := missing_objects || 'Function "auth.check_jwt" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'generate_short_code'
    ) INTO function_exists;
    IF NOT function_exists THEN
        missing_objects := missing_objects || 'Function "generate_short_code" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'create_short_link'
    ) INTO function_exists;
    IF NOT function_exists THEN
        missing_objects := missing_objects || 'Function "create_short_link" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'get_original_url'
    ) INTO function_exists;
    IF NOT function_exists THEN
        missing_objects := missing_objects || 'Function "get_original_url" is missing.' || E'\n';
    END IF;
    
    -- Check for required roles
    SELECT EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'anon'
    ) INTO role_exists;
    IF NOT role_exists THEN
        missing_objects := missing_objects || 'Role "anon" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'authenticator'
    ) INTO role_exists;
    IF NOT role_exists THEN
        missing_objects := missing_objects || 'Role "authenticator" is missing.' || E'\n';
    END IF;
    
    -- Check API functions
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'get_original_url' AND n.nspname = 'api'
    ) INTO function_exists;
    IF NOT function_exists THEN
        missing_objects := missing_objects || 'Function "api.get_original_url" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'create_short_link' AND n.nspname = 'api'
    ) INTO function_exists;
    IF NOT function_exists THEN
        missing_objects := missing_objects || 'Function "api.create_short_link" is missing.' || E'\n';
    END IF;
    
    -- Check indexes
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'idx_urls_created_at'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Index "idx_urls_created_at" is missing.' || E'\n';
    END IF;
    
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'idx_short_links_custom_alias'
    ) INTO table_exists;
    IF NOT table_exists THEN
        missing_objects := missing_objects || 'Index "idx_short_links_custom_alias" is missing.' || E'\n';
    END IF;
    
    -- If any objects are missing, raise an error with details
    IF missing_objects <> '' THEN
        RAISE EXCEPTION 'Migration verification failed. Missing objects: %', missing_objects;
    ELSE
        -- Log successful verification
        PERFORM log_migration('999_verify_migration', TRUE);
        RAISE NOTICE 'Migration verification successful. All required database objects exist.';
    END IF;
    
EXCEPTION WHEN OTHERS THEN
    -- Log failed verification
    PERFORM log_migration('999_verify_migration', FALSE);
    RAISE;
END;
$$; 