#!/usr/bin/env bash
set -euo pipefail

readonly EDGE=http://10.0.3.2

echo "Route to CDN edge:"
ip route get 10.0.3.2
traceroute -n -m 6 10.0.3.2 || true

echo
echo "Waiting for CDN, origin, and live manifests..."
curl --fail --silent --retry 20 --retry-delay 1 --retry-all-errors "$EDGE/edge-healthz"
curl --fail --silent --retry 20 --retry-delay 1 --retry-all-errors "$EDGE/origin-healthz"
curl --fail --silent --retry 90 --retry-delay 1 --retry-all-errors "$EDGE/hls/master.m3u8" > /tmp/master.m3u8
curl --fail --silent --retry 90 --retry-delay 1 --retry-all-errors "$EDGE/dash/manifest.mpd" > /tmp/manifest.mpd

grep -q '#EXT-X-STREAM-INF' /tmp/master.m3u8
grep -q '<MPD' /tmp/manifest.mpd

variants=$(grep -c '#EXT-X-STREAM-INF' /tmp/master.m3u8)
representations=$(grep -o '<Representation' /tmp/manifest.mpd | wc -l | tr -d ' ')

[[ "$variants" -eq 6 ]] || { echo "Expected 6 HLS variants, got $variants." >&2; exit 1; }
[[ "$representations" -eq 7 ]] || { echo "Expected 7 DASH audio/video representations, got $representations." >&2; exit 1; }
grep -q 'RESOLUTION=3840x2160' /tmp/master.m3u8
grep -Eq 'width="3840"[^>]*height="2160"|height="2160"[^>]*width="3840"' /tmp/manifest.mpd
grep -q 'contentType="audio"' /tmp/manifest.mpd

# Compare the phase within a four-second segment across the six video
# Representations, which the manifest lists before the audio. They share one
# encoder clock and keyframes, so their segments must start together; whole
# segment window differences are fine. Audio is left out: its segment
# boundaries need not match video's, and in GPU mode the film's 193.2-second
# loop moves the keyframes by about 170 ms each pass while A/V sync is kept.
mapfile -t timeline_timescales < <(
  sed -n 's/.*<SegmentTemplate timescale="\([0-9][0-9]*\)".*/\1/p' /tmp/manifest.mpd
)
mapfile -t timeline_ticks < <(
  sed -n 's/.*<S t="\([0-9][0-9]*\)".*/\1/p' /tmp/manifest.mpd
)
[[ "${#timeline_timescales[@]}" -eq 7 && "${#timeline_ticks[@]}" -eq 7 ]] || {
  echo "Expected seven DASH audio/video timelines." >&2
  exit 1
}

reference_phase_ms=
maximum_phase_skew_ms=0
for ((i=0; i<6; i++)); do
  start_ms=$((timeline_ticks[$i] * 1000 / timeline_timescales[$i]))
  phase_ms=$((start_ms % 4000))
  if [[ -z "$reference_phase_ms" ]]; then
    reference_phase_ms=$phase_ms
    continue
  fi
  phase_skew_ms=$((phase_ms - reference_phase_ms))
  ((phase_skew_ms < 0)) && phase_skew_ms=$((-phase_skew_ms))
  ((phase_skew_ms > 2000)) && phase_skew_ms=$((4000 - phase_skew_ms))
  ((phase_skew_ms > maximum_phase_skew_ms)) && maximum_phase_skew_ms=$phase_skew_ms
done
# 50 ms is just over one frame at 24 fps.
[[ "$maximum_phase_skew_ms" -le 50 ]] || {
  echo "DASH video timelines are misaligned by ${maximum_phase_skew_ms} ms." >&2
  exit 1
}

# Players switch renditions by segment number, so segment N must cover the same
# time in every rendition and in the audio. For each timeline, number x 4 s
# minus the segment's start time must therefore be the same; a rendition whose
# packager input joined late differs by a whole segment.
readonly SEGMENT_MS=4000
check_numbering() {
  local label=$1 reference=$2
  shift 2
  local offset
  for offset in "$@"; do
    offset=$((offset - reference))
    ((offset < 0)) && offset=$((-offset))
    ((offset < SEGMENT_MS / 2)) || {
      echo "$label segment numbering differs between renditions by ${offset} ms." >&2
      exit 1
    }
  done
}

