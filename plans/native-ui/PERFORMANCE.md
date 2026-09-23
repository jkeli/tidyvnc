# Viewer workload measurements

Local matched baseline for N0.5/N5.9, recorded 2026-09-23. This is **not** a
completed performance gate. Native presentation latency, presentation copies,
damage and a two-view workload are measured below. Not measured: FLTK
presentation latency, allocation rate, mixed displays and a second machine. All
results come from one machine.

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

## Native presentation latency, copies and damage (2026-09-23)

`tests/perf/viewer-workloads.py --probe <core>/tests/macos/native-presentation-probe`
runs the same peer and workloads against `native-presentation-probe`. The probe
hosts the production `NativeSession` and `NativeDesktopView` in on-screen
1280×720 windows (fit scaling, bilinear, 2× backing, so each view resamples to a
2560×1440 output). `--probe-views 2` binds two views to one session. The only
product change is an internal `onDrawn` seam on the view, called after
`draw(_:)`. The peer records when it finished writing each update and the probe
records, in the same `CLOCK_UPTIME_RAW` clock:

- **decode**: update written → frame published to the main actor;
- **draw**: → AppKit finished drawing that frame (in the last view, with two views);
- **display (estimate)**: → the next display-link refresh target after the draw.
  This is the earliest time the frame can reach the screen. Compositor delay and
  panel response are not included; there was no camera or photon measurement.

Per drawn view frame the probe also reports:

- **rendered**: resampled output bytes written, i.e. copies made for presentation;
- **resident**: output tile bytes held;
- **damage**: invalidated device pixels as a fraction of the view.

Each arrival is paired with the latest update sent before it. No steady-state
arrival was later than one offered interval (33 ms), so the pairing is
unambiguous. The single late arrivals are connection first frames. `patch` is a
new small-damage workload: one moving 64×64 Raw rectangle per update on a 1080p
desktop.

Setup: Release build (`build/native-release-validation`), 30 updates/s, 8 s per
workload, 120 Hz refresh (8.35 ms). There were two single-view runs, shown as
ranges, and one two-view run. Raw JSON:
[perf-2026-09-23-presentation.json](perf-2026-09-23-presentation.json).

| Workload | Views | Sent / drawn | Decode p50 / p95 | Draw p50 / p95 | Display est. p50 / p95 | Rendered / frame | Damage | CPU s/s | Peak RSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| full1080 | 1 | 242 / 240 | 3.5 / 3.9–4.0 ms | 15.5–15.8 / 16.7–17.2 ms | 21.2–21.5 / 22.0–22.7 ms | 14.1 MiB | 100% | 0.65 | 266 MiB |
| full4k | 1 | 242 / 241–242 | 2.3–2.4 / 3.3 ms | 14.3–14.5 / 16.7–18.5 ms | 18.2–19.2 / 22.3–22.4 ms | 14.1 MiB | 100% | 0.85 | 606 MiB |
| scroll | 1 | 242 / 240 | 0.9–1.1 / 1.2 ms | 14.1–14.3 / 15.2–16.1 ms | 16.1–16.3 / 20.6–21.3 ms | 14.1 MiB | 100% | 0.49 | 210–214 MiB |
| patch | 1 | 242 / 241 | 0.7 / 1.8–2.1 ms | 2.5–3.4 / 5.7–6.1 ms | 5.6–8.3 / 10.8 ms | 0.5 MiB | 0.21% | 0.12 | 227–231 MiB |
| full1080 | 2 | 242 / 240 | 3.5 / 4.1 ms | 19.0 / 22.2 ms | 27.1 / 30.3 ms | 14.1 MiB each | 100% | 1.04 | 347 MiB |
| scroll | 2 | 242 / 240 | 0.8 / 1.2 ms | 16.3 / 19.5 ms | 24.2 / 27.4 ms | 14.1 MiB each | 100% | 0.88 | 246 MiB |
| patch | 2 | 242 / 240 | 0.6 / 2.1 ms | 3.8 / 10.6 ms | 10.7 / 18.7 ms | 0.5 MiB each | 0.21% | 0.18 | 332 MiB |

`idle` has one sample, the first frame after connecting (decode 27–34 ms, draw
43–52 ms). That time includes session setup and the first allocation of geometry
and 14 MiB of output tiles. A Debug build was about 2.5 ms slower to draw at 1080p.

Reading:

- **Updates are presented, not only decoded.** The native path keeps the offered
  rate and draws all but at most two updates per run, in every workload.
- **Full-frame draw cost is resampling.** Draw latency follows the damaged output
  size, not the source size. A full update resamples the whole 14 MiB output, so
  1080p, 4K and scroll all cost about 14–16 ms p50. A 64×64 patch touches 0.21%
  of the view but still re-renders 0.5 MiB, because damage is rounded out to
  output tiles; it draws in about 3 ms p50.
- **Scroll invalidates the whole view.** CopyRect currently marks the full view
  as damaged; it does not shift the existing output.
- **A second view** of the same session adds its own 14 MiB output copy per full
  frame. That costs about 0.4 CPU s/s, 3–4 ms of draw p50 and 80–100 MiB of RSS.
  It stays at the offered rate.
- **FLTK not compared.** FLTK has no matching draw hook, so its presentation
  latency was not measured. Its protocol round trip (about 55 ms at 1080p, above)
  is a different measurement.
- **Sign-off open.** The N0.5/N5.9 budget decision remains a review item.
