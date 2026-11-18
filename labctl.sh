#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && (pwd -W 2>/dev/null || pwd))"
readonly COMMON_LAB_DIR="$PROJECT_DIR/lab"
readonly SCENARIOS_DIR="$PROJECT_DIR/scenarios"
readonly RUNTIME_DIR="$PROJECT_DIR/.runtime"
readonly ACTIVE_MODE_FILE="$RUNTIME_DIR/source-mode"
readonly ACTIVE_SCENARIO_FILE="$RUNTIME_DIR/scenario"
readonly CLIENT_STATE_DIR="$RUNTIME_DIR/client-state"
readonly RESULTS_DIR="$PROJECT_DIR/results"
readonly RUM_REPOSITORY="https://github.com/paolocastagno/rum.git"
readonly RUM_REVISION="41839ec379222935d4e70049676571ff2daadbd2"
readonly RUM_IMAGE="${RUM_IMAGE:-rum/runtime:24.04}"

compose() {
  docker compose --project-directory "$PROJECT_DIR" "$@"
}

kathara() {
  MSYS_NO_PATHCONV=1 compose run --rm kathara "$@"
}

detect_cuda_arch() {
  if [[ -n "${CUDA_ARCH:-}" && "${CUDA_ARCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$CUDA_ARCH"
    return 0
  fi
  local arch=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    arch=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '.\r\n ' || true)
  fi
  if [[ "$arch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$arch"
  else
    printf '%s\n' 75
  fi
}

active_mode() {
  local mode=cpu
  if [[ -s "$ACTIVE_MODE_FILE" ]]; then
    read -r mode <"$ACTIVE_MODE_FILE"
  fi
  case "$mode" in
    cpu|gpu) printf '%s\n' "$mode" ;;
    *) printf '%s\n' cpu ;;
  esac
}

active_scenario() {
  local scenario=single-isp
  if [[ -s "$ACTIVE_SCENARIO_FILE" ]]; then
    read -r scenario <"$ACTIVE_SCENARIO_FILE"
  fi
  if [[ -s "$SCENARIOS_DIR/$scenario/scenario.conf" ]]; then
    printf '%s\n' "$scenario"
  else
    printf '%s\n' single-isp
  fi
}

scenario_exists() {
  [[ -s "$SCENARIOS_DIR/$1/scenario.conf" && -s "$SCENARIOS_DIR/$1/lab.conf" ]]
}

load_scenario() {
  local scenario=$1
  scenario_exists "$scenario" || {
    echo "Unknown scenario '$scenario'. Run './labctl.sh scenarios' to list them." >&2
    exit 2
  }

  SCENARIO_TITLE=
  ISP_DEVICES=()
  HOME_DEVICES=()
  CLIENT_DEVICES=()
  BACKGROUND_DEVICES=()
  CROWD_DEVICES=()  # optional: other CDN subscribers outside the households
  ALL_DEVICES=()
  VNC_PORTS=()
  SHAPED_PORTS=()
  # Scenario metadata is version-controlled alongside this launcher.
  source "$SCENARIOS_DIR/$scenario/scenario.conf"

  local count=${#ISP_DEVICES[@]}
  if [[ "$count" -eq 0 || "${#HOME_DEVICES[@]}" -ne "$count" || \
        "${#CLIENT_DEVICES[@]}" -ne "$count" || \
        "${#BACKGROUND_DEVICES[@]}" -ne "$count" || \
        "${#VNC_PORTS[@]}" -ne "$count" || \
        "${#SHAPED_PORTS[@]}" -ne "$count" ]]; then
    echo "Invalid household metadata in $scenario/scenario.conf." >&2
    exit 1
  fi
}

lab_dir() {
  printf '/workspace/.runtime/labs/%s-%s\n' "$(active_scenario)" "$(active_mode)"
}

prepare_scenario_lab() {
  local scenario=$1
  local mode=$2
  local target="$RUNTIME_DIR/labs/${scenario}-${mode}"
  scenario_exists "$scenario" || {
    echo "Unknown scenario '$scenario'. Run './labctl.sh scenarios' to list them." >&2
    exit 2
  }
  [[ "$mode" == cpu || "$mode" == gpu ]] || {
    echo "Unknown source mode '$mode'. Choose cpu or gpu." >&2
    exit 2
  }

  mkdir -p "$RUNTIME_DIR/labs"
  rm -rf "$target"
  mkdir -p "$target"
  cp -R "$COMMON_LAB_DIR/." "$target/"
  cp -R "$SCENARIOS_DIR/$scenario/." "$target/"
  if [[ "$mode" == gpu ]]; then
    cp "$target/lab.gpu.conf" "$target/lab.conf"
  fi
}

select_context() {
  local scenario=$1
  local mode=$2
  prepare_scenario_lab "$scenario" "$mode"
  mkdir -p "$RUNTIME_DIR"
  printf '%s\n' "$scenario" >"$ACTIVE_SCENARIO_FILE"
  printf '%s\n' "$mode" >"$ACTIVE_MODE_FILE"
}

initialize_client_state() {
  local client
  mkdir -p "$CLIENT_STATE_DIR"
  for client in "${CLIENT_DEVICES[@]}"; do
    printf '%s\n' 4g >"$CLIENT_STATE_DIR/$client.profile"
    printf '%s\n' off >"$CLIENT_STATE_DIR/$client.traffic"
  done
  # fresh lab: unshaped CDN egress (cdn.startup), crowd idle with the delay of crowd.startup
  printf '%s\n' off >"$CLIENT_STATE_DIR/all.fault_upstream"
  printf '%s\n' off >"$CLIENT_STATE_DIR/all.crowd"
  printf '%s\n' 20ms >"$CLIENT_STATE_DIR/all.crowd_delay"
}

write_client_state() {
  local client=$1
  local kind=$2
  local value=$3
  mkdir -p "$CLIENT_STATE_DIR"
  printf '%s\n' "$value" >"$CLIENT_STATE_DIR/$client.$kind"
}

read_client_state() {
  local client=$1
  local kind=$2
  local fallback=$3
  local path="$CLIENT_STATE_DIR/$client.$kind"
  if [[ -s "$path" ]]; then
    sed -n '1p' "$path"
  else
    printf '%s\n' "$fallback"
  fi
}

sanitize_result_token() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

client_container_id() {
  local client=$1
  local id
  local ids=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && ids+=("$id")
  done < <(
    docker ps --no-trunc \
      --filter label=app=kathara \
      --filter "label=name=$client" \
      --format '{{.ID}}'
  )

  if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "No running Kathara container found for client '$client'." >&2
    return 1
  fi
  if [[ "${#ids[@]}" -ne 1 ]]; then
    echo "More than one running Kathara container is named '$client'; stop the stale lab and retry." >&2
    return 1
  fi
  printf '%s\n' "${ids[0]}"
}

build_rum_image() {
  local source_dir=${1:-}
  if [[ -z "$source_dir" ]]; then
    source_dir="$RUNTIME_DIR/rum-$RUM_REVISION"
    if [[ ! -s "$source_dir/Makefile" ]]; then
      command -v git >/dev/null 2>&1 || {
        echo "git is required to fetch RUM. Pass an existing RUM checkout instead." >&2
        exit 1
      }
      mkdir -p "$RUNTIME_DIR"
      git clone "$RUM_REPOSITORY" "$source_dir"
      git -C "$source_dir" checkout --detach "$RUM_REVISION"
    fi
  fi

  [[ -s "$source_dir/containers/base/Dockerfile" && \
     -s "$source_dir/containers/build/Dockerfile" && \
     -s "$source_dir/containers/runtime/Dockerfile" ]] || {
    echo "'$source_dir' is not a RUM source checkout." >&2
    exit 2
  }

  source_dir="$(cd "$source_dir" && pwd)"
  echo "Building RUM from $source_dir"
  docker build --file "$source_dir/containers/base/Dockerfile" --tag rum/base:24.04 "$source_dir"
  docker build --file "$source_dir/containers/build/Dockerfile" --tag rum/build:24.04 "$source_dir"
  docker build --file "$source_dir/containers/runtime/Dockerfile" --tag "$RUM_IMAGE" "$source_dir"
}

run_rum_measurement() {
  local duration=${1:-60s}
  local interval=${2:-500ms}
  local scenario
  local mode
  local timestamp
  local slug
  local result_dir
  local candidate
  local suffix=2
  local index client profile traffic container_id monitor_name
  local failed=0
  local monitor_pids=()
  local monitor_names=()
  local container_ids=()

  [[ "$duration" =~ ^[1-9][0-9]*(ns|us|ms|s|min|h)$ ]] || {
    echo "Invalid duration '$duration'. Use a positive integer such as 30s, 500ms, or 2min." >&2
    exit 2
  }
  [[ "$interval" =~ ^[1-9][0-9]*(ns|us|ms|s|min|h)$ ]] || {
    echo "Invalid interval '$interval'. Use a positive integer such as 100ms or 1s." >&2
    exit 2
  }
  [[ $# -le 2 ]] || {
    echo "Usage: ./labctl.sh rum [DURATION] [INTERVAL]" >&2
    exit 2
  }

  need_docker
  if [[ "$(docker info --format '{{.CgroupVersion}}')" != 2 ]]; then
    echo "RUM requires a Docker host using cgroup v2." >&2
    exit 1
  fi
  if ! docker image inspect "$RUM_IMAGE" >/dev/null 2>&1; then
    echo "Missing RUM image '$RUM_IMAGE'. Run './labctl.sh rum-build [RUM_SOURCE_DIR]' first." >&2
    exit 1
  fi

  scenario=$(active_scenario)
  mode=$(active_mode)
  load_scenario "$scenario"

  # Resolve every client before creating output so a stopped or ambiguous lab
  # cannot leave behind a directory that looks like a completed experiment.
  for client in "${CLIENT_DEVICES[@]}"; do
    container_ids+=("$(client_container_id "$client")")
  done

  timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
  slug="${scenario}-${mode}"
  for client in "${CLIENT_DEVICES[@]}"; do
    profile=$(read_client_state "$client" profile 4g)
    traffic=$(read_client_state "$client" traffic off)
    slug+="_${client}-${profile}-${traffic}"
  done
  slug+="_rum-${duration}-${interval}"
  slug=$(sanitize_result_token "$slug")

  mkdir -p "$RESULTS_DIR"
  result_dir="$RESULTS_DIR/${timestamp}_${slug}"
  candidate=$result_dir
  while [[ -e "$candidate" ]]; do
    candidate="${result_dir}-${suffix}"
    suffix=$((suffix + 1))
  done
  result_dir=$candidate
  mkdir "$result_dir"

  printf '%s\n' 'scenario,source_mode,duration,interval,client,isp,access_profile,background_traffic,rum_output' \
    >"$result_dir/configuration.csv"
  for ((index=0; index<${#CLIENT_DEVICES[@]}; index++)); do
    client=${CLIENT_DEVICES[$index]}
    profile=$(read_client_state "$client" profile 4g)
    traffic=$(read_client_state "$client" traffic off)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s.csv\n' \
      "$scenario" "$mode" "$duration" "$interval" "$client" \
      "${ISP_DEVICES[$index]}" "$profile" "$traffic" "$client" \
      >>"$result_dir/configuration.csv"
  done

  stop_rum_monitors() {
    if [[ "${#monitor_names[@]}" -gt 0 ]]; then
      docker rm --force "${monitor_names[@]}" >/dev/null 2>&1 || true
    fi
  }
  trap 'stop_rum_monitors; exit 130' INT TERM

  echo "RUM output: $result_dir"
  for ((index=0; index<${#CLIENT_DEVICES[@]}; index++)); do
    client=${CLIENT_DEVICES[$index]}
    container_id=${container_ids[$index]}
    monitor_name="livestreaming-rum-${client}-$$"
    monitor_names+=("$monitor_name")
    echo "Starting RUM for $client (${container_id:0:12})..."
    docker run --rm \
      --name "$monitor_name" \
      --privileged \
      --cgroupns=host \
      --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup \
      --mount type=bind,source="$result_dir",target=/output \
      --mount type=bind,source="$PROJECT_DIR/docker/rum/monitor-client.sh",target=/monitor-client.sh,readonly \
      --entrypoint /bin/sh \
      "$RUM_IMAGE" \
      /monitor-client.sh "$container_id" "$duration" "$interval" "/output/$client.csv" \
      >"$result_dir/$client.rum.log" 2>&1 &
    monitor_pids+=("$!")
  done

  for ((index=0; index<${#monitor_pids[@]}; index++)); do
    if ! wait "${monitor_pids[$index]}"; then
      client=${CLIENT_DEVICES[$index]}
      echo "RUM failed for $client; see $result_dir/$client.rum.log" >&2
      failed=1
    fi
  done
  trap - INT TERM

  if [[ "$failed" -ne 0 ]]; then
    return 1
  fi
  echo "RUM measurement complete (${#CLIENT_DEVICES[@]} client(s))."
}

resolve_up_context() {
  local first=${1:-}
  local second=${2:-}
  RESOLVED_SCENARIO=single-isp
  RESOLVED_MODE=cpu

  case "$first" in
    '') ;;
    cpu|gpu)
      RESOLVED_MODE=$first
      [[ -z "$second" ]] || { echo "Unexpected argument '$second'." >&2; exit 2; }
      ;;
    *)
      RESOLVED_SCENARIO=$first
      RESOLVED_MODE=${second:-cpu}
      ;;
  esac

  scenario_exists "$RESOLVED_SCENARIO" || {
    echo "Unknown scenario '$RESOLVED_SCENARIO'. Run './labctl.sh scenarios' to list them." >&2
    exit 2
  }
  [[ "$RESOLVED_MODE" == cpu || "$RESOLVED_MODE" == gpu ]] || {
    echo "Unknown source mode '$RESOLVED_MODE'. Choose cpu or gpu." >&2
    exit 2
  }
}

find_household_index() {
  local selector=$1
  local i number

  if [[ "$selector" =~ ^[1-9][0-9]*$ ]]; then
    number=$((selector - 1))
    if [[ "$number" -lt "${#ISP_DEVICES[@]}" ]]; then
      printf '%s\n' "$number"
      return 0
    fi
  fi

  for ((i=0; i<${#ISP_DEVICES[@]}; i++)); do
    if [[ "$selector" == "${ISP_DEVICES[$i]}" || "$selector" == "${HOME_DEVICES[$i]}" || \
          "$selector" == "${CLIENT_DEVICES[$i]}" || "$selector" == "${BACKGROUND_DEVICES[$i]}" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

select_households() {
  local selector=${1:-all}
  local idx i
  SELECTED_INDEXES=()

  if [[ "$selector" == all ]]; then
    for ((i=0; i<${#ISP_DEVICES[@]}; i++)); do SELECTED_INDEXES+=("$i"); done
    return
  fi

  if idx=$(find_household_index "$selector"); then
    SELECTED_INDEXES+=("$idx")
    return
  fi

  echo "Unknown household '$selector'. Choose all, a 1-based number, or an ISP/device name." >&2
  exit 2
}

is_household_selector() {
  [[ "$1" == all ]] && return 0
  find_household_index "$1" >/dev/null 2>&1
}

device_exists() {
  local requested=$1
  local device
  for device in "${ALL_DEVICES[@]}"; do
    [[ "$requested" == "$device" ]] && return 0
  done
  return 1
}

crowd_device() {
  if [[ "${#CROWD_DEVICES[@]}" -eq 0 ]]; then
    echo "Scenario '$(active_scenario)' has no crowd device (CROWD_DEVICES in scenario.conf)." >&2
    exit 2
  fi
  printf '%s\n' "${CROWD_DEVICES[0]}"
}

rate_to_bps() {
  [[ "$1" =~ ^([1-9][0-9]*)(kbit|mbit|gbit)$ ]] || return 1
  case "${BASH_REMATCH[2]}" in
    kbit) printf '%s\n' $((10#${BASH_REMATCH[1]} * 1000)) ;;
    mbit) printf '%s\n' $((10#${BASH_REMATCH[1]} * 1000000)) ;;
    gbit) printf '%s\n' $((10#${BASH_REMATCH[1]} * 1000000000)) ;;
  esac
}

# Shared CDN->provider link: cdn eth1 is the egress of every household's segments and of the
# crowd's ones. HTB at RATE, the fixed 2 ms backbone delay of cdn.startup, then the queue of the
# shared link: drop-tail FIFO holding BUFFER_MS at RATE (default, core router), fq_codel (AQM) or
# SFQ (per-flow fairness, as on the access links). Owns the cdn eth1 root like 'fault cdn-delay':
# the two are mutually exclusive.
apply_upstream() {
  local rate=$1 qdisc=$2 buffer_ms=$3
  local bps bytes pkts leaf
  bps=$(rate_to_bps "$rate") || { echo "Invalid rate '$rate' (e.g. 30mbit, 2500kbit)." >&2; exit 2; }
  [[ "$buffer_ms" =~ ^[1-9][0-9]*$ ]] || { echo "buffer_ms must be a positive integer (ms)." >&2; exit 2; }
  bytes=$((bps / 8 * buffer_ms / 1000))
  if ((bytes < 15140)); then bytes=15140; fi
  pkts=$(((bytes + 1513) / 1514))
  case "$qdisc" in
    fifo) leaf="bfifo limit $bytes" ;;
    fqcodel) leaf="fq_codel" ;;
    sfq)
      if ((pkts < 127)); then pkts=127; fi
      leaf="sfq quantum 1514 perturb 10 limit $pkts"
      ;;
    *) echo "Unknown qdisc '$qdisc'. Choose fifo, fqcodel, or sfq." >&2; exit 2 ;;
  esac
  local out
  out=$(kathara exec --wait -d "$(lab_dir)" cdn -- sh -c "
    tc qdisc del dev eth1 root 2>/dev/null
    tc qdisc add dev eth1 root handle 1: htb default 10 &&
    tc class add dev eth1 parent 1: classid 1:10 htb rate $rate ceil $rate burst 64k cburst 64k quantum 1514 &&
    tc qdisc add dev eth1 parent 1:10 handle 10: netem delay 2ms limit 100000 &&
    tc qdisc add dev eth1 parent 10:1 handle 20: $leaf
    tc qdisc show dev eth1")
  # a fault that is not in place would invalidate the label: check the result, not the exit status
  if ! grep -q "qdisc htb 1: root" <<<"$out" || ! grep -q "qdisc ${leaf%% *} 20:" <<<"$out"; then
    printf '%s\n' "$out" >&2
    echo "upstream: FAILED, cdn eth1 is not shaped as requested" >&2
    exit 1
  fi
  write_client_state "all" "fault_upstream" "${rate}_${qdisc}_${buffer_ms}ms"
  echo "upstream: SHAPED (cdn eth1 rate=$rate qdisc=$qdisc buffer=${buffer_ms}ms, $bytes B)"
}

clear_upstream() {
  local out
  out=$(kathara exec --wait -d "$(lab_dir)" cdn -- sh -c 'tc qdisc del dev eth1 root 2>/dev/null; tc qdisc add dev eth1 root netem delay 2ms; tc qdisc show dev eth1')
  if grep -q "qdisc htb" <<<"$out" || ! grep -q "qdisc netem .*root" <<<"$out"; then
    printf '%s\n' "$out" >&2
    echo "upstream: FAILED to restore the unshaped cdn eth1" >&2
    exit 1
  fi
  write_client_state "all" "fault_upstream" "off"
  echo "upstream: CLEARED (nominal: unshaped, 2 ms)"
}

check_crowd_players() {
  local abr=$1 proto=$2 cache=$3 spread=$4 ramp=${5:-4}
  [[ "$abr" =~ ^(throughput|buffer|hybrid)$ ]] || { echo "ABR must be throughput, buffer, or hybrid." >&2; exit 2; }
  [[ "$proto" =~ ^(dash|hls)$ ]] || { echo "Protocol must be dash or hls." >&2; exit 2; }
  [[ "$cache" =~ ^(cache|bypass)$ ]] || { echo "Cache mode must be cache or bypass." >&2; exit 2; }
  [[ "$spread" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Phase spread must be seconds, e.g. 0 or 4." >&2; exit 2; }
  [[ "$ramp" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Ramp must be seconds, e.g. 4." >&2; exit 2; }
}

# Crowd: other subscribers of the CDN edge outside every household, N headless ABR players on the
# crowd device (same generator as the household background, see docker/traffic). With proto=dash
# they load the shared link but not the HLS player's cache keys; proto=hls is the flash crowd of the
# same live event (shared cache). Their segments cross only the shared cdn eth1 queue. All players
# start within RAMP s (default 4: one segment), so a large crowd is at full strength quickly.
# The state is set before starting, so that 'fault reset' stops a crowd whose start went wrong.
crowd_traffic() {
  local dev out action=${1:-status}
  dev=$(crowd_device)
  case "$action" in
    off|stop)
      kathara exec --wait -d "$(lab_dir)" "$dev" -- /usr/local/bin/background-traffic.sh stop
      write_client_state "all" "crowd" "off"
      ;;
    status)
      kathara exec --wait -d "$(lab_dir)" "$dev" -- /usr/local/bin/background-traffic.sh status
      echo "crowd: $(read_client_state all crowd off), egress delay $(read_client_state all crowd_delay 20ms)"
      ;;
    log)
      kathara exec --wait -d "$(lab_dir)" "$dev" -- /usr/local/bin/background-traffic.sh hls-log
      ;;
    delay)
      [[ "${2:-}" =~ ^[0-9]+ms$ ]] || { echo "Usage: ./labctl.sh traffic crowd delay DELAY (e.g. 30ms)" >&2; exit 2; }
      kathara exec --wait -d "$(lab_dir)" "$dev" -- tc qdisc replace dev eth0 root netem delay "$2" limit 10000
      write_client_state "all" "crowd_delay" "$2"
      echo "crowd: one-way delay on the crowd egress = $2"
      ;;
    *)
      [[ "$action" =~ ^[1-9][0-9]*$ ]] || {
        echo "Usage: ./labctl.sh traffic crowd {N [ABR] [dash|hls] [cache|bypass] [PHASE_SPREAD_S] [RAMP_S]|delay DELAY|status|log|off}" >&2
        exit 2
      }
      check_crowd_players "${2:-throughput}" "${3:-dash}" "${4:-cache}" "${5:-0}" "${6:-4}"
      write_client_state "all" "crowd" "starting"
      out=$(kathara exec --wait -d "$(lab_dir)" "$dev" -- /usr/local/bin/background-traffic.sh start-hls \
        "$action" "${2:-throughput}" "${3:-dash}" "${4:-cache}" "${5:-0}" "${6:-4}")
      printf '%s\n' "$out"
      grep -q "hls: running" <<<"$out" || { echo "crowd: FAILED, players not running on $dev" >&2; exit 1; }
      write_client_state "all" "crowd" "hls${action}-${3:-dash}-${4:-cache}-spread${5:-0}"
      ;;
  esac
}

print_endpoints() {
  local i
  for ((i=0; i<${#CLIENT_DEVICES[@]}; i++)); do
    echo "  Household $((i + 1)) (${ISP_DEVICES[$i]}):"
    echo "    noVNC:  http://localhost:${VNC_PORTS[$i]}/vnc.html?autoconnect=true&resize=scale"
    echo "    shaped: http://localhost:${SHAPED_PORTS[$i]}/"
  done
}

list_scenarios() {
  local directory scenario
  for directory in "$SCENARIOS_DIR"/*; do
    [[ -d "$directory" && -s "$directory/scenario.conf" ]] || continue
    scenario=${directory##*/}
    (
      source "$directory/scenario.conf"
      printf '%-12s %s\n' "$scenario" "$SCENARIO_TITLE"
    )
  done
}

need_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker is not reachable. Start Docker Desktop (or the Docker daemon) and retry." >&2
    exit 1
  fi
}

need_media() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media/generated/variants"
  local quality
  for quality in 240p 360p 480p 720p 1080p 2160p; do
    if [[ ! -s "$root/glass-half-${quality}.mp4" ]]; then
      echo "Missing generated media. Run './labctl.sh prepare' first." >&2
      exit 1
    fi
  done
  if [[ ! -s "$root/glass-half-audio.flac" ]]; then
    echo "Missing generated audio loop. Run './labctl.sh prepare' first." >&2
    exit 1
  fi
}

need_gpu_media() {
  local source="$PROJECT_DIR/media/generated/source/glass-half-2160p.webm"
  if [[ ! -s "$source" ]]; then
    echo "Missing native 4K source. Run './labctl.sh prepare gpu' first." >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Container-only adaptive live-streaming experiment

Usage: ./labctl.sh COMMAND [ARGS]

  up [SCENARIO] [cpu|gpu]       Prepare/build, then start every scenario device
  up [cpu|gpu]                  Start single-isp (backward-compatible form)
  down                         Stop the active Kathara scenario
  scenarios                    List the available scenarios
  validate [SCENARIO] [MODE]   Check a scenario without starting its devices
  prepare [cpu|gpu]            Prepare the CPU ladder or native 4K GPU source
  build [cpu|gpu]              Build images for the selected source mode
  gpu-check                    Verify GPU access, FFmpeg, and one NVENC encode
  mode                         Show the active scenario, source, and lab path
  status                       Show Kathara device status and topology
  check                        Validate every player path in the scenario
  profile NAME [TARGET]        Apply an access profile to all or one household
  traffic PRESET [TARGET]      Control cross traffic for all or one household
  traffic DIR RATE [TARGET]    Start custom download, upload, or both traffic
  traffic hls N [ABR] [dash|hls] [bypass] [TARGET]
                               Start N competing headless ABR players
  traffic crowd N [ABR] [dash|hls] [cache|bypass] [PHASE_SPREAD_S] [RAMP_S]
                               Start N ABR players of other CDN subscribers
                               (crowd device, outside every household)
  traffic crowd {delay DELAY|status|log|off}
  fault ACTION [ARGS...]       Inject/control physical faults (origin, cdn, cpu, access, traffic,
                               upstream, crowd)
  fault upstream RATE [qdisc=fifo|fqcodel|sfq] [buffer_ms=100] | off
                               Shape the shared CDN->provider link (cdn eth1)
  fault crowd N RATE [qdisc=..] [buffer_ms=..] [delay=..] [proto=dash|hls]
              [cache=cache|bypass] [spread=S] [ramp=4] [abr=..] | off
                               Shared-link congestion by N crowd players
  rum-build [SOURCE_DIR]       Build the pinned RUM runtime image
  traffic-deploy               Copy the traffic scripts into running background/crowd devices
  rum [DURATION] [INTERVAL]    Measure every client (defaults: 60s, 500ms)
  rum-cgroup CGROUP DURATION INTERVAL OUTPUT
                               Measure an arbitrary host cgroup v2 path to OUTPUT (CSV)
  shell DEVICE                 Open a shell in a scenario device
  exec DEVICE CMD...           Run a command in a scenario device
  logs                         Tail source, origin, and CDN logs
  clean-media                  Remove generated media after confirmation
  help                         Show this message

TARGET defaults to all and may be a 1-based household number, ISP name, or
household device name. The source mode defaults to cpu.

The origin debug endpoint is at http://localhost:8080 and the CDN edge debug
endpoint is at http://localhost:8081. Both bypass the residential access path.
EOF
}

case "${1:-help}" in
  prepare)
    need_docker
    compose build media-prep
    case "${2:-cpu}" in
      cpu) compose run --rm media-prep all ;;
      gpu) compose run --rm media-prep source-only ;;
      *) echo "Choose cpu or gpu." >&2; exit 2 ;;
    esac
    ;;
  build)
    need_docker
    case "${2:-cpu}" in
      cpu)
        need_media
        compose build kathara stream-source stream-server cdn-edge stream-client traffic-client
        ;;
      gpu)
        need_gpu_media
        cuda_arch=$(detect_cuda_arch)
        echo "Building GPU source image for CUDA architecture compute_${cuda_arch} (sm_${cuda_arch})..."
        CUDA_ARCH="$cuda_arch" compose build kathara stream-source-gpu stream-server cdn-edge stream-client traffic-client
        ;;
      *) echo "Choose cpu or gpu." >&2; exit 2 ;;
    esac
    ;;
  up)
    need_docker
    resolve_up_context "${2:-}" "${3:-}"
    source_mode=$RESOLVED_MODE
    scenario=$RESOLVED_SCENARIO
    "$0" prepare "$source_mode"
    "$0" build "$source_mode"
    select_context "$scenario" "$source_mode"
    load_scenario "$scenario"
    initialize_client_state
    kathara lstart --noterminals --no-shared -d "$(lab_dir)"
    echo
    echo "Scenario '$scenario' started with the $source_mode source."
    echo "Give the live packagers about 10 seconds, then open:"
    print_endpoints
    echo
    echo "Experiment controls: './labctl.sh profile NAME' and './labctl.sh traffic PRESET'."
    ;;
  down)
    need_docker
    kathara lclean -d "$(lab_dir)"
    compose --profile "*" down --remove-orphans
    ;;
  status)
    need_docker
    echo "Scenario: $(active_scenario)"
    echo "Source mode: $(active_mode)"
    kathara linfo -d "$(lab_dir)" --topology
    ;;
  check)
    need_docker
    load_scenario "$(active_scenario)"
    for client in "${CLIENT_DEVICES[@]}"; do
      echo "===== validating $client ====="
      output="$(kathara exec --wait -d "$(lab_dir)" "$client" -- /usr/local/bin/check-streams.sh)"
      printf '%s\n' "$output"
      if ! grep -q '^STREAM_CHECK_OK$' <<<"$output"; then
        echo "Stream validation failed inside $client." >&2
        exit 1
      fi
    done
    echo "SCENARIO_CHECK_OK ($(active_scenario), ${#CLIENT_DEVICES[@]} player path(s))"
    ;;
  profile)
    need_docker
    load_scenario "$(active_scenario)"
    case "${2:-}" in
      fiber)     args=(300mbit 100mbit 3ms 0.001%) ;;
      5g)        args=(100mbit 20mbit 10ms 0.05%) ;;
      4g)        args=(20mbit 5mbit 25ms 0.2%) ;;
      dsl)       args=(15mbit 1mbit 15ms 0.05%) ;;
      congested) args=(5mbit 1mbit 50ms 1%) ;;
      3g)        args=(1500kbit 500kbit 60ms 1%) ;;
      bad)       args=(600kbit 256kbit 150ms 3%) ;;
      clear)     args=(clear clear 0ms 0%) ;;
      *)
        echo "Unknown profile '${2:-}'. Choose: fiber, 5g, 4g, dsl, congested, 3g, bad, clear." >&2
        exit 2
        ;;
    esac
    select_households "${3:-all}"
    for index in "${SELECTED_INDEXES[@]}"; do
      if [[ "${args[0]}" == clear ]]; then
        kathara exec --wait -d "$(lab_dir)" "${ISP_DEVICES[$index]}" -- /usr/local/sbin/set-access-link.sh eth1 clear
        kathara exec --wait -d "$(lab_dir)" "${HOME_DEVICES[$index]}" -- /usr/local/sbin/set-access-link.sh eth0 clear
      else
        kathara exec --wait -d "$(lab_dir)" "${ISP_DEVICES[$index]}" -- /usr/local/sbin/set-access-link.sh eth1 "${args[0]}" "${args[2]}" "${args[3]}"
        kathara exec --wait -d "$(lab_dir)" "${HOME_DEVICES[$index]}" -- /usr/local/sbin/set-access-link.sh eth0 "${args[1]}" "${args[2]}" "${args[3]}"
      fi
      write_client_state "${CLIENT_DEVICES[$index]}" profile "${2}"
      echo "${ISP_DEVICES[$index]} profile '${2}': down=${args[0]} up=${args[1]} delay=${args[2]}/direction loss=${args[3]}"
    done
    ;;
  traffic)
    need_docker
    load_scenario "$(active_scenario)"
    if [[ "${2:-}" == crowd ]]; then
      crowd_traffic "${@:3}"
      exit 0
    fi
    traffic_target=all
    case "${2:-status}" in
      off)
        traffic_args=(stop)
        traffic_target=${3:-all}
        ;;
      status)
        traffic_args=(status)
        traffic_target=${3:-all}
        ;;
      light|medium|heavy)
        case "$2" in
          light) rate=5M ;;
          medium) rate=20M ;;
          heavy) rate=80M ;;
        esac
        traffic_args=(start download "$rate")
        traffic_target=${3:-all}
        ;;
      upload)
        if [[ -n "${3:-}" ]] && is_household_selector "$3"; then
          traffic_args=(start upload 10M)
          traffic_target=$3
        else
          traffic_args=(start upload "${3:-10M}")
          traffic_target=${4:-all}
        fi
        ;;
      hls)
        [[ "${3:-}" =~ ^[1-9][0-9]*$ ]] || {
          echo "Usage: ./labctl.sh traffic hls N [ABR=throughput] [dash|hls] [bypass|cache] [TARGET]" >&2; exit 2; }
        traffic_args=(start-hls "$3" "${4:-throughput}" "${5:-dash}" "${6:-cache}")
        traffic_target=${7:-all}
        ;;
      download|both)
        [[ -n "${3:-}" ]] || { echo "Usage: ./labctl.sh traffic ${2} RATE [TARGET]" >&2; exit 2; }
        traffic_args=(start "${2}" "${3}")
        traffic_target=${4:-all}
        ;;
      *)
        echo "Unknown traffic mode '${2:-}'. Choose off, light, medium, heavy, upload, status, download RATE, both RATE, hls N, or crowd N." >&2
        exit 2
        ;;
    esac
    select_households "$traffic_target"
    for index in "${SELECTED_INDEXES[@]}"; do
      echo "===== ${BACKGROUND_DEVICES[$index]} (${ISP_DEVICES[$index]}) ====="
      kathara exec --wait -d "$(lab_dir)" "${BACKGROUND_DEVICES[$index]}" -- /usr/local/bin/background-traffic.sh "${traffic_args[@]}"
      case "${traffic_args[0]}" in
        stop) write_client_state "${CLIENT_DEVICES[$index]}" traffic off ;;
        start) write_client_state "${CLIENT_DEVICES[$index]}" traffic "${traffic_args[1]}-${traffic_args[2]}" ;;
        start-hls) write_client_state "${CLIENT_DEVICES[$index]}" traffic "hls${traffic_args[1]}-${traffic_args[3]}-${traffic_args[4]}" ;;
      esac
    done
    ;;
  fault)
    need_docker
    load_scenario "$(active_scenario)"
    fault_action=${2:-status}
    case "$fault_action" in
      status)
        echo "===== Active Faults in scenario '$(active_scenario)' ====="
        echo -n "origin_latency: "
        kathara exec --wait -d "$(lab_dir)" server -- sh -c 'tc qdisc show dev eth1 | grep -q netem && tc qdisc show dev eth1 || echo "nominal (none)"'
        echo -n "cdn_delay: "
        kathara exec --wait -d "$(lab_dir)" cdn -- sh -c 'tc qdisc show dev eth1 | grep -q netem && tc qdisc show dev eth1 || echo "nominal (none)"'
        echo -n "edge_delay: "
        read_client_state "all" "fault_edge_delay" "off"
        echo -n "origin_proc_delay: "
        read_client_state "all" "fault_origin_proc" "off"
        echo -n "cdn_bypass: "
        read_client_state "all" "fault_cdn_bypass" "off"
        echo -n "upstream: "
        read_client_state "all" "fault_upstream" "off"
        if [[ "${#CROWD_DEVICES[@]}" -gt 0 ]]; then
          echo -n "crowd: "
          read_client_state "all" "crowd" "off"
        fi
        for client in "${CLIENT_DEVICES[@]}"; do
          echo -n "$client cpu stress: "
          kathara exec --wait -d "$(lab_dir)" "$client" -- sh -c 'pgrep stress-ng >/dev/null && echo "ACTIVE (stress-ng running)" || echo "nominal (none)"'
        done
        ;;
      origin-delay)
        delay=${3:-1500ms}
        jitter=${4:-150ms}
        if [[ "$delay" == clear || "$delay" == off || "$delay" == 0ms ]]; then
          kathara exec --wait -d "$(lab_dir)" server -- tc qdisc del dev eth1 root 2>/dev/null || true
          write_client_state "all" "fault_origin" "off"
          echo "origin_latency: CLEARED (nominal)"
        else
          kathara exec --wait -d "$(lab_dir)" server -- tc qdisc del dev eth1 root 2>/dev/null || true
          if [[ "$jitter" == 0 || "$jitter" == 0ms ]]; then
            # netem rejects 'distribution' without a jitter
            kathara exec --wait -d "$(lab_dir)" server -- tc qdisc add dev eth1 root netem delay "$delay"
          else
            kathara exec --wait -d "$(lab_dir)" server -- tc qdisc add dev eth1 root netem delay "$delay" "$jitter" distribution normal
          fi
          write_client_state "all" "fault_origin" "${delay}_${jitter}"
          echo "origin_latency: INJECTED (delay=$delay jitter=$jitter on server eth1)"
        fi
        ;;
      cdn-delay)
        delay=${3:-1000ms}
        if [[ "$delay" == clear || "$delay" == off || "$delay" == 0ms ]]; then
          # restore the fixed 2 ms backbone delay installed by cdn.startup
          kathara exec --wait -d "$(lab_dir)" cdn -- tc qdisc replace dev eth1 root netem delay 2ms
          write_client_state "all" "fault_cdn_delay" "off"
          echo "cdn_delay: CLEARED (nominal)"
        else
          kathara exec --wait -d "$(lab_dir)" cdn -- tc qdisc del dev eth1 root 2>/dev/null || true
          kathara exec --wait -d "$(lab_dir)" cdn -- tc qdisc add dev eth1 root netem delay "$delay"
          write_client_state "all" "fault_cdn_delay" "$delay"
          echo "cdn_delay: INJECTED (delay=$delay on cdn eth1)"
        fi
        ;;
      edge-delay)
        # Edge *processing* delay: only HTTP request packets (client->CDN, TCP dport 80,
        # IP length >= 128 B) are delayed on the ISP backbone egress, so TTFB grows by
        # DELAY while ACKs and the transfer rate are untouched (unlike cdn-delay, which
        # delays every packet and therefore also the TCP throughput).
        delay=${3:-500ms}
        for isp in "${ISP_DEVICES[@]}"; do
          if [[ "$delay" == clear || "$delay" == off || "$delay" == 0ms ]]; then
            kathara exec --wait -d "$(lab_dir)" "$isp" -- sh -c 'tc qdisc del dev eth0 root 2>/dev/null; tc qdisc add dev eth0 root netem delay 2ms'
          else
            [[ "$delay" =~ ^[0-9]+ms$ ]] || { echo "edge-delay expects milliseconds, e.g. 500ms" >&2; exit 2; }
            kathara exec --wait -d "$(lab_dir)" "$isp" -- sh -c "
              tc qdisc del dev eth0 root 2>/dev/null
              tc qdisc add dev eth0 root handle 1: prio bands 3 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
              tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 2ms
              tc qdisc add dev eth0 parent 1:2 handle 20: netem delay \$((2 + ${delay%ms}))ms
              for m in '0x0080 0xff80' '0x0100 0xff00' '0x0200 0xfe00' '0x0400 0xfc00'; do
                tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 6 0xff match ip dport 80 0xffff match u16 \$m at 2 flowid 1:2
              done"
          fi
        done
        if [[ "$delay" == clear || "$delay" == off || "$delay" == 0ms ]]; then
          write_client_state "all" "fault_edge_delay" "off"
          echo "edge_delay: CLEARED (nominal)"
        else
          write_client_state "all" "fault_edge_delay" "$delay"
          echo "edge_delay: INJECTED (request delay=$delay on ISP backbone egress)"
        fi
        ;;
      origin-proc-delay)
        # Origin *processing* delay: only HTTP requests CDN->origin (TCP dport 80, IP length
        # >= 128 B) are delayed on the CDN's ORIGIN-side interface (eth0), so the TTFB of
        # cache misses and playlist fetches grows by DELAY while the origin->CDN transfer rate
        # is untouched. 'origin-delay' instead delays every packet (RTT and TCP throughput).
        delay=${3:-800ms}
        if [[ "$delay" == clear || "$delay" == off || "$delay" == 0ms ]]; then
          kathara exec --wait -d "$(lab_dir)" cdn -- sh -c 'tc qdisc del dev eth0 root 2>/dev/null || true'
          write_client_state "all" "fault_origin_proc" "off"
          echo "origin_proc_delay: CLEARED (nominal)"
        else
          [[ "$delay" =~ ^[0-9]+ms$ ]] || { echo "origin-proc-delay expects milliseconds, e.g. 800ms" >&2; exit 2; }
          kathara exec --wait -d "$(lab_dir)" cdn -- sh -c "
            tc qdisc del dev eth0 root 2>/dev/null
            tc qdisc add dev eth0 root handle 1: prio bands 3 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
            tc qdisc add dev eth0 parent 1:2 handle 20: netem delay ${delay}
            for m in '0x0080 0xff80' '0x0100 0xff00' '0x0200 0xfe00' '0x0400 0xfc00'; do
              tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 6 0xff match ip dport 80 0xffff match u16 \$m at 2 flowid 1:2
            done"
          write_client_state "all" "fault_origin_proc" "$delay"
          echo "origin_proc_delay: INJECTED (request delay=$delay on cdn eth0)"
        fi
        ;;
      upstream)
        # Capacity and queue of the shared CDN->provider link (cdn eth1); 'off' restores the
        # unshaped 2 ms link of cdn.startup. Options: qdisc=fifo|fqcodel|sfq buffer_ms=100.
        if [[ "${3:-}" == off || "${3:-}" == clear ]]; then
          clear_upstream
        else
          [[ -n "${3:-}" ]] || { echo "Usage: ./labctl.sh fault upstream RATE [qdisc=fifo|fqcodel|sfq] [buffer_ms=100] | off" >&2; exit 2; }
          qdisc=fifo
          buffer_ms=100
          for opt in "${@:4}"; do
            case "$opt" in
              qdisc=*) qdisc=${opt#*=} ;;
              buffer_ms=*) buffer_ms=${opt#*=} ;;
              *) echo "Unknown option '$opt' for fault upstream." >&2; exit 2 ;;
            esac
          done
          apply_upstream "$3" "$qdisc" "$buffer_ms"
        fi
        ;;
      crowd)
        # Congestion of the shared CDN->provider link by other subscribers of the edge, outside every
        # household: shape cdn eth1 (as 'fault upstream') and start N crowd players. Options:
        # qdisc/buffer_ms (shared link), delay (one-way delay on the crowd egress, i.e. crowd RTT),
        # proto/cache/abr (crowd players), spread (phase spread at the live edge, s; 0 = synchronised).
        if [[ "${3:-}" == off || "${3:-}" == clear ]]; then
          clear_upstream
          crowd_traffic off
        else
          [[ "${3:-}" =~ ^[1-9][0-9]*$ && -n "${4:-}" ]] || {
            echo "Usage: ./labctl.sh fault crowd N RATE [qdisc=fifo|fqcodel|sfq] [buffer_ms=100] [delay=20ms] [proto=dash|hls] [cache=cache|bypass] [spread=0] [ramp=4] [abr=throughput] | off" >&2
            exit 2
          }
          crowd_n=$3
          qdisc=fifo
          buffer_ms=100
          crowd_delay=
          proto=dash
          cache=cache
          spread=0
          ramp=4
          abr=throughput
          for opt in "${@:5}"; do
            case "$opt" in
              qdisc=*) qdisc=${opt#*=} ;;
              buffer_ms=*) buffer_ms=${opt#*=} ;;
              delay=*) crowd_delay=${opt#*=} ;;
              proto=*) proto=${opt#*=} ;;
              cache=*) cache=${opt#*=} ;;
              spread=*) spread=${opt#*=} ;;
              ramp=*) ramp=${opt#*=} ;;
              abr=*) abr=${opt#*=} ;;
              *) echo "Unknown option '$opt' for fault crowd." >&2; exit 2 ;;
            esac
          done
          check_crowd_players "$abr" "$proto" "$cache" "$spread" "$ramp"
          [[ -z "$crowd_delay" || "$crowd_delay" =~ ^[0-9]+ms$ ]] || { echo "delay must be milliseconds, e.g. 30ms." >&2; exit 2; }
          crowd_dev=$(crowd_device)
          apply_upstream "$4" "$qdisc" "$buffer_ms"
          write_client_state "all" "crowd" "starting"
          # one exec for the crowd RTT and the players (the fault onset is timed by the caller)
          out=$(kathara exec --wait -d "$(lab_dir)" "$crowd_dev" -- sh -c "${crowd_delay:+tc qdisc replace dev eth0 root netem delay $crowd_delay limit 10000 && }/usr/local/bin/background-traffic.sh start-hls $crowd_n $abr $proto $cache $spread $ramp; tc qdisc show dev eth0")
          if ! grep -q "hls: running" <<<"$out" || { [[ -n "$crowd_delay" ]] && ! grep -q "delay $crowd_delay" <<<"$out"; }; then
            printf '%s\n' "$out" >&2
            echo "crowd: FAILED, players or crowd delay not in place on $crowd_dev" >&2
            exit 1
          fi
          [[ -z "$crowd_delay" ]] || write_client_state "all" "crowd_delay" "$crowd_delay"
          write_client_state "all" "crowd" "hls${crowd_n}-${proto}-${cache}-spread${spread}"
          echo "crowd: INJECTED (n=$crowd_n proto=$proto cache=$cache spread=${spread}s delay=${crowd_delay:-unchanged})"
        fi
        ;;
      cdn-purge)
        kathara exec --wait -d "$(lab_dir)" cdn -- sh -c 'rm -rf /var/cache/nginx/media/* 2>/dev/null || true'
        echo "cdn_cache: PURGED (/var/cache/nginx/media cleared)"
        ;;
      cdn-bypass)
        mode=${3:-on}
        if [[ "$mode" == on || "$mode" == 1 || "$mode" == enable ]]; then
          write_client_state "all" "fault_cdn_bypass" "on"
          echo "cdn_cache: BYPASS ENABLED (clients will request X-Force-Bypass-Cache: 1)"
        else
          write_client_state "all" "fault_cdn_bypass" "off"
          echo "cdn_cache: BYPASS DISABLED (nominal)"
        fi
        ;;
      client-cpu)
        load_pct=${3:-95}
        duration=${4:-60}
        target=${5:-all}
        select_households "$target"
        for index in "${SELECTED_INDEXES[@]}"; do
          client="${CLIENT_DEVICES[$index]}"
          if [[ "$load_pct" == clear || "$load_pct" == off || "$load_pct" == 0 ]]; then
            kathara exec --wait -d "$(lab_dir)" "$client" -- sh -c 'pkill -9 stress-ng 2>/dev/null || true'
            write_client_state "$client" "fault_cpu" "off"
            echo "$client cpu stress: CLEARED"
          else
            kathara exec --wait -d "$(lab_dir)" "$client" -- sh -c "pkill -9 stress-ng 2>/dev/null || true; nohup stress-ng --cpu 2 --cpu-load $load_pct --timeout ${duration}s >/dev/null 2>&1 &"
            write_client_state "$client" "fault_cpu" "${load_pct}%_${duration}s"
            echo "$client cpu stress: INJECTED (load=${load_pct}% duration=${duration}s)"
          fi
        done
        ;;
      access)
        profile=${3:-bad}
        target=${4:-all}
        "$0" profile "$profile" "$target"
        ;;
      traffic)
        preset=${3:-heavy}
        target=${4:-all}
        "$0" traffic "$preset" "$target"
        ;;
      reset|clear)
        echo "===== Resetting all faults to nominal ====="
        kathara exec --wait -d "$(lab_dir)" server -- tc qdisc del dev eth1 root 2>/dev/null || true
        write_client_state "all" "fault_origin" "off"
        # del + add: also removes the HTB root of 'fault upstream'/'fault crowd'
        kathara exec --wait -d "$(lab_dir)" cdn -- sh -c 'tc qdisc del dev eth1 root 2>/dev/null; tc qdisc add dev eth1 root netem delay 2ms'
        write_client_state "all" "fault_cdn_delay" "off"
        write_client_state "all" "fault_upstream" "off"
        "$0" fault edge-delay off >/dev/null 2>&1 || true
        "$0" fault origin-proc-delay off >/dev/null 2>&1 || true
        write_client_state "all" "fault_cdn_bypass" "off"
        for client in "${CLIENT_DEVICES[@]}"; do
          kathara exec --wait -d "$(lab_dir)" "$client" -- sh -c 'pkill -9 stress-ng 2>/dev/null || true'
          write_client_state "$client" "fault_cpu" "off"
        done
        "$0" traffic off all >/dev/null 2>&1 || true
        if [[ "${#CROWD_DEVICES[@]}" -gt 0 && "$(read_client_state all crowd off)" != off ]]; then
          "$0" traffic crowd off >/dev/null 2>&1 || true
        fi
        "$0" profile 4g all >/dev/null 2>&1 || true
        echo "All faults RESET to nominal."
        ;;
      *)
        echo "Usage: ./labctl.sh fault {status|origin-delay DELAY [JITTER]|cdn-delay DELAY|edge-delay DELAY|origin-proc-delay DELAY|cdn-purge|cdn-bypass on/off|client-cpu LOAD% [SEC]|access PROFILE|traffic PRESET|upstream RATE [opts]|crowd N RATE [opts]|reset}" >&2
        exit 2
        ;;
    esac
    ;;
  rum-build)
    need_docker
    [[ $# -le 2 ]] || { echo "Usage: ./labctl.sh rum-build [RUM_SOURCE_DIR]" >&2; exit 2; }
    build_rum_image "${2:-}"
    ;;
  rum)
    run_rum_measurement "${@:2}"
    ;;
  traffic-deploy)
    # Hot-deploy the traffic scripts into running background and crowd devices (no lab restart).
    need_docker
    load_scenario "$(active_scenario)"
    for bg in "${BACKGROUND_DEVICES[@]}" "${CROWD_DEVICES[@]}"; do
      if [[ " ${CROWD_DEVICES[*]} " == *" $bg "* ]]; then
        cid=$(client_container_id "$bg" 2>/dev/null) || {
          echo "$bg: not found or not unique (lab started without the crowd device?), skipped"
          continue
        }
      else
        cid=$(client_container_id "$bg")
      fi
      docker cp "$PROJECT_DIR/docker/traffic/background-traffic.sh" "$cid:/usr/local/bin/background-traffic.sh"
      docker cp "$PROJECT_DIR/docker/traffic/hls-background-client.py" "$cid:/usr/local/bin/hls-background-client.py"
      docker exec "$cid" chmod 0755 /usr/local/bin/background-traffic.sh /usr/local/bin/hls-background-client.py
      echo "$bg: traffic scripts deployed"
    done
    ;;
  rum-cgroup)
    # Measure an arbitrary host cgroup (e.g. the systemd scope running a host-side player).
    need_docker
    [[ $# -eq 5 ]] || { echo "Usage: ./labctl.sh rum-cgroup CGROUP_PATH DURATION INTERVAL OUTPUT_CSV" >&2; exit 2; }
    [[ -d "$2" ]] || { echo "No such cgroup: $2" >&2; exit 1; }
    out_dir=$(cd "$(dirname "$5")" && pwd)
    echo "RUM output: $out_dir/$(basename "$5")"
    exec docker run --rm --privileged --cgroupns=host \
      --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup \
      --mount type=bind,source="$out_dir",target=/output \
      --entrypoint /usr/local/bin/rum "$RUM_IMAGE" \
      --duration "$3" --interval "$4" --cgroup "$2" --output "/output/$(basename "$5")"
    ;;
  shell)
    need_docker
    load_scenario "$(active_scenario)"
    device_exists "${2:-}" || {
      echo "Unknown device '${2:-}'. Available: ${ALL_DEVICES[*]}" >&2
      exit 2
    }
    kathara connect -d "$(lab_dir)" "${2}"
    ;;
  exec)
    need_docker
    [[ $# -ge 3 ]] || { echo "Usage: ./labctl.sh exec DEVICE COMMAND..." >&2; exit 2; }
    load_scenario "$(active_scenario)"
    device=$2
    device_exists "$device" || {
      echo "Unknown device '$device'. Available: ${ALL_DEVICES[*]}" >&2
      exit 2
    }
    shift 2
    kathara exec --wait -d "$(lab_dir)" "$device" -- "$@"
    ;;
  logs)
    need_docker
    echo "===== source contribution publishers ====="
    kathara exec --wait -d "$(lab_dir)" source -- sh -c 'tail -n 8 /var/log/streaming/*.log 2>/dev/null || true'
    echo "===== origin ====="
    kathara exec --wait -d "$(lab_dir)" server -- /usr/local/bin/show-stream-logs.sh
    echo "===== CDN edge ====="
    kathara exec --wait -d "$(lab_dir)" cdn -- sh -c 'tail -n 30 /var/log/nginx/error.log /var/log/iperf3-*.log 2>/dev/null || true'
    ;;
  gpu-check)
    need_docker
    need_gpu_media
    if ! docker image inspect livestreaming/source-gpu:local >/dev/null 2>&1; then
      echo "Missing GPU source image. Run './labctl.sh build gpu' first." >&2
      exit 1
    fi
    docker run --rm --gpus device=0 \
      --entrypoint /usr/local/bin/start-publishers.sh \
      livestreaming/source-gpu:local --check
    ;;
  mode)
    echo "Scenario: $(active_scenario)"
    echo "Source mode: $(active_mode)"
    echo "Kathara lab: $(lab_dir)"
    ;;
  scenarios)
    list_scenarios
    ;;
  validate)
    need_docker
    resolve_up_context "${2:-}" "${3:-}"
    prepare_scenario_lab "$RESOLVED_SCENARIO" "$RESOLVED_MODE"
    kathara lstart --print -d "/workspace/.runtime/labs/${RESOLVED_SCENARIO}-${RESOLVED_MODE}"
    ;;
  clean-media)
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media/generated"
    read -r -p "Remove downloaded and encoded media under $root? [y/N] " answer
    if [[ "$answer" == y || "$answer" == Y ]]; then
      find "$root" -mindepth 1 ! -name .gitkeep -delete
      echo "Generated media removed; it can be recreated with './labctl.sh prepare'."
    fi
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
