FROM postgrest/postgrest:latest

USER root

# Install netcat for our health check server
RUN apt-get update && \
    apt-get install -y --no-install-recommends netcat-openbsd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Change back to the default postgrest user
USER 1000

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"] 