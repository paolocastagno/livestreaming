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
  rum-build [SOURCE_DIR]       Build the pinned RUM runtime image
  rum [DURATION] [INTERVAL]    Measure every client (defaults: 60s, 500ms)
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
      download|both)
        [[ -n "${3:-}" ]] || { echo "Usage: ./labctl.sh traffic ${2} RATE [TARGET]" >&2; exit 2; }
        traffic_args=(start "${2}" "${3}")
        traffic_target=${4:-all}
        ;;
      *)
        echo "Unknown traffic mode '${2:-}'. Choose off, light, medium, heavy, upload, status, download RATE, or both RATE." >&2
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
      esac
    done
    ;;
  rum-build)
    need_docker
    [[ $# -le 2 ]] || { echo "Usage: ./labctl.sh rum-build [RUM_SOURCE_DIR]" >&2; exit 2; }
    build_rum_image "${2:-}"
    ;;
  rum)
    run_rum_measurement "${@:2}"
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
