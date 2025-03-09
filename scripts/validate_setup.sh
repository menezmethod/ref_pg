#!/bin/bash
set -e

# This script validates that all components of the URL Shortener are properly initialized
# It can be run automatically by Coolify during deployment or as a health check

echo "Running setup validation for URL Shortener..."
FAILURES=0

# Check PostgreSQL
echo "Checking PostgreSQL connection..."
if pg_isready -h db -p 5432 -U ${POSTGRES_USER:-postgres}; then
  echo "✅ PostgreSQL is up and accepting connections"
else
  echo "❌ PostgreSQL connection failed"
  FAILURES=$((FAILURES+1))
fi

# Check if the database exists
echo "Checking if database exists..."
if PGPASSWORD=${POSTGRES_PASSWORD:-postgres} psql -h db -p 5432 -U ${POSTGRES_USER:-postgres} -lqt | cut -d \| -f 1 | grep -qw ${POSTGRES_DB:-url_shortener}; then
  echo "✅ Database '${POSTGRES_DB:-url_shortener}' exists"
else
  echo "❌ Database '${POSTGRES_DB:-url_shortener}' does not exist"
  FAILURES=$((FAILURES+1))
fi

# Check if the schema has been applied
echo "Checking if schema has been applied..."
if PGPASSWORD=${POSTGRES_PASSWORD:-postgres} psql -h db -p 5432 -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-url_shortener} -c "SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='short_links'" | grep -q 1; then
  echo "✅ Schema has been applied correctly"
else
  echo "❌ Schema has not been applied correctly"
  FAILURES=$((FAILURES+1))
fi

# Check Redis
echo "Checking Redis connection..."
if redis-cli -h redis -a ${REDIS_PASSWORD:-} ping | grep -q PONG; then
  echo "✅ Redis is up and accepting connections"
else
  echo "❌ Redis connection failed"
  FAILURES=$((FAILURES+1))
fi

# Check PostgREST API
echo "Checking PostgREST API..."
if curl -s http://postgrest:3000/ | grep -q "postgrest"; then
  echo "✅ PostgREST API is working"
else
  echo "❌ PostgREST API is not responding"
  FAILURES=$((FAILURES+1))
fi

# Check OpenResty
echo "Checking OpenResty..."
if curl -s http://openresty:80/health | grep -q "ok"; then
  echo "✅ OpenResty is working"
else
  echo "❌ OpenResty is not responding"
  FAILURES=$((FAILURES+1))
fi

# Summary
if [ $FAILURES -eq 0 ]; then
  echo "✅ All checks passed! The URL Shortener is correctly set up."
  exit 0
else
  echo "❌ Some checks failed. Please review the logs above."
  exit 1
fi 