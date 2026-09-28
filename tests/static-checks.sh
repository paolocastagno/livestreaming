#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

bash -n labctl docker/media-prep/prepare-media.sh \
  docker/source/start-publishers docker/source-gpu/start-publishers \
  docker/server/bin/start-live \
  docker/server/bin/package-hls docker/server/bin/package-dash \
  docker/server/bin/show-stream-logs docker/client/start-browser \
  docker/client/check-streams docker/traffic/background-traffic \
  lab/source.startup lab/server.startup lab/cdn.startup lab/isp.startup \
  lab/home.startup lab/client.startup lab/background.startup \
  lab/isp/usr/local/sbin/set-access-link \
  lab/home/usr/local/sbin/set-access-link

for file in \
  ARCHITECTURE.md \
  docker-compose.yml \
  docker/kathara/Dockerfile \
  docker/kathara/patch-docker-resources.py \
  docker/source/Dockerfile \
  docker/source-gpu/Dockerfile \
  docker/server/Dockerfile \
  docker/server/supervisord.conf \
  docker/cdn/Dockerfile \
  docker/cdn/nginx.conf \
  docker/client/Dockerfile \
  docker/client/nginx.conf \
  docker/traffic/Dockerfile \
  lab/lab.conf \
  lab/lab.gpu.conf \
  lab/source.startup \
  lab/server.startup \
  lab/cdn.startup \
  lab/isp.startup \
  lab/home.startup \
  lab/client.startup \
  lab/background.startup; do
  test -s "$file"
done

grep -q 'livestreaming/server:local' lab/lab.conf
grep -q 'livestreaming/source:local' lab/lab.conf
grep -q 'livestreaming/source-gpu:local' lab/lab.gpu.conf
grep -q 'source\[gpus\]="0"' lab/lab.gpu.conf
grep -q 'source\[cpuset_cpus\]="16-23"' lab/lab.gpu.conf
grep -q 'livestreaming/cdn:local' lab/lab.conf
grep -q 'livestreaming/traffic:local' lab/lab.conf
grep -q 'livestreaming/client:local' lab/lab.conf
grep -q 'dash/manifest.mpd' docker/server/web/player.js
grep -q 'hls/master.m3u8' docker/server/web/player.js
grep -q 'glass-half-2160p.mp4' docker/source/Dockerfile
grep -q 'h264_nvenc' docker/source-gpu/start-publishers
grep -q 'scale_cuda' docker/source-gpu/start-publishers
grep -q 'DeviceRequest' docker/kathara/patch-docker-resources.py
grep -q 'gpu-check' labctl
grep -q '100mbit 20mbit 10ms 0.05%' labctl
grep -q 'proxy_cache media' docker/cdn/nginx.conf
grep -q 'sfq quantum 1514 perturb' lab/isp/usr/local/sbin/set-access-link
grep -q 'traffic heavy' README.md
grep -q 'ARCHITECTURE.md' README.md
grep -q 'Playback request flow' ARCHITECTURE.md

python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("docker/kathara/patch-docker-resources.py").read_text())'

echo "Static checks passed."
