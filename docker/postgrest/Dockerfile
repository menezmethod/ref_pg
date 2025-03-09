FROM postgrest/postgrest:latest

# No additional packages to avoid build issues in Coolify
# We'll adapt the entrypoint script to work without them

# Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"] 