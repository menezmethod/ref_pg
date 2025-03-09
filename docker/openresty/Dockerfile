FROM openresty/openresty:alpine

# Install required packages
RUN apk add --no-cache git gettext curl \
    && cd /tmp \
    && git clone https://github.com/ledgetech/lua-resty-http \
    && cd lua-resty-http \
    && mkdir -p /usr/local/openresty/lualib/resty \
    && cp -r lib/resty/http* /usr/local/openresty/lualib/resty/ \
    && cd / \
    && rm -rf /tmp/lua-resty-http

# Copy configuration files
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf.template
COPY lua /usr/local/openresty/nginx/lua/

# Create log and cache directories with permissive permissions
RUN mkdir -p /var/log/nginx /var/cache/nginx /tmp/nginx && \
    chmod -R 777 /var/log/nginx /var/cache/nginx /tmp/nginx && \
    chmod -R 777 /usr/local/openresty/nginx/conf

# Set up entrypoint script
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Use SIGQUIT instead of default SIGTERM to cleanly drain requests
# See https://github.com/openresty/docker-openresty/blob/master/README.md#tips--pitfalls
STOPSIGNAL SIGQUIT

# Expose HTTP port
EXPOSE 80

# Set working directory
WORKDIR /usr/local/openresty

# Use custom entrypoint script to handle environment variables
ENTRYPOINT ["/docker-entrypoint.sh"]

# Default command - removed USER directive here to allow file creation
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]