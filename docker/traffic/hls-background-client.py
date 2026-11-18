#!/usr/bin/env python3
"""Competing headless ABR players for household cross traffic (stdlib only).

Each worker behaves like a live ABR player without decoding: it fetches video segments
from the CDN at the representation chosen by a simple ABR rule, keeps a virtual playout
buffer that drains in real time, pauses when the buffer is full (ON-OFF pattern) and
waits for new segments at the live edge.

Unlike a greedy iperf flow, N such players generate the bursty, self-limited competition
typical of other video streams in the same household.  By default they use the DASH
packaging, whose segment files are distinct from the HLS ones, so they do not warm the
CDN cache for an HLS player under test.

Players at the live edge request each new segment as soon as it is published, so all of
them (and the player under test) download at the same instants of the segment cycle.
--phase-spread S gives every worker a fixed extra wait, uniform in [0, S] s, before
fetching a segment it had to wait for: viewers with different live latencies, same
periodicity but de-phased bursts.  The default 0 keeps them synchronised.

Usage:
  hls-background-client.py --n 3 [--abr throughput|buffer|hybrid] [--protocol dash|hls]
                           [--bypass] [--phase-spread S] [--ramp-sec R] [--server http://10.0.3.2]
                           [--log FILE]

One JSON line per downloaded segment is appended to --log:
  {"t": unix_s, "w": worker, "rep": id, "bps": declared, "bytes": n, "dl": s, "ttfb": s, "buf": s}
"""

from __future__ import annotations

import argparse
import http.client
import json
import random
import re
import signal
import sys
import threading
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from urllib.parse import urljoin, urlparse

STOP = threading.Event()
LOG_LOCK = threading.Lock()
NS = {"m": "urn:mpeg:dash:schema:mpd:2011"}


@dataclass
class Rep:
    rep_id: str
    bandwidth: int
    init_url: str | None
    media_tmpl: str  # DASH: template with $Number$; HLS: media playlist URL


class Http:
    """One persistent HTTP/1.1 connection per worker (a real player reuses its connection)."""

    def __init__(self, server: str, headers: dict[str, str]) -> None:
        u = urlparse(server)
        self.host, self.port = u.hostname or "10.0.3.2", u.port or 80
        self.headers = {"Connection": "keep-alive", "User-Agent": "mosnn-bg-player/1.0", **headers}
        self.conn: http.client.HTTPConnection | None = None

    def get(self, url: str) -> tuple[bytes, float, float]:
        """Returns (body, ttfb_s, total_s)."""
        path = urlparse(url).path
        for attempt in range(2):
            try:
                if self.conn is None:
                    self.conn = http.client.HTTPConnection(self.host, self.port, timeout=30)
                t0 = time.monotonic()
                self.conn.request("GET", path, headers=self.headers)
                resp = self.conn.getresponse()
                t1 = time.monotonic()
                body = resp.read()
                t2 = time.monotonic()
                if resp.status >= 400:
                    raise OSError(f"HTTP {resp.status} for {path}")
                return body, t1 - t0, t2 - t0
            except (OSError, http.client.HTTPException):
                if self.conn is not None:
                    self.conn.close()
                self.conn = None
                if attempt == 1:
                    raise
        raise AssertionError("unreachable")


# ------------------------------------------------------------------ manifests


class DashSource:
    def __init__(self, http: Http, server: str) -> None:
        self.http, self.url = http, urljoin(server, "/dash/manifest.mpd")
        self.reps: list[Rep] = []
        self.first = self.last = 0
        self.seg_dur = 4.0
        self.refresh()

    def refresh(self) -> None:
        body, _, _ = self.http.get(self.url)
        root = ET.fromstring(body)
        base = self.url.rsplit("/", 1)[0] + "/"
        reps: list[Rep] = []
        for aset in root.iterfind(".//m:AdaptationSet", NS):
            if aset.get("contentType", "") != "video" and "video" not in aset.get("mimeType", ""):
                continue
            for r in aset.iterfind("m:Representation", NS):
                tmpl = r.find("m:SegmentTemplate", NS)
                if tmpl is None:
                    tmpl = aset.find("m:SegmentTemplate", NS)
                if tmpl is None:
                    continue
                rid = r.get("id", "0")
                start = int(tmpl.get("startNumber", "1"))
                timescale = int(tmpl.get("timescale", "1"))
                count, dur = 0, 0
                tl = tmpl.find("m:SegmentTimeline", NS)
                if tl is not None:
                    for s in tl.iterfind("m:S", NS):
                        rep_n = int(s.get("r", "0")) + 1
                        count += rep_n
                        dur = int(s.get("d", "0"))
                self.first, self.last = start, start + count - 1
                self.seg_dur = dur / timescale if dur else self.seg_dur
                init = tmpl.get("initialization", "").replace("$RepresentationID$", rid)
                media = tmpl.get("media", "").replace("$RepresentationID$", rid)
                reps.append(Rep(rid, int(r.get("bandwidth", "0")), urljoin(base, init), urljoin(base, media)))
        if not reps:
            raise RuntimeError("no video representations in MPD")
        self.reps = sorted(reps, key=lambda x: x.bandwidth)

    def refresh_edge(self, rep: Rep) -> None:
        """Live-edge refresh: the MPD lists every representation (one request)."""
        self.refresh()

    def segment_url(self, rep: Rep, number: int) -> str:
        return re.sub(r"\$Number(%0(\d+)d)?\$", lambda m: str(number).zfill(int(m.group(2) or 0)), rep.media_tmpl)

    def available(self, rep: Rep) -> tuple[int, int]:
        return self.first, self.last


