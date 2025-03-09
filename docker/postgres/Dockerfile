FROM postgres:15

# Copy initialization scripts
COPY migrations/000_main_migration.sql /docker-entrypoint-initdb.d/1-schema.sql
COPY sql/init/init-db.sh /docker-entrypoint-initdb.d/2-init-db.sh
COPY sql/init/update-pg-hba.sh /docker-entrypoint-initdb.d/3-update-pg-hba.sh
COPY sql /docker-entrypoint-initdb.d/sql

# Set permissions
RUN chmod +x /docker-entrypoint-initdb.d/2-init-db.sh
RUN chmod +x /docker-entrypoint-initdb.d/3-update-pg-hba.sh

# Add verification script
COPY <<EOF /docker-entrypoint-initdb.d/4-verify-setup.sh
#!/bin/bash
set -e

echo "Verifying database setup..."
psql -U "\$POSTGRES_USER" -d "\$POSTGRES_DB" <<EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc 
      WHERE proname = 'test_create_link' 
      AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')
    ) THEN
      RAISE EXCEPTION 'Function api.test_create_link does not exist! Database initialization failed.';
    END IF;
    
    IF NOT EXISTS (
      SELECT 1 FROM pg_roles WHERE rolname = 'anon'
    ) THEN
      RAISE EXCEPTION 'Role anon does not exist! Database initialization failed.';
    END IF;
    
    IF NOT EXISTS (
      SELECT 1 FROM pg_roles WHERE rolname = 'authenticator'
    ) THEN
      RAISE EXCEPTION 'Role authenticator does not exist! Database initialization failed.';
    END IF;
    
    RAISE NOTICE 'Database initialization verified successfully!';
  END
  \$\$;
EOSQL

echo "All database objects verified successfully!"
EOF

RUN chmod +x /docker-entrypoint-initdb.d/4-verify-setup.sh 