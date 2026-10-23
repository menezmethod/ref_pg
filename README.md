# ref_pg

A URL shortener where PostgreSQL is the application. The logic is a few SQL functions. [PostgREST](https://postgrest.org) turns them into an HTTP API, and OpenResty (nginx + Lua) serves redirects and applies rate limits. There is no application server.

```
client ──► OpenResty :8001 ──┬── POST /api/rpc/*  ──► PostgREST ──► api.* functions ──► Postgres
                             ├── GET  /r/{code}   ──► Lua ──► api.resolve_link() ──► 302 + click row
                             └── GET  /health
```

- Tables (`api_keys`, `links`, `clicks`) live in `public` and are not exposed.
- PostgREST exposes only the `api` schema. The `anon` role can execute four functions and nothing else.
- Input rules are table constraints: URLs must be `http(s)://`, codes are 3–32 letters or digits.
- API keys are stored as SHA-256 hashes. The plaintext is shown once, when the key is created.

## Run it

```bash
cp .env.example .env    # set POSTGRES_PASSWORD and AUTHENTICATOR_PASSWORD
docker compose up -d --wait
```

Create the first admin key (the only step that needs database access):

```bash
docker compose exec db sh -c 'psql -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select issue_api_key('"'admin'"', true)"'
```

## API

| Call | Auth | Result |
|---|---|---|
| `POST /api/rpc/create_short_link` `{"p_original_url", "p_custom_alias"?}` | key | `{"code", "original_url"}` |
| `GET /r/{code}` | none | `302` to the URL and one row in `clicks`, or `404` |
| `POST /api/rpc/create_api_key` `{"p_name", "p_is_admin"?}` | admin key | the new key (plaintext, shown once) |
| `POST /api/rpc/revoke_api_key` `{"p_key"}` | admin key | `true` if a key was revoked |

Send the key in the `X-API-Key` header. Errors: `401` bad or missing key, `400` invalid URL or alias, `409` alias taken.

```bash
curl -X POST localhost:8001/api/rpc/create_short_link \
  -H "Content-Type: application/json" -H "X-API-Key: $KEY" \
  -d '{"p_original_url": "https://example.com/docs", "p_custom_alias": "docs"}'

curl -i localhost:8001/r/docs
```

Take down an abusive link: `update links set is_active = false where code = '...';`

## Test

```bash
RATE_LIMIT_REQUESTS=6000 docker compose up -d --wait
./test.sh
```

`test.sh` covers auth, input validation, redirects, click counting, and that internal or removed functions are not reachable.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | required | Superuser password |
| `AUTHENTICATOR_PASSWORD` | required | PostgREST login. Letters and digits only (it goes into a URI) |
| `POSTGRES_USER`, `POSTGRES_DB` | `postgres`, `url_shortener` | |
| `PORT` | `8001` | Published OpenResty port |
| `RATE_LIMIT_REQUESTS`, `RATE_LIMIT_WINDOW` | `60`, `60` | Requests per window (seconds) per IP |
| `LOG_LEVEL` | `notice` | nginx error log level |
| `CORS_ALLOW_ORIGIN` | `*` | |

## Schema changes

`db/` runs once, on an empty volume. To start over: `docker compose down -v && docker compose up -d --wait`. For a database with data in it, apply changes with `psql` by hand. Add a migration tool when that becomes painful.

## Known limitations

- Rate limits key on the TCP peer address. Behind a reverse proxy (Coolify, Traefik), add `set_real_ip_from` and `real_ip_header` to `nginx.conf`, or all clients share one limit.
- Short links are public by design. Anyone with a key can create links to any `http(s)` URL.

## License

MIT
