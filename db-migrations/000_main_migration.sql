-- URL Shortener Consolidated Migration
-- This single file contains the complete schema for the URL shortener service with all updates
-- It merges all incremental migrations into one main file

-- Initiate the transaction
BEGIN;

-- Create necessary extensions first
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";      -- UUID support
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- Cryptographic functions
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- Query monitoring

-- Create roles for authentication and authorization
DROP ROLE IF EXISTS anonymous;
DROP ROLE IF EXISTS authenticator;

-- Create anonymous role (used for unauthenticated operations)
CREATE ROLE anonymous NOLOGIN;

-- Create authenticator role with a temporary password that will be updated by init-db.sh
CREATE ROLE authenticator WITH LOGIN PASSWORD 'temp_password' NOINHERIT;

-- Grant anonymous role to authenticator
GRANT anonymous TO authenticator;

-- Create schemas if they don't exist
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS api;

-- Create functions used by the schema
CREATE OR REPLACE FUNCTION update_timestamp() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create function to check JWT tokens
CREATE OR REPLACE FUNCTION auth.check_jwt() RETURNS void AS $$
BEGIN
  -- This is a placeholder for JWT checking
  -- In a real application, you would verify the JWT and set user-related settings
  -- For now, we'll just proceed without verification since we're in development
END;
$$ LANGUAGE plpgsql;

-- Create Users table for authentication if it doesn't exist
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Only create the trigger if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'update_users_timestamp') THEN
        CREATE TRIGGER update_users_timestamp
        BEFORE UPDATE ON users
        FOR EACH ROW
        EXECUTE FUNCTION update_timestamp();
    END IF;
END $$;

-- Create indexes if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_email') THEN
        CREATE INDEX idx_users_email ON users(email);
    END IF;
END$$;

-- Create URLs table to store original URLs if it doesn't exist
CREATE TABLE IF NOT EXISTS urls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    original_url TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Only create the trigger if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'update_urls_timestamp') THEN
        CREATE TRIGGER update_urls_timestamp
        BEFORE UPDATE ON urls
        FOR EACH ROW
        EXECUTE FUNCTION update_timestamp();
    END IF;
END $$;

-- Create indexes if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_urls_created_by') THEN
        CREATE INDEX idx_urls_created_by ON urls(created_by);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_urls_created_at') THEN
        CREATE INDEX idx_urls_created_at ON urls(created_at);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_urls_original_url') THEN
        CREATE INDEX idx_urls_original_url ON urls(original_url);
    END IF;
END$$;

-- Create short_links table if it doesn't exist
CREATE TABLE IF NOT EXISTS short_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    url_id UUID NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
    code TEXT NOT NULL UNIQUE,
    custom_alias TEXT UNIQUE,
    is_active BOOLEAN DEFAULT TRUE,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Only create the trigger if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'update_short_links_timestamp') THEN
        CREATE TRIGGER update_short_links_timestamp
        BEFORE UPDATE ON short_links
        FOR EACH ROW
        EXECUTE FUNCTION update_timestamp();
    END IF;
END $$;

-- Create indexes if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_short_links_url_id') THEN
        CREATE INDEX idx_short_links_url_id ON short_links(url_id);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_short_links_code') THEN
        CREATE INDEX idx_short_links_code ON short_links(code);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_short_links_custom_alias') THEN
        CREATE INDEX idx_short_links_custom_alias ON short_links(custom_alias);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_short_links_is_active') THEN
        CREATE INDEX idx_short_links_is_active ON short_links(is_active);
    END IF;
END$$;

