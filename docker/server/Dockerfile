FROM node:22-bookworm-slim AS player

ARG SHAKA_PLAYER_VERSION=5.2.9
WORKDIR /tmp/player
RUN npm pack "shaka-player@${SHAKA_PLAYER_VERSION}" \
    && tar -xzf shaka-player-*.tgz \
    && test -s package/dist/shaka-player.compiled.js

FROM kathara/core:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg nginx libnginx-mod-rtmp procps curl supervisor \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

COPY docker/server/nginx.conf /etc/nginx/nginx.conf
COPY docker/server/web/ /srv/www/
COPY --from=player /tmp/player/package/dist/shaka-player.compiled.js /srv/www/vendor/shaka-player.compiled.js
COPY docker/server/bin/ /usr/local/bin/
COPY docker/server/supervisord.conf /etc/supervisor/conf.d/streaming.conf

RUN chmod 0755 /usr/local/bin/start-live.sh /usr/local/bin/package-hls.sh \
                  /usr/local/bin/package-dash.sh /usr/local/bin/live-start-time.sh \
                  /usr/local/bin/show-stream-logs.sh \
    && ln -sf /usr/local/bin/live-start-time.sh /usr/local/bin/live-start-time \
    && mkdir -p /srv/stream/hls /srv/stream/dash /var/log/streaming