mapfile -t start_numbers < <(
  sed -n 's/.*<SegmentTemplate .*startNumber="\([0-9][0-9]*\)".*/\1/p' /tmp/manifest.mpd
)
[[ "${#start_numbers[@]}" -eq 7 ]] || { echo "Expected seven DASH startNumber values." >&2; exit 1; }
dash_offsets=()
for ((i=0; i<7; i++)); do
  dash_offsets+=( $((start_numbers[$i] * SEGMENT_MS - timeline_ticks[$i] * 1000 / timeline_timescales[$i])) )
done
check_numbering DASH "${dash_offsets[0]}" "${dash_offsets[@]}"

# HLS playlists carry no media time, so read the first segment's tfdt.
fragment_start_ms() {
  python3 - "$1" "$2" <<'EOF'
import struct, sys

def payload(data, box):
    i = data.find(box)
    if i < 4:
        sys.exit(f'missing {box.decode()} box')
    return i + 4  # version byte

init, fragment = (open(path, 'rb').read() for path in sys.argv[1:3])
i = payload(init, b'mdhd')
timescale = struct.unpack('>I', init[i + 12:i + 16] if init[i] == 0 else init[i + 20:i + 24])[0]
i = payload(fragment, b'tfdt')
start = struct.unpack('>Q', fragment[i + 4:i + 12])[0] if fragment[i] == 1 else struct.unpack('>I', fragment[i + 4:i + 8])[0]
print(start * 1000 // timescale)
EOF
}

hls_offsets=()
for playlist in 240p 360p 480p 720p 1080p 2160p audio; do
  curl --fail --silent --show-error "$EDGE/hls/$playlist/index.m3u8" > /tmp/numbering.m3u8
  sequence=$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE:\([0-9]*\).*/\1/p' /tmp/numbering.m3u8)
  init_uri=$(sed -n 's/^#EXT-X-MAP:URI="\([^"]*\)".*/\1/p' /tmp/numbering.m3u8)
  segment_uri=$(awk '!/^#/ && NF {print; exit}' /tmp/numbering.m3u8 | tr -d '\r')
  curl --fail --silent --show-error "$EDGE/hls/$playlist/$init_uri" > /tmp/numbering-init.mp4
  # The tfdt box sits near the start of the fragment; skip the media payload.
  curl --fail --silent --show-error --range 0-65535 \
    "$EDGE/hls/$playlist/$segment_uri" > /tmp/numbering-fragment.m4s
  start_ms=$(fragment_start_ms /tmp/numbering-init.mp4 /tmp/numbering-fragment.m4s)
  hls_offsets+=( $((sequence * SEGMENT_MS - start_ms)) )
done
check_numbering HLS "${hls_offsets[0]}" "${hls_offsets[@]}"

echo "HLS:  OK ($variants variants; consistent segment numbering)"
echo "DASH: OK ($representations audio/video representations; consistent segment numbering; video max skew ${maximum_phase_skew_ms} ms)"

timeout 25 ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height -of csv=p=0 \
  "$EDGE/hls/240p/index.m3u8" > /tmp/hls-codec.csv
timeout 25 ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height -of csv=p=0 \
  "$EDGE/dash/manifest.mpd" > /tmp/dash-codec.csv
timeout 25 ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 \
  "$EDGE/hls/audio/index.m3u8" > /tmp/hls-audio-codec.csv
grep -q '^h264,426,240' /tmp/hls-codec.csv
grep -q '^h264,426,240' /tmp/dash-codec.csv
grep -q '^aac,48000,2' /tmp/hls-audio-codec.csv
echo "Media fetch/decode probe: OK (H.264 through HLS/DASH and aligned AAC audio)"

variant_uri=$(awk '!/^#/ && NF {print; exit}' /tmp/master.m3u8 | tr -d '\r')
curl --fail --silent --show-error "$EDGE/hls/$variant_uri" > /tmp/variant.m3u8
segment_uri=$(awk '!/^#/ && /\.m4s/ {print; exit}' /tmp/variant.m3u8 | tr -d '\r')
variant_dir=${variant_uri%/*}
segment_url="$EDGE/hls/$variant_dir/$segment_uri?cache-probe=1"
curl --fail --silent --show-error --dump-header /tmp/cache-first.headers --output /dev/null "$segment_url"
curl --fail --silent --show-error --dump-header /tmp/cache-second.headers --output /dev/null "$segment_url"
grep -qi '^X-Cache-Status: HIT' /tmp/cache-second.headers
echo "CDN edge: OK (manifest bypass and segment cache HIT)"
echo
echo "Household access path: client -> home gateway -> ISP -> CDN edge"

echo 'STREAM_CHECK_OK'
