# Live-streaming testbed architecture

## 1. Purpose and scope

This experimental testbed models the complete media-delivery path between a
live encoder and a residential viewer. It supports controlled observation of
adaptive bitrate (ABR) selection, live segment delivery, CDN caching,
last-mile constraints, and competition from other household traffic.

The architecture deliberately concentrates on the video pipeline and network
behavior; it does not imply a particular experimental outcome. DRM,
advertising, subscriber authentication, multi-CDN steering, and backend
telemetry are outside its scope.

The system runs entirely in Docker. A containerized Kathará manager creates the
device containers, Layer-2 collision domains, interfaces, routes, and traffic
control queues. Kathará itself does not need to be installed on the host.

## 2. End-to-end topologies

Scenario definitions are collected under `scenarios/`. They reuse the same
container images and common startup resources, so changing the scenario alters
the network and device population without changing the media pipeline.

### 2.1 Single-ISP scenario

```text
                                      HTTP pull                         shaped residential path
  live contribution                  and cache fill
  ┌──────────────┐  six RTMP feeds  ┌──────────────┐  HLS/DASH  ┌──────────────┐
  │ source       │ ───────────────▶ │ origin       │ ◀───────── │ CDN edge     │
  │ encoder sim. │                  │ ingest +     │            │ reverse proxy│
  │ 10.0.5.2     │                  │ packagers    │            │ and cache    │
  └──────────────┘                  │ 10.0.4.2     │            │ 10.0.3.2     │
                                    └──────────────┘            └──────┬───────┘
                                                                      │
                                                               ┌──────▼───────┐
                                                               │ ISP/core     │
                                                               │ router       │
                                                               │ 10.0.3.1     │
                                                               │ 10.0.2.1     │
                                                               └──────┬───────┘
                                                        downlink HTB/netem/SFQ
                                                               ┌──────▼───────┐
                                                               │ home gateway │
                                                               │ 10.0.2.2     │
                                                               │ 10.0.1.1     │
                                                               └──────┬───────┘
                                                                      │ HOME LAN
                                                        ┌─────────────┴─────────────┐
                                                 ┌──────▼───────┐           ┌──────▼───────┐
                                                 │ client       │           │ background   │
                                                 │ browser/ABR  │           │ TCP traffic  │
                                                 │ 10.0.1.2     │           │ 10.0.1.3     │
                                                 └──────────────┘           └──────────────┘
```

The `single-isp` topology contains five emulated Ethernet domains:

| Domain | Subnet | Attached components | Purpose |
|---|---|---|---|
| `CONTRIBUTION` | `10.0.5.0/24` | source, origin | Live RTMP transport from encoder to origin |
| `ORIGIN` | `10.0.4.0/24` | origin, CDN | Private origin-facing CDN connection |
| `BACKBONE` | `10.0.3.0/24` | CDN, ISP | CDN point-of-presence to provider/core connection |
| `ACCESS` | `10.0.2.0/24` | ISP, home gateway | Residential WAN and shaped last mile |
| `HOME` | `10.0.1.0/24` | home gateway, player, background client | Subscriber's local network |

### 2.2 Multi-ISP scenario

The `multi-isp` scenario keeps the encoder, origin, and CDN edge shared, then
fans out into two provider and household paths:

```text
                                              shared PEERING LAN
                                          ┌──────────────────────┐
 source ──RTMP──▶ origin ◀──HTTP pull── CDN edge                │
                                          │                      │
                                          ├──▶ isp ──▶ home ─────┼──▶ client + background
                                          │                      │
                                          └──▶ isp2 ─▶ home2 ────┴──▶ client2 + background2
```

The diagram is logical: both provider routers and the CDN edge attach to the
same emulated peering fabric, but traffic from each home follows only its own
provider path. The domains added or changed relative to `single-isp` are:

| Domain | Subnet | Attached components | Purpose |
|---|---|---|---|
| `PEERING` | `10.0.3.0/24` | CDN, ISP 1, ISP 2 | Shared CDN PoP/private-peering or IXP fabric |
| `ACCESS` | `10.0.2.0/24` | ISP 1, home 1 | Independently shaped subscriber access path 1 |
| `HOME` | `10.0.1.0/24` | home 1, client 1, background 1 | Subscriber LAN 1 |
| `ACCESS2` | `10.1.2.0/24` | ISP 2, home 2 | Independently shaped subscriber access path 2 |
| `HOME2` | `10.1.1.0/24` | home 2, client 2, background 2 | Subscriber LAN 2 |

