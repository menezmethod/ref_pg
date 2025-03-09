#!/bin/bash
set -e

# This script runs after PostgreSQL starts and sets the master password
# as a database parameter that can be read by functions

echo "Setting master password from environment variable..."

# Wait for PostgreSQL to be ready
until pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do
  echo "Waiting for PostgreSQL to be ready..."
  sleep 1
done

# Check if master password is set
if [ -z "$MASTER_PASSWORD" ] || [ "$MASTER_PASSWORD" = "master123" ]; then
  echo "⚠️  WARNING: Using default or empty master password. This is INSECURE for production!"
  echo "⚠️  Please set a strong MASTER_PASSWORD environment variable in production."
else
  # Check password strength
  if [ ${#MASTER_PASSWORD} -lt 8 ]; then
    echo "⚠️  WARNING: Master password is too short (less than 8 characters)."
    echo "⚠️  Using it anyway, but consider setting a stronger password in production."
  fi
fi

# Set the master password as a database parameter
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
  -- Make the password accessible to SQL functions
  ALTER DATABASE $POSTGRES_DB SET app.master_password TO '$MASTER_PASSWORD';
  
  -- Apply our new migration if it exists
  \i /docker-entrypoint-initdb.d/005_env_password.sql
EOSQL

echo "Master password set successfully!"
echo "💡 Note: For production, remember to use a strong master password and enable HTTPS." 