class HlsSource:
    def __init__(self, http: Http, server: str) -> None:
        self.http, self.url = http, urljoin(server, "/hls/master.m3u8")
        body, _, _ = self.http.get(self.url)
        base = self.url.rsplit("/", 1)[0] + "/"
        reps, bw = [], 0
        for line in body.decode().splitlines():
            if line.startswith("#EXT-X-STREAM-INF:"):
                m = re.search(r"BANDWIDTH=(\d+)", line)
                bw = int(m.group(1)) if m else 0
            elif line and not line.startswith("#") and bw:
                reps.append(Rep(line.split("/")[0], bw, None, urljoin(base, line)))
                bw = 0
        self.reps = sorted(reps, key=lambda x: x.bandwidth)
        self.lists: dict[str, tuple[int, list[str], float, str | None]] = {}
        self.seg_dur = 4.0
        for r in self.reps:
            self.refresh_rep(r)

    def refresh_rep(self, rep: Rep) -> None:
        body, _, _ = self.http.get(rep.media_tmpl)
        base = rep.media_tmpl.rsplit("/", 1)[0] + "/"
        seq, uris, dur, init = 0, [], 4.0, None
        for line in body.decode().splitlines():
            if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
                seq = int(line.split(":")[1])
            elif line.startswith("#EXT-X-TARGETDURATION:"):
                dur = float(line.split(":")[1])
            elif line.startswith("#EXT-X-MAP:"):
                m = re.search(r'URI="([^"]+)"', line)
                init = urljoin(base, m.group(1)) if m else None
            elif line and not line.startswith("#"):
                uris.append(urljoin(base, line))
        self.lists[rep.rep_id] = (seq, uris, dur, init)
        self.seg_dur = dur
        rep.init_url = init

    def refresh(self) -> None:
        for r in self.reps:
            self.refresh_rep(r)

    def refresh_edge(self, rep: Rep) -> None:
        """Live-edge refresh: only the reference playlist, like a player reloading its current variant
        (the chosen variant is reloaded before a fetch when stale). Reloading all variants every second
        would add ~6 uncached playlist requests per player and second at the CDN and origin."""
        self.refresh_rep(rep)

    def available(self, rep: Rep) -> tuple[int, int]:
        seq, uris, _, _ = self.lists[rep.rep_id]
        return seq, seq + len(uris) - 1

    def segment_url(self, rep: Rep, number: int) -> str:
        seq, uris, _, _ = self.lists[rep.rep_id]
        if not seq <= number < seq + len(uris):
            # outside the live window (a negative index would silently pick another segment): the
            # worker refreshes and restarts from the window, like a live skip
            raise LookupError(f"segment {number} outside the playlist window {seq}..{seq + len(uris) - 1}")
        return uris[number - seq]


# ------------------------------------------------------------------ player


def choose(reps: list[Rep], thr_bps: float, buf: float, mode: str, safety: float) -> Rep:
    if thr_bps <= 0:
        return reps[0]
    by_thr = reps[0]
    for r in reps:
        if r.bandwidth <= safety * thr_bps:
            by_thr = r
    if mode == "throughput":
        return by_thr
    # buffer-based (BBA-like): reservoir 2 s, cushion up to 8 s
    frac = min(1.0, max(0.0, (buf - 2.0) / 6.0))
    by_buf = reps[int(round(frac * (len(reps) - 1)))]
    if mode == "buffer":
        return by_buf
    return by_thr if buf >= 2.0 else reps[0]  # hybrid


