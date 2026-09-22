# Session isolation audit (N0.3)

Source baseline: `623308a7`, 2026-09-18. This is an extraction map, not a
thread-safety certification. The existing macOS frontend normally isolates new
connections with `fork`/`exec` (`new_connection_cb`); native session windows will
remove that protection. Do not enable multiple engine workers merely because
each has a different `CConnection`.

## Mutable configuration and credentials

Paths below are relative to the repository root. A source symbol is supplied
where line numbers would become stale during extraction.

| Source / state | Current use and hazard | Required ownership / compatibility |
| --- | --- | --- |
| `common/core/Configuration.{h,cxx}`: `global_`, registered parameters, immutable flags | Constructors register in a shared mutable list; parsing mutates values and precedence flags | Native parsing produces value snapshots without registering per-session globals. Retain the existing registry for FLTK/server CLI callers |
| `vncviewer/parameters.cxx`: all viewer parameters, `parameterArray`, `ParameterSnapshot` | UI, document load and import change live globals; rollback snapshots are transactional only on the existing single UI thread | Typed draft and immutable connection snapshot; explicit app/profile/CLI layers; shared codecs must not temporarily mutate the registry |
| `common/rfb/SecurityClient.{h,cxx}`: `secTypes` | `SecurityClient()` copies the list into instance `enabledSecTypes`, but concurrent edits/construction still race | Inject an already validated policy at construction; preserve a legacy constructor for FLTK |
| `common/rfb/Security.cxx`: `GnuTLSPriority`, `ToString` static output | TLS reads global handshake policy; string conversions overwrite the same buffer | Instance TLS policy; owned result string. Keep server policy independent |
| `common/rfb/CSecurityTLS.cxx`: `X509CA`, `X509CRL`, `configdirfn` buffer | Global paths; helpers reuse static storage | Copy immutable paths into the session security policy before handshake; explicit trust/file service |
| `common/rfb/CConnection.cxx`: `noJpeg` | Shared encoding policy read during update negotiation | Instance encoding options; retain legacy default as an adapter input |
| `common/rfb/CMsgReader.cxx`: `maxCutText` | Global incoming clipboard cap, default 262144 bytes, range 0..INT_MAX | Reader/session resource limits; server reader policy remains separate |
| `common/network/TcpSocket.cxx`: `UseIPv4`, `UseIPv6` | Global address-family policy, both default true | Inject transport policy for connections/listeners; keep legacy constructors |
| `vncviewer/CConn.cxx`: `savedUsername`, `savedPassword` | Static reconnect secret cache, cleared by connection error; one session could clear or reuse another's secret | Session-owned retention with explicit use-once/session/Keychain choice; no shared static cache |
| `CConn::getUserPasswd` | Reads process environment, static cache, password file, then blocking dialog; password file applies only to password-only auth | Capture explicit invocation inputs once, scope to the intended session, preserve precedence and bounded lifetimes; never reserialize secrets into launch arguments |
| `CConn::initDone` and `DesktopWindow` | Protocol compatibility/fullscreen also write global options | Negotiated state is session state, not a mutation of app defaults |

Credential precedence in the current implementation is environment credentials
(both variables for username/password auth, password alone for VNC auth), then
nonempty retained credentials, then the password file for password-only auth,
then the dialog. This is behavior to explicitly translate, not a reason to let
every future native window read the process environment.

## Crypto and decoder state

| Source / state | Finding | Required action |
| --- | --- | --- |
| `common/rfb/d3des.c`: `KnL[32]` | One mutable DES schedule for client VNC challenge, server response verification and password-file obfuscation. Interleaving key setup and block transforms corrupts results even with different connection objects | Replace with caller-owned context; update **all** four uses in `CSecurityVncAuth`, `SSecurityVncAuth`, `obfuscate` and `deobfuscate`. Verify known outputs, interleaved contexts and concurrent helpers; preserve VNC's reversed key-bit convention |
| `common/rfb/TightDecoder.cxx`: templated `FilterGradient` | `prevRow`/`thisRow` are static scratch arrays shared by calls of the same template specialization. Decoder instances and their queue mutexes do not protect each other | Invocation-owned scratch; test simultaneous gradient rectangles from distinct sessions and decoder workers before claiming decoder isolation |
| `common/rfb/CSecurityTLS.cxx`: constructor/destructor | Calls `gnutls_global_init` / `gnutls_global_deinit` per security object; TLS sessions/credentials themselves are members | Audit selected GnuTLS lifetime guarantees and use a host runtime owner as needed; never tear down shared crypto while another session is using it. No TLS backend replacement |
| `common/rdr/RandomStream.cxx`: `seed`, `rand`/`srand` fallback | System random handles are instance-owned; missing-system-source path mutates process PRNG state | Native secure-random contract must fail closed on unavailable entropy. Preserve/review legacy consumers explicitly rather than using a lock to endorse weak fallback entropy |
| `common/rfb/CSecurity{DH,MSLogonII,RSAAES}.cxx` | Key/session state is object/local storage; RSA callback constructs `RandomStream` | Audit cancellation and secret clearing; inherits random-source and prompt constraints above |
| `common/rfb/PixelFormat.cxx`: conversion lookup tables / `_init` | Populated by static initialization, then read | Retain read-only tables; no need to duplicate per session |
| DES permutation/S-box tables, encoding constants, pixel format constants | Read-only in use | Make const where practical; do not confuse constants with mutable session state |
| `common/rfb/DecodeManager.{h,cxx}` | Queue, decoder array, threads and exception state are per manager; workers hold framebuffer/server pointers; destructor joins workers | Preserve queue synchronization; drain before framebuffer/session destruction. Native main thread must not perform that join |

## Scheduling, services and application state

| Source / state | Finding | Required ownership / compatibility |
| --- | --- | --- |
| `common/core/Timer.cxx`: `Timer::pending` | Shared list with static dispatch. Input emulation and gesture helpers own timers but not the queue | Inject a monotonic scheduler with cancellation tokens; legacy default queue stays available to server/FLTK loops. Cancellation may not depend on a parked engine worker |
| `vncviewer/CConn.cxx`: `socketEvent` static `recursing`, FLTK fd/timeouts | Reentrancy suppression crosses instances; dispatch is attached to UI loop | Instance executor/reactor registration; teardown deregisters before resource release |
| `vncviewer/{DesktopSession,DesktopWindow,Viewport}.cxx` | FLTK timers/callbacks, widget pointers, desktop instance registry, clipboard routing and input state | Session-owned input and publication; generation-tagged view subscriptions. Window registry belongs to the main-thread host |
| `vncviewer/OptionsDialog.{h,cxx}` | Singleton dialog and callback map keyed by function pointer, not session identity | Per-session drafts and subscriptions. Multiple instances of the same callback must not overwrite each other |
| `vncviewer/ShortcutHandler.cxx`: `modifierPrefix` static buffer | Returned text overwritten on next call | Owned text in presentation layer; per-session shortcut/input state |
| `vncviewer/vncviewer.cxx` | Global exit/error/server-name state; process signal handlers; About buffer; New Connection forks; tunnel mutates `G/H/R/L` environment then calls `system` | App owns process lifecycle, sessions own errors. Inject tunnel launch with argument vectors and child-specific environment; separately review custom `VNC_VIA_CMD` compatibility |
| `common/network/Socket.cxx`: `socketsInitialised` | Unsynchronized lazy setup, including Winsock on Windows | Runtime setup once before workers (or synchronized once); preserve server startup behavior |
| `common/network/TcpSocket.cxx`: peer address/endpoint buffers | Static formatting buffers in methods returning borrowed strings | Return/copy owned endpoint values without concurrent access to shared buffers |
| `common/core/xdgdirs.cxx`: directory buffers | Static scratch storage reused by calls; environment is process state | Resolve/copy compatibility paths before workers; native stores inject paths and do not infer missing data from errors |
| `common/core/{LogWriter,Logger,Logger_file,Logger_stdio}.{h,cxx}` | Global writer/logger registration and mutable levels/destinations remain startup-only; file/stdio writes and file lifecycle share a recursive sink lock; timestamps use caller-owned storage | Initialize/freeze registry, writer levels/destinations and formatting before workers; join writers before logger destruction. Sink locking does not make global configuration concurrent-safe. Session-aware redacted diagnostics must not use global log mutation |
| `common/core/i18n.cxx` | Lazy initialized flag, locale buffers, `setlocale`/gettext setup | Initialize on host thread before workers; no per-session locale mutation. Native UI localizes structured errors; retained consumers keep gettext |

`CConnection::setFramebuffer` deletes the previous pixel buffer. This is a
lifetime boundary even though it is not a global: retained native views cannot
borrow that storage across resize. Introduce immutable frame leases and size
generations, then test resize/disconnect with old frames still held.

## Extraction order and review gates

1. Remove independent mutable crypto/decoder scratch hazards with regression
   tests. These changes do not depend on the eventual native window strategy.
2. Add typed options and instance security/transport/reader policy seams with
   legacy default adapters. Keep UI/document parsing out of global mutation.
3. Introduce executor/scheduler/runtime ownership; inject service contracts and
   move prompt/credential state into sessions.
4. Prove cancellation and real VNC/TLS authentication, then two simultaneous
   sessions (one parked prompt, one receiving updates). Do not hold a shared
   crypto, framebuffer or store lock while waiting on a prompt.
5. Add frame leases and drain tests before native rendering/screens.

Server-only parameters (`SecurityServer`, `ServerCore`, server certificate/key
paths and password getters) are not native viewer settings. Preserve their
behavior and build them whenever a shared helper changes. Existing global
entry points are compatibility obligations where still used; unused private
helpers need not be perpetuated as a binary plugin API.

N0.3 is complete as a source audit. N1.4 remains open until configuration,
credentials and scheduling have actually been scoped and concurrency tested.
N0 inventory, deployment, native-window and service decisions remain separate
gates; this audit does not authorize UI cutover.

Follow-up: the DES schedule row has been addressed by caller-owned contexts
and seven regression tests. Tight gradient scratch is now invocation-owned;
the new concurrent decoder test reproduced the old corruption and passes
after the fix (see the N1.4 prerequisite evidence in [TODO.md](TODO.md)). The
table above preserves the inspected baseline; other rows are still extraction
work, not resolved issues.

Authentication-method selection now also has an explicit value-list constructor
and a `CConnection` policy-copy constructor. Native callers can avoid reading
the legacy `SecurityTypes` parameter; existing callers still use their current
defaults. Compiled capabilities are available independently of global settings.
The subsequent TLS-policy change adds value-owned priority/CA/CRL fields and
passes them through every TLS factory branch. Legacy defaults are captured at
policy construction on the host thread, not read later during handshake.
Explicit policies never inherit legacy TLS values. Concurrent in-memory X509
handshakes verify independent CA/revocation policy and encrypted data exchange;
see [TODO.md](TODO.md). Global crypto initialization, legacy static path helpers,
trust-store callbacks and prompt cancellation remain open.

JPEG negotiation now uses an instance flag for both standalone JPEG and Tight
quality hints. The default constructor captures legacy `NoJPEG`; explicit-policy
construction uses a documented JPEG-enabled default, with `setJpegAllowed` for
session settings. The FLTK Options callback translates the legacy parameter into
that setter, including scheduling renegotiation when only JPEG changes. Encoding
updates no longer read the global parameter. Wire-message tests cover legacy
snapshots, explicit defaults, live toggles and concurrent independent sessions.
This does not isolate the remaining viewer parameters or validate native UI.

Incoming clipboard limits are now value-owned by `CConnection` and `CMsgReader`.
The legacy constructor captures `MaxCutText` before the handshake; explicit
construction takes `ClientMessageLimits` or uses its fixed defaults without
reading the global parameter. Plain text, extended wire payloads and each
expanded format use the snapshot. Tests exercise real RFB 3.8/None negotiation,
concurrent distinct limits and alignment after discarded updates. This preserves
the existing per-format semantics, not an aggregate transport/decompression
budget; reader buffering and clipboard service ownership remain separate work.

Security-policy serialization now returns an owned `std::string` from the const
`Security::ToString` method. Both configuration callers consume it synchronously.
This removes shared output storage and the fixed-buffer overflow for long type
lists; independent or shared read-only policies can be formatted concurrently.
Mutation of the same policy still requires its owning executor. The Windows
registry caller was updated and inspected, but not built on the macOS host.

Reconnect credentials now live in a noncopyable `ClientCredentialCache` owned
by the FLTK host's logical-session/reconnect loop. Each `CConn` attempt receives
a reference; authentication errors clear that cache alone, and returning from
the loop destroys it. Owned bytes are overwritten before replacement, clear or
destruction. Password-only replacement drops any old username; opting out of
retention clears prior values. Legacy nonempty reuse rules and environment →
cache → password-file → dialog precedence are preserved. Environment/password
file inputs still require explicit native invocation snapshots; prompt/service
ownership and clearing protocol/dialog copies are not solved by this cache.
No interactive retry or full native authentication lifecycle is claimed.

## Build-boundary extraction (N1.1)

Shared rendering sources have moved from `vncviewer` to `viewer/core` and are
compiled once into `tidyvnc_viewer_core`. Display-metrics values/validation live
in `tidyvnc_viewer_platform`; obtaining them from FLTK/Cocoa remains in the
frontend adapter. Core links down to these contracts and the existing protocol
libraries, never back to the frontend. The clean headless driver checks that
generated dependency graph and public includes, then builds/runs a separate
consumer and the available unit suites. See [viewer/README.md](../../viewer/README.md)
and the N1.1 evidence in TODO. This boundary does not resolve the outstanding
shared-state and session-lifecycle issues above.

## Retained publication boundary (N1.8)

`viewer/core/FramePublisher` now implements independently retained immutable
pixel leases with explicit layout, session/size generations, bounded payload
storage and per-subscriber damage coalescing. Old source/framebuffer destruction
cannot invalidate published bytes. Queued stale-generation data is cleared on
reset, while already-held leases remain valid and tagged. Tests include an RFB
pixel buffer that is destroyed before its published image is read, plus
concurrent consumption during reset. The current FLTK `DesktopSession` still
uses its existing buffer path. The portable `ProtocolSession` now feeds this
boundary (N1.7); native-renderer integration remains open. See N1.8 evidence in TODO.

## Window-independent session owner (N1.7)

`viewer/core/ProtocolSession` now owns RFB attempts and an ordinary
`ManagedPixelBuffer`, with no dependency on FLTK windows or platform pixel
surfaces. It drives retained frame/cursor publication only after decoder work
is joined, preserves subscribers across new attempt generations, and destroys
protocol-owned buffers safely while views retain immutable leases. Source frame
allocation is bounded independently of publication copies and checked against
legacy RFB signed-size arithmetic. Wire fixtures exercise decode, resize,
backpressure, detach, reconnect and failure. This completes the portable
framebuffer/view ownership boundary, not the remaining executor, service,
full lifecycle work in the audit. FLTK remains the comparison adapter.

## Cancellable authentication bridge (N1.10)

`viewer/core/PromptAuthentication` now connects synchronous credential, TLS
certificate and RSA host-key callbacks to owned, generation-tagged requests.
Only the requesting worker waits; its condition-variable wait releases the
bridge mutex, and notification callbacks run outside locks. No framebuffer,
publication or service-store lock is held at the session authentication seam.
UI reply/cancel operations take only the short bridge mutex and do not depend on
a queued worker command. Cancellation and monotonic timeout invalidate the
attempt and wake the waiter; reconnect requires a drained worker and newer
generation. Private response buffers are cleared after use/failure/cancellation.

Fourteen tests cover typed replies, payload limits, trust identity copies,
reply/cancel ordering, expiry, stale generations, independent sessions and
RFB-client VNC callback resume/cancel/reconnect using fixture streams. Real TLS/socket
cancellation is now verified by N1.11 below. N1.6 now supplies the established-
socket peer observer described below; native prompt presentation and trust persistence remain service/frontend
work. This bridge
does not make `ProtocolSession::close()` callable from the UI thread; the host
calls bridge cancellation directly, then drains/closes on the worker.

## Real authentication/cancellation proof (N1.11)

The `authenticationsocket` suite drives the core against an independent loopback
TCP peer, verifies VNC challenge responses before sending success, and negotiates
actual GnuTLS/VeNCrypt X509Vnc with an in-memory self-signed certificate. Tests
exercise accepted/rejected trust, correct/incorrect passwords, direct close/quit
cancellation, monotonic timeout, observed socket FIN, and stale/duplicate replies
after reconnect. A second session with the other security mode completes while
the first waits for credentials/trust. The FIN observer now uses the production
transport's macOS kqueue or Linux POLLRDHUP wait before cancelling the bridge,
without reading protocol bytes.

This proves safe pause/resume/unwind at the core/host boundary. The test host is
not a production lifecycle adapter. N1.5, remaining N1.6 and N1.13 work,
native close/quit UI, Windows sockets and N1.14's full settings/input/clipboard
isolation matrix remain open. See the TODO evidence for builds and sanitizers.

