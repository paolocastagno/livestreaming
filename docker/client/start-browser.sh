#!/usr/bin/env bash
set -euo pipefail

readonly LOG_DIR=/var/log/browser
mkdir -p "$LOG_DIR" /tmp/chromium-profile

pkill -f 'Xvfb :0' 2>/dev/null || true
pkill -x x11vnc 2>/dev/null || true
pkill -f 'websockify.*6080' 2>/dev/null || true

Xvfb :0 -screen 0 1440x900x24 -nolisten tcp >"$LOG_DIR/xvfb.log" 2>&1 &
export DISPLAY=:0
fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 >"$LOG_DIR/x11vnc.log" 2>&1 &
websockify --web=/usr/share/novnc/ 6080 localhost:5900 >"$LOG_DIR/novnc.log" 2>&1 &

for _ in $(seq 1 30); do
  curl --silent --fail http://10.0.3.2/edge-healthz >/dev/null && break
  sleep 1
done

exec chromium \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-software-rasterizer=false \
  --disable-features=TranslateUI \
  --no-first-run \
  --autoplay-policy=no-user-gesture-required \
  --user-data-dir=/tmp/chromium-profile \
  --start-maximized \
  --app=http://10.0.3.2/ >"$LOG_DIR/chromium.log" 2>&1
