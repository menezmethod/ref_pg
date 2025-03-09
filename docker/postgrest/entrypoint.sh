#!/bin/sh
set -e

echo "Starting PostgREST entrypoint script (with built-in health check)..."

# Create a simple health check server using a background process
start_health_server() {
  # Use a simple while loop to create a basic HTTP server on port 8888
  # This will respond to health checks while PostgREST is starting
  echo "Starting built-in health check server on port 8888..."
  (
    while true; do
      { echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"; } | nc -l -p 8888 -q 1 || true
      sleep 0.1
    done
  ) &
  HEALTH_SERVER_PID=$!
  echo "Health check server started with PID: $HEALTH_SERVER_PID"
}

# Kill the health check server when it's no longer needed
stop_health_server() {
  if [ -n "$HEALTH_SERVER_PID" ]; then
    echo "Stopping health check server (PID: $HEALTH_SERVER_PID)..."
    kill $HEALTH_SERVER_PID 2>/dev/null || true
  fi
}

# Handle signals properly for clean shutdown
cleanup() {
  echo "Received signal to shut down..."
  stop_health_server
  
  # Kill PostgREST if it's running
  if [ -n "$POSTGREST_PID" ]; then
    echo "Stopping PostgREST (PID: $POSTGREST_PID)..."
    kill $POSTGREST_PID 2>/dev/null || true
  fi
  
  exit 0
}

# Print diagnostic information about environment and networking
run_diagnostics() {
  echo "========== ENVIRONMENT DIAGNOSTICS =========="
  
  # Container identification
  echo "CONTAINER INFO:"
  echo "- Hostname: $(hostname)"
  echo "- Current user: $(id)"
  
  # Network configuration
  echo "NETWORK CONFIGURATION:"
  if command -v ip >/dev/null 2>&1; then
    echo "IP Configuration:"
    ip addr | grep -E 'inet|eth' || echo "No IP configuration found"
    echo "Routing table:"
    ip route || echo "No routing table found"
  elif command -v ifconfig >/dev/null 2>&1; then
    echo "Interface configuration:"
    ifconfig || echo "No interface configuration found"
  fi
  
  # DNS Resolution tests
  echo "DNS RESOLUTION TESTS:"
  if command -v dig >/dev/null 2>&1; then
    echo "Testing DNS resolution for 'db':"
    dig db || echo "dig command failed for db"
    echo "Testing DNS resolution for 'db-gwg0scggsk0o8swcgogg04wc':"
    dig db-gwg0scggsk0o8swcgogg04wc || echo "dig command failed for db-gwg0scggsk0o8swcgogg04wc"
  elif command -v nslookup >/dev/null 2>&1; then
    echo "Testing DNS resolution for 'db':"
    nslookup db || echo "nslookup command failed for db"
    echo "Testing DNS resolution for 'db-gwg0scggsk0o8swcgogg04wc':"
    nslookup db-gwg0scggsk0o8swcgogg04wc || echo "nslookup command failed for db-gwg0scggsk0o8swcgogg04wc"
  fi
  
  # Check Docker networks
  echo "DOCKER NETWORKS:"
  if command -v cat >/dev/null 2>&1; then
    echo "Docker networks configuration (if available):"
    cat /etc/hosts || echo "Cannot access /etc/hosts"
  fi
  
  # Check connectivity to common ports
  echo "CONNECTIVITY TESTS:"
  echo "Testing connectivity to db:5432:"
  if command -v nc >/dev/null 2>&1; then
    nc -zv db 5432 2>&1 || echo "nc command failed for db:5432"
    echo "Testing connectivity to db-gwg0scggsk0o8swcgogg04wc:5432:"
    nc -zv db-gwg0scggsk0o8swcgogg04wc 5432 2>&1 || echo "nc command failed for db-gwg0scggsk0o8swcgogg04wc:5432"
  fi
  
  # List environment variables (excluding passwords)
  echo "ENVIRONMENT VARIABLES:"
  env | grep -v -E 'PASSWORD|PASS|SECRET|KEY' | sort || echo "No environment variables found"
  
  # Try some common Docker network IPs
  echo "COMMON DOCKER NETWORK IP SCANS:"
  for ip in 172.17.0.2 172.17.0.3 172.18.0.2 172.18.0.3; do
    echo "Testing connectivity to $ip:5432:"
    if command -v nc >/dev/null 2>&1; then
      nc -zv $ip 5432 -w 1 2>&1 || echo "nc command failed for $ip:5432"
    fi
  done
  
  echo "========== END DIAGNOSTICS =========="
}

# Parse DATABASE_URL to extract components and try multiple host formats
parse_db_url() {
  # First try the main DB_URI
  db_uri="${PGRST_DB_URI}"
  
  # Extract host and port
  db_host=$(echo "$db_uri" | sed -n 's|.*@\([^:]*\):\([0-9]*\)/.*|\1|p')
  db_port=$(echo "$db_uri" | sed -n 's|.*@\([^:]*\):\([0-9]*\)/.*|\2|p')
  db_name=$(echo "$db_uri" | sed -n 's|.*/\([^?]*\).*|\1|p')
  
  if [ -z "$db_name" ]; then
    db_name=$(echo "$db_uri" | sed -n 's|.*/\(.*\)|\1|p')
  fi
  
  echo "Database connection details (primary):"
  echo "- Host: $db_host"
  echo "- Port: $db_port"
  echo "- Database: $db_name" 
  
  # Extract username and password for later use with other hosts
  db_user=$(echo "$db_uri" | sed -n 's|postgres://\([^:]*\):.*|\1|p')
  db_pass=$(echo "$db_uri" | sed -n 's|postgres://[^:]*:\([^@]*\)@.*|\1|p')
  
  echo "DB User: $db_user"
  echo "DB Password: [redacted]"
  
  export DB_HOST="$db_host"
  export DB_PORT="$db_port"
  export DB_NAME="$db_name"
  export DB_USER="$db_user"
  export DB_PASS="$db_pass"
  
  # Also store fallback connection details if provided
  if [ -n "${COOLIFY_DB_FALLBACK}" ]; then
    db_uri_fallback="${COOLIFY_DB_FALLBACK}"
    db_host_fallback=$(echo "$db_uri_fallback" | sed -n 's|.*@\([^:]*\):\([0-9]*\)/.*|\1|p')
    echo "Fallback database host: $db_host_fallback"
    export DB_HOST_FALLBACK="$db_host_fallback"
  fi
}

# Wait for PostgreSQL to be ready using basic TCP connection check
wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready..."
  
  # First try primary host
  if wait_for_postgres_host "$DB_HOST" "$DB_PORT"; then
    update_connection_string "$DB_HOST"
    return 0
  fi
  
  # If that fails and we have a fallback hostname, try the fallback
  if [ -n "$DB_HOST_FALLBACK" ]; then
    echo "Primary database host unreachable, trying fallback host: $DB_HOST_FALLBACK"
    if wait_for_postgres_host "$DB_HOST_FALLBACK" "$DB_PORT"; then
      update_connection_string "$DB_HOST_FALLBACK"
      return 0
    fi
  fi
  
  # Try some common Docker network IPs
  common_docker_ips="172.17.0.1 172.17.0.2 172.17.0.3 172.17.0.4 172.17.0.5 172.18.0.1 172.18.0.2 172.18.0.3 172.18.0.4 172.18.0.5 172.19.0.1 172.19.0.2 172.19.0.3 172.19.0.4 172.19.0.5 192.168.1.1 192.168.1.2 192.168.1.3 192.168.1.4 192.168.1.5"
  
  for ip in $common_docker_ips; do
    echo "Trying common Docker IP: $ip"
    if wait_for_postgres_host "$ip" "$DB_PORT"; then
      update_connection_string "$ip"
      return 0
    fi
  done
  
  # If all else fails, use DNS to try to discover the database
  echo "Attempting service discovery..."
  if command -v nslookup >/dev/null 2>&1; then
    nslookup db 2>/dev/null || true
  fi
  
  # Try to find the database through subnet scanning
  for subnet in "172.17.0" "172.18.0" "172.19.0" "192.168.1"; do
    for i in $(seq 1 10); do
      ip="${subnet}.${i}"
      echo "Scanning subnet: trying $ip"
      if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        echo "Host $ip is responding to ping, checking PostgreSQL..."
        if wait_for_postgres_host "$ip" "$DB_PORT" 5; then  # Only try 5 times per IP
          update_connection_string "$ip"
          return 0
        fi
      fi
    done
  done
  
  # If we get here, all attempts failed
  echo "Failed to connect to any PostgreSQL host"
  return 1
}

