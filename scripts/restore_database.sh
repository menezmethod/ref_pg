#!/bin/bash

# Database Restore Script for Churnistic Referral Service
# Usage: ./restore_database.sh backup_file.sql.gz

# Check if backup file is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <backup_file.sql.gz>"
    exit 1
fi

BACKUP_FILE=$1

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Load environment variables if .env file exists
if [ -f ../.env ]; then
    source ../.env
else
    echo "Warning: .env file not found. Using default values."
    POSTGRES_USER=${POSTGRES_USER:-postgres}
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
    POSTGRES_DB=${POSTGRES_DB:-referral_service}
fi

echo "Restoring $POSTGRES_DB database from $BACKUP_FILE..."

# If the backup is compressed, uncompress it first
if [[ "$BACKUP_FILE" == *.gz ]]; then
    echo "Uncompressing backup file..."
    gunzip -c "$BACKUP_FILE" > /tmp/restore_temp.sql
    RESTORE_FILE="/tmp/restore_temp.sql"
else
    RESTORE_FILE="$BACKUP_FILE"
fi

# Restore the database
echo "Dropping existing database..."
PGPASSWORD=$POSTGRES_PASSWORD dropdb -h localhost -U $POSTGRES_USER $POSTGRES_DB --if-exists

echo "Creating fresh database..."
PGPASSWORD=$POSTGRES_PASSWORD createdb -h localhost -U $POSTGRES_USER $POSTGRES_DB

echo "Restoring data..."
PGPASSWORD=$POSTGRES_PASSWORD psql -h localhost -U $POSTGRES_USER -d $POSTGRES_DB -f "$RESTORE_FILE"

# Check if restore was successful
if [ $? -eq 0 ]; then
    echo "Database restore completed successfully."
    
    # Clean up temp file if it was created
    if [[ "$BACKUP_FILE" == *.gz ]]; then
        rm -f /tmp/restore_temp.sql
    fi
else
    echo "Database restore failed!"
    exit 1
fi

exit 0 