# Native UI architecture and macOS SwiftUI migration

Status: started; N0 source audit, baseline validation and initial session
isolation prerequisites (DES schedules, Tight gradient scratch and explicit
authentication/TLS policies, session-owned JPEG negotiation and clipboard limits,
and owned security-policy strings) are recorded in
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

Proposed structure; use actual repository conventions during N0 refinement:

```text
common/{rfb,network,rdr,core}/    Existing protocol foundation
viewer/core/                   Session, configuration, input policy, frames
viewer/api/                    C ABI headers, implementation, module map
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

Use narrowly scoped secret buffers, redact all diagnostics, clear owned mutable
buffers at release and minimize Swift string copies. Do not claim guaranteed
zeroization of every OS/Swift runtime copy. Replace current process-static saved
credentials with session-scoped lifetime; disconnect/Forget clears retained data.

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

The display adapter supplies immutable topology snapshots with stable opaque IDs,
backing scales and generation. No persisted monitor array indices. Reconcile
missing monitors, negative origins, hotplug and changing Spaces safely. Preserve
windowed/current/all/selected-monitor fullscreen, reconnect layout and spanning
behavior; test native fullscreen versus coordinated borderless windows before
selecting the implementation. Do not assume SwiftUI's window modifiers alone
reproduce the current multi-display behavior.

Input carries remote coordinates, buttons, wheel units and physical key identity
plus logical text where supported. Reuse audited keysym/scancode mappings. Handle
modifier-only events, repeats, focus loss, shortcut interception, Unicode/IME
policy, different keyboard layouts and dead keys explicitly. Do not emit both a
text event and key event for the same input without defined protocol semantics.
One session owns remote pressed-key/button state across all its views. Focus
loss, disconnect, sleep or capture revocation sends release-all/reset. View-only
is enforced in the core, including synthetic menu shortcuts.

Clipboard send/receive settings are independently enforced; focus and session
routing prevent broadcast to every connected server. Define text encoding,
newline conversion, maximum size, generation and loop prevention. Preserve
supported extended clipboard behavior; do not silently add file/image transfer.
A remote framebuffer is not a semantic accessibility tree for the remote OS;
make the local view/status/actions accessible without promising remote controls
that the VNC protocol does not describe.

## 9. SwiftUI replacement inventory

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

## 10. macOS integration and packaging

Keep `io.github.jkeli.tidyvnc`, icons, document types, Local Network usage text and
credits. Use a SwiftUI app entry point with an AppKit delegate/coordinator only
for native integration; never start two competing application event loops.
Build C++ libraries with CMake, expose an importable C module, and use an Xcode
app target as the initial bundle/test authority. Provide a scripted reproducible
CMake-library → xcodebuild app/test/package path, explicit SDK/architecture/
deployment settings and generated dependency inputs. No hand-copied developer
build paths or duplicate version/Info.plist sources.

Add a frontend selector scoped to the viewer (proposed `TIDYVNC_UI=FLTK|SWIFTUI`).
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
