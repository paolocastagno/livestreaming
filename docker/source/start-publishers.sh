#!/usr/bin/env bash
set -euo pipefail

readonly ORIGIN=http://10.0.5.1
readonly RTMP_BASE=rtmp://10.0.5.1:1935/ingest
readonly MEDIA=/opt/media
readonly LOG=/var/log/streaming

mkdir -p "$LOG"

for _ in $(seq 1 60); do
  if curl --fail --silent "$ORIGIN/healthz" >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent "$ORIGIN/healthz" >/dev/null

readonly QUALITIES=(240p 360p 480p 720p 1080p 2160p)

# One FFmpeg process publishes every rendition. All outputs then share a single
# timestamp clock, so the origin can align renditions and audio by timestamp
# instead of by the moment it happened to join each RTMP stream. A failure
# restarts all six feeds together, which keeps them on the same clock.
ffmpeg_args=(-hide_banner -loglevel warning -nostdin)
for quality in "${QUALITIES[@]}"; do
  ffmpeg_args+=(-re -stream_loop -1 -i "$MEDIA/glass-half-${quality}.mp4")
done
# The exact-sample audio loop has the same duration as every video loop.
ffmpeg_args+=(-re -stream_loop -1 -i "$MEDIA/glass-half-audio.flac")
readonly AUDIO_INPUT=${#QUALITIES[@]}

for i in "${!QUALITIES[@]}"; do
  quality=${QUALITIES[$i]}
  ffmpeg_args+=(-map "$i:v:0" -c:v copy)
  if [[ "$quality" == 240p ]]; then
    # The origin packages this feed's audio as the shared audio rendition.
    ffmpeg_args+=(-map "$AUDIO_INPUT:a:0" -c:a aac -b:a 128k -ar 48000 -ac 2)
  else
    ffmpeg_args+=(-an)
  fi
  ffmpeg_args+=(-flvflags no_duration_filesize -f flv "$RTMP_BASE/glass-half-${quality}")
done

publish_forever() {
  while true; do
    ffmpeg "${ffmpeg_args[@]}" >>"$LOG/publisher.log" 2>&1 || true
    echo "$(date --iso-8601=seconds) FFmpeg exited; restarting in one second." \
      >>"$LOG/publisher.log"
    sleep 1
  done
}

publish_forever &
echo $! >"$LOG/publisher.pid"

echo "Six live RTMP contribution renditions are publishing to the origin."
wait
