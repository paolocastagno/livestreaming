#!/usr/bin/env bash
set -euo pipefail

for log in /var/log/streaming/*.log /var/log/nginx/error.log; do
  echo "===== $log ====="
  tail -n 30 "$log" 2>/dev/null || true
done

