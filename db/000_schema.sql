-- Runs once, on an empty data volume (docker-entrypoint-initdb.d).
--
-- Security model
--   * PostgREST exposes only the "api" schema. Tables live in "public".
--   * Every request runs as role anon. public.authenticate() (PostgREST
--     pre-request) turns the X-API-Key header into app.tenant_id / app.key_id /
--     app.is_admin for the current transaction.
--   * Row-level security on links and clicks scopes every read and write to
--     app.tenant_id. Functions that act for the caller are SECURITY INVOKER,
--     so RLS applies to them too.
--   * api.internal_* functions are SECURITY DEFINER (cross-tenant) and only
--     OpenResty calls them: nginx returns 404 for /api/rpc/internal_*.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

-- New functions are not executable by PUBLIC unless granted below.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticator LOGIN NOINHERIT;  -- password set by 001_authenticator.sh
GRANT anon TO authenticator;

CREATE SCHEMA api;
GRANT USAGE ON SCHEMA api TO anon;

-- Request context ---------------------------------------------------------------

CREATE FUNCTION current_tenant() RETURNS bigint LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('app.tenant_id', true), '')::bigint $$;

CREATE FUNCTION current_key() RETURNS bigint LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('app.key_id', true), '')::bigint $$;

-- Tables ------------------------------------------------------------------------

