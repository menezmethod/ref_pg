#!/bin/bash

# Database Backup Script for Churnistic Referral Service
# Usage: ./backup_database.sh [backup_dir]

# Get backup directory from argument or use default
BACKUP_DIR=${1:-"../backups"}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/referral_service_$TIMESTAMP.sql"

# Load environment variables if .env file exists
if [ -f ../.env ]; then
    source ../.env
else
    echo "Warning: .env file not found. Using default values."
    POSTGRES_USER=${POSTGRES_USER:-postgres}
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
    POSTGRES_DB=${POSTGRES_DB:-referral_service}
fi

# Create backup directory if it doesn't exist
mkdir -p $BACKUP_DIR

echo "Creating backup of $POSTGRES_DB database..."

# Run pg_dump to create the backup
PGPASSWORD=$POSTGRES_PASSWORD pg_dump -h localhost -U $POSTGRES_USER -d $POSTGRES_DB -F p > $BACKUP_FILE

# Check if backup was successful
if [ $? -eq 0 ]; then
    echo "Backup completed successfully: $BACKUP_FILE"
    
    # Compress the backup file
    gzip $BACKUP_FILE
    echo "Backup compressed: $BACKUP_FILE.gz"
    
    # Optional: Remove backups older than 30 days
    find $BACKUP_DIR -name "referral_service_*.sql.gz" -type f -mtime +30 -delete
    echo "Removed backups older than 30 days."
else
    echo "Backup failed!"
    exit 1
fi

exit 0 