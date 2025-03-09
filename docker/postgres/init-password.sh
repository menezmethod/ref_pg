#!/bin/bash
set -e

# This script runs after PostgreSQL starts and sets the master password
# as a database parameter that can be read by functions

echo "Setting master password from environment variable..."

# Wait for PostgreSQL to be fully ready
for i in {1..30}; do
  if pg_isready -U "$POSTGRES_USER"; then
    break
  fi
  echo "Waiting for PostgreSQL to be ready (attempt $i/30)..."
  sleep 2
done

# Additional check - try to connect to the actual database
for i in {1..30}; do
  if psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" >/dev/null 2>&1; then
    echo "Successfully connected to $POSTGRES_DB database"
    break
  fi
  echo "Waiting for $POSTGRES_DB database to be ready (attempt $i/30)..."
  sleep 2
  # If we've tried many times, attempt to create the database
  if [ $i -eq 20 ]; then
    echo "Attempting to create $POSTGRES_DB database manually..."
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -c "CREATE DATABASE $POSTGRES_DB;" postgres || true
  fi
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
echo "Setting master password for $POSTGRES_DB database..."
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL
  -- Make the password accessible to SQL functions
  ALTER DATABASE $POSTGRES_DB SET app.master_password TO '$MASTER_PASSWORD';
  
  -- Verify the schema exists and has the expected tables
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'short_links') THEN
      RAISE NOTICE 'Essential tables not found, you may need to re-apply the migration';
    ELSE
      RAISE NOTICE 'Schema verification passed';
    END IF;
  END
  \$\$;
EOSQL

echo "Master password set successfully!"
echo "💡 Note: For production, remember to use a strong master password and enable HTTPS." 