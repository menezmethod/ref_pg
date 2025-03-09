-- Environment-based Master Password Setup
BEGIN;

-- Function to set the master password from environment variable
CREATE OR REPLACE FUNCTION set_password_from_env()
RETURNS VOID AS $$
DECLARE
    v_password TEXT;
    v_hash_result RECORD;
BEGIN
    -- Try to get the master password from environment variable
    BEGIN
        v_password := current_setting('app.master_password', TRUE);
    EXCEPTION WHEN OTHERS THEN
        v_password := NULL;
    END;
    
    -- If no password in environment, set a default for development only
    IF v_password IS NULL OR v_password = '' THEN
        -- Generate a random password instead of hardcoding one
        v_password := encode(gen_random_bytes(12), 'hex');
        RAISE WARNING 'SECURITY RISK: Using randomly generated password for development only. Set MASTER_PASSWORD environment variable in production!';
    END IF;
    
    -- Hash the password
    SELECT * INTO v_hash_result FROM hash_password(v_password);
    
    -- Delete any existing passwords and insert the new one
    DELETE FROM master_password;
    INSERT INTO master_password (password_hash, salt)
    VALUES (v_hash_result.hash, v_hash_result.salt);
    
    RAISE NOTICE 'Master password set from environment variable';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create a function to get the API key with just a password
CREATE OR REPLACE FUNCTION get_api_key(p_password TEXT)
RETURNS JSON AS $$
DECLARE
    v_api_key TEXT;
    v_auth_result JSON;
BEGIN
    -- Authenticate
    v_auth_result := authenticate(p_password);
    
    -- Check if authentication was successful
    IF NOT (v_auth_result->>'success')::BOOLEAN THEN
        RETURN v_auth_result;
    END IF;
    
    -- Return just the API key
    RETURN json_build_object(
        'success', TRUE,
        'api_key', v_auth_result->>'api_key'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION get_api_key(TEXT) IS 'Get API key with just a password';

-- Create a super simple function to create short links with just URL and password
CREATE OR REPLACE FUNCTION quick_link(
    p_url TEXT,
    p_password TEXT,
    p_code TEXT DEFAULT NULL
)
RETURNS TEXT AS $$
DECLARE
    v_result JSON;
    v_code TEXT;
BEGIN
    -- Call the simple_create_link function
    v_result := simple_create_link(p_password, p_url, p_code);
    
    -- Check if successful
    IF NOT (v_result->>'success')::BOOLEAN THEN
        RETURN v_result->>'error';
    END IF;
    
    -- Return just the code
    v_code := v_result->>'code';
    RETURN v_code;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION quick_link(TEXT, TEXT, TEXT) IS 'Super simple function that returns just the short code';

-- Run the function to set the password from environment
SELECT set_password_from_env();

COMMIT; 