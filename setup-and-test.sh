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
echo "       URL Shortener Service - Setup and Test Script                "
echo "===================================================================="
echo -e "${NC}"

# Make the script files executable
make_scripts_executable() {
  echo -e "${YELLOW}Making scripts executable...${NC}"
  chmod +x sql/init/init-db.sh
  chmod +x sql/init/update-pg-hba.sh
  chmod +x test-endpoints.sh
  echo -e "${GREEN}Scripts are now executable.${NC}"
}

# Start Docker containers
start_containers() {
  echo -e "${YELLOW}Starting Docker containers...${NC}"
  docker-compose down --volumes
  docker-compose up -d
  echo -e "${GREEN}Docker containers are starting...${NC}"
}

# Check if containers are running and healthy
check_containers() {
  echo -e "${YELLOW}Checking container status...${NC}"
  max_attempts=12  # Reduced from 30 to 12 (1 minute total with 5-second intervals)
  attempt=1
  
  # List of services to check
  services=("url_shortener_db" "url_shortener_api" "url_shortener_redirect")
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Checking container status..."
    
    all_healthy=true
    for service in "${services[@]}"; do
      status=$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null || echo "not_found")
      health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}N/A{{end}}' "$service" 2>/dev/null || echo "not_found")
      
      echo "$service: Status=$status, Health=$health"
      
      # If any container is not running or not healthy, set flag to false
      if [ "$status" != "running" ] || ([ "$health" != "healthy" ] && [ "$health" != "N/A" ]); then
        all_healthy=false
      fi
    done
    
    if $all_healthy; then
      echo -e "${GREEN}All containers are running and healthy!${NC}"
      return 0
    fi
    
    attempt=$((attempt + 1))
    sleep 5
  done
  
  echo -e "${RED}Containers are not all running and healthy after $max_attempts attempts${NC}"
  docker-compose logs
  return 1
}

# Run the tests
run_tests() {
  echo -e "${YELLOW}Running API tests...${NC}"
  ./test-endpoints.sh
}

# Main execution
main() {
  # Create necessary directories if they don't exist
  mkdir -p sql/init
  
  # Make scripts executable
  make_scripts_executable
  
  # Start containers
  start_containers
  
  # Wait for containers to be healthy
  echo -e "${YELLOW}Waiting for containers to be ready (this may take a minute)...${NC}"
  if check_containers; then
    # Run tests
    run_tests
  else
    echo -e "${RED}Setup failed. Please check the Docker logs above for more information.${NC}"
    exit 1
  fi
}

# Run the main function
main 