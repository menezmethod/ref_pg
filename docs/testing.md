# Testing Guide for Churnistic Referral Service

This document provides instructions for testing the PostgreSQL-based Churnistic Referral Service.

## Prerequisites

- Docker and Docker Compose installed
- cURL or Postman for API testing
- jq (optional, for JSON formatting in command line)

## Starting the Services

1. Start all services:
```bash
docker-compose up -d
```

2. Check if all services are running:
```bash
docker-compose ps
```

## Testing the API

### Authentication

1. Create a user (if not using sample data):
```bash
curl -X POST http://localhost:3000/rpc/create_user \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com", "plain_password": "test123", "role": "user"}'
```

2. Login to get a JWT token:
```bash
curl -X POST http://localhost:3000/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com", "password": "test123"}'
```

3. Store the returned token in a variable (for subsequent requests):
```bash
TOKEN=$(curl -s -X POST http://localhost:3000/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"email": "admin@example.com", "password": "admin123"}')
```

### Testing Offers Endpoints

1. List all offers (public access):
```bash
curl -X GET http://localhost:3000/offers?status=eq.active
```

2. Get a specific offer:
```bash
curl -X GET "http://localhost:3000/offers?id=eq.YOUR_OFFER_ID"
```

3. Create a new offer (requires admin authentication):
```bash
curl -X POST http://localhost:3000/offers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Test Offer",
    "institution": "Test Bank",
    "offer_type": "credit_card",
    "requirements": "Test requirements",
    "status": "draft",
    "metadata": {
      "expiry_date": "2023-12-31",
      "annual_fee": 99
    }
  }'
```

4. Update an offer (requires admin authentication):
```bash
curl -X PATCH "http://localhost:3000/offers?id=eq.YOUR_OFFER_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Updated Offer Title",
    "status": "active"
  }'
```

5. Delete an offer (requires admin authentication):
```bash
curl -X DELETE "http://localhost:3000/offers?id=eq.YOUR_OFFER_ID" \
  -H "Authorization: Bearer $TOKEN"
```

### Testing Full-Text Search

Search for offers containing specific terms:
```bash
curl -X POST http://localhost:3000/rpc/search_offers \
  -H "Content-Type: application/json" \
  -d '{"search_term": "credit card"}'
```

### Testing Analytics

View offer view counts (requires admin authentication):
```bash
curl -X GET http://localhost:3000/offer_view_counts \
  -H "Authorization: Bearer $TOKEN"
```

## Testing Database Backup & Restore

1. Create a backup:
```bash
cd scripts
./backup_database.sh
```

2. Restore from a backup:
```bash
cd scripts
./restore_database.sh ../backups/referral_service_YYYYMMDD_HHMMSS.sql.gz
```

## Testing Row-Level Security

1. Try accessing offers as anonymous user:
```bash
# Should only show active offers
curl -X GET http://localhost:3000/offers
```

2. Try accessing offers as admin:
```bash
# Should show all offers, including drafts
curl -X GET http://localhost:3000/offers \
  -H "Authorization: Bearer $TOKEN"
```

## Testing Monitoring Views

Execute SQL queries to check monitoring views (via pgAdmin or psql):

1. Query performance statistics:
```sql
SELECT * FROM query_stats LIMIT 10;
```

2. View database statistics:
```sql
SELECT * FROM db_stats;
```

## Using pgAdmin for Testing

1. Access pgAdmin at http://localhost:5050
2. Login with credentials from .env file
3. Add a new server connection:
   - Name: Referral Service
   - Host: db
   - Port: 5432
   - Database: referral_service
   - Username: (from .env file)
   - Password: (from .env file)

4. Browse tables, execute queries, and verify database structure

## Troubleshooting

If you encounter issues:

1. Check container logs:
```bash
docker-compose logs db
docker-compose logs postgrest
```

2. Verify database connectivity:
```bash
docker-compose exec db psql -U postgres -c "SELECT 1;"
```

3. Check if PostgREST can connect to the database:
```bash
docker-compose exec postgrest curl http://localhost:3000/
``` 