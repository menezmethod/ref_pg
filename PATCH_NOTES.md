# Patch Notes - URL Shortener Coolify Deployment Fixes

## Version 1.1.2 - 2025-03-09

This patch specifically addresses port conflict issues when deploying in Coolify environments, along with other reliability improvements.

### Bug Fixes for Coolify

1. **Port Conflict Resolution**
   - Changed OpenResty port from 8000 to 8001 to avoid conflicts with other services
   - Updated documentation to reflect the new port mapping

2. **PostgREST Configuration Fix**
   - Replaced mounted config file with direct environment variables
   - Added custom entrypoint script to ensure database connection
   - Simplified container dependencies

3. **PostgreSQL Initialization Enhancements**
   - Improved initialization script with better error handling
   - Added automatic retry mechanisms
   - Ensured database creation is reliable in Coolify containers

4. **Container Dependencies Simplified**
   - Removed health-check based dependencies which can be problematic in Coolify
   - Simplified service ordering to avoid circular dependencies
   - Improved individual container health checks

5. **Coolify-Specific Optimizations**
   - Made the solution work without relying on Coolify's support for volume mounts
   - Ensured containers start in the right order without complex dependencies

### Automatic Deployment for Coolify

The changes ensure that deployment is fully automated in Coolify with no manual steps:

1. Start the stack with `coolify deploy`
2. All services will automatically initialize correctly
3. No need for SSH access or manual intervention

### Environment Variables

Ensure these variables are correctly set in your Coolify environment:

- `POSTGRES_PASSWORD`
- `POSTGRES_USER`  
- `POSTGRES_DB` (should be "url_shortener")
- `JWT_SECRET`
- `MASTER_PASSWORD`
- `PGADMIN_EMAIL`
- `PGADMIN_PASSWORD`
- `REDIS_PASSWORD`

### Connection Details

- PostgreSQL is accessible on port 5433 (external) and 5432 (internal)
- PostgREST API is available on port 3001
- URL Shortener redirect service is on port 8001 (changed from 8000)
- Swagger UI is on port 8080
- pgAdmin is on port 5050 