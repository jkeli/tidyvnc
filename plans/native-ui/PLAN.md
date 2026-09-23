# Native UI architecture and macOS SwiftUI migration

For the current implementation checkpoint and restart instructions, see
[RESUME.md](RESUME.md) (updated 2026-09-23). The
entire plan remains in scope. Configured SSH gateway authentication and host-key
review, native Help/About resources, and 1052 English-source UI entries plus 2 system-metadata entries
are implemented. Actual Help/About interaction and expanded Settings/trust layouts
now have additional evidence in RESUME.md. Remaining localization, interactive accessibility, physical
input/display, installed-app and release gates are not yet accepted. Continue the remaining dynamic user-presentation audit and interactive
window/menu/file-panel acceptance. Profile/history/import text
and minimum-window fixes now have focused evidence. Defaults-import and listener
hosts now also preserve their content minimums after AppKit layout; reverse hosts
use the same policy, with actual-app acceptance still open. Fullscreen/remote-resize fields now also have localized
text and expanded layouts, with physical display order preserved under RTL; see
the latest RESUME/TODO evidence. Listener text and model recovery errors now have
catalog coverage, expanded minimum-size renders and scroll reachability evidence.
Connection-file review/export, monitor mapping and file/invocation diagnostics now
also have catalog coverage and focused admission/layout/packaging evidence.
Defaults-import and first-use/source/recovery text now have expanded minimum-size
fixtures. App menus, connection state/controls and information/statistics now have
catalog coverage. Integrated connection fixtures check 640×420 with expanded and
mirrored text; idle guidance has a compact, high-contrast fallback. Actual user-app
interaction and accessibility acceptance remain open.
Fixed controller/tunnel/clipboard/fullscreen/desktop recovery and desktop accessibility
text now have catalog coverage and expanded behavior checks; see the latest evidence.
CLI and Keychain presentation now have catalog coverage, protected syntax arguments
and byte-identical English terminal output; real OS prompt acceptance remains open.
Startup/desktop errors now use structured, redacted recovery and injected-failure
checks. The latest full rebuilt native suite passes 88/88; see RESUME/TODO for scope.
Native metadata now has a separate compiled InfoPlist catalog. Trust identity
messages use complete localized sentences over typed values; affected tests pass
5/5 after the prior full-suite checkpoint. System Finder/privacy acceptance is open.
The standard app build now verifies compiler localization records for all 139 Swift
sources (1351 call sites) against the UI catalog. Dynamic text provenance and
interactive accessibility still need acceptance; see the latest RESUME evidence.

2026-09-23: the portable suite also passes as Linux Debug under ASan+UBSan+LSan and
TSan (fixing a shared TLS leak and null-copy UB); N1.14 two-session isolation and
the N1.4 global-state reconciliation are recorded in TODO/STATE-AUDIT.

The latest checkpoint passes all 55 retained protocol baseline cases through the
actual native executable, with measured resize assertions and isolated user state;
see [PROTOCOL.md](PROTOCOL.md). It fixes duplicate AppKit interpretation of CLI
operands. The full rebuilt automated suites pass **3/756/89**. This is baseline
wire coverage, not complete protocol, presentation/input or interaction acceptance.

N6.1/N6.3 now provide an explicit Apple-only SwiftUI frontend selector while FLTK
remains the default. The root viewer target and convenience script share one
CMake core → Xcode app path with checked configuration/SDK/architecture/floor
handoff. Clean native/headless and retained FLTK build evidence is in [BUILD.md](BUILD.md).
The automated all-target build/test path passes 3 viewer, 756 core and 88 native
tests plus bundle/CLI checks. Native CI is defined; hosted matrix execution,
deployment/installed-app acceptance, distribution packaging and cutover remain open.
SSH exit notification now retains completion across Darwin's early notification;
compiler localization freshness uses completed-build content receipts. See RESUME
for the deterministic/repeated/sanitized checks and final full-run evidence.

Status: N1.1 headless build boundary, N1.7 window-independent protocol session,
N1.8 retained frame/cursor contract, N1.10 cancellable authentication prompts,
N1.11 real authentication/cancellation proof, and N1.12 bounded input/event queues
are complete (see [viewer/README.md](../../viewer/README.md)).
The full session/listener lifecycle and command catalog remain N1.5.
N1.2 now includes owned endpoint values, checked shared address parsing and
typed encoding/color snapshots/schema with shared FLTK/core selection policy.
Security choices now expose shared canonical names, compiled availability and an
exact allow-list parser, with native defaults/profile controls and initial session
capture. Advanced TLS-priority controls now validate in storage actors through the
shared GnuTLS preflight and preserve independent inheritance and session snapshots.
Connection-local security can now change through disconnected generation/revision
compare-and-replace, preserving session identity and applying on the next attempt.
Shared-session and Retry controls now have defaults/profile inheritance and
disconnected connection-local editors. Shared access is sent in ClientInit; Retry
remains an explicit user action. Remote-layout snapshots, shared validation and
server-completed requests now cross the C/Swift boundary. A native explicit resize
sheet reports actual server results and drains cancellation before reopening.
Automatic resize now coalesces viewport changes per session, respects scaling and
input/capability gates, and captures initial size per accepted connection. Local
policy controls use copied revision-checked drafts. Resize defaults/profile storage
now preserves independent inheritance, explicit blank sizes and per-field sources.
Explicit remote resize now includes an all/selected local-display chooser using
shared DesktopLayout mapping, mixed-density normalization and topology review.
Native canvas geometry now routes per-monitor rendering, inverse input and damage
through the retained shared transform, with coherent asynchronous publication and
window-resize ownership gates. Native surface focus now has scoped ownership,
held-input release on transfer and focus-driven command/capture routing. Fullscreen
canvas coordination now preflights every member, distributes shared pan and remaps
logical/device monitor units with scaling. Fullscreen surface ownership/selection
now has an AppKit window-owner prototype with explicit native-Space/borderless
strategies and bounded transition rollback. A visible local-fixture comparison app
now verifies native/borderless entry and exit on one Retina display and prevents
Space work-area changes from cancelling entry; multi-monitor strategy comparison
remains open. The experimental app now uses a connection-scoped native-Space owner,
a current/all/selected display sheet, activation-aware menu routing and deferred
windowed sheet/error presentation. Saved fullscreen startup/display policy and
guarded reconnect restoration are implemented (see [FULLSCREEN.md](FULLSCREEN.md)).
Automatic fullscreen resizing now submits the complete shared display layout with
exclusive canvas ownership, transition/minimize handoff and drained latest-layout
follow-up; physical acceptance remains open. Remaining settings, capabilities and general errors
remain open; see [CANVAS.md](CANVAS.md).
N1.6 now includes bounded session-owned monotonic timers, statistics throttling,
publication retry and an owned macOS/Linux established-socket readiness adapter
with cancellable waits and peer-closure observation during authentication.
N1.5/N1.13 now include an application-owned bounded runtime for established
attempts, with serialized protocol workers, independent FIN observers and joined
asynchronous drain, consistent authenticating/terminal states, and bounded
asynchronous refresh/encoding commands with reserved completions and cancellation.
Endpoint setup now runs on those workers, using cancellable macOS asynchronous
hostname resolution and nonblocking numeric TCP/Unix connects on macOS/Linux.
Setup-to-transport cancellation, ordered resolving/connecting states and typed
setup failures are covered. Reusable runtime sessions now retain one executor,
mailboxes, prompt IDs and settings across generations, with reserved connect/
disconnect completions and permanent joined close. Remote layout commands now
validate owned topology, expose server capability/current layout, and complete
on server reply, timeout or close with late-reply isolation. Clipboard now has
bounded retained text, asynchronous offer/withdraw commands, independent direction
policy, focus/generation routing and remote-origin echo suppression at the core
boundary. The macOS pasteboard adapter, app-wide focus routing and independent
direction controls are implemented; visible control/app activation verification
remains N3.15. A separate bounded
listener runtime now owns TCP bind/accept, pending-peer expiry and explicit
handoff into session workers, with ordered events and joined shutdown. glibc Linux
hostname resolution now uses cancellable `getaddrinfo_a` (N1.6 complete). The
remaining command catalog and native application service ownership remain open. Native display snapshots now provide opaque UUID identity,
logical/work geometry, scales, generation notifications and missing-monitor
selection resolution; physical topology/fullscreen acceptance remains N5.
N2 now has a versioned, checked C boundary for reusable session lifecycle,
events, retained images, input and authentication, plus nonblocking handle cleanup
and joined runtime disposal. Encoding schema/choices and immutable sourced options
now cross the same boundary for initial configuration and async live application.
Pure C and loopback consumers exercise it without
GUI dependencies. Retained callback subscriptions now use a bounded independent
dispatcher, coalesced mailbox readiness, unsubscribe/context drain and immediate
generation validation. The opt-in `TidyVNCNative` Swift 6 module now owns handles,
copies prompt values, retains images, resolves async operations and coalesces
MainActor delivery with invalidation/drain. Model tests use real loopback peers.
An opt-in Xcode-built SwiftUI app now presents native authentication, a retained
Core Graphics desktop, shared input mapping and asynchronous window/quit cleanup.
Native defaults now include typed encoding preferences loaded before session
construction. A separate live encoding draft uses the same fields with per-session
Apply/Cancel, generation validation, uncertain-outcome reconciliation and joined
sheet cleanup. Initial unlocked-app Settings cancellation and live encoding
Cancel/Apply/reopen checks pass; complete interactive acceptance remains open.
A native profile/history file-store foundation now provides typed records, bounded
recent endpoints, private files, cooperative writer locking and atomic replacement.
The app now shares recent history, records successful connections and offers
selection/removal/clear with nonfatal storage recovery. A saved-profile editor now
supports names, addresses, inherited/explicit clipboard and encoding fields,
revision-checked save/delete and a fresh profile read before new-session creation.
Remaining profile fields and migration/document flows are not yet integrated;
complete interactive profile acceptance remains open.
Native connection/profile forms now validate addresses through the shared core
parser before Connect/Save, with specific inline errors and no DNS or network IO.
The controlled loopback vertical slice is exercised through the visible app and
AppKit tests. Full responsiveness/parity work remains; this is not a shipping
frontend cutover or minimum-OS compatibility claim.
N0 source audit, baseline validation and initial session
isolation prerequisites (DES schedules, Tight gradient scratch and explicit
authentication/TLS policies, session-owned JPEG negotiation and clipboard limits,
owned security-policy strings and session-scoped reconnect credentials)
are recorded in
[STATE-AUDIT.md](STATE-AUDIT.md). Baseline: `4e07cc16`,
inspected 2026-09-18. Track delivery in [TODO.md](TODO.md). Existing source paths
are repository-relative; proposed directories and API names are marked below.

