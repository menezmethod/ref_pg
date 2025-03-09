FROM postgrest/postgrest:latest

# No additional packages to avoid build issues in Coolify
# We'll adapt the entrypoint script to work without them

# Create the entrypoint script directly in the Dockerfile
RUN echo '#!/bin/sh\n\
set -e\n\
\n\
echo "Starting PostgREST with minimal entrypoint..."\n\
\n\
# Try to resolve the database host and wait for it to be available\n\
wait_for_database() {\n\
  echo "Checking database connection..."\n\
  \n\
  # Extract connection details from PGRST_DB_URI\n\
  db_uri="${PGRST_DB_URI}"\n\
  db_host=$(echo "$db_uri" | sed -n "s|.*@\([^:]*\):\([0-9]*\)/.*|\\1|p")\n\
  db_port=$(echo "$db_uri" | sed -n "s|.*@\([^:]*\):\([0-9]*\)/.*|\\2|p")\n\
  db_name=$(echo "$db_uri" | sed -n "s|.*/\([^?]*\).*|\\1|p")\n\
  \n\
  if [ -z "$db_name" ]; then\n\
    db_name=$(echo "$db_uri" | sed -n "s|.*/\(.*\)|\\1|p")\n\
  fi\n\
  \n\
  echo "Database connection details:"\n\
  echo "- Host: $db_host"\n\
  echo "- Port: $db_port"\n\
  echo "- Database: $db_name"\n\
  \n\
  # Use basic connection check with /dev/tcp\n\
  timeout=60\n\
  counter=0\n\
  echo "Waiting for PostgreSQL at $db_host:$db_port (timeout: $timeout seconds)..."\n\
  \n\
  while [ $counter -lt $timeout ]; do\n\
    if (echo > /dev/tcp/$db_host/$db_port) 2>/dev/null; then\n\
      echo "Successfully connected to PostgreSQL!"\n\
      return 0\n\
    fi\n\
    \n\
    counter=$((counter + 1))\n\
    echo "Attempt $counter/$timeout: Waiting for PostgreSQL... (sleeping 1s)"\n\
    sleep 1\n\
  done\n\
  \n\
  echo "WARNING: Could not connect to PostgreSQL after $timeout attempts"\n\
  echo "Continuing anyway, PostgREST will retry connecting..."\n\
  return 1\n\
}\n\
\n\
# Try to connect to the database before starting PostgREST\n\
wait_for_database\n\
\n\
# Log environment for debugging\n\
echo "Environment variables:"\n\
env | grep -v -E "PASSWORD|PASS|SECRET|KEY" | sort || true\n\
\n\
# Start PostgREST in the foreground\n\
echo "Starting PostgREST..."\n\
exec postgrest' > /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"] 