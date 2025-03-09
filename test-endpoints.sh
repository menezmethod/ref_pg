#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Configuration
API_BASE_URL=${API_BASE_URL:-"http://localhost:8001/api"}
REDIRECT_BASE_URL=${REDIRECT_BASE_URL:-"http://localhost:8001/r"}
TIMEOUT=${TIMEOUT:-5}

# Function to make API requests
make_request() {
  local endpoint=$1
  local method=${2:-GET}
  local data=$3
  local header_str=""
  local content_type=""
  
  # Add content-type header if data is provided
  if [ -n "$data" ]; then
    content_type="-H 'Content-Type: application/json'"
  fi
  
  # Add headers
  if [ -n "$4" ]; then
    header_str="-H '$4'"
  fi
  
  # Construct the command
  local cmd="curl -s -X $method $content_type $header_str -m $TIMEOUT"
  
  # Add data if provided
  if [ -n "$data" ]; then
    cmd="$cmd -d '$data'"
  fi
  
  # Complete the URL
  cmd="$cmd '$endpoint'"
  
  # Execute the command
  echo -e "${BLUE}Running: $cmd${NC}"
  eval $cmd
  echo ""
}

# Function to report test results
report_test() {
  local test_name=$1
  local status=$2
  if [ "$status" -eq 0 ]; then
    echo -e "${GREEN}✓ $test_name: PASSED${NC}"
  else
    echo -e "${RED}✗ $test_name: FAILED${NC}"
  fi
}

echo -e "${BLUE}=== URL Shortener API Tests ===${NC}"
echo -e "${YELLOW}Using API base URL: $API_BASE_URL${NC}"

# Test 1: Get API Schema
echo -e "\n${YELLOW}Test 1: Get API Schema${NC}"
make_request "$API_BASE_URL/"
report_test "Get API Schema" $?

# Test 2: Create a short URL with quick_link function
echo -e "\n${YELLOW}Test 2: Create a short URL with quick_link function${NC}"
ORIGINAL_URL="https://example.com"
CUSTOM_ALIAS="test$(date +%s)" # Use timestamp to ensure uniqueness
RESPONSE=$(make_request "$API_BASE_URL/rpc/quick_link" "POST" '{"url":"'$ORIGINAL_URL'","alias":"'$CUSTOM_ALIAS'"}')
echo "$RESPONSE"
if echo "$RESPONSE" | grep -q "short_url"; then
  report_test "Create Short URL" 0
  # Extract the short_url from response
  SHORT_URL=$(echo "$RESPONSE" | grep -o '"short_url":"[^"]*' | cut -d'"' -f4)
  echo -e "${GREEN}Created Short URL: $SHORT_URL${NC}"
else
  report_test "Create Short URL" 1
fi

# Test 3: Test alternate create_short_link function
echo -e "\n${YELLOW}Test 3: Test alternate create_short_link function${NC}"
ORIGINAL_URL="https://example-alternate.com"
CUSTOM_ALIAS="alt$(date +%s)" # Use timestamp to ensure uniqueness
RESPONSE=$(make_request "$API_BASE_URL/rpc/create_short_link" "POST" '{"p_original_url":"'$ORIGINAL_URL'","p_custom_alias":"'$CUSTOM_ALIAS'"}')
echo "$RESPONSE"
if echo "$RESPONSE" | grep -q "success.*true"; then
  report_test "Create Short URL (Alternate)" 0
  # Extract the code from response if available
  CODE=$(echo "$RESPONSE" | grep -o '"code":"[^"]*' | cut -d'"' -f4)
  if [ -n "$CODE" ]; then
    echo -e "${GREEN}Created Short Code: $CODE${NC}"
  fi
else
  report_test "Create Short URL (Alternate)" 1
fi

# Test 4: Try to get the original URL for a short code
echo -e "\n${YELLOW}Test 4: Get Original URL${NC}"
if [ -n "$CUSTOM_ALIAS" ]; then
  RESPONSE=$(make_request "$API_BASE_URL/rpc/get_original_url" "POST" '{"p_code":"'$CUSTOM_ALIAS'"}')
  echo "$RESPONSE"
  if echo "$RESPONSE" | grep -q "$ORIGINAL_URL"; then
    report_test "Get Original URL" 0
  else
    report_test "Get Original URL" 1
  fi
else
  echo -e "${RED}Skipping - No short code available from previous test${NC}"
fi

# Test 5: Test the redirect endpoint
echo -e "\n${YELLOW}Test 5: Test redirect endpoint${NC}"
if [ -n "$CUSTOM_ALIAS" ]; then
  REDIRECT_URL="$REDIRECT_BASE_URL/$CUSTOM_ALIAS"
  echo -e "${BLUE}Testing redirect URL: $REDIRECT_URL${NC}"
  # Use -I to only get headers and follow redirects
  RESPONSE=$(curl -s -I -L -m $TIMEOUT "$REDIRECT_URL")
  echo "$RESPONSE"
  if echo "$RESPONSE" | grep -q "example"; then
    report_test "Redirect endpoint" 0
  else
    report_test "Redirect endpoint" 1
  fi
else
  echo -e "${RED}Skipping - No short code available from previous test${NC}"
fi

# Test 6: Test the test_create_link function
echo -e "\n${YELLOW}Test 6: Test the test_create_link function${NC}"
ORIGINAL_URL="https://example-test.com"
CUSTOM_ALIAS="tst$(date +%s)" # Use timestamp to ensure uniqueness
RESPONSE=$(make_request "$API_BASE_URL/rpc/test_create_link" "POST" '{"p_url":"'$ORIGINAL_URL'","p_alias":"'$CUSTOM_ALIAS'"}')
echo "$RESPONSE"
if echo "$RESPONSE" | grep -q "success.*true"; then
  report_test "Test Create Link" 0
else
  report_test "Test Create Link" 1
fi

echo -e "\n${BLUE}=== All tests completed ===${NC}" 