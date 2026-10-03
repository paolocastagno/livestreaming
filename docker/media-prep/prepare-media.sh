#!/usr/bin/env bash
set -euo pipefail

readonly OUTPUT=/output
readonly SOURCE_DIR="$OUTPUT/source"
readonly VARIANT_DIR="$OUTPUT/variants"
readonly SOURCE="$SOURCE_DIR/glass-half-2160p.webm"
readonly SOURCE_URL='https://commons.wikimedia.org/wiki/Special:Redirect/file/Glass_Half_-_Blender_Open_Movie-full_movie.webm'
readonly FRAME_RATE=30
# Keyframes, and therefore every point where the origin can join a feed, sit on
# the same four-second grid as the HLS/DASH segments.
readonly GOP_SECONDS=4
readonly AUDIO_SAMPLE_RATE=48000
readonly AUDIO="$VARIANT_DIR/glass-half-audio.flac"
readonly MODE="${1:-all}"

case "$MODE" in
  all|source-only) ;;
  *) echo "Usage: prepare-media [all|source-only]" >&2; exit 2 ;;
esac

mkdir -p "$SOURCE_DIR" "$VARIANT_DIR"

if [[ ! -s "$SOURCE" ]]; then
  echo "Downloading the CC BY 4.0 native-4K Glass Half film (about 167 MB)..."
  tmp="$SOURCE.part"
  curl --fail --location --retry 5 --retry-delay 2 --output "$tmp" "$SOURCE_URL"
  mv "$tmp" "$SOURCE"
fi

cat >"$OUTPUT/ATTRIBUTION.txt" <<'EOF'
Glass Half
Copyright Blender Foundation
License: Creative Commons Attribution 4.0 International
https://creativecommons.org/licenses/by/4.0/

Source copy used by this lab:
https://commons.wikimedia.org/wiki/File:Glass_Half_-_Blender_Open_Movie-full_movie.webm

The CPU-source mode uses six full-length video-only adaptations and one
shared, sample-aligned lossless audio loop. The GPU-source mode decodes the
native 3840x2160 VP9 source and creates its live ladder with CUDA and NVENC.
EOF

if [[ "$MODE" == source-only ]]; then
  echo "Native 4K source is ready for the live GPU transcoder."
  exit 0
fi

# Loop the whole film, padded with black and silence to a whole number of GOPs
# so that every loop starts on the keyframe/segment grid.
source_duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SOURCE")"
readonly CLIP_DURATION="$(
  awk -v d="$source_duration" -v g="$GOP_SECONDS" 'BEGIN { n = int(d / g); if (n * g < d) n++; print n * g }'
)"
readonly VIDEO_FRAMES=$((CLIP_DURATION * FRAME_RATE))
readonly AUDIO_SAMPLES=$((CLIP_DURATION * AUDIO_SAMPLE_RATE))
readonly GOP_FRAMES=$((GOP_SECONDS * FRAME_RATE))

audio_signature="$(
  ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_fmt,sample_rate,channels,duration_ts,duration \
    -of csv=p=0 "$AUDIO" 2>/dev/null || true
)"
if [[ "$audio_signature" == "flac,s16,$AUDIO_SAMPLE_RATE,2,$AUDIO_SAMPLES,${CLIP_DURATION}.000000" ]]; then
  echo "Keeping existing sample-aligned audio loop."
else
  echo "Encoding shared audio loop ($AUDIO_SAMPLES stereo samples at $AUDIO_SAMPLE_RATE Hz)..."
  audio_tmp="$AUDIO.part.flac"
  ffmpeg -hide_banner -loglevel warning -y \
    -i "$SOURCE" \
    -map 0:a:0 \
    -af "aresample=${AUDIO_SAMPLE_RATE}:async=1:first_pts=0,apad=whole_len=${AUDIO_SAMPLES},atrim=end_sample=${AUDIO_SAMPLES},asetpts=N/SR/TB" \
    -c:a flac -sample_fmt s16 -ar "$AUDIO_SAMPLE_RATE" -ac 2 \
    -metadata title='Glass Half - aligned live audio loop' \
    "$audio_tmp"
  mv "$audio_tmp" "$AUDIO"
fi

# label width height video-bitrate maxrate buffer H.264-level
variants=(
  '240p 426 240 150k 180k 300k 4.1'
  '360p 640 360 350k 420k 700k 4.1'
  '480p 854 480 800k 960k 1600k 4.1'
  '720p 1280 720 2000k 2400k 4000k 4.1'
  '1080p 1920 1080 4500k 5400k 9000k 4.1'
  '2160p 3840 2160 12000k 14400k 24000k 5.1'
)


for spec in "${variants[@]}"; do
  read -r label width height bitrate maxrate buffer level <<<"$spec"
  target="$VARIANT_DIR/glass-half-$label.mp4"
  video_signature="$(
    ffprobe -v error \
      -show_entries stream=codec_type,display_aspect_ratio,duration,nb_frames \
      -of csv=p=0 "$target" 2>/dev/null || true
  )"
  if [[ -s "$target" && "$video_signature" == "video,16:9,${CLIP_DURATION}.000000,$VIDEO_FRAMES" ]]; then
    echo "Keeping existing $label rendition."
    continue
  fi

  echo "Encoding $label ($width x $height, $bitrate)..."
  tmp="$target.part.mp4"
  ffmpeg -hide_banner -loglevel warning -y \
    -i "$SOURCE" \
    -map 0:v:0 -an \
    -vf "scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,setsar=1,setdar=16/9,fps=${FRAME_RATE},tpad=stop_mode=add:stop_duration=${GOP_SECONDS},trim=end_frame=${VIDEO_FRAMES},setpts=N/(${FRAME_RATE}*TB)" \
    -c:v libx264 -profile:v main -level:v "$level" -pix_fmt yuv420p -preset veryfast \
    -b:v "$bitrate" -maxrate "$maxrate" -bufsize "$buffer" \
    -g "$GOP_FRAMES" -keyint_min "$GOP_FRAMES" -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${GOP_SECONDS})" \
    -metadata title="Glass Half - $label streaming test rendition" \
    -metadata comment='Transcoded from Blender Foundation CC BY 4.0 material' \
    -movflags +faststart "$tmp"
  mv "$tmp" "$target"
done

{
  echo 'Generated adaptive bitrate ladder:'
  for file in "$VARIANT_DIR"/glass-half-*.mp4; do
    ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,avg_frame_rate,bit_rate,duration,nb_frames \
      -of csv=p=0 "$file" | sed "s#^#$(basename "$file"): #"
  done
  ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_fmt,sample_rate,channels,duration_ts,duration \
    -of csv=p=0 "$AUDIO" | sed "s#^#$(basename "$AUDIO"): #"
} | tee "$OUTPUT/RENDITIONS.txt"

echo "Media preparation complete."
