# PostgreSQL URL Shortener

A production-ready URL shortening service built on PostgreSQL with API key authentication. This project demonstrates how to build a robust URL shortening service using PostgreSQL's powerful features for both data storage and business logic.

## Features

- **URL Shortening**: Generate short codes for long URLs
- **API Key Authentication**: Secure your API with key-based authentication
- **Custom Aliases**: Optionally specify a custom short code
- **URL Expiration**: Set expiration dates for links
- **Click Tracking**: Track click events on short links
- **Caching**: Redis-based caching for high-performance redirects
- **Rate Limiting**: Protect against abuse with configurable rate limits
- **Horizontal Scalability**: Designed for containerized environments
- **Production-Ready**: Includes monitoring, health checks, and security features

## Architecture

The service is built with the following components:

- **PostgreSQL**: Core database for storing URLs, short codes, analytics, and API keys
- **PostgREST**: Auto-generated REST API for database access
- **OpenResty**: High-performance Nginx with Lua for URL redirection
- **Redis**: Caching layer for frequently accessed URLs
- **Docker**: Containerization for easy deployment

## Quick Start

### Prerequisites

- Docker and Docker Compose
- Git

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/url-shortener.git
   cd url-shortener
   ```

2. Start the services:
   ```bash
   docker-compose up -d
   ```

3. Retrieve your master admin API key:
   ```bash
   docker exec url_shortener_db psql -U postgres -d url_shortener -c "SELECT key FROM api_keys WHERE name = 'Master Admin Key'"
   ```

## API Usage

### Authentication

The API supports two methods for API key authentication:

1. **Using the X-API-Key header**:
   ```bash
   curl -X POST "http://localhost:3001/rpc/create_short_link" \
     -H "Content-Type: application/json" \
     -H "X-API-Key: your-api-key" \
     -d '{"p_original_url": "https://example.com/test"}'
   ```

2. **Including the API key in the request body**:
   ```bash
   curl -X POST "http://localhost:3001/rpc/create_short_link" \
     -H "Content-Type: application/json" \
     -d '{
       "p_original_url": "https://example.com/test",
       "p_api_key": "your-api-key"
     }'
   ```

### Creating a Short Link

```bash
curl -X POST "http://localhost:3001/rpc/create_short_link" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-api-key" \
  -d '{
    "p_original_url": "https://example.com/some-long-url",
    "p_custom_alias": "my-custom-code",  # Optional
    "p_expires_at": "2023-12-31T23:59:59Z",  # Optional
    "p_metadata": {"campaign": "summer_promo"}  # Optional
  }'
```

### Accessing a Short Link

```
http://localhost:8000/r/{code}
```

### API Key Management

#### Generate a new API key (admin only)

```bash
curl -X POST "http://localhost:3001/rpc/generate_api_key" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-admin-key" \
  -d '{"p_name": "My Application", "p_is_admin": false}'
```

#### Revoke an API key (admin only)

```bash
curl -X POST "http://localhost:3001/rpc/revoke_api_key" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-admin-key" \
  -d '{"p_key": "api-key-to-revoke"}'
```

#### List all API keys (admin only)

```bash
curl -X POST "http://localhost:3001/rpc/list_api_keys" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-admin-key"
```

## Authentication Methods

The URL shortener supports multiple authentication methods:

### 1. API Key Authentication

Suitable for programmatic access and integration with other systems:

- **Using X-API-Key header**:
  ```bash
  curl -X POST "http://localhost:3001/rpc/create_short_link" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: your-api-key" \
    -d '{"p_original_url": "https://example.com/test"}'
  ```

- **Including API key in request body**:
  ```bash
  curl -X POST "http://localhost:3001/rpc/create_short_link" \
    -H "Content-Type: application/json" \
    -d '{
      "p_original_url": "https://example.com/test",
      "p_api_key": "your-api-key"
    }'
  ```

### 2. Simple Password Authentication (Recommended for Coolify)

For simpler deployments like Coolify, we provide a straightforward password-based authentication:

1. **Set the master password** (using admin API key, do this once):
   ```bash
   curl -X POST "http://localhost:3001/rpc/set_master_password" \
     -H "Content-Type: application/json" \
     -d '{
       "p_password": "your-secure-password",
       "p_admin_api_key": "your-admin-api-key"
     }'
   ```

2. **Create short links with just the password**:
   ```bash
   curl -X POST "http://localhost:3001/rpc/simple_create_link" \
     -H "Content-Type: application/json" \
     -d '{
       "p_password": "your-secure-password",
       "p_url": "https://example.com/to-shorten",
       "p_custom_code": "optional-custom-code"
     }'
   ```

3. **Change the password** (if needed):
   ```bash
   curl -X POST "http://localhost:3001/rpc/change_master_password" \
     -H "Content-Type: application/json" \
     -d '{
       "p_current_password": "your-current-password",
       "p_new_password": "your-new-password"
     }'
   ```

This simplified approach is perfect for Coolify as it only requires remembering a single password instead of managing complex API keys.

## Environment Variables

The service can be configured using the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| POSTGRES_PASSWORD | PostgreSQL database password | postgres |
| POSTGRES_USER | PostgreSQL database user | postgres |
| POSTGRES_DB | PostgreSQL database name | url_shortener |
| JWT_SECRET | Secret for JWT authentication | your_jwt_secret_change_me |
| REDIS_PASSWORD | Password for Redis | (empty) |
| RATE_LIMIT_REQUESTS | Number of requests allowed per minute | 60 |
| CORS_ALLOW_ORIGIN | CORS allowed origins | * |

## Production Deployment

For production deployment, refer to the [Production Checklist](docs/production-checklist.md).

## Development

### Directory Structure

```
.
├── docker/                  # Docker configuration files
│   ├── openresty/           # OpenResty configuration
│   ├── postgres/            # PostgreSQL configuration
│   └── postgrest/           # PostgREST configuration
├── migrations/              # Database migration scripts
├── monitoring/              # Monitoring configuration
├── scripts/                 # Utility scripts
└── docker-compose.yml       # Docker Compose configuration
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgements

- [PostgreSQL](https://postgresql.org/)
- [PostgREST](https://postgrest.org/)
- [OpenResty](https://openresty.org/)
- [Redis](https://redis.io/) 