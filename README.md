# PostgreSQL URL Shortener Service

A production-ready URL shortening service built using PostgreSQL as the primary technology.

## Overview

This URL shortener service is designed to be a simple, yet powerful solution for creating and managing short links. Unlike traditional URL shorteners that often require complex microservices, this implementation leverages PostgreSQL's advanced features to create a more maintainable system with fewer dependencies.

## Features

- **PostgreSQL-First Architecture**: PostgreSQL handles all business logic, data storage, and even some API handling
- **Short Link Generation**: Create short, memorable links for any URL
- **Custom Aliases**: Support for vanity URLs (custom short links)
- **Link Expiration**: Set expiration dates for short links
- **Click Tracking**: Comprehensive analytics on link usage
- **Redis Caching**: High-performance caching for fast redirects
- **Full-Text Search**: Search through your URLs and metadata
- **Prometheus Metrics**: Monitor system performance 
- **JWT Authentication**: Secure API access
- **Swagger UI**: Interactive API documentation
- **Docker Deployment**: Production-ready containerization

## Getting Started

### Prerequisites

- Docker and Docker Compose
- Git

### Installation

1. Clone the repository:
```bash
git clone https://github.com/menezmethod/ref_pg.git
cd ref_pg
```

2. Create a `.env` file in the root directory with the following variables (or use the defaults):
```
# Database Configuration
POSTGRES_PASSWORD=secure_password_here
POSTGRES_USER=postgres
POSTGRES_DB=url_shortener

# JWT Authentication
JWT_SECRET=secure_random_string_for_jwt_token_signing

# PgAdmin Configuration
PGADMIN_EMAIL=your_email@example.com
PGADMIN_PASSWORD=secure_pgadmin_password

# Redis Configuration
REDIS_PASSWORD=secure_redis_password

# Environment
ENVIRONMENT=development
```

3. Start the services:
```bash
docker-compose up -d
```

4. Access the services:
- API: http://localhost:3001
- Short URLs: http://localhost:8000/r/{code}
- PgAdmin: http://localhost:5050
- Swagger UI: http://localhost:8080
- Prometheus: http://localhost:9090

## Architecture Overview

The URL shortener service consists of several components:

1. **PostgreSQL**: Stores URLs, short links, and analytics data. Also provides business logic through stored procedures.
2. **PostgREST**: Auto-generates a RESTful API based on your PostgreSQL schema. 
3. **OpenResty**: Handles URL redirections with LuaJIT scripting for flexibility.
4. **Redis**: Provides high-speed caching for frequently accessed URLs.
5. **Prometheus & Grafana**: Monitoring and visualization.
6. **PgAdmin**: Database administration.
7. **Swagger UI**: API documentation and testing.

## How It Works

1. When a user submits a URL to be shortened, it's stored in the PostgreSQL database.
2. A unique code is generated (either random or custom-provided).
3. When a user visits a short URL (e.g., `http://localhost:8000/r/abcde`):
   - OpenResty receives the request
   - It calls the PostgREST API to retrieve the original URL
   - If found, it redirects the user to the original URL
   - Analytics data is recorded in PostgreSQL

## Using Swagger UI

The Swagger UI provides an interactive interface to explore and test the API:

1. Open http://localhost:8080 in your browser
2. You'll see all available endpoints for the URL shortener service
3. To create a short link:
   - Find the `/rpc/create_short_link` endpoint and click on it
   - Click "Try it out"
   - Enter a JSON payload with your original URL and optional custom alias:
     ```json
     {
       "p_original_url": "https://example.com/very/long/url",
       "p_custom_alias": "mylink"
     }
     ```
   - Click "Execute"
   - The response will contain your short link code

4. To test other endpoints, such as retrieving statistics or tracking clicks, follow the same process with the appropriate endpoint.

## API Endpoints

The API automatically generates RESTful endpoints based on the database schema:

### URL Shortening

- `POST /rpc/create_short_link` - Create a new short link with payload:
  ```json
  {
    "p_original_url": "https://example.com/very/long/url",
    "p_custom_alias": "mylink",
    "p_expires_at": "2023-12-31T23:59:59Z"
  }
  ```
- `GET /rpc/get_original_url` - Get the original URL for a code (used internally by OpenResty)
- `GET /urls` - List all URLs
- `GET /short_links` - List all short links

### Analytics

- `GET /link_clicks` - View all clicks
- `POST /rpc/track_link_click` - Track a click event for a short link

### User Management

- `GET /users` - List all users (for admin purposes)
- `POST /users` - Create a new user

## Usage Examples

### Creating a Short Link

```bash
curl -X POST "http://localhost:3001/rpc/create_short_link" \
  -H "Content-Type: application/json" \
  -d '{"p_original_url": "https://example.com/very/long/url", "p_custom_alias": "example"}'
```

Response:
```json
{
  "code": "example"
}
```

### Accessing a Short Link

Simply visit in your browser:
```
http://localhost:8000/r/example
```

This will redirect you to the original URL and track the click.

## Troubleshooting

### Common Issues

1. **500 Internal Server Error on redirect**: 
   - Check if the PostgREST service is running: `docker ps | grep postgrest`
   - Verify the redirect code exists in the database
   - Check OpenResty logs: `docker logs url_shortener_redirect`

2. **OpenResty fails to start**:
   - Check for syntax errors in nginx.conf
   - Verify that all required Lua modules are installed
   - Check logs for detailed error messages

3. **PostgREST API not accessible**:
   - Ensure PostgreSQL is running and healthy
   - Check if the database migrations have been applied
   - Verify network connectivity between containers

## Project Structure

```
/
├── docker/                 # Docker setup
│   ├── postgres/           # Postgres configuration
│   │   ├── postgresql.conf # PostgreSQL configuration
│   │   └── pg_hba.conf     # Host-based authentication config
│   ├── openresty/          # OpenResty configuration
│   │   ├── nginx.conf      # Main NGINX configuration
│   │   ├── Dockerfile      # OpenResty Docker build
│   │   └── lua/            # Lua scripts for OpenResty
│   └── postgrest/          # PostgREST configuration
├── migrations/             # SQL migrations for database setup
├── monitoring/             # Monitoring configuration
│   └── prometheus/         # Prometheus configuration
├── docker-compose.yml      # Main compose file
└── README.md               # This file
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details. 