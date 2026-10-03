#!/usr/bin/env bash
set -euo pipefail

readonly SERVER=10.0.3.2
readonly LOG_DIR=/var/log/background
readonly PID_DIR=/run/background

mkdir -p "$LOG_DIR" "$PID_DIR"

stop_all() {
  local pid_file pid
  for pid_file in "$PID_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    pid=$(cat "$pid_file")
    kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  done
  pkill -f 'iperf3.*10[.]0[.]3[.]2' 2>/dev/null || true
}

normalize_rate() {
  local value=$1
  case "$value" in
    *mbit) printf '%sM' "${value%mbit}" ;;
    *kbit) printf '%sK' "${value%kbit}" ;;
    *gbit) printf '%sG' "${value%gbit}" ;;
    *) printf '%s' "$value" ;;
  esac
}

start_flow() {
  local direction=$1
  local rate=$2
  local reverse=()
  local port=5202
  if [[ "$direction" == download ]]; then
    reverse=(-R)
    port=5201
  fi

  nohup iperf3 --client "$SERVER" --port "$port" "${reverse[@]}" --time 86400 \
    --bitrate "$rate" --interval 5 --forceflush \
    >"$LOG_DIR/${direction}.log" 2>&1 &
  echo $! >"$PID_DIR/${direction}.pid"
}

show_status() {
  local direction pid state
  for direction in download upload; do
    if [[ -s "$PID_DIR/${direction}.pid" ]]; then
      pid=$(cat "$PID_DIR/${direction}.pid")
      if kill -0 "$pid" 2>/dev/null; then state="running (pid $pid)"; else state="stopped"; fi
    else
      state="stopped"
    fi
    echo "$direction: $state"
  done
}

case "${1:-status}" in
  start)
    direction=${2:-}
    rate=$(normalize_rate "${3:-}")
    [[ "$direction" == download || "$direction" == upload || "$direction" == both ]] \
      || { echo "Direction must be download, upload, or both." >&2; exit 2; }
    [[ "$rate" =~ ^[0-9]+([.][0-9]+)?[KMG]$ ]] \
      || { echo "Rate must look like 20M, 500K, or 1G." >&2; exit 2; }
    stop_all
    if [[ "$direction" == download || "$direction" == both ]]; then start_flow download "$rate"; fi
    if [[ "$direction" == upload || "$direction" == both ]]; then start_flow upload "$rate"; fi
    sleep 1
    show_status
    ;;
  stop)
    stop_all
    echo "Background traffic stopped."
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: background-traffic.sh start {download|upload|both} RATE | stop | status" >&2
    exit 2
    ;;
esac
