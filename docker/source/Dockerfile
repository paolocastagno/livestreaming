FROM kathara/core:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ffmpeg procps \
    && rm -rf /var/lib/apt/lists/*

COPY docker/source/start-publishers.sh /usr/local/bin/start-publishers.sh
COPY media/generated/variants/ /opt/media/

RUN chmod 0755 /usr/local/bin/start-publishers.sh \
    && test -s /opt/media/glass-half-240p.mp4 \
    && test -s /opt/media/glass-half-360p.mp4 \
    && test -s /opt/media/glass-half-480p.mp4 \
    && test -s /opt/media/glass-half-720p.mp4 \
    && test -s /opt/media/glass-half-1080p.mp4 \
    && test -s /opt/media/glass-half-2160p.mp4 \
    && test -s /opt/media/glass-half-audio.flac \
    && mkdir -p /var/log/streaming
