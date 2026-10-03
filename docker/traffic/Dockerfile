FROM kathara/core:latest

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       curl iperf3 procps \
    && rm -rf /var/lib/apt/lists/*

COPY background-traffic.sh /usr/local/bin/background-traffic.sh
RUN chmod 0755 /usr/local/bin/background-traffic.sh
