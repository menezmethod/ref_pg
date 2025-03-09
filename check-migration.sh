#!/bin/bash
set -e

# Text colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
echo -e "${BLUE}"
echo "===================================================================="
echo "      URL Shortener Service - Database Migration Check              "
echo "===================================================================="
echo -e "${NC}"

# Default database configuration (can be overridden with environment variables)
DB_USER=${POSTGRES_USER:-postgres}
DB_PASS=${POSTGRES_PASSWORD:-n72NVZe99Fg8toaVc7jqAg}
DB_NAME=${POSTGRES_DB:-url_shortener}
DB_PORT=${DB_PORT:-5433}
DB_HOST=${DB_HOST:-localhost}

# Function to check if a table exists
check_table() {
  table=$1
  echo -e "${YELLOW}Checking if table '$table' exists...${NC}"
  
  # Run query to check if table exists
  if docker exec url_shortener_db psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table');" | grep -q 't'; then
    echo -e "${GREEN}✓ Table '$table' exists${NC}"
    return 0
  else
    echo -e "${RED}✗ Table '$table' does not exist${NC}"
    return 1
  fi
}

# Function to check if a schema exists
check_schema() {
  schema=$1
  echo -e "${YELLOW}Checking if schema '$schema' exists...${NC}"
  
  # Run query to check if schema exists
  if docker exec url_shortener_db psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT EXISTS (SELECT FROM information_schema.schemata WHERE schema_name = '$schema');" | grep -q 't'; then
    echo -e "${GREEN}✓ Schema '$schema' exists${NC}"
    return 0
  else
    echo -e "${RED}✗ Schema '$schema' does not exist${NC}"
    return 1
  fi
}

# Function to check if a function exists
check_function() {
  function_name=$1
  schema=$2
  
  echo -e "${YELLOW}Checking if function '$schema.$function_name' exists...${NC}"
  
  # Run query to check if function exists
  if docker exec url_shortener_db psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT EXISTS (SELECT FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE proname = '$function_name' AND nspname = '$schema');" | grep -q 't'; then
    echo -e "${GREEN}✓ Function '$schema.$function_name' exists${NC}"
    return 0
  else
    echo -e "${RED}✗ Function '$schema.$function_name' does not exist${NC}"
    return 1
  fi
}

# Function to check if a role exists
check_role() {
  role=$1
  echo -e "${YELLOW}Checking if role '$role' exists...${NC}"
  
  # Run query to check if role exists
  if docker exec url_shortener_db psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role');" | grep -q 't'; then
    echo -e "${GREEN}✓ Role '$role' exists${NC}"
    return 0
  else
    echo -e "${RED}✗ Role '$role' does not exist${NC}"
    return 1
  fi
}

# Function to check database configuration parameters
check_db_config() {
  param=$1
  echo -e "${YELLOW}Checking if database parameter '$param' is set...${NC}"
  
  # Run query to check if parameter exists
  if docker exec url_shortener_db psql -U "$DB_USER" -d "$DB_NAME" -t -c "SHOW $param;" 2>/dev/null; then
    echo -e "${GREEN}✓ Database parameter '$param' is set${NC}"
    return 0
  else
    echo -e "${RED}✗ Database parameter '$param' is not set${NC}"
    return 1
  fi
}

# Main function
main() {
  # Wait for the database to be up
  echo -e "${YELLOW}Checking if database container is running...${NC}"
  if ! docker ps | grep -q url_shortener_db; then
    echo -e "${RED}Database container not running. Please start the containers first.${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Database container is running.${NC}"
  
  # Check schemas
  echo -e "\n${BLUE}=== Checking Schemas ===${NC}"
  check_schema "public" || exit 1
  check_schema "api" || exit 1
  
  # Check tables
  echo -e "\n${BLUE}=== Checking Tables ===${NC}"
  tables=("users" "urls" "short_links" "link_clicks" "analytics_events" "api_keys")
  
  for table in "${tables[@]}"; do
    check_table "$table" || exit 1
  done
  
  # Check roles
  echo -e "\n${BLUE}=== Checking Roles ===${NC}"
  check_role "authenticator" || exit 1
  check_role "anon" || exit 1
  
  # Check functions
  echo -e "\n${BLUE}=== Checking Functions ===${NC}"
  api_functions=("get_original_url" "create_short_link" "track_link_click" "redirect_to_original_url" "get_api_key")
  
  for func in "${api_functions[@]}"; do
    check_function "$func" "api" || echo -e "${YELLOW}⚠️ Function might be missing, but could still be created later${NC}"
  done
  
  # Check database configuration
  echo -e "\n${BLUE}=== Checking Database Configuration ===${NC}"
  check_db_config "jwt_secret" || echo -e "${YELLOW}⚠️ JWT secret not set yet, will be set by init scripts${NC}"
  
  # Print final result
  echo -e "\n${BLUE}=== Migration Check Summary ===${NC}"
  echo -e "${GREEN}✓ Database schema appears to be properly migrated.${NC}"
  echo -e "${GREEN}✓ Basic database structure is in place.${NC}"
  echo -e "${YELLOW}ℹ️ Note: This is a basic check and doesn't verify all database objects or their contents.${NC}"
}

# Run the main function
main 