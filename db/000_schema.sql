-- Runs once, on an empty data volume (docker-entrypoint-initdb.d).
-- Tables live in "public" and are not exposed. PostgREST exposes only the
-- "api" schema, and anon can execute only the functions granted at the end.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

-- New functions are not executable by PUBLIC unless granted below.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticator LOGIN NOINHERIT;  -- password set by 001_authenticator.sh
GRANT anon TO authenticator;

CREATE SCHEMA api;
GRANT USAGE ON SCHEMA api TO anon;

-- Only the SHA-256 of a key is stored. The plaintext is shown once, at creation.
CREATE TABLE api_keys (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         text NOT NULL,
    key_hash     bytea NOT NULL UNIQUE,
    is_admin     boolean NOT NULL DEFAULT false,
    is_active    boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz
);

CREATE TABLE links (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code       text NOT NULL UNIQUE
               CONSTRAINT code_must_be_3_to_32_letters_or_digits CHECK (code ~ '^[A-Za-z0-9]{3,32}$'),
    url        text NOT NULL
               CONSTRAINT url_must_be_http_or_https CHECK (url ~* '^https?://[^\s]+$' AND length(url) <= 2048),
    api_key_id bigint REFERENCES api_keys(id) ON DELETE SET NULL,
    is_active  boolean NOT NULL DEFAULT true,  -- set false with psql to take down an abusive link
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE clicks (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    link_id    bigint NOT NULL REFERENCES links(id) ON DELETE CASCADE,
    clicked_at timestamptz NOT NULL DEFAULT now(),
    referrer   text,
    user_agent text,
    ip         text
);
CREATE INDEX clicks_link_id_clicked_at ON clicks (link_id, clicked_at);

-- Internal helpers (not in "api", not executable by anon) ---------------------

-- Create a key and return its plaintext. Bootstrap the first admin key with:
--   SELECT issue_api_key('admin', true);
CREATE FUNCTION issue_api_key(p_name text, p_is_admin boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_key text := encode(gen_random_bytes(24), 'hex');
BEGIN
    INSERT INTO api_keys (name, key_hash, is_admin)
    VALUES (p_name, digest(v_key, 'sha256'), p_is_admin);
    RETURN v_key;
END $$;

-- Return the id of the caller's X-API-Key, or raise HTTP 401 through PostgREST.
CREATE FUNCTION require_api_key(p_admin boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_key text := nullif(current_setting('request.headers', true), '')::json ->> 'x-api-key';
    v_id  bigint;
BEGIN
    UPDATE api_keys SET last_used_at = now()
    WHERE key_hash = digest(coalesce(v_key, ''), 'sha256')
      AND is_active
      AND (is_admin OR NOT p_admin)
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
        RAISE EXCEPTION '% API key required', CASE WHEN p_admin THEN 'An admin' ELSE 'A valid' END
            USING ERRCODE = 'PT401';
    END IF;
    RETURN v_id;
END $$;

-- HTTP API (POST /api/rpc/<name>) ---------------------------------------------
-- SECURITY DEFINER: anon has no table privileges, so these run as the owner.
-- search_path is pinned so a caller cannot shadow tables or pgcrypto.
-- Errors map to HTTP: PT401 -> 401, check_violation -> 400, unique_violation -> 409.

CREATE FUNCTION api.create_short_link(p_original_url text, p_custom_alias text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_key_id bigint := require_api_key();
    v_code   text;
BEGIN
    IF p_custom_alias IS NOT NULL THEN
        INSERT INTO links (code, url, api_key_id) VALUES (p_custom_alias, p_original_url, v_key_id)
        RETURNING code INTO v_code;
    ELSE
        LOOP
            BEGIN
                INSERT INTO links (code, url, api_key_id)
                VALUES (left(translate(encode(gen_random_bytes(12), 'base64'), '+/', ''), 7), p_original_url, v_key_id)
                RETURNING code INTO v_code;
                EXIT;
            EXCEPTION WHEN unique_violation THEN
                -- generated code collided with an existing one; try another
            END;
        END LOOP;
    END IF;

    RETURN json_build_object('code', v_code, 'original_url', p_original_url);
END $$;

-- Called by OpenResty for GET /r/{code}. Records a click and returns the URL,
-- or NULL when the code is unknown or inactive. nginx blocks direct calls.
CREATE FUNCTION api.resolve_link(
    p_code       text,
    p_referrer   text DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_ip         text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id  bigint;
    v_url text;
BEGIN
    SELECT id, url INTO v_id, v_url FROM links WHERE code = p_code AND is_active;
    IF v_id IS NOT NULL THEN
        INSERT INTO clicks (link_id, referrer, user_agent, ip)
        VALUES (v_id, left(p_referrer, 2048), left(p_user_agent, 512), left(p_ip, 64));
    END IF;
    RETURN v_url;
END $$;

CREATE FUNCTION api.create_api_key(p_name text, p_is_admin boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM require_api_key(p_admin := true);
    RETURN issue_api_key(p_name, p_is_admin);
END $$;

CREATE FUNCTION api.revoke_api_key(p_key text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM require_api_key(p_admin := true);
    UPDATE api_keys SET is_active = false WHERE key_hash = digest(p_key, 'sha256');
    RETURN FOUND;
END $$;

GRANT EXECUTE ON FUNCTION
    api.create_short_link(text, text),
    api.resolve_link(text, text, text, text),
    api.create_api_key(text, boolean),
    api.revoke_api_key(text)
TO anon;

COMMIT;