def worker(idx: int, args: argparse.Namespace, log) -> None:
    rnd = random.Random(args.seed * 1000 + idx)
    # start offset (interruptible: a stop must not wait for it)
    if args.ramp_sec > 0:  # all workers start within ramp_sec (large crowds at full strength quickly)
        STOP.wait(rnd.uniform(0.0, args.ramp_sec))
    else:
        STOP.wait(rnd.uniform(0.0, args.stagger) * idx)
    if STOP.is_set():
        return
    headers = {"X-Force-Bypass-Cache": "1"} if args.bypass else {}
    http = Http(args.server, headers)
    try:
        src = DashSource(http, args.server) if args.protocol == "dash" else HlsSource(http, args.server)
    except Exception as exc:  # noqa: BLE001
        print(f"[bg{idx}] manifest error: {exc}", file=sys.stderr)
        return
    safety = rnd.uniform(0.75, 0.95)
    phase = rnd.uniform(0.0, args.phase_spread) if args.phase_spread > 0 else 0.0
    ref = src.reps[0]
    _first, last = src.available(ref)
    nxt = max(_first, last - 2)  # start 3 segments behind the live edge
    thr, buf, playing = 0.0, 0.0, False
    tick = time.monotonic()
    inited: set[str] = set()
    last_refresh = time.monotonic()

    def drain() -> None:
        nonlocal buf, tick
        now = time.monotonic()
        if playing:
            buf = max(0.0, buf - (now - tick))
        tick = now

    while not STOP.is_set():
        try:
            # wait for the live edge
            waited = False
            while not STOP.is_set():
                first, last = src.available(ref)
                if nxt < first:
                    nxt = first
                if nxt <= last:
                    break
                waited = True
                STOP.wait(0.5)
                if time.monotonic() - last_refresh > 1.0:
                    src.refresh_edge(ref)
                    last_refresh = time.monotonic()
                drain()
            if STOP.is_set():
                break
            if waited and phase > 0:  # de-phased viewer: fixed offset from the segment publication
                STOP.wait(phase)
                if STOP.is_set():
                    break
            drain()
            rep = choose(src.reps, thr, buf, args.abr, safety)
            if isinstance(src, HlsSource):
                f, l = src.available(rep)
                if not (f <= nxt <= l):
                    src.refresh_rep(rep)
            if rep.init_url and rep.rep_id not in inited:
                http.get(rep.init_url)
                inited.add(rep.rep_id)
            body, ttfb, total = http.get(src.segment_url(rep, nxt))
            xfer = max(total - ttfb, 1e-3)
            sample = 8.0 * len(body) / max(total, 1e-3)
            thr = sample if thr <= 0 else 0.3 * sample + 0.7 * thr
            drain()
            buf += src.seg_dur
            playing = True
            with LOG_LOCK:
                log.write(json.dumps({"t": round(time.time(), 3), "w": idx, "rep": rep.rep_id,
                                      "bps": rep.bandwidth, "bytes": len(body), "dl": round(total, 4),
                                      "ttfb": round(ttfb, 4), "xfer": round(xfer, 4),
                                      "buf": round(buf, 2), "seq": nxt}) + "\n")
                log.flush()
            nxt += 1
            while buf >= args.buffer_max and not STOP.is_set():  # OFF period
                STOP.wait(0.2)
                drain()
            if time.monotonic() - last_refresh > src.seg_dur:
                src.refresh_edge(ref)
                last_refresh = time.monotonic()
        except Exception as exc:  # noqa: BLE001
            print(f"[bg{idx}] error: {exc}", file=sys.stderr)
            STOP.wait(1.0)
            try:
                src.refresh_edge(ref)
                last_refresh = time.monotonic()
            except Exception:  # noqa: BLE001
                pass


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=2)
    ap.add_argument("--abr", choices=["throughput", "buffer", "hybrid"], default="throughput")
    ap.add_argument("--protocol", choices=["dash", "hls"], default="dash")
    ap.add_argument("--bypass", action="store_true", help="send X-Force-Bypass-Cache: 1 (origin load)")
    ap.add_argument("--server", default="http://10.0.3.2")
    ap.add_argument("--buffer-max", type=float, default=10.0)
    ap.add_argument("--stagger", type=float, default=1.0, help="max random start offset per worker index [s]")
    ap.add_argument("--ramp-sec", type=float, default=0.0,
                    help="start every worker within this many seconds (0: --stagger per worker index)")
    ap.add_argument("--phase-spread", type=float, default=0.0,
                    help="max fixed per-worker wait after a segment is published [s] (0: synchronised)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--log", default="/var/log/background/hls.jsonl")
    args = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: STOP.set())
    signal.signal(signal.SIGINT, lambda *_: STOP.set())
    with open(args.log, "a", encoding="utf-8") as log:
        threads = [threading.Thread(target=worker, args=(i, args, log), daemon=True) for i in range(args.n)]
        for t in threads:
            t.start()
        while not STOP.is_set():
            STOP.wait(0.5)
        deadline = time.monotonic() + 3.0  # one deadline for all workers, not 3 s each
        for t in threads:
            t.join(timeout=max(0.0, deadline - time.monotonic()))


if __name__ == "__main__":
    main()