## 1. Outcome, scope and decisions

Replace the macOS viewer's FLTK interface with a native SwiftUI application,
retaining the existing C++ VNC protocol, security, decoding and desktop-scaling
implementation where possible. Define platform-neutral session and service
contracts that a later WinUI application can consume without modifying protocol
logic or pretending Windows services have macOS semantics.

This is an interface and macOS implementation plan. It does **not** schedule a
WinUI application, Windows screen layouts, installer, renderer, credential
backend or Windows migration. Windows appears only as a portability constraint
and possible mapping of the contracts. The Java client remains removed.

Decisions for this plan:

- SwiftUI owns macOS application navigation, forms, sheets, menus and observable
  presentation state. AppKit owns the specialized remote-desktop `NSView`, raw
  input, native windows/display integration and platform facilities where needed.
  Embed that view with `NSViewRepresentable`; do not recreate the remote desktop
  with thousands of SwiftUI views or publish each pixel through observation.
- Retain C++ for RFB, codecs, transport/security policy and reusable geometry.
  Keep GnuTLS/nettle behavior initially; replacing the TLS implementation is not
  a prerequisite or an implicit consequence of using native Keychain storage.
- Expose a small C ABI implemented over a typed internal C++ session API. Swift
  uses a module map and an owning wrapper; future WinUI can use that ABI from
  C++/WinRT or managed interop. Objective-C++ may implement macOS facilities
  behind the boundary. Do not expose C++ templates, STL objects or exceptions
  to UI callers. Direct Swift/C++ interop is an alternative to evaluate only if
  it materially simplifies implementation without weakening portability.
- “Plug in” means injected, compiled adapters with explicit contracts. No
  runtime plugin discovery, IPC service or general-purpose GUI toolkit is needed.
- Preserve the current FLTK frontend for Windows/Linux and as a temporary macOS
  comparison target. The shipped SwiftUI macOS app must not link or initialize
  FLTK. Do not remove other platforms' working frontend in this migration.
- Preserve `.tidyvnc` and legacy `.tigervnc` import, option meanings, security
  checks, client scaling and connection capabilities. A visual redesign cannot
  silently remove advanced features or change VNC wire behavior.
- Provisional macOS deployment floor: macOS 14. Validate it, Swift/toolchain
  versions and dependency targets in N0 before committing implementation to new
  SDK-only APIs. The current macOS 27 build is not evidence of older-OS support.
- No App Store/sandbox conversion, cloud settings sync, new audio backend,
  transport rewrite, new VNC encodings, GPU-only renderer or full Windows port.
  Signing/packaging work needed for the macOS app is in scope; publishing is not.

## 2. Baseline and extraction map

| Current area | Coupling found | Planned disposition |
| --- | --- | --- |
| `vncviewer/vncviewer.cxx` | FLTK main loop, global exit/error state, menus, opening files, reconnect, process launch and tunnel setup | Split app lifecycle/launch adapters from session lifecycle and command-line parsing |
| `vncviewer/CConn.{h,cxx}` | `rfb::CConnection` subclass owns `DesktopWindow`, socket registration, FLTK timers, blocking auth/trust dialogs, static saved credentials | Extract session engine, event delivery, prompts and platform services; remove widget ownership |
| `common/rfb`, `common/network`, `common/rdr`, `common/core` | Reusable protocol/streams/crypto, but static configuration and timer machinery exist | Reuse, audit global/thread state, add narrowly scoped instance configuration/scheduler seams |
| `ServerDialog.cxx`, `AuthDialog.cxx`, `OptionsDialog.cxx` | Forms, history/import/file dialogs, authentication, option mutation | Replace with SwiftUI views and typed commands; reuse validation/parser semantics |
| `DesktopWindow.cxx`, `DesktopView.cxx`, `Viewport.cxx` | Rendering, scrolling, fullscreen surfaces, clipboard, keyboard/pointer, menus, stats and timers interleaved | Separate presentation geometry/input policy from AppKit views and native windows |
| `DesktopSession.{h,cxx}` | Shares framebuffer/damage among `Viewport*`; schedules via `Fl::add_timeout` | Starting concept only: replace widget pointers with view subscriptions and scheduler-owned damage publication |
| `PlatformPixelBuffer`, `Surface*`, `DisplayMetrics` | Framebuffer inherits platform drawing surface; metrics accept `Fl_Window*` | Separate CPU pixel ownership from platform presentation; typed metrics from display adapter |
| `DesktopTransform`, `DesktopLayout`, `DesktopResampler`, `DesktopTileCache`, `CursorRenderer` | Reusable tested math/cache logic; some terminology refers to FLTK logical units | Retain algorithms and tests; logical units become frontend-independent, audit headers/dependencies |
| `KeyboardMacOS.mm`, `cocoa.mm`, `ShortcutHandler`, touch/gesture/emulation helpers | Useful mappings mixed with FLTK/native callbacks | Preserve mappings and policy, replace dispatch with AppKit integration |
| `parameters.cxx`, `LegacyImport`, `core::AtomicFile`, `core::xdgdirs` | Global configuration, POSIX files, Windows registry and FLTK UTF conversion | Extract typed settings/codecs; platform stores own storage, explicit compatibility adapters keep legacy behavior |
| `release/Info.plist.in`, `makemacapp.in`, CMake and CI | Assumes FLTK executable, gettext catalogs and bundle packaging | Add native macOS target, resources and bridge; retain identity, Local Network description, sealing and package checks |

Important traps to address before building screens:

1. `CConn::getUserPasswd`, certificate and host-key verification are synchronous
   protocol callbacks. Merely replacing `fl_choice` with an async Swift closure
   cannot work; there must be an explicit response/lifetime strategy.
2. `core::Timer` maintains a shared timer list. `SecurityClient::secTypes`,
   `CConnection::noJpeg`, viewer parameters and saved username/password are
   static/global. The current macOS New Connection action forks/execs another viewer process;
   moving to native in-process session windows removes that implicit isolation.
   Multiple workers must not race these or leak settings/secrets
   between sessions. A global mutex around a modal prompt is not a solution.
3. `rfb::CConnection::setFramebuffer` owns/deletes its pixel buffer. Native views
   must never retain a dangling pointer after resize, disconnect or reconnect.
4. The current 304-test Release pass and protocol smoke suite establish a
   baseline, not SwiftUI, accessibility, mixed-display or permission validation.

## 3. Layering and proposed source structure

The `viewer/core`, `viewer/platform` and `tests/viewer` build boundary is now
implemented for shared rendering, display-metrics values, retained publication,
a window-independent protocol session and headless validation. `viewer/bridge`
and the initial Swift layer/tests in `platform/macos` and `tests/macos` now exist.
Full command/event lifecycle, native services and the app directory remain open:

```text
common/{rfb,network,rdr,core}/    Existing protocol foundation
viewer/core/                   Session, configuration, input policy, frames
viewer/bridge/                 C ABI headers, implementation, module map
viewer/platform/               Service interfaces and shared test doubles
platform/macos/                Native stores, display/input/clipboard, bridge
apps/macos/TidyVNC/             SwiftUI app, models, assets, localization
vncviewer/                     Retained FLTK adapter/frontend during transition
tests/viewer/                 Core/API/service contract tests
tests/macos/                  Native adapter and UI tests
```

Dependency direction: SwiftUI → Swift wrapper → C ABI → C++ session → existing
RFB libraries. The session depends on abstract services injected by the host;
macOS implementations depend on AppKit/Foundation/Security, never the reverse.
The frame renderer consumes retained frame data, not protocol internals. Only
native adapters contain `NSView`, `NSScreen`, `SecItem`, `UserDefaults` or future
Windows API types. Pure core/API targets must configure, compile and test
without FLTK, AppKit, SwiftUI or WinUI installed.

Avoid a large interface that draws controls or exposes every OS call. Separate
capabilities with distinct lifetime and error contracts; host implementations
can compose several services internally. Use fake services in deterministic
headless tests and a second mock frontend to demonstrate the boundary.

## 4. Session API and data contracts

### 4.1 Identity and configuration

Define value types with documented units, ownership and validation:

