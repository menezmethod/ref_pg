FROM openresty/openresty:1.27.1.2-alpine

# envsubst renders nginx.conf from the template at container start.
RUN apk add --no-cache gettext

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf.template
COPY lua /usr/local/openresty/nginx/lua
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# SIGQUIT lets nginx drain open requests before it stops.
STOPSIGNAL SIGQUIT
EXPOSE 80

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
