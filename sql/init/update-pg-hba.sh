#!/bin/bash
set -e

echo "Running update-pg-hba.sh..."

# Location of pg_hba.conf file inside the container
PG_HBA_FILE="/var/lib/postgresql/data/pg_hba.conf"

# Wait for the file to exist (first boot of PostgreSQL)
while [ ! -f "$PG_HBA_FILE" ]; do
  echo "Waiting for pg_hba.conf to be created..."
  sleep 1
done

# Allow all connections from the internal network
echo "# Allow all connections from containers in the same network" >> "$PG_HBA_FILE"
echo "host    all             all             0.0.0.0/0               md5" >> "$PG_HBA_FILE"
echo "host    all             all             ::/0                    md5" >> "$PG_HBA_FILE"

# Reload PostgreSQL configuration
psql -U "$POSTGRES_USER" -c "SELECT pg_reload_conf();"

echo "Successfully updated pg_hba.conf and reloaded PostgreSQL configuration." 