CREATE TABLE tenants (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Only the SHA-256 of a key is stored. The plaintext is shown once, at creation.
CREATE TABLE api_keys (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name         text NOT NULL,
    key_hash     bytea NOT NULL UNIQUE,
    is_admin     boolean NOT NULL DEFAULT false,
    is_active    boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz
);

-- Codes are one global namespace (they share /r/), so uniqueness is global even
-- though each tenant sees only its own rows.
CREATE TABLE links (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL DEFAULT current_tenant() REFERENCES tenants(id) ON DELETE CASCADE,
    code       text NOT NULL UNIQUE
               CONSTRAINT code_must_be_3_to_32_letters_or_digits CHECK (code ~ '^[A-Za-z0-9]{3,32}$'),
    url        text NOT NULL
               CONSTRAINT url_must_be_http_or_https CHECK (url ~* '^https?://[^\s]+$' AND length(url) <= 2048),
    api_key_id bigint DEFAULT current_key() REFERENCES api_keys(id) ON DELETE SET NULL,
    is_active  boolean NOT NULL DEFAULT true,  -- set false with psql to take down an abusive link
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX links_tenant_id ON links (tenant_id);

-- ip holds a truncated network (/24 for IPv4, /48 for IPv6), never a full address.
CREATE TABLE clicks (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    link_id    bigint NOT NULL REFERENCES links(id) ON DELETE CASCADE,
    clicked_at timestamptz NOT NULL DEFAULT now(),
    referrer   text,
    user_agent text,
    ip         inet
);
CREATE INDEX clicks_link_id_clicked_at ON clicks (link_id, clicked_at);
CREATE INDEX clicks_tenant_id ON clicks (tenant_id);

ALTER TABLE links  ENABLE ROW LEVEL SECURITY;
ALTER TABLE clicks ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON links
    USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
CREATE POLICY tenant_isolation ON clicks
    USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());

-- Internal helpers (not in "api") -------------------------------------------------

-- Create a key and return its plaintext. The tenant is created if it is new.
-- Bootstrap: SELECT issue_api_key('acme', 'admin', true);
CREATE FUNCTION issue_api_key(p_tenant text, p_name text, p_is_admin boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_key       text := encode(gen_random_bytes(24), 'hex');
    v_tenant_id bigint;
BEGIN
    INSERT INTO tenants (name) VALUES (p_tenant) ON CONFLICT (name) DO NOTHING;
    SELECT id INTO v_tenant_id FROM tenants WHERE name = p_tenant;
    INSERT INTO api_keys (tenant_id, name, key_hash, is_admin)
    VALUES (v_tenant_id, p_name, digest(v_key, 'sha256'), p_is_admin);
    RETURN v_key;
END $$;

-- 203.0.113.77 -> 203.0.113.0/24, 2001:db8:1:2::5 -> 2001:db8:1::/48, junk -> NULL.
CREATE FUNCTION anonymize_ip(p_ip text) RETURNS inet LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN network(set_masklen(p_ip::inet, CASE family(p_ip::inet) WHEN 4 THEN 24 ELSE 48 END))::inet;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- PostgREST pre-request: runs before every API call, as anon.
CREATE FUNCTION authenticate() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_key text := nullif(current_setting('request.headers', true), '')::json ->> 'x-api-key';
    k     api_keys;
BEGIN
    IF v_key IS NULL THEN
        RETURN;  -- anonymous: RLS shows nothing, functions that need a key raise 401
    END IF;

    SELECT * INTO k FROM api_keys WHERE key_hash = digest(v_key, 'sha256') AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid API key' USING ERRCODE = 'PT401';
    END IF;

    PERFORM set_config('app.tenant_id', k.tenant_id::text, true),
            set_config('app.key_id', k.id::text, true),
            set_config('app.is_admin', k.is_admin::text, true);

    -- PostgREST runs GET requests in a read-only transaction.
    IF current_setting('transaction_read_only') = 'off' THEN
        UPDATE api_keys SET last_used_at = now() WHERE id = k.id;
    END IF;
END $$;

-- HTTP API ---------------------------------------------------------------------
-- Errors map to HTTP: PT401 -> 401, PT403 -> 403, check_violation -> 400,
-- unique_violation -> 409.

-- SECURITY INVOKER: the insert goes through RLS as the caller's tenant.
CREATE FUNCTION api.create_short_link(p_original_url text, p_custom_alias text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    v_code text;
BEGIN
    IF current_tenant() IS NULL THEN
        RAISE EXCEPTION 'A valid API key required' USING ERRCODE = 'PT401';
    END IF;

    IF p_custom_alias IS NOT NULL THEN
        INSERT INTO links (code, url) VALUES (p_custom_alias, p_original_url) RETURNING code INTO v_code;
    ELSE
        LOOP
            BEGIN
                INSERT INTO links (code, url)
                VALUES (left(translate(encode(gen_random_bytes(12), 'base64'), '+/', ''), 7), p_original_url)
                RETURNING code INTO v_code;
                EXIT;
            EXCEPTION WHEN unique_violation THEN
                -- generated code collided with an existing one; try another
            END;
        END LOOP;
    END IF;

    RETURN json_build_object('code', v_code, 'original_url', p_original_url);
END $$;

CREATE FUNCTION api.create_api_key(p_name text, p_is_admin boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF current_setting('app.is_admin', true) IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'An admin API key required' USING ERRCODE = 'PT403';
    END IF;
    RETURN issue_api_key((SELECT name FROM tenants WHERE id = current_tenant()), p_name, p_is_admin);
END $$;

CREATE FUNCTION api.revoke_api_key(p_key text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF current_setting('app.is_admin', true) IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'An admin API key required' USING ERRCODE = 'PT403';
    END IF;
    UPDATE api_keys SET is_active = false
    WHERE key_hash = digest(p_key, 'sha256') AND tenant_id = current_tenant();
    RETURN FOUND;
END $$;

-- Read-only views. security_invoker makes RLS apply, so each tenant sees only
-- its own rows. PostgREST serves them with filtering and ordering, e.g.
-- GET /api/link_stats?order=clicks.desc&limit=10
CREATE VIEW api.link_stats WITH (security_invoker = true) AS
SELECT l.code,
       l.url,
       l.is_active,
       l.created_at,
       count(c.id)                                                          AS clicks,
       count(c.id) FILTER (WHERE c.clicked_at > now() - interval '24 hours') AS clicks_24h,
       max(c.clicked_at)                                                    AS last_click_at
FROM links l
LEFT JOIN clicks c ON c.link_id = l.id
GROUP BY l.id;

CREATE VIEW api.top_referrers WITH (security_invoker = true) AS
SELECT l.code,
       coalesce(c.referrer, '(direct)') AS referrer,
       count(*)                         AS clicks
FROM clicks c
JOIN links l ON l.id = c.link_id
GROUP BY l.code, 2;

-- Internal API (OpenResty only; nginx blocks /api/rpc/internal_*) -----------------

CREATE FUNCTION api.internal_lookup_link(p_code text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT url FROM links WHERE code = p_code AND is_active $$;

-- p_clicks: [{"code", "ts" (unix seconds), "referrer", "user_agent", "ip"}, ...]
CREATE FUNCTION api.internal_record_clicks(p_clicks json)
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    WITH inserted AS (
        INSERT INTO clicks (tenant_id, link_id, clicked_at, referrer, user_agent, ip)
        SELECT l.tenant_id, l.id, to_timestamp(x.ts), left(x.referrer, 2048), left(x.user_agent, 512), anonymize_ip(x.ip)
        FROM json_to_recordset(p_clicks) AS x(code text, ts double precision, referrer text, user_agent text, ip text)
        JOIN links l ON l.code = x.code
        RETURNING 1
    )
    SELECT count(*)::integer FROM inserted
$$;

-- Grants ------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION current_tenant(), current_key(), authenticate() TO anon;
GRANT EXECUTE ON FUNCTION
    api.create_short_link(text, text),
    api.create_api_key(text, boolean),
    api.revoke_api_key(text),
    api.internal_lookup_link(text),
    api.internal_record_clicks(json)
TO anon;
GRANT SELECT, INSERT ON links TO anon;  -- RLS limits both to the caller's tenant
GRANT SELECT ON clicks TO anon;
GRANT SELECT ON api.link_stats, api.top_referrers TO anon;

COMMIT;
