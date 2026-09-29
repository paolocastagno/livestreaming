#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

bash -n labctl docker/media-prep/prepare-media.sh \
  docker/source/start-publishers docker/source-gpu/start-publishers \
  docker/server/bin/start-live \
  docker/server/bin/package-hls docker/server/bin/package-dash \
  docker/server/bin/live-start-time \
  docker/server/bin/show-stream-logs docker/client/start-browser \
  docker/client/check-streams docker/traffic/background-traffic \
  docker/rum/monitor-client \
  lab/source.startup lab/server.startup lab/cdn.startup lab/isp.startup \
  lab/home.startup lab/client.startup lab/background.startup \
  lab/isp/usr/local/sbin/set-access-link \
  lab/home/usr/local/sbin/set-access-link \
  scenarios/multi-isp/cdn.startup scenarios/multi-isp/isp2.startup \
  scenarios/multi-isp/home2.startup scenarios/multi-isp/client2.startup \
  scenarios/multi-isp/background2.startup \
  scenarios/multi-isp/isp2/usr/local/sbin/set-access-link \
  scenarios/multi-isp/home2/usr/local/sbin/set-access-link

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
  docker/rum/monitor-client \
  scenarios/single-isp/scenario.conf \
  scenarios/single-isp/lab.conf \
  scenarios/single-isp/lab.gpu.conf \
  scenarios/multi-isp/scenario.conf \
  scenarios/multi-isp/lab.conf \
  scenarios/multi-isp/lab.gpu.conf \
  lab/source.startup \
  lab/server.startup \
  lab/cdn.startup \
  lab/isp.startup \
  lab/home.startup \
  lab/client.startup \
  lab/background.startup; do
  test -s "$file"
done

grep -q 'livestreaming/server:local' scenarios/single-isp/lab.conf
grep -q 'livestreaming/source:local' scenarios/single-isp/lab.conf
grep -q 'livestreaming/source-gpu:local' scenarios/single-isp/lab.gpu.conf
grep -q 'source\[gpus\]="0"' scenarios/single-isp/lab.gpu.conf
grep -q 'source\[cpuset_cpus\]="16-23"' scenarios/single-isp/lab.gpu.conf
grep -q 'livestreaming/cdn:local' scenarios/multi-isp/lab.conf
grep -q 'livestreaming/traffic:local' scenarios/multi-isp/lab.conf
grep -q 'livestreaming/client:local' scenarios/multi-isp/lab.conf
grep -q 'isp2\[0\]="PEERING"' scenarios/multi-isp/lab.conf
grep -q 'client2\[port\]="8089:8088/tcp"' scenarios/multi-isp/lab.conf
grep -q '10.1.1.0/24 via 10.0.3.3' scenarios/multi-isp/cdn.startup
grep -q 'dash/manifest.mpd' docker/server/web/player.js
grep -q 'hls/master.m3u8' docker/server/web/player.js
grep -q 'glass-half-2160p.mp4' docker/source/Dockerfile
grep -q 'glass-half-audio.flac' docker/source/Dockerfile
grep -q 'atrim=end_sample' docker/media-prep/prepare-media.sh
grep -q 'maximum_phase_skew_ms' docker/client/check-streams
grep -q 'check_numbering HLS' docker/client/check-streams
grep -q 'live-start-time' docker/server/bin/package-hls docker/server/bin/package-dash docker/server/Dockerfile
grep -q 'h264_nvenc' docker/source-gpu/start-publishers
grep -q 'scale_cuda' docker/source-gpu/start-publishers
grep -q 'DeviceRequest' docker/kathara/patch-docker-resources.py
grep -q 'gpu-check' labctl
grep -q 'up \[SCENARIO\] \[cpu|gpu\]' labctl
grep -q 'SCENARIO_CHECK_OK' labctl
grep -q 'lstart --print' labctl
grep -q '100mbit 20mbit 10ms 0.05%' labctl
grep -q 'proxy_cache media' docker/cdn/nginx.conf
grep -q 'sfq quantum 1514 perturb' lab/isp/usr/local/sbin/set-access-link
grep -q 'traffic heavy' README.md
grep -q 'labctl rum 60s 500ms' README.md
grep -q 'results/' .gitignore
grep -q 'RUM_REVISION=' labctl
grep -q 'cgroupns=host' labctl
grep -q 'ARCHITECTURE.md' README.md
grep -q 'Playback request flow' ARCHITECTURE.md

python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("docker/kathara/patch-docker-resources.py").read_text())'

echo "Static checks passed."
