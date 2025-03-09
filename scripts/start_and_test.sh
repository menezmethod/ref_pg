#!/bin/bash

# Start the application using Docker Compose
echo "Starting the URL shortener application..."
docker-compose down
docker-compose up -d

# Wait for the database to be ready
echo "Waiting for the database to be ready..."
sleep 10

# Run the test script
echo "Running database tests..."
docker exec url_shortener_db psql -U postgres -d url_shortener -c "SELECT 'Database is ready and has been initialized' as status;"

# Run the test script
echo "Running test script..."
docker exec url_shortener_db psql -U postgres -d url_shortener -f /tmp/test_db.sql

# Check if PostgREST API is working
echo "Testing PostgREST API..."
curl -s -X GET http://localhost:3001/ | grep -q "PostgREST" && echo "PostgREST API is working" || echo "PostgREST API failed"

# Check if OpenResty is working
echo "Testing OpenResty redirects..."
curl -s -I http://localhost:8000/health | grep -q "200 OK" && echo "OpenResty is working" || echo "OpenResty failed"

echo "All tests completed!" 