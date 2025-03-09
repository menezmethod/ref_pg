#!/bin/bash
# Database Diagnostic Script for URL Shortener
# This script helps diagnose issues with the PostgreSQL database setup

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-url_shortener}
DB_USER=${DB_USER:-postgres}
DB_PASSWORD=${DB_PASSWORD:-postgres}

# Print header
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}   URL Shortener Database Diagnostics   ${NC}"
echo -e "${BLUE}=========================================${NC}"
echo

# Function to run a query and return the result
run_query() {
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "$1"
}

# Check if we can connect to the database
echo -e "${YELLOW}Checking database connection...${NC}"
if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "SELECT 1" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Successfully connected to the database${NC}"
else
    echo -e "${RED}✗ Failed to connect to the database${NC}"
    echo -e "  Host: $DB_HOST"
    echo -e "  Port: $DB_PORT"
    echo -e "  Database: $DB_NAME"
    echo -e "  User: $DB_USER"
    echo -e "  Password: [hidden]"
    echo
    echo -e "${RED}Please check your database credentials and connection settings.${NC}"
    exit 1
fi

echo

# Check if migration_history table exists
echo -e "${YELLOW}Checking migration history...${NC}"
if run_query "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'migration_history')" | grep -q "t"; then
    echo -e "${GREEN}✓ Migration history table exists${NC}"
    
    # Show migration history
    echo
    echo -e "${BLUE}Migration History:${NC}"
    run_query "SELECT id, migration_name, applied_at, success FROM migration_history ORDER BY id"
else
    echo -e "${YELLOW}⚠ Migration history table does not exist${NC}"
    echo -e "  This suggests the verification script (999_verify_migration.sql) hasn't run yet."
fi

echo

# Check for required schemas
echo -e "${YELLOW}Checking required schemas...${NC}"
for schema in "api" "auth"; do
    if run_query "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '$schema')" | grep -q "t"; then
        echo -e "${GREEN}✓ Schema '$schema' exists${NC}"
    else
        echo -e "${RED}✗ Schema '$schema' is missing${NC}"
    fi
done

echo

# Check for required tables
echo -e "${YELLOW}Checking required tables...${NC}"
for table in "users" "urls" "short_links" "link_clicks" "analytics_events" "api_keys"; do
    if run_query "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = '$table')" | grep -q "t"; then
        echo -e "${GREEN}✓ Table '$table' exists${NC}"
        
        # Count rows in the table
        count=$(run_query "SELECT COUNT(*) FROM $table")
        echo -e "  Contains $count rows"
    else
        echo -e "${RED}✗ Table '$table' is missing${NC}"
    fi
done

echo

# Check for required roles
echo -e "${YELLOW}Checking required roles...${NC}"
for role in "anon" "authenticator"; do
    if run_query "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$role')" | grep -q "t"; then
        echo -e "${GREEN}✓ Role '$role' exists${NC}"
        
        # Check role permissions
        if [ "$role" = "authenticator" ]; then
            if run_query "SELECT rolcanlogin FROM pg_roles WHERE rolname = 'authenticator'" | grep -q "t"; then
                echo -e "  Role has LOGIN permission"
            else
                echo -e "${RED}  Role is missing LOGIN permission${NC}"
            fi
        fi
    else
        echo -e "${RED}✗ Role '$role' is missing${NC}"
    fi
done

echo

# Check for required functions
echo -e "${YELLOW}Checking key API functions...${NC}"
for func in "api.get_original_url" "api.create_short_link" "api.redirect_to_original_url"; do
    schema=$(echo $func | cut -d. -f1)
    name=$(echo $func | cut -d. -f2)
    
    if run_query "SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE p.proname = '$name' AND n.nspname = '$schema')" | grep -q "t"; then
        echo -e "${GREEN}✓ Function '$func' exists${NC}"
    else
        echo -e "${RED}✗ Function '$func' is missing${NC}"
    fi
done

echo

# Check PostgREST connection
echo -e "${YELLOW}Checking PostgREST connection...${NC}"
if curl -s http://postgrest:3000/ > /dev/null 2>&1; then
    echo -e "${GREEN}✓ PostgREST is responding${NC}"
else
    echo -e "${RED}✗ Cannot connect to PostgREST${NC}"
    echo -e "  This could be due to PostgREST not running or network issues."
fi

echo

# Check authenticator role connection
echo -e "${YELLOW}Testing authenticator role connection...${NC}"
if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U authenticator -d $DB_NAME -c "SELECT current_user" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Successfully connected as 'authenticator' role${NC}"
else
    echo -e "${RED}✗ Failed to connect as 'authenticator' role${NC}"
    echo -e "  This suggests an issue with the authenticator role or its password."
    echo -e "  Make sure the password matches what's in the PGRST_DB_URI environment variable."
fi

echo

# Summary
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}             Summary                     ${NC}"
echo -e "${BLUE}=========================================${NC}"
echo
echo -e "If you're experiencing issues, check the following:"
echo -e "1. Make sure all migrations have been applied"
echo -e "2. Verify the authenticator role has the correct password"
echo -e "3. Ensure all required schemas, tables, and functions exist"
echo -e "4. Check that PostgREST can connect to the database"
echo
echo -e "For more detailed diagnostics, you can run:"
echo -e "  PGPASSWORD=\$DB_PASSWORD psql -h \$DB_HOST -p \$DB_PORT -U \$DB_USER -d \$DB_NAME"
echo
echo -e "${BLUE}=========================================${NC}" 