- `SessionID`, `ViewID`, `RequestID`, `OperationID`: opaque IDs; requests also carry
  a connection generation so late responses cannot affect a reconnect.
- `Endpoint`: transport kind, original display label, canonical host and numeric
  port, IPv6 scope where applicable, optional Unix socket path, optional tunnel
  route identity. Parse existing `host:display`/`host::port` forms once. Do not
  collapse distinct aliases/endpoints based solely on DNS resolution.
- `ConnectionOptions`: immutable validated snapshot for handshake/security,
  encoding/color/compression, input/clipboard, display/resize and local scaling.
  Separate app defaults, saved profile, session overrides and CLI overrides.
- `Capabilities`: supported security/encoding features, clipboard, remote resize,
  display modes and platform facilities. Disabled controls explain the reason.
- `SessionError`: stable domain/code, operation, retry disposition, safe diagnostic
  context, optional native error code. UI localizes it; core never returns
  preformatted modal content as its only error representation.
- `SettingsSchema`: type/default/range, aliases, persistence class and whether an
  option is live-changeable or requires reconnect. One validator serves both
  frontends and CLI; prevent Swift and C++ default/range drift.

Configuration precedence: compiled defaults → platform app defaults → explicitly
selected connection profile → invocation/session overrides. Document each
option's effective source. Import is a separate user action, not another hidden
fallback layer. UI edits commit only on Apply/Save; Cancel never changes a live
session or durable defaults. Reconnect-only changes require an explicit choice.

### 4.2 Commands, events and state

Internal API sketch (semantic contract, not implementation-ready declarations):

```text
createSession(options, services, eventSink) -> SessionHandle
connect(session) -> OperationID
listen(options) -> ListenerHandle                 # separate lifecycle
accept(listener, incomingID) -> SessionHandle
applyOptions(session, validatedPatch) -> OperationID
sendInput(session, viewID, inputBatch) -> Result
requestRefresh(session) -> OperationID
requestDesktopLayout(session, layout, origin) -> OperationID
respond(session, requestID, generation, response) -> Result
cancelOperation(session, operationID) -> Result
disconnect(session, reason) -> OperationID
closeAndDrain(session) -> asynchronous completion
acquireLatestFrame(session, afterSequence) -> FrameHandle or NoChange
releaseFrame(frame)
```

Ordered lifecycle: `Idle → Resolving → Connecting → Negotiating → Authenticating
→ Connected → Disconnecting → Closed`, with `Failed` terminal for an attempt.
Prompt-required substates include credentials and trust. Retry creates a new
attempt generation; existing subscription/session identity can remain. Listening
has its own starting/listening/stopping/failure states and incoming-peer events.

Events include state snapshots, capability/desktop-layout changes, request
prompts, frame availability, cursor updates, clipboard offers, bell, throttled
statistics, command completion and structured errors. Every accepted operation
completes once, including cancellation/failure. Invalid-state commands return a
structured rejection; UI button disabling is not the only defense. Snapshot
subscription starts with current state, avoiding a subscribe/connect race.

### 4.3 C ABI and wrapper rules

- Prefix exported symbols `tidyvnc_`; use opaque handles, fixed-width integer
  types, explicit enum values, pointer-plus-length UTF-8/byte spans and documented
  nullable fields. No `bool`, `long`, STL containers or OS handles in public data.
- Supply ABI version, size-tagged structures and capability negotiation. Reject
  unsupported mandatory versions/fields; reserve extension space. This is an
  internal versioned boundary, not a promise of arbitrary binary plugin support.
- Explicit create/retain/release and returned-buffer release functions; free
  allocations in the allocating module. Borrowed callback payloads expire when
  callback returns unless explicitly retained/copied. Input spans are copied
  before an async call returns. Secret submission has a separate ownership API.
- Catch all C++ exceptions at the boundary and translate them. Define allocation
  failure and invalid-handle behavior. Validate counts, strides and multiplication
  overflow before allocating or copying data from servers or foreign callers.
- Swift wrappers own handles, expose async operations and typed errors, and
  marshal low-rate UI state to `@MainActor`. Explicit close awaits drain; `deinit`
  initiates safe nonblocking cleanup rather than synchronously joining a worker
  on the main thread. Do not expose unsafe borrowed pointers as Swift model data.
- Callback contexts stay alive until drain completes. Unsubscribe invalidates UI
  delivery; queued work checks session/view generation. No callback into a freed
  view or app controller, and no protocol work reentered from a callback.

## 5. Execution, prompts and shutdown

Use one serialized engine executor per session. Network readiness, protocol
state, timers and command processing run there; decoding helpers may retain
existing internal concurrency only behind their documented synchronization.
The app's main thread exclusively owns SwiftUI/AppKit state. Service callbacks
may arrive on service queues and enqueue an engine completion.

N1 must scope mutable configuration and scheduling before enabling concurrent
sessions. Audit all reachable process-global parameters/timers/logging and crypto
initialization; move mutable per-session state to instances. Keep legacy static
entry points for existing server/FLTK consumers when necessary. Timer services
use monotonic deadlines and cancel tokens, not SwiftUI view lifetimes. Native
socket registrations are hidden behind a reactor/transport adapter; Windows
socket handles must not be represented as POSIX `int` in the public API.

Initial compatibility strategy for synchronous RFB security callbacks: park only
the requesting session's worker on a cancellable prompt rendezvous while the
UI/service resolves an asynchronous request. Do not hold framebuffer, store or
shared-library locks during the wait. Main-thread cancellation wakes the
rendezvous directly through a thread-safe cancellation token; it cannot depend
on a queued command running on the parked worker. Define a bounded prompt
lifetime, cancel on window close/quit/reconnect, and handle peer closure/timeout.
No nested AppKit/FLTK event loop, main-thread semaphore wait, or UI callback from
a decoder thread. Other sessions and the app must remain responsive.

N1 must prove this bridge with real TLS/VNC authentication and cancellation.
If a protocol callback cannot safely pause, explicitly add resumable security
states before proceeding; do not fake success, throw-and-replay a partly consumed
handshake or launch a second competing socket reader. Prefer resumable requests
later if measurements justify replacing the rendezvous.

Queues are bounded. Coalesce pointer moves, damage and statistics, but retain
button/key transitions and request completions in order. Overflow releases input
state and reports a controlled error instead of dropping a key-up silently.
Disconnect cancels network IO, prompts, timers, frame subscriptions and store
requests; releases all remote modifiers/buttons; drains decoder tasks; emits one
terminal result; then releases protocol resources. Repeated close is safe.
Application quit coordinates all sessions without freezing the UI.

## 6. UI and platform-service interfaces

Each async service takes an operation/cancellation token and completes once.
Expose `Unsupported`, `Unavailable`, `NotFound`, `Denied`, `Cancelled`, `Invalid`,
`Conflict` and `IOFailure` distinctly where applicable. Cancellation is not an
empty successful result. Native error details stay in diagnostic metadata.

| Interface | Required operations/data | macOS implementation | Future Windows constraint only |
| --- | --- | --- | --- |
| `SessionEventSink` / prompt responder | Typed state/events, request ID, allowed responses, cancel | Swift wrapper → MainActor models and sheets | Same events consumable by WinUI dispatcher |
| `PreferencesStore` | Read typed versioned snapshot; compare-revision commit/reset; change subscription | Dedicated UserDefaults domain for small non-secret defaults; serialize writes | Local per-user store; no dependence on macOS suite names or registry layout |
| `ProfileHistoryStore` | List/read/upsert/delete profiles; bounded recent endpoints; revision/atomic replacement | Versioned files in Application Support with private permissions | Host-selected per-user app-data files/database |
| `CredentialStore` | Lookup/save/delete scoped secret; metadata listing; interaction policy | Security framework Keychain adapter | Credential Manager or suitable vault adapter; backend not selected here |
| `TrustStore` | Endpoint-scoped certificate/key exception lookup and explicit add/remove | Preserve dedicated trust policy/store initially | No requirement to install trust into OS-wide roots |
| `ConnectionDocumentService` | Parse/serialize bytes, import/export, legacy header support | Shared codec plus native open/save panels | Same codec with Windows file picker adapter |
| `ClipboardService` | Offer/request text, generation/origin, read/write policy and limits | NSPasteboard, focus/activation-aware observation | Clipboard notifications/ownership model hidden |
| `DisplayService` | Stable opaque IDs, logical/work bounds, backing scale, topology generation; observe changes | NSScreen/AppKit adapter | Per-monitor DPI/topology supplied in identical units |
| `WindowHost` / `PresentationSink` | Attach/detach ViewID, fullscreen intent/result, metrics, invalidate/frame lease | NSWindow and NSView coordinators | WinUI/native window and presentation implementation deferred |
| `InputAdapter` | Normalized pointer, wheel, key/scancode/text/focus events; capability flags | AppKit responders and existing key maps | Windows keyboard/input translation remains adapter work |
| `NetworkReactor` / `Scheduler` | Readiness registration, cancellable waits, monotonic deadlines, wakeups | Native/POSIX implementation outside UI loop | Accommodates different IO mechanisms without changing session API |
| `PlatformAccessService` | Capability/permission evidence, actionable recovery, open relevant settings when supported | Local Network and input-capture guidance | Does not assume equivalent permissions exist |
| `FileAccessService` / `TunnelLauncher` | Scoped file access, explicit external process invocation/cancel and endpoint result | File URLs/native panels; existing tunnel capability via adapter | Unsupported capabilities are explicit, no Unix shell contract |
| `AppServices` | Open URL, About/credits, notification/bell and redacted logging | SwiftUI/AppKit facilities | Host-specific implementation |