Static routes on the shared edge stand in for reachability normally exchanged
with BGP. The lab does not attempt to model route selection or convergence.

Sharing an off-net CDN PoP across providers is realistic: a CDN can peer with
many networks at the same facility or exchange. Subscriber requests reach the
same cache through different ISPs, so cache state and edge capacity are shared
while access queues and cross traffic remain independent. An alternative
production deployment places separate CDN appliances inside each ISP; that
on-net-cache model would require one edge per provider and is outside these two
scenarios.

## 3. Components

### 3.1 Media-preparation container

The media-preparation image is a build-time tool rather than a node in the
running topology. It downloads a 60-second native 3840×2160 excerpt of the
Blender Foundation open movie **Glass Half**, licensed under CC BY 4.0.

FFmpeg creates a keyframe-aligned H.264/AAC ladder:

| Name | Resolution | Configured video rate | H.264 level |
|---|---:|---:|---:|
| 240p | 426×240 | 400 kb/s | 4.1 |
| 360p | 640×360 | 800 kb/s | 4.1 |
| 480p | 854×480 | 1.4 Mb/s | 4.1 |
| 720p | 1280×720 | 2.8 Mb/s | 4.1 |
| 1080p | 1920×1080 | 5 Mb/s | 4.1 |
| 2160p | 3840×2160 | 12 Mb/s | 5.1 |

All renditions use 30 frames per second, AAC stereo at 48 kHz/128 kb/s, a
two-second GOP, disabled scene-cut keyframes, and forced two-second keyframe
alignment. Alignment is essential because an ABR player must be able to switch
between representations at equivalent points on the media timeline.

The prepared MP4 files are stored under `media/generated/variants/` and copied
only into the source image.

### 3.2 Portable source/encoder simulator

The `source` node represents the output side of a managed live encoder. It does
not encode video at runtime. Instead, it reads each prepared rendition at its
natural rate with FFmpeg, loops the 60-second programme indefinitely, and
publishes six concurrent RTMP streams to the origin:

```text
rtmp://10.0.5.1:1935/ingest/glass-half-240p
rtmp://10.0.5.1:1935/ingest/glass-half-360p
rtmp://10.0.5.1:1935/ingest/glass-half-480p
rtmp://10.0.5.1:1935/ingest/glass-half-720p
rtmp://10.0.5.1:1935/ingest/glass-half-1080p
rtmp://10.0.5.1:1935/ingest/glass-half-2160p
```

FFmpeg uses stream copy, so the encoded video and audio are not modified during
publication. Each publisher runs in a restart loop: if its RTMP connection is
lost, it waits briefly and reconnects independently of the other qualities.
The source waits for the origin's HTTP liveness endpoint before starting the
publishers.

This design separates the contribution phase from origin packaging while
avoiding the large and machine-dependent CPU/GPU cost of real-time 4K ladder
encoding. From the origin onward, the channel behaves as a live service.

### 3.2.1 Live GPU encoder

The optional GPU topology replaces only the source image. The origin, both
packagers, CDN, network, browser, and background-traffic components are
identical, which makes CPU-source and GPU-source experiments directly
comparable from RTMP ingest onward.

The GPU image builds FFmpeg 7.1.1 and NVIDIA codec headers 13.0.19.0 from
pinned upstream commits on CUDA 12.8. It runs one FFmpeg process with the
following data flow:

```text
native 3840x2160 VP9/Opus input
          │
          ├── NVDEC VP9 decode ── CUDA frame split
          │                         ├── scale_cuda 426x240   ── NVENC H.264
          │                         ├── scale_cuda 640x360   ── NVENC H.264
          │                         ├── scale_cuda 854x480   ── NVENC H.264
          │                         ├── scale_cuda 1280x720  ── NVENC H.264
          │                         ├── scale_cuda 1920x1080 ── NVENC H.264
          │                         └── scale_cuda 3840x2160 ── NVENC H.264
          │
          └── CPU Opus decode ── six AAC encoders
                                      │
                                      └── six RTMP contribution outputs
```

The video frames stay in GPU memory between decode, split, scaling, and
encoding. All branches retain the source's native 24 fps cadence and use a
48-frame GOP, so every rendition has a keyframe every two seconds. Rate,
maximum-rate, and VBV-buffer settings match the portable ladder. If any RTMP
output fails, the single encoder process is restarted so the complete ladder
returns with a common timeline.

