FROM postgres:15

# Check migrations directory and file
RUN echo "Starting PostgreSQL container with debugging" && mkdir -p /docker-entrypoint-initdb.d

# Alternative approach: Create a script to apply migrations at runtime
COPY <<EOF /docker-entrypoint-initdb.d/1-copy-schema.sh
#!/bin/bash
set -e
echo "Checking for migration file..."
if [ -f /docker-entrypoint-initdb.d/sql/000_main_migration.sql ]; then
  echo "Migration file found as copied SQL file"
  cp /docker-entrypoint-initdb.d/sql/000_main_migration.sql /docker-entrypoint-initdb.d/schema.sql
  echo "Copied migration SQL to schema.sql"
elif [ -f /migrations/000_main_migration.sql ]; then
  echo "Migration file found in mounted volume"
  cp /migrations/000_main_migration.sql /docker-entrypoint-initdb.d/schema.sql
  echo "Copied migration SQL to schema.sql"
else
  echo "Warning: Migration SQL file not found, will use fallback"
fi
EOF

RUN chmod +x /docker-entrypoint-initdb.d/1-copy-schema.sh

# Copy migrations directory to a location in the container for direct access
COPY migrations /docker-entrypoint-initdb.d/sql/

# Use environment variables from docker-compose to configure the database

# Create a simple script to setup roles
COPY <<EOF /docker-entrypoint-initdb.d/2-setup.sh
#!/bin/bash
set -e
echo "Setting up roles..."
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
  -- Create roles
  CREATE ROLE IF NOT EXISTS anon NOLOGIN;
  DROP ROLE IF EXISTS authenticator;
  CREATE ROLE authenticator WITH LOGIN PASSWORD '$POSTGRES_PASSWORD' NOINHERIT;
  GRANT anon TO authenticator;
  
  -- Grant permissions
  GRANT USAGE ON SCHEMA public TO anon;
  GRANT USAGE ON SCHEMA api TO anon;
"
echo "Setup complete"
EOF

# Make script executable
RUN chmod +x /docker-entrypoint-initdb.d/2-setup.sh

# Copy initialization scripts
COPY sql/init/init-db.sh /docker-entrypoint-initdb.d/3-init-db.sh
COPY sql/init/update-pg-hba.sh /docker-entrypoint-initdb.d/4-update-pg-hba.sh
COPY sql /docker-entrypoint-initdb.d/sql

# Set permissions
RUN chmod +x /docker-entrypoint-initdb.d/3-init-db.sh
RUN chmod +x /docker-entrypoint-initdb.d/4-update-pg-hba.sh

# Add verification script
COPY <<EOF /docker-entrypoint-initdb.d/5-verify-setup.sh
#!/bin/bash
set -e

echo "Verifying database setup..."
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL
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

RUN chmod +x /docker-entrypoint-initdb.d/5-verify-setup.sh 

# Add emergency fallback script as a final step
COPY <<EOF /docker-entrypoint-initdb.d/6-emergency-fallback.sh
#!/bin/bash
set -e

echo "Checking if emergency fallback is needed..."
# Check if core functions exist
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "
  SELECT EXISTS (
    SELECT 1 FROM pg_proc 
    WHERE proname = 'create_short_link' 
    AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'api')
  );
" > /tmp/function_exists

if ! grep -q 't' /tmp/function_exists; then
  echo "EMERGENCY FALLBACK: Core functions missing! Creating minimal API..."
  
  # Create API schema if not exists
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    CREATE SCHEMA IF NOT EXISTS api;
  "
  
  # Create anon role if missing
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
      END IF;
    END
    \$\$;
  "
  
  # Create authenticator role if missing
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
        DROP ROLE IF EXISTS authenticator;
        CREATE ROLE authenticator WITH LOGIN PASSWORD '$POSTGRES_PASSWORD' NOINHERIT;
        GRANT anon TO authenticator;
      END IF;
    END
    \$\$;
  "
  
  # Grant schema permissions
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    GRANT USAGE ON SCHEMA api TO anon;
    GRANT USAGE ON SCHEMA api TO authenticator;
  "
  
  # Create minimal tables if needed
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    CREATE TABLE IF NOT EXISTS api.urls (
      id SERIAL PRIMARY KEY,
      original_url TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    
    CREATE TABLE IF NOT EXISTS api.short_links (
      id SERIAL PRIMARY KEY,
      url_id INTEGER REFERENCES api.urls(id),
      code TEXT NOT NULL UNIQUE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    
    GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA api TO anon;
  "
  
  # Create minimal functions
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    -- Function to create a short link (simplified version)
    CREATE OR REPLACE FUNCTION api.create_short_link(p_original_url TEXT, p_custom_alias TEXT DEFAULT NULL)
    RETURNS JSON AS \$\$
    DECLARE
      v_url_id INTEGER;
      v_code TEXT;
    BEGIN
      -- Insert URL
      INSERT INTO api.urls (original_url) VALUES (p_original_url) RETURNING id INTO v_url_id;
      
      -- Use custom alias or generate one
      v_code := COALESCE(p_custom_alias, 'url' || v_url_id::TEXT);
      
      -- Create short link
      INSERT INTO api.short_links (url_id, code) VALUES (v_url_id, v_code);
      
      RETURN json_build_object(
        'success', TRUE,
        'code', v_code,
        'short_url', 'https://ref.menezmethod.com/r/' || v_code,
        'original_url', p_original_url
      );
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;
    
    -- Function to get the original URL for a short code
    CREATE OR REPLACE FUNCTION api.get_original_url(p_code TEXT)
    RETURNS JSON AS \$\$
    DECLARE
      v_original_url TEXT;
    BEGIN
      SELECT u.original_url INTO v_original_url
      FROM api.short_links s
      JOIN api.urls u ON s.url_id = u.id
      WHERE s.code = p_code;
      
      IF v_original_url IS NULL THEN
        RETURN json_build_object(
          'success', FALSE,
          'error', 'Short URL not found'
        );
      END IF;
      
      RETURN json_build_object(
        'success', TRUE,
        'original_url', v_original_url
      );
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;
    
    -- Simple test function
    CREATE OR REPLACE FUNCTION api.test_create_link(p_url TEXT, p_alias TEXT)
    RETURNS JSON AS \$\$
    BEGIN
      RETURN api.create_short_link(p_url, p_alias);
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;
    
    -- Simple quick link function
    CREATE OR REPLACE FUNCTION api.quick_link(url TEXT, alias TEXT, api_key TEXT DEFAULT NULL)
    RETURNS JSON AS \$\$
    BEGIN
      RETURN api.create_short_link(url, alias);
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;
  "
  
  echo "✅ Emergency fallback created successfully!"
else
  echo "✅ Core functions exist, no emergency fallback needed."
fi
EOF

RUN chmod +x /docker-entrypoint-initdb.d/6-emergency-fallback.sh 