Do not add abstractions solely for hypothetical Windows features. Clipboard,
input, window/display coordination and service errors are necessary now; backend
classes for unimplemented Windows services are not.

## 7. Preferences, credentials, trust and migration

### 7.1 Storage boundaries

Preferences are not credentials. Saved profiles contain connection settings and
opaque credential references only. Keychain entries hold passwords/secrets;
trust decisions remain a separate, auditable policy. No password in UserDefaults,
profile/history JSON, `.tidyvnc` exports, URLs, logs, crash attachments or observable
state snapshots. Do not treat legacy VNC password-file obfuscation as encryption.

UserDefaults is for small non-secret defaults, not a transactional database.
The adapter provides one serialized writer and a versioned snapshot/revision;
concurrent stale edits receive Conflict. If cross-process durable transactions
are required, use the versioned file store for those records rather than promise
CAS/durability that UserDefaults does not provide. History/profile files use
atomic replacement, restricted permissions, schema validation and recovery from
partial writes. Newer unknown schemas are preserved and opened read-only with an
error, never overwritten with defaults. Separate app window state from connection
settings. Never persist transient connection errors or permission guesses.

### 7.2 Credential contract and macOS policy

`CredentialKey` includes application namespace, canonical endpoint/port/transport,
route identity, authentication kind and username (explicit empty value for VNC
password-only authentication). A local tunnel port alone is not server identity.
When the negotiated protocol supplies a cryptographic server identity, verify it
before automatic credential reuse; a changed server key/certificate
requires the existing trust decision and cannot silently inherit approval.
Unencrypted/password-only modes cannot promise server authentication; preserve
their explicit security indication and credential-send policy rather than invent
a verified identity.

The canonical credential identity is now implemented as NativeCredentialKey.
The shared endpoint parser is exposed through immutable owned C handles; Swift
hashes versioned, length-prefixed fields including the app namespace, transport,
canonical host, exact scope, port, exact path/route, negotiated authentication
method, password-only versus username/password shape, and exact username bytes.
The retained value contains only an opaque SHA-256 account identifier. DNS aliases,
trailing dots, scopes and Unicode-equivalent but byte-distinct user/path/route
values do not merge. Callers must supply the logical server destination and a
non-secret route identity, not treat a temporary local forwarding port as proof
of the remote target. Keychain, retention and trust-gated reuse remain separate.
The authentication sheet now describes the core's credential-protection policy
without interpreting that flag as whole-connection encryption.

Results distinguish missing entry, locked/unavailable store, denied access,
interaction required, user cancellation and other failure. Callers specify
whether OS interaction is allowed; background reconnect must not generate an
unbounded sequence of Keychain prompts. Cancellation after an OS call starts may
not undo its side effects: return/report the committed outcome and reconcile
metadata instead of pretending a successful save was rolled back.

Authentication UI offers separate choices: use once, retain for this session's
reconnect, and remember on this Mac. Default to no durable save. Persist only
after authentication succeeds and only with explicit remember choice. A failed
stored credential does not loop indefinitely or delete itself without consent;
prompt to replace or forget it. A credential-save failure does not convert a
successful connection into failure or fall back to plaintext storage.

Use app-scoped generic-password Keychain records via SecItem APIs. Select and
record the macOS keychain implementation, access policy and signing requirements
in N0/N3; test the actual packaged signed app, including upgrade behavior. Default
to local-only storage, no iCloud synchronization, no shared access group and no
biometric requirement. Do not invent an entitlement or require biometric prompts
for every reconnect. Apple documents important differences between macOS keychain
implementations; access policy must be tested rather than inferred from iOS.

The selected Keychain policy and signing prerequisites are recorded in
[KEYCHAIN.md](KEYCHAIN.md). The SecItem adapter and bounded async store now provide
lookup, explicit create/replace, exact delete and secret-free bounded metadata
listing. Per-call interaction defaults to forbidden; missing entitlements and
other OS failures remain typed. Owned secret storage is wiped on clear/deinit.
NativeAuthenticationCredentials now integrates per-window use-once/session/remember
choices, explicit session/saved-password submission, replace-on-success and exact-key
Forget. The protocol worker captures the negotiated credential subtype in each
owned prompt; no configured-method inference is used. Session values survive an
unexpected interruption for explicit reconnect, but cancel/disconnect/close clear
them. Save happens once the matching generation connects; failure is a separate
nonfatal notice. Delayed lookup results cannot submit after cancellation or close.
There is no automatic stored-secret retry or deletion. Real signed-app Keychain,
OS prompt behavior and interactive acceptance remain open.

Use narrowly scoped secret buffers, redact all diagnostics, clear owned mutable
buffers at release and minimize Swift string copies. Do not claim guaranteed
zeroization of every OS/Swift runtime copy. Replace current process-static saved
credentials with session-scoped lifetime; disconnect/Forget clears retained data.

The shared certificate exception mask and native one-time trust presentation now
follow [TRUST.md](TRUST.md). Fatal/unknown certificate errors are rejected at the
prompt reply boundary, independently of UI state. Typed reasons, DER decoding and
correctly labeled SHA-256/compatibility fingerprints are implemented. A read-only legacy
trust-store adapter now reuses existing host-scoped exceptions and displays expected
and received public-key identities with cancellation/generation guards. Explicit
destination-scoped certificate save/replace/forget, revision-checked atomic writes,
recovery and management UI are implemented under the dedicated TidyVNC state path.
Forgotten certificate scopes suppress legacy fallback. RSA-AES keys now have an
independent kind/domain and file, shared encoding/reply policy, explicit scoped
save/replace/forget and management. CA/CRL defaults/profile controls now select
required per-session files. Physical/full native security acceptance remains open; see the precedence and write contract in TRUST.md.

### 7.3 Existing user data and launch behavior

The current native viewer writes TidyVNC XDG files on macOS. Keep explicit
connection files and CLI options compatible; switching the GUI to native stores
must not silently abandon those users or create ambiguous dual writers.

- Offer explicit import of existing TidyVNC defaults/history into the native
  stores on first use. Preview imported categories; mark migration only after
  success. New native data wins; corrupt/inaccessible native data is not absent.
- Preserve separate opt-in legacy import under [the existing migration policy](../rebrand/MIGRATION.md).
  Never automatically migrate passwords, CA/CRL, security types, trust records or
  tunnel commands. Keep originals untouched; cancellation and retry are safe.
- Explicit `XDG_*` overrides remain honored by compatibility import/file paths;
  explain that native app defaults use native stores. Preserve CLI explicit-file
  precedence. Provide a documented export to `.tidyvnc` for intentional handoff
  back to FLTK; no continuous bidirectional synchronization.
- Keep current trust paths/policy for the first SwiftUI release through a trust
  adapter, independently of preference migration. Select CA/CRL paths explicitly.
  Do not weaken verification or import all user/system trust roots implicitly.
- Finder open, drag/open document, CLI host/options/password-file/environment,
  reverse/listen mode and supported tunnel invocations need defined behavior.
  Parse secret-bearing inputs outside shell-string interpolation; do not log or
  reserialize secrets into process arguments. CLI compatibility stays explicit,
  not an automatic secure-store import.

## 8. Rendering, input and multiple displays

The frame contract is a retained immutable lease: sequence, connection and size
generation, remote dimensions, pixel format, stride, bounded damage rectangles
and color-space metadata. Start with canonical CPU pixels and explicit format
conversion; document byte order/alpha and top-left coordinate origin. A resize
publishes a new generation. Old leases remain valid until release; views discard
stale generations. Network/decoder ownership is never handed to AppKit.

Use bounded snapshot/tile storage with reuse and backpressure, not an unbounded
queue or a full desktop copy for each view on every update. Dropping intermediate
presentations is allowed only if the acquired frame contains all changes since
the displayed sequence (merged damage or explicit full invalidation). Detaching
a view frees its leases. One source desktop serves all fullscreen windows.

First renderer: AppKit view with a measured Core Graphics/layer-backed CPU path,
using existing resampler/cache/cursor algorithms. Metal is optional later, not
required to deliver SwiftUI. Benchmark whether the CPU path meets existing
scaling budgets before choosing GPU work. Native view invalidation is separate
from SwiftUI state updates. Keep controls, overlays and statistics at native UI
size; the remote image alone follows desktop scaling.

Preserve all eight scaling modes, logical/device-pixel choices, nearest/bilinear/
area filters, identity fast path, fractional scale and pan, letterboxing, dirty
regions, remote cursor hotspot/shape, and the local fallback cursor. Keep client
scaling separate from server resolution requests and JPEG/compression quality.
Use the existing transform for both image placement and inverse input mapping;
convert AppKit's coordinate orientation at one tested boundary.

Implemented increment (2026-09-19): the native connection sheet now exposes eight
modes, custom values and logical/device units using a stateless shared-parser ABI.
Copied Apply/Cancel drafts validate the current view geometry before publication;
view/input share the applied transform, with temporary fit recovery after a display
change exceeds limits. Nearest, bilinear and area controls now use the shared
resampler; bilinear matches the retained frontend default. Filter-only Apply
preserves pan, and Cancel discards the draft. Scaling defaults/profile persistence
and native menu/accessibility pan actions are implemented. Pan moves by 80% of
the viewport in the selected units, clamps to the shared geometry's edges and
keeps remote input aligned with the displayed pixels during asynchronous rendering.
Performance and full interactive keyboard/VoiceOver acceptance remain open;
N4.7/N5 are not complete. See the scaling and panning evidence in TODO.md.

