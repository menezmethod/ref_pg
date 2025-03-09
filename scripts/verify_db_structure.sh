#!/bin/bash

# Verify the database structure after migration
echo "Verifying database structure..."

# Function to run SQL queries and display results
function run_query() {
  echo "Running query: $1"
  docker exec url_shortener_db psql -U postgres -d url_shortener -c "$1"
  echo
}

# Check if the container is running
docker ps | grep -q url_shortener_db
if [ $? -ne 0 ]; then
  echo "Error: The database container is not running!"
  exit 1
fi

# List all tables
run_query "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name;"

# List all functions
run_query "SELECT proname, proargnames FROM pg_proc WHERE pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public') ORDER BY proname;"

# Check indexes
run_query "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename, indexname;"

# Check API keys
run_query "SELECT id, name, is_admin FROM api_keys;"

# Check table counts
run_query "
SELECT 'users' as table_name, COUNT(*) as row_count FROM users
UNION ALL
SELECT 'urls' as table_name, COUNT(*) as row_count FROM urls
UNION ALL
SELECT 'short_links' as table_name, COUNT(*) as row_count FROM short_links
UNION ALL
SELECT 'link_clicks' as table_name, COUNT(*) as row_count FROM link_clicks
UNION ALL
SELECT 'api_keys' as table_name, COUNT(*) as row_count FROM api_keys
UNION ALL
SELECT 'analytics_events' as table_name, COUNT(*) as row_count FROM analytics_events
ORDER BY table_name;
"

echo "Database structure verification completed!" 