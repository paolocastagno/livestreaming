#!/usr/bin/env bash
set -euo pipefail

readonly OUT=/srv/stream
readonly LOG=/var/log/streaming

mkdir -p "$OUT/hls" "$OUT/dash" "$LOG"
find "$OUT/hls" "$OUT/dash" -type f -delete

# Supervisor owns nginx and both packagers. Packagers may start before the
# contribution publisher; supervisor retries them until all inputs are live.
supervisord -c /etc/supervisor/conf.d/streaming.conf

echo "Origin ingest, supervised HLS packager, and supervised DASH packager started."
