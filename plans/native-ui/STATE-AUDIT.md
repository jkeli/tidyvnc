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
| `common/core/{LogWriter,Logger,Logger_file,Logger_stdio}.{h,cxx}` | Global writer/logger registration and mutable levels/destinations; file lifecycle and timestamp state need synchronization | Initialize registry before workers; synchronize sink writes/configuration or freeze legacy logging policy. Session-aware redacted diagnostics must not use global log mutation |
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
cancellation is now verified by N1.11 below. Production peer monitoring remains
N1.6, and native prompt presentation and trust persistence remain service/frontend
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
the first waits for credentials/trust. The test FIN observer does not read protocol
bytes; it uses macOS kqueue or Linux POLLRDHUP before cancelling the bridge.

This proves safe pause/resume/unwind at the core/host boundary. The test host and
socket watcher are not production lifecycle/reactor adapters. N1.5/N1.6/N1.13,
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
General event/completion queues, worker readiness/flush, full lifecycle drain,
native input mapping and multi-view focus ownership remain unchecked work.

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
