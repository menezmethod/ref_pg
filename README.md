# URL Shortener Service

A robust URL shortening service built with PostgreSQL, PostgREST, and OpenResty.

## Features

- Create short URLs with custom aliases
- Track link clicks with detailed analytics
- API key authentication
- Rate limiting
- RESTful API

## Architecture

This project uses:

- **PostgreSQL**: Database with functions for business logic
- **PostgREST**: Auto-generated REST API from the database
- **OpenResty**: High-performance web server for URL redirection

## Getting Started

### Prerequisites

- Docker and Docker Compose

### Installation

1. Clone this repository
2. Run the service:

```bash
docker-compose up -d
```

## Database Migration Verification

This project includes tools to verify that database migrations have been applied correctly, which is especially useful when deploying to platforms like Coolify.

### Verification Script

The `migrations/999_verify_migration.sql` script runs after all other migrations and:

1. Creates a `migration_history` table to track migration status
2. Checks if all required database objects (schemas, tables, functions, roles) exist
3. Raises clear error messages if anything is missing

### Diagnostic Tool

The `scripts/diagnose_db.sh` script helps diagnose database issues:

```bash
# Run locally
./scripts/diagnose_db.sh

# Or inside the container
docker exec -it url_shortener_db bash -c "/app/scripts/diagnose_db.sh"
```

This tool will:

1. Check database connection
2. Verify migration history
3. Check for required schemas, tables, and functions
4. Test role permissions
5. Verify PostgREST connection
6. Provide a detailed report of any issues

## Troubleshooting

If you encounter issues with the database setup:

1. Check the logs:
   ```bash
   docker-compose logs db
   ```

2. Run the diagnostic script:
   ```bash
   ./scripts/diagnose_db.sh
   ```

3. If migrations aren't being applied:
   ```bash
   # Remove the volume and start fresh
   docker-compose down -v
   docker-compose up -d
   ```

4. Check if the authenticator role has the correct password:
   ```bash
   # The password should match POSTGRES_PASSWORD in your environment
   docker exec -it url_shortener_db psql -U postgres -c "ALTER ROLE authenticator WITH PASSWORD 'your_password';"
   ```

## Environment Variables

- `POSTGRES_PASSWORD`: Database password (default: postgres)
- `POSTGRES_USER`: Database user (default: postgres)
- `POSTGRES_DB`: Database name (default: url_shortener)
- `JWT_SECRET`: Secret for JWT tokens
- `RATE_LIMIT_REQUESTS`: Rate limit requests per window (default: 60)
- `RATE_LIMIT_WINDOW`: Rate limit window in seconds (default: 60)
- `LOG_LEVEL`: Logging level (default: debug)
- `CORS_ALLOW_ORIGIN`: CORS allowed origins (default: *)

## License

This project is licensed under the MIT License. 