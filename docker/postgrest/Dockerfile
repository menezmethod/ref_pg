FROM postgrest/postgrest:latest

# Install networking tools and PostgreSQL client for diagnostics
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    netcat-openbsd \
    iputils-ping \
    net-tools \
    dnsutils \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Copy both entrypoint scripts - use the enhanced one by default
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-enhanced.sh /entrypoint-enhanced.sh

# Make both scripts executable
RUN chmod +x /entrypoint.sh /entrypoint-enhanced.sh

# Use the enhanced script by default 
ENTRYPOINT ["/bin/sh", "/entrypoint-enhanced.sh"] 