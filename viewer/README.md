# Portable viewer targets

`tidyvnc_viewer_core` contains the window-independent protocol session and retained
frame publisher, plus the shared desktop transform, monitor layout,
resampling, tile cache and cursor renderer. It links the existing RFB client
and transport libraries. The retained FLTK application, rendering unit tests
and scaling benchmark consume this same target instead of compiling separate
copies of the implementation.

`tidyvnc_viewer_platform` contains the initial host/service value contract:
display metrics and its validation. It has no dependency on protocol code or a
UI toolkit. The FLTK adapter obtains actual window/display values in
`vncviewer/DisplayMetrics.cxx`. Future native adapters supply the same values.
Storage, scheduling, clipboard and authentication services remain later work;
this target does not yet implement those service interfaces. The core protocol
session is driven by a host executor; full command/event lifecycle is separate.

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
a completed command/event session engine or a stable public ABI.

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

The window-independent `ProtocolSession` now feeds this publisher (N1.7).
Mapping leases into the C ABI/native renderer and measuring full-frame-copy
performance remain N2 and the performance gates. The retained FLTK rendering
path is not switched to snapshot copies by this change.


## Window-independent protocol session (N1.7)

`viewer::ProtocolSession` owns a fresh RFB connection for each attempt, the
protocol framebuffer and the retained publication boundary. It owns no widgets,
windows, native surfaces or event loop. An executor calls `start()` with borrowed
input/output streams and calls `processMessage()` when data is available. Streams
must outlive `close()`. Security/TLS policy, clipboard limits and buffer budgets
are copied at construction; no legacy UI configuration is read by the wrapper.

The authoritative buffer is always 32-bit BGRA with opaque alpha semantics,
independent of host integer endianness. The session requests the matching wire
format. Raw/compressed/CopyRect data flows through the existing RFB decoder;
publication happens only after the end-of-update decoder join. Resize preserves
overlapping pixels, zeros exposed areas and produces full-damage publication.
RFB cursor callbacks feed straight RGBA cursor leases, including explicit hide.

`attachView()` returns a retained subscription with the current snapshot. Dropping
its final reference detaches the view; other views and protocol processing keep
running. Views receive immutable copies, never the decoder's mutable buffer.
After backpressure, the executor can call `retryPublication()` with no extra
network input. It returns false during an incomplete update or while retained
leases prevent another allocation. Cursor retry uses the latest protocol-owned
shape, not the borrowed callback buffer.

`close()` synchronously drains the RFB connection on its owning worker and queues
frame/cursor clears in a newer generation. Repeated close is harmless. A new
`start()` creates a new RFB object with fresh protocol/decode state, retaining
view subscriptions and rejecting active-attempt replacement. Errors from protocol
processing close the attempt and invalidate pending images before being rethrown;
already-held leases remain safe. `desktop()` returns an owned metadata snapshot.
This synchronous worker operation is not the future asynchronous close/drain API.

A host may supply `SessionAuthentication` for credentials/trust. Missing handlers
cancel credentials and reject trust; no dialog is opened. The delegate is retained
for the session lifetime. Callbacks must not reenter protocol processing, close or
publication. `PromptAuthentication` supplies the cancellable worker rendezvous
(N1.10); the host supplies notification delivery and native prompt presentation.

The default source-frame limit is 64 MiB and the publication payload budget is
128 MiB. Resize may temporarily hold both old and replacement source buffers
(up to twice the source limit), in addition to published leases, decoder scratch
and protocol state. Requests that exceed the source limit or the existing RFB
allocator's signed arithmetic capacity are rejected before allocation. These are
buffer budgets, not a whole-process memory ceiling.

The headless tests drive actual client RFB processing using fixture streams:
None negotiation, raw/CopyRect updates, resize, cursor shape/hide, view detach,
backpressure, reconnect, invalid dimensions and the VNC credential callback path.
The VNC fixture supplies SecurityResult rather than implementing a server-side
password verifier. Socket readiness, typed command/event operations, cancellation,
clipboard/input service adapters, native UI and async shutdown remain separate
milestones. The legacy FLTK `CConn`/`DesktopSession` remains the comparison adapter.

## Cancellable authentication prompts (N1.10)

Create one `PromptAuthentication` per logical session and pass it to
`ProtocolSession`. The session calls `beginAttempt()` with its generation and
server name. Credential, certificate and host-key callbacks publish owned request
data, invoke the notification hook outside the bridge mutex, then wait on a
condition variable on the requesting worker only. The wait releases that mutex;
the session holds no framebuffer, publisher or service-store lock at this seam.
The notification hook must promptly enqueue work for the UI/service dispatcher;
it must not enter a nested GUI loop, wait for UI completion or retain the bridge
strongly. The host must keep the bridge alive until its worker has drained.

The UI calls `takeRequest()` once per prompt and answers using `replyCredentials()`
or `replyTrust()` with both the request ID and connection generation. IDs increase
across reconnects; stale, duplicate, wrong-kind and oversized replies cannot
complete a different request. Certificate/key bytes and fingerprint strings are
owned copies. Only one prompt is outstanding per session. Identity bytes are
limited to 64 KiB and server names, fingerprints and each credential field to
4096 bytes. Private credential response storage is overwritten after consumption,
cancellation or failure; caller-owned strings retain their ordinary lifetimes.

Close, quit and reconnect controllers must call `cancel()` directly from their
thread before waiting for or queuing worker teardown. It wakes a parked callback
without a command running on that worker; cancellation also wins over a reply
accepted but not consumed yet. After callback unwinding, `ProtocolSession` closes
and advances the generation. Its own `close()` remains a worker-only operation,
not a thread-safe cancellation API. A new attempt may begin only after the old
worker has drained. Cancelling an attempt prevents later prompts in that attempt.