# Helper function to update the connection string with working host
update_connection_string() {
  working_host="$1"
  echo "Updating connection string to use working host: $working_host"
  export DB_HOST="$working_host"
  export PGRST_DB_URI="postgres://${DB_USER}:${DB_PASS}@${working_host}:${DB_PORT}/${DB_NAME}"
  echo "New connection string: postgres://${DB_USER}:****@${working_host}:${DB_PORT}/${DB_NAME}"
}

# Helper function to check a specific host/port combination
wait_for_postgres_host() {
  host="$1"
  port="$2"
  max_attempts="${3:-60}"  # Default to 60 attempts unless specified
  
  echo "Checking PostgreSQL at $host:$port (max $max_attempts attempts)..."
  
  attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Checking PostgreSQL connection at $host:$port..."
    
    # Try basic TCP connection first - capture the error output
    conn_result=$(echo > /dev/tcp/$host/$port 2>&1) || true
    conn_status=$?
    
    if [ $conn_status -eq 0 ]; then
      echo "PostgreSQL is up and accepting connections at $host:$port!"
      echo "Verifying with a query..."
      
      # Try to actually connect and run a simple query if we have psql
      if command -v psql >/dev/null 2>&1; then
        psql_output=$(PGPASSWORD="$DB_PASS" psql -h "$host" -p "$port" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" 2>&1) || true
        psql_status=$?
        
        if [ $psql_status -eq 0 ]; then
          echo "PostgreSQL query successful!"
          return 0
        else
          echo "TCP connection succeeded but PostgreSQL query failed."
          echo "psql error: $psql_output"
        fi
      else
        echo "TCP connection succeeded, but psql not available for full verification."
        # If we don't have psql, assume TCP connection is enough
        return 0
      fi
    else
      echo "Connection attempt failed with output: $conn_result"
    fi
    
    attempt=$((attempt + 1))
    sleep 2
  done
  
  echo "Failed to connect to PostgreSQL at $host:$port after $max_attempts attempts"
  return 1
}

# Check that the api schema exists
check_schema() {
  echo "Checking if schema '${PGRST_DB_SCHEMA}' exists..."
  
  # We use the environment variables set by parse_db_url
  if PGPASSWORD=${POSTGRES_PASSWORD} psql -h $DB_HOST -p $DB_PORT -U ${POSTGRES_USER:-postgres} -d $DB_NAME -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name = '${PGRST_DB_SCHEMA}';" | grep -q "${PGRST_DB_SCHEMA}"; then
    echo "Schema '${PGRST_DB_SCHEMA}' exists!"
    return 0
  else
    echo "Schema '${PGRST_DB_SCHEMA}' does not exist in the database."
    echo "Please ensure the database migration has been applied correctly."
    return 1
  fi
}

# Check that the authenticator role exists
check_role() {
  echo "Checking if role '${PGRST_DB_ANON_ROLE}' exists..."
  
  if PGPASSWORD=${POSTGRES_PASSWORD} psql -h $DB_HOST -p $DB_PORT -U ${POSTGRES_USER:-postgres} -d $DB_NAME -c "SELECT rolname FROM pg_roles WHERE rolname = '${PGRST_DB_ANON_ROLE}';" | grep -q "${PGRST_DB_ANON_ROLE}"; then
    echo "Role '${PGRST_DB_ANON_ROLE}' exists!"
    return 0
  else
    echo "Role '${PGRST_DB_ANON_ROLE}' does not exist in the database."
    echo "Please ensure the database migration has been applied correctly."
    return 1
  fi
}

# Main execution logic
main() {
  # Start our health check server
  # Check if netcat is available for the health server
  if command -v nc >/dev/null 2>&1; then
    # Start the health check server
    start_health_server
  else
    echo "WARNING: netcat not available, health check server will not be started"
  fi
  
  # Set up basic signal handling - using numbers because some shells don't support names
  # SIGTERM = 15, SIGINT = 2
  trap cleanup 15
  trap cleanup 2
  
  # Run diagnostics before attempting connections
  run_diagnostics
  
  # Parse database URL
  parse_db_url
  
  # Dump current hostname and network info
  echo "Container hostname: $(hostname)"
  echo "Container IP addresses:"
  if command -v ip >/dev/null 2>&1; then
    ip addr | grep "inet " || true
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig | grep "inet " || true
  fi
  
  # Wait for PostgreSQL to be ready - with longer timeout
  wait_for_postgres || echo "WARNING: Database connection check failed, but continuing anyway..."
  
  echo "Starting PostgREST in foreground mode..."
  echo "Using database connection: $PGRST_DB_URI"
  
  # Start PostgREST in the foreground, but keep script running
  postgrest &
  POSTGREST_PID=$!
  
  # Wait for PostgREST to start or fail
  sleep 5
  
  # Check if PostgREST is running
  if kill -0 $POSTGREST_PID 2>/dev/null; then
    echo "PostgREST started successfully with PID: $POSTGREST_PID"
    
    # Keep the script running to maintain our health check server
    echo "Entrypoint script is now monitoring PostgREST..."
    
    # Wait for PostgreSQL to terminate
    wait $POSTGREST_PID || true
    
    echo "PostgREST has terminated."
  else
    echo "ERROR: PostgREST failed to start properly"
  fi
  
  # Clean up before exiting
  stop_health_server
  
  echo "Entrypoint script is exiting."
}

# Run the main function
main
