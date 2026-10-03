#!/bin/sh
set -eu

container_id=${1:?missing client container ID}
duration=${2:?missing duration}
interval=${3:?missing interval}
output=${4:?missing output path}

# Docker's cgroup path depends on its cgroup driver.  cgroupfs names the leaf
# after the container ID; systemd wraps the same ID in docker-ID.scope.
cgroup_path=$(
  find /sys/fs/cgroup -type d \
    \( -name "$container_id" -o -name "docker-${container_id}.scope" \) \
    -print -quit
)

if [ -z "$cgroup_path" ]; then
  echo "Unable to find the cgroup for client container $container_id." >&2
  exit 1
fi

exec /usr/local/bin/rum \
  --duration "$duration" \
  --interval "$interval" \
  --cgroup "$cgroup_path" \
  --output "$output"
