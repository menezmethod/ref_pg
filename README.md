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

## Quick Start for Coolify

### 1. Set Required Environment Variables

In Coolify, set the following environment variables:

| Required | Variable | Value |
|----------|----------|-------|
| ✅ | `MASTER_PASSWORD` | A strong, unique password (min 12 chars, mix of letters, numbers, symbols) |
| ✅ | `POSTGRES_PASSWORD` | A strong, unique database password |
| ✅ | `JWT_SECRET` | A random string (32+ characters) |
| ✅ | `PGADMIN_EMAIL` | Your email for pgAdmin access |
| ✅ | `PGADMIN_PASSWORD` | A strong password for pgAdmin |
| ✅ | `REDIS_PASSWORD` | A strong password for Redis |

> 🔒 **Security Note**: These credentials are critical for your application's security. Use Coolify's environment variable encryption feature if available.

### 2. Setup HTTPS

For production deployments, always enable HTTPS in Coolify to prevent sensitive data (including your master password) from being transmitted in plaintext.

### 3. Important Configuration Notes

- **PostgreSQL port**: This project uses port 5433 for external PostgreSQL connections to avoid conflicts with other PostgreSQL instances. Update your connection strings accordingly.
- **OpenResty port**: The URL shortener redirect service runs on port 8001 instead of the standard port 8000 to avoid conflicts with other services in Coolify.
- **Custom PostgreSQL configuration**: The default PostgreSQL configuration is used to avoid errors. If you need custom configurations, add them to the Coolify settings.
- **pgAdmin access**: For information on how to use pgAdmin with this project, see the [pgAdmin Guide](./pgadmin-guide.md).
- **Prometheus**: The Prometheus service has been removed to simplify deployment, but metrics endpoints are still available.

### 4. Troubleshooting Coolify Deployment

If you encounter issues with your Coolify deployment:

- **PostgreSQL configuration errors**: Check that your volume mounts are correct and the PostgreSQL configuration files exist and are formatted properly
- **Port conflicts**: If you see errors about ports already being in use, modify the exposed ports in your configuration
- **Connection issues**: Ensure network connectivity between services using the service names defined in your configuration

### 5. That's it!

With these security settings in place, your URL shortener is ready to use in production.

## Authentication Flow

The URL shortener uses a simple API key authentication system. Here's how it works:

### The Authentication Flow

1. **Set a master password** as an environment variable (done once during setup)
2. **Get the API key** using this master password (done once at application startup)
3. **Use the API key in all your API calls**

### Getting the API Key

Call this endpoint once to get your API key:

```bash
# Get API key using master password
curl -X POST "https://your-domain/api/rpc/get_api_key" \
  -H "Content-Type: application/json" \
  -d '{"p_password": "your-master-password"}'
```

Response:
```json
{
  "success": true,
  "api_key": "042af4f146b96858888537f87414eeab246e3432ee958e79"
}
```

### Using the API Key

For production use, we recommend the dedicated parameter-based endpoint for reliable authentication:

```bash
# Production-ready approach for API key authentication
curl -X POST "https://your-domain/api/rpc/create_short_link_with_key_param" \
  -H "Content-Type: application/json" \
  -d '{
    "p_original_url": "https://example.com/test",
    "p_api_key": "your-api-key"
  }'
```

For backward compatibility, you can also include the API key in the request body of the standard endpoint:

```bash
# Alternative approach (backward compatibility)
curl -X POST "https://your-domain/api/rpc/create_short_link" \
  -H "Content-Type: application/json" \
  -d '{
    "p_original_url": "https://example.com/test",
    "p_api_key": "your-api-key"
  }'
```

## API Usage

### Creating Short Links (With API Key)

This is the recommended method for all production use:

```bash
curl -X POST "https://your-domain/api/rpc/create_short_link_with_key_param" \
  -H "Content-Type: application/json" \
  -d '{
    "p_original_url": "https://example.com/long-url",
    "p_api_key": "your-api-key",
    "p_custom_alias": "optional-custom-code",  // Omit to auto-generate
    "p_expires_at": "2023-12-31T23:59:59Z",    // Optional expiration
    "p_metadata": {"campaign": "summer-promo"} // Optional metadata
  }'
```

Returns:
```json
{
  "success": true,
  "short_link_id": "64cd8a46-7c38-4693-829e-6687563fa6aa",
  "url_id": "657dab71-a4f7-4389-801c-2e99e9a5a344",
  "code": "auto-generated-or-custom-code",
  "original_url": "https://example.com/long-url",
  "custom_alias": "optional-custom-code",
  "expires_at": null
}
```

### Direct Password Method (FOR TESTING ONLY)

> ⚠️ **Not recommended for production use**. This method exists mainly for testing and development.

```bash
curl -X POST "https://your-domain/api/rpc/quick_link" \
  -H "Content-Type: application/json" \
  -d '{
    "p_url": "https://example.com/your-long-url",
    "p_password": "your-master-password",
    "p_code": "optional-custom-code"  // Omit to auto-generate a code
  }'
```

Returns: `"generated-or-custom-code"`

### Accessing Short Links

To access a short link, simply navigate to:

```
https://your-domain/r/{code}
```

This will redirect to the original URL.

## API Documentation (Swagger)

The URL shortener includes comprehensive API documentation via Swagger UI:

### Accessing Swagger UI

```
https://your-domain:8080/
```

The Swagger UI provides:
- Interactive documentation for all API endpoints
- The ability to test API calls directly from the browser
- Sample request/response payloads
- Authentication requirements for each endpoint

### Key Endpoints in Swagger

These are the main endpoints you'll use:

1. `/rpc/get_api_key` - Get an API key using master password
2. `/rpc/create_short_link_with_key_param` - Create a short link with API key (recommended)
3. `/rpc/create_short_link` - Create a short link with API key (alternative)
4. `/rpc/quick_link` - Create a short link with master password (for testing only)
5. `/rpc/change_master_password` - Change the master password

## Security Best Practices

For secure production deployment, follow these guidelines:

1. **Strong Passwords**: Use complex, unique passwords for all credentials
2. **HTTPS Required**: Always use HTTPS in production to prevent credential interception
3. **API Key Management**: Rotate API keys periodically for enhanced security
4. **Least Privilege**: Create API keys with only the permissions needed
5. **Logging**: Monitor analytics_events table for security-related events
6. **Rate Limiting**: Configure appropriate rate limits to prevent abuse

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

## Additional Features

### Auto-Generation of Short Codes

If you don't specify a custom code (`p_code` or `p_custom_alias`), the system will automatically generate a random short code for you. The generated codes:

- Are typically 6 characters long
- Contain a mix of letters and numbers
- Are guaranteed to be unique

### API Key Management

The system provides several endpoints for API key management:

- `/rpc/generate_api_key` - Generate a new API key (admin only)
- `/rpc/revoke_api_key` - Revoke an existing API key (admin only)
- `/rpc/list_api_keys` - List all API keys (admin only)

### Analytics

Basic analytics are stored for each short link:

- Click count and timestamps
- Referrer information (where available)
- Geographic information (if enabled)

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