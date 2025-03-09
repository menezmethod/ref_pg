#!/bin/bash
# Script to apply the API key authentication migration and test it

echo "Adding API key authentication to URL shortener service..."

# Check migration file exists
if [ ! -f migrations/003_api_key_authentication.sql ]; then
    echo "Error: Migration file not found!"
    exit 1
fi

# Copy migration file to Docker volume location
echo "Copying migration file to Docker volume..."
cp migrations/003_api_key_authentication.sql docker/postgres/.

# Force add the migration file to git
git add -f migrations/003_api_key_authentication.sql

# Apply the migration to the database
echo "Applying migration to the database..."
docker exec url_shortener_db psql -U postgres -d url_shortener -c "DROP FUNCTION IF EXISTS validate_api_key CASCADE;"
docker exec url_shortener_db psql -U postgres -d url_shortener -c "DROP FUNCTION IF EXISTS check_admin_permission CASCADE;"
docker exec url_shortener_db psql -U postgres -d url_shortener -c "DROP FUNCTION IF EXISTS pre_request CASCADE;"
docker exec url_shortener_db psql -U postgres -d url_shortener -c "DROP TABLE IF EXISTS api_keys CASCADE;"

docker cp migrations/003_api_key_authentication.sql url_shortener_db:/tmp/
MIGRATION_OUTPUT=$(docker exec url_shortener_db psql -U postgres -d url_shortener -f /tmp/003_api_key_authentication.sql)
echo "$MIGRATION_OUTPUT"

# Try to get the admin key from the migration output
MASTER_KEY=$(echo "$MIGRATION_OUTPUT" | grep -oP "Master admin key: \K[a-f0-9]+" || echo "")

# If we couldn't get the key from the output, query the database directly
if [ -z "$MASTER_KEY" ]; then
    echo "Retrieving master admin key from database..."
    MASTER_KEY=$(docker exec url_shortener_db psql -U postgres -d url_shortener -c "SELECT key FROM api_keys WHERE name = 'Master Admin Key'" | grep -v "key\|\-\-\-\|\(.*row" | tr -d ' ' || echo "")
fi

if [ -z "$MASTER_KEY" ]; then
    echo "Error: Could not retrieve master admin key!"
    exit 1
fi

echo "Master admin key: $MASTER_KEY"

# Check if we need to restart PostgREST to apply config changes
echo "Restarting PostgREST to apply configuration changes..."
docker-compose restart postgrest

echo "Waiting for PostgREST to be ready..."
sleep 5

# Test API key authentication
echo -e "\nTesting API key authentication...\n"

# Test creating a short URL with the master key
echo "Creating a short URL with the master key..."
curl -s -X POST "http://localhost:3001/rpc/create_short_link" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $MASTER_KEY" \
  -d '{"p_original_url": "https://example.com/api-key-test"}' | jq

# Generate a new API key for testing
echo -e "\nGenerating a new API key for testing..."
TEST_KEY=$(curl -s -X POST "http://localhost:3001/rpc/generate_api_key" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $MASTER_KEY" \
  -d '{"p_name": "Test Application", "p_is_admin": false}' | tr -d '"')

echo "New API key: $TEST_KEY"

# Test the new API key
echo -e "\nTesting the new API key..."
curl -s -X POST "http://localhost:3001/rpc/create_short_link" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $TEST_KEY" \
  -d '{"p_original_url": "https://example.com/new-api-key-test"}' | jq

# Test accessing admin function with non-admin key (should fail)
echo -e "\nTesting admin function with non-admin key (should fail)..."
curl -s -X POST "http://localhost:3001/rpc/generate_api_key" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $TEST_KEY" \
  -d '{"p_name": "Should Fail"}' | jq

# Test without API key (should fail)
echo -e "\nTesting without API key (should fail)..."
curl -s -X POST "http://localhost:3001/rpc/create_short_link" \
  -H "Content-Type: application/json" \
  -d '{"p_original_url": "https://example.com/no-api-key-test"}' | jq

echo -e "\nAPI key authentication testing completed!"
echo "You can now use the master admin key or the test key for authentication."
echo "Master admin key: $MASTER_KEY"
echo "Test API key: $TEST_KEY" 