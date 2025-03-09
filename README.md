# URL Shortener Service

A simple URL shortener microservice built with Docker, PostgreSQL, PostgREST, and OpenResty.

## Project Structure

```
.
├── config/                  # Configuration files
├── docker/                  # Docker-related files for services
│   ├── openresty/           # OpenResty configuration
│   │   └── nginx.conf       # Nginx configuration
│   └── postgres/            # PostgreSQL initialization scripts
├── migrations/              # Database migration files
│   └── 000_main_migration.sql  # Main database schema
├── sql/                     # SQL files organized by purpose
│   ├── init/                # Database initialization scripts
│   │   ├── init-db.sh       # Main initialization script
│   │   └── update-pg-hba.sh # Script to update PostgreSQL authentication
│   ├── migrations/          # Database migrations
│   └── schemas/             # Schema definitions
├── docker-compose.yml       # Docker Compose configuration
└── .env                     # Environment variables
```

## Getting Started

### Prerequisites

- Docker
- Docker Compose

### Setup and Run

1. Clone the repository
2. Create a `.env` file with the required environment variables (see `.env.example`)
3. Start the services:

```bash
docker-compose up -d
```

4. Access the URL shortener service at http://localhost:8080

## API Usage

### Create a Short URL

```bash
curl -X POST "http://localhost:8080/api/create_short_link" \
  -H "Content-Type: application/json" \
  -d '{"p_original_url": "https://example.com"}'
```

### Create a Short URL with Custom Alias

```bash
curl -X POST "http://localhost:8080/api/create_short_link" \
  -H "Content-Type: application/json" \
  -d '{"p_original_url": "https://example.com", "p_custom_alias": "my-custom-link"}'
```

### Quick Link Creation (Admin)

```bash
curl -X POST "http://localhost:8080/api/quick_link" \
  -H "Content-Type: application/json" \
  -d '{"p_url": "https://example.com", "p_password": "your-master-password"}'
```

## Services

- **PostgreSQL**: Database server (port 5432)
- **PostgREST**: REST API for PostgreSQL (port 3000)
- **OpenResty**: Web server and URL redirection (port 8080)
- **Swagger UI**: API documentation (port 8081)

## Development

### Database Migrations

All database schemas are consolidated in a single main migration file: `migrations/000_main_migration.sql`

### Authentication

The service uses a master password for admin operations and API keys for regular operations.

To get an API key:

```bash
curl -X POST "http://localhost:8080/api/get_api_key" \
  -H "Content-Type: application/json" \
  -d '{"p_password": "your-master-password"}'
```

## License

This project is licensed under the MIT License. 