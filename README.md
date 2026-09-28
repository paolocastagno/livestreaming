# Adaptive live-streaming experiment

This project is a reproducible testbed for observing adaptive live-video
delivery under controlled residential-network conditions. It runs complete
streaming paths—encoder, origin, CDN edge, one or more ISPs, home gateways,
browser players, and competing household traffic—entirely in Docker/Kathará.

The testbed is intended for experiments with adaptive bitrate (ABR) selection,
live latency, buffering, CDN caching, last-mile constraints, and cross traffic.
It provides the environment and controls without assuming a particular result.

See [ARCHITECTURE.md](ARCHITECTURE.md) for a detailed description of the
components, protocols, network segments, and request flow.

The default `single-isp` scenario is:

```text
live encoder       origin             CDN PoP              ISP/access       home
source ──RTMP──▶ server ──HTTP──▶ cdn edge ──▶ isp ──▶ home gateway ┬───▶ client/player
                                                                    └──▶ background traffic
  10.0.5.2         10.0.4.2          10.0.3.2       shaped last mile      10.0.1.2/.3
```

The browser requests the CDN address, never the origin. Live manifests bypass
the CDN cache; immutable fragmented-MP4 initialization and media objects are
cached. Video and background traffic share the same asymmetric residential
bottleneck.

## What the testbed measures

The main experimental controls are:

- access capacity, delay, and loss;
- background traffic rate and direction;
- HLS or MPEG-DASH delivery; and
- a portable pre-encoded source or live GPU transcoding.

The player displays the active resolution, declared media bitrate, estimated
bandwidth, buffer ahead, live latency, and dropped frames. Network queue
counters and CDN cache status are also available for diagnostics.

DRM, advertising, subscriber authentication, radio-layer behavior, multi-CDN
steering, and production telemetry are deliberately outside the scope of the
experiment.

## Quick start

Requirements:

- Docker Desktop or Docker Engine with Linux containers;
- approximately 6 GB of free disk; and
- preferably at least 6 CPUs and 8 GB RAM for smooth 4K preparation and
  playback.

Start the portable CPU-source experiment:

```bash
./labctl up cpu
```

On the first run, the command downloads a 60-second excerpt of the native-4K
Blender open movie **Glass Half** (CC BY 4.0), creates a six-rendition ladder,
builds the images, and launches the topology.

Allow approximately 15–30 seconds for the contribution streams and packagers
to become ready, then validate the complete path:

```bash
./labctl check
```

A successful validation ends with `STREAM_CHECK_OK`. It checks routing,
manifests, rendition counts, actual media retrieval, and CDN cache behavior.

Open either player:

- <http://localhost:6080/vnc.html?autoconnect=true&resize=scale> — Chromium
  running inside the emulated client.
- <http://localhost:8088/> — a host or LAN browser whose requests are proxied
  by the client and still cross the full emulated path.

Stop and remove the topology with:

```bash
./labctl down
```

## Scenarios

All scenario definitions live under `scenarios/`:

| Scenario | Topology |
|---|---|
| `single-isp` | One content provider, one CDN edge, and one residential ISP path |
| `multi-isp` | The same content provider and CDN edge shared by two independent ISP and household paths |

List or launch them with:

```bash
./labctl scenarios
./labctl validate multi-isp cpu
./labctl up single-isp cpu
./labctl up multi-isp cpu
```

`up` remains a single command: it prepares media, builds the required images,
and starts every device in the selected scenario. `./labctl up cpu` is retained
as shorthand for `./labctl up single-isp cpu`.

In `multi-isp`, both providers peer with the same off-net CDN edge on a common
peering network, while each provider has its own access link, gateway, player,
and background-traffic device:

```text
                                      ┌── isp ── home ── client/background
source ──▶ origin ──▶ shared CDN edge ┤
                                      └── isp2 ─ home2 ─ client2/background2
```

This is realistic when a CDN PoP connects to several networks through private
peering or an Internet exchange. Strictly speaking, the ISPs do not “get the
live stream”; viewers request it from the CDN and the response traverses their
ISP. Large access networks may instead host dedicated on-net CDN caches. That
alternative is deliberately not modeled here. A useful consequence of the
shared-edge design is that a request through one ISP can warm the cache for the
other ISP, which is realistic for a shared PoP and should be considered when
interpreting results.

The two multi-ISP players are exposed separately:

| Household | noVNC browser | Shaped host/LAN endpoint |
|---|---|---|
| ISP 1 | <http://localhost:6080/vnc.html?autoconnect=true&resize=scale> | <http://localhost:8088/> |
| ISP 2 | <http://localhost:6081/vnc.html?autoconnect=true&resize=scale> | <http://localhost:8089/> |

## Reference experiment

The following procedure provides a repeatable starting point for observing ABR
behavior under competing household traffic:

1. Start the CPU source and confirm that `./labctl check` succeeds.
2. Open the player, select MPEG-DASH and **Auto**, and apply the baseline:

   ```bash
   ./labctl profile 4g
   ./labctl traffic off
   ```

