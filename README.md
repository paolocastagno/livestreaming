# Kathará live-streaming lab

This project runs a realistic adaptive live-video delivery chain and a
controllable residential network entirely in Docker/Kathará.

See [ARCHITECTURE.md](ARCHITECTURE.md) for a detailed description of every
component, protocol, network segment, and end-to-end request flow.

```text
live encoder       origin             CDN PoP              ISP/access       home
source ──RTMP──▶ server ──HTTP──▶ cdn edge ──▶ isp ──▶ home gateway ──┬─▶ client/player
                                                                    └─▶ background traffic
  10.0.5.2         10.0.4.2          10.0.3.2       shaped last mile      10.0.1.2/.3
```

The browser requests the CDN address, never the origin. Live manifests bypass
the CDN cache; immutable CMAF initialization and media objects are cached.
Video and background traffic share the same asymmetric residential bottleneck.

## Streaming pipeline

1. The `source` node acts as a managed live encoder. In portable CPU mode it
   paces six prepared renditions; in GPU mode it decodes one native 4K source,
   performs six CUDA scales, and runs six simultaneous NVENC encoders. Both
   modes publish keyframe-aligned H.264/AAC over RTMP from 240p through 2160p.
2. The `server` node is the origin. nginx-rtmp receives those contribution
   streams and supervised FFmpeg packagers produce live fMP4 HLS and MPEG-DASH
   with four-second segments and a 32-second live window. Video renditions use
   one shared audio representation.
3. The `cdn` node is a pull-through edge. It refreshes live manifests from the
   origin and caches CMAF media objects with cache locking, range requests, and
   visible `X-Cache-Status` headers.
4. The client reaches the edge through an ISP/core hop and a residential
   gateway. HTB sets shared down/up capacity, netem adds delay/loss, and SFQ
   makes concurrent household flows share the bottleneck fairly.

Portable mode encodes rendition files ahead of time so experiments can run on
a laptop without an NVIDIA GPU. The optional GPU mode performs the complete
decode, scale, encode, contribution, packaging, caching, and playback pipeline
live on suitable Linux workstations.

DRM, advertising, subscriber authentication, and production telemetry are
intentionally excluded. They do not improve the transport and ABR experiments
this lab is designed for.

## Quick start

Prerequisites are Docker Desktop or Docker Engine, about 6 GB of free disk, and
preferably at least 6 CPUs/8 GB RAM for smooth 4K preparation and playback.

```bash
./labctl up
```

The first run downloads a 60-second excerpt of the native-4K Blender open movie
**Glass Half** (CC BY 4.0), creates the six-rendition ladder, builds the images,
and launches the topology. Then open either:

- <http://localhost:6080/vnc.html?autoconnect=true&resize=scale> — Chromium
  running inside the emulated client.
- <http://localhost:8088/> — a host/LAN browser whose requests are reverse
  proxied from the client and still cross the full emulated path.

Allow roughly 15–30 seconds for all contribution streams and packagers to
become ready, then verify routing, manifests, rendition counts, and CDN cache
behavior:

```bash
./labctl check
```

Stop and remove all devices and collision domains with:

```bash
./labctl down
```

## Live GPU transcoding

The GPU source is designed for a workstation equipped with: an Intel i9-13900,
RTX 4000 SFF Ada with 20 GB VRAM, 32 logical CPUs, and one NUMA node. It needs
Docker Engine, a working NVIDIA driver, and NVIDIA Container Toolkit; Kathará
itself remains inside its management container.

```bash
./labctl prepare gpu     # download the native 4K source; no CPU ladder encode
./labctl build gpu       # build pinned CUDA 12.8 + FFmpeg/NVENC image
./labctl gpu-check       # verify GPU injection and perform a one-frame encode
./labctl up gpu          # generate the GPU lab and start it
```

GPU mode uses FFmpeg 7.1.1 and nv-codec-headers 13.0.19.0 at pinned commits.
One FFmpeg process decodes the native 3840×2160 VP9 programme with NVDEC,
splits it into six CUDA scaling branches, and opens six H.264 NVENC outputs.
All outputs retain the native 24 fps cadence and use aligned 48-frame
(two-second) GOPs. Audio is decoded from Opus and encoded to 48 kHz AAC for
RTMP compatibility.

Because FFmpeg's CUDA scaling kernels are compiled with NVIDIA `nvcc`, FFmpeg
marks this build `nonfree`. Build and use the image locally for experiments;
do not publish or redistribute the resulting binary image. The Dockerfile,
patches, scripts, and build instructions may still be kept in the repository.

