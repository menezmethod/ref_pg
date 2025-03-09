FROM postgrest/postgrest:latest

# Check which package manager is available and install tools accordingly
RUN if command -v apt-get >/dev/null; then \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        netcat-openbsd \
        iputils-ping \
        net-tools \
        dnsutils \
        postgresql-client \
      && rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null; then \
      apk add --no-cache \
        netcat-openbsd \
        iputils \
        net-tools \
        bind-tools \
        postgresql-client; \
    fi

# Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Use the original entrypoint script for compatibility
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"] 