An unanswered prompt expires against a monotonic deadline (60 seconds by default,
configurable from a positive millisecond duration through 24 hours). A host socket
watcher can call `cancel(PromptCancelReason::PeerClosed)`; cancellation, timeout
and peer closure are distinguishable in `PromptInterrupted`. Automatic socket
watching belongs to N1.6; N1.11 below verifies actual TLS/socket cancellation.
Tests cover direct bridge races and real RFB client VNC callback resume/cancel
using fixture streams. Native dialogs, trust persistence and a main-thread event
dispatcher are not provided by this bridge.

## Real authentication and cancellation proof (N1.11)

On macOS/Linux builds with GnuTLS, `authenticationsocket` exercises
`ProtocolSession` and `PromptAuthentication` against an independent loopback TCP
RFB peer. The peer compares the received VNC DES response with a known answer
before sending success; a wrong password receives an actual failed SecurityResult.
The TLS cases negotiate VeNCrypt X509Vnc and TLS 1.2 with an ephemeral self-signed
certificate, then perform password verification inside the encrypted connection.
The tests accept or reject the actual certificate callback; no successful result
is substituted for the handshake.

The same tests cancel outstanding trust/credential prompts on host close/quit,
expire an unanswered request, and observe a socket FIN while the worker is parked.
The test host detects FIN with kqueue `EV_EOF` (macOS) or `POLLRDHUP` (Linux), then
calls direct prompt cancellation. It never consumes protocol bytes on a competing
reader. Reconnect uses the same session/bridge with a fresh socket, generation and
request ID, and rejects stale and duplicate responses. A second session with a
different security mode completes while the first remains parked.

Run in an existing GnuTLS-enabled build:

```sh
cmake --build build/headless-check --target authenticationsocket
ctest --test-dir build/headless-check/tests/unit -R AuthenticationSocket \
  --output-on-failure --no-tests=error
```

These tests bind only `127.0.0.1` on an ephemeral port and need permission to open
local sockets. They generate certificate/key material in memory and contact no
external server. CTest caps each case at 30 seconds; prompt, peer and drain waits
also have deadlines. The headless CI matrix automatically includes the suite.

This proves the synchronous security callbacks can pause and unwind safely at
the core/host boundary. The host controller and FIN watcher here are test fixtures;
the production readiness adapter (N1.6), asynchronous lifecycle/drain (N1.5/N1.13),
native close/quit wiring, other TLS versions/security modes, and Windows socket
coverage remain separate acceptance work. N1.14's complete settings/input/clipboard
isolation matrix also remains open.

## Bounded keyboard and pointer input (N1.12 input portion)

`ProtocolSession::inputQueue()` returns a retainable, thread-safe mailbox for
host-mapped RFB keysyms/QEMU keycodes and remote pointer coordinates. Submit the
current connection generation with each event. The core rejects disconnected,
stale, view-only and unfocused input; invalid button masks and empty key presses
are rejected before reaching the protocol writer. Physical key IDs match repeats
and releases to the original press mapping. Native shortcut/keyboard translation
remains the host's responsibility; the portable path does not apply the legacy
`CConnection::sendKeyPress()` platform remapping a second time.

The host wakes its worker after input or policy changes, then calls
`drainInput()` on that worker. Submission never writes to the socket. Each drain
processes at most `inputCommands + 1` entries, keeping a busy producer from
monopolizing protocol processing. Check mailbox status and schedule another drain
if queued input or a release flag remains; the return value is not an empty-queue
indicator. Consecutive pointer motions with unchanged
buttons coalesce, including drag motion. Button transitions retain their original
coordinates and are never coalesced; motion never crosses a key-event boundary.
The existing RFB writer clamps positions and negotiates extended keys/buttons.

The default queue capacity is 256 commands (configurable from 1 through 65536),
with at most 64 held physical keys (1 through 1024). A separate release-all flag
cannot be crowded out by input commands. Queue/storage exhaustion returns
`InputResult::Overflow`, clears unsent input, increments the observable overflow
counter and suspends new input until explicit `setFocused(generation, true)`.
Held-key exhaustion reports false from `drainInput()`, releases held state in that
call and records the same mailbox fault. Queue status is a bounded snapshot;
the wider lifecycle/error event stream is still N1.5/N1.12 work.

`setFocused(..., false)` clears unsent input and requests key/button release.
Reactivation keeps that release ahead of newly accepted input. Enabling view-only
has the same release behavior and blocks new submissions in core. A command
already dequeued by the worker may finish before a concurrent policy change;
the next dequeue handles the release. Focus and view-only policy persist across
reconnect, while queued events and held state do not. View-only is logical-session
policy; its setter does not carry a connection generation.

Close and protocol/write failure invalidate queued input and attempt to release
held keys/buttons before destroying the connection. A dead transport can prevent
remote delivery; release-write failures do not prevent local cleanup or replace
the original exception. Transport buffering, writable readiness and asynchronous
flush/drain are separate responsibilities of N1.6/N1.13. These queue/held-key limits
are not a whole-process or transport-buffer memory budget. Retained mailboxes
remain safe and reject input after session destruction.

`SessionInput` tests decode the emitted RFB bytes and exercise coalescing,
transition order, repeats, extended capabilities, focus/view-only changes,
overflow/recovery, disconnect/reconnect, write/protocol failure, retained lifetime,
and a concurrent producer with independent sessions. Native input translation,
focus ownership across multiple views, general event/completion queues and the
remaining N1.12 acceptance criteria are still pending.
