# Portable viewer targets

`tidyvnc_viewer_core` contains the window-independent protocol session and retained
frame publisher, plus the shared desktop transform, monitor layout,
resampling, tile cache and cursor renderer. It links the existing RFB client
and transport libraries. The retained FLTK application, rendering unit tests
and scaling benchmark consume this same target instead of compiling separate
copies of the implementation.

`tidyvnc_viewer_platform` contains display metrics/validation, the portable
transport/wakeup contracts, a macOS/Linux established-socket adapter and endpoint
connection setup with asynchronous macOS hostname resolution. It links
the existing network/stream libraries without depending on RFB protocol code or
a UI toolkit. The FLTK adapter obtains actual window/display values in
`vncviewer/DisplayMetrics.cxx`. Future native adapters supply the same values.
Storage, clipboard and native authentication services remain later work;
this target does not yet implement those service interfaces. The core protocol
session is driven by a host executor; its monotonic scheduler is described below.
`SessionRuntime` owns connection setup, protocol workers and asynchronous drain,
as described below. Reusable sessions preserve identity and settings across
connection generations. The remaining command catalog and listener readiness
remain separate.

Dependency direction:

```text
FLTK frontend / headless consumer
  -> tidyvnc_viewer_core
       -> tidyvnc_viewer_platform -> network / rdr / core
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
leaving existing leases intact. ProtocolSession now schedules bounded retries;
the host must dispatch its deadlines as described below.

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
independent of host integer endianness. Wire color/encoding selection follows the
session's validated encoding options; decoders convert reduced wire formats into
the same BGRA framebuffer. Raw/compressed/CopyRect data flows through the existing RFB decoder;
publication happens only after the end-of-update decoder join. Resize preserves
overlapping pixels, zeros exposed areas and produces full-damage publication.
RFB cursor callbacks feed straight RGBA cursor leases, including explicit hide.

`attachView()` returns a retained subscription with the current snapshot. Dropping
its final reference detaches the view; other views and protocol processing keep
running. Views receive immutable copies, never the decoder's mutable buffer.
After backpressure, the session schedules a retry without extra network input;
the executor must drive `dispatchScheduled()`. It can also call
`retryPublication()` explicitly. That returns false during an incomplete update or while retained
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
and peer closure are distinguishable in `PromptInterrupted`. The N1.6 transport
below supplies the FIN wait; the host owns its observer and direct cancellation.
N1.11 below verifies actual TLS/socket cancellation.
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
The test host now uses the production `SessionTransport` for both worker IO
readiness and an independent FIN wait, then calls direct prompt cancellation.
The adapter uses kqueue `EV_EOF` (macOS) or `POLLRDHUP` (Linux), and consumes no bytes on a competing
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
the core/host boundary. The original host controller remains a test fixture;
four additional cases use the production `SessionRuntime` described below.
Socket readiness and the FIN watcher use the production adapter.
Endpoint setup and asynchronous worker drain are described below. Listener
readiness, native close/quit wiring, other TLS versions/security modes, and Windows socket
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
the bounded event stream is described below; the wider lifecycle/error event
catalog remains N1.5 work.

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
focus ownership across multiple views and the full command/lifecycle catalog
remain pending. The event/completion queue is implemented below.

## Bounded session events and refresh completion (N1.12)

A worker calls `ProtocolSession::subscribeEvents(capacity)` to attach one lifecycle
coordinator, independently of the frame/view subscribers. The returned retained
`SessionEvents` stream begins with the current owned snapshot, including when
subscribing after connection. The coordinator consumes it with `take()` on any
thread. State publication belongs to the serialized session/host executor;
operation reservation/completion can also run on synchronized command-admission
and cancellation threads. UI consumers use the worker command API, not the event
producer methods directly. There are no event callbacks under locks.
Dropping the stream detaches it. A sealed stream can be replaced with a new one
starting from the latest session snapshot.

The session publishes negotiation, authenticating, connected, closed/failed, desktop-size and
bell events, plus completed-frame statistics. This is the existing protocol
owner's event surface; it does not yet implement resolving/listening,
the full command catalog, service events or all asynchronous lifecycle
operations from N1.5/N1.9. Frame/cursor pixel leases remain in their own bounded
coalescing mailboxes. Statistics currently contain complete-update and bell counts;
statistics delivery is throttled by the session scheduler described below.

Every event carries a queue-local increasing sequence and connection generation.
The initial snapshot and reliable events retain their order. New statistics
replace older pending statistics by removing them and appending the newest event;
sequence gaps are therefore valid. Reliable events may reclaim a statistics slot.
If only reliable events/reservations occupy capacity, statistics update the
queryable snapshot without taking a slot. They never displace a completion.

`reserve(generation)` admits an operation only if a completion slot is available;
zero rejects without a completion obligation. `complete(id, result)` converts
that reservation into exactly one ordered result. `pending(id,generation)` validates
an externally reserved execution token. Duplicate/unknown IDs and stale
admission generations are rejected. Pending operations must finish before advancing
the stream generation. IDs are scoped to their stream, so the host must retain
that identity with an operation token across coordinator replacement.

`ProtocolSession::requestRefresh()` uses this contract. It requires a connected
session and active event coordinator, returning zero on rejection. A successful
completion means the RFB refresh request was scheduled, not that a new framebuffer
has arrived. Normal close cancels pending operations and publishes its terminal
state; the same stream can continue across reconnect with a new generation.
Session destruction seals a retained stream after terminal events, which remain
readable. Sealing on the executor cancels remaining reservations and prevents new
admission/publication without discarding queued results.

The default `SessionTerminalOwnership::Protocol` preserves this standalone
behavior. `SessionWorker` uses Host ownership: protocol failure still immediately
cleans up streams/decoders/views/timers, but leaves terminal publication, pending
operation settlement and sealing to the worker after it classifies termination.
For externally reserved refresh/encoding operations, a nonzero token is validated
against the pending stream/generation and execution leaves completion to the host.
Ordinary zero-argument synchronous admission/completion remains unchanged.

The capacity defaults to 128 and is configurable from 2 through 65536. Fixed-size
records and operation storage are preallocated at construction. The count of
queued events plus reserved completions never exceeds capacity, with one extra
fixed terminal-overflow record. If another reliable event cannot fit, the stream
fails outstanding operations, preserves queued events/completions, then delivers
exactly one `Overflow` and seals. Protocol publication failure closes the affected
attempt and releases held input. It never silently drops a completion or grows an
unbounded queue. Sequence exhaustion also preserves space for pending completions
and the terminal fault. A consumer must drain terminal records before replacing
its coordinator if it still needs those results.

`SessionEvents` and `ProtocolSession` tests exercise reserved capacity, reliable
ordering, statistics replacement, cancellation/sealing, overflow, concurrency,
late subscription, resize snapshots, refresh admission/completion, reconnect,
retained lifetime and real RFB input release on event overflow. Together with the
input and frame mailboxes, this completes N1.12's queue/coalescing contract. The
full session/listener state machine and operation catalog remain N1.5.

## Owned endpoints (N1.2 endpoint portion)

`viewer::Endpoint::parse()` returns an owned destination with original display
text, transport, canonical host, numeric port, IPv6 scope, Unix socket path and
optional opaque tunnel-route identity. It performs no DNS lookup, filesystem IO,
socket initialization or global configuration access. Getters do not allow field
mutation after validation. `networkHost()` combines the host and scope for a
resolver; the route identity describes the intended destination route, not an
ephemeral local tunnel port or a shell command.

The shared `network::parseHostAndPort()` implements VNC syntax for both this value
and the existing `getHostAndPort()` compatibility adapter. Single-colon numbers
below 100 are display numbers; double-colon numbers are explicit ports. Empty
hosts mean localhost. Brackets disambiguate IPv6, including scopes. Historical
ambiguities are preserved: `::1` means localhost port 1 and `2001::1` means host
`2001` port 1; use `[::1]` and `[2001::1]` for those IPv6 addresses. Surrounding
ASCII whitespace and a leading plus on numbers remain accepted. The server's
reverse-connection base port of 5500 is also preserved.

Ports are checked before narrowing to 16 bits. Empty suffixes (`host:`/`host::`),
negative numbers, explicit zero, out-of-range numbers, integer overflow and malformed
host brackets/whitespace are now rejected instead of relying
on `strtol` truncation or a later socket failure. The adapter retains localized
errors; the new string APIs also reject embedded NUL and expose typed error codes
with diagnostics that omit input.
Empty/all-whitespace input safely yields localhost:5900. Parsing uses explicit
ASCII rules rather than the process locale.

Endpoint equality ignores the original label, folds ASCII hostname case and
normalizes numeric IP literals. It does not resolve or merge DNS aliases, remove
trailing dots, merge IPv4 with IPv4-mapped IPv6, interpret interface names/indices,
or case-fold scope/route IDs. Non-ASCII host bytes are preserved; IDNA conversion
is not implemented. A credential key must additionally include authentication
kind and username; endpoint equality alone is not a credential lookup contract.

Any slash selects Unix transport, matching the POSIX viewer's existing syntax.
Paths remain exact bytes, including whitespace, case and relative components;
there is no URI parsing, expansion, symlink resolution or path normalization.
Hosts without Unix support explicitly pass `allowUnixSockets=false` and receive
`UnsupportedTransport`. The value can otherwise be parsed on any platform.
Platform socket path limits and relative-path resolution belong to the eventual
transport adapter. Address and route strings are each capped at 4096 bytes.

The headless smoke consumer exercises the endpoint value. Twelve endpoint tests
and the ten existing host/port tests cover compatibility, reverse connections,
identity separation, bounds, invalid data, ownership and concurrent parsing.
Typed connection options, schema/default/precedence validation, capabilities,
general session errors and production native connection wiring remain N1.2/N1.3.

## Encoding settings and shared selection policy (N1.2/N1.3/N1.4)

`EncodingOptions` owns eight validated encoding/color settings. `encodingSchema()`
provides canonical names, aliases, types, defaults, ranges and persistence/live
metadata. `encodingChoices()` reports the six existing preferred encodings and
whether each decoder is compiled; an unavailable choice yields `Unsupported`.
No native call reads the legacy parameter registry. The existing RFB security
and clipboard-limit snapshots remain separate inputs; this is not the complete
connection settings schema.

| Setting | Default | Accepted values / alias |
| --- | --- | --- |
| AutoSelect | on | Boolean |
| FullColor | on | Boolean; FullColour |
| LowColorLevel | 2 | 0–2; LowColourLevel |
| PreferredEncoding | Tight | Tight, JPEG, ZRLE, Hextile, H.264 when compiled, Raw |
| CustomCompressLevel | off | Boolean |
| CompressLevel | 2 | 0–9 |
| NoJPEG | off | Boolean |
| QualityLevel | 8 | 0–9 |

`resolve(defaults, profile, session, commandLine)` applies compiled defaults →
app defaults → explicitly selected profile → session overrides → CLI overrides.
`source(id)` records the effective source, including when an alias was used.
Each supplied layer is validated even when a later layer replaces its value.
`withPatch()` returns a new snapshot or throws a typed `OptionError`; a failed
draft cannot partially change the original snapshot. It applies the explicit
patch unconditionally and labels its provenance; use `resolve()` for startup
precedence. Duplicate assignments within a patch use the last value. Names,
aliases, enums and boolean words use ASCII case-insensitive matching. Boolean
spellings match the retained viewer, including empty text meaning enabled.
Integers retain base-0 decimal/octal/hex and leading whitespace/sign syntax;
empty integer text now fails instead of accidentally becoming zero. Patches
are bounded to 256 entries and each name/value to 128 bytes. Embedded NUL is
rejected; errors do not include the supplied text.

`ProtocolSession` accepts a snapshot as its final constructor argument.
`applyEncodingOptions()` runs on the worker, requires a connected session and
an event coordinator, and reserves a completion before changing any settings.
Zero means rejection with no mutation. Success means the new policy is scheduled
at the RFB implementation's safe format/encoding boundary, not that the server
has acknowledged it. The snapshot survives reconnect; a new attempt starts with
a fresh bandwidth estimate. The worker-only getter returns an owned copy.

Both the core session and retained FLTK viewer use the same selection rules:
AutoSelect chooses Tight, quality 8 above 16 Mbit/s and 6 otherwise, and full
color above 256 kbit/s. Reduced color retains the existing 8/64/256-color layouts.
NoJPEG suppresses both standalone JPEG and Tight JPEG hints; a preferred JPEG
choice can remain stored while JPEG is disabled. Disabling custom compression
omits that hint. Settings preserve manual values while automatic mode is active.
Servers before RFB 3.8 retain their negotiated pixel format to avoid the known
asynchronous-cursor format hazard; stored color preferences do not change that
wire format. Future native controls must surface this server limitation.

The shared bandwidth estimator starts at 20 Mbit/s and uses the existing
one-second weight with a 20% per-update cap. The callers measure update duration
with `steady_clock`, including decoder work. Arithmetic saturates samples at
1 Tbit/s to avoid overflow. FLTK measures socket bytes; the portable session
measures its active RFB input stream (plaintext after TLS), so encrypted transport
overhead is excluded there. This is not a matched performance-budget result.

FLTK's encoding parameter adapters consume the same defaults, ranges, compiled
choices and text validator. Their existing aliases and global UI/document
interfaces remain available, while `CConn` captures a value snapshot initially
and on explicit Options callbacks. It no longer reads these globals during
automatic selection or sets the global FullColor value for an old server.
Initial negotiation now applies automatic quality and the custom-compression
toggle consistently with later updates, instead of briefly sending the manual
quality/default compression hint. The low-level RFB NoJPEG boolean remains a
legacy compatibility entry with matching boolean semantics.

Eleven policy tests, seven real RFB wire tests and a FLTK adapter test cover
defaults/aliases, precedence/provenance, draft atomicity, unavailable decoders,
limits, thresholds, independent snapshots/sessions, live completion/admission,
reconnect, old servers and actual reduced-color conversion into retained BGRA.
Document transactions, security/display/input/clipboard/launch settings, general
capabilities/errors, native presentation and the full apply-options command
contract remain open. This does not complete N1.2, N1.3 or N1.4.

## Session-owned monotonic scheduling (N1.6 timer portion)

`SessionScheduler` replaces process-global timer lists for the portable session.
It owns a bounded queue of one-shot callbacks using `steady_clock` deadlines.
Default capacity is 64, configurable from 1 through 4096. Equal deadlines run in
admission order; an invalid returned token means the queue was full, shut down,
or exhausted its monotonically increasing IDs. Queue capacity bounds pending
callback count, not the bytes captured by caller-provided functions. At most one
additional callback is running. Timer allocation and callback-capture destruction
happen outside the queue lock, including rejection, cancellation and teardown.

Producers can schedule and cancel from other threads. A token is scoped to its
scheduler, copyable, explicitly cancelled, and safe after shutdown/destruction;
it retains neither the callback nor the scheduler. `cancel()` succeeds only while
the callback remains queued. Dequeue is the execution boundary: cancellation does
not interrupt or wait for an already-started callback. `cancelAll()` cancels the
current queue but permits new work; `shutdown()` additionally prevents future
admission. IDs are never reused. Destroying a scheduler cancels queued captures.
Neither shutdown nor destruction joins the executor; hosts must drain running
callbacks before destroying the scheduler or their callback targets.

The optional retained `SchedulerWakeup` adapter is notified after successful
admission, cancellation and shutdown, outside locks. It must be thread-safe,
nonblocking and noexcept, and signal a coalescing, level-triggered host wakeup.
It must not reenter protocol processing. No native descriptors, GUI loop or worker
thread are created by the scheduler. The adapter must retain its notification
resources through worker drain. `SessionTransport::control()` supplies the
macOS/Linux socket implementation described below.

The sole executor calls `dispatchDue(now, budget)` and then queries `nextDeadline()`
before waiting for IO, a wakeup or that deadline. It must recheck work after a
wakeup, including when a producer changed the deadline while the executor was
preparing to wait. The callback budget prevents self-rescheduling from monopolizing
the worker. Concurrent/reentrant dispatch is rejected. A throwing callback is
consumed, the dispatch guard resets, and its exception propagates; unrelated
callbacks remain queued for the owner's failure policy. Callbacks can schedule,
cancel or shut down the queue; they cannot destroy it during dispatch.

`ProtocolSession` owns a two-slot scheduler. A completed framebuffer update arms
one statistics timer, default 100 ms; further frames update the pending sample
without postponing its deadline. The callback publishes the latest counters once
and leaves no periodic work while idle. A new event subscriber still receives the
current snapshot immediately. Existing event-stream statistics snapshots can lag
until the deadline or a reliable event publishes newer counters; terminal events
include the final counts even when the statistics timer was cancelled.

Backpressured frame/cursor publication arms one retry, default 16 ms, using the
latest complete protocol-owned image. The callback reschedules only if still
blocked. It cannot publish a partially decoded update. Successful publication,
including a normal incoming update or manual `retryPublication()`, cancels the
pending retry. The host must run `dispatchScheduled()` even when no new socket data
arrives; otherwise statistics/retries cannot progress. An unreleased frame can
keep retries pending indefinitely, but each call and its next deadline are bounded.
Lease-release wakeups and performance tuning remain later integration work.

`SessionTiming` supplies intervals, an optional wakeup adapter and an injectable
worker-only monotonic clock. Intervals must be 1–60000 ms. `nextDeadline()` and
`dispatchScheduled()` are worker-only session APIs; default dispatch budget is two.
Close, failure and reconnect cancel all timer kinds before protocol destruction.
Remote resize now adds a third slot for its reply deadline (described below).
Callbacks also check attempt generation. Timer/publication exceptions close the
attempt after unwinding; invalid zero-budget dispatch rejects without closing.
There is no UI-thread join or global timer dispatch. This completes the timer
portion; established socket readiness, runtime execution and asynchronous drain
are described below.

Ten scheduler tests and seven additional protocol tests cover deadline/FIFO order,
capacity, cancellation races, capture disposal and wakeup reentry, dispatch bounds,
exceptions, retained tokens, concurrent producers, per-session timer isolation,
statistics throttling, retry without IO, incomplete updates and reconnect cleanup.
The existing frame-statistics test now drives a deterministic deadline explicitly.

## Owned established-socket transport (N1.6 transport portion)

`viewer/platform/SessionTransport.h` defines a descriptor-free transport contract.
The sole session worker borrows its input/output streams, flushes pending output
and waits for readable/writable readiness, a work notification or an absolute
`steady_clock` deadline. `TimePoint::max()` permits indefinite waits. Readiness is
advisory; process buffered protocol data before waiting, enable writable interest
only while `outputPending()`, and dispatch commands/timers after each return.
Flags may coexist: peer closure does not discard unread final bytes. System IO
failures throw `std::system_error` with an operation and native error code, without
endpoint/credential text. Invalid adoption arguments throw `std::invalid_argument`.

`SocketTransport.h` is a separate adapter boundary: on macOS/Linux,
`adoptSocketTransport()` takes exclusive ownership of an established
`network::Socket`, including failure paths. It validates a connected stream,
configures nonblocking and close-on-exec, and suppresses socket SIGPIPE on macOS.
TCP and Unix stream sockets share the implementation. Legacy streams still use
`select` internally, so descriptors outside `FD_SETSIZE` are explicitly rejected.
This is an implementation limit, not a descriptor type in the portable contract.
The socket initialization helper now uses `std::call_once`, preserving existing
Winsock/SIGPIPE behavior while preventing concurrent initialization races.
FdStreams treat EAGAIN/EWOULDBLOCK as no progress, preserving buffered output.

The retainable `TransportControl` implements `SchedulerWakeup` for timers and
host commands. `wake()` is thread-safe, noexcept and nonblocking; a bounded
nonblocking pipe preserves wake-before-wait and coalesces a full pipe. Notification
drain is bounded, so continuous producers cannot monopolize the worker inside a
single wait. Additional/spurious wakeups are permitted; always recheck work.
`cancel()` is irreversible per attempt, idempotent, shuts down the socket and
wakes both waiters. It never calls stream-mutating `Socket::shutdownRead/Write`.
Controls weakly retain state; they are safe after teardown and cannot cancel a
later attempt even if the OS reuses the same descriptor. An in-flight control call
holds the resources until it returns, preventing shutdown/close/reuse races.

One independent host observer may call `waitPeerClosure()` while the worker is
parked on a synchronous authentication prompt. It consumes/peeks at no bytes and
ignores worker wakeups and ordinary readable data. macOS uses a persistent kqueue
with EV_CLEAR, avoiding a busy loop over unread data while still detecting EV_EOF;
Linux polls POLLRDHUP without POLLIN. A separate cancellation pipe prevents one
waiter from stealing the other's cancellation wakeup. Both paths recompute the
remaining monotonic timeout after interrupted waits. FIN is sticky and wakes the
worker too. The host maps it to direct `PromptAuthentication::cancel(PeerClosed)`.
Transport cancellation alone does not wake the authentication rendezvous: close
must cancel both, then drain protocol/decoder work on the worker and the observer
before destroying the transport. No thread or UI-thread join is owned here.

Thirteen socket tests cover ownership, byte preservation, descriptor flags and
rejection, explicit write interest, backpressure, absolute deadlines, wake-before-
wait/flooding, scheduler integration, FIN behind unread bytes, independent waits,
concurrent cancellation/destruction, stale controls after actual descriptor reuse,
failed adoption and concurrent independent sessions. The sixteen real VNC/TLS
authentication tests also use this adapter; their host lifecycle remains a fixture.
The independent peer server retains its small test-only polling loop.

Cancellable listen/accept and whole-transport buffer budgets remain open. Endpoint
connection setup is described below. Worker/observer ownership and drain are now
provided by `SessionRuntime` below, including its reusable session mode.
This adapter does not adopt the retained FLTK event loop or supply a Windows
backend. Linux source is included but runtime evidence here is macOS only.

## Established-attempt worker ownership and drain (N1.5/N1.13 portion)

`SessionRuntime` is an application service owning a configurable 1–64 concurrent
attempts (default 16) and one join coordinator. `start()` takes an already connected
`SessionTransport`, explicit security policy and owned worker options; it returns
a `SessionWorker` handle. It takes transport ownership even on rejection. Invalid
arguments reject synchronously; a full/shut-down runtime rejects admission without
publishing a handle. Thread-start/allocation failures propagate to the caller.
There are no detached threads. Admission slots remain occupied through worker join.
Starting, requesting shutdown and querying active count are mutually synchronized.

Before thread publication, construction creates the protocol session, initial
event snapshot, one view mailbox, input mailbox and authentication bridge. Only
the protocol worker subsequently accesses the protocol owner or streams. It
drains input and due timers, processes at most 64 protocol steps per turn, flushes
output and waits against the next timer deadline. Buffered work is handled before
waiting; continuous network input cannot indefinitely starve input/timer dispatch
or cancellation checks. The independent peer observer can cancel a parked prompt
without consuming protocol bytes. Other sessions continue on their own workers.

The handle exposes synchronized event/frame/input mailboxes and the prompt bridge.
Call `wake()` after submitting input, focus or view-only changes. Prompt-ready
notifications run on the requesting worker and must enqueue UI work and return;
they must not retain the worker, block on the UI, or reenter protocol processing.
Low-rate state/frame UI notification dispatch and more than the initial view
attachment remain frontend/lifecycle work. Consumers can retain leases/mailboxes
after handle release, and a drained input mailbox rejects further input.

`closeAndDrain()` and handle destruction set a cancellation flag, cancel the
authentication rendezvous directly and wake readiness without joining. Startup
checks cancellation again after `beginAttempt`, so a close racing that reset cannot
leave the worker waiting on a fresh prompt. The worker attempts held-input release
and TLS close while the socket is writable, drains decoder work, cancels timers,
invalidates views, then attempts a final nonblocking output flush. It shuts down
IO, joins the peer observer and destroys the transport before publishing and
sealing its terminal event. The runtime's
coordinator joins the protocol thread before fulfilling the shared drain future.
Repeated close returns the same future; a queued terminal event alone is not drain
completion. Backpressured final output may be lost; this is not a flush-acknowledgment
or guaranteed remote key-release contract.

The drain result distinguishes cancellation, peer closure, prompt timeout,
authentication rejection, event overflow, transport/protocol/resource/internal failure and an
optional native error code. It never returns server-supplied exception text.
`ProtocolSession::close(failed)` also lets the worker report a readiness failure
detected outside protocol processing. These results describe termination of one
attempt, not connect-operation completion. Worker events now include Authenticating
before credential/trust callbacks and Disconnecting before final disposal. A worker
publishes exactly one terminal Closed or Failed event, including when closed before
startup; queue overflow instead supplies its one terminal Overflow record.
Cancellation and peer closure end Closed; timeout/rejection/other failures end
Failed. `SessionSnapshot::endReason/nativeError` agree with the drain result.
Protocol exception cleanup cannot publish a premature contradictory terminal state.
Closing after finalization starts does not rewrite the chosen termination reason;
terminal event overflow can still replace it with EventOverflow. Terminal snapshots
retain final counters even if a statistics timer never fired.

`SessionRuntime::shutdown()` cancels all admitted attempts outside its mutex and
rejects future admission; `drained()` becomes ready after all jobs join. Keep this
service across windows/attempts. Its destructor joins its coordinator and therefore
belongs on an application service/shutdown thread, never the UI or a session
callback. Session-handle destruction is the nonblocking UI cleanup path. The future
native application must arrange this service lifetime explicitly.

Nineteen fake-transport tests exercise automatic protocol/input/timer driving,
retained frames, held-key release, delayed observer exit, immediate/repeated close,
admission limits, concurrent shutdown/start, service-thread destruction, parked
prompts, timeout/FIN, independent sessions, structured failures and construction
cleanup, command admission/cancellation and terminal-state consistency. Six
additional loopback cases run real VNC/TLS authentication, password rejection and
FIN during a prompt through the production runtime, verifying joined drain completion.

`start()` and runtime-level `connect()` keep their one-attempt behavior. The
`createSession()` mode below supplies a reusable worker and stable mailboxes.
Bounded listen/accept and C/Swift callback ownership are described below. The
remaining command catalog and native OS service-request cancellation remain open.
These macOS worker tests
do not establish native UI, Linux/Windows execution or performance results.

## Asynchronous refresh and encoding commands (N1.5 command portion)

`SessionWorker::requestRefresh(generation)` and
`applyEncodingOptions(generation, validatedSnapshot)` are thread-safe admission
calls. They require a connected, current-generation attempt. `CommandSubmission`
returns Accepted with a nonzero stream-local operation ID, or a typed Closing,
NotConnected, StaleGeneration, QueueFull or EventCapacity rejection with ID zero.
Rejection neither changes protocol state nor owes a completion. Tokens must stay
paired with their worker/event-stream identity; they are not transferable across
new worker handles. Commands automatically wake the executor.

The separate command queue holds 1–256 fixed-size entries, default 32. Storage is
preallocated; an event completion slot is reserved before enqueueing a copied
command. Encoding snapshots include their provenance. A compile-time requirement
keeps copies/assignments nonthrowing, so reservation cannot succeed then lose its
command to an allocation failure. Queue and event budgets are independent. State
publication, command completion and cancellation preserve one ordered event stream;
completion order follows actual execution/cancellation, not necessarily admission.

The worker drains at most commandCapacity commands per loop, outside the command
mutex. It passes the reserved operation to the protocol owner, updates its
thread-safe `encodingOptions()` snapshot before publishing successful completion,
and completes failed execution without losing a reservation. Refresh/encoding
success means scheduling at a safe RFB boundary, not peer acknowledgment or arrival
of a new framebuffer. Initial/default settings are copied into each worker.

`cancelOperation(generation,id)` completes a queued command as Cancelled and removes
it. Dequeue is the start boundary: NotPending includes started/completed/unknown IDs
and cannot undo a committed operation; stale generations reject separately. No
unbounded operation history is retained. Close stops admission and cancels queued
commands directly even if the worker is busy. An already-started command finishes;
worker failure settles remaining queued commands before its terminal event.
Event overflow preserves all reserved completions and terminates with a matching
EventOverflow result. Late close cannot turn an already finalized failure into a
successful cancellation.

Seven new worker cases cover rejection, queue/event bounds, owned/FIFO settings,
policy visibility before completion, cancellation/close, terminal overflow and
concurrent producers/cancellers/consumer. Two protocol tests verify reserved-token
validation and cleanup with host-owned terminal publication. Existing worker cases
now assert authenticating/closing states and matching typed terminal reasons.
Clipboard and other command kinds, listener state and native delivery remain
separate work. Connect/disconnect and desktop layout operations are described below.


## Cancellable endpoint connection setup (N1.6 / N1.5 portion)

`prepareSocketConnection(endpoint, options)` prepares a single-use
`ConnectionAttempt` without DNS or connect work. Pass it to
`SessionRuntime::connect(attempt, security, workerOptions)` to admit the attempt
and receive its mailboxes immediately. The worker publishes Resolving (hostnames),
Connecting, then the existing negotiation/authentication states. Connected means
RFB negotiation succeeded; the drain future still describes attempt termination.
Connection setup shares the runtime's bounded admission and joined cleanup.

The macOS backend uses `DNSServiceGetAddrInfo` with separate enabled-family
queries and `DNSServiceProcessResult` on the session worker. Socket readiness and
a cancellation pipe drive lookup; there is no detached resolver thread or UI
loop dependency. Each query is deallocated on success, failure or cancellation.
The SDK exports this API through libSystem; CMake verifies its availability.
Results are bounded to 16 addresses (8 per family when both are enabled), then
tried sequentially in observed order. This is not a Happy Eyeballs algorithm.

Numeric IPv4/IPv6, numeric or interface-name IPv6 scopes, and Unix sockets use the
shared macOS/Linux POSIX implementation. Linux hostname lookup reports Unsupported
until a cancellable resolver backend exists. Nonempty tunnel routes also report
Unsupported; the adapter never silently bypasses the requested route. Address
family policy is explicitly copied, without reading legacy globals. The RFB/TLS
server name is the canonical host without its IPv6 scope, or the Unix path;
credential-store identity remains a separate service concern.

Lookup and total-connect deadlines default to 10 seconds each; per-address
connect time defaults to 2 seconds and cannot exceed the remaining total budget.
Each configured timeout must be 1–60000 milliseconds. If one DNS family provides
addresses before the other exhausts the lookup budget, those addresses are used.
Readiness waits recompute monotonic deadlines after interruptions. Socket setup
uses nonblocking/CLOEXEC descriptors and closes every failed candidate. A
successful socket transfers into the established transport adapter. The private
POSIX helper shares descriptor/wakeup ownership with that adapter; no descriptor
appears in `ConnectionAttempt` or `SessionTransport`.

The worker retains a stable cancellation control across the setup-to-transport
handoff. Close directly cancels pending setup and wakes connected protocol work;
a socket arriving concurrently with close is disposed before drain completes.
Old setup controls cannot close a transferred or subsequently reused socket.
ResolutionFailure, ConnectionFailure, stage-specific timeout, UnsupportedEndpoint
and InvalidEndpoint results carry a native numeric code without raw endpoint or
exception text. Close during either stage produces the existing Closed/Cancelled
terminal contract. All setup resources are released before joined completion.

Thirteen socket-connector cases exercise local IPv4/IPv6/Unix connections,
localhost system resolution, rejection/validation, cancellation, a real pending
connect deadline, retained controls and an RFB handshake through the production
runtime. Five worker cases cover setup-thread ownership, ordered states, slow
fake resolve/connect, close at handoff, structured failures and mixed shutdown.
These run on macOS 27 arm64, including ASan/UBSan and TSan. Actual stalled DNS
service behavior, Linux execution, minimum macOS support and UI responsiveness
still require separate evidence. Deadlines bound readiness waits; they are not a
hard real-time guarantee for local DNS-service IPC or OS scheduling.


## Reusable logical sessions and reconnect (N1.5 / N1.13 portion)

`SessionRuntime::createSession(security, options)` returns an Idle `SessionWorker`
with one persistent serialized executor. It occupies one runtime slot until
permanent close, including while disconnected; the runtime still bounds all
workers to 1–64 handles. Idle workers sleep on a condition variable. The same
protocol owner, frame publisher/budget, input mailbox, event stream,
authentication bridge and encoding snapshot survive successive attempts.
The handle is the logical session identity; a new attempt does not create a new
window or require replacing those subscriptions.

Call `session->connect(preparedAttempt)` for each connection. Admission takes
ownership even on rejection, returns a nonzero operation ID and the new generation,
and reserves completion capacity before mutating session state. A Busy rejection
means an existing attempt is still active; it does not queue an implicit retry.
Generation starts with the Idle snapshot at 1, and the first admitted connection
uses 2. Every admitted attempt advances it, including resolution failure or
cancellation before the worker starts. IDs and event sequences increase across
attempts; exhaustion rejects rather than wrapping.

The worker publishes Idle for the new generation, then Resolving/Connecting and
normal RFB states. Connect completes Succeeded at RFB Connected, or Failed/Cancelled
after an unsuccessful attempt drains. A successful TCP dial alone is insufficient.
Connect success and cancellation share the command-admission lock, so exactly one
wins. `cancelOperation(generation, connectId)` interrupts setup or authentication
directly while that connect completion is pending. An already completed connect
cannot be cancelled by its old token.

`disconnect(generation)` reserves a completion, rejects stale/inactive/closing
attempts, cancels outstanding protocol commands and interrupts setup/prompts/IO.
It also works immediately after connect admission, before the worker has published
the new generation. Disconnect is committed on admission and cannot be undone by
`cancelOperation`. Its Succeeded completion means the old transport, FIN observer,
protocol connection, decoder work and timers have drained. The serialized session
worker remains alive and sleeps for another connection. Frames/input are cleared;
external leases remain valid and count against the same publication budget.
Encoding policy, focus and view-only policy persist; held input and queued commands
do not. Security policy remains fixed for the lifetime of this session.

Terminal state and retry admission are synchronized: a consumer reacting to Closed
or Failed can immediately submit the next attempt. Those attempt-terminal events
do not seal the stream. Reserved connect/disconnect completions are settled under
the same gate before another generation can advance. Queue overflow seals and
permanently ends the whole logical session, preserving reserved completions.
Session refresh/encoding commands keep their existing queue/dequeue cancellation
rules. A capacity rejection accepts no work; callers can consume events before
retrying, or use permanent close, which needs no completion slot.

Cancellation captures the old attempt's control before leaving the admission lock.
`PromptAuthentication::cancelAttempt(generation)` also checks identity under its
own lock. A delayed disconnect/cancel call cannot cancel a new generation's socket
or prompt. Scheduler wakes use a stable router that only wakes the current attempt;
control calls and destruction occur outside router/admission locks. Requests keep
monotonic IDs across reconnect and require both ID and generation in replies.

`closeAndDrain()`, handle destruction and runtime shutdown permanently stop future
admission. The shared drain future is fulfilled only after the persistent worker
has destroyed its protocol owner and joined, including its last FIN observer.
Between attempts that future stays pending. It reports the final attempt's result,
or Cancelled if no attempt ran. Runtime destruction remains a service-thread task;
UI code must not wait synchronously for these futures.

Coverage includes repeated reconnect with the same executor/mailboxes, retained
old frames and shared budget pressure, encoding/view-only persistence, stale input,
commands/replies/cancellations, immediate disconnect, failed setup then retry,
concurrent connect admission, delayed observer drain, terminal-triggered retry,
queue overflow and mixed idle/active shutdown. An independent real TCP peer
verifies VNC passwords on two successive sockets in both plaintext VNC and
X509Vnc/TLS 1.2 sessions. This does not implement automatic retry/backoff, reconnect
security-option changes, credential caching, listeners, native delivery or the C ABI.


## Remote desktop layout commands and replies (N1.5 / N1.2 portion)

`RemoteDesktopLayout` is an immutable owned value in remote pixels, separate from
local display/window geometry. It validates a 1–65535 pixel framebuffer with
1–255 enclosed, nonempty screens and unique 32-bit IDs. Screen flags and IDs are
preserved; gaps and overlaps remain legal as in the existing RFB `ScreenSet`.
`SessionSnapshot::layout` retains the server's actual validated topology, including
same-dimension screen changes. The snapshot also reports `supportsDesktopResize`
and `resizePending`. Old snapshots/layout values remain valid after later replies
or session destruction. Each retained layout holds at most 255 screen records;
metadata memory is separate from the pixel-publication budget and bounded by the
number of queued/externally retained snapshots.

`SessionWorker::requestDesktopLayout(generation, layout, origin)` copies the value
before returning and reserves a completion before queueing it. `origin` is an
opaque 64-bit host correlation value, echoed by the completion; it is never sent
to the server. Admission rejects stale/disconnected/closing attempts, view-only,
unsupported servers, an already queued/on-wire resize, or a requested framebuffer
that exceeds the session/int-sized storage budget. It shares the bounded command
queue, event completion reservations and dequeue/cancellation boundary. Copies
queued for execution cannot retain a caller-supplied custom shared-pointer deleter.
The core rechecks connection, capability, view-only, geometry budget and the
reserved operation before writing RFB SetDesktopSize.

Only one resize is queued or on the wire per session. Unlike refresh/encoding
commands, success means a successful ExtendedDesktopSize reply for this client,
not simply writing the request. The actual layout snapshot is published before
completion. A server/other-client layout change updates the snapshot without
settling this client's operation. Rejections preserve the existing actual layout
and complete Failed with `OperationFailure::ServerRejected` and the unmodified
native result code, including unknown codes. The session remains usable.

`desktopResizeTimeout` defaults to 10 seconds and accepts 1–60000 ms in
`SessionTiming`/`SessionWorkerOptions`. It occupies one additional bounded timer
slot. Timeout completes Failed with `OperationFailure::TimedOut`, while leaving
`resizePending` true: the RFB reply carries no request ID, so sending another
request at that point could misattribute the late reply. A later client-reason
reply clears the wire slot and updates the actual layout without completing the
old operation twice. Reconnect also clears the slot. A server that never replies
therefore requires reconnect before another resize. Cancellation can remove a
queued resize, but cannot retract an already-sent one; it returns NotPending
once execution starts. Disconnect/close settles any pending completion, cancels
the deadline, clears capability/layout/pending state and drains as usual.

Eleven layout/value/protocol tests cover coordinate overflow, duplicate IDs,
maximum counts/flags, exact request bytes, retained topology, same-size changes,
server rejection, other-client changes, timeout/late replies, capability/view-only/
resource/operation validation, reserved-capacity rejection, write failure and
close/reconnect. Three worker tests add asynchronous admission, owned command
execution, queue cancellation, view-only changes before dequeue, runtime timeout,
late-reply recovery and close completion. These are protocol/core tests; native
window resize policy, coalescing/rate limiting, display selection and presentation
fidelity remain N3/N5 work. The retained FLTK frontend keeps its existing resize
policy and remains covered by the full build/tests.


## Session clipboard channel (N1.5 / N1.9 portion)

`SessionWorker::clipboard()` is a retainable, thread-safe channel with one
coalesced receive update and immutable `ClipboardText` leases. `ClipboardPolicy`
independently enables send and receive; both also require a connected, focused,
non-view-only session. `setClipboardPolicy` changes policy immediately and wakes
protocol cleanup. It is a mailbox policy setter, without an operation completion.
The policy, mailbox and byte budget survive reconnect; cached local offers and
pending receive updates do not. External text leases remain valid after close.

`offerClipboard(generation, text, originLease, changeId)` validates/copies UTF-8,
normalizes CR/CRLF to LF, rejects embedded NUL, reserves completion capacity and
queues an owned offer. One offer or withdrawal can be queued at a time. The
completion echoes `changeId` in its `origin` field; it means the protocol accepted
an announcement/send, not that the remote OS pasteboard changed. Queue cancellation
and permanent close settle accepted commands exactly once. `clearClipboard`
withdraws local availability, including after focus or send permission is lost.
The existing RFB implementation negotiates extended UTF-8 text with CRLF/NUL wire
representation and retains legacy Latin-1 cut-text fallback. No file/image formats
are added. Eligible remote announcements automatically request text as in FLTK.

`ClipboardUpdate` reports Offered, Text, Unavailable, Rejected or Invalidated,
with monotonic sequence and a generation/focus/policy route. Taking an update
transfers the channel's lease reference to the consumer. Focus/view-only changes
increment an input routing revision, so a focus loss and regain still invalidates
previously queued offers and delayed replies. Policy changes likewise invalidate
old routing tokens. Execution rechecks eligibility; a no-longer-eligible queued
command completes Failed without sending. Cached local offers are revoked on the
worker's next input/policy wake or before serving a remote request.

The native adapter must route OS clipboard observation to the active session,
check `channel->check(update.route, false)` immediately before a deferred OS write,
and serialize that write with focus changes on its UI executor. Preserve the remote
lease as the origin of the corresponding native pasteboard change; passing it to
`offerClipboard` returns Echo, including after reconnect or across sessions. An
explicit local user copy can instead create a fresh local-origin offer. Numeric
routes alone do not establish cross-session identity: core local sends also require
a lease owned by that channel. The C/Swift boundary now adds originating session
identity to receive-route tokens, retained text handles, independent direction
policy, async offer/clear, validation and callback delivery. The macOS MainActor
coordinator now arbitrates eligible session focus and uses an injected NSPasteboard
adapter. A custom remote-origin marker prevents automatic re-offers after focus
changes or reconnects; a new ordinary local copy creates a local offer. Pending
host work is coalesced and invalidated on each routing transition. RFB replies have
no clipboard transaction ID; the channel tracks the
latest request's routing stamp, not exact matching of overlapping remote offers.

`SessionBufferLimits` defaults to 256 KiB per text and 1 MiB total retained text.
Construction accepts text limits 1 byte–16 MiB and total limits from the text limit
through 64 MiB. The budget charges normalized UTF-8 payload bytes held by queued
commands, cached local offers, the receive mailbox and all external leases, even
across reconnect. Retained leases can backpressure new text without disconnecting
the session. Metadata, string capacity, protocol conversion/decompression buffers
and caller input strings are separate; this is not an aggregate process-memory
limit. `ClientMessageLimits::maxCutText` still bounds incoming wire/formats in the
RFB reader independently. Reader format buffers now use scoped ownership on both
malformed later formats and throwing delivery callbacks.

Tests cover legacy/extended wire text, newline/UTF-8 validation, retained budgets,
coalescing, independent policy, focus round trips, stale/foreign leases, echo tags,
reconnect and close, queue/completion ordering and concurrent mailbox use. The
protocol/service boundary and macOS adapter are implemented. Separate native tests
exercise disposable named pasteboards, two-session routing, failure injection and
cleanup under normal/ASan/TSan builds. Visible clipboard controls and actual app
activation checks remain N3.15 work; the latest UI attempt was blocked by a locked Mac.


## Reverse/listen lifecycle (N1.5 / N1.6 / N1.13 portion)

`ListenerRuntime` is an application-owned service separate from `SessionRuntime`.
It admits 1–16 listener workers (default capacity 4) and owns one join coordinator.
`listen(preparedSource, options)` returns a handle immediately; binding and accepting
run on its worker. Each listener is single-use, with Starting → Listening →
Stopping → Closed/Failed state and monotonically ordered events. A restart creates
a new handle. `events()->snapshot()` provides current state, while the single
retained event consumer starts with the initial Starting snapshot. Events and
bound-address snapshots remain safe after the listener handle is released.

`prepareSocketListener` supplies the macOS/Linux TCP backend. Defaults preserve
port 5500 and IPv4/IPv6 wildcard listening. A numeric bind address selects one
family; zero port chooses one ephemeral port shared across enabled families.
IPv6 sockets use V6ONLY. Unavailable families (`EAFNOSUPPORT`/`EADDRNOTAVAIL`) are
skipped as in the legacy viewer; at least one family must bind. Other errors roll
back all sockets and report Bind plus the native error. Returned addresses show
what actually bound. There is no synchronous DNS lookup, native descriptor in the
portable contract, or GUI readiness integration. Listening and accepted sockets
are nonblocking/close-on-exec, readiness uses cancellable poll, and retained wake
controls become harmless after destruction. The backend accepts numeric IPv4 and
unscoped numeric IPv6 bind addresses; hostname/Unix/scoped-bind support is absent.

Incoming events contain immutable numeric peer address/port and an ID scoped to
the listener. The worker consumes no RFB bytes before a host decision. Pending
accepted sockets are bounded to 1–64 (default 8), independently of the kernel
backlog (1–64, default 16). At capacity the worker pauses acceptance, then resumes
on a decision or expiry; it does not allocate an unbounded list of peers. Pending
peers expire after a monotonic 1–60000ms timeout (default 30s). Expiry closes the
transport and publishes Expired. Pending FIN is handled by expiry or by the
session after acceptance; there is no observer thread per unclaimed socket.

`takePeer(id)` atomically transfers a transport once, and `reject(id)` disposes it.
Stale/duplicate/expired/closing IDs cannot consume another peer. The convenience
`accept(id, sessionRuntime, explicitSecurity, options)` transfers to the existing
serialized protocol/authentication worker; its returned session follows normal
Connected/failure events. It returns null on peer admission rejection. Session
construction/runtime admission exceptions consume and close that peer rather than
silently restoring it; the listener remains usable. Numeric IPv6 scope information
is preserved in the peer endpoint but omitted from the certificate hostname.
Accepted sessions have an independent lifetime and survive listener shutdown.

Event capacity is 4–4096 (default 32), with two additional reserved terminal slots.
Overflow fails the listener, preserves queued events and Stopping/Failed delivery,
and closes all unclaimed peers. Decisions reserve event capacity before ownership
transfer. Event sequence and peer IDs never wrap. Event output replacement,
transport disposal and injected control calls happen outside mailbox/runtime
locks. No UI callback is installed by the listener service.

`closeAndDrain` and handle destruction request cancellation directly, including
during bind/start or a readiness wait. Disposal occurs on the worker; the future
is fulfilled only after its sockets/pending transports are destroyed and the join
coordinator has joined it. Runtime shutdown cancels all listeners without blocking;
its drain future covers admitted workers. Destroy the runtime on an application
service/shutdown thread, not the UI thread, and finish concurrent API calls first.
Closing a listener does not shut down the separate session runtime.

Fake-source tests exercise bounded queues, event overflow, ordered state,
nonblocking handle release, delayed disposal, concurrent decisions and timeouts.
Real IPv4/IPv6 tests exercise acceptance, shared ephemeral port, partial-bind
rollback, cancellation, transport transfer, session admission failure and a full
reverse RFB/None handshake. Native listen UI/CLI wiring, app quit coordination,
incoming-peer presentation, reverse TLS UI and minimum-OS/Linux
execution remain later integration work. FLTK's listen implementation is retained.


## C ABI foundation (N2 portion)

The static `tidyvnc_viewer_c` target exposes `viewer/bridge/tidyvnc.h` and its
`TidyVNC` module map. It supplies version/size-tagged C values, capability checks,
checked numeric handles, explicit ownership, structured errors, reusable session
lifecycle, polling event/view/prompt consumers, input, and credential/trust replies.
Runtime cleanup belongs to a joined application service thread; final handle
release initiates shutdown without joining on the caller. Retained images and
prompt metadata survive their session. Mutable credential submission buffers are
wiped on return within the documented bounds. See [bridge/README.md](bridge/README.md)
for exact contracts, limits, supported surface and remaining native work.

A pure C99 consumer exercises validation and injected allocation failures. Real
loopback ABI tests cover VNC authentication, input/release barriers, retained
frames, reconnect, simultaneous sessions, cancellation and capacity. The clean
headless audit now checks both C and C++ consumers and the ABI library's dependency
graph. Retained C callback subscriptions now coalesce event/view/prompt/drain
readiness on a separate dispatcher, with unsubscribe, context drain and generation
validation. Queued/running cancellation and callback-driven VNC/frame/drain tests
cover the boundary. The opt-in [Swift/MainActor layer](../platform/macos/README.md)
now owns this boundary, exposes async completions and joins cleanup through
nonblocking awaits. Real native-model loopback tests exercise queued delivery,
password prompts, wire input and retained frames. An opt-in Xcode SwiftUI app now
uses an AppKit desktop view with retained CG images, shared transform/key mapping,
native authentication sheets and async window/quit cleanup. This controlled
vertical slice preserves the shipping FLTK frontend; platform services and full
native parity remain open. See the macOS README for app build and test commands.


### Shared middle-button policy

`MiddleButtonEmulator` contains the retained 11-state left/right chord policy.
It has no callbacks, timers, global settings or allocation: each step returns at
most three pointer events and whether the host should replace its one-shot timer.
The retained `EmulateMB` adapter continues to own its legacy timer and parameter;
the native protocol session uses a scoped 50 ms `SessionScheduler` deadline.
Both preserve delayed press origins, late-chord behavior, release/repress states
and physical middle/other button masks. Original upstream attribution is retained.

`InputQueue::setPolicy` changes view-only and emulation atomically under the
mailbox lock. Emulation changes release held state, clear queued input and bump
the routing revision. Dequeued commands carry that revision and policy. The
protocol executor resets emulation at release barriers/revision changes; a timed
press checks generation, routing revision, connection, focus and view-only before
writing. Teardown cancels the timer and resets the state machine. The bounded
protocol scheduler now has five slots: statistics, publication retry, desktop
resize, middle-button emulation and pointer-event timing. No delayed work survives reconnection.

The C ABI advertises `TIDYVNC_FEATURE_INPUT_POLICY` and provides the boolean-only
`tidyvnc_session_input_policy` setter. Invalid values fail before mutation; the
existing view-only setter preserves emulation. Policy defaults off and persists
within a session across reconnect. Native app/default/profile persistence is
separate work. Full retained/headless tests and deterministic fake-clock protocol
fixtures cover the shared policy and session-local cancellation.


### Shared shortcut classification

`ShortcutState` contains the retained shortcut state machine, with Control/Shift/
Alt/Super modifier bits and normal/unarm/shortcut/ignore decisions. A fixed array
holds at most 1024 distinct physical IDs; repeats reuse entries. Invalid masks
and capacity failures leave state unchanged. Reset clears held state while keeping
the selected modifier mask. The current arm64 object is 12,304 bytes and has no
per-event allocation, callbacks or timers. The original upstream attribution is
retained. `ShortcutHandler` supplies only retained-frontend names/localized prefixes;
its legacy static prefix buffer is not part of the shared core or native ABI.

`TIDYVNC_FEATURE_SHORTCUTS` adds typed create/modifiers/key/reset C functions. Each
handle serializes mutable operations with a mutex, independently of all sessions,
and uses the standard retain/release registry. Invalid inputs and output pointers
are checked before mutation; failed calls leave output action/handle values alone.
Hosts own input lifecycle, wire key release, command dispatch and Space bypass.
The native wrapper/router exercises those decisions but is not yet attached to
AppKit event interception. Pure C, capacity/allocation/concurrency tests and the
retained classifier tests cover this service. A deterministic differential run
matched 1.6 million events against the original checked-in classifier.


`InputQueue::releaseAll(generation)` and `tidyvnc_session_release_input` provide a
generation-checked release barrier without changing focus or view-only/emulation
policy. They discard queued commands, advance the routing revision and release
held input on the executor. Delayed middle-button presses cannot cross the barrier.
The additive `TIDYVNC_FEATURE_INPUT_RELEASE` bit advertises the operation; the
native shortcut and synthetic-command adapters require it. With the connection
information query and owned endpoint identity API below, the ABI export count is 63.

## Negotiated connection information

`SessionSnapshot::information` retains an immutable, fixed-size observation of
the negotiated protocol/security, current wire pixel format, requested encoding,
last received data encoding and existing line-speed estimate. The desktop name is
bounded to 1024 bytes with explicit truncation. CopyRect does not replace the last
data encoding. Attempt replacement resets metadata; retained observations survive
independently. Existing statistics scheduling throttles publication, and live
encoding changes schedule an observation even when no new frame arrives.

`tidyvnc_session_information` requires `TIDYVNC_FEATURE_CONNECTION_INFO` and the
current generation. It returns copied text and the matching snapshot/counters
without a new handle or borrowed span. Wrong type/generation, invalid output
header and disconnected state preserve output memory. `credentials_secure` is
the existing credential-exchange policy result, not proof that all traffic is
encrypted or that remote identity was verified. No endpoint, credential, key,
certificate or filesystem path is part of this record. Older C structs and their
layouts remain unchanged.

### Owned endpoint identity for native credentials

`tidyvnc_endpoint_create` snapshots the shared parser's canonical destination and
an opaque non-secret route in a typed immutable handle. `tidyvnc_endpoint_get`
returns borrowed field spans valid while the caller retains that handle. Inputs
are UTF-8 without NUL and bounded to 4096 bytes each. No DNS, filesystem or network
IO occurs. DNS ASCII case/numeric IP spelling normalize; aliases, trailing dots,
scopes, paths and routes remain distinct. The normal registry reference limits,
wrong-kind/stale rejection, concurrency and no-output-on-failure rules apply.
This is destination identity, not server trust or permission to reuse credentials.

## Connection-file syntax

`ConnectionDocument` is an owned, bounded portable codec for the two historical
version-1 headers. It preserves ordered entries and decodes values on demand so
unknown fields retain their compatibility behavior. It has no IO, parameter
registry or mutable global state. Serialization uses an explicit non-secret
export catalog, emits the current header and validates complete escaped lines
before a destination is opened. Retained FLTK load/save/import now uses it.
Semantic option validation, migration policy and file permissions remain consumer
responsibilities. Native bridge/panels are still pending; see
[the document contract](../plans/native-ui/DOCUMENTS.md).

Connection documents are also available through CONNECTION_DOCUMENT in the C
ABI: parse returns an immutable retained handle; metadata/entry calls copy output;
entry decoding is opt-in. Serialization takes explicit decoded assignments, queries
or fills a bounded buffer and writes nothing on failure. The C interface preserves
opaque file bytes; the Swift owner rejects invalid UTF-8. Four additive exports
bring the ABI to 86; no platform type or file IO enters this document boundary.


### Invocation syntax

`InvocationSyntax` and its C ABI parse bounded argv snapshots independently of the
mutable parameter registry. The retained Configuration parser now uses the same
lexical helper. This preserves names/aliases, exact literal values, boolean
lookahead and the ordered source positions needed for transactional validation.
Encoding catalog metadata comes from the existing schema; platform-specific options
have explicit availability. Help/version retain preceding assignments so later
semantic validation cannot be bypassed by a terminal flag.

The INVOCATION_SYNTAX exports and additive INVOCATION_VALUES validation operation
bring the C boundary to **92 exports**.
Metadata/catalog names are copied; value/operand spans borrow an immutable owned
handle until release. Swift copies these spans into Sendable values. Parsing neither
validates settings nor starts IO/session/listener/tunnel work. A separate immutable
canonical copy validates each occurrence through shared field rules. Native injected
requests now resolve ordinary settings after defaults/profile and before explicit
files, preserving deprecated migration state and command-line provenance. The
remaining option adapters stay open. See [CLI.md](../plans/native-ui/CLI.md).


For explicit-file startup, the native host now defers CLI numeric monitor mapping
until file fields settle. A file can replace an obsolete CLI selection; surviving
CLI numbers enter the native display chooser and review with original provenance.
Pending display values cannot reach a session. File review captures actual resolved
assignments and revalidates topology before admission. The app executable now
strictly decodes raw argv and handles help/version/errors before app/store startup.
Its first ordinary window consumes one process-local launch request; direct hosts
connect when ready, while files require review and manual Connect. Later windows
and zero-window reopening do not replay launch options. No-file monitor selections
have their own connected-display recovery flow. Parsing/resolution do not write
settings; successful connections use ordinary recent history. Credential inputs,
remaining option adapters, listen/tunnel and installed launch acceptance stay open.


Native outgoing connections now honor CLI `UseIPv4`/`UseIPv6` through an immutable
session policy passed to the existing C connector on every attempt. Numeric
addresses and hostname lookup respect the selected families; reconnect retains
policy and unrelated sessions remain independent. Unix sockets work with both IP
families disabled. These fields are CLI-only, preserved through file review and
explicitly disclosed as omitted by Save As. Native stores and the 92-export C ABI
are unchanged; native listen and tunnel adapters remain open.


Pointer motion can now be throttled on the protocol worker after middle-button
emulation. SessionTiming/SessionWorkerOptions capture an interval; zero keeps the
existing low-level behavior. Native sessions use the new INPUT_TIMING C creation
path and the shared retained default of 17 ms, overridden by PointerEventInterval.
One pending value and one scheduler slot bound the work. Button/wheel transitions
send immediately, motions keep their first deadline, and keys flush pending motion
to preserve input ordering. Generation/routing checks and release/terminal cleanup
prevent stale motion after focus changes, overflow, disconnect or close. The worker
scheduler reserves five slots for statistics, publication, desktop resize, middle
button and pointer timing. File exports disclose unsupported pointer timing. The
additive C surface now has 94 exports; native storage schemas do not change.

Native session creation can now supply immutable incoming message limits through
MESSAGE_LIMITS. MaxCutText uses the shared reader default (256 KiB) and retained
0..INT_MAX bounds. Each attempt receives the session's copied policy; clipboard
UTF-8 retention budgets remain independent of wire/decompression limits. Old C
creation APIs retain their original default message limits.
