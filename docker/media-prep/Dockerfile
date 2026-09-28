FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY prepare-media.sh /usr/local/bin/prepare-media
RUN chmod 0755 /usr/local/bin/prepare-media

ENTRYPOINT ["/usr/local/bin/prepare-media"]

