#!/bin/bash
set -e

echo "=== URL Shortener Migration Verification ==="
echo "This script will verify that your migration has been applied correctly."

# Default values
DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-5432}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_DB=${POSTGRES_DB:-url_shortener}

# Check if password is provided
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "ERROR: POSTGRES_PASSWORD environment variable is required."
  echo "Please run: export POSTGRES_PASSWORD=yourpassword"
  exit 1
fi

# Get container ID
DB_CONTAINER=$(docker ps --filter name=url_shortener_db -q)

if [ -z "$DB_CONTAINER" ]; then
  echo "WARNING: Could not find database container. Using direct connection."
  CONNECTION_METHOD="direct"
else
  echo "Found database container: $DB_CONTAINER"
  CONNECTION_METHOD="container"
fi

# Function to execute SQL
run_sql() {
  local sql=$1
  local message=$2
  
  echo -n "$message... "
  
  local result
  if [ "$CONNECTION_METHOD" = "container" ]; then
    result=$(docker exec $DB_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "$sql")
  else
    result=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "$sql")
  fi
  
  echo "$result" | tr -d '[:space:]'
}

# Check API schema
api_schema=$(run_sql "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'api');" "Checking API schema")
if [ "$api_schema" = "t" ]; then
  echo "✅ API schema exists!"
else
  echo "❌ API schema does not exist!"
fi

# Check key tables
urls_table=$(run_sql "SELECT EXISTS(SELECT 1 FROM pg_tables WHERE schemaname = 'api' AND tablename = 'urls');" "Checking urls table")
if [ "$urls_table" = "t" ]; then
  echo "✅ api.urls table exists!"
else
  echo "❌ api.urls table does not exist!"
fi

short_links_table=$(run_sql "SELECT EXISTS(SELECT 1 FROM pg_tables WHERE schemaname = 'api' AND tablename = 'short_links');" "Checking short_links table")
if [ "$short_links_table" = "t" ]; then
  echo "✅ api.short_links table exists!"
else
  echo "❌ api.short_links table does not exist!"
fi

# Check key functions
functions=("get_api_key" "quick_link" "create_short_link" "test_create_link")
for func in "${functions[@]}"; do
  func_exists=$(run_sql "SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname='$func' AND pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='api'));" "Checking api.$func function")
  if [ "$func_exists" = "t" ]; then
    echo "✅ api.$func function exists!"
  else
    echo "❌ api.$func function does not exist!"
  fi
done

# Check roles
anon_role=$(run_sql "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon');" "Checking anon role")
if [ "$anon_role" = "t" ]; then
  echo "✅ anon role exists!"
else
  echo "❌ anon role does not exist!"
fi

authenticator_role=$(run_sql "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticator');" "Checking authenticator role")
if [ "$authenticator_role" = "t" ]; then
  echo "✅ authenticator role exists!"
else
  echo "❌ authenticator role does not exist!"
fi

# Check permissions
echo -n "Checking sequence permissions... "
seq_permission=$(run_sql "SELECT has_sequence_privilege('anon', 'api.urls_id_seq', 'USAGE');" "")
if [ "$seq_permission" = "t" ]; then
  echo "✅ anon role has proper sequence permissions!"
else
  echo "❌ anon role is missing sequence permissions!"
fi

echo -n "Checking function permissions... "
func_permission=$(run_sql "SELECT has_function_privilege('anon', 'api.get_api_key(text)', 'EXECUTE');" "")
if [ "$func_permission" = "t" ]; then
  echo "✅ anon role has proper function permissions!"
else
  echo "❌ anon role is missing function permissions!"
fi

echo ""
echo "=== Verification Summary ==="
if [[ "$api_schema" = "t" && "$urls_table" = "t" && "$short_links_table" = "t" && 
      "$anon_role" = "t" && "$authenticator_role" = "t" && 
      "$seq_permission" = "t" && "$func_permission" = "t" ]]; then
  echo "✅ Migration appears to have been applied successfully!"
  echo "The URL shortener should be fully operational."
else
  echo "❌ Some components are missing. The migration may not have been fully applied."
  echo "Please check the logs for more information."
fi 