Before live startup, the source verifies GPU visibility and the presence of
`h264_nvenc` and `scale_cuda`. `./labctl gpu-check` additionally opens a real
NVENC session for a one-frame test, catching driver/runtime mismatches before
the selected scenario is launched.

FFmpeg classifies a build containing CUDA kernels produced by NVIDIA `nvcc` as
nonfree. The GPU image is therefore a local experimental artifact and must not
be redistributed as a binary image.

Kathará 3.8.3 does not expose Docker GPU requests or hard CPU affinity. The
management image therefore carries a small fail-fast patch which passes three
otherwise ordinary lab metadata fields to the Docker SDK:

- `gpus` becomes a Docker GPU `DeviceRequest`;
- `cpuset_cpus` defines the exact logical CPUs available to a device;
- `cpuset_mems` binds memory allocation to the selected NUMA node.

The patch is local to this project's pinned management image. It neither
installs Kathará on the host nor changes Docker's global NVIDIA runtime.

### 3.3 Streaming origin

The `server` node is the live origin. It has two emulated interfaces:

- `10.0.5.1` receives contribution traffic.
- `10.0.4.2` serves the private CDN-facing origin interface.

It contains three principal services managed by Supervisor:

1. **nginx-rtmp ingest** listens on TCP 1935 and accepts the six live
   contribution streams. Recording is disabled because the purpose is live
   delivery rather than archive creation.
2. **HLS packager** reads all six RTMP streams and generates a live HLS master,
   six video renditions, and one shared audio rendition.
3. **DASH packager** reads the same contribution streams and generates a
   dynamic MPEG-DASH presentation with six video Representations and one audio
   Representation.

Supervisor automatically restarts nginx or a failed packager. Packagers can be
started before the contribution streams are ready; they wait for input, and
Supervisor retries them after unexpected exits.

#### HLS output

The HLS packager produces:

```text
/hls/master.m3u8
/hls/240p/index.m3u8
/hls/360p/index.m3u8
...
/hls/2160p/index.m3u8
/hls/audio/index.m3u8
```

Properties of the output include:

- fragmented MP4 initialization and media objects;
- four-second target segment duration;
- eight segments in the visible live playlist, approximately 32 seconds;
- independent-segment signalling;
- programme date-time tags;
- temporary-file-and-rename publication, preventing clients from reading
  partially written objects;
- deletion of objects that leave the origin's live window;
- one audio group shared by all six video variants.

#### MPEG-DASH output

The DASH packager produces `/dash/manifest.mpd` plus initialization and media
objects. It uses four-second segments, `SegmentTemplate`, a segment timeline,
an eight-segment live window, and four extra retained segments. Video and audio
are placed in separate Adaptation Sets.

Both protocols use ISO Base Media File Format fragments. The HLS and DASH
outputs are produced by separate packager processes and therefore do not share
the exact same segment files; this is CMAF-style fragmented delivery rather
than a single unified CMAF object set serving both manifests.

#### Origin HTTP service

nginx serves the HLS and DASH outputs, the player application, RTMP status XML,
and two operational endpoints:

- `/healthz` proves that nginx is alive.
- `/readyz` succeeds only once the HLS master manifest exists.

Live content carries no-cache headers at the origin. The CDN applies the final
cache policy according to object type.

### 3.4 CDN edge

The `cdn` node represents a CDN point of presence close to the viewer. It has a
private origin-side address (`10.0.4.1`) and a subscriber-facing backbone
address (`10.0.3.2`). The viewer requests only the CDN address; it has no route
or URL that directly targets the origin during normal playback.

The CDN is a pull-through nginx reverse proxy:

- HLS and DASH manifests bypass cache. Every request is forwarded to the
  origin, ensuring that the player sees the current live window.
- `.m4s` and `.mp4` initialization/media objects are cached for 15 minutes.
- Cache locking coalesces concurrent misses so multiple viewers do not all
  request the same new segment from the origin.
- Byte-range requests are supported.
- Player HTML, JavaScript, CSS, and the local Shaka Player library use a
  separate one-hour static cache.
- `X-Cache-Status` exposes `MISS`, `HIT`, or `BYPASS`, and `X-Edge` identifies
  the emulated edge.

Retaining media objects at the edge longer than at the origin is realistic: a
segment that has left the origin live window can remain available to clients
that already received its URL. Because manifests bypass cache, new viewers are
not directed to stale segments.

The CDN also runs two iperf3 servers. Port 5201 supplies reverse-mode download
traffic and port 5202 receives upload traffic. Separate ports allow simultaneous
download and upload experiments.

