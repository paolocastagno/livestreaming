FROM kathara/core:latest

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       curl iperf3 procps python3 \
    && rm -rf /var/lib/apt/lists/*

COPY background-traffic.sh /usr/local/bin/background-traffic.sh
COPY hls-background-client.py /usr/local/bin/hls-background-client.py
RUN chmod 0755 /usr/local/bin/background-traffic.sh /usr/local/bin/hls-background-client.py
