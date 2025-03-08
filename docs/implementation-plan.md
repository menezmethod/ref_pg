# Postgres-Centric Churnistic Referral Service Implementation Plan

A production-ready implementation plan leveraging PostgreSQL's advanced capabilities for the Churnistic Referral Service.

## Executive Summary

This document outlines a minimalist, production-ready implementation plan for the Churnistic Referral Service using PostgreSQL as the primary technology. Instead of relying on multiple external services, we'll leverage PostgreSQL extensions and features to handle most application concerns. This approach reduces external dependencies, simplifies operations, and creates a more maintainable system.

## Core Design Principles

- **PostgreSQL-First**: Utilizing PostgreSQL's advanced features and extensions for most functionality
- **Minimalist Architecture**: Reducing external dependencies to the absolute minimum
- **Production Readiness**: Docker-based deployment with monitoring and proper operational considerations
- **Performance**: Leveraging PostgreSQL's capabilities for efficient data handling
- **Security**: Implementing proper data access controls and authentication

## System Architecture

### 1. High-Level Architecture

```
┌─────────────────────────────────┐
│             Client              │
└───────────────┬─────────────────┘
                │
┌───────────────▼─────────────────┐
│           PostgREST             │
│    (Automatic REST API Layer)   │
└───────────────┬─────────────────┘
                │
┌───────────────▼─────────────────┐
│      PostgreSQL Database        │
│                                 │
│  ┌─────────────────────────┐    │
│  │    Schema & Functions   │    │
│  └─────────────────────────┘    │
│  ┌─────────────────────────┐    │
│  │      pg_extensions      │    │
│  └─────────────────────────┘    │
│  ┌─────────────────────────┐    │
│  │ RLS Policies & Security │    │
│  └─────────────────────────┘    │
└─────────────────────────────────┘
```

### 2. Directory Structure

```
/
├── docs/                   # Documentation
│   └── implementation-plan.md  # This document
├── docker/                 # Docker setup
│   ├── docker-compose.yml  # Main compose file
│   ├── postgres/           # Postgres configuration
│   └── postgrest/          # PostgREST configuration
├── migrations/             # SQL migrations
│   ├── 001_initial_schema.sql
│   ├── 002_extensions.sql
│   └── 003_security.sql
├── scripts/                # Utility scripts
└── README.md               # Project overview
```

## Implementation Plan

### 1. PostgreSQL Core Setup

#### Database Schema

```sql
-- offers table without bonus_value field
CREATE TABLE offers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    institution TEXT NOT NULL,
    offer_type TEXT NOT NULL,
    requirements TEXT, 
    status TEXT NOT NULL DEFAULT 'draft',
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_offers_status ON offers (status);
CREATE INDEX idx_offers_institution ON offers (institution);
CREATE INDEX idx_offers_type ON offers (offer_type);
CREATE INDEX idx_offers_created_at ON offers (created_at);
CREATE INDEX idx_offers_metadata ON offers USING GIN (metadata);
```

#### Extensions

```sql
-- Core extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";      -- UUID support
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- Cryptographic functions
CREATE EXTENSION IF NOT EXISTS "pg_cron";        -- Scheduling
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- Query monitoring
CREATE EXTENSION IF NOT EXISTS "pgjwt";          -- JWT authentication
CREATE EXTENSION IF NOT EXISTS "postgrest";      -- REST API
```

### 2. Using PostgreSQL for Core Functionality

#### Authentication with pgcrypto and pgjwt

```sql
-- Users table
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Store hashed passwords
CREATE FUNCTION create_user(
    email TEXT,
    plain_password TEXT,
    role TEXT DEFAULT 'user'
) RETURNS UUID AS $$
DECLARE
    user_id UUID;
BEGIN
    INSERT INTO users (email, password, role)
    VALUES (email, crypt(plain_password, gen_salt('bf')), role)
    RETURNING id INTO user_id;
    
    RETURN user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- JWT token generation
CREATE FUNCTION login(email TEXT, password TEXT) RETURNS TEXT AS $$
DECLARE
    _user_id UUID;
    _role TEXT;
    result TEXT;
BEGIN
    SELECT id, role INTO _user_id, _role
    FROM users
    WHERE users.email = login.email AND users.password = crypt(login.password, users.password);
    
    IF _user_id IS NULL THEN
        RETURN NULL;
    END IF;
    
    SELECT sign(
        json_build_object(
            'role', _role,
            'user_id', _user_id,
            'exp', extract(epoch from now())::integer + 60*60*24
        ),
        current_setting('app.jwt_secret')
    ) INTO result;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

#### Row-Level Security

```sql
-- Enable RLS on offers table
ALTER TABLE offers ENABLE ROW LEVEL SECURITY;

-- Create policy for viewing offers
CREATE POLICY offers_view_policy ON offers
    FOR SELECT USING (status = 'active' OR auth.role() = 'admin');

-- Create policy for managing offers
CREATE POLICY offers_manage_policy ON offers
    USING (auth.role() = 'admin');
```

#### Automated Cleanup with pg_cron

```sql
-- Schedule a job to clean up expired offers
SELECT cron.schedule(
    'cleanup-expired-offers',
    '0 0 * * *',  -- Run at midnight every day
    $$
    UPDATE offers
    SET status = 'expired'
    WHERE status = 'active' AND metadata->>'expiry_date' < NOW()::text;
    $$
);
```

#### Full-Text Search

```sql
-- Add full-text search capabilities
ALTER TABLE offers ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(institution, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(requirements, '')), 'C')
    ) STORED;

