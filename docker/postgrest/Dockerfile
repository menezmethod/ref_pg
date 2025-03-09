FROM postgrest/postgrest:latest

# Coolify needs a very simple Dockerfile without complex scripts
# This approach uses the default entrypoint from the base image

# Add labels for Coolify compatibility
LABEL coolify.managed=true

# No additional packages to avoid build issues in Coolify

# Create a startup script that performs database checks before starting PostgREST
RUN echo "#!/bin/sh\n\
set -e\n\
\n\
echo \"Starting PostgREST with database verification...\"\n\
\n\
# Extract connection details from PGRST_DB_URI\n\
db_uri=\"\${PGRST_DB_URI}\"\n\
db_host=\$(echo \"\$db_uri\" | sed -n 's|.*@\\([^:]*\\):\\([0-9]*\\)/.*|\\1|p')\n\
db_port=\$(echo \"\$db_uri\" | sed -n 's|.*@\\([^:]*\\):\\([0-9]*\\)/.*|\\2|p')\n\
db_name=\$(echo \"\$db_uri\" | sed -n 's|.*/\\([^?]*\\).*|\\1|p')\n\
db_user=\$(echo \"\$db_uri\" | sed -n 's|postgres://\\([^:]*\\):\\([^@]*\\)@.*|\\1|p')\n\
db_pass=\$(echo \"\$db_uri\" | sed -n 's|postgres://\\([^:]*\\):\\([^@]*\\)@.*|\\2|p')\n\
\n\
if [ -z \"\$db_name\" ]; then\n\
  db_name=\$(echo \"\$db_uri\" | sed -n 's|.*/\\(.*\\)|\\1|p')\n\
fi\n\
\n\
echo \"Database connection details:\"\n\
echo \"- Host: \$db_host\"\n\
echo \"- Port: \$db_port\"\n\
echo \"- Database: \$db_name\"\n\
echo \"- User: \$db_user\"\n\
\n\
# Wait for database connection\n\
echo \"Waiting for PostgreSQL to be available...\"\n\
max_retries=60\n\
retries=0\n\
\n\
while [ \$retries -lt \$max_retries ]; do\n\
  if (echo > /dev/tcp/\$db_host/\$db_port) 2>/dev/null; then\n\
    echo \"Database is available!\"\n\
    break\n\
  fi\n\
  retries=\$((retries + 1))\n\
  echo \"Waiting for database connection (\$retries/\$max_retries)...\"\n\
  sleep 1\n\
done\n\
\n\
if [ \$retries -eq \$max_retries ]; then\n\
  echo \"Failed to connect to database after \$max_retries attempts.\"\n\
  echo \"Continuing anyway, PostgREST will retry connecting...\"\n\
fi\n\
\n\
# Check if important roles exist or create them if possible\n\
create_roles() {\n\
  psql_cmd=\"PGPASSWORD=\$db_pass psql -h \$db_host -p \$db_port -U \$db_user -d \$db_name -t -c\"\n\
  \n\
  # Check for anon role\n\
  anon_exists=\$(eval \"\$psql_cmd \\\"SELECT 1 FROM pg_roles WHERE rolname='anon'\\\"\" 2>/dev/null || echo \"0\")\n\
  \n\
  if ! echo \"\$anon_exists\" | grep -q \"1\"; then\n\
    echo \"Creating anon role...\"\n\
    eval \"\$psql_cmd \\\"CREATE ROLE anon NOLOGIN;\\\"\" 2>/dev/null || echo \"Failed to create anon role. Continuing...\"\n\
  fi\n\
  \n\
  # Check for authenticator role\n\
  auth_exists=\$(eval \"\$psql_cmd \\\"SELECT 1 FROM pg_roles WHERE rolname='authenticator'\\\"\" 2>/dev/null || echo \"0\")\n\
  \n\
  if ! echo \"\$auth_exists\" | grep -q \"1\"; then\n\
    echo \"Creating authenticator role...\"\n\
    eval \"\$psql_cmd \\\"CREATE ROLE authenticator WITH LOGIN PASSWORD '\$db_pass' NOINHERIT;\\\"\" 2>/dev/null || echo \"Failed to create authenticator role. Continuing...\"\n\
    eval \"\$psql_cmd \\\"GRANT anon TO authenticator;\\\"\" 2>/dev/null || echo \"Failed to grant anon to authenticator. Continuing...\"\n\
  fi\n\
  \n\
  # Check for api schema\n\
  api_exists=\$(eval \"\$psql_cmd \\\"SELECT 1 FROM pg_namespace WHERE nspname='api'\\\"\" 2>/dev/null || echo \"0\")\n\
  \n\
  if ! echo \"\$api_exists\" | grep -q \"1\"; then\n\
    echo \"Creating api schema...\"\n\
    eval \"\$psql_cmd \\\"CREATE SCHEMA IF NOT EXISTS api;\\\"\" 2>/dev/null || echo \"Failed to create api schema. Continuing...\"\n\
    eval \"\$psql_cmd \\\"GRANT USAGE ON SCHEMA api TO anon;\\\"\" 2>/dev/null || echo \"Failed to grant usage on api schema. Continuing...\"\n\
  fi\n\
}\n\
\n\
# Try to create roles but continue if it fails\n\
create_roles || echo \"Could not check or create roles. Continuing...\"\n\
\n\
# Start PostgREST\n\
echo \"Starting PostgREST...\"\n\
exec postgrest" > /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

# Skip any customization to make the build as reliable as possible
# If needed, we can handle database connection logic at the orchestration level 