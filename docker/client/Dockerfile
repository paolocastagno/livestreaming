FROM kathara/core:latest

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       chromium curl ffmpeg fluxbox jq nginx novnc procps traceroute websockify x11vnc xvfb \
    && rm -rf /var/lib/apt/lists/*

COPY nginx.conf /etc/nginx/nginx.conf
COPY start-browser check-streams /usr/local/bin/
RUN chmod 0755 /usr/local/bin/start-browser /usr/local/bin/check-streams
