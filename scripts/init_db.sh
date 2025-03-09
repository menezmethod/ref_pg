#!/bin/bash
set -e

# This script can be run to manually initialize the database if needed
# Useful for Coolify deployments where automatic initialization might fail

echo "Initializing URL Shortener database..."

# Configuration from environment variables or defaults
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5433}
DB_USER=${POSTGRES_USER:-postgres}
DB_PASSWORD=${POSTGRES_PASSWORD:-postgres}
DB_NAME=${POSTGRES_DB:-url_shortener}

# Check if PostgreSQL is accepting connections
until PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c '\q' postgres; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 1
done

echo "PostgreSQL is up - checking if database exists"

# Check if database exists
if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
  echo "Database $DB_NAME already exists"
else
  echo "Creating database $DB_NAME"
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "CREATE DATABASE $DB_NAME" postgres
fi

# Apply migrations
echo "Applying migrations from 000_main_migration.sql"
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f ../migrations/000_main_migration.sql

# Set master password
echo "Setting master password"
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "ALTER DATABASE $DB_NAME SET app.master_password TO '$MASTER_PASSWORD';"

echo "Database initialization complete!"
echo "You can now access:"
echo "- API: http://localhost:3001/"
echo "- URL Shortener: http://localhost:8000/"
echo "- Swagger UI: http://localhost:8080/"
echo "- pgAdmin: http://localhost:5050/" 