The shared tile cache/resampler now feeds AppKit composition through bounded C
calls and a native background actor/scheduler. Immutable native frames carry
consumed-sequence damage; skipped work invalidates cache history. Unchanged CG
tiles share their immutable storage, and identity uses the retained original image.
Image and input geometry publish together; shared damage mapping limits redraw.
Session-owned slots include detached renderers until their asynchronous cleanup
finishes, and close/quit joins them. Tests cover displayed filter pixels, stale
results, damage reuse and held-worker teardown. AppKit image streams now replay
retained frames/cursors independently of SwiftUI observation; the shell observes
frame availability and distinct control/statistics values. Physical display acceptance and
end-to-end performance remain open; this does not complete N5.1/N5.2.

The shared cursor sampler now has checked C exports and a Swift owner. It retains
an original-sized premultiplied source copy, returns rounded/clamped hotspot
geometry and renders bounded straight-RGBA tiles without an enlarged raster.
Alpha goldens, all filters, extreme/anisotropic scaling, concurrent reads and
source independence are tested. AppKit now uses sampled native images up to 128 ×
128 backing pixels and clipped software tiles for larger cursors, with one active
and one latest cursor job per view. Session close joins cursor and desktop jobs.
Blank/empty cursors follow hidden/dot/system fallback policy; view-only uses the
system arrow. Tests cover overlay pixels, clipping, motion reuse, backing-scale
transitions and held-work teardown. A connection-local Input Settings sheet now
exposes view-only, middle-button emulation and hidden/dot/system fallback with
copied Apply/Cancel drafts. Middle-button behavior shares the retained viewer’s
state machine, using a per-session 50 ms worker deadline in the native path.
External policy changes, reconnect and close invalidate old drafts; enabling
view-only releases core-held input and clears AppKit input composition/state.
Default/profile persistence, physical acceptance and measured memory/latency
remain open; N4.6 and N5.4 are not complete.



The display adapter supplies immutable topology snapshots with stable opaque IDs,
backing scales and generation. No persisted monitor array indices. Reconcile
missing monitors, negative origins, hotplug and changing Spaces safely. Preserve
windowed/current/all/selected-monitor fullscreen, reconnect layout and spanning
behavior; test native fullscreen versus coordinated borderless windows before
selecting the implementation. Do not assume SwiftUI's window modifiers alone
reproduce the current multi-display behavior.

The current native single-window commands now support minimizing from fullscreen:
release input/capture, request fullscreen exit, wait for the owning window's exit
notification, then minimize and await completion. Duplicate commands are gated;
detach, close, disconnect, rebind and reversed transitions cancel the pending intent.
A bounded deadline clears failed transitions and exposes retry guidance without
replacing SwiftUI's window delegate. Physical Spaces/multi-display acceptance is
still required. The owned fullscreen prototype now also exits its temporary group
and minimizes the original window, with success-only handoff and cancellation on
sheet/lifecycle/topology changes. Native-Space and borderless minimize/restore have
been observed on one Retina display. The app now uses the owned minimize route;
visible app interaction and multi-monitor acceptance remain open.

The native information sheet now reads negotiated desktop name, RFB version,
security method, wire pixel format, requested/last received encoding and bandwidth
estimate from bounded immutable core observations. A generation-checked C query
copies metadata with its matching counters/state; the Swift bridge publishes them
as one snapshot, retaining the existing statistics cadence and deduplication.
Copy Diagnostics omits endpoint, desktop name, credentials and filesystem paths.
A per-connection Show Connection Statistics toggle now exposes a passive overlay
of dimensions, frames, last encoding, line-speed estimate, protocol and security.
It consumes the same sampled observation, adds no timer/subscription, and resets
on disconnect/reconnect/close. Broader metrics and interactive acceptance remain
N4.12.

Input carries remote coordinates, buttons, wheel units and physical key identity
plus logical text where supported. Reuse audited keysym/scancode mappings. Handle
modifier-only events, repeats, focus loss, shortcut interception, Unicode/IME
policy, different keyboard layouts and dead keys explicitly. Do not emit both a
text event and key event for the same input without defined protocol semantics.
One session owns remote pressed-key/button state across all its views. Focus
loss, disconnect, sleep or capture revocation sends release-all/reset. View-only
is enforced in the core, including synthetic menu shortcuts.

The retained shortcut classifier is now shared through bounded core state and
checked C handles. Native routing decisions cover command selection, modifier-only
release and temporary Space bypass. AppKit now consumes these decisions, translates
bounded layout candidates only for armed shortcuts, and routes native context
menus and window actions. Connection-local modifier controls and fullscreen
system-key capture use copied drafts. Typed app-default and saved-profile input
patches resolve before session creation; live overrides retain fieldwise sources
and never write defaults or profiles. Existing windows retain their settings when
saved defaults change. Capture is scoped to the focused desktop,
with release on focus loss, sleep, policy change, disconnect and close; unavailable
capture has recovery guidance without prompting for permission automatically.
Native Connection/toolbar/context menus route window actions and synthetic input
to the owning desktop. The information sheet shows negotiated connection metadata and snapshot/input/
clipboard fields. Actual global capture, physical layout/IME parity and physical
window transitions still require acceptance;
injected backend tests do not establish those behaviors.


Scaling defaults and profile patches also resolve before the initial desktop
presentation, covering the shared eight-mode parser, logical/device units and all
three filters. Explicit saves canonicalize sizing text; reads preserve original
stored bytes. A live scaling apply changes only its connection and marks only
changed fields as session overrides. Display-limit preflight and fit fallback
remain in the desktop adapter; saving syntax-valid sizing does not establish
physical-display suitability or keyboard/VoiceOver acceptance.

Clipboard send/receive settings are independently enforced; focus and session
routing prevent broadcast to every connected server. Define text encoding,
newline conversion, maximum size, generation and loop prevention. Preserve
supported extended clipboard behavior; do not silently add file/image transfer.
A remote framebuffer is not a semantic accessibility tree for the remote OS;
make the local view/status/actions accessible without promising remote controls
that the VNC protocol does not describe.

## 9. SwiftUI replacement inventory

The source/control inventory is now [PARITY.md](PARITY.md) (162 detailed rows),
with [CAPABILITIES.md](CAPABILITIES.md) covering all 47 canonical parameters,
aliases, compiled defaults/ranges and change lifetime. These complete the N0.1/N0.2
inventory deliverables, not the acceptance gates. AlertOnFatalError now has a
scoped native adapter and automated evidence; actual window acceptance remains
open. The latest RESUME records the implementation and validation boundaries.

Every row must map to implementation and acceptance evidence before cutover.
Inventory individual parameters/menu actions during N0 so smaller controls are
not lost inside a large screen rewrite.

| Existing UI/behavior | Native replacement and acceptance criteria |
| --- | --- |
| Server dialog, recent hosts, endpoint entry, import actions | Connection window with endpoint validation, recent list, Open/Save and separate settings/history import; keyboard-first Connect/Cancel; preserve history limit/privacy |
| Authentication dialog | Session-scoped sheet with username/password as required, visible server/transport security context, use-once/session/Keychain choices; secure field and cancellation |
| Certificate exceptions and server key verification in `CConn` | Structured trust sheet showing endpoint, reason, expected/received identity and details; safe cancel default and explicit scoped decision; no global “trust everything” |
| Options: compression/color | Auto select, available encodings, full/reduced color, JPEG enable/quality and compression level with current ranges; supported features only |
| Options: security | Current encryption/authentication choices and CA/CRL file pickers; preserve negotiation policy and reconnect-required changes |
| Options: input/shortcuts/clipboard | View-only, middle-button emulation, cursor fallback/type, fullscreen system keys, modifier selection, send/receive clipboard; X11-only selections absent on macOS |
| Options: scaling | All eight modes and editable sizes/percentages, validation/help, quality, logical/device units; independent of remote desktop resizing |
| Options: display/miscellaneous | Window/current/all/selected screens, visual screen chooser, remote resize/size policy, shared connection and reconnect; unsupported audio explicitly capability-gated |
| Live Options and saved defaults | Native Settings for app defaults and session settings sheet for overrides; draft/apply/cancel, effective values and reconnect indication; no cross-session global mutation |
| Desktop window/secondary fullscreen views | SwiftUI shell plus native desktop views, scroll/pan, resize, fullscreen transitions, title, cursor and focus continuity |
| Context menu and shortcut actions | Disconnect, fullscreen, minimize, resize window to session, Ctrl/Alt toggles, Ctrl-Alt-Del, refresh, Options, connection info and About; menu state follows active session |
| App menu/Dock/open-file/new connection/quit | Native commands and app delegate routing, `.tidyvnc` association, explicit legacy open, multiple session lifecycle; do not restore live connections without intent |
| Connection info/performance overlay | Native inspector/overlay with negotiated encoding/security, dimensions and throttled stats; selectable/copyable diagnostics with redaction |
| Errors/reconnect/Local Network denial | Structured alerts/status with Retry/Cancel and retained safe context; distinguish auth, DNS, routing, permission suspicion and unsupported capability |
| Open/Save As/overwrite/import confirmation | Native file panels; correct extension/header, explicit overwrite, no secret export, rollback on failure and security-scoped access only if packaging requires it |
| About/credits/help | SwiftUI/native About content, current identity, upstream/license credits and support links, localized and selectable where useful |

