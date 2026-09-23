# Viewer workload measurements

Local matched baseline for N0.5/N5.9, recorded 2026-09-23. This is **not** a
completed performance gate: presentation latency, copies/allocation rate, damage
size and multi-view workloads are not measured, and the results come from one machine.

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
