#!/bin/bash
set -e

# Script to set the master password and verify database initialization
# Enhanced version for Coolify environments

echo "Setting master password from environment variable..."

# Simple pause to ensure PostgreSQL is fully initialized
sleep 5

# Wait for PostgreSQL to be fully ready
for i in {1..60}; do
  if pg_isready -U "$POSTGRES_USER"; then
    echo "PostgreSQL server is accepting connections."
    break
  fi
  echo "Waiting for PostgreSQL to be ready (attempt $i/60)..."
  sleep 2
  if [ $i -eq 60 ]; then
    echo "WARNING: PostgreSQL did not become ready in time, but continuing anyway..."
  fi
done

# Verify the database exists, create it if not
if ! psql -lqt | cut -d \| -f 1 | grep -qw "$POSTGRES_DB"; then
  echo "Database $POSTGRES_DB does not exist. Creating it..."
  createdb "$POSTGRES_DB"
  echo "Database $POSTGRES_DB created."
else
  echo "Database $POSTGRES_DB already exists."
fi

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

# Retry mechanism for setting the master password
for i in {1..30}; do
  if psql -v ON_ERROR_STOP=0 -d "$POSTGRES_DB" -c "ALTER DATABASE $POSTGRES_DB SET app.master_password TO '$MASTER_PASSWORD';" >/dev/null 2>&1; then
    echo "Successfully set master password for $POSTGRES_DB database."
    break
  fi
  echo "Attempt $i/30: Could not set master password, retrying in 2 seconds..."
  sleep 2
  if [ $i -eq 30 ]; then
    echo "WARNING: Could not set master password after 30 attempts, but continuing..."
  fi
done

# Final verification steps
echo "Verifying database setup..."

# Check if tables exist in public schema
psql -d "$POSTGRES_DB" << EOF
SELECT CASE 
  WHEN EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'short_links') 
  THEN 'Tables found in schema, initialization appears successful.'
  ELSE 'WARNING: Essential tables not found. Schema might not be properly initialized.'
END AS schema_status;
EOF

echo "Master password setup complete!"
echo "💡 Note: For production, remember to use a strong master password and enable HTTPS." 