Use native spacing, typography, focus behavior, light/dark/high-contrast support
and reduced-motion preferences. VoiceOver labels, keyboard navigation and escape/
default buttons apply to every sheet. Move UI strings to a native localization
catalog with stable IDs; keep existing gettext strings for retained FLTK/core
consumers. Map structured core messages into native localization with a safe
fallback. Preserve translator attribution; do not mark untranslated strings as
translated or discard existing catalogs wholesale.

The native connection model now presents structured failures using fixed redacted
messages. DNS, refusal, routing, timeouts, suspected network/system policy,
authentication, protocol and resource failures remain distinct. Socket errno is
interpreted only for connection/transport failures; routing errors do not identify
a Local Network denial. Unexpected peer closure creates a reconnect alert, while
requested disconnect and cancellation remain silent. Retry is explicit and bound
to the same problem identity, generation and unchanged endpoint, and Cancel/close
revoke it. Authentication reply errors use the same safe fallback mapping. Native
localization and interactive alert/keyboard/VoiceOver acceptance remain open.

## 10. macOS integration and packaging

Keep `io.github.jkeli.tidyvnc`, icons, document types, Local Network usage text and
credits. Use a SwiftUI app entry point with an AppKit delegate/coordinator only
for native integration; never start two competing application event loops.
Build C++ libraries with CMake, expose an importable C module, and use an Xcode
app target as the initial bundle/test authority. Provide a scripted reproducible
CMake-library → xcodebuild app/test/package path, explicit SDK/architecture/
deployment settings and generated dependency inputs. No hand-copied developer
build paths or duplicate version/Info.plist sources.

Local native app/DMG assembly is now implemented through the same build script
and root targets. [PACKAGING.md](PACKAGING.md) records recursive dependency
bundling, enforced minimums, relocation/signing and mounted-image checks. The
current macOS 27 ad hoc Debug and clean Release packages have inspection evidence;
supported minimum-OS, Intel, production identity and installed acceptance remain
open.

The viewer selector is `TIDYVNC_UI=FLTK|SWIFTUI`; see [BUILD.md](BUILD.md).
Keep default FLTK until parity gates pass; SwiftUI is Apple-only and missing Swift/
Xcode must fail clearly when requested. SwiftUI/core-only builds must not discover
or link FLTK; Linux/Windows FLTK configure/build continues unchanged. Adapt tests
that currently link FLTK surfaces so pure core tests remain independent. Preserve
CLI help/version/options and decide whether the CLI is the app executable or a
small launcher in N0, without transferring secrets through command-line relaunch.

Network access itself triggers macOS Local Network consent. Preserve explanatory
metadata and an actionable retry path; do not invent a universal permission
request/status API or label every `EHOSTUNREACH` as denial. Test Finder-launched
app consent separately from Terminal child-process tests. Request any special
input-capture permission only when its feature requires it; ordinary view input
must not be made dependent on broad global event monitoring. Never modify privacy
databases or add bypass entitlements.

Seal the final assembled bundle. Test Keychain and privacy behavior with the
intended signing identity across rebuild/update; ad hoc development results are
not proof of stable production identity. Keep notarization/distribution and
Homebrew dependency portability explicit, measured gates. A rollback uses the
retained FLTK build and untouched legacy data; it must not overwrite the SwiftUI
stores or secretly share new credentials with the old frontend.

## 11. Delivery sequence and completion gates

| Phase | Work and required exit evidence | Dependencies |
| --- | --- | --- |
| N0 — Inventory and decisions | Per-control/parameter parity map; API/ownership review; supported SDK/floor/build choice; trust/Keychain policy; baseline screenshots and performance captures | This plan |
| N1 — Core extraction | Headless session, typed config, scoped globals/timers, services, cancelled auth rendezvous, native-independent build and fake transport tests | N0 |
| N2 — ABI and native vertical slice | C module + Swift owning wrapper; connect/auth/render/input/disconnect to loopback through AppKit view; responsive UI, no FLTK runtime | N1 |
| N3 — Storage and platform services | Native defaults/history/Keychain/trust/file/clipboard/display adapters and explicit migrations with contract/integration tests | N1; integrate through N2 |
| N4 — SwiftUI screens | Complete replacement inventory, commands, options, prompts, documents, localization and accessibility | N2, N3 |
| N5 — Desktop fidelity | Scaling/cursor/input/mixed-density/multi-display/fullscreen parity and performance evidence | N2; N4 controls |
| N6 — Packaging and cutover | Reproducible native build/CI, full matrix, signed app privacy/Keychain checks, no FLTK links, docs and rollback validation | N3–N5 |

Make reviewable commits per phase/subtask and update TODO evidence as work lands.
Do not implement all screens against a provisional interface before the vertical
slice proves lifecycle, cancellation and frame ownership. Keep the old frontend
usable until N6 passes. Remove macOS FLTK from the shipping path at cutover; shared
FLTK source/dependencies stay for the existing other-platform frontend. Subsequent
WinUI work receives a separate plan based on the proven contracts.

## 12. Verification and acceptance matrix

- **Core and ABI:** existing applicable unit suites plus session transitions,
  invalid commands, per-session isolation, ABI ownership/version/error handling,
  generation rejection, frame retain/resize/disconnect, cancellation at every
  connection stage and bounded queues. Use ASan/UBSan and TSan where supported;
  document uninstrumented dependencies. Test two sessions with different security
  and encoding policies, one waiting for credentials while the other updates.
- **Protocol integration:** reuse/extend `tests/integration/macos-scaling-smoke.py`
  and the existing full 55-case baseline; instrument native presentation/input
  separately because protocol success alone does not prove displayed pixels.
  Cover supported encodings/security, bad credentials/certificates/keys, clipboard,
  resize, reverse/listen, tunnel, disconnect/reconnect and server disappearance.
- **Storage:** isolated app domains/temp roots/fake vault; defaults precedence,
  conflict/schema/corruption, interrupted writes, import cancellation/idempotence,
  read-only paths and no secret exports. Real Keychain tests use unique disposable
  entries and delete only those entries, including failure/locked/denied cases.
  Never clear the user's defaults, Keychain or trust store to run tests.
- **UI:** Swift model tests, native UI automation and manual accessibility review;
  all inventory rows, focus/keyboard actions, two concurrent sessions, prompt
  cancellation/close/quit, light/dark/high contrast, localization expansion and
  VoiceOver. Record native screenshots; do not reuse FLTK screenshots as evidence.
- **Rendering/input:** deterministic pixel/transform fixtures, unscaled identity,
  each scaling mode/filter, fractional pan, cursor hotspots, display changes and
  stress resize. Physical 1×/2× and mixed-display cases plus layout/hotplug/Spaces
  require real hardware/manual evidence; simulations are supplemental.
- **Performance:** capture identical baseline hardware/build/server/workload for
  FLTK and native frontend. Measure decode-to-present p50/p95, input latency,
  idle/update CPU, retained bytes, allocation/copy rate and damage size for idle,
  scrolling, 1080p/4K and multiple views. Carry forward existing scaling budgets;
  provisionally reject >10% p95 latency/CPU or retained-memory regression on the
  same workload unless reviewed with measured benefit. No claims from renderer
  microbenchmarks alone. Long reconnect/resize/attach cycles must not leak.
- **Build and platform boundary:** clean core without GUI dependencies; macOS
  Debug/Release on chosen minimum and current OS; supported architecture matrix;
  pure C caller and mock non-Apple host; retain Windows/Linux FLTK CI. Verify
  signatures, resources/localization, document opens, dependencies and absence of
  FLTK symbols/libraries in shipped app. Windows UI/backend runtime is deferred.
- **OS integration:** actual installed Finder-launched app, fresh consent where
  supported, allow/deny/retry, upgrade signing identity and Keychain access,
  sleep/wake/network changes and clean quit. Keep unavailable physical/signing
  checks open instead of counting them as test passes.

N6 is complete only when macOS parity rows and contract tests pass, shipped app
contains no FLTK runtime, native stores and credential handling are verified, and
remaining platform/distribution limitations are stated accurately. No Windows
frontend completion is implied.

## 13. Risks and decisions to record in N0

| Risk/decision | Resolution required before dependent work |
| --- | --- |
| Shared globals and synchronous auth | Demonstrate scoped state and cancellable worker wait before multiple sessions; resumable protocol fallback if necessary |
| Buffer copies and stale pointers | Implement retained generations and bounded damage publication before native renderer integration |
| SwiftUI/AppKit fullscreen semantics | Prototype mixed-display/Spaces behavior, then document the chosen window strategy |
| Defaults migration and CLI coexistence | Define authoritative writers, explicit import/export and rollback before enabling native stores |
| Keychain implementation/signing | Select supported SecItem backend/access policy and record signing prerequisites; test packaged upgrade |
| Toolchain/deployment floor | Pin compatible Xcode/Swift/C++ settings and dependency targets; validate provisional macOS 14 floor |
| Current optional features | Inventory actual compiled capabilities; unsupported audio/H.264 is explicit rather than a nonfunctional control |
| Windows portability | Review public contracts for Foundation/POSIX/widget leakage and prove with a mock non-Apple host; no WinUI implementation now |

## 14. References

The architecture above is a project design choice informed by source inspection.
Platform API details should be rechecked against the selected SDK during N0.

