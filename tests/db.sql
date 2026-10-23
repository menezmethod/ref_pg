-- pgTAP tests for the schema's rules. Everything runs in one transaction and
-- is rolled back. Run against a running stack:
--   docker compose exec -T db sh -c 'psql -X -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/db.sql
\set ON_ERROR_STOP 1
BEGIN;
CREATE EXTENSION pgtap;
SELECT plan(30);

-- Act like PostgREST does for a request carrying this X-API-Key (NULL = none).
CREATE FUNCTION pg_temp.act_as(p_key text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('app.tenant_id', '', true), set_config('app.key_id', '', true),
            set_config('app.is_admin', '', true),
            set_config('request.headers', json_build_object('x-api-key', p_key)::text, true);
    PERFORM authenticate();
END $$;

-- Run a query as anon and return its single value as text.
CREATE FUNCTION pg_temp.as_anon(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
    SET LOCAL ROLE anon;
    EXECUTE q INTO v;
    RESET ROLE;
    RETURN v;
END $$;

-- Run a statement as anon; return its SQLSTATE, or NULL if it succeeded.
CREATE FUNCTION pg_temp.error_as_anon(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    SET LOCAL ROLE anon;
    BEGIN
        EXECUTE q;
    EXCEPTION WHEN others THEN
        RESET ROLE;
        RETURN SQLSTATE;
    END;
    RESET ROLE;
    RETURN NULL;
END $$;

SELECT issue_api_key('tenant_a', 'admin', true) AS key_a,
       issue_api_key('tenant_b', 'user')        AS key_b \gset
SELECT id AS tenant_a FROM tenants WHERE name = 'tenant_a' \gset

-- Building blocks
SELECT is(anonymize_ip('203.0.113.77'), '203.0.113.0/24'::inet, 'IPv4 is truncated to /24');
SELECT is(anonymize_ip('2001:db8:1:2::5'), '2001:db8:1::/48'::inet, 'IPv6 is truncated to /48');
SELECT ok(anonymize_ip('junk') IS NULL, 'an invalid IP becomes NULL');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'links'::regclass), 'RLS is on for links');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'clicks'::regclass), 'RLS is on for clicks');

-- Authentication
SELECT pg_temp.act_as(NULL);
SELECT is(pg_temp.error_as_anon($$SELECT api.create_short_link('https://a.com')$$), 'PT401',
          'creating a link without a key is 401');
SELECT throws_ok($$SELECT pg_temp.act_as('nope')$$, 'PT401', 'Invalid API key', 'an unknown key is 401');

-- Tenant A creates links
SELECT pg_temp.act_as(:'key_a');
SELECT is(pg_temp.error_as_anon($$SELECT api.create_short_link('https://a.com', 'alpha')$$), NULL,
          'a valid key creates a link');
SELECT is(pg_temp.error_as_anon($$SELECT api.create_short_link('javascript:alert(1)')$$), '23514',
          'a javascript: URL violates a check constraint (HTTP 400)');
SELECT is(pg_temp.error_as_anon($$SELECT api.create_short_link('https://a.com', 'alpha')$$), '23505',
          'a duplicate alias is a unique violation (HTTP 409)');
SELECT is(pg_temp.error_as_anon(format('SELECT api.create_short_link(%L)', 'https://a.com/x' || chr(1) || 'y')),
          '23514', 'a URL with a control character is rejected (OpenResty would answer 500)');
SELECT is(pg_temp.as_anon('SELECT count(*) FROM links'), '1', 'tenant A sees its own link');
SELECT is(pg_temp.as_anon($$SELECT length(api.create_short_link('https://a.com/gen')->>'code')$$), '7',
          'a generated code has 7 characters');

-- Tenant B is isolated and not an admin
SELECT pg_temp.act_as(:'key_b');
SELECT is(pg_temp.as_anon('SELECT count(*) FROM links'), '0', 'tenant B cannot see tenant A links');
SELECT is(pg_temp.error_as_anon(format(
              $$INSERT INTO links (tenant_id, code, url) VALUES (%s, 'sneaky', 'https://x.com')$$, :tenant_a)),
          '42501', 'tenant B cannot insert a link into tenant A');
SELECT is(pg_temp.error_as_anon($$SELECT api.create_api_key('x')$$), 'PT403',
          'a non-admin key cannot create keys (HTTP 403)');
SELECT is(pg_temp.error_as_anon('SELECT * FROM api_keys'), '42501', 'anon cannot read api_keys');
SELECT is(pg_temp.error_as_anon($$SELECT issue_api_key('t', 'x', true)$$), '42501',
          'anon cannot call the internal key helper');

-- Click recording (what the OpenResty flusher calls)
SELECT is(pg_temp.as_anon($$SELECT api.internal_record_clicks('batch-1',
              '[{"code":"alpha","ts":1700000000,"ip":"203.0.113.77"},{"code":"nosuch","ts":1700000000}]')$$),
          '1', 'clicks for unknown codes are skipped');
SELECT is(pg_temp.as_anon($$SELECT api.internal_record_clicks('batch-1',
              '[{"code":"alpha","ts":1700000000,"ip":"203.0.113.77"}]')$$),
          '0', 'a retried batch id is not recorded twice');
SELECT is((SELECT c.ip FROM clicks c JOIN links l ON l.id = c.link_id WHERE l.code = 'alpha'),
          '203.0.113.0/24'::inet, 'the stored click IP is truncated');
SELECT is((SELECT c.tenant_id FROM clicks c JOIN links l ON l.id = c.link_id WHERE l.code = 'alpha'),
          :tenant_a::bigint, 'the click belongs to the link''s tenant');
SELECT is((SELECT c.clicked_at FROM clicks c JOIN links l ON l.id = c.link_id WHERE l.code = 'alpha'),
          to_timestamp(1700000000), 'clicked_at is the time OpenResty saw the click');

-- Stats views
SELECT is(pg_temp.as_anon('SELECT count(*) FROM api.link_stats'), '0', 'tenant B link_stats is empty');
SELECT pg_temp.act_as(:'key_a');
SELECT is(pg_temp.as_anon($$SELECT clicks FROM api.link_stats WHERE code = 'alpha'$$), '1',
          'tenant A link_stats counts the click');
SELECT is(pg_temp.as_anon($$SELECT referrer || '=' || clicks FROM api.top_referrers WHERE code = 'alpha'$$),
          '(direct)=1', 'top_referrers counts a click without a referrer as (direct)');
SELECT pg_temp.as_anon(format($$SELECT api.internal_record_clicks('batch-2', '[{"code":"alpha","ts":%s}]')$$,
                              extract(epoch FROM now())));
SELECT is(pg_temp.as_anon($$SELECT clicks || '/' || clicks_24h FROM api.link_stats WHERE code = 'alpha'$$),
          '2/1', 'the rollups count an old click in clicks and a new one in clicks_24h too');

-- Key management
SELECT is(pg_temp.as_anon($$SELECT length(api.create_api_key('ci'))$$), '48', 'an admin key creates a key');
SELECT is(pg_temp.as_anon(format('SELECT api.revoke_api_key(%L)', :'key_b')), 'false',
          'an admin cannot revoke another tenant''s key');
SELECT ok((SELECT is_active FROM api_keys WHERE key_hash = digest(:'key_b', 'sha256')),
          'the other tenant''s key is still active');

SELECT * FROM finish(true);
ROLLBACK;
