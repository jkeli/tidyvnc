# Portable viewer targets

`tidyvnc_viewer_core` contains the shared desktop transform, monitor layout,
resampling, tile cache and cursor renderer. It links the existing RFB client
and transport libraries. The retained FLTK application, rendering unit tests
and scaling benchmark consume this same target instead of compiling separate
copies of the implementation.

`tidyvnc_viewer_platform` contains the initial host/service value contract:
display metrics and its validation. It has no dependency on protocol code or a
UI toolkit. The FLTK adapter obtains actual window/display values in
`vncviewer/DisplayMetrics.cxx`. Future native adapters supply the same values.
Storage, scheduling, clipboard and authentication services remain later work;
this target does not yet implement those interfaces or the session lifecycle.

Dependency direction:

```text
FLTK frontend / headless consumer
  -> tidyvnc_viewer_core
       -> tidyvnc_viewer_platform
       -> rfbclient / network -> rfb / rdr / core
```

Public includes use `<viewer/core/...>` and `<viewer/platform/...>`. Neither
target imports `vncviewer`, FLTK, AppKit, SwiftUI or WinUI. No GUI event loop is
initialized by the headless consumer. This is the build boundary for N1.1, not
a completed session engine or a stable public ABI.

## Reproduce the headless check

Install a C/C++ compiler, CMake, zlib, pixman and libjpeg-turbo. GnuTLS/nettle
are optional protocol dependencies; GoogleTest enables the full unit suite.
No FLTK or display server is needed. Then run from the repository root:

```sh
python3 tests/viewer/headless.py --build-dir build/headless
```

The directory must not already exist. The script never deletes an existing
build. Use `--cmake-arg=-DNAME=VALUE` to select dependencies/toolchains. For
example, on the development Mac with Homebrew and the existing GoogleTest:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
python3 tests/viewer/headless.py --build-dir build/headless-check \
  --cmake-arg=-GNinja \
  --cmake-arg=-DCMAKE_PREFIX_PATH=/opt/homebrew \
  --cmake-arg=-DGTest_DIR="$PWD/build/test-deps/install/lib/cmake/GTest" \
  --cmake-arg=-DENABLE_GNUTLS=ON --cmake-arg=-DENABLE_NETTLE=ON
```

The script configures with `BUILD_VIEWER=OFF`, `BUILD_PLATFORM_APPS=OFF` and
NLS/audio/H.264 disabled. It explicitly disables FLTK and X11 discovery,
checks the generated CMake dependency graph and portable headers for GUI
dependencies, builds all enabled targets, runs the independent smoke consumer,
and runs unit tests when GoogleTest is available. The smoke executable uses
the real RFB connection constructor, transport parser and rendering routines.
CI requires GoogleTest and repeats this check on Linux and macOS.

`BUILD_PLATFORM_APPS` defaults to `ON`, preserving legacy server/tool builds.
Setting it to `OFF` avoids platform application directories and their X11,
Wayland, PAM, SELinux, systemd and password-quality discovery. It does not
disable reusable `rfbserver` protocol code or protocol benchmarks. NLS-disabled
macOS core builds no longer link Carbon; retained translated builds keep the
existing bundle-localization behavior.

## Retained frames and cursors (N1.8)

`viewer::FramePublisher` is the session-executor-owned publication boundary.
`subscribe()` returns a thread-safe mailbox with an initial state snapshot;
`take()` returns the newest frame/cursor changes; a short mutex protects mailbox
assignment, with no decode or pixel copying under that lock.
The consumer may retain the immutable `FrameLease` / `CursorLease` on any thread.
Those leases remain valid across resize, generation reset and publisher teardown.

The producer supplies a complete, synchronized `PixelView`: explicit byte length,
byte stride, dimensions, BGRA8 or RGBA8 channel order, alpha mode and row origin.
It must join decoder writes before publishing and keep the input stable for the
call. Publication copies rows into packed top-left storage; it does not convert
channel order or alpha representation. Damage and cursor hotspots use top-left
remote coordinates even when input rows are bottom-up. No native window, OS
bitmap or borrowed protocol-buffer pointer is retained.

Every frame carries a connection generation, a size/layout generation and a
monotonic publication sequence. Dimensions, channel order or alpha changes
advance the layout generation and force full damage. `reset(nextGeneration)`
requires a strictly newer connection generation, drops pending old images and
queues explicit frame/cursor clears. Already-taken leases retain their original
generation; the eventual session/UI bridge must check it before presentation.
Old-generation publication requests are rejected without changing state.

Each mailbox holds at most one pending frame and cursor update. Skipped frame
updates replace the pending image and union the damage into a bounding rectangle,
independently for every subscriber. A resize forces full damage. Subscriptions
are bounded (16 by default), and expired mailboxes are reclaimed before adding
another subscriber. There are no user callbacks under a publisher lock.

The constructor's byte budget covers all copied pixel payloads, including old
leases held externally and cursor data. Source decoder buffers, allocator
metadata and host rendering surfaces are outside that budget. Payload bytes are
released before their budget reservation is returned. New publication reserves
its copy before replacing the old frame, so the budget must allow overlap
(normally at least two full frames plus cursor/retained-view allowance).
`Backpressure` means no new image was queued. The producer should retry with
its latest complete image after consumers release leases; frame damage is kept
until publication succeeds, including skipped resize invalidation. Cursor data
must be resubmitted. There is no waiting for leases on the engine or UI thread.
Invalid spans/layouts throw before copying; allocation failure propagates while
leaving existing leases intact. Cancellation/wakeup for retries belongs to N1.6.

This core contract and its headless consumer are implemented. Feeding it from
the extracted session engine, mapping leases into the C ABI and native renderer,
and measuring full-frame-copy performance belong to N1.7/N2 and the performance
gates. The retained FLTK rendering path is not switched to snapshot copies by
this change.
