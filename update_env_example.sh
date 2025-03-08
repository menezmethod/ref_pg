#!/bin/bash

cat > .env.example << 'EOL'
# Database Configuration
POSTGRES_PASSWORD=secure_password_here
POSTGRES_USER=referral_service
POSTGRES_DB=referral_service

# JWT Authentication
JWT_SECRET=secure_random_string_for_jwt_token_signing

# PgAdmin Configuration
PGADMIN_EMAIL=admin@example.com
PGADMIN_PASSWORD=admin_password

# Grafana Configuration
GRAFANA_USER=admin
GRAFANA_PASSWORD=secure_grafana_password

# Redis Configuration
REDIS_PASSWORD=secure_redis_password

# Environment
ENVIRONMENT=development
EOL

echo ".env.example file updated with Grafana and Redis configuration." 