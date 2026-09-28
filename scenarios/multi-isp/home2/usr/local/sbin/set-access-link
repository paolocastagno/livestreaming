#!/usr/bin/env bash
set -euo pipefail

interface=${1:-}
rate=${2:-}
delay=${3:-}
loss=${4:-}

[[ "$interface" =~ ^eth[0-9]+$ ]] || { echo "Invalid interface: $interface" >&2; exit 2; }

if [[ "$rate" == clear ]]; then
  tc qdisc del dev "$interface" root 2>/dev/null || true
  echo "Cleared shaping on $interface."
  exit 0
fi

[[ "$rate" =~ ^[0-9]+(kbit|mbit|gbit)$ ]] || { echo "Invalid rate: $rate" >&2; exit 2; }
[[ "$delay" =~ ^[0-9]+ms$ ]] || { echo "Invalid one-way delay: $delay" >&2; exit 2; }
[[ "$loss" =~ ^([0-9]+([.][0-9]+)?)%$ ]] || { echo "Invalid loss: $loss" >&2; exit 2; }

tc qdisc del dev "$interface" root 2>/dev/null || true
tc qdisc add dev "$interface" root handle 1: htb default 10
tc class replace dev "$interface" parent 1: classid 1:10 htb \
  rate "$rate" ceil "$rate" burst 64k cburst 64k quantum 1514
tc qdisc replace dev "$interface" parent 1:10 handle 10: netem \
  delay "$delay" loss "$loss" limit 2000
tc qdisc replace dev "$interface" parent 10:1 handle 20: sfq quantum 1514 perturb 10

echo "Applied on $interface: rate=$rate one-way-delay=$delay loss=$loss"
tc -s qdisc show dev "$interface"