3. Allow playback to stabilize, then note the displayed resolution, bandwidth
   estimate, buffer, latency, and dropped frames.
4. Start a competing download:

   ```bash
   ./labctl traffic heavy
   ```

5. Observe the same values for a fixed interval chosen before the run.
6. Remove the competing traffic and observe recovery:

   ```bash
   ./labctl traffic off
   ```

For comparable repetitions, keep the source mode, protocol, access profile,
warm-up time, and observation interval unchanged. The selected representation
or buffer response is an observation, not a required outcome.

## Client resource measurement with RUM

[RUM](https://github.com/paolocastagno/rum) measures the complete resource
usage of each end-user client container: Chromium, the display/noVNC stack,
and the shaped-player reverse proxy. Build the pinned RUM runtime once, then
start a measurement for every client in the active scenario:

```bash
./labctl rum-build
./labctl rum 60s 500ms
```

The first command downloads the pinned upstream RUM revision into `.runtime/`
and builds `rum/runtime:24.04`. To build from an existing checkout instead,
run `./labctl rum-build /path/to/rum`. Set `RUM_IMAGE` when invoking `labctl`
to use an already-built image under another name.

The measurement duration and sampling interval default to 60 seconds and 500
milliseconds. One RUM monitor runs concurrently for each scenario client, so
multi-ISP households cover the same wall-clock interval. RUM attaches to the
existing client cgroups and writes directly to a host bind mount; nothing has
to be copied out of the clients afterward.

Results are stored under the Git-ignored `results/` directory. A run directory
is named with its UTC timestamp, scenario, source mode, every client's access
profile and background-traffic setting, and the RUM duration/interval, for
example:

```text
results/20260928T143000Z_multi-isp-cpu_client-4g-off_client2-congested-download-80M_rum-60s-500ms/
├── configuration.csv
├── client.csv
├── client.rum.log
├── client2.csv
└── client2.rum.log
```

`configuration.csv` repeats the run context in machine-readable form. Each
client CSV is RUM's schema-versioned aggregate CPU, memory, block-I/O, and
ingress-network output. The directory records controls applied through
`labctl`; player choices made interactively, such as HLS versus DASH or a
manual representation, should be recorded separately when they are part of
the experiment.

RUM requires Linux cgroup v2 and elevated BPF/cgroup access. Its short-lived
monitor containers therefore run privileged with the host cgroup namespace.
Only use a trusted RUM image. On Docker Desktop, the measurements describe the
client containers inside Docker's Linux VM, not macOS or Windows processes.

## Streaming pipeline

1. The `source` node publishes six keyframe-aligned H.264/AAC RTMP feeds from
   240p through 2160p. CPU mode paces prepared files; GPU mode performs live
   decode, scale, and encode.
2. The `server` node receives the contribution streams and packages live fMP4
   HLS and MPEG-DASH with four-second segments and a 32-second live window.
3. The `cdn` node acts as a pull-through edge. It refreshes live manifests from
   the origin and caches immutable media objects.
4. The client reaches the edge through an ISP/core hop and residential gateway.
   HTB controls capacity, netem adds delay and loss, and SFQ shares the
   bottleneck between concurrent flows.

Portable mode is the default because it removes the machine-dependent cost of
real-time 4K encoding while preserving the live contribution, packaging,
caching, network, and playback stages.

## Residential access profiles

Profiles are asymmetric. Delay is applied once in each access direction; the
CDN/backbone side adds another fixed 2 ms each way.

| Profile | Down | Up | Access delay per direction | Random loss |
|---|---:|---:|---:|---:|
| `fiber` | 300 Mb/s | 100 Mb/s | 3 ms | 0.001% |
| `5g` | 100 Mb/s | 20 Mb/s | 10 ms | 0.05% |
| `4g` (default) | 20 Mb/s | 5 Mb/s | 25 ms | 0.2% |
| `dsl` | 15 Mb/s | 1 Mb/s | 15 ms | 0.05% |
| `congested` | 5 Mb/s | 1 Mb/s | 50 ms | 1% |
| `3g` | 1.5 Mb/s | 0.5 Mb/s | 60 ms | 1% |
| `bad` | 0.6 Mb/s | 0.256 Mb/s | 150 ms | 3% |

```bash
./labctl profile 5g
./labctl profile congested
./labctl profile clear
```

In a multi-household scenario, controls apply to every household by default.
Pass a 1-based household number or device name to target just one path:

```bash
./labctl profile fiber isp
./labctl profile congested isp2
```

These profiles reproduce application-visible IP conditions, not radio
scheduling, a 5G core, or DOCSIS/DSL framing.

## Competing household traffic

The `background` device runs paced TCP traffic to iperf3 servers at the CDN
edge. It sits beside the player on the HOME network and shares the same
downlink and uplink queues.

```bash
./labctl traffic light          # 5 Mb/s download
./labctl traffic medium         # 20 Mb/s download
./labctl traffic heavy          # 80 Mb/s download
./labctl traffic upload         # 10 Mb/s upload
./labctl traffic download 35M   # custom target rate
./labctl traffic upload 3M
./labctl traffic both 10M       # one flow in each direction
./labctl traffic status
./labctl traffic off
```

The optional final selector also isolates cross traffic to one household:

```bash
./labctl traffic heavy isp2
./labctl traffic download 35M isp
./labctl traffic off all
```

A target above the current access capacity intentionally saturates that link.
The configured value is a target rate; `./labctl traffic status` reports the
traffic generator state.

## Live GPU transcoding

GPU mode is designed for an NVIDIA Linux workstation. It requires Docker
Engine, a working NVIDIA driver, and NVIDIA Container Toolkit.

```bash
./labctl prepare gpu
./labctl build gpu
./labctl gpu-check
./labctl up gpu
```

The source uses FFmpeg 7.1.1 and nv-codec-headers 13.0.19.0 at pinned commits.
One process decodes the native 3840×2160 VP9 programme with NVDEC, creates six
CUDA scaling branches, and publishes six H.264 NVENC/AAC outputs. All outputs
retain the native 24 fps cadence and use aligned 48-frame GOPs.

The project-local Kathará extension passes GPU, CPU-affinity, and NUMA metadata
to Docker. `./labctl mode` reports the active source mode. Run `./labctl down`
before switching between CPU and GPU modes.

FFmpeg classifies this CUDA-enabled build as `nonfree` because its scaling
kernels are compiled with NVIDIA `nvcc`. Build and use the image locally; do
not redistribute the binary image.

## Diagnostics

```bash
./labctl status
./labctl logs
./labctl shell cdn
./labctl exec client traceroute -n 10.0.3.2
./labctl exec client2 traceroute -n 10.0.3.2  # multi-isp
./labctl exec isp tc -s qdisc show dev eth1
./labctl exec isp2 tc -s qdisc show dev eth1  # multi-isp
./labctl exec home tc -s qdisc show dev eth0
./labctl exec background /usr/local/bin/background-traffic status
```

| Endpoint | Purpose | Uses residential emulation? |
|---|---|---|
| <http://localhost:8088/> | Shaped player through the client proxy | Yes |
| <http://localhost:6080/vnc.html> | Display for the in-testbed browser | Media does |
| <http://localhost:8081/> | CDN edge diagnostics | No |
| <http://localhost:8080/> | Origin diagnostics | No |

Inside the topology:

| Purpose | URL |
|---|---|
| CDN DASH | `http://10.0.3.2/dash/manifest.mpd` |
| CDN HLS | `http://10.0.3.2/hls/master.m3u8` |
| CDN health | `http://10.0.3.2/edge-healthz` |
| Origin readiness | `http://10.0.4.2/readyz` |
| Origin RTMP status | `http://10.0.4.2/status` |

## Reproducibility and limits

The scenarios, media preparation, service configuration, network profiles,
and validation are version controlled and invoked through `labctl`.
Reproducing a run requires the same repository revision, scenario, source
mode, protocol, per-ISP access profiles, traffic settings, and timing. Random
packet loss and host scheduling can still introduce run-to-run variation, so
quantitative comparisons should use repeated runs.

CPU mode republishes an offline-encoded ladder and therefore does not model
encoder delay or overload. The testbed also uses one origin, one shared CDN
edge, static routing, plain HTTP, and application-level network shaping.
Conclusions should remain within those boundaries.

## Build and maintenance

```bash
./labctl prepare cpu   # download and encode the portable ladder
./labctl build cpu     # build the portable images
./labctl prepare gpu   # download only the native 4K source
./labctl build gpu     # build the live GPU source and common images
./labctl clean-media   # remove generated media after confirmation
```

Generated media is stored under `media/generated/` and ignored by version
control. Attribution is written to `media/generated/ATTRIBUTION.txt`.

Kathará runs in a management container with `/var/run/docker.sock` mounted.
Docker-socket access is effectively administrative access to Docker, so only
use the reviewed local launcher image. Device nodes start with `--no-shared`,
which avoids host-path mounts.

For LAN access, use `http://HOST_LAN_IP:8088/` after allowing TCP 8088 through
the host firewall. This endpoint is plain HTTP with no authentication or rate
limiting. Do not expose noVNC (6080), the direct origin (8080), or the CDN
diagnostic port (8081) publicly.

## Repository layout

- `ARCHITECTURE.md` — topology, components, protocols, and request lifecycle.
- `scenarios/` — selectable single-ISP and multi-ISP topology definitions.
- `lab/` — startup files and last-mile shapers shared by the scenarios.
- `docker/source/` — paced portable contribution publishers.
- `docker/source-gpu/` — live NVDEC/CUDA/NVENC encoder.
- `docker/server/` — RTMP ingest, HLS/DASH packagers, and player.
- `docker/cdn/` — pull-through media edge and iperf3 endpoint.
- `docker/client/` — Chromium/noVNC, shaped host proxy, and validation.
- `docker/traffic/` — controllable household TCP traffic.
- `docker/media-prep/` — containerized media preparation.
- `docker/kathara/` — containerized Kathará CLI.
- `labctl` — command wrapper for the complete experiment.
