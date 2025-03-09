# Deploying the URL Shortener on Coolify

This guide provides step-by-step instructions for deploying the PostgreSQL URL Shortener application on Coolify.

## Prerequisites

- A Coolify instance (self-hosted or cloud)
- Access to a GitHub account with the repository
- A domain name for the application (optional but recommended)

## Step 1: Initial Setup in Coolify

1. Log in to your Coolify dashboard.
2. Create a new project by clicking "New Project" and give it a name (e.g., "URL Shortener").
3. Add a new resource to the project.

## Step 2: Add the Source Code

1. Select "Application" as the resource type.
2. Connect to your GitHub repository:
   - Click "Connect New Source"
   - Select GitHub and authenticate if necessary
   - Choose the URL shortener repository
3. Configure the source:
   - Select the branch you want to deploy (usually `main` or `production-ready`)
   - Coolify will automatically detect Docker Compose configuration

## Step 3: Configure the Application

1. In the application settings, scroll to the "Environment Variables" section.
2. Add the following environment variables:
   ```
   POSTGRES_PASSWORD=<your-secure-password>
   JWT_SECRET=<your-jwt-secret>
   PGADMIN_EMAIL=<your-admin-email>
   PGADMIN_PASSWORD=<your-secure-admin-password>
   REDIS_PASSWORD=<your-redis-password>
   RATE_LIMIT_REQUESTS=60
   RATE_LIMIT_WINDOW=60
   LOG_LEVEL=warn
   ```
   Replace placeholders with your actual values.

3. Configure the build settings:
   - Build Command: Leave empty (Docker Compose will handle this)
   - Docker Compose File Path: `./docker-compose.yml`
   - Docker Compose Environment File: `.env.production`

## Step 4: Configure Networking

1. In the "Networking" tab, set up your domain:
   - For production use, add your custom domain
   - Enable HTTPS (Coolify can automatically provision Let's Encrypt certificates)
   - Configure ports:
     - URL Shortener (OpenResty): Port 8000
     - API (PostgREST): Port 3001
     - Swagger UI: Port 8080
     - pgAdmin: Port 5050
     - Prometheus: Port 9090

2. Configure the health check endpoint:
   - Path: `/health`
   - Port: 8000

## Step 5: Configure Persistent Storage

1. In the "Storage" tab, configure persistent volumes:
   - PostgreSQL data: `/var/lib/postgresql/data`
   - Redis data: `/data`
   - pgAdmin data: `/var/lib/pgadmin`
   - Prometheus data: `/prometheus`

## Step 6: Deploy the Application

1. Click "Save" to apply all settings.
2. Click "Deploy" to start the deployment process.
3. Monitor the deployment logs for any issues.

## Step 7: Post-Deployment Tasks

1. Set up automated backups:
   - Upload the `scripts/backup_database.sh` script to your Coolify server
   - Configure a cron job to run the script daily
   - Set up a remote storage location for backups (AWS S3, Google Cloud Storage, etc.)

2. Set up monitoring:
   - Configure Coolify's built-in monitoring
   - Set up alerts for service availability
   - Connect your application's `/metrics` endpoints to your monitoring system

3. Test the deployment:
   - Create a short URL using the API
   - Test the redirection functionality
   - Check the health endpoint

## Troubleshooting

### Container Startup Issues

If containers fail to start, check:
- Logs in the Coolify dashboard
- Environment variable configuration
- Network connectivity between services
- Permission issues with mounted volumes

### Database Connection Issues

If the application cannot connect to the database:
- Verify PostgreSQL is running
- Check database credentials in environment variables
- Ensure database migrations ran successfully

### SSL/TLS Issues

If HTTPS is not working correctly:
- Verify DNS records point to your Coolify instance
- Check certificate provisioning logs
- Ensure ports 80 and 443 are accessible

## Scaling

To scale the application:
1. Increase resources for the PostgreSQL container first
2. Scale the OpenResty containers horizontally
3. Consider adding a load balancer in front of multiple OpenResty instances
4. Implement Redis Cluster for caching at scale

## Maintenance Tasks

### Updating the Application

1. Push changes to your repository
2. In Coolify, go to your application and click "Redeploy"
3. Monitor the deployment logs

### Database Backups

1. Automated backups should be running via cron job
2. Periodically test backup restoration process
3. Monitor backup storage usage

### Monitoring

1. Regularly check application metrics
2. Set up alerts for error spikes or performance degradation
3. Monitor disk space, especially for database volumes 