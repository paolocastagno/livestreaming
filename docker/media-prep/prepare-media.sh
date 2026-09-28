#!/usr/bin/env bash
set -euo pipefail

readonly OUTPUT=/output
readonly SOURCE_DIR="$OUTPUT/source"
readonly VARIANT_DIR="$OUTPUT/variants"
readonly SOURCE="$SOURCE_DIR/glass-half-2160p.webm"
readonly SOURCE_URL='https://commons.wikimedia.org/wiki/Special:Redirect/file/Glass_Half_-_Blender_Open_Movie-full_movie.webm'
readonly CLIP_DURATION=60
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

The CPU-source mode uses six 60-second transcoded adaptations. The GPU-source
mode decodes the native 3840x2160 VP9 source and creates its live ladder with
CUDA and NVENC.
EOF

if [[ "$MODE" == source-only ]]; then
  echo "Native 4K source is ready for the live GPU transcoder."
  exit 0
fi

# label width height video-bitrate maxrate buffer H.264-level
variants=(
  '240p 426 240 400k 500k 800k 4.1'
  '360p 640 360 800k 960k 1600k 4.1'
  '480p 854 480 1400k 1680k 2800k 4.1'
  '720p 1280 720 2800k 3360k 5600k 4.1'
  '1080p 1920 1080 5000k 6000k 10000k 4.1'
  '2160p 3840 2160 12000k 14400k 24000k 5.1'
)

for spec in "${variants[@]}"; do
  read -r label width height bitrate maxrate buffer level <<<"$spec"
  target="$VARIANT_DIR/glass-half-$label.mp4"
  display_aspect_ratio="$(
    ffprobe -v error -select_streams v:0 -show_entries stream=display_aspect_ratio \
      -of default=nw=1:nk=1 "$target" 2>/dev/null || true
  )"
  if [[ -s "$target" && "$display_aspect_ratio" == '16:9' ]]; then
    echo "Keeping existing $label rendition."
    continue
  fi

  echo "Encoding $label ($width x $height, $bitrate)..."
  tmp="$target.part.mp4"
  ffmpeg -hide_banner -loglevel warning -y \
    -i "$SOURCE" \
    -map 0:v:0 -map '0:a:0?' \
    -vf "scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,setsar=1,setdar=16/9" \
    -r 30 -c:v libx264 -profile:v main -level:v "$level" -pix_fmt yuv420p -preset veryfast \
    -b:v "$bitrate" -maxrate "$maxrate" -bufsize "$buffer" \
    -g 60 -keyint_min 60 -sc_threshold 0 -force_key_frames 'expr:gte(t,n_forced*2)' \
    -c:a aac -b:a 128k -ar 48000 -ac 2 \
    -metadata title="Glass Half - $label streaming test rendition" \
    -metadata comment='Transcoded from Blender Foundation CC BY 4.0 material' \
    -movflags +faststart -t "$CLIP_DURATION" -shortest "$tmp"
  mv "$tmp" "$target"
done

{
  echo 'Generated adaptive bitrate ladder:'
  for file in "$VARIANT_DIR"/glass-half-*.mp4; do
    ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,avg_frame_rate,bit_rate \
      -of csv=p=0 "$file" | sed "s#^#$(basename "$file"): #"
  done
} | tee "$OUTPUT/RENDITIONS.txt"

echo "Media preparation complete."
