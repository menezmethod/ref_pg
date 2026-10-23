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
               CONSTRAINT url_must_be_http_or_https CHECK (url ~* '^https?://' AND length(url) <= 2048)
               -- no spaces or control characters: OpenResty refuses to send them in Location (500)
               CONSTRAINT url_must_not_contain_spaces_or_control_characters CHECK (url !~ '[\x01-\x20\x7f-\x9f]'),
    api_key_id bigint DEFAULT current_key() REFERENCES api_keys(id) ON DELETE SET NULL,
    is_active  boolean NOT NULL DEFAULT true,  -- set false with psql to take down an abusive link
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX links_tenant_id ON links (tenant_id);

-- ip holds a truncated network (/24 for IPv4, /48 for IPv6), never a full address.
-- Partitioned by UTC day (clicks_YYYYMMDD), so retention drops whole days
-- instead of deleting rows. See create_click_partitions() and
-- api.internal_maintain_clicks(). The rollups below never read old clicks, so
-- dropping a day changes no statistic.
CREATE TABLE clicks (
    id         bigserial,  -- (identity columns on partitioned tables need Postgres 17)
    tenant_id  bigint NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    link_id    bigint NOT NULL REFERENCES links(id) ON DELETE CASCADE,
    clicked_at timestamptz NOT NULL DEFAULT now(),
    referrer   text,
    user_agent text,
    ip         inet,
    PRIMARY KEY (id, clicked_at)
) PARTITION BY RANGE (clicked_at);
CREATE INDEX clicks_link_id_clicked_at ON clicks (link_id, clicked_at);
CREATE INDEX clicks_tenant_id ON clicks (tenant_id);

-- Creates the missing daily partitions for p_from..p_to (UTC dates) and returns
-- how many it created. Each is built standalone and then attached: ATTACH needs
-- only a SHARE UPDATE EXCLUSIVE lock on clicks, so inserts never wait for it
-- (CREATE TABLE ... PARTITION OF would take ACCESS EXCLUSIVE).
CREATE FUNCTION create_click_partitions(p_from date, p_to date)
RETURNS integer LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
    d       date;
    created integer := 0;
    part    text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('create_click_partitions'));  -- one creator at a time
    FOR d IN SELECT generate_series(p_from, p_to, interval '1 day')::date LOOP
        part := 'clicks_' || to_char(d, 'YYYYMMDD');
        CONTINUE WHEN to_regclass(part) IS NOT NULL;
        EXECUTE format('CREATE TABLE %I (LIKE clicks INCLUDING DEFAULTS)', part);
        EXECUTE format('ALTER TABLE clicks ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
                       part, d::timestamp AT TIME ZONE 'UTC', (d + 1)::timestamp AT TIME ZONE 'UTC');
        created := created + 1;
    END LOOP;
    RETURN created;
END $$;

-- Rollups, kept current by a trigger on clicks, so analytics cost grows with
-- links and days, not with clicks. Raw clicks stay for ad-hoc queries.
CREATE TABLE link_totals (
    link_id       bigint PRIMARY KEY REFERENCES links(id) ON DELETE CASCADE,
    tenant_id     bigint NOT NULL,
    clicks        bigint NOT NULL,
    last_click_at timestamptz NOT NULL
);
CREATE TABLE link_clicks_hourly (
    link_id   bigint NOT NULL REFERENCES links(id) ON DELETE CASCADE,
    tenant_id bigint NOT NULL,
    hour      timestamptz NOT NULL,
    clicks    bigint NOT NULL,
    PRIMARY KEY (link_id, hour)
);
CREATE TABLE link_referrers_daily (
    link_id   bigint NOT NULL REFERENCES links(id) ON DELETE CASCADE,
    tenant_id bigint NOT NULL,
    day       date NOT NULL,
    referrer  text NOT NULL,  -- '(direct)' when the request had none
    clicks    bigint NOT NULL,
    PRIMARY KEY (link_id, day, referrer)
);
CREATE INDEX link_totals_tenant_id ON link_totals (tenant_id);
CREATE INDEX link_referrers_daily_tenant_id ON link_referrers_daily (tenant_id);

