-- Simple Authentication for Coolify Deployment
BEGIN;

-- Table to store the master password (hashed, never plaintext)
CREATE TABLE IF NOT EXISTS master_password (
    id SERIAL PRIMARY KEY,
    password_hash TEXT NOT NULL, -- Store hash, not plaintext
    salt TEXT NOT NULL,          -- Each password has its own salt
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Function to hash passwords with salt
CREATE OR REPLACE FUNCTION hash_password(p_password TEXT, p_salt TEXT DEFAULT NULL)
RETURNS TABLE(hash TEXT, salt TEXT) AS $$
DECLARE
    v_salt TEXT;
BEGIN
    -- Generate a salt if not provided
    IF p_salt IS NULL THEN
        v_salt := encode(gen_random_bytes(16), 'hex');
    ELSE
        v_salt := p_salt;
    END IF;
    
    -- Return the hash and salt
    RETURN QUERY SELECT
        encode(digest(p_password || v_salt, 'sha256'), 'hex') as hash,
        v_salt;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Insert initial password only if table is empty - but password must be set via environment or explicit call
-- DO NOT create a default password, this is a security risk
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM master_password) THEN
        -- Log a notice that the password needs to be set
        RAISE NOTICE 'No master password set. Please set one using the set_master_password function.';
    END IF;
END $$;

-- Function to set the master password initially or reset it (admin only)
CREATE OR REPLACE FUNCTION set_master_password(p_password TEXT, p_admin_api_key TEXT)
RETURNS JSON AS $$
DECLARE
    v_hash_result RECORD;
BEGIN
    -- Check if the API key is valid and has admin privileges
    IF NOT EXISTS (SELECT 1 FROM api_keys WHERE key = p_admin_api_key AND is_admin = TRUE AND is_active = TRUE) THEN
        RETURN json_build_object(
            'success', FALSE,
            'message', 'Unauthorized: valid admin API key required'
        );
    END IF;
    
    -- Check if password is strong enough (minimum 8 characters)
    IF LENGTH(p_password) < 8 THEN
        RETURN json_build_object(
            'success', FALSE,
            'message', 'Password must be at least 8 characters long'
        );
    END IF;
    
    -- Hash the password
    SELECT * INTO v_hash_result FROM hash_password(p_password);
    
    -- Delete any existing passwords and insert the new one
    DELETE FROM master_password;
    INSERT INTO master_password (password_hash, salt)
    VALUES (v_hash_result.hash, v_hash_result.salt);
    
    RETURN json_build_object(
        'success', TRUE,
        'message', 'Master password set successfully'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION set_master_password(TEXT, TEXT) IS 'Set or reset the master password (admin only)';

-- Simple authentication function that checks the master password
CREATE OR REPLACE FUNCTION authenticate(p_password TEXT)
RETURNS JSON AS $$
DECLARE
    v_api_key TEXT;
    v_hash TEXT;
    v_salt TEXT;
    v_password_record RECORD;
BEGIN
    -- Get the stored password hash and salt
    SELECT password_hash, salt INTO v_password_record 
    FROM master_password 
    LIMIT 1;
    
    -- If no password has been set, return error
    IF v_password_record IS NULL THEN
        RETURN json_build_object(
            'success', FALSE,
            'message', 'No master password has been set. Please set one using the set_master_password function.'
        );
    END IF;
    
    -- Hash the provided password with the stored salt
    SELECT hash INTO v_hash FROM hash_password(p_password, v_password_record.salt);
    
    -- Check if password hash matches
    IF v_hash = v_password_record.password_hash THEN
        -- Get the master admin API key
        SELECT key INTO v_api_key FROM api_keys WHERE name = 'Master Admin Key' AND is_admin = TRUE;
        
        -- Return success with the API key
        RETURN json_build_object(
            'success', TRUE,
            'api_key', v_api_key,
            'message', 'Authentication successful'
        );
    ELSE
        -- Return failure
        RETURN json_build_object(
            'success', FALSE,
            'message', 'Invalid password'
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION authenticate(TEXT) IS 'Simple password authentication to get API key';

-- Function to change the master password (requires current password)
CREATE OR REPLACE FUNCTION change_master_password(p_current_password TEXT, p_new_password TEXT)
RETURNS JSON AS $$
DECLARE
    v_auth_result JSON;
    v_hash_result RECORD;
BEGIN
    -- Authenticate first
    v_auth_result := authenticate(p_current_password);
    
    -- Check if authentication was successful
    IF NOT (v_auth_result->>'success')::BOOLEAN THEN
        RETURN v_auth_result;
    END IF;
    
    -- Check if new password is strong enough (minimum 8 characters)
    IF LENGTH(p_new_password) < 8 THEN
        RETURN json_build_object(
            'success', FALSE,
            'message', 'New password must be at least 8 characters long'
        );
    END IF;
    
    -- Hash the new password
    SELECT * INTO v_hash_result FROM hash_password(p_new_password);
    
    -- Update the password
    UPDATE master_password
    SET password_hash = v_hash_result.hash,
        salt = v_hash_result.salt,
        updated_at = NOW();
    
    RETURN json_build_object(
        'success', TRUE,
        'message', 'Password changed successfully'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION change_master_password(TEXT, TEXT) IS 'Change the master password';

-- Create a simplified function to create short links with just password
CREATE OR REPLACE FUNCTION simple_create_link(
    p_password TEXT,
    p_url TEXT,
    p_custom_code TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
    v_auth_result JSON;
    v_api_key TEXT;
    v_result JSON;
BEGIN
    -- Authenticate first
    v_auth_result := authenticate(p_password);
    
    -- Check if authentication was successful
    IF NOT (v_auth_result->>'success')::BOOLEAN THEN
        RETURN v_auth_result;
    END IF;
    
    -- Get the API key from authentication result
    v_api_key := v_auth_result->>'api_key';
    
    -- Call the regular create_short_link function with API key
    v_result := create_short_link(
        p_url,  -- Original URL
        p_custom_code,  -- Custom code (optional)
        NULL,   -- User ID
        NULL,   -- Expires at
        '{}',   -- Metadata
        v_api_key  -- API key
    );
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION simple_create_link(TEXT, TEXT, TEXT) IS 'Simple function to create short links with just password and URL';

COMMIT; 