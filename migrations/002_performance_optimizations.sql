-- URL Shortener Performance Optimizations
-- This migration file adds indexes and query optimizations for better performance

BEGIN;

-- Add combined index for short_links to optimize lookup by code, activity and expiration
CREATE INDEX IF NOT EXISTS idx_short_links_lookup ON short_links(code, is_active, expires_at);

-- Create index on URLs table for original_url lookups
CREATE INDEX IF NOT EXISTS idx_urls_original_url ON urls(original_url);

-- Add partial index for non-expired short links (most common query)
CREATE INDEX IF NOT EXISTS idx_active_unexpired_links ON short_links(code)
WHERE is_active = TRUE AND (expires_at IS NULL OR expires_at > now());

-- Create index for better performance when querying recent clicks
CREATE INDEX IF NOT EXISTS idx_link_clicks_recent ON link_clicks(short_link_id, created_at DESC);

-- Add index for metadata filtering on urls table
CREATE INDEX IF NOT EXISTS idx_urls_metadata ON urls USING GIN (metadata);

-- Optimize get_original_url function for better performance
CREATE OR REPLACE FUNCTION get_original_url(
    p_code TEXT
) RETURNS TEXT AS $$
DECLARE
    v_original_url TEXT;
BEGIN
    -- Optimized query using one join and WHERE conditions directly in the query
    -- This avoids multiple unnecessary checks in PL/pgSQL code
    SELECT u.original_url 
    INTO v_original_url
    FROM short_links sl
    JOIN urls u ON sl.url_id = u.id
    WHERE sl.code = p_code
      AND sl.is_active = TRUE
      AND (sl.expires_at IS NULL OR sl.expires_at > now());
    
    RETURN v_original_url;
END;
$$ LANGUAGE plpgsql;

-- Optimize track_link_click function to be more efficient
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
    -- Simplified query to just get what we need
    SELECT id INTO v_short_link_id
    FROM short_links
    WHERE code = p_code;
    
    -- Check if short link exists
    IF v_short_link_id IS NULL THEN
        RETURN;
    END IF;
    
    -- Record click - we don't need to return the ID
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
    
    -- No need to return value
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- Update comments to maintain API documentation
COMMENT ON FUNCTION get_original_url(TEXT) IS 
  'Gets the original URL for a given short code.';

COMMENT ON FUNCTION track_link_click(TEXT, TEXT, TEXT, TEXT, UUID, JSONB) IS 
  'Records a click on a short link.';

COMMIT; 