## Bounded input ownership (N1.12 input portion)

`ProtocolSession` owns a retainable `InputQueue`, per-attempt held-key state and
pointer buttons. Producers enqueue generation-tagged commands without touching
RFB streams. The worker drains a bounded number of commands and uses the existing
RFB writer. Only adjacent motion coalesces; key/button transitions retain order.
Core policy rejects view-only/unfocused/disconnected/stale input. A release flag
outside normal queue capacity clears remote held state on focus loss, policy
changes or overflow; overflow suspends input until explicit focus reactivation.
Close invalidates queued commands and attempts release before protocol teardown.
A transport failure cannot guarantee remote release delivery, but cleanup proceeds.

Input command capacity and held-key count are independently bounded. Retained
mailboxes become disconnected on session destruction. Wire tests cover basic and
extended input, failures, concurrent production and per-session policy isolation.
The general event/completion queue is now implemented below. Worker
readiness/flush, full lifecycle drain, native input mapping and multi-view focus
ownership remain unchecked work.

## Bounded event/completion ownership (N1.12)

`SessionEvents` preallocates a bounded ordered stream and operation reservations.
A new protocol subscriber receives the current snapshot. Reliable events preserve
order, statistics coalesce, and admission reserves a completion slot before an
operation is accepted. Overflow retains queued results, fails pending reservations
and publishes one terminal fault in a dedicated slot. All records are owned fixed
values; no user callback runs while the queue mutex is held.

The protocol owner emits state, size, bell and completed-frame statistics events
and supplies a refresh operation with an admission ID and exactly-once completion.
Overflow closes the attempt and releases input. Subscriptions survive normal
reconnect with generation tags; retained events remain readable after destruction.
Tests cover queue pressure/order, concurrent consumption, snapshots, completion
admission, startup overflow and release behavior. This completes N1.12's queue
contract; N1.5 still owns full session/listener transitions and command coverage,
and N1.6/N1.13 still own readiness, scheduling and asynchronous drain.

## Scoped encoding policy (N1.2/N1.3/N1.4 partial)

`EncodingOptions` owns the eight color/encoding settings and per-setting source
metadata. Explicit core construction, layer resolution and live application never
read the legacy registry. Schema-driven FLTK parameter adapters share defaults,
ranges, alias validation and compiled decoder choices. `CConn` snapshots encoding
policy on construction and Options callbacks; automatic selection now reads that
snapshot. An older server no longer changes global FullColor as a side effect.
The shared bandwidth estimator uses caller-supplied monotonic durations and
bounded arithmetic. No scheduler or timer executor is introduced here.

`ProtocolSession` configures actual RFB encoding, compression, quality, JPEG and
wire pixel format from the snapshot. Live policy changes reserve one completion
before mutation, take effect at existing RFB boundaries, and persist across
reconnect. The source framebuffer remains BGRA, including reduced-color decode.
The retained FLTK frontend consumes the same selection policy. Its global Options
UI and remaining parameters still require extraction; this is not a claim of
fully isolated FLTK multi-window configuration or a complete settings schema.
See the encoding evidence in TODO and the viewer README for changed malformed
integer handling, initial hint consistency, old-server restrictions and validation.

## Session-owned timers (N1.6 timer portion)

The portable protocol owner now uses `SessionScheduler`, a bounded monotonic
queue with scheduler-scoped cancellation tokens and an injected host wakeup seam.
No native protocol callback uses the global `core::Timer` list. Statistics and
publication retries are scheduled per attempt; close/reconnect cancels them before
protocol resources are destroyed. Callback execution and captured-object disposal
occur outside queue locks, and cancellation does not wait for a running callback.
The host must still drive deadlines and drain its executor before destruction.

Tests cover timer isolation, cancellation races, capture lifetime, queue pressure,
reentry, callback failure and actual protocol publication/statistics with fake time.
Established-socket wakeups are now implemented below; asynchronous drain and
DNS/connect/listen readiness remain separate work.
The legacy timer list remains for server/FLTK consumers; native emulation and
remaining service timers are not yet migrated. See the N1.6 evidence in TODO.

## Owned socket readiness (N1.6 transport portion)

`viewer/platform/SessionTransport` hides IO readiness, monotonic wait deadlines
and cancellation behind a descriptor-free contract. The macOS/Linux adapter
exclusively owns an established legacy socket and two bounded wake pipes, plus a
macOS kqueue. It sets nonblocking/CLOEXEC and rejects descriptors unsafe for the
legacy select-based streams. These streams now handle would-block as no progress.
`network::initSockets()` uses `std::call_once` instead of an unsynchronized bool;
existing process SIGPIPE/Winsock policy remains unchanged, with failed Winsock
initialization eligible for retry.

Worker-only stream access is separate from thread-safe weak control tokens.
Cancellation uses raw socket shutdown and separate worker/peer wakes, without
mutating stream buffers. Control calls hold state until return; stale retained
controls neither keep sockets alive nor affect reused descriptors. The host must
still drain both wait callers before destroying the transport itself.

Peer closure observation reads no protocol bytes and can run while authentication
parks the worker. Persistent EV_CLEAR/EV_EOF on macOS and POLLRDHUP without POLLIN
on Linux prevent unchanged unread data from spinning the observer. The real
VNC/TLS fixtures now exercise this production adapter and directly cancel the
prompt bridge on peer closure; their worker/controller remains test-only.
Thirteen additional transport tests, full headless/FLTK regressions and focused
ASan/UBSan/TSan passed on macOS. DNS/connect/listen readiness, buffer budgets,
production lifecycle/drain and Linux runtime evidence remain open. See TODO.

## Established-attempt execution and drain (N1.5/N1.13 portion)

`SessionRuntime` now owns a bounded set of established attempts and one join
coordinator. Each attempt has one serialized protocol worker and an independent
peer observer. Protocol construction/mailbox setup happens before publication;
thereafter stream/protocol operations, input drain, timer dispatch, decoder drain
and protocol/transport disposal run on the worker. No worker is detached.

Handle destruction and repeated `closeAndDrain()` cancel the prompt rendezvous
and wake readiness directly without a join. Startup rechecks cancellation after
the prompt bridge reset. Cleanup attempts input release and TLS close before
socket shutdown, joins the observer, and releases protocol/transport resources.
The coordinator joins the worker before setting its shared drain promise. Final
output flushing is nonblocking/best-effort, not a remote delivery guarantee.
Retained views/frames/events/input stay memory-safe after drain; input is inert.

Runtime admission/shutdown is synchronized, and cancellation runs outside its
mutex. Runtime shutdown rejects new jobs and cancels admitted ones; its destructor
joins the coordinator and is explicitly restricted to an application service
thread. Native app lifetime/deinit wiring remains N2; session-handle destruction
itself never joins. Reusable session identity, commands, richer state transitions,
UI notification delivery and service-request cancellation are still open.

Twelve fake-transport tests plus four real VNC/TLS worker cases exercise retained
frames/input release, timers, prompt cancellation/timeout/FIN, concurrent sessions,
immediate close, delayed observer exit, partial construction/admission failure and
concurrent runtime shutdown. Full headless/FLTK regressions and focused ASan/UBSan/
TSan passed on macOS; see TODO for counts, commands and known scope limits.

## Established-attempt lifecycle and asynchronous commands (N1.5 portion)

The worker now owns terminal state publication, pending command settlement and
event sealing. Protocol exceptions still immediately drain/release protocol
resources, but Host terminal ownership prevents a premature Failed event when
the eventual classified result is cancellation or peer closure. Standalone
ProtocolSession ownership preserves its existing cleanup/publication behavior.
Authentication callbacks first publish Authenticating. Workers publish
Disconnecting then exactly one Closed/Failed terminal, even on close before
startup; event overflow uses the existing single terminal Overflow record.
Terminal snapshots and drain results share typed end reason/native error fields.

Refresh and encoding commands use a separately bounded 1–256 entry queue (default
32). Admission checks worker state/generation and both command/event capacity,
reserves a completion before copying a fixed-size command and wakes the executor.
Copying cannot throw or allocate, enforced by static assertion. The worker executes
outside the command mutex and uses the existing reservation, not a second ID.
Encoding snapshot visibility precedes successful completion. Cancellation wins
before dequeue; close stops admission and cancels queued work directly. A started
command finishes, and failures settle remaining work once. Close after finalization
does not rewrite the result; terminal delivery overflow remains a typed failure.

Seven new worker tests, two protocol reservation/ownership tests and two real
VNC/TLS rejection cases cover this change. Existing tests now assert consistent
authenticating/terminal states, including immediate cancellation and timeout/FIN.
Full headless/FLTK and focused ASan/UBSan/TSan suites passed on macOS; see TODO.
Logical-session reuse, resolver/connect/listener lifecycle, remaining commands,
native event delivery and the C/Swift bridge remain open.

## Baseline verification

