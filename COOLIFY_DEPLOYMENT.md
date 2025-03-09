# Coolify Deployment Guide - URL Shortener

This document provides instructions for deploying the URL Shortener service on Coolify.

## Environment Variables

Ensure the following environment variables are set in your Coolify deployment:

### Required Variables
- `POSTGRES_PASSWORD` - Password for PostgreSQL database
- `POSTGRES_USER` - Username for PostgreSQL database (default: "postgres")
- `POSTGRES_DB` - Database name (should be "url_shortener")
- `JWT_SECRET` - Secret for JWT token generation
- `MASTER_PASSWORD` - Master password for the service
- `PGADMIN_EMAIL` - Email for pgAdmin login
- `PGADMIN_PASSWORD` - Password for pgAdmin login
- `REDIS_PASSWORD` - Password for Redis

### Optional Variables
- `CORS_ALLOW_ORIGIN` - Allowed origins for CORS (default: '*')
- `RATE_LIMIT_REQUESTS` - Number of requests allowed (default: 60)
- `RATE_LIMIT_WINDOW` - Time window in minutes for rate limits (default: 60)
- `LOG_LEVEL` - Logging level (default: notice)

## Deployment Steps

1. **Create a new service in Coolify**:
   - Select "Docker Compose" as the service type
   - Use your Git repository as the source

2. **Configure Environment Variables**:
   - Add all required environment variables
   - Set the port mappings as per the documentation

3. **Deploy**:
   - Click "Deploy" to start the deployment
   - Wait for all services to start

## Troubleshooting

### Port Conflicts
If you encounter port conflicts, the docker-compose.yml file has been updated to use non-standard ports:
- PostgreSQL: 5433 (instead of 5432)
- Redis: 6380 (instead of 6379)
- PostgREST API: 3333 (instead of 3001)
- URL Shortener redirect service: 8001 (instead of 8000)
- Swagger UI: 8081 (instead of 8080)
- pgAdmin: 5051 (instead of 5050)

### OpenResty Permission Issues
The OpenResty container has been configured to handle restrictive permissions in Coolify:
- If you see "unknown cors_allow_origin variable" errors, ensure the CORS_ALLOW_ORIGIN environment variable is set
- Check that the container is using the latest image with the entrypoint script fixes

### Common Errors and Solutions

1. **Database connection failures**:
   - Verify that the PostgreSQL container is running
   - Check the database credentials in environment variables
   - Ensure the PostgreSQL port is correctly mapped

2. **API not accessible**:
   - Confirm the PostgREST container is running
   - Check the logs for any JWT or database connection errors
   - Verify the port mapping is correct

3. **URL redirects not working**:
   - Check the OpenResty container logs for errors
   - Verify the connection between OpenResty and PostgREST
   - Ensure the short link exists in the database

## Verification

After deployment, verify the system is working by:

1. Creating a short URL through the API
2. Accessing the short URL to test redirection
3. Checking pgAdmin to verify database structure

## Updates and Maintenance

When updating the deployment:
- Always check the PATCH_NOTES.md file for changes
- Back up your database before major version updates
- Update environment variables as needed for new features 