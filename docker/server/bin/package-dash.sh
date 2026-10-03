#!/usr/bin/env bash
set -euo pipefail

readonly RTMP=rtmp://127.0.0.1:1935/ingest
readonly OUT=/srv/stream/dash

input_args=()
for quality in 240p 360p 480p 720p 1080p 2160p; do
  # A short analysis lets each input open within one GOP of the previous one.
  input_args+=( -thread_queue_size 1024 -analyzeduration 1000000 -i "$RTMP/glass-half-${quality}" )
done

# -copyts keeps the publisher's shared clock instead of rebasing every input
# to zero, which keeps renditions and audio aligned. Output -ss then starts all
# outputs at one common keyframe after every input has joined (see
# live-start-time) and moves that clock back to about zero.
start_time=$(live-start-time)

exec ffmpeg -hide_banner -loglevel warning \
  "${input_args[@]}" \
  -map 0:v:0 -map 1:v:0 -map 2:v:0 -map 3:v:0 -map 4:v:0 -map 5:v:0 \
  -map 0:a:0 -c copy -copyts -ss "$start_time" \
  -f dash -seg_duration 4 -window_size 8 -extra_window_size 4 \
  -use_template 1 -use_timeline 1 -remove_at_exit 0 -streaming 1 \
  -adaptation_sets 'id=0,streams=v id=1,streams=a' \
  "$OUT/manifest.mpd"