The project-local Kathará manager extension translates `gpus`, `cpuset_cpus`,
and `cpuset_mems` metadata into Docker resource requests. It does not change
Docker's global default runtime. The resource allocation is:

| Role | Logical CPUs | CPU quota | Memory | GPU |
|---|---:|---:|---:|---:|
| Host reserve | `0-3`, `30-31` | — | — | — |
| ISP | `4-5` | 1 | 512 MiB | — |
| Home gateway | `6-7` | 1 | 512 MiB | — |
| CDN edge | `8-11` | 1 | 2 GiB | — |
| Origin/packagers | `12-15` | 2 | 4 GiB | — |
| GPU source | `16-23` | 8 | 8 GiB | GPU 0 |
| Browser/player | `24-27` | 2 | 4 GiB | — |
| Background traffic | `28-29` | 0.5 | 512 MiB | — |

`./labctl mode` reports which generated topology subsequent control commands
will use. Run `./labctl down` before switching between CPU and GPU labs.

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

These reproduce end-to-end IP conditions, not radio scheduling, a 5G core, or
DOCSIS/DSL framing. Their purpose is realistic capacity, latency, queueing, and
loss at the point where adaptive streaming reacts.

## Competing household traffic

The `background` device runs paced TCP traffic to an iperf3 server at the CDN
edge. Because it sits beside the player on the HOME LAN, it competes for the
same downlink or uplink queue.

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

A target above the current access capacity intentionally saturates that link.
With Quality set to **Auto**, compare the selected rendition, buffer, latency,
and dropped frames before and after adding traffic.

## Debugging and observability

```bash
./labctl status
./labctl logs
./labctl shell cdn
./labctl exec client traceroute -n 10.0.3.2
./labctl exec isp tc -s qdisc show dev eth1
./labctl exec home tc -s qdisc show dev eth0
./labctl exec background /usr/local/bin/background-traffic status
```

Host endpoints:

| Endpoint | Purpose | Uses residential emulation? |
|---|---|---|
| <http://localhost:8088/> | Shaped player via the client proxy | Yes |
| <http://localhost:6080/vnc.html> | Display for the in-lab browser | Media does |
| <http://localhost:8081/> | CDN edge debugging | No |
| <http://localhost:8080/> | Origin debugging | No |

Inside the lab, the primary endpoints are:

| Purpose | URL |
|---|---|
| CDN DASH | `http://10.0.3.2/dash/manifest.mpd` |
| CDN HLS | `http://10.0.3.2/hls/master.m3u8` |
| CDN health | `http://10.0.3.2/edge-healthz` |
| Origin readiness | `http://10.0.4.2/readyz` |
| Origin RTMP status | `http://10.0.4.2/status` |

## Access from another computer or the Internet

On the same LAN, use `http://HOST_LAN_IP:8088/` after allowing TCP 8088 through
the host firewall. Internet access additionally requires a port forward or a
secure tunnel/reverse proxy. This endpoint is plain HTTP with no authentication
or rate limiting. Do not expose noVNC (`6080`), the direct origin (`8080`), or
the CDN debug port (`8081`) publicly.

## Build and maintenance

```bash
./labctl prepare cpu   # download/encode the portable six-rendition ladder
./labctl build cpu     # build the portable lab images
./labctl prepare gpu   # download only the native 4K input
./labctl build gpu     # build the live NVENC source and common lab images
./labctl clean-media   # remove generated media after confirmation
```

Generated media lives under `media/generated/` and is ignored by version
control. Attribution is written to `media/generated/ATTRIBUTION.txt`.

Kathará itself runs in a management container and controls sibling device
containers through `/var/run/docker.sock`. Docker-socket access is effectively
administrator access to Docker, so only use the reviewed local launcher image.
The lab starts with `--no-shared`, avoiding host-path mounts in device nodes.

## Repository layout

- `lab/` — the seven-node topology, routes, and last-mile shapers.
- `docker/source/` — paced live contribution publishers.
- `docker/source-gpu/` — pinned CUDA/FFmpeg live NVDEC/CUDA/NVENC encoder.
- `docker/server/` — RTMP ingest, supervised HLS/DASH origin packagers, player.
- `docker/cdn/` — pull-through media edge and iperf3 traffic endpoint.
- `docker/client/` — Chromium/noVNC, shaped host proxy, end-to-end checks.
- `docker/traffic/` — controllable competing household TCP traffic.
- `docker/media-prep/` — containerized download and rendition preparation.
- `docker/kathara/` — pinned containerized Kathará CLI.
- `labctl` — the command wrapper for the complete experiment.
