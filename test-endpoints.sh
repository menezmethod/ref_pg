#!/bin/bash
set -e

# Text colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Configuration
API_HOST=${API_HOST:-localhost:8001}
MASTER_PASSWORD=${MASTER_PASSWORD:-Churnistic2025!}

# Function to print a header
print_header() {
  echo -e "\n${YELLOW}==== $1 ====${NC}"
}

# Function to check if the services are up
wait_for_services() {
  print_header "Checking if services are up"
  
  # Try up to 10 times (10 seconds)
  max_attempts=10  # Reduced from 30 to 10
  attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Checking if the API service is available..."
    
    if curl -s "http://$API_HOST/health" > /dev/null; then
      echo -e "${GREEN}API service is up!${NC}"
      return 0
    fi
    
    attempt=$((attempt + 1))
    sleep 1
  done
  
  echo -e "${RED}Failed to connect to API service after $max_attempts attempts${NC}"
  return 1
}

# Function to test an API endpoint
test_endpoint() {
  local endpoint=$1
  local method=${2:-POST}
  local data=$3
  local description=$4
  local expected_status=${5:-200}
  
  echo -e "\n${YELLOW}Testing ${method} ${endpoint}${NC} - ${description}"
  
  # Build the curl command based on whether data is provided
  if [ -n "$data" ]; then
    response=$(curl -s -X "${method}" "http://${API_HOST}${endpoint}" \
      -H "Content-Type: application/json" \
      -d "${data}" \
      -w "\n%{http_code}")
  else
    response=$(curl -s -X "${method}" "http://${API_HOST}${endpoint}" \
      -w "\n%{http_code}")
  fi
  
  # Extract HTTP status code
  http_code=$(echo "$response" | tail -n1)
  
  # Extract response body (remove the last line which is the status code)
  body=$(echo "$response" | sed '$d')
  
  # Check if the status code is as expected
  if [ "$http_code" = "$expected_status" ]; then
    echo -e "${GREEN}✓ Success (Status: $http_code)${NC}"
    echo "Response: $body"
    echo "$body" # Return the response body for further processing
  else
    echo -e "${RED}✗ Failed (Status: $http_code, Expected: $expected_status)${NC}"
    echo "Response: $body"
    return 1
  fi
}

# Main test sequence
main() {
  print_header "URL Shortener API Test Script"
  
  # Wait for services to be up
  wait_for_services || { echo -e "${RED}Services not available, exiting.${NC}"; exit 1; }
  
  # Test 1: Get API Key
  print_header "1. Getting an API Key"
  api_key_response=$(test_endpoint "/api/get_api_key" "POST" "{\"p_password\": \"$MASTER_PASSWORD\"}" "Get API Key")
  api_key=$(echo "$api_key_response" | grep -o '"key":"[^"]*' | grep -o '[^"]*$')
  
  if [ -n "$api_key" ]; then
    echo -e "${GREEN}Successfully obtained API key: $api_key${NC}"
  else
    echo -e "${RED}Failed to extract API key from response${NC}"
    exit 1
  fi
  
  # Test 2: Create a short URL
  print_header "2. Creating a short URL"
  short_url_response=$(test_endpoint "/api/create_short_link" "POST" "{\"p_original_url\": \"https://example.com\"}" "Create Short URL")
  short_code=$(echo "$short_url_response" | grep -o '"code":"[^"]*' | grep -o '[^"]*$')
  
  if [ -n "$short_code" ]; then
    echo -e "${GREEN}Successfully created short URL with code: $short_code${NC}"
  else
    echo -e "${RED}Failed to extract short code from response${NC}"
    exit 1
  fi
  
  # Test 3: Create a short URL with custom alias
  print_header "3. Creating a short URL with custom alias"
  custom_alias="test-alias-$(date +%s)"
  custom_url_response=$(test_endpoint "/api/create_short_link" "POST" "{\"p_original_url\": \"https://example.org\", \"p_custom_alias\": \"$custom_alias\"}" "Create Short URL with Custom Alias")
  
  if echo "$custom_url_response" | grep -q "$custom_alias"; then
    echo -e "${GREEN}Successfully created short URL with custom alias: $custom_alias${NC}"
  else
    echo -e "${RED}Failed to create short URL with custom alias${NC}"
    exit 1
  fi
  
  # Test 4: Quick link creation (Admin)
  print_header "4. Creating a quick link (Admin)"
  quick_link_response=$(test_endpoint "/api/quick_link" "POST" "{\"p_url\": \"https://example.net\", \"p_password\": \"$MASTER_PASSWORD\"}" "Create Quick Link")
  quick_code=$(echo "$quick_link_response" | grep -o '"code":"[^"]*' | grep -o '[^"]*$')
  
  if [ -n "$quick_code" ]; then
    echo -e "${GREEN}Successfully created quick link with code: $quick_code${NC}"
  else
    echo -e "${RED}Failed to extract quick link code from response${NC}"
    exit 1
  fi
  
  # Test 5: Test redirection for the short URL
  print_header "5. Testing redirection for short URL"
  redirect_response=$(curl -s -I "http://$API_HOST/$short_code" | head -n 1)
  
  if echo "$redirect_response" | grep -q "302"; then
    echo -e "${GREEN}Redirection works correctly for short URL${NC}"
  else
    echo -e "${RED}Redirection failed for short URL${NC}"
    echo "Response: $redirect_response"
    exit 1
  fi
  
  # Test 6: Test redirection for custom alias
  print_header "6. Testing redirection for custom alias"
  redirect_response=$(curl -s -I "http://$API_HOST/$custom_alias" | head -n 1)
  
  if echo "$redirect_response" | grep -q "302"; then
    echo -e "${GREEN}Redirection works correctly for custom alias${NC}"
  else
    echo -e "${RED}Redirection failed for custom alias${NC}"
    echo "Response: $redirect_response"
    exit 1
  fi
  
  print_header "All tests completed successfully!"
  echo -e "${GREEN}✓ The URL shortener service is working as expected.${NC}"
}

# Run the tests
main 