### 3.5 ISP/core routers

Each ISP node forwards packets between the CDN-facing backbone or peering
network and its own residential access network. It is the downstream end of
that emulated last mile. `single-isp` has `isp`; `multi-isp` has the independent
`isp` and `isp2` paths.

Download shaping is attached to each ISP's egress interface toward its home.
This placement is important: packets from video delivery and background
downloads for one household enter the same queue before reaching that
subscriber, without consuming the other ISP's access capacity.

The CDN-to-ISP backbone adds a fixed 2 ms delay in each direction. This models
a nearby CDN point of presence and provider transport separately from access
delay.

### 3.6 Residential gateway

Each home node connects a residential WAN to its home LAN and acts as that
viewer's default gateway. The first path uses `home` at `10.0.2.2` and
`10.0.1.1`; the second path uses `home2` at `10.1.2.2` and `10.1.1.1`.

Upload shaping is attached to its WAN egress. The downlink is shaped at the ISP
and the uplink at the home gateway, allowing realistic asymmetric capacity.
Both the video client and background client share these queues.

Each shaped direction uses a hierarchy of Linux traffic-control mechanisms:

1. **HTB** enforces the total link capacity.
2. **netem** adds one-way propagation delay and random packet loss.
3. **SFQ** distributes service among active flows so a single bulk transfer
   does not use an unrealistically simple FIFO queue.

The predefined access profiles are:

| Profile | Down | Up | Access delay each way | Loss |
|---|---:|---:|---:|---:|
| fiber | 300 Mb/s | 100 Mb/s | 3 ms | 0.001% |
| 5G | 100 Mb/s | 20 Mb/s | 10 ms | 0.05% |
| 4G | 20 Mb/s | 5 Mb/s | 25 ms | 0.2% |
| DSL | 15 Mb/s | 1 Mb/s | 15 ms | 0.05% |
| congested | 5 Mb/s | 1 Mb/s | 50 ms | 1% |
| 3G | 1.5 Mb/s | 0.5 Mb/s | 60 ms | 1% |
| bad | 0.6 Mb/s | 0.256 Mb/s | 150 ms | 3% |

These are IP-path profiles. A 5G profile models the capacity, delay, and loss
seen by an application; it does not emulate 5G radio scheduling, spectrum,
mobility, RAN protocols, or a mobile core.

### 3.7 Clients and player

The `client` node is the first end user's device at `10.0.1.2`. In the
multi-ISP scenario, `client2` provides an identical player at `10.1.1.2`. Each
runs:

- Chromium;
- Xvfb, Fluxbox, x11vnc, and noVNC for a browser visible from the host;
- Shaka Player 5.2.9, served through the CDN;
- a small nginx reverse proxy used by host and LAN browsers;
- the end-to-end validation script.

Shaka Player supports both manifests through relative URLs:

```text
dash/manifest.mpd
hls/master.m3u8
```

Because the URLs are relative, loading the application through the CDN keeps
all media requests on the CDN path. The player can run in automatic ABR mode or
lock a specific quality. Its local UI displays the selected resolution,
declared media bitrate, estimated bandwidth, buffer ahead, live latency, and
dropped frames. These are browser-local diagnostics, not a telemetry backend.

In automatic mode, Shaka estimates sustainable throughput from media requests
and selects a representation that should fit the measured path. Changing an
access profile or introducing competing traffic alters segment completion time,
which causes ABR down-switches, buffer changes, or recovery to higher qualities.

### 3.8 Background household clients

The `background` node at `10.0.1.3` is a second device in the first home. The
multi-ISP scenario adds `background2` at `10.1.1.3`. Each generates long-lived
paced TCP flows to the shared CDN's iperf3 services.

It can generate:

- download-only traffic;
- upload-only traffic;
- simultaneous traffic in both directions;
- preset or user-specified target rates.

Since each generator is placed behind the same home gateway as its paired
player, the traffic crosses exactly the same ISP and access queues as that
player's media. It models another household member downloading a game,
synchronizing cloud data, or performing another sustained transfer.

## 4. Playback request flow

A typical DASH playback follows these steps:

1. Chromium requests `/` from `10.0.3.2`, the CDN edge.
2. The CDN retrieves and caches the player application from the origin.
3. Shaka requests `/dash/manifest.mpd` from the CDN.
4. The CDN bypasses its cache for the manifest and obtains the latest dynamic
   MPD from the origin.
