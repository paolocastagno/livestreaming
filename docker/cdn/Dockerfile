FROM kathara/core:latest

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       curl iperf3 nginx \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

COPY nginx.conf /etc/nginx/nginx.conf

RUN mkdir -p /var/cache/nginx/media /var/cache/nginx/static \
    && chown -R www-data:www-data /var/cache/nginx