-- Batch ids already written by internal_record_clicks, so a retried batch
-- (the first attempt timed out but committed) is not counted twice.
CREATE TABLE click_batches (
    id          text PRIMARY KEY,
    recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX click_batches_recorded_at ON click_batches (recorded_at);

ALTER TABLE links  ENABLE ROW LEVEL SECURITY;
ALTER TABLE clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE link_totals ENABLE ROW LEVEL SECURITY;
ALTER TABLE link_clicks_hourly ENABLE ROW LEVEL SECURITY;
ALTER TABLE link_referrers_daily ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON links
    USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
CREATE POLICY tenant_isolation ON clicks
    USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
CREATE POLICY tenant_isolation ON link_totals USING (tenant_id = current_tenant());
CREATE POLICY tenant_isolation ON link_clicks_hourly USING (tenant_id = current_tenant());
CREATE POLICY tenant_isolation ON link_referrers_daily USING (tenant_id = current_tenant());

-- One statement-level trigger run per INSERT (one per click batch), whatever
-- path inserted the rows. ORDER BY makes every batch lock rollup rows in the
-- same order, so two concurrent flushes cannot deadlock on a hot link.
CREATE FUNCTION roll_up_clicks() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO link_totals (link_id, tenant_id, clicks, last_click_at)
    SELECT link_id, tenant_id, count(*), max(clicked_at) FROM new_clicks
    GROUP BY link_id, tenant_id ORDER BY link_id
    ON CONFLICT (link_id) DO UPDATE
    SET clicks = link_totals.clicks + excluded.clicks,
        last_click_at = greatest(link_totals.last_click_at, excluded.last_click_at);

    INSERT INTO link_clicks_hourly (link_id, tenant_id, hour, clicks)
    SELECT link_id, tenant_id, date_trunc('hour', clicked_at), count(*) FROM new_clicks
    GROUP BY 1, 2, 3 ORDER BY 1, 3
    ON CONFLICT (link_id, hour) DO UPDATE SET clicks = link_clicks_hourly.clicks + excluded.clicks;

    INSERT INTO link_referrers_daily (link_id, tenant_id, day, referrer, clicks)
    SELECT link_id, tenant_id, clicked_at::date, coalesce(referrer, '(direct)'), count(*) FROM new_clicks
    GROUP BY 1, 2, 3, 4 ORDER BY 1, 3, 4
    ON CONFLICT (link_id, day, referrer) DO UPDATE SET clicks = link_referrers_daily.clicks + excluded.clicks;
    RETURN NULL;
END $$;
CREATE TRIGGER roll_up_clicks AFTER INSERT ON clicks
    REFERENCING NEW TABLE AS new_clicks FOR EACH STATEMENT EXECUTE FUNCTION roll_up_clicks();

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
        -- ON CONFLICT instead of an exception block: no subtransaction per call.
        LOOP
            INSERT INTO links (code, url)
            VALUES (left(translate(encode(gen_random_bytes(12), 'base64'), '+/', ''), 7), p_original_url)
            ON CONFLICT (code) DO NOTHING
            RETURNING code INTO v_code;
            EXIT WHEN v_code IS NOT NULL;  -- NULL: the generated code was taken; try another
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
-- Both read rollups, never raw clicks. clicks_24h counts whole hours: the
-- current hour plus the 23 before it.
CREATE VIEW api.link_stats WITH (security_invoker = true) AS
SELECT l.code,
       l.url,
       l.is_active,
       l.created_at,
       coalesce(t.clicks, 0) AS clicks,
       coalesce((SELECT sum(h.clicks) FROM link_clicks_hourly h
                 WHERE h.link_id = l.id AND h.hour >= date_trunc('hour', now()) - interval '23 hours'), 0)::bigint
                             AS clicks_24h,
       t.last_click_at
FROM links l
LEFT JOIN link_totals t ON t.link_id = l.id;

CREATE VIEW api.top_referrers WITH (security_invoker = true) AS
SELECT l.code,
       r.referrer,
       sum(r.clicks)::bigint AS clicks
FROM link_referrers_daily r
JOIN links l ON l.id = r.link_id
GROUP BY l.code, r.referrer;

-- Internal API (OpenResty only; nginx blocks /api/rpc/internal_*) -----------------

CREATE FUNCTION api.internal_lookup_link(p_code text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT url FROM links WHERE code = p_code AND is_active $$;

-- p_batch: unique per batch, reused when a batch is retried.
-- p_clicks: [{"code", "ts" (unix seconds), "referrer", "user_agent", "ip"}, ...]
-- Returns the clicks written: 0 for a batch already recorded. Clicks for codes
-- that no longer exist are skipped.
CREATE FUNCTION api.internal_record_clicks(p_batch text, p_clicks json)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO click_batches (id) VALUES (p_batch) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    FOR attempt IN 1..3 LOOP
        BEGIN
            WITH inserted AS (
                INSERT INTO clicks (tenant_id, link_id, clicked_at, referrer, user_agent, ip)
                SELECT l.tenant_id, l.id, to_timestamp(x.ts), left(x.referrer, 2048), left(x.user_agent, 512),
                       anonymize_ip(x.ip)
                FROM json_to_recordset(p_clicks) AS x(code text, ts double precision, referrer text, user_agent text, ip text)
                JOIN links l ON l.code = x.code
                RETURNING 1
            )
            SELECT count(*) INTO n FROM inserted;
            EXIT;
        EXCEPTION
            WHEN foreign_key_violation THEN
                -- A link was deleted while this batch was being inserted. Retry: the
                -- join now skips it. (Locking the links rows instead cost ~12% of
                -- ingest throughput on every batch to cover this rare race.)
                IF attempt = 3 THEN RAISE; END IF;
            WHEN check_violation THEN
                -- No partition for some click's day: maintenance has not run (it
                -- creates a week ahead). Create the batch's days and retry.
                IF attempt = 3 THEN RAISE; END IF;
                PERFORM create_click_partitions(min(d), max(d))
                FROM (SELECT (to_timestamp(x.ts) AT TIME ZONE 'UTC')::date AS d
                      FROM json_to_recordset(p_clicks) AS x(ts double precision)) days;
        END;
    END LOOP;
    RETURN n;
END $$;

-- Called hourly by OpenResty (and at its start). Creates the partitions for
-- today and the next 7 UTC days, drops partitions older than p_retention_days
-- (0 keeps everything), and prunes rollup and batch-id rows nothing reads.
-- Dropping a partition briefly takes ACCESS EXCLUSIVE on clicks: lock_timeout
-- keeps a busy moment from stalling inserts behind it; the next run retries.
CREATE FUNCTION api.internal_maintain_clicks(p_retention_days integer DEFAULT 90)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    today   date := (now() AT TIME ZONE 'UTC')::date;
    created integer;
    dropped text[] := '{}';
    skipped text[] := '{}';
    part    text;
BEGIN
    IF p_retention_days IS NULL OR p_retention_days < 0 THEN
        RAISE EXCEPTION 'p_retention_days must be 0 (keep everything) or more' USING ERRCODE = '22023';
    END IF;
    created := create_click_partitions(today, today + 7);

    IF p_retention_days > 0 THEN
        FOR part IN
            SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = 'clicks'::regclass AND c.relname ~ '^clicks_[0-9]{8}$'
              AND to_date(substr(c.relname, 8), 'YYYYMMDD') < today - p_retention_days
            ORDER BY c.relname
        LOOP
            BEGIN
                PERFORM set_config('lock_timeout', '2s', true);
                EXECUTE format('DROP TABLE %I', part);
                dropped := dropped || part;
            EXCEPTION WHEN lock_not_available THEN
                skipped := skipped || part;
            END;
        END LOOP;
    END IF;

    DELETE FROM link_clicks_hourly WHERE hour < now() - interval '48 hours';  -- clicks_24h reads 24
    DELETE FROM click_batches WHERE recorded_at < now() - interval '1 hour';  -- retries come within seconds
    RETURN json_build_object('created', created, 'dropped', dropped, 'skipped', skipped);
END $$;

-- Grants ------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION current_tenant(), current_key(), authenticate() TO anon;
GRANT EXECUTE ON FUNCTION
    api.create_short_link(text, text),
    api.create_api_key(text, boolean),
    api.revoke_api_key(text),
    api.internal_lookup_link(text),
    api.internal_record_clicks(text, json),
    api.internal_maintain_clicks(integer)
TO anon;
GRANT SELECT, INSERT ON links TO anon;  -- RLS limits both to the caller's tenant
GRANT SELECT ON clicks, link_totals, link_clicks_hourly, link_referrers_daily TO anon;
GRANT SELECT ON api.link_stats, api.top_referrers TO anon;

SELECT create_click_partitions((now() AT TIME ZONE 'UTC')::date, (now() AT TIME ZONE 'UTC')::date + 7);

COMMIT;