5. Shaka selects an initial Representation from its bandwidth estimate.
6. It requests that Representation's initialization object and media segments.
7. On the first request for each object, the CDN fetches it from the origin and
   stores it. Later requests for the same URL are edge cache hits.
8. Responses traverse CDN → selected ISP → its shaped downlink → home gateway
   → client.
9. Shaka continuously updates its throughput estimate and may select another
   aligned Representation for a future segment.

HLS follows the same sequence using the master playlist, a media playlist, the
shared audio playlist, and fMP4 media objects.

## 5. Startup and steady-state lifecycle

`./labctl up SCENARIO SOURCE_MODE` performs the following sequence:

1. Prepare or reuse the six media renditions.
2. Build the Kathará manager and all device images.
3. Assemble the selected scenario with the common startup resources, then ask
   the containerized Kathará CLI to create all of its domains and devices.
4. Configure addresses, routes, IP forwarding, policy routing, and the default
   4G queues through the device startup files.
5. Start the origin's supervised nginx and packagers.
6. Start the six source publishers after origin liveness is available.
7. Start the CDN proxy/cache and both traffic servers.
8. Start every client proxy, desktop service, and Chromium instance.

The origin clears previous live output during startup. There is no persistent
DVR or archive. Once contribution data is flowing, the packagers need several
segments before both live manifests are ready.

## 6. Host access and policy routing

The origin, CDN, and every client also have Docker bridge interfaces for
controlled host access:

| Host port | Device/service | Path behavior |
|---:|---|---|
| 6080 | client noVNC | Carries only the remote display; browser media originates inside the lab |
| 8088 | client reverse proxy | Host/LAN media requests are reopened by the client and cross the full emulated path |
| 6081 | client2 noVNC (`multi-isp`) | Second remote display; browser media originates inside the lab |
| 8089 | client2 reverse proxy (`multi-isp`) | Second host/LAN path through ISP 2 |
| 8081 | CDN HTTP | Direct edge debugging; bypasses residential emulation |
| 8080 | origin HTTP | Direct origin debugging; bypasses both CDN and residential emulation |

Policy-routing rules keep replies for Docker-published ports on the Docker
bridge. Normal in-lab traffic continues to use the emulated interfaces and
static/default routes.

Port 8088 is the correct host-facing endpoint for network experiments. The
proxy connection from the host terminates at the client; nginx then opens a new
upstream connection from the client's HOME-side network stack to `10.0.3.2`.
Consequently, manifests and every media object still traverse home, ISP, and
CDN nodes.

## 7. Validation and diagnostics

`./labctl check` runs from every emulated client in the selected scenario and
verifies:

- the route and three-hop path to the CDN;
- CDN and origin health;
- six HLS video variants, including 3840×2160;
- six DASH video Representations plus shared audio, including 3840×2160;
- actual H.264 media retrieval and probing through both HLS and DASH;
- a CDN segment request followed by a cache `HIT`;
- the final `STREAM_CHECK_OK` marker consumed by the host wrapper.

Additional diagnostics expose Supervisor/FFmpeg/nginx logs, RTMP status XML,
traffic-generator logs, and `tc -s` byte, packet, queue, and drop counters.

## 8. Realism and intentional boundaries

The lab includes the parts that materially affect video delivery experiments:

- a separate encoder/source role;
- live contribution transport;
- a multi-representation aligned ABR ladder;
- continuously updated live HLS and DASH packaging;
- shared audio and native 4K;
- an origin distinct from a caching CDN edge;
- a multi-hop provider and residential topology;
- asymmetric capacity, delay, loss, queueing, and cross traffic;
- a production-grade browser ABR player.

The following are intentional simplifications:

- The ladder is encoded offline and republished in real time. Runtime encoding
  delay, encoder overload, GPU behavior, and content-aware bitrate allocation
  are not modeled.
- RTMP is used for contribution instead of redundant SRT/RIST links.
- There is one origin and one shared CDN edge, with no failover, per-ISP on-net
  edge, or multi-CDN steering.
- Static routing substitutes for Internet routing and BGP policy.
- Delivery uses plain HTTP rather than TLS, HTTP/2, or HTTP/3.
- The HLS and DASH packagers do not share one common set of CMAF media objects.
- There is no DRM, ad insertion, authentication, DVR, or persistent recording.
- Access profiles model application-visible IP behavior, not physical or radio
  protocol internals.

These boundaries keep the experiment reproducible on a normal workstation
while preserving the pipeline stages and network effects that drive ABR live
streaming behavior.
