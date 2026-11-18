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
  pkill -TERM -f 'hls-background-client' 2>/dev/null || true
  # "stopped" must mean stopped: wait for the players (up to 5 s), then kill what is left
  local i
  for i in $(seq 50); do
    pgrep -f 'hls-background-client' >/dev/null || return 0
    sleep 0.1
  done
  pkill -KILL -f 'hls-background-client' 2>/dev/null || true
}

start_hls() {
  local n=$1 abr=${2:-throughput} protocol=${3:-dash} cache=${4:-cache} spread=${5:-0} ramp=${6:-0}
  local extra=()
  [[ "$cache" == bypass ]] && extra=(--bypass)
  [[ "$spread" != 0 ]] && extra+=(--phase-spread "$spread")
  [[ "$ramp" != 0 ]] && extra+=(--ramp-sec "$ramp")
  nohup python3 /usr/local/bin/hls-background-client.py --n "$n" --abr "$abr" \
    --protocol "$protocol" "${extra[@]}" --server "http://$SERVER" \
    --seed "$RANDOM" --log "$LOG_DIR/hls.jsonl" \
    >"$LOG_DIR/hls.log" 2>&1 &
  echo $! >"$PID_DIR/hls.pid"
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
  if [[ -s "$PID_DIR/hls.pid" ]] && kill -0 "$(cat "$PID_DIR/hls.pid")" 2>/dev/null; then
    echo "hls: running (pid $(cat "$PID_DIR/hls.pid"))"
  else
    echo "hls: stopped"
  fi
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
  start-hls)
    n=${2:-}
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "N must be a positive integer." >&2; exit 2; }
    stop_all
    sleep 0.5
    : >"$LOG_DIR/hls.jsonl"
    spread=${6:-0}
    ramp=${7:-0}
    [[ "$spread" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "PHASE_SPREAD must be seconds, e.g. 4 or 2.5." >&2; exit 2; }
    [[ "$ramp" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "RAMP must be seconds, e.g. 4." >&2; exit 2; }
    start_hls "$n" "${3:-throughput}" "${4:-dash}" "${5:-cache}" "$spread" "$ramp"
    sleep 1
    show_status
    ;;
  hls-log)
    cat "$LOG_DIR/hls.jsonl" 2>/dev/null || true
    ;;
  stop)
    stop_all
    echo "Background traffic stopped."
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: background-traffic.sh start {download|upload|both} RATE | start-hls N [ABR] [dash|hls] [cache|bypass] [PHASE_SPREAD_S] [RAMP_S] | hls-log | stop | status" >&2
    exit 2
    ;;
esac
