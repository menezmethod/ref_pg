-- URL Shortener API Key Authentication
-- This migration file adds API key authentication to secure the URL shortener service

BEGIN;

-- Create a table for API keys
CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_used_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,
    is_admin BOOLEAN DEFAULT FALSE,
    permissions JSONB DEFAULT '[]'::JSONB
);

-- Create indexes for efficient lookups
CREATE INDEX IF NOT EXISTS idx_api_keys_key ON api_keys(key);
CREATE INDEX IF NOT EXISTS idx_api_keys_is_active ON api_keys(is_active);

-- Check if a master admin key already exists
DO $$
DECLARE
    v_key TEXT;
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM api_keys WHERE name = 'Master Admin Key';
    
    IF v_count = 0 THEN
        -- Generate a random key
        v_key := encode(gen_random_bytes(24), 'hex');
        
        -- Insert the master admin key
        INSERT INTO api_keys (key, name, is_admin, permissions)
        VALUES (v_key, 'Master Admin Key', TRUE, '["admin"]'::JSONB);
        
        -- Output the key
        RAISE NOTICE 'Generated Master Admin Key: %', v_key;
    END IF;
END $$;

-- Function to check if an API key is valid
CREATE OR REPLACE FUNCTION is_valid_api_key(p_api_key TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- Update last_used_at timestamp
    UPDATE api_keys
    SET last_used_at = NOW()
    WHERE key = p_api_key
    AND is_active = TRUE;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to check if an API key has admin privileges
CREATE OR REPLACE FUNCTION is_admin_api_key(p_api_key TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM api_keys
        WHERE key = p_api_key
        AND is_active = TRUE
        AND is_admin = TRUE
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to generate a new API key (requires admin)
CREATE OR REPLACE FUNCTION generate_api_key(p_name TEXT, p_is_admin BOOLEAN DEFAULT FALSE)
RETURNS TEXT AS $$
DECLARE
    v_key TEXT;
    v_current_api_key TEXT;
BEGIN
    -- Get the current API key from request headers
    v_current_api_key := current_setting('request.header.x-api-key', TRUE);
    
    -- Check if the current API key is an admin key
    IF v_current_api_key IS NULL OR NOT is_admin_api_key(v_current_api_key) THEN
        RAISE EXCEPTION 'Unauthorized: admin API key required';
    END IF;
    
    -- Generate a random key
    v_key := encode(gen_random_bytes(24), 'hex');
    
    -- Insert the new API key
    INSERT INTO api_keys (key, name, is_admin)
    VALUES (v_key, p_name, p_is_admin);
    
    RETURN v_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION generate_api_key(TEXT, BOOLEAN) IS 'Generate a new API key (requires admin privileges)';

-- Function to revoke an API key (requires admin)
CREATE OR REPLACE FUNCTION revoke_api_key(p_key TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_current_api_key TEXT;
BEGIN
    -- Get the current API key from request headers
    v_current_api_key := current_setting('request.header.x-api-key', TRUE);
    
    -- Check if the current API key is an admin key
    IF v_current_api_key IS NULL OR NOT is_admin_api_key(v_current_api_key) THEN
        RAISE EXCEPTION 'Unauthorized: admin API key required';
    END IF;
    
    -- Revoke the API key
    UPDATE api_keys
    SET is_active = FALSE
    WHERE key = p_key;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION revoke_api_key(TEXT) IS 'Revoke an API key (requires admin privileges)';

-- Function to list all API keys (requires admin)
CREATE OR REPLACE FUNCTION list_api_keys()
RETURNS SETOF api_keys AS $$
DECLARE
    v_current_api_key TEXT;
BEGIN
    -- Get the current API key from request headers
    v_current_api_key := current_setting('request.header.x-api-key', TRUE);
    
    -- Check if the current API key is an admin key
    IF v_current_api_key IS NULL OR NOT is_admin_api_key(v_current_api_key) THEN
        RAISE EXCEPTION 'Unauthorized: admin API key required';
    END IF;
    
    RETURN QUERY SELECT * FROM api_keys;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION list_api_keys() IS 'List all API keys (requires admin privileges)';

-- Function to handle pre-request processing
CREATE OR REPLACE FUNCTION pre_request()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
BEGIN
    -- Get the API key from request headers
    v_api_key := current_setting('request.header.x-api-key', TRUE);
    
    -- Log the API key for debugging
    RAISE NOTICE 'Pre-request: API Key received: %', COALESCE(v_api_key, 'NULL');
    
    -- Store the API key in a session variable for use in functions
    IF v_api_key IS NOT NULL THEN
        -- Update last_used_at timestamp
        UPDATE api_keys
        SET last_used_at = NOW()
        WHERE key = v_api_key
        AND is_active = TRUE;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION pre_request() IS 'Function to handle pre-request processing';

-- Override the create_short_link function to check for a valid API key
CREATE OR REPLACE FUNCTION create_short_link(
    p_original_url TEXT,
    p_custom_alias TEXT DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_expires_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON AS $$
DECLARE
    v_url_id UUID;
    v_code TEXT;
    v_short_link_id UUID;
    v_result JSON;
    v_api_key TEXT;
BEGIN
    -- Get the API key from request headers
    v_api_key := current_setting('request.header.x-api-key', TRUE);
    
    -- Debug log
    RAISE NOTICE 'API Key received: %', COALESCE(v_api_key, 'NULL');
    
    -- Check if the API key is valid
    IF v_api_key IS NULL THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Unauthorized: API key is missing'
        );
    END IF;
    
    -- Check if the API key exists in the database
    IF NOT EXISTS (SELECT 1 FROM api_keys WHERE key = v_api_key) THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Unauthorized: API key not found'
        );
    END IF;
    
    -- Check if the API key is active
    IF NOT EXISTS (SELECT 1 FROM api_keys WHERE key = v_api_key AND is_active = TRUE) THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Unauthorized: API key is inactive'
        );
    END IF;

    -- First, check if URL already exists for this user
    IF p_user_id IS NOT NULL THEN
        SELECT id INTO v_url_id
        FROM urls
        WHERE original_url = p_original_url
        AND created_by = p_user_id
        LIMIT 1;
    END IF;

    -- If URL doesn't exist, create it
    IF v_url_id IS NULL THEN
        INSERT INTO urls (original_url, created_by, metadata)
        VALUES (p_original_url, p_user_id, p_metadata)
        RETURNING id INTO v_url_id;
    END IF;

    -- Handle custom alias if provided
    IF p_custom_alias IS NOT NULL THEN
        -- Check if custom alias is available
        IF EXISTS(SELECT 1 FROM short_links WHERE custom_alias = p_custom_alias) THEN
            RETURN json_build_object(
                'success', false,
                'error', 'Custom alias already in use'
            );
        END IF;

        v_code := p_custom_alias;
    ELSE
        -- Generate a random code
        v_code := generate_short_code();
    END IF;

    -- Create the short link
    INSERT INTO short_links (url_id, code, custom_alias, expires_at)
    VALUES (v_url_id, v_code, p_custom_alias, p_expires_at)
    RETURNING id INTO v_short_link_id;

    -- Log event
    INSERT INTO analytics_events (
        event_type,
        user_id,
        event_data
    ) VALUES (
        'short_link_created',
        p_user_id,
        jsonb_build_object(
            'url_id', v_url_id,
            'short_link_id', v_short_link_id,
            'code', v_code,
            'custom_alias', p_custom_alias,
            'original_url', p_original_url
        )
    );

    -- Prepare result
    SELECT json_build_object(
        'success', true,
        'short_link_id', v_short_link_id,
        'url_id', v_url_id,
        'code', v_code,
        'original_url', p_original_url,
        'custom_alias', p_custom_alias,
        'expires_at', p_expires_at
    ) INTO v_result;

    -- Cache the result in Redis if possible
    BEGIN
        PERFORM cache_short_link(v_code);
    EXCEPTION WHEN OTHERS THEN
        -- Continue even if caching fails
        NULL;
    END;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION create_short_link(TEXT, TEXT, UUID, TIMESTAMP WITH TIME ZONE, JSONB) IS 'Creates a short link from an original URL, optionally using a custom alias. Requires a valid API key.';

-- Output all API keys for reference
SELECT * FROM api_keys;

COMMIT; 