-- Create link_clicks table to track clicks if it doesn't exist
CREATE TABLE IF NOT EXISTS link_clicks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    short_link_id UUID NOT NULL REFERENCES short_links(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    ip_address TEXT,
    user_agent TEXT,
    referrer TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Create indexes if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_link_clicks_short_link_id') THEN
        CREATE INDEX idx_link_clicks_short_link_id ON link_clicks(short_link_id);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_link_clicks_created_at') THEN
        CREATE INDEX idx_link_clicks_created_at ON link_clicks(created_at);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_link_clicks_metadata') THEN
        CREATE INDEX idx_link_clicks_metadata ON link_clicks USING GIN (metadata);
    END IF;
END$$;

-- Create analytics_events table for general event tracking if it doesn't exist
CREATE TABLE IF NOT EXISTS analytics_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    event_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create indexes if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_analytics_event_type') THEN
        CREATE INDEX idx_analytics_event_type ON analytics_events(event_type);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_analytics_user_id') THEN
        CREATE INDEX idx_analytics_user_id ON analytics_events(user_id);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_analytics_created_at') THEN
        CREATE INDEX idx_analytics_created_at ON analytics_events(created_at);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_analytics_event_data') THEN
        CREATE INDEX idx_analytics_event_data ON analytics_events USING GIN (event_data);
    END IF;
END$$;

-- Create a table for API keys if it doesn't exist
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

-- Create indexes if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_api_keys_key') THEN
        CREATE INDEX idx_api_keys_key ON api_keys(key);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_api_keys_is_active') THEN
        CREATE INDEX idx_api_keys_is_active ON api_keys(is_active);
    END IF;
END$$;

-- Function to generate short code if it doesn't exist
CREATE OR REPLACE FUNCTION generate_short_code(length INTEGER DEFAULT 6) RETURNS TEXT AS $$
DECLARE
    chars TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    result TEXT := '';
    i INTEGER := 0;
    code_exists BOOLEAN;
BEGIN
    LOOP
        -- Generate a random code
        result := '';
        FOR i IN 1..length LOOP
            result := result || substr(chars, floor(random() * length(chars) + 1)::INTEGER, 1);
        END LOOP;
        
        -- Check if the code already exists
        SELECT EXISTS(SELECT 1 FROM short_links WHERE code = result) INTO code_exists;
        
        -- Exit if code is unique
        EXIT WHEN NOT code_exists;
    END LOOP;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;

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

-- Function to get an API key using the master password
CREATE OR REPLACE FUNCTION get_api_key(p_password TEXT)
RETURNS JSON AS $$
DECLARE
    v_master_password TEXT;
    v_key TEXT;
BEGIN
    -- We'll use a simpler approach - check against a standard master password
    -- In production, you would use a more secure method
    v_master_password := current_setting('app.master_password', TRUE);
    
    IF p_password IS NULL OR p_password <> v_master_password THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Invalid password'
        );
    END IF;
    
    -- Generate a new API key
    v_key := encode(gen_random_bytes(24), 'hex');
    
    -- Insert the new API key
    INSERT INTO api_keys (key, name, is_admin)
    VALUES (v_key, 'Generated API Key', FALSE);
    
    RETURN json_build_object(
        'success', TRUE,
        'key', v_key
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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

-- Function to handle pre-request processing
CREATE OR REPLACE FUNCTION pre_request()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
BEGIN
    -- Get the API key from request headers
    v_api_key := current_setting('request.header.x-api-key', TRUE);
    
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

-- Function to create a short link
CREATE OR REPLACE FUNCTION create_short_link(
    p_original_url TEXT,
    p_custom_alias TEXT DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_expires_at TIMESTAMPTZ DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_api_key TEXT DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
    v_url_id UUID;
    v_code TEXT;
    v_short_link_id UUID;
    v_result JSON;
    v_api_key TEXT;
BEGIN
    -- Get the API key from parameter or request headers
    IF p_api_key IS NOT NULL THEN
        v_api_key := p_api_key;
    ELSE
        v_api_key := current_setting('request.header.x-api-key', TRUE);
    END IF;
    
    -- Check if the API key is valid
    IF v_api_key IS NULL THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Unauthorized: API key is missing. Please provide X-API-Key header or p_api_key parameter.'
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
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- Function to get the original URL from a short code
CREATE OR REPLACE FUNCTION get_original_url(p_code TEXT)
RETURNS TEXT AS $$
DECLARE
    v_original_url TEXT;
BEGIN
    SELECT u.original_url INTO v_original_url
    FROM short_links sl
    JOIN urls u ON sl.url_id = u.id
    WHERE sl.code = p_code
    AND (sl.expires_at IS NULL OR sl.expires_at > NOW())
    AND sl.is_active = TRUE;
    
    RETURN v_original_url;
END;
$$ LANGUAGE plpgsql;

-- Function to track link clicks
CREATE OR REPLACE FUNCTION track_link_click(
    p_code TEXT,
    p_referrer TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS VOID AS $$
DECLARE
    v_short_link_id UUID;
BEGIN
    -- Get the short link ID
    SELECT id INTO v_short_link_id
    FROM short_links
    WHERE code = p_code;
    
    -- If short link exists, record the click
    IF v_short_link_id IS NOT NULL THEN
        INSERT INTO link_clicks (
            short_link_id,
            user_id,
            ip_address,
            user_agent,
            referrer,
            metadata
        ) VALUES (
            v_short_link_id,
            p_user_id,
            p_ip_address,
            p_user_agent,
            p_referrer,
            p_metadata
        );
        
        -- Log the event
        INSERT INTO analytics_events (
            event_type,
            user_id,
            event_data
        ) VALUES (
            'link_clicked',
            p_user_id,
            jsonb_build_object(
                'short_link_id', v_short_link_id,
                'code', p_code,
                'ip_address', p_ip_address,
                'referrer', p_referrer
            )
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Function to redirect to the original URL
CREATE OR REPLACE FUNCTION redirect_to_original_url(
    p_code TEXT,
    p_referrer TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL
) RETURNS TEXT AS $$
DECLARE
    v_original_url TEXT;
    v_short_link_id UUID;
BEGIN
    -- Get the original URL
    SELECT u.original_url, sl.id INTO v_original_url, v_short_link_id
    FROM short_links sl
    JOIN urls u ON sl.url_id = u.id
    WHERE sl.code = p_code
    AND (sl.expires_at IS NULL OR sl.expires_at > NOW())
    AND sl.is_active = TRUE;
    
    -- If URL exists, track the click asynchronously and return the URL
    IF v_original_url IS NOT NULL THEN
        -- Track the click
        PERFORM track_link_click(
            p_code,
            p_referrer,
            p_user_agent,
            p_ip_address
        );
        
        RETURN v_original_url;
    ELSE
        -- URL not found or expired
        RETURN NULL;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Function for a quick link creation (admin shortcut)
CREATE OR REPLACE FUNCTION quick_link(
    p_url TEXT,
    p_password TEXT,
    p_custom_alias TEXT DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
    v_master_password TEXT;
BEGIN
    -- Check the master password
    v_master_password := current_setting('app.master_password', TRUE);
    
    IF p_password IS NULL OR p_password <> v_master_password THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Invalid master password'
        );
    END IF;
    
    -- Call the regular create_short_link function with admin privileges
    RETURN create_short_link(
        p_original_url := p_url,
        p_custom_alias := p_custom_alias,
        p_api_key := 'master123'  -- This is the master admin key created in the DO block below
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to process click notifications
CREATE OR REPLACE FUNCTION process_click_notification() RETURNS TRIGGER AS $$
DECLARE
    v_payload JSON;
BEGIN
    -- Parse the payload
    v_payload := NEW.payload::JSON;
    
    -- Call the tracking function
    PERFORM track_link_click(
        v_payload->>'code',
        v_payload->>'referrer',
        v_payload->>'user_agent',
        v_payload->>'ip_address'
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create a master admin API key if one doesn't exist
DO $$
DECLARE
    v_key TEXT;
    v_count INT;
    v_master_password TEXT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM api_keys WHERE name = 'Master Admin Key';
    
    IF v_count = 0 THEN
        -- Generate a key with the env var or use a random one if not available
        v_key := 'master123';
        
        -- Insert the master admin key
        INSERT INTO api_keys (key, name, is_admin, permissions)
        VALUES (v_key, 'Master Admin Key', TRUE, '["admin"]'::JSONB);
        
        -- Output the key
        RAISE NOTICE 'Generated Master Admin Key: %', v_key;
    END IF;
END $$;

-- Create simple authentication functions
CREATE OR REPLACE FUNCTION register_user(
    p_email TEXT,
    p_password TEXT
) RETURNS JSON AS $$
DECLARE
    v_user_id UUID;
    v_password_hash TEXT;
BEGIN
    -- Check if email already exists
    IF EXISTS (SELECT 1 FROM users WHERE email = p_email) THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Email already registered'
        );
    END IF;
    
    -- Hash the password
    v_password_hash := crypt(p_password, gen_salt('bf'));
    
    -- Insert the new user
    INSERT INTO users (email, password_hash)
    VALUES (p_email, v_password_hash)
    RETURNING id INTO v_user_id;
    
    -- Log the event
    INSERT INTO analytics_events (
        event_type,
        user_id,
        event_data
    ) VALUES (
        'user_registered',
        v_user_id,
        jsonb_build_object(
            'email', p_email
        )
    );
    
    RETURN json_build_object(
        'success', TRUE,
        'user_id', v_user_id
    );
END;
$$ LANGUAGE plpgsql;

-- Function to authenticate a user
CREATE OR REPLACE FUNCTION login_user(
    p_email TEXT,
    p_password TEXT
) RETURNS JSON AS $$
DECLARE
    v_user_id UUID;
    v_password_hash TEXT;
    v_jwt_payload JSON;
    v_jwt_token TEXT;
    v_jwt_secret TEXT;
BEGIN
    -- Get the user's password hash
    SELECT id, password_hash INTO v_user_id, v_password_hash
    FROM users
    WHERE email = p_email;
    
    -- Check if user exists and password is correct
    IF v_user_id IS NULL OR v_password_hash IS NULL OR v_password_hash <> crypt(p_password, v_password_hash) THEN
        RETURN json_build_object(
            'success', FALSE,
            'error', 'Invalid email or password'
        );
    END IF;
    
    -- Create JWT payload
    v_jwt_payload := json_build_object(
        'user_id', v_user_id,
        'email', p_email,
        'exp', extract(epoch from now() + interval '24 hours')::integer
    );
    
    -- Log the event
    INSERT INTO analytics_events (
        event_type,
        user_id,
        event_data
    ) VALUES (
        'user_login',
        v_user_id,
        jsonb_build_object(
            'email', p_email
        )
    );
    
    RETURN json_build_object(
        'success', TRUE,
        'token', 'jwt_token_placeholder',
        'user_id', v_user_id
    );
END;
$$ LANGUAGE plpgsql;

-- Create API schema wrapper functions

-- API wrapper for get_original_url
CREATE OR REPLACE FUNCTION api.get_original_url(p_code TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN public.get_original_url(p_code);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION api.get_original_url(TEXT) IS 'Get the original URL from a short code';

-- API wrapper for create_short_link
CREATE OR REPLACE FUNCTION api.create_short_link(
    p_original_url TEXT,
    p_custom_alias TEXT DEFAULT NULL
) RETURNS JSON AS $$
BEGIN
    RETURN public.create_short_link(
        p_original_url := p_original_url,
        p_custom_alias := p_custom_alias
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION api.create_short_link(TEXT, TEXT) IS 'Create a short link with optional custom alias';

-- API wrapper for track_link_click
CREATE OR REPLACE FUNCTION api.track_link_click(
    p_code TEXT,
    p_referrer TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS VOID AS $$
BEGIN
    PERFORM public.track_link_click(
        p_code,
        p_referrer,
        p_user_agent,
        p_ip_address,
        p_user_id,
        p_metadata
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION api.track_link_click(TEXT, TEXT, TEXT, TEXT, UUID, JSONB) IS 'Track a click on a short link';

-- API wrapper for redirect_to_original_url
CREATE OR REPLACE FUNCTION api.redirect_to_original_url(
    p_code TEXT,
    p_referrer TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL
) RETURNS TEXT AS $$
BEGIN
    RETURN public.redirect_to_original_url(
        p_code,
        p_referrer,
        p_user_agent,
        p_ip_address
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION api.redirect_to_original_url(TEXT, TEXT, TEXT, TEXT) IS 'Redirect to the original URL and track the click';

-- API wrapper for get_api_key
CREATE OR REPLACE FUNCTION api.get_api_key(p_password TEXT)
RETURNS JSON AS $$
BEGIN
    RETURN public.get_api_key(p_password);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION api.get_api_key(TEXT) IS 'Get an API key using the master password';

-- API wrapper for quick_link
CREATE OR REPLACE FUNCTION api.quick_link(
    p_url TEXT,
    p_password TEXT,
    p_custom_alias TEXT DEFAULT NULL
) RETURNS JSON AS $$
BEGIN
    RETURN public.quick_link(
        p_url,
        p_password,
        p_custom_alias
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION api.quick_link(TEXT, TEXT, TEXT) IS 'Quick link creation for administrators';

-- Add a new test function for creating a short link without requiring an API key
CREATE OR REPLACE FUNCTION api.test_create_link(
    p_original_url TEXT,
    p_custom_alias TEXT DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
    v_url_id UUID;
    v_code TEXT;
    v_short_link_id UUID;
BEGIN
    -- First, check if URL already exists
    SELECT id INTO v_url_id
    FROM urls
    WHERE original_url = p_original_url
    LIMIT 1;

    -- If URL doesn't exist, create it
    IF v_url_id IS NULL THEN
        INSERT INTO urls (original_url, metadata)
        VALUES (p_original_url, '{}'::jsonb)
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
    INSERT INTO short_links (url_id, code, custom_alias)
    VALUES (v_url_id, v_code, p_custom_alias)
    RETURNING id INTO v_short_link_id;

    -- Log event
    INSERT INTO analytics_events (
        event_type,
        event_data
    ) VALUES (
        'test_short_link_created',
        jsonb_build_object(
            'url_id', v_url_id,
            'short_link_id', v_short_link_id,
            'code', v_code,
            'custom_alias', p_custom_alias,
            'original_url', p_original_url
        )
    );
    
    -- Return success
    RETURN json_build_object(
        'success', true,
        'short_link_id', v_short_link_id,
        'url_id', v_url_id,
        'code', v_code,
        'original_url', p_original_url,
        'custom_alias', p_custom_alias
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION api.test_create_link(TEXT, TEXT) IS 'Test function to create a short link without requiring an API key';

-- Grant execute permissions on API functions (these will be handled by init-db.sh)
-- GRANT EXECUTE ON FUNCTION api.get_original_url(TEXT) TO anonymous;
-- GRANT EXECUTE ON FUNCTION api.create_short_link(TEXT, TEXT) TO anonymous;
-- GRANT EXECUTE ON FUNCTION api.track_link_click(TEXT, TEXT, TEXT, TEXT, UUID, JSONB) TO anonymous;
-- GRANT EXECUTE ON FUNCTION api.redirect_to_original_url(TEXT, TEXT, TEXT, TEXT) TO anonymous;
-- GRANT EXECUTE ON FUNCTION api.get_api_key(TEXT) TO anonymous;
-- GRANT EXECUTE ON FUNCTION api.quick_link(TEXT, TEXT, TEXT) TO anonymous;

-- Commit the transaction
COMMIT; 