#!/bin/bash

cat > .env << 'EOL'
# Database Configuration
POSTGRES_PASSWORD=postgres
POSTGRES_USER=postgres
POSTGRES_DB=referral_service

# JWT Authentication
JWT_SECRET=test_jwt_secret_1234

# PgAdmin Configuration
PGADMIN_EMAIL=admin@example.com
PGADMIN_PASSWORD=admin

# Grafana Configuration
GRAFANA_USER=admin
GRAFANA_PASSWORD=admin

# Redis Configuration
REDIS_PASSWORD=

# Environment
ENVIRONMENT=development
EOL

echo ".env file updated with Grafana and Redis configuration." 