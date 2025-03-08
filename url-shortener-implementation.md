# PostgreSQL URL Shortener Implementation

This document outlines the implementation plan for converting our PostgreSQL-based referral service into a Bitly-like URL shortener service. We'll leverage our existing infrastructure while adapting the data model and API endpoints to support URL shortening functionality.

## Overview

We'll transform our current referral system into a URL shortener service that:

1. Generates short links for any URL
2. Tracks clicks and provides statistics
3. Supports custom aliases (vanity URLs)
4. Maintains all the performance benefits of our PostgreSQL-first architecture
5. Utilizes Redis for caching and Prometheus for monitoring

## 1. Database Schema Modifications

### New Migration File: `006_url_shortener.sql`

```sql
-- Initiate the transaction
BEGIN;

-- Create URLs table to store original URLs
CREATE TABLE urls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    original_url TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Create index for faster lookups
CREATE INDEX idx_urls_created_by ON urls(created_by);
CREATE INDEX idx_urls_created_at ON urls(created_at);

-- Create short_links table
CREATE TABLE short_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    url_id UUID NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
    code TEXT NOT NULL UNIQUE,
    custom_alias TEXT UNIQUE,
    is_active BOOLEAN DEFAULT TRUE,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Add timestamp update trigger
CREATE TRIGGER update_short_links_timestamp
BEFORE UPDATE ON short_links
FOR EACH ROW
EXECUTE FUNCTION update_timestamp();

-- Create indexes for short_links
CREATE INDEX idx_short_links_url_id ON short_links(url_id);
CREATE INDEX idx_short_links_code ON short_links(code);
CREATE INDEX idx_short_links_custom_alias ON short_links(custom_alias);
CREATE INDEX idx_short_links_is_active ON short_links(is_active);

-- Create link_clicks table to track clicks
CREATE TABLE link_clicks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    short_link_id UUID NOT NULL REFERENCES short_links(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    ip_address TEXT,
    user_agent TEXT,
    referrer TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Create indexes for link_clicks
CREATE INDEX idx_link_clicks_short_link_id ON link_clicks(short_link_id);
CREATE INDEX idx_link_clicks_created_at ON link_clicks(created_at);
CREATE INDEX idx_link_clicks_metadata ON link_clicks USING GIN (metadata);

-- Function to generate short code (reuse our existing code generation)
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

-- Function to create a short link
CREATE OR REPLACE FUNCTION create_short_link(
    p_original_url TEXT,
    p_custom_alias TEXT DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_expires_at TIMESTAMPTZ DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSON AS $$
DECLARE
    v_url_id UUID;
    v_code TEXT;
    v_short_link_id UUID;
    v_result JSON;
BEGIN
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
    
    -- Log event (reusing our analytics_events table)
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
$$ LANGUAGE plpgsql;

-- Function to get original URL by code
CREATE OR REPLACE FUNCTION get_original_url(
    p_code TEXT
) RETURNS TEXT AS $$
DECLARE
    v_original_url TEXT;
    v_short_link_id UUID;
    v_is_active BOOLEAN;
    v_expires_at TIMESTAMPTZ;
BEGIN
    -- Get short link details
    SELECT sl.id, sl.is_active, sl.expires_at, u.original_url 
    INTO v_short_link_id, v_is_active, v_expires_at, v_original_url
    FROM short_links sl
    JOIN urls u ON sl.url_id = u.id
    WHERE sl.code = p_code;
    
    -- Check if short link exists
    IF v_original_url IS NULL THEN
        RETURN NULL;
    END IF;
    
    -- Check if short link is active
    IF NOT v_is_active THEN
        RETURN NULL;
    END IF;
    
    -- Check if short link has expired
    IF v_expires_at IS NOT NULL AND v_expires_at < now() THEN
        RETURN NULL;
    END IF;
    
    RETURN v_original_url;
END;
$$ LANGUAGE plpgsql;

-- Function to track link click
CREATE OR REPLACE FUNCTION track_link_click(
    p_code TEXT,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_referrer TEXT DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    v_short_link_id UUID;
    v_url_id UUID;
    v_click_id UUID;
    v_original_url TEXT;
BEGIN
    -- Get short link ID
    SELECT sl.id, sl.url_id, u.original_url
    INTO v_short_link_id, v_url_id, v_original_url
    FROM short_links sl
    JOIN urls u ON sl.url_id = u.id
    WHERE sl.code = p_code;
    
    -- Check if short link exists
    IF v_short_link_id IS NULL THEN
        RETURN NULL;
    END IF;
    
    -- Record click
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
    ) RETURNING id INTO v_click_id;
    
    -- Log analytics event
    INSERT INTO analytics_events (
        event_type,
        user_id,
        event_data
    ) VALUES (
        'link_click',
        p_user_id,
        jsonb_build_object(
            'short_link_id', v_short_link_id,
            'url_id', v_url_id,
            'click_id', v_click_id,
            'code', p_code,
            'original_url', v_original_url
        )
    );
    
    RETURN v_click_id;
END;
$$ LANGUAGE plpgsql;

-- Redis caching integration (similar to our existing implementation)
DO $$
BEGIN
    -- Try to create function for caching short links
    BEGIN
        -- Function to cache short link
        CREATE OR REPLACE FUNCTION cache_short_link(code TEXT, days INTEGER DEFAULT 1) RETURNS void AS $$
        DECLARE
            link_json text;
        BEGIN
            -- Get short link as JSON
            SELECT row_to_json(t)::text INTO link_json
            FROM (
                SELECT sl.code, sl.is_active, sl.expires_at, u.original_url
                FROM short_links sl
                JOIN urls u ON sl.url_id = u.id
                WHERE sl.code = code
            ) t;
            
            -- Cache in Redis with expiration
            INSERT INTO cache.short_link_cache (key, value)
            VALUES (code, link_json)
            ON CONFLICT (key) DO UPDATE SET value = link_json;
            
            -- Set expiration
            PERFORM redis_fdw_expire('short_link:'||code, days * 86400);
        END;
        $$ LANGUAGE plpgsql;
        
        -- Create Redis cache foreign table for short links
        CREATE FOREIGN TABLE IF NOT EXISTS cache.short_link_cache (
            key text,
            value text
        ) SERVER redis_server
            OPTIONS (database '0', tablekeyprefix 'short_link:');
            
        -- Function to get cached short link
        CREATE OR REPLACE FUNCTION get_cached_short_link(code TEXT) RETURNS TEXT AS $$
        DECLARE
            cached_json text;
            original_url text;
        BEGIN
            -- Try to get from cache
            SELECT value INTO cached_json 
            FROM cache.short_link_cache
            WHERE key = code;
            
            IF cached_json IS NOT NULL THEN
                -- Extract original URL from JSON
                SELECT t.original_url INTO original_url
                FROM json_to_record(cached_json::json) AS t(code text, is_active boolean, expires_at timestamptz, original_url text);
                
                -- Check if expired
                IF t.expires_at IS NOT NULL AND t.expires_at < now() THEN
                    RETURN NULL;
                END IF;
                
                -- Check if active
                IF NOT t.is_active THEN
                    RETURN NULL;
                END IF;
                
                RETURN original_url;
            ELSE
                -- Not in cache, get from database
                SELECT get_original_url(code) INTO original_url;
                
                -- Cache the result
                IF original_url IS NOT NULL THEN
                    PERFORM cache_short_link(code);
                END IF;
                
                RETURN original_url;
            END IF;
        END;
        $$ LANGUAGE plpgsql;
        
        -- Grant access to caching functions
        GRANT EXECUTE ON FUNCTION cache_short_link(TEXT, INTEGER) TO postgres;
        GRANT EXECUTE ON FUNCTION get_cached_short_link(TEXT) TO postgres;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Redis caching for short links is not available.';
    END;
END $$;

-- Create views for statistics
CREATE OR REPLACE VIEW link_stats AS
SELECT 
    sl.id AS short_link_id,
    sl.code,
    sl.custom_alias,
    u.id AS url_id,
    u.original_url,
    u.created_by AS owner_id,
    usr.email AS owner_email,
    COUNT(lc.id) AS click_count,
    MIN(lc.created_at) AS first_click,
    MAX(lc.created_at) AS last_click,
    sl.created_at,
    sl.is_active,
    sl.expires_at
FROM 
    short_links sl
LEFT JOIN 
    urls u ON sl.url_id = u.id
LEFT JOIN 
    link_clicks lc ON sl.id = lc.short_link_id
LEFT JOIN
    users usr ON u.created_by = usr.id
GROUP BY 
    sl.id, u.id, usr.id;

-- Create view for daily link statistics
CREATE OR REPLACE VIEW daily_link_stats AS
SELECT 
    lc.short_link_id,
    sl.code,
    sl.custom_alias,
    u.original_url,
    DATE_TRUNC('day', lc.created_at) AS day,
    COUNT(*) AS click_count
FROM 
    link_clicks lc
JOIN 
    short_links sl ON lc.short_link_id = sl.id
JOIN 
    urls u ON sl.url_id = u.id
GROUP BY 
    lc.short_link_id, sl.code, sl.custom_alias, u.original_url, DATE_TRUNC('day', lc.created_at)
ORDER BY 
    DATE_TRUNC('day', lc.created_at) DESC, COUNT(*) DESC;

-- Expose functions via the API
GRANT EXECUTE ON FUNCTION create_short_link(TEXT, TEXT, UUID, TIMESTAMPTZ, JSONB) TO postgres;
GRANT EXECUTE ON FUNCTION get_original_url(TEXT) TO postgres;
GRANT EXECUTE ON FUNCTION track_link_click(TEXT, TEXT, TEXT, TEXT, UUID, JSONB) TO postgres;
GRANT EXECUTE ON FUNCTION get_cached_short_link(TEXT) TO postgres;

-- Grant access to views and tables
GRANT SELECT ON TABLE link_stats TO postgres;
GRANT SELECT ON TABLE daily_link_stats TO postgres;
GRANT SELECT ON TABLE short_links TO postgres;
GRANT SELECT ON TABLE urls TO postgres;
GRANT SELECT ON TABLE link_clicks TO postgres;

-- Add permissions for tables
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE short_links TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE urls TO postgres;
GRANT INSERT, SELECT ON TABLE link_clicks TO postgres;

-- Sample function for redirecting (executed server-side)
CREATE OR REPLACE FUNCTION redirect_to_original_url(
    p_code TEXT,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_referrer TEXT DEFAULT NULL
) RETURNS TEXT AS $$
DECLARE
    v_original_url TEXT;
BEGIN
    -- Try to get from cache first
    BEGIN
        SELECT get_cached_short_link(p_code) INTO v_original_url;
    EXCEPTION WHEN OTHERS THEN
        -- If cache fails, fall back to database
        SELECT get_original_url(p_code) INTO v_original_url;
    END;
    
    -- Track click asynchronously
    IF v_original_url IS NOT NULL THEN
        PERFORM pg_notify('track_click', json_build_object(
            'code', p_code,
            'ip_address', p_ip_address,
            'user_agent', p_user_agent,
            'referrer', p_referrer
        )::text);
    END IF;
    
    RETURN v_original_url;
END;
$$ LANGUAGE plpgsql;

-- Grant execution of redirect function
GRANT EXECUTE ON FUNCTION redirect_to_original_url(TEXT, TEXT, TEXT, TEXT) TO postgres;

-- Create a trigger function to listen for pg_notify events
CREATE OR REPLACE FUNCTION process_click_notification() RETURNS TRIGGER AS $$
DECLARE
BEGIN
    PERFORM pg_listen('track_click');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create a listener trigger
CREATE TRIGGER track_click_listener
AFTER INSERT ON short_links
FOR EACH STATEMENT
EXECUTE FUNCTION process_click_notification();

-- Add some sample data for testing
DO $$
DECLARE
    v_result JSON;
BEGIN
    -- Create some sample short links
    SELECT create_short_link('https://www.example.com', 'example', NULL) INTO v_result;
    SELECT create_short_link('https://www.google.com', NULL, NULL) INTO v_result;
    SELECT create_short_link('https://www.github.com', 'github', NULL) INTO v_result;
END $$;

-- Commit the transaction
COMMIT;
```