CREATE INDEX idx_offers_search ON offers USING GIN (search_vector);

-- Create function for searching offers
CREATE FUNCTION search_offers(search_term TEXT) RETURNS SETOF offers AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM offers
    WHERE search_vector @@ plainto_tsquery('english', search_term)
    ORDER BY ts_rank(search_vector, plainto_tsquery('english', search_term)) DESC;
END;
$$ LANGUAGE plpgsql;
```

#### Analytics with PostgreSQL

```sql
-- Create an events table for analytics
CREATE TABLE analytics_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    event_data JSONB NOT NULL,
    user_id UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create function to log events
CREATE FUNCTION log_event(
    event_type TEXT,
    event_data JSONB,
    user_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    event_id UUID;
BEGIN
    INSERT INTO analytics_events (event_type, event_data, user_id)
    VALUES (event_type, event_data, user_id)
    RETURNING id INTO event_id;
    
    RETURN event_id;
END;
$$ LANGUAGE plpgsql;

-- Create views for analytics dashboards
CREATE VIEW offer_view_counts AS
SELECT 
    o.id AS offer_id,
    o.title,
    COUNT(*) AS view_count
FROM analytics_events ae
JOIN offers o ON ae.event_data->>'offer_id' = o.id::text
WHERE ae.event_type = 'offer_view'
GROUP BY o.id, o.title
ORDER BY view_count DESC;
```

### 3. PostgREST API Layer

Configure PostgREST to automatically generate a RESTful API based on your PostgreSQL schema:

```ini
# postgrest.conf
db-uri = "postgres://authenticator:password@db:5432/referral_service"
db-schema = "public"
db-anon-role = "anonymous"
jwt-secret = "${JWT_SECRET}"
```

API endpoints will be automatically generated:

- `GET /offers` - List offers with filtering
- `GET /offers?id=eq.{id}` - Get offer details
- `POST /offers` - Create a new offer
- `PATCH /offers?id=eq.{id}` - Update an offer
- `DELETE /offers?id=eq.{id}` - Delete an offer

### 4. Docker Deployment

```yaml
# docker-compose.yml
version: '3.8'

services:
  db:
    image: postgres:15
    container_name: referral_service_db
    restart: always
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./migrations:/docker-entrypoint-initdb.d
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_DB: ${POSTGRES_DB}
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgrest:
    image: postgrest/postgrest:latest
    container_name: referral_service_api
    restart: always
    depends_on:
      - db
    environment:
      PGRST_DB_URI: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}
      PGRST_DB_SCHEMA: public
      PGRST_DB_ANON_ROLE: anonymous
      PGRST_JWT_SECRET: ${JWT_SECRET}
    ports:
      - "3000:3000"

  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: referral_service_pgadmin
    restart: always
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_PASSWORD}
    ports:
      - "5050:80"
    depends_on:
      - db

volumes:
  postgres_data:
```

### 5. Monitoring and Observability

Use built-in PostgreSQL features for monitoring:

```sql
-- Create extension for monitoring
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Create a view for query monitoring
CREATE VIEW query_stats AS
SELECT
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 100;

-- Create a view for database statistics
CREATE VIEW db_stats AS
SELECT
    datname,
    numbackends,
    xact_commit,
    xact_rollback,
    blks_read,
    blks_hit,
    tup_returned,
    tup_fetched,
    tup_inserted,
    tup_updated,
    tup_deleted
FROM pg_stat_database;
```

## Implementation Checklist

### Phase 1: Foundation Setup
- [x] Set up Docker environment
- [x] Create initial database schema
- [x] Install required PostgreSQL extensions
- [x] Configure environment variables

### Phase 2: Core Database Functionality
- [x] Implement authentication with pgcrypto and pgjwt
- [x] Set up Row-Level Security policies
- [x] Create database functions for business logic
- [x] Implement full-text search capabilities
- [x] Set up automated jobs with pg_cron

### Phase 3: API Layer
- [x] Configure PostgREST
- [x] Test and verify API endpoints
- [x] Set up authentication and authorization
- [x] Implement rate limiting with PgBouncer

### Phase 4: Monitoring and Operations
- [x] Set up PostgreSQL monitoring views
- [x] Configure backups
- [x] Implement analytics collection
- [x] Create operational dashboards

### Phase 5: Testing and Deployment
- [x] Create test data and test scripts
- [x] Set up CI/CD pipeline
- [x] Perform security review
- [x] Create deployment documentation

## Best Practices

### Database Management
- Use connection pooling with PgBouncer
- Implement proper database indexing
- Regularly vacuum the database
- Keep transactions short
- Use prepared statements

### Security
- Never expose the database directly to the internet
- Use Row-Level Security for access control
- Store secrets in environment variables
- Regularly update and patch PostgreSQL
- Implement proper authentication and token management

### Performance
- Monitor query performance with pg_stat_statements
- Use appropriate indexes
- Implement pagination for list endpoints
- Use materialized views for complex queries
- Configure appropriate connection pool size

### Production Readiness
- Set up automated backups
- Implement health checks
- Configure proper logging
- Set up monitoring alerts
- Document operational procedures 