# Viewer workload measurements

Local matched baseline for N0.5/N5.9, recorded 2026-09-23. This is **not** a
completed performance gate: copies/allocation rate, damage size, multi-view
workloads and FLTK presentation latency are not measured, and the results come
from one machine. Native presentation latency is measured below.

## Method

`tests/perf/viewer-workloads.py` runs an actual viewer executable against a
loopback RFB 3.8 peer that answers FramebufferUpdateRequests with scripted
updates at a fixed offered rate (30 updates/s). Workloads: `idle` (one frame, then
nothing), `full1080` and `full4k` (full-frame Raw every update), and `scroll`
(1080p CopyRect shift of 16 rows plus a 16-row Raw strip). Both frontends run with
`-ScalingFactor=100 -RemoteResize=0`, no clipboard and fresh HOME/XDG roots; the
native app runs as an isolated copy. CPU is user+system time per wall second, RSS
is the peak of 250 ms samples.

```sh
python3 tests/perf/viewer-workloads.py \
  --native build/native-release-validation/app/Release/TidyVNC.app \
  --fltk build/hidpi-release/vncviewer/vncviewer --seconds 8 --report results.json
```

## Results (Apple M3 Max, 14 cores, 36 GiB, macOS 27.0, built-in Retina display)

Native: Release app built at `8b56c793`. FLTK: retained Release viewer
(`build/hidpi-release`). Raw JSON: [perf-2026-09-23-workloads.json](perf-2026-09-23-workloads.json).

| Workload (offered 30/s) | Frontend | Updates/s | CPU s/s | Peak RSS |
| --- | --- | --- | --- | --- |
| idle | FLTK | 0 | 0.142 | 249 MiB |
| idle | native | 0 | 0.007 | 194 MiB |
| full1080 | FLTK | 15.8 | 0.987 | 337 MiB |
| full1080 | native | 30.1 | 0.646 | 288 MiB |
| full4k | FLTK | 10.8 | 0.923 | 601 MiB |
| full4k | native | 30.1 | 0.755 | 620 MiB |
| scroll | FLTK | 16.0 | 1.002 | 288 MiB |
| scroll | native | 30.1 | 0.429 | 229 MiB |

Reading: the native app keeps up with the offered rate in every workload at lower
CPU, while the FLTK viewer saturates near one core at 11–16 updates/s. Idle cost is
about 20× lower. 4K peak RSS is within 3% (native 620 vs FLTK 601 MiB), inside the
provisional 10% regression threshold.

Caveats, which keep N0.5 and N5.9 open:

- **Not like-for-like presentation.** FLTK draws each update before requesting the
  next; native decodes each update, but presentation may coalesce updates at the
  display's refresh. "Updates/s" is decoded updates, not displayed frames.
- The harness's request round trip is near zero when a viewer pipelines requests
  and never includes display time, so it is not reported as latency here.
- No decode-to-present p50/p95, input latency, copy/allocation rate, damage size,
  multi-view or mixed-display measurements; no second machine; one run of 8 s each.

## Native presentation latency (2026-09-23)

`tests/perf/viewer-workloads.py --probe <core>/tests/macos/native-presentation-probe`
runs the same peer and workloads against `native-presentation-probe`, which hosts
the production `NativeSession` and `NativeDesktopView` in an on-screen 1280×720
window (fit scaling, bilinear, 2× backing, so 1080p and 4K sources are resampled).
The only product change is an internal `onDrawn` seam on the view, called after
`draw(_:)`. The peer records when it finished writing each update and the probe
records, in the same `CLOCK_UPTIME_RAW` clock:

- **decode**: update written → frame published to the main actor;
- **draw**: → AppKit finished drawing that frame;
- **display (estimate)**: → the next display-link refresh target after the draw.
  This is the earliest time the frame can reach the screen. Compositor delay and
  panel response are not included; there was no camera or photon measurement.

Each arrival is paired with the latest update sent before it. No steady-state
arrival was later than one offered interval (33 ms), so the pairing is
unambiguous. The single late arrival in `scroll` is the connection's first frame.
Release build (`build/native-release-validation`), two 8 s runs at 30 updates/s,
120 Hz refresh (8.35 ms). Raw JSON:
[perf-2026-09-23-presentation.json](perf-2026-09-23-presentation.json).

| Workload | Sent / drawn | Decode p50 / p95 | Draw p50 / p95 | Display est. p50 / p95 | CPU s/s |
| --- | --- | --- | --- | --- | --- |
| full1080 | 242 / 240 | 3.5 / 4.0 ms | 15.7 / 17.5 ms | 21.3–21.8 / 22.1–23.2 ms | 0.66 |
| full4k | 242 / 242 | 2.4 / 3.5 ms | 14.8 / 18.0 ms | 18.6–18.9 / 22.6–23.4 ms | 0.87 |
| scroll | 242 / 240 | 0.9–1.0 / 1.2 ms | 14.1–14.5 / 17.7 ms | 19.0–19.3 / 21.9 ms | 0.48 |

Ranges show the spread between the two runs; other values matched in both.
`idle` has one sample, the first frame after connecting (decode 34–36 ms, draw
51–59 ms). That time includes session setup and the first geometry and tile
allocation, so it is a first-frame figure, not steady state. A Debug build was
about 2.5 ms slower to draw.

Reading: in every workload the native path keeps the offered rate, and all but at
most two updates per run were drawn. Draw latency is about 15 ms p50 and under
18 ms p95. Its size barely changes between 1080p, 4K and scroll, so it is
dominated by the resampling handoff and the wait for the display cycle, not by
source size. The frame is drawn about 11–13 ms after it arrives. FLTK has no
matching draw hook, so its presentation latency was not measured. Its protocol
round trip (about 55 ms at 1080p, above) is a different measurement and is not
compared. Budgets for sign-off remain an N0.5/N5.9 review decision.