On 2026-09-18, before code changes, the retained Release build passed **304/304**
unit tests in 14.79 seconds:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build build/tidyvnc-release --parallel 8
DEVELOPER_DIR=/Library/Developer/CommandLineTools ctest --test-dir build/tidyvnc-release/tests/unit --output-on-failure --no-tests=error
```

Host: macOS 27.0 (26A428), arm64. Selected tools for this build: AppleClang
21.0.0 (`clang-2100.3.34.2`), SDK 27.0. Release/static FLTK 1.4.5; GnuTLS,
nettle and NLS enabled; H.264/audio disabled. Architecture, SDK and deployment
target cache entries are not pinned in this existing build; it is **not**
evidence of macOS 14 compatibility.

An initial rebuild without `DEVELOPER_DIR` failed linking against cached CLT SDK
paths while the system selection pointed to Xcode (AppleClang
`clang-2100.0.123.102`): TAPI reported unknown `arm64e.x1` architecture. The
explicit CLT environment above resolved it. Keep SDK/compiler selection paired
in the eventual native build script. No system toolchain settings were changed.

Logs for this run: `/tmp/tidyvnc-native-baseline-build.log` and
`/tmp/tidyvnc-native-baseline-tests.log` (ephemeral, not release artifacts).
No new screenshot, keyboard/focus, full protocol, latency, physical display,
Keychain or minimum-OS result is claimed. N0.4–N0.6 remain unchecked.


## Endpoint setup ownership (N1.6 / N1.5 portion)

Prepared `ConnectionAttempt` objects copy endpoint and address-family/deadline
policy, exposing no native descriptor or global parameter reads. DNS/connect
work starts only on the admitted session worker. macOS asynchronous DNS-SD
queries, bounded address results, nonblocking candidate sockets and cancellation
pipes have scoped ownership; successful socket ownership transfers once into
`SessionTransport`. Linux hostname lookup explicitly rejects until a cancellable
backend is supplied. Numeric TCP/Unix source is shared but tested here on macOS.

A stable synchronized worker control preserves close across the setup/connected
handoff. Control callbacks and disposal run outside its mutex. Close during setup
cancels readiness directly; connected close retains the existing input/TLS release
opportunity. Setup resources are destroyed before the coordinator publishes joined
drain completion. No resolver thread is detached. The socket stream constructor
now stages both stream allocations with unique ownership, preventing a leak if
its second allocation fails.

Real localhost lookup, pending-connect cancellation/deadline, endpoint-to-RFB and
fake slow-setup/handoff tests pass under normal, ASan/UBSan and TSan runs. This does
not establish a bound on a stalled local DNS daemon's IPC calls, native UI
responsiveness, Linux execution, minimum OS or listener/tunnel service behavior.
See the connection-setup evidence in TODO for exact counts and commands.


## Reusable runtime session ownership (N1.5 / N1.13 portion)

`SessionRuntime::createSession` now retains one serialized worker and protocol
owner across attempts. The bounded runtime counts idle logical sessions as active
handles. Frame publication budgets and subscriptions, input policy, event sequence
and operation IDs, prompt request IDs and encoding policy remain session-scoped.
DNS failures and pre-start cancellation consume a generation too. No protocol or
transport instance is reused: each attempt receives fresh connection/security
objects and clears old input/timers while external frame leases stay valid.

Connect/disconnect operations reserve completion capacity before admission.
Disconnect completion follows transport destruction and observer/decoder drain;
permanent close additionally destroys the protocol owner and joins its executor.
Attempt-terminal publication and retry admission share a gate, avoiding a visible
terminal state with a transient Busy rejection. Operation completion and generation
advance cannot interleave. Event overflow permanently closes the logical session.

Cross-thread cancellation captures an attempt-specific control, and prompt
cancellation is generation-scoped. Delayed calls cannot cancel a later socket or
prompt. Scheduler wake routing calls controls outside locks. Native service/store
requests, reconnect security-policy edits and notification dispatch are not yet
covered by this ownership boundary. See TODO's reconnect evidence for macOS fake
transport, sanitizer and real VNC/TLS validation.


## Remote desktop layout ownership and completion (N1.5 / N1.2 portion)

Remote screen topology is now an immutable bounded value in session snapshots;
requests are copied before command admission and do not expose native display or
window types. Capability and actual server layout are per-attempt state. One
queued/on-wire resize and one monotonic deadline prevent unbounded request queues
or ambiguous response matching. Command records copy without allocation after
completion reservation; bounded layout allocation occurs before that boundary.
View-only and framebuffer limits are enforced both at admission and execution.

The RFB response has no request ID. A timeout settles the operation but retains
an occupied wire slot until the late client reply or reconnect. Other-client
changes cannot complete a local request. The response publishes actual topology
before its typed completion; rejected requests leave actual layout unchanged.
Close settles pending operations and cancels the deadline before destroying the
connection. This is core protocol ownership, not native window-resize policy or
physical display/presentation validation. See TODO's layout evidence.


## Clipboard ownership and routing (N1.5 / N1.9 portion)

Each protocol session now owns a ClipboardChannel with independent send/receive
policy, one coalesced incoming update and a shared normalized-text byte budget.
Immutable leases retain the budget across commands, cached offers, reconnect and
external consumers. Only the channel can construct noncopyable lease objects;
foreign local leases cannot be used as offers. Remote-origin tags suppress native
clipboard echoes, including across sessions. Input focus/view-only transitions and
clipboard policy changes invalidate routing revisions even if the state returns
to its prior value before a queued command executes.

The worker owns RFB callbacks and offer/withdraw commands, reserves completions
before queueing, and keeps one clipboard command slot. Cancellation/close releases
queued data, and protocol cleanup releases cached data. Native consumers must
serialize focus and OS writes and recheck a retained update's route before writing.
No native callback executes inside channel locks. RFB has no request IDs; latest
request routing is not exact transactional matching across repeated notifications.

Payload limits exclude metadata, string capacity, temporary RFB conversions and
caller strings. Reader wire/decompressed format limits remain separate. Extended
clipboard reader buffers now have scoped ownership if later decoding or a delivery
callback throws. Native pasteboard, active-session arbitration and multi-window
integration remain open. See TODO's clipboard evidence for tests and limitations.


## Reverse listener ownership (N1.5 / N1.6 / N1.13 portion)

ListenerRuntime owns bounded listener executors and a join coordinator separately
from session workers. Prepared ListenerSource objects bind/accept only on those
executors. SocketListener uses numeric TCP endpoints, nonblocking/CLOEXEC sockets,
V6ONLY, poll and a weakly retained cancellation control. Partial bind errors roll
back all descriptors, except unavailable families skipped under legacy policy.

Each worker owns a bounded list of unclaimed transports with monotonic expiry.
Capacity pauses acceptance; host decisions transfer or dispose a transport once.
No RFB bytes are read until explicit acceptance into SessionRuntime, with caller
security policy and numeric peer identity. The accepted session survives listener
stop. Runtime admission failure consumes/closes the claimed peer. Peer scope is
routing metadata and is excluded from the TLS certificate hostname.

One bounded ordered event stream preserves initial/lifecycle/peer events and
reserves two terminal slots. Overflow closes the listener and all pending peers.
Events retain owned addresses/peer metadata independently; output replacement,
control callbacks and transport destruction occur outside shared locks. IDs never
wrap. Handle release requests cancellation without joining; drain completion follows
source/pending-resource disposal and worker join. Native app coordination and
pasteboard/window/service lifetimes remain separate. See TODO's listener evidence.


## Initial C ABI ownership (N2 portion)

The C boundary uses non-reused 64-bit IDs and a bounded typed registry, not foreign
pointers to C++ instances. Calls retain implementation objects while accessing
state; explicit refcounts determine final-release shutdown. Registry deletion and
object cleanup occur outside its mutex. All exported calls translate exceptions
and bounded text diagnostics never contain exception input. Input/output C values
use explicit scalar/enum mappings and versioned size prefixes; immutable image and
prompt spans borrow from explicit retained handles.

A separate bounded service retains runtimes until their worker/coordinator drain,
then destroys them on its own joined thread. Final runtime release only requests
shutdown. It sleeps when idle and polls closing futures at 20ms intervals; at most
eight runtimes and 4096 registry records are admitted. Reservation happens before
asynchronous admission and view/prompt consumption, preventing allocation failure
from losing an update without an owning handle. Frame leases retain core budgets
across session/runtime disposal. Secret input spans and bridge string temporaries
are wiped within documented bounds; foreign copies cannot be guaranteed erased.

Pure C allocation-failure tests and real VNC/None loopback tests exercise the public
boundary, including concurrent retain/release, stale handles, two sessions with
one parked for credentials, cancellation, generations and retained pixels. The
headless dependency audit includes the C ABI target. C callback contexts now have
explicit retention, unsubscribe and post-release drain. A separate joined
dispatcher holds at most 512 subscriptions; weak core wake targets signal
event/view/prompt mailboxes and joined session drain. It invokes host code outside
core/registry/dispatcher locks. Final session release invalidates its subscription
without extending protocol lifetime; explicit close preserves terminal delivery.
Queued host closures remain the host's ownership responsibility, with subscription
and generation checks required at delivery. `platform/macos/Bridge` now implements
the Swift ownership layer with MainActor observable session state. A lock guards
one queued delivery bit and latest generation; its closure owns the subscription
and context while weakly targeting the model. Every delivery validates identity
and generation before consuming bounded event batches and latest view/prompt data.
Borrowed pointers do not enter model state: images own immutable C leases and
prompts copy metadata. Immutable C handle/image wrappers and the locked delivery
gate are the limited, documented unchecked-Sendable types.

Native command awaits use generation/operation identity and checked continuations.
Close invalidates delivery, resumes outstanding callers, closes/unsubscribes and
asynchronously awaits core join, context release and queued MainActor delivery.
Cleanup tasks survive cancellation of callers' awaits; deinit only cancels/releases.
Runtime records sessions weakly, while sessions own the runtime. Tests verify weak
model/context disposal, repeated capacity recovery, parked-prompt cancellation,
MainActor progress and retained frames through shutdown. Native views now keep
CGDataProvider-owned C leases without copying pixels; drawing and pointer mapping
use the same portable geometry. Shared key tables remain immutable. The SwiftUI
app coordinator tracks independent windows, starts session close on window removal
and drains its runtime before termination, including an outstanding auth sheet.
OS service requests, full responsiveness and production packaging remain open.

Clipboard channels now signal the same weak mailbox readiness target for offers,
text, invalidation and policy changes, always outside their mutex. The C boundary
reserves text-handle storage before consumption; retained immutable text keeps
the core byte budget and origin alive without retaining a session. Receive tokens
add the originating non-reused session ID to generation/focus/policy revisions.
The host must still serialize native writes and focus changes and validate just
before writing. Swift sessions publish copied text plus its retained lease,
resolve async offer/withdraw completions and clear clipboard/focus presentation on
terminal state. Cross-session remote-origin echoes are rejected.

The app now owns one MainActor `NativeClipboardCoordinator` with weak session
registrations and an injected `NativePasteboardAccess` implementation. It selects
exactly one focused, connected, non-view-only session while the app is active.
Every routing transition invalidates pending host work immediately; deferred
reconciliation samples the stored state after Published notifications. One weak
250ms observation task exists only while sending is eligible. There is at most one
admitted transfer and one latest pending job, stamped with session generation,
routing epoch and native change count. Remote writes validate the receive route
without suspending MainActor and mark the pasteboard with a fresh origin UUID;
that marker suppresses automatic cross-session/reconnect echoes. Registration
does not replay cached remote updates. Changed native snapshots retry; fixed error
messages contain no payload. OS/provider allocation and cross-process write atomicity
are outside the admission bound. Stop gates native access and cancels observation;
async close joins transfer completion, and quit awaits it after session shutdown.
Disposable named-board and fake-adapter tests verify routing, ownership races,
bounded coalescing and weak disposal. Visible app-control/activation checks remain
open because the Mac was locked. OS store lifetimes remain separate future work.

## Native display topology (N3.16)

One app-owned MainActor `NativeDisplayService` injects `NativeDisplaySource` and
publishes immutable value snapshots. AppKit NSScreen objects are read fresh and
never retained in snapshots; ColorSync UUIDs supply opaque identity instead of
transient display numbers or array indices. Full/work rectangles share one
AppKit-to-top-left logical-point conversion; backing scale is explicit. Validation
is bounded to 64 displays and rejects invalid geometry/identity as a unit. A failed
read publishes empty geometry with a typed error; unchanged/reordered values do
not churn generation. Missing selections are reported without mutating saved IDs;
current/primary fallback is used only if no requested monitor survives.

Screen and active-Space notifications trigger synchronous MainActor refresh; there
is no polling task or worker. Notification registrations and desktop subscriptions
do not retain their targets. Desktop detach cancels its subscription; app quit
stops service observation before window/session shutdown. Published topology causes
geometry/cursor refresh using the window's actual backing scale. Isolated provider
tests exercise generations, missing/reappearing IDs, errors, reentry and disposal;
actual capture reads the host's single drawable display. Simulated multi-display
tests do not prove physical hotplug, mixed-density or fullscreen/Spaces behavior;
those N5 gates remain open. No new process-global mutable cache or portable C ABI
surface is introduced by this native service.

## Native preferences storage foundation (N3.1 portion)

`NativePreferencesStore` owns one serialized actor executor, an injected Sendable
backing and up to 64 latest-value stream continuations. UUID revisions change on
each accepted commit/reset; a fresh backing read rejects observed stale drafts.
The UserDefaults adapter reads only its dedicated persistent domain and writes
one owned Data record key. It does not consult registration/global/argument/XDG
fallbacks. Schema/type/unknown-field validation occurs before any write; invalid
or future data is preserved. Schemas 1–3 remain read-compatible without rewriting;
explicit saves write schema 4 with optional clipboard directions and closed typed
encoding/input/scaling patches.
Encoding resolution uses the shared core schema, with no duplicate defaults/ranges
or secret-bearing fields. Invalid/unavailable encoding values preserve stored bytes.

No await occurs between validation/admission and synchronous backend acceptance.
Cancellation before admission has no effect; after acceptance the committed result
is returned. Backend failures can have side effects and require reread/reconciliation.
UserDefaults supplies asynchronous persistence, not cross-process CAS or durability;
independent writers are outside the single-actor conflict guarantee. Change streams
coalesce to one snapshot and return capacity on termination through weak actor
cleanup tasks. Close finishes all streams; retained streams do not retain the store.
Tests use disposable domains/fakes and cover uncertain outcomes and cleanup. The
app now owns one store. `NativePreferencesDraft` keeps a copied snapshot/revision
and editable values on MainActor; saving runs on the store actor. Cancel/dismiss
does not save and restore only edits the draft. Conflicts/uncertain writes require
reload; encoding validation errors leave the draft correctable. UI close cannot undo an already accepted save.
`NativeSessionDefaults` owns its runtime and, after one successful defaults read,
creates and owns one session with the resolved initial encoding snapshot. Thus
encoding defaults precede both session construction and Connect. Failed loads need Retry or explicit built-in fallback;
neither repairs or overwrites unreadable data. A ready session never observes later
app-default saves. Live direction changes record only that session's per-field
override. Models' operation tasks weakly reference the models; stop invalidates
delivery and async close joins admitted completions. App quit joins these model
operations and the store after starting session/runtime shutdown. Injected blocked
IO verifies MainActor progress, late-result suppression and no session allocation
after close during a pending read. Broader schema,
remaining live-session settings sheets and interactive checks remain N3.1/N4.9.
Migration, credentials and trust lifetimes remain
separate unchecked work. File storage, profile editing and app history ownership are described
below. Rendering tests use independent in-memory stores and
unshown windows; no production preferences or existing user data are changed.

## Encoding C/Swift ownership (N2.1 / N2.2 portion)

The C boundary now owns immutable `EncodingOptions` snapshots in the existing
bounded typed handle registry. Fixed output structs copy schema/choice/value text;
patch spans are validated and copied before return. No borrowed C++ strings or
mutable process parameter registry enters Swift. Explicit source/option enums
are checked against the core mapping at compile time. All shared-validator errors
cross C as fixed diagnostic text plus structured reason/option metadata.

Session creation copies initial options before negotiation without changing the
existing session-options struct layout. Live apply copies a complete snapshot into
the established bounded worker queue and reserves its completion; only execution
changes that session's requested snapshot. Query handles retain independent values
through reconnect/close and do not own sessions. Protocol-safe emission, automatic
selection and old-server pixel-format restrictions are unchanged. Cancellation
cannot roll back an executed change. Swift owns immutable handles, copies strings,
uses one bounded temporary UTF-8 patch buffer and resolves apply through existing
generation/operation completion tracking. C loopback and Swift tests cover isolation
and ownership. Native app-default controls and typed preferences now resolve through
this schema before session creation.

`NativeSessionEncodingDraft` owns immutable baseline/draft snapshots, copied values,
a captured generation and at most one pending Apply. Its session target is weak;
the admitted task retains the target only until completion, and weakly references
the editor. All editing/validation/publication occurs on MainActor. Pending work
gates editing and duplicate Apply; observed baseline differences prevent overwrite,
while the C boundary independently validates generation. The baseline comparison
is not atomic with core execution. The app admits one editor per connection and
awaits an old editor's drain before reopening. Successful confirmation rereads
requested options and rechecks generation/state; failed/cancelled commands require
reload since accepted changes cannot be undone by cancelling an await.

Session/close observations invalidate a draft on disconnect/reconnect. Cancel edits
restores only the draft and never clears a conflict gate. Stop cancels work and
observation; async close joins completion without blocking MainActor. The app
ConnectionModel owns sheet cleanup and includes it in window/quit drain. It removes
encoding sheets on disconnect and uses a single authentication/encoding sheet route.
An old encoding dismissal cannot cancel a newly published authentication prompt.
No preferences backend participates in live editing. Fake delayed-completion tests,
real independent sessions/reconnect and the compiled app controller exercise these
lifetimes; interactive sheet/keyboard/VoiceOver acceptance remains open.


## Native profile/history files (N3.2 foundation)

`NativeProfileHistoryStore` serializes typed record operations on one actor. Its
snapshot owns profile values, bounded exact-address history and a fresh revision;
there are no callbacks, subscriptions, workers or retained session references.
Profiles apply explicit settings with profile provenance and contain only an opaque
UUID for a future credential reference. No credential lookup or save is performed.
Shared encoding validation remains authoritative. Record/header/nested-key/type
validation rejects unknown or corrupt state before any mutation.

Schema 10 additionally owns explicit history initialization state. New
profile-only writes do not initialize history; record/clear do. A separately
reviewed current/legacy history import uses the same actor, revision and backing
CAS to commit list plus marker while preserving profiles. Old schemas 1–9 count
as initialized even if empty, because prior clears are indistinguishable. All
ordinary edits retain migration state. The import service reads a bounded source
off the main actor and captures the native revision before reading; cancelled
reads produce no review, source changes cannot replace the reviewed list, and
stale destination revisions fail. It creates no session, trust or credential
operation. History UI/consent and recent-model refresh remain separate work.

`NativePrivateFile` is immutable and Sendable; every operation owns its local file
descriptors and bounded Data buffers. Reads do not create state. The host chooses
Application Support; filenames are fixed or UUID-generated, never profile names.
Pinned directory descriptors, no-follow opens, regular/single-link checks, current
UID ownership, private POSIX modes and extended-ACL checks guard access. Newly
created objects have inherited ACLs cleared; existing permissions are not repaired.
The surrounding host Application Support parent is trusted. The default backend
creates a missing parent only on first write; construction/read remains side-effect
free. Injected-directory backends require an existing parent unless opted in.

One private flock descriptor serializes cooperating writers across actors/processes;
contention returns busy without waiting. Exact expected bytes are rechecked under
that lock, followed by bounded same-directory temp write/fsync/rename/directory
fsync. This is not CAS against an uncooperative same-user writer. Cancellation
before rename cleans the temporary and preserves the old record; after rename it
cannot roll back. A later failure requires reread because the new revision may
already be visible. Ordinary failures close/unlink their owned temporaries; crash
orphans are ignored rather than promoted or automatically deleted. Power-loss
hardware durability and orphan maintenance are not claimed.

Tests use disposable roots and native file operations, plus injected checkpoint
failures/cancellation and a separate test subprocess for lock contention. Profile
and history mutations share one revision, so stale operations cannot erase each
other. No native or legacy production user data was accessed by these tests.

The app owns one store and one MainActor `NativeRecentHistory` model shared across
connection windows. The immutable default backing resolves Application Support
inside operations, so app construction performs no filesystem setup. Successful
connect completions check current generation/connected state before enqueueing
their captured address; failures and cancelled authentication never record. The
connection operation never awaits disk IO. History errors are nonfatal UI state.

The model holds one operation task and at most 20 pending successful addresses;
duplicates and refreshes coalesce. Tasks weakly reference the model and retain the
store only for admitted operations. Failed records await explicit reload before
retry, while remove/clear use the displayed revision and are never replayed.
Failed reads suppress stale cached entries. App activation/popover opening refresh
state. Stop rejects later completions and cancels delivery; quit awaits admitted
history work before closing the store. Cancellation after an accepted write does
not claim rollback. Tests hold reads and accepted writes while checking MainActor
progress, disposal, late-publication suppression and join.

Remaining typed settings, credential-reference resolution and import/
export remain unchecked. Synthetic light/dark history renders verify layout;
unlocked-app checks now verify popover selection, Escape dismissal, shared windows
and restart persistence. Removal/clear, complete keyboard navigation and VoiceOver
acceptance remain open. See the later unlocked-app evidence in TODO.md; its two
loopback connections intentionally exercised the real app's native history store.

`NativeProfileLibrary` is a single app-owned MainActor editor over the same file
store and the preferences store. It owns copied list/draft/baseline values and a
revision, with one weak-self operation task. Save/delete compare the displayed
revision, including intervening history changes. Dirty edits are preserved on
conflict/uncertain outcome; explicit reload reads actual state and never replays
mutations. Failed reads clear the list, keep the draft for review and gate editing.
Model/window cancellation does not claim rollback after an accepted save. App quit
joins editor operations before closing stores. No credential backend participates;
opaque references are preserved with the copied profile.

Profile launches retain only a profile UUID and unique window UUID for scene
identity/restoration. `NativeSessionDefaults` freshly reads app defaults and the
profile, applies compiled/base -> app -> profile precedence, then creates its
session and delivers the saved address to the controller. Missing/invalid profiles
never fall back to plain connections. Explicit built-ins after a preferences error
still require a successful profile read. The two stores are independent snapshots,
not a cross-store transaction. Ready connections do not observe later profile
changes/deletions. Stop during either read suppresses late allocation; close joins
the operation. Tests exercise the real controller and held profile reads, with
normal/ASan/TSan and light/dark view fixtures. Full interactive profile acceptance
is still pending after a confirmed computer-control helper crash during inspection.

## Native endpoint preflight (N2.1 / N4.1 portion)

The C ABI adds stateless `endpoint_validate`, borrowing at most 4096 UTF-8 bytes for
one synchronous call. It owns only local bounded strings, allocates no handles or
runtime/session, and invokes the same helper as Connect. Native Swift builds a
temporary buffer bounded to 4097 bytes so the C boundary reports TooLong before
copying overlong input. Neither layer resolves names, opens sockets/files or
canonicalizes the user's field. Error text never incorporates input; C reasons
map to typed native issues. Empty-field UI policy is distinct from the parser's
legacy empty-to-localhost behavior. Concurrent and pure-C tests cover parity,
span/version errors and rejected Connect preserving operation output/session state.

`ConnectionModel` owns the latest validation result beside its endpoint and gates
Connect; `NativeProfileLibrary` validates its current draft before Save. Fixed
inline errors leave the original editable text intact. Storage reads continue
admitting bounded legacy address strings so malformed saved values can be repaired
through the editor. No validation task, callback, subscription or lifetime extends
beyond the synchronous call. Native tests verify invalid form actions do no work.

## Native connection scaling (N2.1 / N4.7 portion)

`scaling_parse` is a stateless bounded C wrapper over the shared parser. It returns
copied explicit mode IDs and canonical text, never handles or borrowed outputs.
`NativeScalingState` belongs to one connection and owns one immutable applied value
and revision, including the nearest/bilinear/area filter. Bilinear matches the
retained frontend default. A draft weakly references it, retains only copied
baseline/custom texts and uses a synchronous MainActor revision check before
publication. The settings transaction starts no worker, async task, preference
write or server-resolution command; the subscribed view schedules rendering.
Disconnect/close cancels the visible draft; shutdown gates any retained old draft.

The desktop weakly references state and the state weakly references its attached
view. A separate subscription installs mode/units/filter atomically and is cancelled on
detach. Geometry validation immediately before Apply uses the current image, bounds
and backing scale; the existing transform remains the image/input/cursor authority.
Later geometry overflow falls back to a shared fit transform and emits one fixed
message until recovery, retaining the user's selected value. Tests cover copied
state, stale editors, weak lifetime, AppKit release after pending window cleanup,
actual controller disconnect, wire input and Retina overflow. Filter-only changes
preserve pan; mode/units changes reset it. Tests prove filter Cancel/Apply/reopen,
revision conflicts, connection isolation and pixels produced through the actual
draft-to-view path. Shared renderer/cache ownership is documented below; scaling
defaults/profile persistence remains a future increment.

## Bounded frame-tile renderer ownership (N2.1 / N5.1 foundation)

A C renderer handle owns one mutex and `FrameTileRenderer`, which wraps the existing
CPU tile cache/resampler. Cache memory is capped at 32 MiB (native default 8 MiB).
The renderer retains source identity/sequence/generation metadata, not a frame or
session. Each call temporarily owns the registry's image object; retained old
images render after session close. Wrong stream/generation/size/transform/filter
or missing previous-sequence history invalidates cache. Valid partial damage only
invalidates affected source footprints. Both cache allocation failure positions
are injected: output is already complete, cache is dropped, and later calls recover.

`NativeSession` copies damage and the previous consumed frame sequence into each
immutable `NativeImage`, plus a stable UUID used only for native presentation
routing. No borrowed pixel pointer or mutable damage array escapes. A native actor
renders visible fixed-grid tiles, rejecting more than 64 MiB / 1024 output tiles
before allocating; zero visible area clears cache. Results retain one source image
and immutable CG tiles. Each provider directly retains one native allocation written
before publication; only diagnostic Data access copies it. Contiguous damage history
allows unchanged CG images/storage to be reused. Shared damage geometry computes
filter halos and backing-pixel rounding for both reuse and AppKit invalidation.

The MainActor scheduler stores one active and one latest request. Tasks capture the
worker/request strongly and scheduler weakly. Same-presentation updates finish
current work before rendering latest; transform/source changes cancel at tile
boundaries. Close gates admission/delivery, cancels, joins asynchronously and clears
cache. Fake held workers prove stale-result suppression even without cooperation,
500-update coalescing, explicit retry and weak disposal. Actual retained-image tests
prove pixel values, byte limits and cancellation.

AppKit now publishes tile images and input geometry together, retaining the displayed
map during asynchronous scale changes and clearing it for source/size changes.
Identity uses the original retained image; hidden views clear presentation and
reset the worker. The worker's previous result can differ from the displayed result
after suppression/failure. Conservatively allow three 64 MiB tile payloads (displayed,
previous worker result, in-progress output), plus 8 MiB native-default C cache per
renderer. Sharing often reduces this. Metadata, source-frame leases, allocator and
CG upload costs remain separate and require measurement.

`NativeSession` owns a `NativePresentationPool` with 16 slots. Detached renderers
remain counted until cleanup finishes, bounding rapid attach/detach; view deallocation
also releases its slot. Slot cleanup retains the scheduler, references the pool weakly
and joins running work before dropping cached tiles. The pool holds no view references.
Session close stops admission before clearing frame streams, then joins all slots;
runtime shutdown joins session close. Held actual workers that ignore cancellation
verify obsolete-result suppression, detached-slot accounting, asynchronous close,
capacity enforcement and released-view cleanup. Session deallocation also schedules
pool cleanup without retaining the session. Each slot now also owns a bounded cursor
scheduler/worker; release stops both schedulers and joins both before freeing the
slot. Measured end-to-end budgets remain open; this is
not full N5 ownership/performance acceptance.

## Native image observation isolation (N5.1 portion)

`NativeSession` now owns separate MainActor current-value frame/cursor subjects.
Their public type-erased streams replay one retained immutable image (or nil) and
do not feed `ObservableObject.objectWillChange`. Read-only image access remains
available without SwiftUI observation. The shell observes only `hasFrame` for
desktop availability; repeated frames, cursor changes and redundant clearing do
not repeat that value. Each subject retains its current image until replacement,
explicit close or subject disposal; subscribers that retain a publisher or image
can extend that lease intentionally. No extra pixel copy or background queue is
introduced. AppKit callbacks remain synchronous on MainActor and weakly reference
the view, with subscriptions cancelled on detach.

The session publishes a snapshot only when its copied value changes. Core frame
counters already advance through throttled statistics publication (100 ms default),
so per-frame readiness no longer republishes identical snapshots to the connection
model and SwiftUI shell. Nil prompt checks and equal focus/view-only assignments
are also suppressed; native input validation still runs for explicit setters.
The loopback test counts actual object notifications through 20 frame updates,
RichCursor show/hide, AppKit presentation and repeated focus calls. Every object
notification in that steady-state interval corresponds to a distinct snapshot;
disconnect publishes one unavailable transition and clears the desktop. New stream
subscribers replay current leases, and retained cursor pixels survive shutdown.

## Shared cursor sampler ownership (N2.1 / N5.4 foundation)

A typed C cursor-sampler handle owns an immutable `CursorRenderer`. Construction
borrows a registry-owned cursor image for the call and copies at most 4 MiB of
packed straight RGBA into original-sized premultiplied storage. The sampler retains
no source image, publisher, session or runtime. Geometry/hotspot metadata is copied;
no enlarged raster is retained. Render validates a <=256 × 256 tile and a bounded
output span before writing straight RGBA. Shared filtering handles alpha in
premultiplied form. Immutable source storage supports concurrent render calls with
separate caller-owned output spans. Final release frees the source; calls already
holding a registry reference finish safely. No background work or callbacks are
owned by the C sampler itself. Injected registry/object/source allocation failures
return typed errors and leave both create outputs unchanged.

Swift `NativeCursorSampler` owns one handle and immutable geometry. Each render
allocates exactly one bounded tile payload, writes it before publication and gives
its CG provider direct retained ownership. No Data copy occurs except diagnostic
pixel access. Cancellation checks surround synchronous calls; within-tile work is
not interruptible. Tests prove original NativeImage deallocation independently of
the sampler, retained CG tile data after shutdown and concurrent sampling. These
source/tile bounds exclude metadata, caller-retained tiles and CG uploads. The
AppKit cursor path now consumes this service as described below.

## Native/software cursor presentation ownership (N5.1 / N5.4 portion)

Each view's presentation slot owns one cursor scheduler/actor alongside the desktop
scheduler. Cursor admission is one running plus one latest pending request. Shape,
filter, scale and clip changes cancel obsolete work at tile boundaries; pointer-only
motion allows useful work to complete and then processes the latest pending point.
Completed software cursor placement uses that request's point/geometry, so motion
can lag the physical pointer until background work completes. Exit/letterbox/hidden
state erases the overlay immediately and rejects late visible results. Actual pointer
events continue independently; latency budgets and physical input acceptance remain.

The actor caches one sampler and one completed batch. It reuses unchanged CG tiles
on motion and rejects visible output beyond 64 MiB / 1024 tiles before allocation.
Native cursors are capped at 128 × 128 backing pixels; larger cursors compose clipped
tiles through the AppKit draw path. Hotspot and native logical size divide shared
backing-pixel values by the displayed geometry's actual backing scale. Images and
cursor requests follow the displayed frame transform/filter, with generation guards.

Conservatively allow three cursor tile batches (displayed, previous successful and
in-progress), or 192 MiB payload, plus up to two 4 MiB source copies transiently
during sampler replacement. This is additional to desktop worker bounds. Usually
tiles share allocations, and a small native cursor needs at most 64 KiB output.
Metadata, source leases, NSCursor internals and CG uploads remain outside these
payload bounds. Sixteen slots bound attached and draining view pairs, not sixteen
total individual cursor/desktop actors; full app memory still needs measurement.

Nil/all-transparent cursors use a local hidden/dot/system policy; default hidden
matches the retained frontend. View-only uses a system arrow. Cursor errors erase
old overlays, show a local arrow and report once until successful recovery. The
fallback policy is exposed on the view and the connection Input Settings sheet;
defaults/profile persistence remains open. Held-worker tests verify stale-filter suppression, 500-motion coalescing and
asynchronous cursor drain after detach. AppKit bitmap tests cover software pixels,
letterbox clipping and alpha, native image/hotspot sizing, blank/empty fallback,
view-only, hide and actual Retina-window attachment/detachment. They do not establish
visible system-cursor behavior on physical multi-display/Spaces configurations.


## Connection input settings ownership (N4.6 / N5.4 portion)

The connection model owns `NativeInputState` and at most one copied input draft.
The state weakly holds its session and observes view-only/lifecycle changes with
weak captures. Each draft weakly holds state and snapshots revision/generation.
MainActor Apply validates connected/nonclosing state and revision before changing
view-only through the C ABI, then publishes combined view-only/fallback settings.
There is no await or storage operation within this transaction. Failed or stale
Apply does not publish fallback. Session policy changes and lifecycle transitions
invalidate prior revisions; stop cancels subscriptions and clears the weak session.

The desktop observes fallback with a weak capture and releases the subscription
on detach. Session view-only publication clears local input and text composition;
the core releases already-held remote input. New pointer presses, wheel movement
and key-down events in view-only mode do not accumulate local input for a later
control session. Controller close/disconnect dismisses the editor; late dismissal
bindings verify draft identity, preserving newer sheets and authentication prompts.
Defaults/profile storage is unchanged. Actual loopback and controller tests cover
release, isolation, stale/external/reconnect changes, close gating and weak owners.


## Middle-button policy and timer ownership (N4.6 portion)

`MiddleButtonEmulator` is an executor-confined value with one 11-state machine,
three fixed output event slots, retained original/latest positions and masks.
It owns no references, heap allocations or timers. The retained adapter consumes
it with the existing global frontend parameter/timer; the native path has no
frontend globals and uses the protocol session scheduler's fourth bounded slot.

Input policy changes are atomic under the mailbox mutex. Emulation changes bump
the routing revision, discard queued commands and enqueue the existing release
barrier. Dequeued commands snapshot revision/policy under the same lock. Release
barriers and revision changes cancel the pending timer and reset emulation. Timer
callbacks capture only session-owned `this`, generation and revision; they run
only on the session executor and check current routing/focus/view-only/connection
before producing events. All timers are cancelled before connection destruction.
Reset, close, reconnect and overflow cannot carry an old delayed press forward.

Swift publishes applied input policy after the checked C call. Copied drafts
observe external emulation changes through the weak session-state binding, and
AppKit clears held local input when policy changes release remote input. No Swift
Task/timer is introduced, and no defaults/profile store or other session is changed.


## Shared shortcut classifier and native routing ownership (N5.5 prerequisite)

Each `ShortcutState` owns a fixed 1024-entry array of physical IDs, keysyms and
fired flags. Normal press/release/reset/reconfiguration allocates nothing. A new
ID beyond capacity or invalid modifier mask fails before state changes; existing
ID repeats remain admissible. The measured arm64 state size is 12,304 bytes. Its
C object owns that state plus a mutex. All mutable C calls serialize per handle,
while independent handles share no input state. The usual 4096-handle registry
bound applies; registry/shared-owner/allocator overhead is additional to state.
No session/runtime/view references, timers, callbacks or process-global keyboard
state are stored by the classifier.

Swift's MainActor owner retains one typed handle. The router adds a bounded set
of at most 1024 physical IDs, active-shortcut and bypass flags. It returns effects
for the host to execute; no wire input, keyboard grab or window action occurs.
Invalid changes preserve existing state. Reset clears active/bypass/held state.
Ordered layout candidates are borrowed synchronously and not retained. Hosts
must release wire keys and reset on lifecycle/routing changes. AppKit integration
is described below; physical keyboard-layout fidelity and actual global capture
still require interactive acceptance.


## Desktop command and modifier-latch ownership (N4.10 portion)

Each connection model owns one `NativeDesktopCommands`; it owns desired/sent
Control/Alt flags, cancellable observations and at most one pending recovery task.
Session and host/view/window references are weak. The desktop attaches/detaches
explicitly. Tasks capture the command owner weakly, have cancellation/stop and
identity guards, and run synchronously on MainActor without an await. Stop cancels
pending recovery/subscriptions and releases sent input. Rebind releases old-session
input before replacing the weak session. No background work retains a window.

A synthetic menu command verifies connected/nonclosing/non-view-only state,
focuses the owning desktop and rechecks host/session/policy. It releases current
wire/local input before changing selected latches or sending Ctrl-Alt-Delete.
Synthetic IDs (0x200000 + keysym) are outside physical and committed-IME ranges.
Failure releases input and rolls back selection intent. Focus loss releases actual
wire keys but retains selected menu modifiers; recovery reasserts them only with
current focus and policy. Disconnect clears intent so reconnect cannot inherit
latched keys. A physical left-modifier release reasserts a selected menu latch.

Window actions query the actual host window and reject sheets/missing targets.
Minimize is currently limited to windowed mode. Fullscreen calls native AppKit for
one window; real transitions, Spaces and multi-display coordination still need
acceptance. The basic information sheet observes the existing session snapshot
and joins the same identity-based sheet arbitration as settings/authentication;
complete negotiated metadata remains open. Shortcut-triggered native popup
dispatch is implemented with a synchronously retained controller and weak model.


## AppKit shortcut dispatch and keyboard capture (N4.6/N4.10/N5.5 portion)

Each desktop owns one shared-classifier router and one capture backend. Layout
queries own/release the current TIS source, use a four-code-unit translation buffer,
try at most 37 modifier variants and return at most 37 unique symbols. Candidate
translation is lazy: ordinary remote input does not perform layout enumeration.
AppKit routes down/up/modifier and key-equivalent events before remote translation;
Space bypass keeps remote modifiers and suppresses only its initiating Space.
Shortcut commands clear remote/local held input while retaining router state until
physical releases. Context-menu tracking relinquishes focus and resets routing.

The additive C release-input operation checks generation/connection under the
input mutex, advances routing revision, discards unsent commands and schedules
release-all without changing focus or input policy. This cancels delayed middle
presses and other work guarded by that routing revision. Tests verify wire key
release, immediate next-key admission, queued-input discard and stale/closed guards.

Capture requires a connected, nonclosing, non-view-only, focused desktop in the
active key window without a sheet. Tests inject backend/eligibility/fullscreen
queries; production uses AppKit state. Capture uses a main-run-loop session event
tap with no host/context pointer in its callback. The callback posts keyboard
events to the owning process, following the retained Cocoa adapter. The resource
owner disables the tap, removes its source and invalidates/releases both CF objects.
Failed creation cleans partial resources. Permission preflight does not prompt.
No background task or timer is introduced for capture or shortcut dispatch.

Focus loss (including external session focus changes), sleep, view-only, policy
reset, disconnect, detach and close synchronously release the capture resource.
Manual release suppresses fullscreen recapture until a subsequent focus cycle.
Automatic capture attempts once per eligible fullscreen/focus cycle; failure is
shown in status rather than generating a focus-stealing alert/retry loop. A tap
that becomes disabled is detected on input/presentation updates, releases held
input and remains disabled until explicit retry or a later focus cycle.

The context popup controller is held with `withExtendedLifetime` throughout native
menu tracking, and its callbacks weakly reference the connection model. Menu
commands revalidate current eligibility at dispatch. No actual global keyboard
capture or fullscreen/Spaces acceptance is inferred from backend/window spies.


## Input persistence, initialization and source ownership (N4.6/N4.9 portion)

The input persistence patch owns only optional value types: three Booleans, an
unsigned modifier mask and a closed cursor enum. Stores inspect raw JSON before
Codable decoding to reject null/coerced Boolean/integer values, unknown keys, masks
outside 0–15 and unsupported cursor tokens. App schema 3 and profile/history schema
2 add these fields. Older supported records are read without mutation; only a
successful explicit write upgrades their envelope/revision. Existing store size,
revision, cancellation and private-file replacement guarantees remain unchanged.

App-default and profile resolution are pure value transforms over the initial
configuration, preserving absent fields and assigning per-field source metadata.
NativeSession validates the host mask before allocating a handle and sets core
view-only/emulation policy before registering delivery or exposing the session.
Its initial host settings/source dictionaries are immutable values, not references
to either store. The session separately tracks current sources for its two mutable
core-policy fields, updating those sources before property publication. Late-bound
input state therefore preserves session provenance even when a live value returns
to its initial value. The input state snapshots these values when binding; changes to
app/profile stores have no path to already-created sessions or reconnect attempts.

InputState publishes sources independently from its existing settings value. A
successful live apply marks only changed fields as session overrides. External
view-only/emulation changes invalidate drafts and update their sources; fields
untouched by an apply retain app/profile provenance. Drafts copy baseline/source
values and weakly reference the state. No new subscriptions, Tasks, actors or
background jobs are introduced by input persistence itself. Existing app/profile
editors use copied patches and their established store actors/operation ownership.
Tests use in-memory stores and loopback peers; no production preferences/profile
files are read or modified as test fixtures.


## Scaling persistence and initial presentation ownership (N4.7/N4.9 portion)

The scaling patch contains optional sizing text, a Boolean unit preference and a
closed filter token. Nested key/type checks run before Codable; resolved values
use the existing stateless core scaling parser and stable native filter mapping.
Explicit preference commits and profile upserts canonicalize present sizing text,
preserving absent fields. Reads never normalize backing bytes. History-only
mutations do not canonicalize profile payloads. App schema 4 reads 1–3 and profile
schema 3 reads 1–2; accepted writes advance schema/revision, while failed validation
and observed conflicts preserve data under the existing store guarantees.

Session initial scaling and its source dictionary are immutable value copies.
The desktop installs an explicit initial selection before replaying frame streams;
an absent initial selection preserves a host's pre-bind rendering configuration.
Connection scaling state weakly binds the session, initializes from the resolved
selection once, and ignores repeated binding to the same session so reconnect
cannot reset live overrides. It retains the existing weak desktop and synchronous
preflight/apply path. Only changed fields acquire session provenance. Drafts copy
baseline/source values and weakly retain their owner; stale binding/apply revisions
remain rejected. No new timer, Task or subscription is introduced.

Preference draft reconciliation adopts the canonical committed values only when
its current editable values still equal the submitted snapshot. The snapshot is
updated for every accepted result, preserving newer unsaved edits if present.
Existing profile mutation completion installs its committed canonical baseline.
Storage validation is syntax/policy admission, not a proof that a particular
physical display can render the requested dimensions; desktop preflight/fallback
and bounded visible rendering still govern presentation.

## Native desktop panning ownership (2026-09-19)

Pan offsets and directional availability belong to NativeDesktopView. Geometry
derives effective offsets and limits in the selected units using the shared
transform's backing dimensions and rounded canvas. Geometry updates clamp stored
offsets without recursively scheduling another render. New streams/generations
and detach reset pan; filter-only changes preserve it. Pending commands advance
desired geometry, while wire pointer coordinates use only the last presented
geometry until matching pixels arrive through the existing bounded scheduler.

NativeDesktopCommands routes pan through its weak host, rechecking connection,
sheet, visibility and edge availability at dispatch. Accessibility selectors use
the same view gate. No remote focus acquisition, synthetic input, new timer or
storage write is introduced. Direction changes reuse the existing coalesced weak
command-notification task. Accessibility actions advertise only available
directions and issue a layout notification when that list changes. Detach removes
pan actions, and tests verify that command/accessibility routing does not retain
the removed view after AppKit's deferred cleanup.

## Native fullscreen minimize operation (2026-09-19)

NativeDesktopCommands owns one optional minimize phase, weak target window,
generation/identity token and cancellable deadline task. It releases capture,
remote focus and local held state before requesting a fullscreen exit. Only the
owning window's exit notification may advance to minimizing; its minimize
notification settles the operation. The command gate suppresses duplicates and
modifier recovery, and NativeDesktopView gates focus/capture acquisition during
the transition, including first-responder callbacks.
Pointer/wheel/key/modifier and IME entry points reject pending-transition input
before mutating local state, even if an external caller restores core focus.

Detach, host replacement, session rebind/disconnect/close, window close and a new
fullscreen entry invalidate the intent and cancel the deadline. A newly attached
sheet also prevents the deferred minimize. The 15-second weak MainActor task
checks identity after its suspension, clears pending state and reports retry
guidance if AppKit never reports completion. It never holds a window/session
across suspension, polls, or starts an automatic retry. Deinit cancels pending
deadline/recovery tasks. Tests exercise late notifications, cancellation and
owner destruction; physical Spaces transitions remain unverified.

## Negotiated connection information ownership (2026-09-19)

ProtocolSession copies negotiated fields on its serialized executor into a const
shared SessionInformation payload. It has fixed-size fields and a 1025-byte name
array (1024 content bytes plus NUL); even scanning the remote name is bounded.
Queued events retain immutable observations under the existing event capacity.
Connection teardown clears current metadata, while already retained observations
remain valid. Last-encoding state belongs to each new protocol connection;
CopyRect leaves the last data encoding intact. Bandwidth uses the existing
connection-local estimator. Statistics and live-encoding observation updates reuse
the existing single cancellable statistics timer; no polling or new timer exists.

The additive C query copies all text and its matching snapshot under a retained
SessionEvents observation. It validates output headers, handle kind, generation
and connected state, preserving outputs on failure. There is no returned handle,
borrowed pointer, endpoint, credential, certificate or path. The fixed credential-
security flag is the existing authentication-policy result, not a transport or
identity-verification assertion.

NativeConnectionInformation owns copied Swift strings/values. It is nested in the
published NativeSnapshot so metadata and counters produce one deduplicated SwiftUI
invalidation; a mapped replaying stream does not add an observation owner. Metadata
from operation-completion snapshots is optional; current published information
comes from the dedicated generation-checked query. Redacted diagnostics use only
static protocol/security/encoding descriptions and numeric fields. The sheet's
explicit copy button writes this redacted value; automated tests do not write the
user's pasteboard. Existing presentation tests enforce that image delivery alone
adds no SwiftUI invalidations.

The native CMake graph also watches the C ABI/keymap headers and module maps and
propagates their combined content hash as a public Swift compile option. This
invalidates downstream Swift objects when imported C layouts change, including
the separately exported Xcode application. A normal-build test crash reproduced
with a stale consumer object and disappeared after recompiling both modules;
the dependency fix makes that recompilation automatic. No runtime hash/state or
stored preference is involved.

## Connection statistics overlay (2026-09-19)

Visibility is a transient published Boolean owned by ConnectionModel. It is
independent for each window and cleared on non-connected snapshots and immediately
on requestClose. Showing requires a live connected information value and no busy/
closing operation; hiding remains possible while busy. The native context menu
uses its existing weak model closure and rechecks this gate at invocation, so an
old menu cannot expose stale observations after disconnect.

ConnectionStatisticsOverlay is a value-only consumer of the existing immutable
NativeConnectionInformation in the session snapshot. It has no observer, timer,
Task, session/window reference or stream subscription. The parent uses SwiftUI's
overlay modifier so statistics cannot change desktop geometry. Hit testing is
disabled, leaving pointer routing intact; the combined accessibility element
explains the menu toggle. Native snapshot publication remains the sole update
cadence. Disconnect removes the overlay, and reconnection starts hidden.

Loopback command tests cover idle/busy/closing guards, context dispatch and checked
state, view-only use, model isolation, stale menu actions, disconnect and reconnect.
Light/dark render fixtures at 320- and 640-point widths cover layout. UI automation
inventory succeeds, but selecting the running app still reports “Sky Computer Use
native pipe closed before response”; physical interaction/VoiceOver remains open.

## Structured native errors and retry ownership (2026-09-19)

NativeConnectionIssue is a Sendable value chosen only from terminal reasons,
operation results and typed ABI statuses. It carries no remote error strings,
endpoint, credential, certificate or filesystem path. Unknown errors map to fixed
text. Socket errno interpretation is confined to connection/transport failures;
DNS native codes cannot accidentally select a privacy category. EACCES/EPERM
produce conditional policy guidance; route failures remain routing errors.

ConnectionModel observes terminal snapshots so peer closure after successful
connection cannot disappear without an alert. It reports at most once per current
generation. Connect starts a new retry context; cancellation and requested
disconnect suppress connection alerts. Close clears presentation, retry intent and
the copied endpoint immediately. The retry record holds only a copied issue, UUID
and generation; no Task, session, window, subscription or credential ownership is
added. The existing snapshot subscription retains its weak model closure.

Retry validates the problem UUID, current session generation, unchanged endpoint,
ready defaults, terminal state and non-busy/non-closing model. It calls the normal
connect path, with no automatic reconnect or retained authentication response.
SwiftUI alert dismissal can precede a button callback, so hiding presentation and
revoking intent are separate: automatic hiding clears only the matching visible
problem; Cancel explicitly revokes the matching intent. Old alert callbacks cannot
hide or retry a newer failure. Live refresh errors check their captured generation
and cannot replace a terminal connection problem.

Real loopback tests cover repeated refused attempts, edited addresses, stale retry/
dismissal, automatic hiding before Retry, two-window isolation, unsolicited peer
closure, no automatic reconnect, authentication cancellation, requested disconnect
and immediate close. Classification tests cover every terminal reason, socket/DNS
code domains, operation outcomes and redaction. Physical alerts and VoiceOver are
still unverified; the last UI connector attempt failed before app inspection.

## Canonical credential identity ownership (2026-09-19)

The additive endpoint create/get API owns a const shared-parser Endpoint in the
existing typed, bounded reference registry. Creation validates bounded UTF-8 input
and route identity, performs no IO, and returns one reference. Get borrows spans
only while the caller retains the handle. All outputs remain unchanged on failure;
released/wrong-kind handles are rejected. Retained values are independent of the
input buffers, and immutable getters may run concurrently. No runtime/session,
protocol worker, callback or platform type is introduced. ABI export count is 63.

NativeCredentialKey bounds endpoint, route and username before copying, validates
password-only's explicit empty user, and rejects non-authentication/negotiation
wrapper types. The caller supplies the actual negotiated method and credential
shape; construction does not negotiate or authorize reuse. The temporary endpoint
handle stays alive around all borrowed-span consumption and hashing, and is
released on return/error. The value retains only a versioned SHA-256 account.

The v1 digest input is a sequence of 32-bit big-endian byte lengths plus fields:
service namespace, transport (32-bit big-endian), canonical host, exact IPv6 scope,
port (32-bit big-endian), exact Unix path, exact non-secret route, security type
(32-bit big-endian), credential shape (1 password-only / 2 username-password,
32-bit big-endian), exact UTF-8 username. The account is v1: plus lowercase hex.
Service is io.github.jkeli.tidyvnc.credentials.v1. This format must be versioned
before any future incompatible normalization/serialization change. It does not
resolve DNS, collapse aliases/scopes/symlinks or normalize Unicode. Description
and debugDescription redact the account; no original identity fields remain in
the value. No password, Keychain operation, save policy or automatic reuse exists
in this implementation. Later reuse must separately verify supplied server trust.

The original fixed-array C output was rejected by Swift's importer at the required
4097-byte field size. The final owned-handle/span form uses established bridge
ownership and keeps the full 4096-byte limits. Authentication render coverage also
exposed the SDK 27 State macro selection in the Command Line Tools compiler. A
private typealias explicitly selects the macOS 14 SwiftUI property-wrapper type,
preserving field-state semantics without requiring an unavailable macro plugin.
The sheet's security indication is now about credential protection; anonymous TLS
and other modes mean the existing isSecure flag is not a transport-encryption
boolean. Render fixtures cover both policy states and optional username fields.

## Native credential store ownership (2026-09-19)

NativeCredentialStore owns one synchronous backing behind a serial utility queue.
The actor bounds accepted work to 16, with one cancellation gate per operation.
Queued cancellation/close prevents backend execution; once execution begins the
actual result wins over task cancellation. Unknown backing error text is discarded.
Close shares one task, rejects new work, cancels queued work, waits asynchronously
for accepted results and crosses the serial queue before declaring drain complete.
No window, session, prompt, UI callback or global secret cache is retained by the
store. Running synchronous OS work is not forcibly interrupted.

NativeKeychainBacking has immutable client/service state and fresh per-call query
and LAContext values. Calls explicitly choose Data Protection, local-only generic
passwords, the app service and exact opaque account. Create/replace are separate
single operations, without delete/readd or upsert retry. Metadata requests only
attributes and validates returned service/account/date values; listing is bounded
and exposes truncation. No global interaction flags, shared access group, biometric
requirement or plaintext fallback is introduced. See KEYCHAIN.md for policy and
signing prerequisites; fake SecItem tests do not prove real OS authorization.

NativeCredentialSecret owns one lock-protected raw allocation (up to 4096 bytes).
Inout input is wiped on successful or rejected construction. Copy access is
explicit and caller-owned; clear/deinit uses memset_s on the unique allocation.
No pointer escapes, no secret appears in descriptions, and no observable/Codable
secret value is introduced. Temporary Foundation/Security/caller copies are not
claimed to be reliably zeroized. Save borrows a bounded copy and preserves the
caller's retained value; the authentication retention controller must own expiry.

Tests cover exact query/interaction policy at the call boundary, explicit create/
replace outcomes, scoped delete, bounded metadata, malformed output, error mapping,
owned input clearing, redaction, actor-to-adapter routing, MainActor responsiveness,
queue saturation, pre-admission/queued cancellation, successful completion after
cancellation and idempotent asynchronous close. No real Keychain entries were read,
created, replaced or deleted. The inspected Debug bundle has get-task-allow only,
so provisioned identity/upgrade acceptance is still required.


## Authentication retention integration (2026-09-20)

The protocol worker calls credentialsForSecurity with csecurity->getType at the
credential rendezvous. PromptAuthentication owns that immutable method value;
tidyvnc_prompt_security_type exposes it without extending the existing prompt-info
layout. Default forwarding preserves existing SessionAuthentication implementations.
The Swift prompt copies the negotiated method before releasing its C handle.

AppCoordinator owns one NativeCredentialStore. Each ConnectionModel owns one
NativeAuthenticationCredentials controller and forwards current snapshots to it.
The controller weakly references the session, privately owns at most one pending
and one retained secret, and publishes only status/availability. Submitted input
arrays are cleared on success and failure. Default use-once values clear after
protocol submission; retained values become reusable only after matching-generation
Connected. Unexpected interruption may retain them for explicit same-key reconnect;
manual cancellation/disconnect, rejection and close clear them. Endpoint changes
clear retained values before another attempt. No automatic credential submission
or static cache is introduced.

Remember/replace pending values transfer to one async task only after Connected.
That task owns the value until the store returns, then clears it. A window close
cannot wipe a buffer beneath a running backend call: it cancels admission and
awaits the task. Store mutations retain their actual committed outcome. Shared
store close runs after the app's window controllers drain. Explicit lookup/delete
use the current prompt-derived key and per-call interaction policy. A late lookup
checks epoch, request identity, generation and cancellation before submission;
all discarded results clear their owned secret. Async closures use weak controller
references and cannot restore state after stop. UI password strings are reset on
submission/disappearance; runtime/OS zeroization limits remain as documented.

Loopback tests exercise all three lifetimes, actual rejected authentication,
use/replace/forget, isolated windows, delayed authentication success, delayed
lookup cancellation and window close during blocked save. Backends are injected;
there is no claim of real Keychain authorization or OS-prompt cancellation.


## Shared trust policy and native presentation (2026-09-20)

CertificatePolicy is a stateless, allocation-free classifier. It factors the
retained CConn exception mask into shared core code; unknown/fatal status bits
remain non-overridable. PromptAuthentication enforces the same rule while checking
an affirmative trust response, under its existing small state lock. A denied
approval leaves the outstanding request intact for cancellation. No identity,
store, GUI callback or new mutable global belongs to the classifier.

The new policy C query copies plain values and preserves caller output on failure.
Swift copies typed reason values, parses certificate data through Security solely
for presentation and computes fingerprints over the already owned bounded identity.
It does not change GnuTLS verification, CA/CRL loading or OS trust. The RSA-AES
compatibility fingerprint is distinguished from SHA-256. Debug descriptions redact
identity data. The trust sheet makes Cancel the default and disables affirmative
actions for fatal/unknown status or undecodable certificates. Existing prompt ID,
attempt generation and cancellation checks still govern the actual reply.

No exception store is added in this step. Existing x509_known_hosts behavior in
CConn remains host-scoped through GnuTLS; the native adapter and explicit scoped
persistence/changed-key work remain open and are documented in TRUST.md.


## Read-only legacy certificate exceptions (2026-09-20)

CertificateKey uses per-call GnuTLS initialization and a private custom verification
backend; callback context, exact DER SPKI and digest output are owned. No static
callback state, filesystem operation or UI type enters the helper. Swift uses an
optional capability and typed registry ownership. CertificateKey and match debug
descriptions redact identity material.

NativeLegacyTrustStore serializes bounded synchronous regular-file reads on its
actor off MainActor. Path selection reproduces the retained TidyVNC state location
without calling xdgdirs' static buffers. The reader accepts legacy owner-readable
0644 records but rejects unsafe final file types/ownership/permissions/ACLs and
changes observed during reading. It has no write API and does not migrate state.
Malformed/unknown records fail closed rather than becoming a missing exception.

Each window has a NativeCertificateTrust controller with one task, a weak session
target, request/generation/epoch guards and joined close. A newer prompt cancels
and drains the previous lookup before starting another. Only the currently pending
certificate can reuse a matching prior host-scoped exception, after fatal/malformed
policy checks. Shared store close follows all window drains. Expected/received key
metadata stays in the trust sheet and cannot leak into credential identity or
cause automatic password reuse. Atomic revision-checked writes, durable recovery,
host-key storage and interactive OS acceptance remain separate unfinished work.


## Scoped certificate persistence (2026-09-20)

NativeTrustScope obtains canonical endpoint fields from owned C handles, hashes
length-framed fields in a separate X509-SPKI domain, and never normalizes route/path
bytes through Swift String equality. NativeTrustStore owns no mutable process global.
Its actor serializes read/compare/mutate calls and enforces a closed schema, private
bounded file and content revision. NativePrivateFile now accepts a fixed record kind;
profile and trust filenames/lock/temporaries remain separate. The new trust file is
under the retained XDG trust-state location, independent of preference/profile
migration and the unchanged legacy file.

A forgotten record retains only destination/suppression metadata, never the old key;
this prevents broad legacy fallback from silently restoring removed trust. Read
failures likewise do not fall back. Core verification and fatal-status policy run
before exception reuse; ordinary CA success does not consult these overrides.

MainActor window controllers capture the attempted endpoint and keep one task with
request/generation/epoch checks. Explicit writes compare the revision actually shown
in the sheet. A committed save is not rolled back on cancellation, but its result
cannot approve a stale or closed prompt. Post-rename errors reconcile exact bytes
and report uncertain durability; no automatic retry or current-prompt approval.
The management library serializes explicit forget operations and requires reload
on conflict. Window/library close joins operations, then AppCoordinator closes the
shared trust actor. No file locks are held across UI or a protocol prompt wait.

Physical confirmation, keyboard/VoiceOver and native TLS acceptance remain open.
The new store does not implement RSA-AES persistence or CA/CRL selection, and no
claim is made that non-cooperating external writers honor its advisory lock.


## Dedicated RSA-AES trust (2026-09-20)

rfb/RSAAESKey adds stateless, allocation-free encoding/number validation shared by
the protocol and host reply boundary. No mutable globals, callbacks or crypto
initialization are introduced. The parser preserves byte-rounded lengths emitted
by the retained server and reports actual modulus size. Its bounds/type gate is
available in non-crypto builds through one new C ABI feature/export. Nettle key
preparation and the existing RSA-AES exchange remain responsible for protocol
cryptography; syntax acceptance is not proof of private-key possession.

NativeTrustStore is fixed to one immutable kind. Certificate scope/file encoding
remains v1-compatible; RSA-AES gets a distinct domain, explicit file kind, hostKey
field and independent fixed private-file/lock names. Mutations reject wrong-kind
scopes, and host records validate encoded keys on load. Native per-window routing
chooses the host actor only for HostKey prompts and never falls back to the legacy
X509 reader. Separate management clients and both stores drain on app shutdown.
Fingerprint presentation derives both algorithms from owned bytes; callback display
strings cannot substitute for actual key fingerprints. New public fixtures retain
no private key, and tests touch only temporary/injected stores.


### Explicit native CA/CRL file configuration

Native defaults/profile trust-file patches are immutable values at session creation.
Absent fields inherit, empty fields deliberately select no additional file; exact
absolute paths are copied through the C bridge. There is no process-global selected
path, implicit XDG import or system-root mutation. GnuTLS loads files on the protocol
worker at each X509 attempt. The bridge enables the new value-only
`ClientTLSOptions.requireConfiguredFiles` policy; retained parameter consumers keep
its false compatibility default. Missing/empty/malformed/wrong-kind files fail
before prompts, and fatal revocation remains non-overridable at reply/storage
boundaries. Preferences/profile actors retain their existing revision, cancellation
and close semantics. File selection is asynchronous; stale/dismissed picker results
cannot change a later draft. Local path persistence is not sandbox bookmark support,
a content pin, or a guarantee that external files will still be accessible later.


### Native security method configuration

SecuritySelection owns its method list and reads only immutable compiled
SecurityClient::supportedTypes, with a function-local immutable catalog initialized
thread-safely. Canonical names/IDs share the retained protocol table. It does not
read the mutable legacy SecurityTypes parameter; tests mutate that parameter and
verify independent concurrent selections. Two stateless C exports copy fixed-size
results and catch allocation/validation failures. Swift stores canonical tokens,
resolves defaults/profile whole-list precedence, and captures IDs/source before
session construction. Saving never mutates a running worker's policy. Empty lists
deny all rather than falling back. Unknown/uncompiled persisted methods block a
read and preserve bytes. Per-window reconnect editing remains open and must not
introduce shared security or credential state. Method categories do not replace
protocol isSecure(), certificate/key verification, or credential assurance rules.

### Advanced TLS priority (2026-09-20)

The native `security.tlsPriority` patch is owned text: nil inherits, empty resets to
library defaults, and profiles override independently from the security method list.
Preferences/profile actors use shared stateless GnuTLS preflight on reads and before
writes; view validity only checks text bounds/NUL. Preflight owns a private cache and
balanced library initialization, never modifies `Security::GnuTLSPriority`, and may
read library configuration. Session creation copies the value/source; actual TLS
configuration remains on the protocol worker. Per-window snapshots are immutable
across subsequent settings saves and reconnects. No credential or trust state is
added, and parser success is not a handshake or server-identity guarantee.

### Disconnected security replacement (2026-09-20)

SessionWorker owns an immutable security policy behind its command-admission mutex,
with a monotonic revision. Getter snapshots retain the old policy independently.
Setter admission compares revision/generation and excludes every active attempt,
including setup, authentication and terminal drain. No protocol object is mutated
by the caller; the worker installs the accepted snapshot before preparing the next
attempt. Session mailboxes and counters survive; connect/close races reject safely.
The native actor preflights before the synchronous commit and checks cancellation.
The controller joins editor cleanup before reopening or Connect and clears retained
reconnect credentials/trust-attempt state after success. Initial NativeSession values
remain immutable restoration baselines; they no longer imply that explicit local
security edits are forbidden. Defaults/profile saves still cannot mutate a window.

### Shared-session and Retry options (2026-09-20)

Shared access is a session-owned Boolean with generation/revision CAS under worker
admission. The worker installs it before each new CConnection; no legacy `shared`
parameter reads occur. False preserves the retained default. Initial app/profile
values and sources are captured before connection. Native Retry policy is window-owned
and only gates the explicit error-dialog action; it never starts a reconnect loop.
Local editor commits update the host flag synchronously after core admission succeeds,
retain untouched field sources, reject stale/active edits and leave durable settings
alone. Old schemas cannot silently adopt the new fields; current writers are defaults
8 and profiles 7. New default/profile saves affect new windows only.

### Native remote layout ownership

The bridge now copies a complete SessionEvents layout/snapshot publication into
owned C/Swift values. Input spans never survive the call; worker commands own the
validated layout. Native resize drafts are per generation, with one controller
editor and joined cancellation before reopen. The explicit action never writes
preferences or profile state. Actual server topology is authoritative, and a
baseline comparison is observational rather than a protocol CAS. Automatic resize now has a session-owned coordinator with typed immutable policy,
a generation snapshot of initial size, one authoritative view identity and bounded
coalescing. Accepted manual requests inhibit automatic work until viewport changes.
Live policy updates compare a host revision. Core admission still enforces all
protocol constraints. Durable policy storage now resolves independent fields through defaults/profile
actors and snapshots per-field sources for each new window. Nil versus explicit
blank initial size remains distinct. Local updates preserve untouched sources and
never mutate durable records. Fullscreen multi-display mapping remains open.


## Shared monitor mapping and explicit native chooser (2026-09-20)

The pure display-layout C export borrows checked bounded monitor values and returns
an owned fixed-capacity layout; it has no global/session/OS state. It reuses the
retained `DesktopLayout` normalization algorithm. Swift converts UUID-identified
logical display snapshots to temporary mapping tokens and separately assigns RFB
identities, preserving existing IDs/flags where possible. No local UUID/index is
used as a remote identity. All failure paths leave output unchanged.

The remote-resize draft owns selected UUIDs, units and its reviewed topology
generation. Topology notifications invalidate submission, and Apply rereads the
source before admission. Missing explicit selections cannot silently fall back.
The app-owned display service is weakly referenced; draft subscriptions/operations
use the existing stop and joined-close lifetime. Custom requests remain independent
of monitor availability. Settings/profile schemas and user display settings are
unchanged. Fullscreen surface ownership, automatic multi-display mapping and
physical topology/Spaces acceptance remain open.


## Native shared canvas geometry (2026-09-20)

The two new canvas geometry exports are pure value operations, using the retained
DesktopTransform for whole-canvas fitting, region placement, pointer inversion and
damage halos. Existing window entry points share their output helpers; no global
state or alternate scaling implementation is introduced. Canvas values carry an
explicit unit choice and bounded enclosed region. Native pan limits use the whole
canvas. Candidate canvas changes validate geometry/tile budgets before mutation,
then use existing asynchronous pixel/geometry publication and session-owned renderer
cleanup. A canvas surface cannot claim or publish ordinary window-resize ownership.

Two AppKit views and loopback input verify distinct regions, coherent delayed
changes, source damage and joined close. Native fullscreen surface ownership,
shared focus/commands/pan and automatic multi-display resize integration remain
open; these tests do not establish physical Spaces or keyboard-capture behavior.


## Scoped native desktop focus and command hosts (2026-09-20)

NativeSession owns one optional surface UUID for native focus. Transfer sends focus
loss before gain, releasing shared wire input and invalidating pending clipboard
routes even if the final Boolean is again true. View-local input/composition and
capture clear on losing ownership. Native input and shortcut routes admit only the
scoped owner; background view events and capture/status callbacks cannot mutate the
new owner's route. Explicit global focus APIs remain compatible, with live-view
revocation of unscoped focus; delayed deinit never revokes an unowned interval.

The command registry stores only weak view references. Registration preserves an
existing active host, focus activates a host, and detach selects a surviving host
without acquiring focus. Generation/disconnect/close clear focus tokens. Deferred
cleanup checks its UUID, protecting a replacement owner. Tests use independent
loopback peers and injected capture/window backends; actual multi-monitor pointer
focus policy, Spaces and physical capture acceptance remain open.

## Shared native canvas intent (2026-09-20)

NativeScalingState now keeps weak registrations for all views, validating each
independent view and each canvas group before publishing a new value/revision or
source. NativeDesktopCanvas keeps weak views and session/scaling references, owns
copied display snapshots and one pan offset, and uses retained shared geometry for
whole-canvas clamping. It preflights all member geometry/tile budgets before an
explicit topology or pan change. Scaling changes recompute logical/device regions
using the retained fullscreen unit policy. Detach does not reflow surviving
coordinates; topology replacement is explicit. Current frame dimensions, rather
than callback ordering, determine the common pan limit.

Stop/close/deinit release group membership and restore window geometry. Deferred
cleanup carries an owner UUID, preventing an old group from clearing replacement
ownership. Per-view asynchronous pixel/input publication is unchanged; no atomic
multi-window presentation barrier is claimed. The coordinator does not create
windows, own Spaces, choose the post-fullscreen resize owner or send complete-layout
automatic resize requests. Those integration requirements remain open.

## Native fullscreen window-owner prototype (2026-09-20)

NativeFullscreenController owns only its dedicated AppKit windows, views, canvas
and a cancellable transition deadline. Session/source/settings/command/display
references are weak. It preserves the original SwiftUI window delegate and uses
delegates only on owned windows. Entry records a source owner token, releases held
input and blocks the source from regaining focus or sending input until restored.
Hidden owned surfaces wait for completion; all native callbacks are checked against
the current owned primary window. Old/unrelated window callbacks are ignored.

Failures, deadlines, topology changes and connection/window closure synchronously
detach owned views and dispose owned windows. Deferred destruction uses MainActor
cleanup and checks the source owner token before restoration. Shared renderer
cleanup remains joined by session close. Display UUID resolution and frame/scale
revalidation use fresh NSScreen values; no monitor index is persisted. Both window
strategies remain explicit prototypes pending physical comparison. App integration,
saved fullscreen policy and complete-layout automatic resize remain incomplete.


## Fullscreen comparison routing and physical work-area fix (2026-09-20)

The developer-only fullscreen comparison app owns an isolated loopback session,
peer, display/input/scaling/command services and a NativeFullscreenController. It
loads no stored endpoints, preferences, credentials or trust; clipboard and automatic
keyboard capture are disabled. Quit joins operation/session/runtime cleanup. Hidden
construction verifies real pattern pixels and renders both appearances without
requesting Spaces. Interactive diagnostics record only fixture state in TMPDIR.

Commands now hold a weak fullscreen owner plus an identity token and phase
subscription. Exit routes to that owner; entry may use a frontend policy callback.
Cleanup/destruction clears only matching ownership. Existing ordinary native
fullscreen exits before the entry callback. Transition commands are gated, and
owned multi-window minimize/fit remain disabled until their integration is defined.

Actual native Space entry changed NSScreen.visibleFrame and previously caused
false topology cancellation, leaving an empty transition window. Fullscreen now
compares stable display identity, full bounds, scale and primary status, excluding
work area/name. The display service continues publishing complete snapshots for
windowed consumers. Tests cover changed work areas during entry and active display,
while real topology changes still trigger cleanup. Single built-in Retina native
entry/menu-shortcut exit and borderless entry/menu exit were observed after the fix.
Synthetic Control–Option–Return from the UI automation tool did not trigger exit;
physical shortcut acceptance, multiple displays and final strategy selection remain
open. This does not complete N4.8/N5.7 or change the shipping app's fullscreen policy.


## Owned fullscreen minimize handoff (2026-09-20)

NativeFullscreenController owns a pending minimize intent and connection generation.
The command target remains the active fullscreen surface during native exit;
temporary owned windows never minimize. Only the current primary's successful
exit (or synchronous borderless cleanup) may hand the request to the restored
original command host. The original window must still be minimizable, attached to
the same source/session, outside native fullscreen and free of sheets; the owned
surfaces must also be sheet-free. Routing commands outside the owned group cancels
the intent.

The handoff reuses NativeDesktopCommands' existing completion notification,
input/capture gates, deadline and retry guidance. A new fullscreen entry cannot
race that operation. Failure/deadline, topology change, close, destruction, stop or
disconnect uses ordinary restoration and drops the pending request. Late callbacks
cannot carry an intent into a later fullscreen generation.

Loopback tests cover native completion ordering, original-window capability and
sheet gates, held-key release, duplicate/unrelated/late callbacks, borderless
cleanup, sheet arrival during exit, native failure, deadline, topology change,
disconnect and reentry while minimizing. Interactive tests additionally recorded
NSWindowDidMiniaturizeNotification with original.isMiniaturized=true and subsequent
deminiaturize=false for each strategy on the built-in Retina display. The UI
automation's next observation reactivates/restores the app, so notification evidence
is retained separately in /tmp/tidyvnc-owned-minimize-live.log. No final multi-monitor
strategy or shipping application integration is inferred from these checks.


## Connection-owned fullscreen presentation state (2026-09-20)

NativeFullscreenState belongs to ConnectionModel; services, source view/window and
session references are weak. It owns its controller and pending presentation intent.
The native view holds the state weakly and reports attach/detach/window movement.
Entry callbacks carry an identity token so obsolete state cleanup cannot remove a
replacement's policy. Source window collection behavior has a corresponding owner
token; deferred deinit restores only its own behavior. The original SwiftUI window
delegate is never replaced. Owned key-window callbacks route the global menu back
to this connection through a weak app/model activation closure.

A single deferred settings callback retains only the model's weak retry closure.
It runs after controller cleanup, only for the same connected generation and visible
source window without another sheet or pending minimize. Close/detach/stop/rebind/
disconnect cancel it. The normal model editor guards run again on retry. Error
alerts are gated until windowed restoration; statistics actions use the windowed
host. Pending native transitions remain bounded by the controller deadline.

Display drafts copy baseline selection/revision/generation and observe immutable
screen snapshots. Apply performs a fresh topology read and rejects changed drafts
or unreviewed arrangements. Missing IDs are retained independently of fallback;
selected display count/identity bounds and shared layout validation apply. No new
durable schema or C ABI is introduced in this step. The provisional native-Space
app policy, durable defaults/profile/CLI sources, reconnect layout restoration,
fullscreen statistics surfaces and physical end-to-end acceptance remain open.


### Fullscreen policy and automatic entry ownership (2026-09-20)

Saved fullscreen patches contain only optional startup, mode and bounded stable
IDs. Per-field sources are captured with the immutable initial session policy.
The live owner separately retains reconnect intent, next-attempt override and
attempt generation; current policy does not mutate other sessions or storage.
An explicit exit clears intent before native completion. Network teardown preserves
active intent through an explicit controller end reason; cleanup order among
Combine subscribers cannot turn network loss into a user exit.

Automatic entry holds a cancellable MainActor task and generation/UUID ticket.
It needs the same connected session/source/window, visible foreground key host,
no sheet, ordinary fullscreen or minimize. Ineligible tasks leave intent queued
for activation/key/deminiaturize/sheet-end notifications. Entry consumes the ticket
before requesting a Space; failure cannot loop on notifications. Source detach,
stop, close, replacement and explicit windowed/settings return revoke intent.
Current/all modes keep inactive selected IDs; fallback does not mutate saved IDs.
Defaults/profile codecs reject malformed fields without rewriting old records;
only an explicit save upgrades defaults to schema 10 and profiles to schema 9.
C ABI remains unchanged at 82 exports. Physical multi-monitor acceptance remains open.


### Automatic fullscreen remote layout ownership (2026-09-20)

NativeRemoteResizeCoordinator now retains an ordinary viewport owner plus an
optional exclusive canvas owner/geometry. A reserved canvas with no layout or
available=false suppresses window requests. Ordinary attachment cannot replace the
remembered window while a canvas owns geometry; stale updates/end calls are token
checked. The canvas itself retains only weak desktop members and a weak coordinator.
Its destruction schedules owner-checked cleanup after leaving surviving members.
Explicit detach marks the group unavailable rather than silently reflowing it.

NativeFullscreenController claims the canvas before surface construction, enables
it at completed activation, and disables it before native exit. Cleanup leaves
members while the canvas lease still blocks transient ordinary ownership, releases
that lease, disposes temporary windows and restores the original viewport. Original
source input/fullscreen ownership also suppresses its automatic updates throughout
the transition. Minimize restores resize availability only after the original
window is available; timeout/completion refreshes current availability.

Resize Target now owns the complete immutable display mapping and source UUID as
well as generation/policy revision. Fresh remote layout mapping retains server IDs
and flags. One operation still drains before a latest-layout follow-up; cancellation
cannot retract wire output. Errors from retired geometry owners do not reset a
replacement's attempt state. Explicit initial sizes remain one-screen requests;
manual/initial holds expire on changed eligible geometry. Manual admission clears
prior attempt suppression so a later return to that geometry can resize again.
No new C exports, durable fields, timers, frame subscriptions or wire message types
are introduced; shared 100 ms scheduling and existing policy/capability gates apply.


### Fullscreen statistics presentation lifetime (2026-09-20)

The fullscreen controller now consumes information from its existing session
snapshot subscription. It checks the attempt generation and retains only the
copied NativeConnectionInformation value. Disconnect/stop clear visibility and
cached values; temporary surfaces remove hosting views before window disposal.
No new sampling timer, frame subscription, runtime/session owner or presentation
lease is introduced. A host owns only its value-only SwiftUI root, and information
updates reuse it instead of allocating a new host.

The connection model's existing visibility flag forwards to NativeFullscreenState
and its current controller. Toggle no longer uses deferred settings/Space exit.
Rebind/stop clear the state flag, and normal disconnect/close handling clears the
model flag. Entry/exit phase gates suppress overlays until a stable active group;
ordinary return preserves the connection's transient choice. Each fullscreen
content container keeps the desktop full size and statistics as a sibling, with
native pointer hit-test pass-through and no first-responder eligibility. Root/window
cleanup preserves existing detach, renderer-drain and resize-owner ordering.

### Shared connection-document codec (2026-09-20)

ConnectionDocument owns syntax records and performs no IO or parameter mutation.
Its static catalog and headers are immutable; independent parses/serializations
share no mutable state. Input size, line size and entry count are bounded. Errors
carry fixed reason text and a line number. Unknown values are decoded only when a
consumer understands the field, preserving compatibility without silently applying
future fields. Serialization only permits the explicit non-secret file catalog.

The retained adapter still owns its ParameterSnapshot and process parameters;
semantic application is transactional and remains confined to its host thread.
Its static returned servername buffer is a retained frontend compatibility API,
not part of the portable codec or a proposed native bridge. File handles use RAII;
output is fully validated before opening/replacing the destination. Existing
legacy migration exclusions and AtomicFile permissions remain in that adapter.
Native documents must resolve into immutable session configuration rather than
invoke loadViewerParameters. See DOCUMENTS.md for the remaining integration gates.

### Owned native connection documents (2026-09-20)

The C bridge registers immutable ConnectionDocument owners with normal handle
capacity/reference limits. Parse copies bounded input; metadata and entry APIs
copy caller-owned structs. Decoding makes a temporary bounded string and never
mutates a stored entry. Serialization owns its assignment copies and complete
result before writing any caller output. Allocation/validation/capacity failure
leaves handles, structs, result size and output bytes unchanged. Error details
contain only reason and source line. There is no runtime, callback or subscription.

NativeConnectionDocument adopts the handle before reading metadata and holds it
through all synchronous queries. Let-only copied metadata and the synchronized
registry make the Swift owner Sendable. Data/array spans stay inside borrowing
closures; no C pointer reaches stored Swift state. Partial initialization releases
its local owner. Native input size is bounded before UTF-8 validation, and export
uses a bounded flat input buffer and exact-size output Data. Concurrent readers
and independent exports are covered under normal/ASan/TSan verification. Settings
application, file IO/permissions and migration remain separate, unfinished layers.

### Connection-file semantic resolution (2026-09-20)

DocumentOptions reads immutable entries, invokes shared encoding/security/scaling
validators and uses context-free boolean/enum/list parsing. It never constructs
registered Parameter objects. BoolParameter and encoding now share the extracted
boolean token parser; existing global parameter ownership remains unchanged.
Retained file application validates first and then uses the original parameter
setter under its existing rollback snapshot. The C semantic query copies output
and catches typed line-tagged errors; no-write/unknown-field behavior is preserved.

NativeDocumentResolution owns the immutable document, final line provenance,
review notices and a private copied session configuration. It has no stores,
services, callbacks or observers. Unknown/macOS-inapplicable fields are not decoded;
known malformed/unavailable settings cannot be bypassed by review acknowledgement.
The host supplies stable display-ID mapping and a bounded absolute working directory.
Relative path joining performs no IO or symlink-sensitive lexical normalization.
Inactive cursor shape remains metadata for the future connection-window/export owner.

The candidate is unavailable until all ignored-field notices are acknowledged.
Acknowledgements are host input for this immutable resolution, not proof of human
approval; the future UI must tie them to preview identity and discard them when a
file is replaced. Default/profile/CLI store loading and native Open/Save/launch
integration are still separate work. No automatic migration or dual writer is added.

### Native document read and review ownership

NativeDocumentFileReader owns each regular-file descriptor/security scope for a
bounded read on its actor. NativeSessionDefaults owns one asynchronous load,
immutable review and retained accepted resolution for its connection. Review UUIDs
scope accept/cancel; no session exists before review acceptance. Reload/close revoke
old review authority, late read completions cannot publish after stop, and fresh
ordered display identities are revalidated before admission. Resolution metadata
precedes session publication so the document's empty or nonempty endpoint is in
place before Connect. AppCoordinator owns/cancels its sole Open panel; per-open
request UUIDs create separate windows. No new mutable global or preference writer
is introduced. Finder/CLI routing, write/export and persistent grants remain open.

### Finder launch routing

NativeDocumentLaunchRouter is main-actor app-owned state with a bounded pending
queue and one app-scoped SwiftUI window action. It validates each whole batch,
copies non-secret URL/invocation requests, removes entries before dispatch and
prevents reentrant drains. Replacement of a scene action does not replay work.
Stop clears both requests and the action, including when invoked during dispatch.
The callback captures only OpenWindowAction, not a ConnectionRoot or model.
Both modern URL and filename AppKit callbacks route into existing per-window
review; no file data, native-store writer or live-session restoration is added.
A real SwiftUI fixture verifies dispatch after closing every visible app window.


### History import presentation

`NativeHistoryImportState` is main-actor presentation state, owning one read/review/
commit at a time. Request and proposal UUIDs distinguish cancellation from approval;
cancelled IO remains retained until drain, and stale callbacks cannot mutate a new
review. Stop revokes delivery immediately and close joins before store shutdown.
Controlled errors never expose arbitrary backend strings. A commit accepted before
close remains in storage even though the closed view suppresses its result.

`HistoryImportWindowController` retains the state until drain. It reloads shared
recent history on success; its app owner reloads again after close to reconcile
uncertain or closed writes. `NativeRecentHistory` owns native snapshot eligibility
and launch-local offer dismissal. No compatibility history source is read at startup
or by eligibility checks, and no defaults state grants history consent. App quit
stops import callbacks and joins this controller before closing profile/history storage.


### Explicit-file monitor recovery ownership

NativeDocumentMonitorMapping owns bounded parsed-file/base/directory snapshots and
sparse integer-to-stable-ID suggestions. Numbers never allocate array extents;
manual UI is capped at 64 distinct numbers. NativeDocumentResolution validates exact
mapping keys and valid stable IDs while preserving all ordinary semantic validation.
NativeSessionDefaults retains the original context across editing, checks current
connected IDs at resolution, and requires a fresh final review identity for admission.
Manual admission checks the available-ID set; automatic admission checks legacy ID
ordering. Topology changes revoke review and can reopen mapping from retained data.
Stop/cancel/ready guards discard or reject recovery callbacks without modifying any
native store or source file, and no network session is created before final Open.


### Export monitor-number recovery

NativeDocumentExportCapture owns a prevalidated non-secret configuration value,
immutable encoding-option handle, endpoint/cursor metadata and display snapshots.
No session object, source document, credential, trust store or arbitrary file field
is retained. NativeDocumentExport requires exact mapping keys, positive Int32 values
and one distinct number per selected ID. IDs/names remain UI metadata; serialization
contains only canonical file numbers and the existing closed export assignment list.

NativeDocumentSaveState owns the capture until cancellation/write drain and keeps
one presentation identity while swapping mapping and review content. Each mapping
request and resulting export has its own UUID, so stale callbacks cannot authorize
replacement content. Resolution performs no IO or live-session reads. Approval of
the current export clears the sheet presentation and exposes its exact destination
choice ID; close cancels/joins through the unchanged writer boundary. The production
sheet fixture verifies one onDismiss handoff and no handoff on edit/cancel/close.


### Defaults-import display recovery ownership

NativeDefaultsImportProjection retains a filtered bounded document of allowed raw
entries, original line positions, redacted notices and origin. Unlike explicit Open,
recovery never retains the original document or excluded/unknown values. Projection
validates recognized fields before any chooser is offered; unavailable platform fields
remain opaque. NativeDefaultsImportMapping reuses the sparse bounded monitor helper
on that filtered document, and exact connected assignments produce a new candidate
and review UUID without source IO, store writes or omission acknowledgement.

NativeDefaultsImportState owns mapping/review/request identities. Editing drops the
old review, preserves connected explicit choices and resets UI acknowledgement.
Cancel/stop discard both mapping and review; late reader delivery drains before a
new request can start. Final commit checks ordered IDs for automatic mapping and
available-ID membership for manual mapping, then uses the unchanged absence-only
store transaction. Changes in availability fail before writing; same-ID reordering
is valid for explicit choices. Marker/default schemas and C ABI remain unchanged.


### Invocation syntax ownership and effects

core::splitParameterArgument is a side-effect-free extraction shared by the retained
registry and viewer::InvocationSyntax. The latter owns bounded copied strings and
source positions, not registry parameters or callbacks. Duplicates remain ordered;
no semantic validation or session authorization is implied. Encoding syntax comes
from the existing schema, with an audited CLI-only catalog and explicit capability
flags. Help/version preserve preceding assignments for later validation and discard
the unused operand. No environment lookup, file inspection/read, shell expansion,
logging, socket or settings mutation occurs at this boundary.

The C invocation object is immutable and registry-owned, with normal retain/release.
Returned operand/value spans borrow its storage while the caller retains it; source
argv spans are never retained. Catalog/name/metadata structs copy values and failures
do not partially publish outputs. NativeInvocationSyntax copies all spans into
Sendable Swift values before releasing the temporary owner. Invocation data can be
private; neither interface automatically logs or serializes it. Credential-file
paths are classified but not read or passed to Keychain. Bootstrap and typed
application are still required before the app can safely consume an invocation.


### Invocation value resolution and cross-layer compatibility

The immutable C invocation can now produce a separately owned canonical copy.
Decoded document-field validation is reused without serialization or file bounds;
raw syntax remains unchanged and every recognized occurrence is validated before
last-assignment folding. CLI-only native strings still require host admission.
NativeInvocationOptions releases C ownership after copying, and the native resolver
never consults global registries, environment, files or stores.

NativeOptionOverlay carries effective deprecated flags and inactive cursor shape
in NativeCompatibilityState. CLI migration is repeated after explicit file fields,
matching retained behavior until a file disables a flag. Effective input/fullscreen
provenance stays with the flag's source; source positions remain layer-local.
NativeDocumentMonitorMapping retains the original base and compatibility through
manual edits/recovery. NativeSessionDefaults resolves defaults/profile/CLI before
file IO and reapplies the same values against the fresh post-read display snapshot.
No session is published before CLI validation or required file review. ConnectionModel
uses file → CLI → profile endpoint priority and retains cursor metadata. Unsupported
adapters produce an explicit error; executable startup does not yet create requests.


### Deferred CLI fullscreen values across explicit files

NativeInvocationPreparation is internal and may carry NativeFullscreenOptions in
compatibility metadata. Its ordinary settings are validated before IO; pending
mode and numeric display values are not exposed as NativeInvocationResolution and
cannot become a NativeFullscreenPolicy until final display resolution. The file
loader captures this candidate once, reads the file, and uses fresh display order
and connected IDs afterward. It no longer needs to remap CLI values before reading
a file that can replace them.

Fullscreen field provenance is retained independently of numeric mappings. File
selection replaces old CLI numbers and host choices atomically; repeated migration
retains the effective all-monitor mode even when a later file only disables the
deprecated flag. Surviving CLI lists use the same sparse mapping context, immutable
review, exact UUID callbacks and connected-ID checks as file lists. Review state
copies actual resolved assignments and explicitly records manual/host mapping, so
reordering IDs cannot change a chosen display and disconnected IDs require recovery.
The unresolved candidate is discarded on close, never persisted or published as an
admitted session. C ABI and native storage schemas are unchanged.


### Native executable bootstrap and direct-launch ownership

NativeInvocationArguments bounds argc, every C string and total bytes before strict
UTF-8 decoding. The executable owns copied values, validates each occurrence and
handles help/version before creating AppCoordinator or stores. Error output never
reflects argument values. Host-only terminal strings remain literal. Ordinary launch
rejects unavailable native adapters before metadata inspection; stat distinguishes
actual Unix sockets from explicit files while preserving cwd/symlink semantics.
No content read, connection or store operation occurs during classification.

NativeInvocationStartup is MainActor-owned, process-local and consumed once. It has
no Codable/IPC/relaunch representation. Only the first ordinary connection receives
its request; profile/file events and subsequent windows retain independent ownership.
ConnectionModel schedules direct-host connection after synchronous admission and
checks session identity, address and canConnect again. Close or an address edit
revokes the pending attempt; terminal disconnect does not replay it. File launch
remains review → idle → explicit Connect. Successful direct connections use the
existing history writer, separately from side-effect-free CLI resolution.

NativeInvocationMonitorMapping holds an immutable prepared candidate, sparse numeric
selection and original provenance. No-file recovery validates exact assignment keys,
currently connected IDs and mapping UUID before publishing a session. Cancellation,
retry and close cannot revive stale callbacks. Accepted mapping resumes the original
host attempt or an idle no-host form. No source/store reread or persistence is
introduced by mapping. Existing explicit-file precedence/review guards remain.

Isolated SwiftUI fixtures exercise custom-main entry, StateObject construction,
first-window consumption, local-peer connection, file review and new windows after
zero-window closure. These use memory backing and do not instantiate production
user stores. The actual built executable is separately checked on terminal-only
paths under isolated HOME/XDG. This evidence does not establish installed
Finder/LAN/privacy, physical multi-display, other OS/architectures or the remaining
CLI/authentication/listen/tunnel adapters.


### Per-session outgoing IPv4/IPv6 policy

NativeInvocationPreparation overlays UseIPv4/UseIPv6 onto a copied NativeNetworkPolicy
and records each supplied field's command-line provenance. NativeSession captures
both policy and sources as immutable values, then fills the existing size-checked
C connect options for every attempt. The shared connector already owns the copied
flags, restricts DNS families and rejects disabled numeric families. No registry
parameters or mutable process-global defaults are touched. Both disabled is allowed
for Unix endpoints; TCP is rejected before submitting an attempt. Reconnect and
address changes do not reset policy or borrow it from another session.

Document resolution and monitor recovery preserve the configuration's policy. The
compatibility format has no network-family fields, so raw UseIPv4/UseIPv6 entries
remain unknown/ignored with review. Export always discloses omission of IP-version
settings, including built-in values that can differ from the receiving viewer's.
Live export captures the current session policy; acknowledgement never writes the
unsupported fields or alters native preferences. No schema/ABI change or incoming
listener behavior is introduced.

NativeInvocation.NetworkFamilyPolicyAndWire covers per-occurrence validation,
field provenance, CLI/file policy retention, actual IPv4 and IPv6 numeric and
localhost connections, three concurrent independent session policies, reconnect,
disabled-family errors, Unix operation with both flags off, production-model direct
startup and reviewed-file connection, and export omission acknowledgement. Peers
bind only loopback or a unique temporary Unix path and remove their own sockets.


### Worker-owned pointer-event timing

PointerEventPolicy.h supplies one retained/native default constant (17 ms).
ProtocolSession accepts a copied interval through SessionTiming; SessionWorker
transfers its owned creation option. Existing low-level callers retain zero-delay
behavior. The bounded scheduler now has five slots, with exactly one pointer timer
and one pending command. Motion replaces that value without postponing its deadline.
Button/wheel transitions bypass timing and update the value for an existing timer,
preserving the retained deadline rules. Keys flush pending motion to preserve the
native mailbox's motion-before-key order. Timing runs after middle-button emulation
so drag origins and synthesized transitions are not collapsed before emulation.

Callbacks validate publisher/input generation, routing revision, connection, focus
and view-only state before using the pending command. Release/revision barriers,
held-key overflow and finish reset both pointer and middle-button state. Focus or
policy transitions invalidate producer revisions immediately, so dispatch before
the worker drains a release barrier still cannot send old motion. Close/reconnect
cancel tokens before connection destruction; no host/UI timer or global list is used.

INPUT_TIMING adds size/version/reserved-checked default initialization and creation
with copied interval plus existing encoding options. Bounds are 0 through INT_MAX;
invalid inputs leave output handles unchanged. Old creation exports delegate with
zero delay, preserving their prior behavior and layouts. NativeRuntime requires the
new feature and NativeSession copies shared defaults, explicit interval and source
before creating the handle. CLI values are validated per occurrence. File overlays
and monitor recovery preserve the policy; Save As acknowledges its unsupported
format omission. No schema or stored preference is added.

Deterministic fake-clock tests prove first-deadline coalescing, latest-position
publication, button/wheel delivery, key ordering, post-emulation scheduling, zero/
maximum bounds, independent sessions and no stale motion across routing/attempt
lifetimes. C/C++ ABI consumers verify initialization, bounds, invalid headers/types
and unchanged outputs. Native wire tests use long-delay versus zero-delay local
sessions to prove creation, isolation, release/key flushing and reconnect retention
without relying on a narrow wall-clock timing assertion.

## Native incoming clipboard limit (2026-09-20)

The retained reader registry and value-only ClientMessageLimits now share one
256 KiB default. Native CLI MaxCutText becomes an immutable UInt32 plus provenance,
validated through INT_MAX by both invocation and the checked MESSAGE_LIMITS C
creation API. SessionWorker copies the reader policy and reuses it across attempts.
No global mutation, UI-side protocol parsing, pointer borrowing or new store field
is introduced. The existing protocol cap remains distinct from clipboard UTF-8
text/retained-byte budgets and outgoing offers. Explicit files cannot overwrite it;
compatibility export discloses omission. Native wire tests distinguish reader discard
from retained-text rejection and prove recovery, zero/boundary behavior and reconnect.

## Initial native window placement (2026-09-20)

WindowGeometry replaces retained sscanf geometry conversion with one checked parser
and a stateless C export. Native CLI values become immutable session policy/source
metadata, preserved through file/display review without process-global configuration
mutation. NativeWindowStartupState owns a weak ordinary window, one admission/attach
decision and notification cleanup; close revokes pending placement. It never mutates
a window after consumption, including reconnect and fullscreen exit. Fullscreen entry
waits for initial placement. Coordinates and work areas use AppKit logical points;
retained signed/trailing-text grammar is preserved while overflow is rejected. No
protocol-worker/AppKit cross-call, polling timer or window-delegate replacement occurs.

## Owned logging policy candidate (2026-09-20)

LoggingPolicy parses into owned rules and resolves against explicit immutable host
catalogs, returning a complete route table without reading/mutating legacy registries
or opening destinations. Every rule is validated before a result escapes, including
overridden rules. Unspecified writers reset to disabled; wildcard order, empty targets
and case-insensitive lookup preserve retained semantics. Checked decimal-prefix level
conversion preserves defined atoi behavior while rejecting overflow. Invocation value
validation now uses this parser for every Log occurrence, with fixed redacted failures
through the existing C ABI. Concurrency tests verify no global writer mutation; direct
differential tests use process-lifetime memory-only registry fixtures. Application of
routes, registry freeze/lifetime and redacted output are still separate unfinished
work. Native Log remains unsupported; no per-session global mutation is introduced.

## Redacted diagnostic sink (2026-09-20)

Logger's formatted entry is now virtual; its default implementation remains the
retained formatter. RedactedLogger intercepts before formatting. Its explicit event
table contains 89 current client/core templates and fixed output, with no argument
inspection for string/pointer fields. Unknown templates, raw preformatted text and
unknown source names cannot pass through. Three known keyboard-event templates emit
nothing. Twenty audited numeric metadata templates use bounded formatting with the
compiled original format; a static assertion limits these to %d/%x. Severity is
normalized to legacy error/info/debug. No raw exceptions, endpoints, TLS strings or
key values cross this adapter.

Construction captures gettext matches into owned immutable patterns before workers;
writes do not access locale or registry state. One sink lock serializes the borrowed
destination. The host must join writers before destroying the adapter/destination.
This implementation opens no files, registers no logger and changes no routing. It
is not yet activated by native startup. Process ownership and validated application
of LoggingPolicy routes remain unfinished, as does native diagnostic localization.

## Process logging startup ownership (2026-09-20)

Native startup now activates stderr/stdout through StartupLogging and the additive
PROCESS_LOGGING C API. The owner snapshots registered writer order after static
initialization. Duplicate names retain legacy behavior: first named match, all
wildcard matches. Targets remain unique. Every route and destination is prepared
before a nonthrowing commit to writer levels/pointers. Failures release staged
resources and leave routing/admission unchanged. Only final used destinations open.

One process mutex orders configuration against the runtime creation gate. Successful
configuration or that gate closes admission permanently; shutdown cannot reconfigure
logging. The gate creates no registry snapshot/destination for an old C caller that
never configures. The process owner is initialized before RuntimeService and is
destroyed after that service has joined workers; it detaches all owned bindings
before destroying sinks. Each stdio sink owns an fd >= 3 duplicate with close-on-exec,
without changing original descriptor status flags or repairing a closed standard fd.

The executable validates all Log occurrences, including before help/version, and
starts logging only after complete launch preflight. Default `*:stderr:30` matches
the retained viewer. This process policy is absent from session/defaults/profile
storage and is not replayed by connection windows/files/reconnects. Unknown writers
and unavailable destinations fail with fixed typed errors. File output is now
implemented as described below; diagnostic localization and installed launch
acceptance remain open. No C ABI struct or persistence schema changed.


## Native file logging (2026-09-20)

The file target now joins the startup catalog. The existing C configure call and
native executable use `/tmp/vncviewer.log`; FILE_LOGGING adds a copied absolute
host-path configure call at the same gate (100 exports). No file IO occurs until
the first emitted record, so validation/help/version and unused destinations do
not create/rotate files. The private sink validates owned single-link leaves,
rejects unsafe parents/extended macOS parent ACLs, removes file ACLs, sets 0600,
and keeps one backup. It pins the parent, uses no-follow leaf operations and
publishes without replacing unexpected entries. A persistent 0600 `.lock` sidecar
holds a nonblocking advisory lock through sink closure, after joined runtime drain.

A second cooperating process falls back to stderr; unavailable files and write
failures also switch once, with a fixed warning and redacted record. Tests cover
actual independent processes and preserve a prior owner's inode/bytes. Rotation
is not a multi-entry atomic transaction and noncooperating legacy writers are not
serialized. No size cap/periodic rotation, persisted path, session replay or native
path option is introduced. Diagnostic localization and installed acceptance remain
open; see CLI.md for the full failure and ownership contract.


## Password-file reply and native reader (2026-09-20)

Legacy password-file bytes cannot be safely routed through the native UTF-8
credential reply: decoded passwords may contain non-UTF-8 bytes. The additive
PASSWORD_FILE_REPLY call now consumes exactly one obfuscated block through a shared
caller-owned decoder, then checks a password-only prompt under the rendezvous lock.
Existing UTF-8 credential semantics remain intact. It clears bounded caller input,
decoded stack storage and bridge-owned plaintext on success and failure. The
existing codec entry point also clears its own temporary plaintext block. No
claim covers all crypto/OS/foreign-runtime copies.

NativePasswordFileReader owns scoped regular-file access off the MainActor, reads
only eight bytes, checks cancellation and metadata, rejects special/short files,
and returns a clearable obfuscated block. Swift forwards it without plaintext String
conversion. This adds one C export (101 total). Launch owner/endpoint scope,
environment precedence and pending-IO cancellation/drain still need integration;
native CLI PasswordFile remains explicitly unsupported until those gates exist.


## Launch credential ownership (2026-09-20)

Native launch now captures bounded VNC_USERNAME/VNC_PASSWORD byte copies once after
terminal/preflight handling. A single-claim owner transfers them and the resolved
PasswordFile policy only to the initial ordinary window. The initial resolved
endpoint binds before editable admission (or on first Connect for an empty form);
endpoint edits revoke the inputs. No later window rereads environment state.
Storage setup now snapshots only HOME/XDG path variables, avoiding whole-environment
Foundation string copies of passwords.

Current credential prompts apply environment precedence, require both variables for
username/password methods, and allow files only for password-only requests. A
matching nonempty explicit session cache precedes a file read. File errors leave
a fixed notice and explicit manual recovery. Automatic sources never access or
persist to Keychain. CREDENTIAL_BYTES preserves raw legacy byte pairs while the
existing text API stays UTF-8 (102 total exports).

Owner epochs and prompt/generation checks reject late reads; close cancels and
joins work, and retry admission waits for outstanding IO. Explicit cancellation,
disconnect, security changes and endpoint edits revoke launch inputs. Unexpected
reconnect to the same endpoint reuses captured environment or rereads the file.
See CREDENTIAL-INPUTS.md for the full ownership and failure contract, including
kernel-read cancellation limits. Installed/physical authentication acceptance is
still open, alongside the broader native UI plan.

### Reverse listener boundary ownership

Runtime owns a lazy listener service alongside sessions; the reaper retires both
only after their drain futures resolve. Listener stop closes unclaimed sockets but
not accepted sessions. A listener handle owns one bounded event stream and a
coalesced notification source. Subscription generation is one because listener
handles do not restart. C callbacks hold retained contexts; Swift NativeDelivery
invalidates queued work before close and drains it after unsubscribe. NativeRuntime
keeps weak listener registrations and begins all listener/session closes before
awaiting any one. NativeListener retains its runtime and copied pending peer values.

Explicit accept consumes a peer once into an already configured reusable session;
post-claim failure closes the socket. The Swift peer token includes the originating
listener handle, preventing accidental same-ID admission against another listener.
Reverse TLS hostname is the numeric peer host without IPv6 scope; incoming source
port is not a saved-server identity. Native listener UI and reverse persistence
policy remain open; this boundary does not attach user stores or launch secrets.

### Manual listener presentation and reverse connection windows

ListenerModel owns the current NativeListener, observations and one pending
start/stop cleanup task. Epoch changes revoke a start awaiting its predecessor;
stop and window close drain it before any replacement can bind. The UI reserves
one peer ID per window-opening action, scoped by the complete NativeIncomingPeer
value. Expired/accepted/rejected events remove reservations. ListenerWindowController
retains state through drain and restores its explicit content size after installing
the hosting controller. Becoming key clears the app's active connection menu target.

ReverseConnectionRequest stays in memory, retaining the listener and copied peer.
ConnectionModel resolves normal native defaults before explicit admission. Reverse
models never attach history/Keychain/legacy or durable trust services and cannot
export, edit their source address or invoke outbound reconnect. Password UI is
use-once. Close rejects an unclaimed peer and cancels any admitted operation through
the normal session close path. The app owns independent reverse NSWindows without
scene-restoration values, keeps them in the existing connection registry and removes
their controllers on close. Incoming roots do not replace the app's Finder routing
closure with a non-scene OpenWindowAction. Quit revokes listener actions before
starting runtime and window cleanup.

### Numeric CLI listener startup

NativeInvocationLaunch carries a typed listen configuration without an outbound
endpoint. Bootstrap validates the port/families and rejects pending file/socket
adapters before filesystem inspection or environment capture. StartupPresentation
consumes the process request once in the first ordinary scene; profile/Finder
scenes never consume it. A listener scene owns no outbound ConnectionModel.
ListenerModel consumes its auto-start flag once; Stop/close revokes that flag.
The coordinator observes scene-window close and drains its model independently of
accepted sessions and the manually opened listener controller.

ReverseConnectionRequest may carry the nonsecret invocation plus one clearable
launch credential owner. ListenerModel transfers that owner only after a successful
window-opening callback, keeps it on failed opening, and clears it on Stop/close.
ConnectionModel claims only the explicitly attached reverse owner; it never derives
file-only inputs for subsequent peers from the repeated option request. All reverse
sessions keep history/Keychain/durable trust disabled. Ordinary window credentials
and settings precedence remain unchanged. Installed interaction remains open.

### Reviewed listener configuration ownership

NativeSessionDefaultsPurpose.listener retains the existing async reader, file/CLI
overlay and review/mapping lifecycle but produces NativePreparedSessionDefaults
without a NativeSession. The approved value contains configuration and its inherited,
document and invocation metadata; it owns no credential payload or native worker.
NativeDocumentEndpointUse.listenPort validates each ServerName occurrence and travels
through mapping reconstruction. The approved listenPort is typed separately from the
ordinary document endpoint string. File schemas and C exports are unchanged.

ListenerModel starts preparation once on scene appearance, binds only after current
review approval, and passes the approved value to accepted windows. ConnectionModel
reuses it through NativeSessionDefaults before reverse admission, bypassing later
store/file reads. Selected display IDs must still be connected at explicit peer
acceptance; existing session/fullscreen topology handling applies thereafter. Cancel
review clears unclaimed launch inputs. Close stops preparation, removes observations,
revokes queued starts and asynchronously drains the reader and listener. A listener
owns and stops a display service only when it created that service itself.

### SSH child process and forwarding ownership

NativeSSHTunnelRequest owns validated target/gateway values and a deterministic
nonsecret gateway route digest. NativeSSHTunnel owns one SSH master and at most one
control client. A private directory fd pins the socket location; admission requires
successful forwarding acknowledgement and the expected owned socket. Nothing is
stored in preferences/profiles, and the service does not capture VNC credentials.

NativeTunnelProcess synchronizes signals, exit state and waiters under a lock.
posix_spawn creates a new group and closes inherited descriptors. A dispatch process
source observes exit; waitid(WNOWAIT) pins the leader while its group is terminated,
then waitpid reaps exactly that child. Exit cleanup survives a dropped actor owner.
Close revokes route publication, cancels both children, awaits reap and removes only
the known socket leaves. No MainActor wait/join or detached SSH child is used.
The future connection owner must drain RFB before ordinary tunnel close and tag
exit observation to its attempt so an old child cannot fail a new connection.
TUNNELS.md records initial authentication/configuration limits and remaining wiring.

NativeAuthenticationCredentials now includes the attempt's route identity in
NativeCredentialKey. Changing endpoint or route clears retained session credentials;
default empty route preserves existing direct-connection accounts. Launch input may
bind a reviewed endpoint before a route is known, then binds that route once at
attempt admission (or earlier when explicitly supplied). Changing a bound route
destroys launch input and revokes automatic replies; returning to the old route
cannot recapture it. Route identity is nonsecret and never becomes a password or
profile payload. The initial ConnectionModel integration now supplies the selected
gateway route; dedicated controller lifecycle coverage remains open.

### Persisted SSH destination ownership

NativeSSHGateway is immutable and validated before construction or decoding. Its
canonical URI stores only gateway host/scope, user and port. A deterministic route
digest is derived, never decoded as authority. NativeConnectionDestination pairs
that value with exact logical target text. Schema 11 persists complete recent
entries and optional profile gateways; old schemas are read as direct routes.
Queued recency operations, deduplication, revision checks and deletion retain the
whole destination. The history initialization marker uses the full collection,
including when no direct endpoints exist. Compatibility endpoint-only accessors
exclude routed entries so callers cannot accidentally strip their gateways.

Export capture holds the gateway across monitor remapping and adds a distinct
loss before serialization. Neither the URI nor digest reaches compatibility-file
bytes. Initial app integration now uses an owned connection attempt, complete route
selection and current-route export capture, replacing the temporary admission
guard. Service/storage coverage does not prove controller cancellation, exit,
reconnect or close/quit behavior; those dedicated tests are the next task. No SSH
session is launched by storage.
