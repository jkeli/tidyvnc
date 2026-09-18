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
trust-store callbacks, prompt cancellation and `Security::ToString` remain open.

JPEG negotiation now uses an instance flag for both standalone JPEG and Tight
quality hints. The default constructor captures legacy `NoJPEG`; explicit-policy
construction uses a documented JPEG-enabled default, with `setJpegAllowed` for
session settings. The FLTK Options callback translates the legacy parameter into
that setter, including scheduling renegotiation when only JPEG changes. Encoding
updates no longer read the global parameter. Wire-message tests cover legacy
snapshots, explicit defaults, live toggles and concurrent independent sessions.
This does not isolate the remaining viewer parameters or validate native UI.

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
