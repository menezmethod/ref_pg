#!/bin/bash
set -e

echo "=== Fix Migration File Structure ==="
echo "This script will ensure the migration file is properly structured."

# Check if migration file exists as directory
if [ -d "migrations/000_main_migration.sql" ]; then
  echo "Migration file is currently a directory. Fixing..."
  
  # Find SQL files in the directory
  SQL_FILES=$(find migrations/000_main_migration.sql -type f -name "*.sql")
  if [ -n "$SQL_FILES" ]; then
    echo "Found SQL files inside directory:"
    echo "$SQL_FILES"
    
    # Create a new file with the correct name
    echo "Creating a new migration file from the found SQL files..."
    cat $SQL_FILES > migrations/000_main_migration.sql.new
    
    # Backup the old directory
    echo "Backing up the old directory..."
    mv migrations/000_main_migration.sql migrations/000_main_migration.sql.bak
    
    # Move the new file to the correct location
    echo "Moving new file to the correct location..."
    mv migrations/000_main_migration.sql.new migrations/000_main_migration.sql
    
    echo "✅ Migration file fixed successfully!"
  else
    echo "❌ No SQL files found in the directory. Please check manually."
    
    # Try to look for any content
    echo "Looking for any content in the directory..."
    find migrations/000_main_migration.sql -type f | head -5
    exit 1
  fi
elif [ -f "migrations/000_main_migration.sql" ]; then
  echo "✅ Migration file already exists as a file. No fix needed."
else
  echo "❌ Migration file does not exist at all."
  echo "Expected path: migrations/000_main_migration.sql"
  exit 1
fi

echo ""
echo "=== Verifying Migration File ==="
if [ -f "migrations/000_main_migration.sql" ]; then
  FILE_SIZE=$(du -h migrations/000_main_migration.sql | cut -f1)
  echo "Migration file size: $FILE_SIZE"
  
  echo "First 10 lines of migration file:"
  head -10 migrations/000_main_migration.sql
  
  echo ""
  echo "✅ Migration file is ready for deployment!"
else
  echo "❌ Migration file still not found. Please check manually."
  exit 1
fi 