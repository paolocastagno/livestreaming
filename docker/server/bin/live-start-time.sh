#!/usr/bin/env bash
set -euo pipefail

readonly RTMP="${1:-rtmp://127.0.0.1:1935/ingest/glass-half-240p}"

# Wait for contribution clock to be available from RTMP ingest
while true; do
  clock_ms=$(
    timeout 10 ffprobe -v error -select_streams v:0 -read_intervals '%+#1' \
      -show_entries packet=pts -of csv=p=0 "$RTMP" 2>/dev/null
  ) || true
  clock_ms=${clock_ms%%$'\n'*}
  if [[ "$clock_ms" =~ ^[0-9]+$ ]]; then
    break
  fi
  sleep 1
done

# Read source clock once, start 9 GOPs later (each GOP is 4 s = 4000 ms),
# half a second before the keyframe (ARCHITECTURE.md).
# target_seconds = (clock_ms / 4000 + 9) * 4 - 0.5
sec=$(( (clock_ms / 4000 + 9) * 4 ))
printf '%d.500\n' "$((sec - 1))"
