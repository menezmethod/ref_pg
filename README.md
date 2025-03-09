# PostgreSQL URL Shortener

A production-ready URL shortening service built on PostgreSQL with simple password authentication. Perfect for deployment on Coolify.

## Features

- **URL Shortening**: Generate short codes for long URLs
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

## Quick Start for Coolify

### 1. Set Required Environment Variables

In Coolify, set the following environment variables:

| Required | Variable | Value |
|----------|----------|-------|
| ✅ | `MASTER_PASSWORD` | A strong, unique password (min 12 chars, mix of letters, numbers, symbols) |
| ✅ | `POSTGRES_PASSWORD` | A strong, unique database password |
| ✅ | `JWT_SECRET` | A random string (32+ characters) |

> 🔒 **Security Note**: These credentials are critical for your application's security. Use Coolify's environment variable encryption feature if available.

### 2. Setup HTTPS

For production deployments, always enable HTTPS in Coolify to prevent sensitive data (including your master password) from being transmitted in plaintext.

### 3. That's it!

With these security settings in place, your URL shortener is ready to use in production.

## API Usage

### Super Simple Method (RECOMMENDED FOR COOLIFY)

Create a short link with a single API call:

```bash
curl -X POST "https://your-coolify-domain/rpc/quick_link" \
  -H "Content-Type: application/json" \
  -d '{
    "p_url": "https://example.com/your-long-url",
    "p_password": "your-master-password",
    "p_code": "optional-custom-code"
  }'
```

This returns just the short code. Access your short link at:

```
https://your-coolify-domain/r/{code}
```

> 🔒 **Security Note**: Always use HTTPS (not HTTP) in production to prevent password interception!

## Environment Variables

The service can be configured using the following environment variables:

| Variable | Description | Default | Security Importance |
|----------|-------------|---------|---------------------|
| MASTER_PASSWORD | Master password for authentication | Random (dev only) | 🔒 HIGH |
| POSTGRES_PASSWORD | PostgreSQL database password | postgres | 🔒 HIGH |
| JWT_SECRET | Secret for JWT authentication | placeholder | 🔒 HIGH |
| REDIS_PASSWORD | Password for Redis | (empty) | 🔒 MEDIUM |
| POSTGRES_USER | PostgreSQL database user | postgres | ⚠️ MEDIUM |
| POSTGRES_DB | PostgreSQL database name | url_shortener | ℹ️ LOW |
| RATE_LIMIT_REQUESTS | Number of requests allowed per minute | 60 | ℹ️ LOW |
| CORS_ALLOW_ORIGIN | CORS allowed origins | * | ⚠️ MEDIUM |

> ⚠️ **SECURITY WARNING**: For production environments:
> - **ALWAYS** set strong, unique values for all variables marked HIGH security importance
> - Use a secrets management solution for storing sensitive values
> - Never commit actual production credentials to version control
> - Use HTTPS in production to prevent credential interception

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