- [Apple: NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable) — supported AppKit embedding boundary for the desktop view.
- [Apple: UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults) — native non-secret preferences facility; application transaction semantics remain our responsibility.
- [Apple: TN3137, macOS keychains](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) — keychain backend/access-policy distinctions to resolve in the native adapter.
- [Apple: TN3179, Local Network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — actual consent and signing behavior, including initial connection failure/retry.
- [Swift: Mixing Swift and C++](https://www.swift.org/documentation/cxx-interop/) — alternative interop path; the portable C ABI is the selected baseline.
- [Microsoft: CredWriteW](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew) — example future credential backend with its own storage/error semantics, not a Windows implementation commitment.
- [Rebrand plan](../rebrand/PLAN.md), [migration policy](../rebrand/MIGRATION.md), [HiDPI plan](../hidpi/PLAN.md), [scaling plan](../client-scaling/PLAN.md) — preserve applicable native behavior and open validation gates; earlier Java requirements are superseded by native-only scope.


Fullscreen policy update (2026-09-20): defaults/profile storage (schemas 10/9),
per-field source-aware controls and generation-scoped startup/reconnect restoration
are implemented. Old records remain unchanged until explicit save, missing display
IDs survive fallback, and explicit exit/failure cancels reconnect intent. See
[FULLSCREEN.md](FULLSCREEN.md) and the latest TODO evidence. CLI mapping, physical
multi-monitor/Spaces and the remaining native UI gates are still open.


Fullscreen statistics update (2026-09-20): the same passive, value-only panel now
appears on every owned fullscreen surface. Connection menu/context toggles stay in
fullscreen; existing sampled snapshots update reusable hosts without new timers
or frame subscriptions. Desktop geometry, pointer routing and first responder are
preserved, and transitions/disconnect/close clean up the overlays. See
[FULLSCREEN.md](FULLSCREEN.md) for model/native-view evidence and the remaining
physical VoiceOver/multi-display gates.

The connection-document syntax and export boundary now lives in the portable
viewer core and is consumed by retained FLTK load/save/import. Complete-output
preflight fixes saves that exceeded the reader's full-line bound. Bounded parsing,
owned ordered records and deferred decoding preserve unknown-option compatibility
without global mutation. Native semantic application, bridge, panels and launch
routing remain open; see [DOCUMENTS.md](DOCUMENTS.md).

The shared document codec now has an additive four-function C boundary and an
immutable Sendable Swift owner. It preserves deferred decoding, copied metadata,
strict native UTF-8 handling, typed redacted failures and explicit non-secret
exports without mutating settings or stores. Native document review, semantic
configuration resolution, Open/Save and launch routing still remain open; see
[DOCUMENTS.md](DOCUMENTS.md).

Explicit connection files now have shared per-field semantic validation, including
retained FLTK consumption, and an immutable native configuration-resolution model.
It preserves explicit-file-after-CLI precedence, empty/missing endpoint behavior,
post-file deprecated migrations, owned provenance and deliberate ignored-field
review. Stable display mapping and relative-path bases are explicit host inputs.
The model is verified through native session construction and real loopback ClientInit
bytes; app file panels, preview identity, loss-aware export and launch routing remain
open. See [DOCUMENTS.md](DOCUMENTS.md).

Explicit Open now runs through a native panel and new connection-window review.
An injected bounded regular-file reader resolves after native defaults/profile;
review identity and fresh monitor mapping gate idle session construction. Window
close and application quit revoke pending reads/pickers, and accepted resolution
metadata is retained before Connect becomes available. Both normal and sanitizer
native suites pass 49 tests, with a separate live Open/review/Ready UI check.
Save/overwrite, detailed mapping recovery, imports and Finder/CLI routing remain
open; see [DOCUMENTS.md](DOCUMENTS.md).

Finder document events now route through both AppKit callbacks into the same
per-file review windows. A bounded app-owned queue handles delivery before the
SwiftUI window action is available, distinct repeated-file requests and quit
revocation. A real SwiftUI fixture proves warm delivery with zero visible windows;
live Finder cold/mixed-batch checks prove current and explicit legacy files reach
review/recovery independently. Window titles identify each file. CLI invocation,
Save/overwrite, imports and release association/consent gates remain open; see
[DOCUMENTS.md](DOCUMENTS.md).

Native connection export now has an immutable, non-secret compatibility model
and synchronous capture of current applied connection settings. Omitted native
resize settings, stable-ID-to-monitor conversion and ignored input require
explicit review; custom TLS priority and unmappable displays fail before output.
Hidden cursor fallback preserves the latest selected shape through export.
Shared syntax and semantic preflight validate all emitted fields. Export review
UI, destination selection, atomic Save/overwrite and imports remain open; see
[DOCUMENTS.md](DOCUMENTS.md) and the latest TODO evidence.


Native Save As now connects immutable export review to NSSavePanel and a private
atomic writer with explicit overwrite, conflict checks and cancellation/quit
joins. Save feedback preserves viewport geometry. Real UI checks verify create,
overwrite and cancellation; 53 native tests pass in normal/ASan/TSan builds.
Direct Command-Q while the system Save panel is open remains an explicit keyboard
acceptance gap; Quit via the menu and Escape then Command-Q work. Imports,
mapping recovery, remaining entry paths and release gates are still open. See
[DOCUMENTS.md](DOCUMENTS.md) and the latest TODO evidence.


Defaults import foundation update (2026-09-20): `NativeDefaultsImport` provides an
explicit-origin, non-secret ordinary-settings projection with required omission /
conversion review and original source lines. The preferences store admits imports
only into absent native state and writes values plus an origin marker together in
defaults schema 11; resets preserve the marker. Profile/history schema remains 9.
No startup migration, XDG writer or credential/trust import is enabled. Candidate
discovery, import UI and history migration remain open; see [IMPORTS.md](IMPORTS.md).

Defaults source/review update (2026-09-20): `NativeImportPaths` and
`NativeDefaultsImportService` implement explicit XDG/home discovery and bounded
reads, with native-state precedence and no fallback on malformed/inaccessible
sources. Legacy import remains a separate request and respects existing current
XDG state. `NativeDefaultsImportState` owns exact preview approval, cancellation,
close/join and mapping revalidation; commits use the reviewed snapshot. These
services are not yet connected to startup or menus. First-use/import UI and
separate history migration remain open; see [IMPORTS.md](IMPORTS.md).

Defaults import UI update (2026-09-20): the File menu now opens a native defaults
import window with separate current and legacy review actions, affected categories,
redacted omissions, monitor mapping and explicit acknowledgement before commit.
Idle ordinary connection windows offer import when native defaults are absent;
dismissal is launch-local, and native-store errors never imply absence. Window
close and app shutdown cancel/join import work. A successful import offers a new
connection so existing windows retain their settings. The production view and
controller have an isolated interactive/automated fixture. History migration and
the remaining launch, mapping-recovery and release gates stay open.

History import foundation update (2026-09-20): separate history projection and
current/legacy source discovery now preserve the first 20 unique address strings,
require omission review, validate every bounded source line and retain an immutable
review with the shared native revision. Profile/history schema 10 records explicit
history initialization so new profile-only data can coexist with an import while
native/cleared history and all older records retain precedence. List, revision and
origin marker commit together through the existing private-file CAS. Defaults
schema remains 11. Separate history UI, first-use integration and end-to-end
migration remain open; see [IMPORTS.md](IMPORTS.md).


History import UI update (2026-09-20): a separate native review window and File-menu
action now complement defaults import. Explicit current/legacy choices show the
ordered address list and require acknowledgement for duplicates/older omissions.
An independent first-use offer uses fresh native history eligibility; success refreshes
the shared recent list without opening a connection. Close and app quit revoke callbacks
and join IO before store shutdown. Isolated automated and live fixture checks cover
consent, cancellation, native precedence and recent-list refresh. Broader mapping,
entry-path, physical-device and release acceptance gates remain open.


Explicit-file display recovery update (2026-09-20): unresolved or mirrored monitor
numbering now opens a manual native chooser; automatic assignments can also be edited.
The final review lists file-number/display-name pairs and still requires explicit
Open before creating an idle session. Sparse bounded mapping keys, immutable
file/base retention, connected-ID validation, topology revalidation and stale callback
guards preserve the existing document boundary. Production views are covered by an
isolated synthetic-display fixture. Import/export mapping recovery, physical display
acceptance, CLI and other full-plan gates remain open; see DOCUMENTS.md.


Export numbering recovery update (2026-09-20): Save As captures immutable session
settings before presenting an export-only numbering chooser for saved displays that
are disconnected or ambiguous. Automatic mappings can also be edited. Exact distinct
positive ordinals are shown in final loss review and never change live fullscreen
policy. Mapping and review share one sheet identity; only current review approval
hands off to the destination panel. Production sheet/serialization/lifetime tests
use isolated temporary output. Defaults-import mapping and broader acceptance remain
open; see DOCUMENTS.md.


Defaults-import display recovery update (2026-09-20): unresolved monitor numbers
now open a native display chooser; automatic assignments are editable from review.
Recovery retains only the ordinary-settings projection and redacted notices, never
excluded values or original bytes. Connected-display assignments create a fresh
review with separate omission consent. Stale callbacks, source changes, native-state
conflicts and changed display availability cannot substitute or overwrite reviewed
settings. The isolated fixture covers automatic/manual recovery, sparse numbers,
many-to-one choices, cancellation and close. See IMPORTS.md and the latest TODO
validation. CLI/entry-path, physical-device and release acceptance remain open.


Invocation foundation update (2026-09-20): the shared argument lexer now serves
both retained Configuration parsing and a stateless viewer invocation model. The
catalog derives encoding entries from the shared schema and records availability
for platform/TLS/audio/tunnel options. Ordered raw occurrences and exact argv
positions survive for typed validation; parsing performs no IO or global mutation.
Four C exports and a Swift owned-value wrapper expose the same model/catalog.
Semantic CLI resolution and native startup/authentication/listen/tunnel routing
remain required; no CLI parity is claimed. See [CLI.md](CLI.md).


Invocation value-resolution update (2026-09-20): decoded field validation is shared
with documents and exposed through an immutable canonical C/Swift copy. Native
injected requests apply ordinary CLI settings after defaults/profile and before
explicit files. Inactive cursor shape and deprecated migration flags survive file
review and monitor remapping, with explicit off overrides and correct provenance.
Unsupported adapters fail before source IO; cancellation prevents late session
admission. The executable bootstrap and remaining adapters are still required.
See CLI.md and the latest TODO validation; no full CLI/parity gate is closed.


CLI/file display-precedence update (2026-09-20): validated CLI fullscreen values
now remain pending until explicit-file fields are applied. Only surviving numeric
selections require a connected-display mapping; replaced CLI lists and stale host
assignments no longer reject a valid file. Inherited CLI selections enter the native
mapping/review flow with accurate source labels and actual resolved assignments.
CLI migration order, immutable recovery, cancellation, topology guards and no-store
writes are retained. Executable startup/no-file CLI recovery and other adapters
remain open; see CLI.md and the latest TODO evidence.


Executable CLI startup update (2026-09-20): the native app now strictly decodes raw
argv, handles help/version and redacted preflight failures before app/store startup,
and classifies retained-style file/socket operands with captured cwd semantics.
One process-local request belongs to the first ordinary window. Direct hosts connect
when ready; no-host options open an idle form, and files retain explicit review and
manual Connect. New windows and zero-window reopening do not replay options.
Unresolved no-file monitor selections now use a scoped connected-display chooser
with stale-identity/cancellation guards. Successful connections retain ordinary
recent-history behavior; resolution does not write settings. Remaining adapters,
credential-file/environment inputs, listen/tunnels and installed launch acceptance
remain open. See CLI.md and the latest TODO evidence; no full CLI/parity or release
gate is closed.


Outgoing CLI family selection update (2026-09-20): UseIPv4/UseIPv6 now flow through
owned per-session policy and the existing C connect options on each attempt.
Hostname lookup and numeric-address rejection use the shared connector; reconnects
retain policy, and Unix sockets remain usable with both IP families disabled.
File review/display recovery preserve these CLI-only settings. Save As explicitly
reviews their omission because the compatibility file has no matching fields.
Native stores and C ABI are unchanged. Listen/tunnel behavior and other CLI adapters
remain open; see CLI.md and the latest TODO evidence.


Pointer timing update (2026-09-20): PointerEventInterval now reaches the protocol
worker through an additive checked input-timing C creation API. Native sessions
use the shared retained 17 ms default, with explicit zero disabling delay. Timing
runs after middle-button emulation, bounds pending motion to one value, preserves
immediate button/wheel transitions and flushes motion before keys. Generation and
routing checks discard stale timers across focus/policy changes, overflow and
attempt teardown. CLI/file recovery retains interval/provenance; exports review
omitted timing. The ABI has 94 exports; native storage schemas are unchanged.
Other CLI adapters and full-plan acceptance remain open. See CLI.md and TODO.md.

Native CLI MaxCutText now uses the shared incoming clipboard default and a copied
per-session reader policy through an additive C API. Full retained bounds, zero,
file/export review, reconnect and independent UTF-8 retention budgets are covered.
Logging, geometry/maximize, credential inputs, listen/tunnels and the remaining
physical/installed/release gates still prevent declaring native parity.

Native CLI geometry and Maximize now own initial ordinary-window placement, using a
checked geometry parser shared with the retained viewer. Placement waits for session
admission and window attachment, precedes automatic fullscreen, and cannot replay
over later user resizing or a new connection window. Compatibility export reviews
the omitted policy. Native logging, credential inputs, listen/tunnels and physical/
installed/performance/release acceptance remain open.

Logging sink prerequisite (2026-09-20): shared file/stdio output serializes records
and file lifecycle changes, with caller-owned timestamp storage. Concurrency and
legacy-format tests pass under normal, ASan and TSan builds. Global registration
and writer configuration still require startup ownership; native Log remains
unsupported pending its policy, lifetime and redaction work. See CLI.md and TODO.md.

Logging policy update (2026-09-20): owned parsing and transactional catalog resolution
now preserve retained route order and defined level syntax without global mutation.
Invocation validation rejects level overflow before startup, even before help/version
or an overriding assignment. Startup route application and redacted output remain
unfinished; this prerequisite does not enable the native Log adapter.

Redacted output prerequisite (2026-09-20): a native sink now intercepts formatting,
retains known event context and audited numeric metadata, suppresses key events and
uses fixed output for unknown/preformatted messages. String/pointer substitutions
never reach printf. Its host must still establish process startup ownership and
apply validated routes before enabling Log; the app does not activate it yet.

Native process logging update (2026-09-20): stderr/stdout Log routes now activate
after executable preflight and before runtime creation, with retained `*:stderr:30`
default and redacted output. All routes/sinks prepare before publication; configuration
commits once and runtime creation permanently closes admission. The process owner
outlives joined runtime shutdown, then detaches writers before closing owned stream
duplicates. This adds two C exports (99 total), with no session/store replay or schema
change. File logging and remaining logging/help/installed acceptance stay open.


Native file logging update (2026-09-20): `Log=*:file:30` now uses lazy private
`/tmp/vncviewer.log` output with one backup and a persistent nonblocking lock
sidecar. Unsafe/unavailable files or write failures switch to redacted stderr.
The additive FILE_LOGGING host-path configure call shares the one-time startup
gate (100 C exports). Tests use private paths and exercise separate-process
ownership through runtime drain, redaction and rotation after owner exit.
Logging/help/localization/installed acceptance remains open; see CLI.md and TODO.md.


Password-file primitive update (2026-09-20): a shared caller-owned decoder and
consuming raw-byte C/Swift prompt reply now preserve legacy non-UTF-8 passwords.
The native reader bounds access to one regular-file block, with cancellation,
metadata checks and explicit clearing. PASSWORD_FILE_REPLY adds one export (101
total). Launch credential ownership, environment precedence, scoped retry/drain
and native PasswordFile CLI admission remain open; these primitives do not enable
ungated file reads or automatic credential persistence.


Launch credential integration update (2026-09-20): PasswordFile/passwd and captured
VNC_USERNAME/VNC_PASSWORD now belong to the first connection window, with exact
endpoint scope, retained precedence, raw-byte replies, prompt/epoch admission and
drained cancellation. Inputs are never persisted or passed to subsequent windows.
The additional byte reply keeps existing UTF-8 API semantics (102 C exports).
Storage setup copies only path variables. File failures support explicit native
prompt recovery. See CREDENTIAL-INPUTS.md; installed/physical/release acceptance
and the rest of the plan remain open.

The reverse listener now crosses the C/Swift boundary with copied events, explicit
handoff into configured reusable sessions, coalesced readiness callbacks and joined
listener/session runtime shutdown. NativeListener owns MainActor delivery and
listener-scoped peer tokens. The app integration below applies the incoming
presentation and reverse identity policy; installed acceptance remains required.
See LISTEN.md. No listener state polling was added to the native layer.

Manual reverse connections now have a native listener window with port/family
controls, explicit peer admission and independent incoming windows. Settings resolve
through NativeSessionDefaults before handoff. Reverse identity is connection-only:
temporary source ports cannot become saved history, credentials/trust decisions,
exported destinations or outbound retry targets. Listener/window/quit cleanup uses
the existing asynchronous drain contracts. Numeric CLI `-listen [port]` now opens
and starts a listener once, carries CLI settings to incoming sessions and transfers
captured credentials to only the first opened incoming window. Stop/close clears
unclaimed inputs. Native ports use checked decimal 0–65535 instead of unchecked
retained `atoi`. Explicit file startup now resolves defaults/CLI/file settings and
display mapping for review without a session or bind. Approval freezes configuration
and metadata for incoming windows; they do not reread preferences or the source.
Unix socket listeners remain unsupported. Full app interaction and installed reverse
acceptance remain open; see LISTEN.md and the 2026-09-21 TODO evidence.

Tunnel work now has a routed socket boundary preserving the logical target name,
an owned SSH master/control process service with isolated real OpenSSH/RFB tests,
and route-scoped credential retention/launch inputs. App/CLI admission, route-aware
history/profile/export behavior, interactive SSH authentication/trust/configuration
and deployment/installed acceptance remain open. See TUNNELS.md and RESUME.md;
the complete plan remains active.

Route persistence follow-up: NativeSSHGateway now validates independently of a
remote target. Profile/history schema 11 and the history queue retain complete
server/gateway destinations; compatibility export requires a separate gateway-loss
acknowledgement. Initial app selection and attempt ownership are now wired and
replace the temporary routed-profile rejection. Dedicated app tunnel lifecycle
validation and CLI integration remain open. See TUNNELS.md for the migration and
next integration step.