## 2. API Endpoints

### Key Endpoints

1. **Create Short Link**
   - Endpoint: `POST /shorten`
   - Function: `create_short_link`
   - Example Request:
     ```json
     {
       "url": "https://example.com/very/long/url/that/needs/shortening",
       "custom_alias": "mylink",
       "expires_at": "2023-12-31T23:59:59Z"
     }
     ```
   - Example Response:
     ```json
     {
       "success": true,
       "short_link_id": "67f8be1c-f70a-45af-a466-afeb89ca88f6",
       "url_id": "123e4567-e89b-12d3-a456-426614174000",
       "code": "mylink",
       "original_url": "https://example.com/very/long/url/that/needs/shortening",
       "short_url": "http://localhost:3001/r/mylink"
     }
     ```

2. **Redirect to Original URL**
   - Endpoint: `GET /r/{code}`
   - Function: `redirect_to_original_url`
   - This will redirect to the original URL and track the click

3. **Get Link Statistics**
   - Endpoint: `GET /stats/{code}`
   - Function: Uses the `link_stats` view
   - Example Response:
     ```json
     {
       "short_link_id": "67f8be1c-f70a-45af-a466-afeb89ca88f6",
       "code": "mylink",
       "custom_alias": "mylink",
       "original_url": "https://example.com/very/long/url/that/needs/shortening",
       "click_count": 42,
       "first_click": "2023-01-01T12:00:00Z",
       "last_click": "2023-03-08T15:30:45Z"
     }
     ```

