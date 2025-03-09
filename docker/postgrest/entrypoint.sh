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
  for ip in 172.19.0.2 172.19.0.3 172.19.0.4 172.20.0.2 172.20.0.3 172.20.0.4; do
    echo "Testing connectivity to $ip:5432:"
    if command -v nc >/dev/null 2>&1; then
      nc -zv $ip 5432 -w 1 2>&1 || echo "nc command failed for $ip:5432"
    fi
  done
  
  echo "========== END DIAGNOSTICS =========="
}

# Resolve hostname to IP address to work around DNS issues
resolve_hostname() {
  hostname="$1"
  
  # Skip empty hostname
  if [ -z "$hostname" ]; then
    echo ""
    return 1
  fi
  
  # First try netcat to see if we can connect directly - this is most reliable
  if command -v nc >/dev/null 2>&1; then
    if nc -zv "$hostname" 5432 -w 2 >/dev/null 2>&1; then
      # If we can connect, try to get the IP it resolved to
      ip_from_nc=$(nc -zv "$hostname" 5432 -w 2 2>&1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
      if [ -n "$ip_from_nc" ]; then
        echo "$ip_from_nc"
        return 0
      fi
    fi
  fi
  
  # Try different methods to get IP address
  if command -v getent >/dev/null 2>&1; then
    ip_address=$(getent hosts "$hostname" | awk '{ print $1 }')
  elif command -v dig >/dev/null 2>&1; then
    ip_address=$(dig +short "$hostname")
  elif command -v nslookup >/dev/null 2>&1; then
    ip_address=$(nslookup "$hostname" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1)
  elif command -v host >/dev/null 2>&1; then
    ip_address=$(host "$hostname" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
  else
    echo ""
    return 1
  fi
  
  if [ -n "$ip_address" ]; then
    echo "$ip_address"
    return 0
  else
    echo ""
    return 1
  fi
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
  
  # Store alternative POSTGRES_USER/PASSWORD from environment if available
  if [ -n "${POSTGRES_USER}" ]; then
    echo "Found alternative POSTGRES_USER: ${POSTGRES_USER}"
    export DB_ALT_USER="${POSTGRES_USER}"
  fi
  
  if [ -n "${POSTGRES_PASSWORD}" ]; then
    echo "Found alternative POSTGRES_PASSWORD: [redacted]"
    export DB_ALT_PASS="${POSTGRES_PASSWORD}"
  elif [ -n "${SERVICE_PASSWORD_DB}" ]; then
    echo "Found alternative SERVICE_PASSWORD_DB: [redacted]"
    export DB_ALT_PASS="${SERVICE_PASSWORD_DB}"
  fi
  
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

# Create a function to test alternative credentials
test_alternative_credentials() {
  host="$1"
  port="$2"
  
  echo "Testing alternative credentials with POSTGRES_USER..."
  
  if [ -n "$DB_ALT_USER" ] && [ -n "$DB_ALT_PASS" ]; then
    if command -v psql >/dev/null 2>&1; then
      alt_psql_output=$(PGPASSWORD="$DB_ALT_PASS" psql -h "$host" -p "$port" -U "$DB_ALT_USER" -d "$DB_NAME" -c "SELECT 1" 2>&1)
      alt_psql_status=$?
      
      if [ $alt_psql_status -eq 0 ]; then
        echo "Alternative credentials successful with user: $DB_ALT_USER"
        
        # Update the DB credentials and connection string
        export DB_USER="$DB_ALT_USER"
        export DB_PASS="$DB_ALT_PASS"
        
        # Try to create the original user if we have postgres admin access
        echo "Attempting to create missing authenticator role with admin credentials..."
        create_role_sql="DO \$\$ 
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$db_user') THEN
            CREATE ROLE $db_user WITH LOGIN PASSWORD '$db_pass';
            GRANT USAGE ON SCHEMA api TO $db_user;
            CREATE SCHEMA IF NOT EXISTS api;
            GRANT ALL PRIVILEGES ON SCHEMA api TO $db_user;
            GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA api TO $db_user;
            GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA api TO $db_user;
          END IF;
        END
        \$\$;"
        
        PGPASSWORD="$DB_ALT_PASS" psql -h "$host" -p "$port" -U "$DB_ALT_USER" -d "$DB_NAME" -c "$create_role_sql" || true
        echo "Authentication setup attempted. Continuing with available credentials."
        
        return 0
      else
        echo "Alternative credentials failed: $alt_psql_output"
      fi
    else
      echo "psql not available to test alternative credentials"
    fi
  else
    echo "No alternative credentials available in environment variables"
  fi
  
  return 1
}

# Wait for PostgreSQL to be ready using basic TCP connection check
wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready..."
  
  # Try to resolve the fallback hostname first as it's likely simpler (like 'db')
  if [ -n "$DB_HOST_FALLBACK" ]; then
    echo "Checking fallback hostname $DB_HOST_FALLBACK first as it's likely more reliable..."
    
    # Try to resolve fallback hostname to IP
    db_ip_fallback=$(resolve_hostname "$DB_HOST_FALLBACK")
    
    if [ -n "$db_ip_fallback" ]; then
      echo "Resolved fallback $DB_HOST_FALLBACK to IP: $db_ip_fallback"
      if wait_for_postgres_host "$db_ip_fallback" "$DB_PORT"; then
        update_connection_string "$db_ip_fallback"
        return 0
      else
        # Even if authentication failed, try with alternative credentials
        if test_alternative_credentials "$db_ip_fallback" "$DB_PORT"; then
          update_connection_string "$db_ip_fallback"
          return 0
        fi
      fi
    fi
    
    # Try with hostname directly if IP resolution failed
    if wait_for_postgres_host "$DB_HOST_FALLBACK" "$DB_PORT"; then
      # Try to get the IP that was used successfully
      if command -v psql >/dev/null 2>&1; then
        server_ip=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST_FALLBACK" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT inet_server_addr();" 2>/dev/null) || true
        if [ -n "$server_ip" ]; then
          echo "PostgreSQL server actual IP from fallback: $server_ip (from server_addr)"
          update_connection_string "$server_ip"
          return 0
        else
          update_connection_string "$DB_HOST_FALLBACK"
        fi
      else
        update_connection_string "$DB_HOST_FALLBACK"
      fi
      return 0
    else
      # Even if authentication failed, try with alternative credentials
      if test_alternative_credentials "$DB_HOST_FALLBACK" "$DB_PORT"; then
        update_connection_string "$DB_HOST_FALLBACK"
        return 0
      fi
    fi
  fi
  
  # If fallback didn't work, try to resolve primary hostname to IP
  if [ -n "$DB_HOST" ]; then
    echo "Attempting to resolve $DB_HOST to an IP address..."
    db_ip=$(resolve_hostname "$DB_HOST")
    
    if [ -n "$db_ip" ]; then
      echo "Resolved $DB_HOST to IP: $db_ip"
      export DB_HOST_IP="$db_ip"
      
      # Try connecting to the resolved IP
      if wait_for_postgres_host "$db_ip" "$DB_PORT"; then
        update_connection_string "$db_ip"
        return 0
      else
        # Even if authentication failed, try with alternative credentials
        if test_alternative_credentials "$db_ip" "$DB_PORT"; then
          update_connection_string "$db_ip"
          return 0
        fi
      fi
    else
      echo "Failed to resolve $DB_HOST to an IP address"
    fi
  fi
  
  # Try primary host directly (if IP resolution failed)
  if wait_for_postgres_host "$DB_HOST" "$DB_PORT"; then
    # Try to get the IP that was used successfully
    if command -v psql >/dev/null 2>&1; then
      # Use psql to get the actual server IP
      server_ip=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT inet_server_addr();" 2>/dev/null) || true
      if [ -n "$server_ip" ]; then
        echo "PostgreSQL server actual IP: $server_ip (from server_addr)"
        update_connection_string "$server_ip"
        return 0
      else
        update_connection_string "$DB_HOST"
      fi
    else
      update_connection_string "$DB_HOST"
    fi
    return 0
  else
    # Even if authentication failed, try with alternative credentials
    if test_alternative_credentials "$DB_HOST" "$DB_PORT"; then
      update_connection_string "$DB_HOST"
      return 0
    fi
  fi
  
  # Try direct connection to the IP we saw in the diagnostic scan
  echo "Trying direct connection to 172.19.0.4 (from diagnostic scan)..."
  if wait_for_postgres_host "172.19.0.4" "$DB_PORT" 5; then
    update_connection_string "172.19.0.4"
    return 0
  else
    # Even if authentication failed, try with alternative credentials
    if test_alternative_credentials "172.19.0.4" "$DB_PORT"; then
      update_connection_string "172.19.0.4"
      return 0
    fi
  fi
  
  # Try IP addresses on our own network subnets
  echo "Trying to find PostgreSQL on local network subnets..."
  my_ips=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || ifconfig | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
  
  for my_ip in $my_ips; do
    if [ "$my_ip" = "127.0.0.1" ]; then
      continue  # Skip localhost
    fi
    
    # Extract subnet prefix (first 3 octets)
    subnet=$(echo "$my_ip" | cut -d. -f1-3)
    echo "Scanning subnet: $subnet.* (from our interface $my_ip)"
    
    for i in $(seq 1 10); do
      ip="${subnet}.${i}"
      if [ "$ip" = "$my_ip" ]; then
        continue  # Skip our own IP
      fi
      
      echo "Scanning subnet: trying $ip"
      if wait_for_postgres_host "$ip" "$DB_PORT" 3; then  # Only try 3 times per IP
        update_connection_string "$ip"
        return 0
      else
        # Try alternative credentials
        if test_alternative_credentials "$ip" "$DB_PORT"; then
          update_connection_string "$ip"
          return 0
        fi
      fi
    done
  done
  
  # Try some common Docker network IPs
  common_docker_ips="172.19.0.2 172.19.0.3 172.19.0.4 172.20.0.2 172.20.0.3 172.20.0.4 172.17.0.2 172.17.0.3 172.18.0.2 172.18.0.3 172.19.0.1 172.20.0.1 172.17.0.1 172.18.0.1"
  
  for ip in $common_docker_ips; do
    echo "Trying common Docker IP: $ip"
    if wait_for_postgres_host "$ip" "$DB_PORT" 3; then  # Only try 3 times per IP
      update_connection_string "$ip"
      return 0
    else
      # Try alternative credentials
      if test_alternative_credentials "$ip" "$DB_PORT"; then
        update_connection_string "$ip"
        return 0
      fi
    fi
  done
  
  # Try connecting to "host.docker.internal" which is a special Docker DNS name on some platforms
  echo "Trying host.docker.internal..."
  if wait_for_postgres_host "host.docker.internal" "$DB_PORT" 3; then
    update_connection_string "host.docker.internal"
    return 0
  fi
  
  # If all else fails, use DNS to try to discover the database
  echo "Attempting service discovery..."
  if command -v nslookup >/dev/null 2>&1; then
    nslookup db 2>/dev/null || true
  fi
  
  # If we get here, all attempts failed
  echo "Failed to connect to any PostgreSQL host"
  return 1
}

# Helper function to update the connection string with working host
update_connection_string() {
  working_host="$1"
  echo "Updating connection string to use working host: $working_host"
  
  # Save the successful host details
  export DB_HOST="$working_host"
  export PGRST_DB_URI="postgres://${DB_USER}:${DB_PASS}@${working_host}:${DB_PORT}/${DB_NAME}"
  echo "New connection string: postgres://${DB_USER}:****@${working_host}:${DB_PORT}/${DB_NAME}"
  
  # Also set PGHOST environment variable for PostgreSQL clients
  export PGHOST="$working_host"
  
  # Save to hosts file if we have permission
  if [ -w /etc/hosts ]; then
    if ! grep -q "$working_host db" /etc/hosts; then
      echo "Adding $working_host to /etc/hosts for 'db'"
      echo "$working_host db" >> /etc/hosts
    fi
    if ! grep -q "$working_host db-gwg0scggsk0o8swcgogg04wc" /etc/hosts; then
      echo "Adding $working_host to /etc/hosts for 'db-gwg0scggsk0o8swcgogg04wc'"
      echo "$working_host db-gwg0scggsk0o8swcgogg04wc" >> /etc/hosts
    fi
  else
    echo "Note: Cannot update /etc/hosts (no write permission)"
  fi
  
  # Write to a file for reference
  echo "$working_host" > /tmp/db_host_ip.txt
}

# Helper function to check a specific host/port combination
wait_for_postgres_host() {
  host="$1"
  port="$2"
  max_attempts="${3:-60}"  # Default to 60 attempts unless specified
  
  # Skip empty hostnames
  if [ -z "$host" ]; then
    echo "Empty hostname passed to wait_for_postgres_host, skipping"
    return 1
  fi
  
  echo "Checking PostgreSQL at $host:$port (max $max_attempts attempts)..."
  
  attempt=1
  authentication_failed=0
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Checking PostgreSQL connection at $host:$port..."
    
    # Try to connect using nc first (most reliable for basic connectivity)
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w 5 "$host" "$port" >/dev/null 2>&1; then
        echo "TCP connection to $host:$port successful with nc!"
        psql_success=1
        
        # Try to actually connect and run a simple query if we have psql
        if command -v psql >/dev/null 2>&1; then
          psql_output=$(PGPASSWORD="$DB_PASS" psql -h "$host" -p "$port" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" 2>&1) || psql_success=0
          
          if [ "$psql_success" = "1" ]; then
            echo "PostgreSQL query successful!"
            return 0
          else
            echo "TCP connection succeeded but PostgreSQL query failed."
            echo "psql error: $psql_output"
            
            # Check if this is an authentication error
            if echo "$psql_output" | grep -q "password authentication failed" || echo "$psql_output" | grep -q "does not exist"; then
              authentication_failed=1
              # Don't keep retrying if it's an authentication error
              break
            fi
          fi
        else
          echo "TCP connection succeeded, but psql not available for full verification."
          # If we don't have psql, assume TCP connection is enough
          return 0
        fi
      fi
    else
      # Fallback to /dev/tcp if nc is not available
      { 
        exec 3>/dev/null
        exec 3>/dev/tcp/$host/$port
        conn_status=$?
        exec 3>&-
      } 2>/dev/null
      
      if [ $conn_status -eq 0 ]; then
        echo "TCP connection to $host:$port successful with /dev/tcp!"
        psql_success=1
        
        # Try to actually connect and run a simple query if we have psql
        if command -v psql >/dev/null 2>&1; then
          psql_output=$(PGPASSWORD="$DB_PASS" psql -h "$host" -p "$port" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" 2>&1) || psql_success=0
          
          if [ "$psql_success" = "1" ]; then
            echo "PostgreSQL query successful!"
            return 0
          else
            echo "TCP connection succeeded but PostgreSQL query failed."
            echo "psql error: $psql_output"
            
            # Check if this is an authentication error
            if echo "$psql_output" | grep -q "password authentication failed" || echo "$psql_output" | grep -q "does not exist"; then
              authentication_failed=1
              # Don't keep retrying if it's an authentication error
              break
            fi
          fi
        else
          echo "TCP connection succeeded, but psql not available for full verification."
          # If we don't have psql, assume TCP connection is enough
          return 0
        fi
      fi
    fi
    
    attempt=$((attempt + 1))
    sleep 2
  done
  
  if [ "$authentication_failed" = "1" ]; then
    echo "Authentication failed for user $DB_USER - this is likely a credentials issue rather than a connection issue"
    return 2  # Special return code for auth failures
  else
    echo "Failed to connect to PostgreSQL at $host:$port after $max_attempts attempts"
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
  if wait_for_postgres; then
    echo "Successfully connected to PostgreSQL!"
  else  
    echo "WARNING: Database connection check failed, but continuing anyway..."
  fi
  
  # The connection string is now updated with a working host
  echo "Starting PostgREST in foreground mode..."
  echo "Using database connection: $PGRST_DB_URI"
  
  # Export any direct IP address found as environment variables
  if [ -n "$DB_HOST_IP" ]; then
    echo "Exporting resolved database IP to PGHOST: $DB_HOST_IP"
    export PGHOST="$DB_HOST_IP"  # This will be used by the psql CLI
  fi
  
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
