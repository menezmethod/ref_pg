FROM openresty/openresty:alpine

# Install lua-resty-http (if not already included in the image)
RUN apk add --no-cache git \
    && cd /tmp \
    && git clone https://github.com/ledgetech/lua-resty-http \
    && cd lua-resty-http \
    && mkdir -p /usr/local/openresty/lualib/resty \
    && cp -r lib/resty/http* /usr/local/openresty/lualib/resty/ \
    && cd / \
    && rm -rf /tmp/lua-resty-http

# Copy configuration files
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua /usr/local/openresty/nginx/lua/

# Use SIGQUIT instead of default SIGTERM to cleanly drain requests
# See https://github.com/openresty/docker-openresty/blob/master/README.md#tips--pitfalls
STOPSIGNAL SIGQUIT

EXPOSE 80

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]