4. **Get All Links for User**
   - Endpoint: `GET /links`
   - Uses the `link_stats` view filtered by user_id

5. **Get Daily Click Statistics**
   - Endpoint: `GET /stats/{code}/daily`
   - Uses the `daily_link_stats` view

## 3. Docker Configuration Updates

Our current Docker setup can be maintained with minimal changes:

1. **Update the docker-compose.yml file**: No changes needed, as we're using the same services.

2. **PostgreSQL Configuration**: No changes needed.

3. **Redis Configuration**: No changes needed.

4. **PostgREST Configuration**: No changes needed.

5. **Prometheus Configuration**: No changes needed.

## 4. Implementation Steps

1. **Create the new migration**
   - Place the SQL code in `migrations/006_url_shortener.sql`

2. **Update API documentation**
   - Update Swagger UI configuration for new endpoints

3. **Test migrations**
   - Run the migrations and verify the new tables and functions are created correctly

4. **Test URL shortening functionality**
   - Create short URLs and verify they work correctly

5. **Test statistics gathering**
   - Verify click tracking and statistics views work correctly

## 5. Usage Examples

### Creating a Short Link

```bash
curl -X POST "http://localhost:3001/rpc/create_short_link" \
  -H "Content-Type: application/json" \
  -d '{"p_original_url": "https://example.com/very/long/url", "p_custom_alias": "example"}'
```

### Redirecting to Original URL

Simply visit:
```
http://localhost:3001/r/example
```

### Getting Statistics

```bash
curl -s "http://localhost:3001/link_stats?code=eq.example" | jq
```

## 6. Benefits Over Existing Solutions

1. **Simplicity**: Everything runs in PostgreSQL, no need for multiple microservices
2. **Performance**: Redis caching for fast redirects
3. **Comprehensive Analytics**: Built-in tracking and statistics
4. **Scalability**: PostgreSQL can handle millions of shortened URLs
5. **Maintainability**: Single technology stack to maintain
6. **Docker-ready**: Works with our existing Docker setup

## 7. Future Enhancements

1. **QR Code Generation**: Add QR code generation for shortened links
2. **User Dashboard**: Create a simple UI for managing links
3. **Rate Limiting**: Add rate limiting to prevent abuse
4. **Link Expiration**: Automatically disable expired links
5. **Custom Domains**: Allow custom domains for short links 