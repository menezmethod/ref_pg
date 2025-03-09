FROM postgrest/postgrest:latest

# Coolify needs a very simple Dockerfile without complex scripts
# This approach uses the default entrypoint from the base image

# Add labels for Coolify compatibility
LABEL coolify.managed=true

# No additional packages to avoid build issues in Coolify

# No complex scripts - using the default PostgREST entrypoint
# The base image already has a suitable entrypoint that will handle startup

# Note: Database roles and schema checks will be handled by the postgres container
# or the db-init service defined in docker-compose.yml

# The default command is already set in the base image
# When PostgREST starts, it will automatically try to connect using the PGRST_* environment variables 