#!/bin/bash
# PostgreSQL URL Shortener Database Backup Script
# This script creates compressed backups of the PostgreSQL database and rotates old backups

# Configuration
BACKUP_DIR="/path/to/backups"  # Change this to your backup directory
CONTAINER_NAME="url_shortener_db"
DB_NAME="url_shortener"
DB_USER="postgres"
BACKUP_RETENTION_DAYS=7
DATE_FORMAT="%Y-%m-%d_%H-%M-%S"
CURRENT_DATE=$(date +"$DATE_FORMAT")
BACKUP_FILENAME="${DB_NAME}_${CURRENT_DATE}.sql.gz"

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Echo start
echo "Starting backup of $DB_NAME at $(date)"

# Create backup 
echo "Creating database backup..."
docker exec "$CONTAINER_NAME" pg_dump -U "$DB_USER" -d "$DB_NAME" | gzip > "$BACKUP_DIR/$BACKUP_FILENAME"

# Check if backup was successful
if [ $? -eq 0 ]; then
    echo "Database backup completed successfully: $BACKUP_FILENAME"
    
    # Create a symlink to the latest backup
    ln -sf "$BACKUP_DIR/$BACKUP_FILENAME" "$BACKUP_DIR/latest.sql.gz"
    
    # Delete backups older than retention period
    find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -type f -mtime +$BACKUP_RETENTION_DAYS -delete
    echo "Removed backups older than $BACKUP_RETENTION_DAYS days"
else
    echo "Error: Database backup failed!"
    exit 1
fi

# Show disk usage
echo "Current backup disk usage:"
du -sh "$BACKUP_DIR"

echo "Backup process completed at $(date)"

# Add this to crontab for daily backups at 2 AM:
# 0 2 * * * /path/to/backup_database.sh >> /path/to/backup_logs/backup.log 2>&1 