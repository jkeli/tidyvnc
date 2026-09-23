# Native UI implementation checklist

Tracker for [PLAN.md](PLAN.md). Baseline: `4e07cc16`, inspected 2026-09-18.
**Resume here:** [RESUME.md](RESUME.md), updated 2026-09-23, records the current
implementation, validation and next steps. N0.1/N0.2 now have a **162-row**
[parity map](PARITY.md) and a complete **47-parameter** [capability inventory](CAPABILITIES.md),
checked against the built catalog and both executable help outputs. The inventory
identified AlertOnFatalError; its scoped native implementation and model/CLI tests now pass. The native `--test` build passes
**3/3 viewer, 756/756 core and 89/89 native tests**, plus graph/configuration,
localization, signature and 36 CLI checks. Local native app/DMG dependency assembly
and mounted-image inspection pass; see [PACKAGING.md](PACKAGING.md). The actual native
55-case protocol baseline now passes, with the retained FLTK 55-case regression;
see [PROTOCOL.md](PROTOCOL.md). Native CI is
defined but hosted execution is unverified. A real SSH exit race is fixed with deterministic/repeated/sanitized
proof; compiler localization freshness uses successful-build content receipts.
The app has **1052 UI + 2 InfoPlist entries**, compiler coverage of **139 sources /
1353 call sites**, and FLTK remains the default. See [BUILD.md](BUILD.md) and the
latest evidence below. The complete migration, including interactive/physical/
installed/deployment/CI/release gates, remains open.
**Completed: N0.1/N0.2 inventories, N0.3 audit, N1.1 headless build boundary, N1.7 window-independent session, N1.8 retained publication contract, N1.10 cancellable authentication prompts, N1.11 real authentication/cancellation proof, N1.12 bounded input/event queues, N2.3–N2.7 native ownership/app vertical slice, and N6.1/N6.3 frontend selection/test separation. N1.2, N1.4, N1.5, N1.6 and N1.13 are in progress.** Check an item only after
its code and stated validation are complete;
record commit, commands/results, platform/build and remaining limitations in the
evidence log. A blocked hardware/signing check stays unchecked, not waived.

Scope: portable session/service interfaces and macOS SwiftUI replacement.
No WinUI application or Windows backend implementation is included. Preserve
Windows/Linux FLTK builds. The Java client remains removed.

## Current committed checkpoint

**`dc065580`** contains the native CLI startup fix, isolated 55-case protocol
baseline, numeric viewport diagnostic and CI definition. Its Debug and protocol
reports pass; the existing Release package predates those changes. Follow the
[ordered execution handoff](RESUME.md#committed-checkpoint-and-next-execution-order)
for current Release/package validation, remaining service/global-state and broader
protocol work, then actual interaction/physical/performance and deployment gates.
This planning update adds no acceptance evidence and changes no completion boxes.

## N0 — Inventory, baseline and decisions

- [x] N0.1 Create an exhaustive parity inventory mapping each dialog/control/menu/shortcut/launch path to source, option, native replacement and acceptance test; include every row of PLAN §9. See [PARITY.md](PARITY.md): 162 rows, registered fixture references and explicit remaining manual actions; acceptance is still N4/N5/N6.
- [x] N0.2 Record actual security/encoding/audio/H.264 capabilities, compiled defaults, aliases, validation ranges and live-change versus reconnect semantics. See [CAPABILITIES.md](CAPABILITIES.md): all 47 parameters, three aliases, actual linked-library capability/default query and both executable help catalogs.
- [x] N0.3 Audit reachable global configuration, static credentials, timer lists, logging and crypto initialization; identify per-session ownership and compatibility obligations to server/FLTK consumers. See [STATE-AUDIT.md](STATE-AUDIT.md).
- [ ] N0.4 Capture baseline native FLTK screenshots and keyboard/focus behavior; record hardware, OS, SDK, dependency versions, build flags, test totals and protocol results.
- [ ] N0.5 Capture matched performance workloads and budgets: idle/scrolling/1080p/4K/multi-view, p50/p95 latency, CPU, memory, copies and damage. Record existing scaling budget requirements and provisional 10% regression threshold.
  - [x] Matched idle/scroll/1080p/4K workload harness and first local baseline
    (CPU, peak RSS, sustained update rate) for FLTK and native: see
    [PERFORMANCE.md](PERFORMANCE.md). Native keeps the offered 30/s at lower CPU;
    4K RSS within 3%. Presentation latency p50/p95, copies, damage and multi-view
    remain unmeasured.
  - [x] Native presentation latency p50/p95 (update written → frame on main actor →
    AppKit draw → next refresh target), presentation copies (resampled bytes per
    frame), damage fraction and a two-view workload, with `native-presentation-probe`
    and `viewer-workloads.py --probe [--probe-views 2]`, plus a small-damage `patch`
    workload. Release full-frame draw p50 is 14–16 ms, the patch about 3 ms, and a
    second view adds about 3–4 ms and 0.4 CPU s/s ([PERFORMANCE.md](PERFORMANCE.md)).
  - [ ] FLTK presentation latency (no matching draw hook), allocation rate, mixed
    displays, a second machine and sign-off budgets.
- [ ] N0.6 Validate provisional macOS 14 deployment floor, Xcode/Swift/C++ versions, architecture matrix and dependency targets; record final supported configurations.
- [x] N0.7 Confirm C ABI/module-map/Swift wrapper and CMake-to-Xcode build arrangement; decide CLI app-executable versus launcher behavior without relaying secrets in arguments. Decision (closed 2026-09-23): the app executable is the CLI (same-process bootstrap, no launcher/relaunch); secrets come only from captured `VNC_USERNAME`/`VNC_PASSWORD` or PasswordFile and never enter argv. All 47 parameters, listen and `via` have native adapters (CAPABILITIES.md), with 36 terminal cases on the development and packaged apps; one CMake core → Xcode path (BUILD.md) and the `TidyVNC` module map/Swift wrappers are in use.
  - [x] Shared stateless CLI syntax/catalog, retained lexer reuse, C ABI and Swift
    ownership wrappers. See [CLI.md](CLI.md).
  - [x] Same-process app-executable bootstrap with strict raw argv, pre-store
    help/version/errors, file/socket classification and first-window ownership.
    Native option/authentication/listen/tunnel completeness remains open.
- [ ] N0.8 Prototype AppKit desktop view/fullscreen coordination in SwiftUI, including mixed displays and Spaces; record chosen window strategy.
- [x] N0.9 Select Keychain backend, item attributes/access policy, local-only behavior and signing prerequisites; document development versus production limitations.
  - See [KEYCHAIN.md](KEYCHAIN.md): SecItem/Data Protection, local-only unlocked
    access, per-call interaction policy and provisioned application identity;
    ad hoc builds do not establish production access or upgrade acceptance.
- [x] N0.10 Review service/ABI contracts for OS-specific types, ownership, cancellation and errors; resolve gaps before extraction. Record decisions in PLAN or a linked decision log. Closed 2026-09-23 with the decision records: ABI — `tidyvnc.h` includes only `stdint.h` and exposes only fixed-width values, spans and opaque handles (enforced by `tests/viewer/headless.py`; see N2.1/N2.2/N2.9); services — the per-service audit and follow-ups under N1.9 (contracts, fakes, typed errors, deliberate process-wide exceptions, platform-owned path policy); cancellation/drain — N1.5/N1.6/N1.13 and STATE-AUDIT.md.

Exit: reviewed inventory and decision record; baseline evidence exists. No screen
may disappear merely because it is absent from an initial mockup.

## N1 — Portable session engine and services

- [x] N1.1 Create GUI-independent core/service targets with clear dependency direction; prove clean configure/build without FLTK, SwiftUI, AppKit or WinUI. See the N1.1 evidence below and [build instructions](../../viewer/README.md).
- [x] N1.2 Extract endpoint parsing/normalization, typed options, capabilities, structured errors and settings schema; preserve endpoint syntax, option aliases/ranges and precedence. Closed 2026-09-23: every parameter's grammar, aliases, ranges and canonical form is in core (the 36/9 audit below plus the moved DesktopSize, port and `via` grammars), with structured errors through the C ABI. Precedence is preserved and tested in the frontend's layer composition; the selected-monitor stable-ID rules (native display identities) and the post-merge deprecated migrations are frontend-owned by design, as recorded in HANDOFF.md.
  - [x] Owned endpoint values and a shared checked VNC address parser, preserving
    original labels, IPv6 scopes, Unix paths and tunnel-route identity. See the
    N1.2 endpoint evidence below; options/schema/capabilities remain open.
  - [x] Encoding/color schema, immutable snapshots, aliases, layered precedence
    and provenance, compiled decoder choices and shared automatic policy; wired
    into core sessions and retained FLTK. Other settings/capabilities remain open.
  - [x] Security method catalog with compiled availability, exact bounded allow-list
    parsing, checked C results and immutable native defaults/profile application.
  - Parameter audit (2026-09-23) of all 47 CAPABILITIES.md parameters: 36 are
    validated/canonicalized in core (`InvocationSyntax::validatingValues`,
    `documentOptionValue`, `EncodingOptions`, `SecuritySelection`, `ScalingSettings`,
    `WindowGeometry`, `LoggingPolicy`), 9 in core and re-checked in Swift, 4 are
    platform exclusions. Fixed: command-line `GnuTLSPriority` skipped the core GnuTLS
    preflight; `validatingValues` now calls `validateTLSPriority` (mutation-checked
    regression test). **Swift-only, to move for N1.2:** `DesktopSize` grammar (legacy
    CLI `%dx%d` and strict `WxH`), `via` gateway grammar/limits/canonical URI and the
    via+listen conflict, `PasswordFile` path policy, `X509CA`/`X509CRL` path policy,
    the listen port operand and both-families-off rule; plus FullScreenSelectedMonitors
    ID/cap rules, the two deprecated migrations and layer order (`NativeOptionOverlay`),
    which also keep N1.3 open.
  - [x] Moved to core (2026-09-23): `DesktopSize` (both grammars), the strict decimal
    port (listen/gateway) and the `via` gateway grammar/limits/canonical URI, exported
    as `tidyvnc_desktop_size_parse`, `tidyvnc_port_parse` and
    `tidyvnc_ssh_gateway_create/get` (`TIDYVNC_FEATURE_PARAMETER_GRAMMARS`). Swift now
    calls them; gateway route/intent identities are pinned and identical before and
    after (checked against the committed Swift parser). Decided host-owned:
    PasswordFile and X509CA/CRL path resolution (platform path semantics, part of the
    N1.9 file services). Remaining for N1.2: FullScreenSelectedMonitors ID/cap rules,
    deprecated migrations and layer order. `run-h996jb49` passes 3/768/90; Linux ASan
    765/765 with zero warnings.
- [x] N1.3 Extract shared configuration/document validation from FLTK/global parameter mutation; distinguish app defaults, profiles, session overrides and CLI inputs. Closed 2026-09-23: document syntax/semantic validation and invocation validation are shared core code with no global mutation (subitems below); native layers keep distinct app-default, profile, session and CLI/file sources with per-field provenance (`NativeInvocation.ResolutionAndPrecedence`, `FileMonitorPrecedenceAndRecovery`, document resolution tests). Transactions are per store (revisioned records). Layer composition stays with each frontend's typed model (HANDOFF.md).
  - [x] Extract owned, bounded connection-document syntax and non-secret export
    serialization; retained FLTK load/save/import uses the shared codec. See
    [DOCUMENTS.md](DOCUMENTS.md). Native file flows remain open.
  - [x] Shared known-field semantic validation, copied C/Swift queries and immutable
    native document-to-session resolution with explicit-file precedence, provenance,
    deprecated migrations and required review of ignored fields. Explicit Open,
    new-window integration and review identity handling are implemented below;
    live export, Save As, Finder delivery and ordinary CLI/file precedence are implemented below; remaining CLI adapters stay open.
  - Encoding settings now share validation and explicit layer resolution. Full
    document transactions and remaining parameter groups are still open.
- [x] N1.4 Replace mutable session-global options, security configuration, timer ownership and reconnect credentials with scoped state. Preserve compatible legacy consumers without introducing races. Closed 2026-09-23 against the row-by-row reconciliation in STATE-AUDIT.md ("N1.4 global-state reconciliation"): every native-reachable row is session/host-owned or resolved (GnuTLS lifetime, client randomness, socket setup); the rest are FLTK/server-only single-thread consumers kept for compatibility. The required integration test (N1.14) and the full core suite pass under ASan/UBSan and TSan on Linux and macOS.
  - Completed prerequisites: caller-owned DES schedules for client/server VNC
    authentication/password-file helpers, invocation-owned Tight gradient
    scratch rows, explicit per-connection authentication/TLS policies, and
    session-owned JPEG negotiation and incoming clipboard limits, plus owned
    security-policy serialization and session-scoped reconnect credentials;
    see evidence below. Other audited globals remain open.
  - Encoding snapshots and monotonic bandwidth policy are now session-owned in
    the portable core; FLTK captures legacy settings on host-thread callbacks.
- [x] N1.5 Implement session/listener lifecycle, commands, operation completion and generation-tagged ordered events; test invalid transitions and initial snapshot subscription.
  - Established attempts and reusable sessions now have a production serialized
    worker and bounded runtime.
  - [x] Command catalog reconciled with PLAN §4.2 (2026-09-23): createSession →
    `tidyvnc_session_create_with_message_limits`; connect → `session_connect`/
    `connect_routed`; listen/accept → `listener_create/subscribe/accept/reject/stop`;
    applyOptions → `apply_encoding`, `set_security`, `set_shared`,
    `clipboard_policy`, `input_policy`, `view_only`; sendInput → `key`, `pointer`,
    `focus`, `release_input`; `refresh`; `request_desktop_layout`; respond →
    `reply_credentials`/`reply_credential_bytes`/`reply_password_file`/`reply_trust`;
    `cancel_operation`; `disconnect`; closeAndDrain → `close` + `poll_drained`;
    frames → `take_view`; events → `subscribe`/`snapshot`/`take_event`. Every session,
    listener and runtime command is called from the native app (the other two
    `session_create*` exports are narrower overloads). Invalid transitions:
    `SessionWorker.CommandsRejectInvalidStateAndGenerationWithoutCompletion`;
    initial snapshots: `SessionEvents.StartsWithOwnedCurrentSnapshot`,
    `ProtocolSession.EventSubscriptionStartsWithCurrentConnectedSnapshot`,
    `ListenerWorker.InitialSnapshotOrderedLifecycleAndRetainedEvents`. The sketch's
    disconnect "reason" is host-side presentation state, not a core parameter.
  - [x] Established-attempt Authenticating/Disconnecting/terminal state ownership,
    typed end reasons and bounded asynchronous refresh/encoding commands with
    reserved completions, generation checks and cancellation before execution.
  - [x] Reusable session worker, stable mailboxes/publication budget/settings,
    attempt generations, connect/disconnect completion and cancellation, immediate
    retry after terminal state, stale prompt protection and permanent joined close.
  - [x] Validated remote desktop layout requests, server capability/topology
    snapshots, single queued/in-flight resize, server-result/timeout completion,
    late-reply isolation and close/reconnect cleanup. Native resize policy remains open.
  - [x] Bounded clipboard offer/withdraw commands and retained receive channel,
    independent send/receive policy, focus/generation routing, remote-origin echo
    suppression and reconnect-safe budgets. Native clipboard integration stays open.
  - [x] Listener C/Swift boundary: copied ordered events, explicit peer handoff into
    configured reusable sessions, coalesced callbacks and joined runtime shutdown.
    Manual/numeric CLI presentation and connection-only reverse identity are now
    implemented; reviewed file listening is implemented below, while installed
    acceptance remains open.
  - [x] Separate bounded listener runtime, ordered Starting/Listening/Stopping/
    terminal events, bounded incoming peers, expiry, explicit accept/reject,
    peer handoff into session workers and joined asynchronous close.
- [x] N1.6 Separate socket readiness/monotonic scheduling from UI loops; implement cancellation/wakeup and test timer teardown. Public contracts do not expose POSIX descriptors. All subitems are complete, including glibc Linux hostname lookup (2026-09-23 evidence below). A stalled macOS mDNSResponder IPC call and non-glibc Linux hostnames remain documented limitations, not hidden fallbacks.
  - [x] Bounded per-session monotonic scheduler, cross-thread cancellation tokens
    and host wakeup seam; integrated statistics throttling and publication retry
    with close/reconnect teardown. See the N1.6 timer evidence below.
  - [x] Owned established-socket transport, concrete worker wakeup/cancellation,
    readable/writable waits and independent FIN observation for parked prompts.
    Real VNC/TLS fixtures now use the adapter. See the N1.6 transport and
    established-attempt worker evidence below.
  - [x] Prepared endpoint attempts, asynchronous macOS DNS, bounded nonblocking
    TCP/Unix connection attempts, stage-specific failures and cancellation across
    worker handoff. See connection-setup and reconnect evidence below.
  - [x] glibc Linux hostname lookup through `getaddrinfo_a`, with cancellation and
    deadline abandonment released by the resolver's own completion; non-glibc
    hostnames stay explicitly unsupported. See the 2026-09-23 Linux evidence.
  - [x] Prepared numeric TCP listener source, cancellable poll/accept, IPv4/IPv6,
    shared ephemeral port, partial-bind rollback and independently owned accepted
    transports. See listener evidence below; native listen wiring remains open.
- [x] N1.7 Remove window/widget ownership from the session; introduce attach/detach view subscriptions and presentation-independent framebuffer ownership. Implemented by the portable `ProtocolSession`; see evidence below. Retained FLTK remains a comparison adapter.
- [x] N1.8 Implement retained frame/cursor leases, explicit pixel format/stride/origin, damage and size generations; bound memory and merge skipped damage correctly. See N1.8 evidence below; session/frontend integration remains in N1.7/N2.
- [x] N1.9 Define and inject PreferencesStore, ProfileHistoryStore, CredentialStore, TrustStore, document/file, clipboard, display/window/input, access, tunnel and app services with typed errors. Closed 2026-09-23 after the audit and follow-ups below. Per service: preferences, profile/history, credential, trust (saved `NativeStorageError`, legacy `NativeTrustStoreIssue`), clipboard, tunnel, bell and display have injected contracts, fakes and typed errors; document/file access is the injected `NativeDocumentReading`/`NativeDocumentWriting`/`NativePasswordFileReading` services (security-scoped access is internal to them); permission access is typed guidance (Local Network connection issues, since macOS offers no query API; Accessibility via `NativeKeyboardCaptureStart`); app services are the injected `AppServices` value, tested by `NativeApp.ProductionWiring`. Deliberately process-wide: redacted process logging (one process log policy), the SwiftUI launch hand-off (`App` has no initializer arguments) and `NSApp` terminate/About. Help reads bundled resources with an explicit localized fallback, verified by bundle inspection.
  - Clipboard protocol/channel boundary, injected native pasteboard adapter and
    active-session routing are implemented. Visible app-control/activation checks
    remain N3.15. Diagnostics copying now uses the coordinator's `copyLocal`
    instead of writing `NSPasteboard.general` on the main thread (2026-09-23).
  - Audit (2026-09-23), per service. **Contract + fake + typed errors:** preferences
    (`NativePreferencesBacking`/`NativePreferencesStore`, `NativePreferencesError`),
    profile/history (`NativeAtomicFileBacking`, `NativeStorageError`), credentials
    (`NativeCredentialBacking`/`NativeSecItemClient`, `NativeCredentialStoreIssue`),
    clipboard (`NativePasteboardAccess`, `NativePasteboardError`), tunnel
    (`NativeTunnelOwning`, `NativeTunnelError`), bell (`NativeBellSounding`).
    **Partial:** trust (two error families; legacy store built with `try?`; foreign
    errors collapse to `.unavailable`), document/file (no writer fake, inline
    open/save panels, save issue as `String`; the reader's `CancellationError` is
    deliberate Swift task cancellation, mapped to `.cancelled` by its callers), display/window/input (direct `NSScreen`/`NSApp.isActive`/
    `NSWorkspace` reads in fullscreen, startup and desktop code). Keyboard capture
    now reports `.active`/`.accessibilityRequired`/`.failed` (2026-09-23): a trusted
    tap failure gets its own recovery text instead of misleading Accessibility
    advice (catalog 1053 keys; `run-ayzryxkl` passes 3/762/89). **Missing:** an access/permission service (Local Network,
    Accessibility, security-scoped file access repeated inline) and app services
    (static launch hand-off, static process logging, direct `NSApp` quit/About,
    `Bundle.main` help resources, `String` startup failures). Stores take concrete
    actors; faking happens at the storage layer. Close N1.9 only after the access
    and app-service contracts and typed errors exist.
  - [x] Production wiring under test (2026-09-23): `AppCoordinator(services:)`
    takes an `AppServices` value (`.production()` by default) for clipboard, bell,
    displays, credential/trust/profile stores, environment, runtime and preference
    backing. `NativeApp.ProductionWiring` compiles the real coordinator and every
    app source except the `@main` entry with memory stores and fakes, and checks
    that Settings/profiles use the injected stores and that each connection window
    gets its own session with the app bell and pasteboard copy action. Removing the
    coordinator's bell assignment makes it fail. `run-jrw1fso9` passes 3/762/90.
  - Reviewed: the remaining direct `NSScreen` reads are inside the AppKit adapters
    (`AppKitFullscreenWindows`, window startup placement, fit-to-desktop), which must
    create/place windows on concrete screens; their geometry is pure and tested.
- [x] N1.10 Bridge synchronous authentication/trust callbacks with the cancellable worker rendezvous; hold no shared locks and never block the main thread. Implemented by `PromptAuthentication`; see evidence below. Real TLS/socket cancellation is verified by N1.11 below.
- [x] N1.11 Prove real VNC/TLS authentication, prompt cancellation, timeout/peer closure and close/quit while a request is outstanding; reject stale/duplicate responses after reconnect. Loopback TCP/GnuTLS proof at the core/host boundary; see evidence below. Production reactor and native close/quit wiring remain separate items.
- [x] N1.12 Implement bounded input/event queues, coalescing rules and release-all on focus loss/overflow/disconnect; keep view-only enforcement in core. See input and event evidence below; the full lifecycle/command catalog remains N1.5.
  - [x] Bounded keyboard/pointer mailbox and held state, motion coalescing, core
    view-only enforcement, release barriers, reconnect invalidation and RFB wire
    tests. See the N1.12 input evidence below.
  - [x] Ordered event/completion queues, reserved completion capacity, statistics
    coalescing and terminal overflow rules, integrated with protocol events and
    refresh operations. See the N1.12 event evidence below.
- [x] N1.13 Implement disconnect/drain with cancelled IO/prompts/timers/subscriptions and joined decoder work; repeated close and partial construction failure are safe. Core ownership is complete (subitem below). App integration (2026-09-23 review): `AppCoordinator.requestQuit` stops panels/imports/clipboard/displays, closes every connection model including reverse windows (they register in `windows`), awaits `NativeRuntime.shutdown()`, each model's `close()`, listeners and every store actor's `close()`, then replies to `applicationShouldTerminate`. Acceptance of quit with pending IO/auth/store work remains N6.10; that wiring is not yet under test (see the N1.9 audit).
  - [x] Established-attempt worker/runtime ownership, direct prompt/readiness
    cancellation, nonblocking handle release and completion after joined workers
    and protocol/transport disposal. Endpoint setup now shares cancellation and
    joined cleanup. Listener teardown now has separate bounded/joined ownership.
    Service requests and native app-level
    runtime shutdown integration remain open.
- [x] N1.14 Test two simultaneous sessions with different security/settings, one awaiting credentials while the other continues; no secret, modifier, clipboard or option leakage. `SessionWorker.SimultaneousSessionsIsolatePromptSecretInputClipboardAndSettings` (2026-09-23 evidence below) exercises this at the production runtime; `ViewerABI.AnotherSessionProgressesWhileCredentialsAreParked` covers the C boundary. Native multi-window/app-quit isolation remains N6.10.
- [x] N1.15 Run existing applicable unit suites plus deterministic core/service tests with fake stores, transport, scheduler and event sink; run supported sanitizers and record limitations. 2026-09-23: retained FLTK 782 unit; portable core 762 (macOS) / 759 (Linux) with fake transport, scheduler, event sink and prompt fixtures; 89 native Swift tests with fake preferences/history/credential/trust/pasteboard/tunnel/display backings. Sanitizers: full core suite under Linux ASan+UBSan+LSan and TSan, and macOS ASan+UBSan and TSan, crypto enabled; full native Swift suite under macOS ASan and TSan. Limitations recorded in the evidence section below.
- [ ] N1.16 Keep the FLTK frontend building and exercising the extracted logic during transition; shared server behavior remains unchanged.
  - 2026-09-23: a local reproduction of the Linux CI job (Ubuntu 24.04 aarch64,
    GCC 13.3, pinned FLTK 1.4.5, Debug `-Werror`, NLS/H.264/audio/GnuTLS/nettle/PAM/
    systemd/pwquality/Wayland on) failed: `vncviewer.cxx` included `<FL/platform.H>`
    only on Apple since the FLTK 1.4.5 upgrade (X11 lost `fl_open_display`/`Window`),
    plus GCC-only shadow and `fclose`-attribute errors. After the fixes it builds with
    zero warnings, passes 775/775 unit tests, produces the tarball and the viewer runs.
    macOS FLTK Release passes 782/782. Stays open as a standing obligation until cutover.

Exit: headless, reusable session engine; lifetime and authentication boundaries
are proven before substantial SwiftUI screen work begins.

## N2 — C ABI, Swift bridge and working native slice

- [x] N2.1 Define versioned `tidyvnc_` C exports, opaque handles, size-tagged structs, explicit enum values, spans and release functions; document each call's thread/ownership contract. Closed 2026-09-23: 117 status-returning exports cover the PLAN §4.2 catalog (map under N1.5) plus settings/parameter grammars; a scripted check found every export under a contract comment after documenting the prompt take/get pair. Future exports must keep these guarantees (N2.2).
  - [x] Initial runtime/session/event/image/input/prompt surface with explicit
    capability negotiation, checked non-reused IDs and ownership documentation.
    Clipboard, encoding and remote-layout exports/Swift ownership are now included.
    Listener and remaining settings exports remain open.
  - [x] Bounded shared tile-renderer handles, copied result metadata, retained-frame
    input, cache/history isolation and pure-C/concurrent/failure validation.
  - [x] Stateless shared damage mapping with filter halos, rounded placement and
    pan; checked C values, no-write failures and differential geometry tests.
  - [x] Immutable shared cursor sampler with copied source ownership, bounded
    tiles, alpha filtering/hotspots, concurrent reads and allocation-failure tests.
  - [x] Stateless shared scaling-parser export, explicit mode IDs/capability,
    copied canonical values and pure-C/concurrent/Swift boundary tests.
  - [x] Stateless shared endpoint-validation export, capability and bounded Swift
    wrapper; typed errors and parity with Connect before operation admission.
  - [x] Owned immutable connection-document handles, copied entries/metadata,
    deferred decoding and transactional export buffers; typed redacted errors,
    pure-C/Swift readers, allocation-failure and concurrent ownership tests.
  - [x] Shared encoding schema/choices, immutable sourced option snapshots, initial
    session configuration and async live apply; structured validation and pure-C/
    Swift ownership/wire tests. Native encoding UI/preferences remain N3/N4.
  - [x] Owned coherent remote-layout snapshots, shared geometry validation and
    async server-completed resize commands, including typed rejection/timeout,
    bounded 255-screen copies and Swift cancellation/drain.
- [x] N2.2 Catch all exceptions at the boundary; validate lengths/overflow/versions/handles and return structured errors. Test failure paths from a pure C caller. Closed 2026-09-23: the single `call` boundary maps every exception to a status; new exports have version-mismatch, wrong-kind, stale-handle, invalid-input no-write and per-position allocation-failure tests (`ViewerABI.SSHGatewayHandlesAreOwnedTypedAndAllocationSafe`, `DesktopSizeGrammars…`), and the pure-C smoke calls them on macOS and Linux (Release/ASan/TSan).
  - [x] Initial surface catches exceptions, validates arguments and rejects stale/
    wrong-type handles; pure C tests inject 48 allocation-failure positions.
    Continue these guarantees as remaining exports are added.
- [x] N2.3 Implement callback context retention, subscriptions, exactly-once completions and drain semantics; test destruction with queued callbacks and retained old frames.
  - [x] C subscriptions retain/release context, coalesce readiness on a bounded
    dispatcher, preserve completion mailboxes and expose unsubscribe/drain plus
    generation validation. Tests cover queued/running cancellation, reentry and
    frames retained through shutdown. Swift queued delivery now owns its captures,
    coalesces readiness, validates generation and acknowledges invalidated work.
- [x] N2.4 Add module map and Swift owning wrappers with async commands, typed errors and MainActor state; prevent unsafe borrowed pointers escaping callbacks.
  - `TidyVNCNative` builds in Swift 6 strict concurrency mode, with observable
    MainActor models, owned images, copied prompts and reserved async completions.
    Extend these guarantees when the remaining C surface is added under N2.1.
- [x] N2.5 Implement explicit async close and safe nonblocking cleanup; no main-thread worker join or nested event loop.
  - Native runtime/session close awaits protocol, callback/context and queued host
    delivery drain. Caller cancellation does not cancel cleanup; deinit only
    cancels/releases. App/window quit coordination is integrated under N2.6;
    the broader responsiveness matrix remains N2.8.
- [x] N2.6 Create SwiftUI app shell with AppKit lifecycle coordinator and `NSViewRepresentable` desktop view; link the C++ core without FLTK.
- [x] N2.7 Connect to a controlled loopback server, show/cancel authentication, display updates, send keyboard/pointer and disconnect/reconnect using the native path.
- [x] N2.8 Verify UI responsiveness during slow DNS/connect/auth/decoding and quit; test active frame resize while view/session is removed.
  - Native auth cancellation/quit and 12 view removals with resize in flight pass.
  - 2026-09-23 `NativeBridge.OwnershipAndLoopback` adds a measured MainActor heartbeat
    (5 ms ticks) across a pending connect to a bound, non-listening loopback socket
    (still pending at 400 ms, cancelled in under 1 s), 256 full-frame raw 1024×768
    updates (768 MiB decoded in about 0.3 s with ~50 ticks during the window) and
    close/runtime shutdown while a second 256-frame flood is in flight (drained in
    3–7 ms). Worst tick gap 8–11 ms over three runs (limit 250 ms); slow
    authentication is covered by the parked-prompt heartbeat test. Slow DNS: macOS
    DNS-SD work runs on the session worker with cancellable readiness (core tests);
    a stalled mDNSResponder cannot be simulated without changing system settings.
    The glibc resolver's stalled-lookup cancellation is verified on Linux.
- [x] N2.9 Compile/exercise a mock non-Apple consumer of the same interface, checking no Foundation/Objective-C/Swift/POSIX/widget types leak into public contracts. No WinUI frontend is required.
  - C99 smoke consumer and generated dependency audit cover the initial C ABI on
    macOS without GUI dependencies.
  - 2026-09-23: the same C99 consumer (`viewer-c-abi-smoke`, now also exercising the
    parameter-grammar exports) and `viewer-core-smoke` build and pass on Linux
    (Ubuntu 24.04, GCC 13) in Release and under ASan+UBSan+LSan and TSan.
    `tests/viewer/headless.py` now also rejects any public-header include other than
    `stdint.h`/`stddef.h` and any POSIX/Apple/Objective-C/Windows/FLTK or
    non-fixed-width type in `tidyvnc.h` declarations; it passes on Linux (3 + 765)
    and macOS (3 + 768). Windows execution is not claimed.

Exit: an end-to-end native vertical slice with proven bridge ownership and
cancellation; not yet permission to replace the shipping frontend.

## N3 — Native storage and platform adapters

### Preferences, profiles and documents

- [ ] N3.1 Implement app-domain non-secret defaults with schema/revision and serialized writes; define conflict behavior without claiming UserDefaults supplies database transactions.
  - [x] Actor-owned compare-revision store, typed initial clipboard patch, strict
    versioned record, dedicated UserDefaults backend, bounded change subscriptions
    and isolated persistence/failure/cancellation tests. See evidence below.
  - [x] One app-owned store, initial clipboard Settings draft/apply/cancel, new-
    session defaults and explicit failed-read fallback; model and render tests.
  - [x] Schema-2 typed encoding patch validated by the shared core, explicit v1
    upgrade on save, and pre-construction loading with late-session suppression.
  - [x] Field coverage (reviewed 2026-09-23): `NativePreferences` stores clipboard,
    shared, reconnect, fullscreen, remote resize (with DesktopSize), security, trust
    files, scaling, input and all eight encoding fields. PointerEventInterval,
    MaxCutText, UseIPv4/UseIPv6, Log, AlertOnFatalError, Maximize, geometry,
    PasswordFile and listen are CLI/launch-only by design (CAPABILITIES.md).
  - [ ] Verify interactive Settings/defaults controls.
- [ ] N3.2 Implement versioned profile/history storage under native Application Support with private permissions, atomic writes, bounded history and safe future-schema/corruption handling.
  - [x] Actor-owned typed profile/history file store, private Application Support
    backend, revision/locked atomic replacement, bounded history and corruption/
    future-schema preservation. Isolated filesystem and fault tests cover it.
  - [x] App-owned shared recent history, successful-only recording, bounded pending
    work, explicit recovery and joined shutdown; deferred host-parent creation.
  - [x] Saved-profile draft/list UI for names, addresses, inherited/explicit
    clipboard and encoding fields; revision-checked save/delete and fresh profile
    read before new-session construction, with missing-profile/failure handling.
  - [x] Profiles use the same typed patches as defaults plus endpoint and SSH gateway;
    migrations (schemas 1–10 → 11) and document export/import flows are implemented
    and tested (reviewed 2026-09-23).
  - [ ] Interactive profile/history/keyboard/accessibility verification.
- [ ] N3.3 Implement connection document codecs and native open/save/overwrite flows; retain both accepted headers and new `.tidyvnc` exports. Never export secrets.
  - [x] Native Save As review/picker, explicit overwrite, private atomic writer,
    conflict/failure/cancellation handling, close/quit joins and result feedback.
    Live create/overwrite and keyboard cancellation verified; direct Command-Q
    with the system panel open remains a keyboard acceptance gap below.
  - [x] Immutable non-secret compatibility export with required omission review,
    shared semantic preflight, explicit display mapping and current connection
    capture. Native Save As and destination writes are implemented below. See [DOCUMENTS.md](DOCUMENTS.md).
  - [x] Explicit Open panel and new-window review/admission: bounded regular-file
    reads, identity-scoped review, defaults/file precedence, ignored-field review,
    display-mapping revalidation and close cancellation. Both headers use the
    shared codec. Ordinary CLI file routing and explicit-file mapping are implemented below; complete entry-path acceptance remains open.
  - Shared portable codec, retained-viewer integration and owned C/Swift bridging
    and native semantic transactions/panels are implemented. Complete entry-path
    coverage and physical display acceptance remain open. See
    [DOCUMENTS.md](DOCUMENTS.md).
  - [x] Explicit-file monitor mapping chooser and final per-display review for
    ambiguous/mirrored, unavailable or foreign numbering; immutable source/base,
    sparse bounded IDs, stale callback guards and topology revalidation. Physical
    multi-display acceptance remains open.
  - [x] Save As monitor-number recovery for disconnected/ambiguous saved IDs,
    editable automatic assignments, immutable capture and explicit numbered final
    review. Mapping and review share one sheet lifetime before destination handoff.
- [x] N3.4 Implement explicit current-TidyVNC XDG defaults/history import with preview, no-overwrite/new-native-state precedence, cancellation, idempotence and post-success migration marker.
  - [x] Defaults-only review projection and absence-only native commit with
    schema-11 same-record origin marker, cancellation/failure reconciliation and
    idempotence. Separate history implementation is listed below; see [IMPORTS.md](IMPORTS.md).
  - [x] Explicit XDG/home path construction, bounded defaults-source discovery,
    native/current/legacy precedence and immutable preview lifecycle. Stale preview
    IDs, display mappings, cancellation and close/join are covered in isolation.
  - [x] Defaults import window and File-menu action, first-use offer for absent
    native defaults, category/omission/mapping review, explicit acknowledgement,
    current/legacy choices, error/absence/success states and close/reopen lifecycle.
    Production view/controller exercised with disposable fixture storage; the
    first-use history flow is implemented separately below.
  - [x] Separate bounded history projection/source service and schema-10 atomic
    history initialization/origin marker. Profile-only state remains eligible;
    native/cleared and older-schema history wins. Revision/CAS commits preserve
    profiles and refuse stale reviews.
  - [x] Separate history review window, current/legacy choices, omission consent,
    independent first-use offer, File-menu action, shared recent-list refresh and
    close/quit drain. Production UI verified with disposable fixture data.
  - [x] Defaults-import display recovery and editable automatic assignments using
    retained allowed fields, sparse bounded monitor keys, separate omission consent,
    fresh review identities and current connected-ID validation.
  - End-to-end combined first-use acceptance across supported OS/architectures,
    physical display acceptance and release packaging remain broader open gates.
- [x] N3.5 Preserve separate legacy import rules; exclude security/credentials/trust/tunnel commands and never modify original sources.
  - [x] Explicit current/legacy origin and a shared closed ordinary-settings
    projection; excluded values cannot enter native preferences or marker metadata.
    Source discovery and read orchestration preserve current-XDG then legacy XDG /
    home precedence without modifying sources. Defaults now have separate UI
    choices; history now has its own explicit legacy consent and import action.
- [x] N3.6 Document/test native-store versus explicit XDG/CLI/file precedence, no dual writer and intentional export back to FLTK; malformed native data must not trigger fallback import. Reviewed 2026-09-23: precedence (compiled → app defaults → profile → CLI → explicit file) in CAPABILITIES.md/CLI.md with `NativeInvocation.ResolutionAndPrecedence` and `FileMonitorPrecedenceAndRecovery`. Native stores are the only writers; XDG/HOME legacy sources are read-only inputs to an explicit import transaction. Corrupt, future, unsupported or inaccessible native records fail and never trigger fallback import (IMPORTS.md "Commit and marker", `NativePreferencesTests` "no fallback" and import tests). Exports use the shared `.tidyvnc` codec the retained FLTK reader also uses. Rollback acceptance itself is N6.11.
- [x] N3.7 Test missing/read-only/inaccessible/corrupt/future-schema stores, interrupted commits and concurrent stale edits in isolated domains/temp roots. Covered by the native suite in isolated domains/temp roots (reviewed 2026-09-23): `NativePreferencesTests` (disposable UserDefaults domain, corruption/future/unknown fields, typed failure and recovery, revision conflicts), `NativeProfileHistoryTests` (missing parent without side effects, future/corrupt preservation, interrupted writes and orphan cleanup, independent stale writers, real read-only/private permissions, hard/symbolic links and ACL refusal), plus trust-store and recent-history equivalents.

### Credentials and trust

- [x] N3.8 Implement CredentialKey normalization for endpoint/port/transport/route/auth kind/user; test IPv6 scope, aliases, password-only auth and tunnel identity collisions.
  - NativeCredentialKey uses the shared parser through owned endpoint handles;
    versioned, app-scoped SHA-256 over length-prefixed exact bytes. This identity
    contract does not enable credential reuse or replace trust verification.
- [ ] N3.9 Implement Keychain lookup/save/delete/metadata with interaction policy and distinct not-found/locked/denied/cancelled/failure results; no plaintext fallback.
  - [x] SecItem adapter and bounded asynchronous store: exact scoped queries,
    create/replace distinction, metadata-only listing, per-operation interaction,
    typed OS outcomes, cancellation/committed-result semantics and joined close.
  - [ ] Real packaged-app Keychain access and OS interaction acceptance (N3.14).
- [ ] N3.10 Implement use-once, session reconnect and explicit “remember on this Mac”; save only after successful auth and reconcile store failure without failing the live session.
  - [x] Per-window controller and UI choices, current-prompt explicit session/saved
    reuse, successful-only persistence, nonfatal save status and joined shutdown.
    Owned buffers clear on rejection, cancellation, explicit disconnect and close.
  - [ ] Packaged Keychain and interactive acceptance, including OS prompt dismissal.
- [ ] N3.11 Implement replace/forget flow and bounded retry for rejected stored secrets; no automatic destructive delete and no cross-session static secret cache.
  - [x] Explicit replace-on-success and exact-key Forget controls; saved-password
    rejection reports recovery without automatic lookup/retry/delete. One pending
    store operation per window, stale-result guards and no process-static cache.
  - [ ] Interactive/real-store recovery and ambiguous OS mutation reconciliation.
- [ ] N3.12 Retain trust verification and dedicated exception storage; explicit scoped certificate/key decisions, changed identity handling and CA/CRL selection. Never install implicit system-wide trust.
  - [x] Shared retained/native certificate exception mask, fatal/unknown-status
    rejection enforced at the prompt reply boundary, stable ABI policy metadata
    and typed native reasons. See [TRUST.md](TRUST.md).
  - [x] Read-only existing-path certificate adapter, exact legacy SPKI/commitment
    matching, changed-key comparison and scoped reuse with stale/cancel/close guards.
  - [x] Explicit destination-scoped certificate save/replace/forget, atomic
    content-revision writes/recovery, legacy suppression and management UI.
  - [x] Dedicated RSA-AES key kind/file, shared key-encoding/reply policy,
    scoped save/replace/forget and management, separate from certificate approval.
  - [x] Explicit CA/CRL defaults/profile paths and file pickers, field inheritance,
    immutable session capture and required-file TLS loading; see [TRUST.md](TRUST.md).
  - [ ] Interactive file-picker/keyboard/VoiceOver and full native security acceptance.
- [x] N3.13 Limit secret buffer lifetime/copies, redact logs/snapshots/exports and clear owned mutable buffers; document runtime zeroization limits.
  - [x] Owned locked secret allocation, consumed-input/clear/deinit wiping,
    redacted descriptions and bounded storage API; runtime-copy limits documented.
  - [x] Integrate all authentication/retention flows and audit their full lifetime
    (2026-09-23; see SECURITY.md "Secret lifetime audit"). Fixed: RFB client
    security handlers now wipe credentials, keys and contexts (`core::ScopedWipe`);
    stream buffers and AES key contexts are wiped before free; no unwiped temporary
    in the C credential reply; the Keychain save wipes the shared payload object
    (test-checked); SSH setup no longer materializes the environment. Limits documented.
- [ ] N3.14 Test real Keychain operations using disposable scoped entries and packaged app identity, including upgrade/access-policy behavior; remove only test entries.

### Remaining native services

- [ ] N3.15 Implement clipboard offer/read/write, size/encoding limits, focus/session routing and loop prevention; independently enforce send/receive settings.
  - [x] Core channel plus callback-driven C/Swift ownership, async offer/clear,
    direction policy, session/generation/focus validation and remote-origin echo
    suppression. Tests cover wire exchange and retained text after shutdown.
  - [x] NSPasteboard adapter, app-wide focus/change arbitration, native copy/write
    provenance, direction controls and isolated adapter/integration tests.
  - [ ] Verify visible clipboard controls and actual app/window activation wiring.
    Native menu visibility now passes through cua_repl: Send/Receive and source
    labels are exposed. Connected clipboard activation/traffic is still pending.
    The earlier connector failure is cleared; isolated named-board tests pass.
- [x] N3.16 Implement display topology/scale snapshots, stable IDs and generation notifications; handle missing monitors and negative coordinates.
  - AppKit/ColorSync adapter and injected contract tests cover snapshot validation,
    generation/selection and weak view delivery; real host capture passes. Physical
    hotplug, mixed-density and fullscreen/Spaces acceptance remain N5.7/N5.8.
- [x] N3.17 Implement window/presentation lifecycle, bell/URL/help and structured redacted diagnostics. Implementation complete 2026-09-23: window lifecycle through `AppCoordinator` (registration, failure closure, joined quit; production wiring under test), Help/About with bundled guide/acknowledgements/licence and project/issue links (actual-app observation in UI-ACCEPTANCE.md), structured redacted recovery and diagnostics (`NativePresentationIssue`, `NativeConnectionIssue`, `redactedDiagnostics`, redacted process logging), and the server bell (below). Interactive and installed acceptance is tracked under N4.15/N4.17 and N6.
  - [x] Remote server bell (2026-09-23): previously only counted, never played.
    `NativeSession.bellHandler` rings once per delivery turn when the current
    attempt's count advances; the app injects `NativeSystemBell` (`NSSound.beep()`).
    Loopback test covers bursts, later bells, reconnect reset and close.
- [x] N3.18 Implement explicit file access and existing supported tunnel invocation/cancellation without shell-string interpolation; report unsupported features honestly. All subitems below are complete (2026-09-23 review): explicit document/password-file readers and writers; owned SSH tunnel with argument vectors, askpass IPC and cancellation; the admitted ~/.ssh/config subset; `VNC_VIA_CMD`, arbitrary SSH commands and proxy hops are rejected with explicit messages. Installed-app acceptance remains N6.
  - [x] Prepared local tunnel socket boundary preserves the logical TCP target
    hostname for protocol/TLS, with explicit route identity and ordinary transport
    cancellation/drain. App/CLI ownership is implemented and tested below;
    see [TUNNELS.md](TUNNELS.md).
  - [x] Owned noninteractive SSH service: validated gateway identity, acknowledged
    private Unix forwarding, bounded startup, cancellation/process-group drain,
    private child fixture and isolated real OpenSSH authentication/RFB acceptance.
    Native prompts and common new-key review are implemented in the follow-ups
    below; broader configuration and deployment/installed acceptance remain open.
  - [x] Native SSH authentication and common new-key review: private askpass IPC,
    cancellation/join, structured observed-key fingerprint binding, explicit save,
    changed/revoked rejection and isolated Ed25519/RSA/ECDSA fixtures. Broader configuration,
    additional key formats and actual app acceptance remain. Reported initial key-save
    failures now abort before VNC admission; see the latest evidence below.
  - [x] ConnectionModel attempt ownership with controller-level startup/admission
    cancellation, remote/child exit, drain ordering, fresh reconnect, repeated
    close, dropped presentation and routed credential tests. Private child and
    isolated OpenSSH controller fixtures pass; actual app/trust interaction remains.
  - [x] Admitted ~/.ssh/config subset in the app: owned preparation/snapshot,
    effective route binding before credentials/trust/RFB, distinct requested launch
    intent and first effective route, fresh preparation on reconnect, redacted
    failures and updated UI/terminal disclosures. Controller fixtures cover alias
    authentication, reconnect, unsupported config and preparation cancellation.
    Installed/native interaction and remaining OpenSSH parity are still open.
- [x] N3.19 Implement platform capability/permission guidance and retry flow. Preserve Local Network metadata; do not require global input monitoring for ordinary view input or modify privacy settings. Reviewed 2026-09-23: `NSLocalNetworkUsageDescription` is in the bundle and localized (checked by bundle localization and package inspection). `EACCES`/`EPERM` connect failures map to `NativeConnectionIssue.networkPolicy`, whose text says policy *may* be the cause and points to Local Network settings; routing errors never mention it (`NativeConnectionIssueTests`). Retry is explicit (ReconnectOnError). Ordinary view input needs no permission; only optional fullscreen system-key capture uses the Accessibility-gated tap, now with typed `accessibilityRequired`/`failed` guidance. The app never changes privacy settings. Installed Finder-launched consent allow/deny/retry acceptance remains N6.8.
- [x] N3.20 Run shared service contract tests against fake adapters and macOS implementations; document unsupported future-Windows semantics without implementing its backend. 2026-09-23: each service runs against fakes and against its macOS implementation in the native suite: an isolated `UserDefaultsPreferencesBacking` domain, `NativePrivateFile` temp roots (profiles/history/trust), `NativeLegacyTrustFile`, the real document reader/writer and password-file reader on temp files, a private named `NSPasteboard`, `AppKitDisplaySource`, and a real `ssh` for the tunnel. Exception: the Keychain backing runs with a faked SecItem client, because real Keychain access with the packaged identity is N3.14. The production wiring is `NativeApp.ProductionWiring`. Windows semantics to decide are listed in [HANDOFF.md](HANDOFF.md).

Exit: platform integration is exercised through the same interfaces the native
UI uses, with migration and credential behavior verified independently.

## N4 — Complete SwiftUI replacements

- [ ] N4.1 Connection window: endpoint validation, recent hosts, Open/Save, Connect/Cancel, separate import choices and keyboard-first operation.
  - 2026-09-23 actual-app (isolated copy, background control; UI-ACCEPTANCE.md):
    separate defaults/history import offers, import window with explicit exclusions
    and "no file" handling, Escape to close, Return-to-connect, connected state,
    correct displayed pixels, Disconnect, menu Quit. Recent-hosts popover and
    remote input need the app frontmost and remain open.
  - [x] Native Open and Save As menus, reviewed immutable export, explicit
    replacement confirmation and non-disruptive save feedback.
  - [x] Shared-parser endpoint preflight with typed inline errors and Connect/Save
    gating; display/port/IPv6/Unix compatibility and no-work invalid-action tests.
  - [x] Shared recent-address selection, individual removal/clear and successful-
    connection persistence with nonfatal storage errors; model and render tests.
- [ ] N4.2 Authentication sheet: required fields, endpoint/security context, secure entry, three retention choices and cancellation per session.
  - [x] Correct credential-protection policy indication without claiming whole-
    connection encryption; long endpoint wrapping and light/dark render fixtures.
  - [x] Three retention choices, explicit replace/use/forget controls, asynchronous
    store status and cancellation; loopback lifecycle and eight render fixtures.
  - [ ] Full security/trust context and interactive acceptance.
- [ ] N4.3 Trust sheets: reason/details/expected and received identity, safe default, scoped decision and reconnect generation handling.
  - [x] Native reasons/subject/destination/fingerprints, fatal and malformed
    approval gating, Cancel default, attempt-only scope and fourteen render fixtures.
    RSA-AES compatibility fingerprint is correctly distinguished from SHA-256.
  - [x] Stored expected/received key comparison, host/wildcard scope, typed store
    failure presentation and four additional light/dark detail renders.
  - [x] Confirmed scoped certificate save/replace, stale-revision errors and
    eight additional light/dark persistence and management renders.
  - [ ] Physical keyboard/VoiceOver/TLS sheet acceptance.
- [ ] N4.4 Encoding/color/compression settings: auto select, all supported encodings, full/reduced color, JPEG enable/quality and compression range.
  - [x] App-default controls for all shared encoding fields, schema-derived bounds
    and decoder availability, automatic/dependent enablement and source labels.
    Model tests and light/dark automatic/manual renders pass.
  - [x] Separate live-session encoding draft/apply/cancel, sourced immutable values,
    generation/baseline guards, cancellation reconciliation and sheet cleanup.
    Fault-injected models, two real sessions and actual app-controller tests pass.
  - [x] Actual-app live encoding sheet: automatic toggle enables dependent
    controls and Cancel discards the draft ([UI-ACCEPTANCE.md](UI-ACCEPTANCE.md), 2026-09-23 full-screen pass).
  - [ ] Interactive keyboard/accessibility and visible live-encoding acceptance.
- [ ] N4.5 Security settings: encryption/authentication options, CA/CRL pickers and reconnect-required changes with unchanged negotiation policy.
  - [x] CA/CRL defaults/profile controls and new-window application.
  - [x] Shared compiled method catalog, exact allow-list validation, defaults/profile
    inheritance and method controls with source/owned session capture; see [SECURITY.md](SECURITY.md).
  - [x] Advanced TLS-priority defaults/profile controls, off-UI preflight validation,
    exact inheritance and per-window snapshots; see [SECURITY.md](SECURITY.md).
  - [x] Connection-local security draft, disconnected generation/revision CAS,
    joined cleanup and next-attempt policy with credential/trust invalidation.
  - [ ] Physical keyboard/VoiceOver/picker acceptance and full native authentication proof.
- [ ] N4.6 Input/clipboard/shortcut settings: view-only, middle button, fallback cursor, fullscreen system keys, modifiers and separate clipboard directions; omit X11-only options on macOS.
  - [x] Connection-local view-only and hidden/dot/system cursor fallback sheet,
    copied Apply/Cancel drafts, stale/reconnect/close guards and held-input release.
  - [x] Shared retained/native middle-button emulation with a connection-local
    setting, a scoped 50 ms worker timer and lifecycle/routing cancellation.
  - [x] Connection-local fullscreen system-key capture and modifier controls,
    AppKit shortcut routing, permission guidance and injected capture lifetime tests.
  - [x] Typed app-default/profile input persistence, pre-connect installation,
    fieldwise inheritance and live-source labels; saved changes affect new windows.
  - [x] Actual-app view-only Apply/clear and source labels, verified by peer key
    counts ([UI-ACCEPTANCE.md](UI-ACCEPTANCE.md), 2026-09-23 full-screen pass).
  - [ ] Interactive clipboard/shortcut/keyboard-only and VoiceOver acceptance.
- [ ] N4.7 Scaling settings: eight modes, custom dimensions/decimal percentages, validation/help, filters and logical/device units.
  - [x] Connection-local eight-mode Apply/Cancel sheet, custom values, shared-parser
    validation/help and logical/device units; atomic view geometry and inverse
    input mapping, size-limit preflight and Retina fallback verified.
  - [x] Shared resampler/cache and nearest/bilinear/area quality controls with
    copied Apply/Cancel drafts, bilinear default, filter-only pan preservation,
    per-connection isolation and AppKit pixel/SwiftUI render verification.
  - [x] Typed scaling defaults/profile patches for all modes, units and filters,
    canonical saves, initial desktop installation and per-field live source labels.
  - [x] Native menu and accessibility pan actions with edge gating, logical/device
    units, resize clamping and coherent displayed-image/pointer mapping.
  - [x] Actual-app scaling-quality pop-up and Apply change the displayed filter
    live (nearest vs bilinear) ([UI-ACCEPTANCE.md](UI-ACCEPTANCE.md), 2026-09-23 full-screen pass).
  - [ ] Full interactive keyboard/VoiceOver acceptance of scaling and pan controls.
- [ ] N4.8 Display/miscellaneous settings: window/current/all/selected screens and visual chooser, remote resize policy, shared/reconnect settings and capability-gated optional features.
  - [x] Shared-session ClientInit policy and explicit Retry option: defaults/profile
    inheritance, disconnected local drafts, sources and revision/generation checks;
    see [CONNECTION.md](CONNECTION.md).
  - [x] Explicit connected remote-size sheet and menu/context actions, capability/
    view-only gates, server feedback, copied drafts and joined dismissal; see
    [REMOTE-RESIZE.md](REMOTE-RESIZE.md).
  - [x] Session-owned automatic resize policy, initial-size snapshot per attempt,
    100 ms viewport coalescing, scaling/units and view-only/capability gates, live
    local policy editor and AppKit lifecycle/fullscreen notification integration.
  - [x] Typed resize defaults/profile persistence, independent enabled/initial-size
    inheritance, explicit blank override, new-window isolation and per-field sources.
  - [x] All/selected local-display chooser for explicit remote resizing, shared
    logical/device layout mapping, stable selection IDs and topology-change review.
  - [x] Connection-local current/all/selected display sheet and owned app fullscreen
    routing, with missing-ID fallback, topology review and deferred settings sheets.
  - [x] Persisted fullscreen startup/current/all/selected policy, independent
    defaults/profile inheritance, connection source labels and reconnect restoration.
  - [x] Complete fullscreen automatic remote layout requests, exclusive canvas
    ownership, transition/minimize handoff and existing policy/initial-size gates.
  - [x] CLI fullscreen mapping (reviewed 2026-09-23): FullScreen, FullScreenMode,
    FullScreenSelectedMonitors and the FullScreenAllMonitors migration have native
    adapters with display-mapping review (`NativeInvocation.FileMonitorPrecedenceAndRecovery`).
  - [ ] Physical per-display acceptance and optional controls.
- [ ] N4.9 Separate app Settings defaults from live session override sheets; draft/apply/cancel and effective-source display; no mutation of other sessions.
  - [x] Clipboard app-default draft/apply/cancel, per-field source labels, revision
    conflict recovery and new-session-only default loading. Model tests prove
    existing-session isolation; light/dark default/conflict renders inspected.
  - [x] Encoding app-default drafts and pre-negotiation installation; later app
    saves affect newly created sessions only. Invalid drafts remain correctable.
  - [x] Live encoding sheet shares schema-driven controls, preserves untouched
    field sources and never writes app defaults. Dismissal drains before reopen.
  - [x] Input defaults/profile patches and connection-local override sources;
    copied drafts preserve untouched inherited values and existing-session isolation.
  - [x] Scaling defaults/profile inheritance and live-source separation, with
    invalid-save gating, canonical draft reconciliation and new-window-only loading.
  - [x] Actual-app Settings window separate from live sheets; app-default and
    connection-override labels, Cancel Edits and Apply gating ([UI-ACCEPTANCE.md](UI-ACCEPTANCE.md), 2026-09-23 full-screen pass).
  - [ ] Broader settings and their live-session sheets, complete effective-source/
    reconnect-required flows and interactive keyboard/accessibility verification.
- [ ] N4.10 Desktop commands/context menu: disconnect, fullscreen/minimize/resize-to-session, Ctrl/Alt toggles, Ctrl-Alt-Del, refresh, options, info and About; route to focused session.
  - [x] Native Connection/toolbar actions, current-window fullscreen, windowed
    minimize/fit, modifier latches, Ctrl-Alt-Delete and basic information sheet.
  - [x] Shortcut-triggered native context popup and command dispatch, with
    checked model actions and scoped menu-controller lifetime.
  - [x] Minimize from fullscreen through an exit-then-minimize sequence, with
    held-input/capture release, bounded retry recovery and lifecycle cancellation.
  - [x] Negotiated connection information matching the retained viewer's fields,
    copied from bounded core observations, with redacted diagnostic copying.
  - [x] Actual-app connected Connection menu, Ctrl-Alt-Delete, Hold Control latch
    and release, and Disconnect verified by peer key counts ([UI-ACCEPTANCE.md](UI-ACCEPTANCE.md), 2026-09-23 full-screen pass).
  - [ ] Physical fullscreen/minimize and multi-display transitions and interactive acceptance.
- [ ] N4.11 Native app menus/Dock/new connection/open document/quit; Finder, CLI, explicit file, reverse/listen and supported tunnel entry paths work without secret-bearing relaunch arguments.
  - [x] Implement AlertOnFatalError with immutable launch/session scope, retained
    ReconnectOnError precedence and joined fatal/non-retry/reverse/startup cleanup.
    Real socket/model tests preserve unrelated connections/listeners and explicit
    cancellation; CLI/file/export policy is covered. See PARITY E06 and CONNECTION.
  - [ ] Verify actual failure-window closure, Retry interaction and application
    lifetime with multiple windows before accepting AlertOnFatalError parity.
  - [x] Noninteractive CLI `via`, per-occurrence gateway validation, final reviewed
    file target resolution, route-scoped launch passwords, listen/Unix rejection
    and explicit VNC_VIA_CMD rejection before startup. Help states limitations;
    interactive SSH/configuration and installed acceptance remain open.
  - [x] Manual native listener window, port/family controls, explicit peer actions,
    independent incoming windows, resolved defaults, connection-only reverse identity
    and listener/window/quit drain. Installed acceptance remains open; see LISTEN.md
    and the presentation evidence below.
  - [x] Numeric CLI listen launch, one-shot listener scene, family selection,
    per-incoming CLI options and single-owner launch credentials. Full app/installed
    interaction remains open; see LISTEN.md.
  - [x] Reviewed connection-file listening, checked ServerName port interpretation,
    no session/bind before approval, immutable settings reuse across incoming
    windows, display mapping/revalidation and cancellation during file IO/review.
  - [x] App-executable CLI bootstrap, one-shot first-window launch, automatic
    direct-host connection, no-host form and reviewed file startup. No-file monitor
    recovery, new-window/zero-window isolation and terminal paths are covered by
    isolated fixtures and actual executable tests. Other adapters and installed
    Finder/LAN/privacy acceptance remain open.
  - [x] Outgoing UseIPv4/UseIPv6 CLI policy, per-session ownership, reconnect,
    numeric/hostname family selection and Unix independence. Compatibility export
    reviews omitted IP settings; incoming listen/tunnel adapters remain open.
  - [x] PointerEventInterval CLI adapter with shared 17 ms default, worker-owned
    post-emulation timer, immediate transitions, input-order/lifetime guards and
    explicit export omission review. Other CLI-only adapters remain open.
  - [x] MaxCutText CLI adapter with shared incoming default, full retained bounds,
    immutable per-session reader policy, reconnect and file/export review. Separate
    UTF-8 retention budgets remain enforced. Export details scroll without clipping
    the introduction or display list; title/actions remain visible.
  - [x] Initial geometry/Maximize CLI adapters with checked shared retained parsing,
    one-shot AppKit window placement, file admission, work-area bounds and automatic
    fullscreen ordering. Reconnect preserves later resizing; new windows do not
    replay launch policy. Compatibility export reviews omitted placement.
  - [x] Logging prerequisite: synchronize shared file/stdio records and sink
    replacement/closure, with reentrant timestamp conversion and regression tests.
    Native activation and file destination are tracked below.
  - [x] Owned logging policy parser and transactional catalog resolution, with
    defined retained level semantics, overflow rejection and per-occurrence CLI
    validation. Duplicate writer names retain legacy lookup order.
  - [x] Redacted sink adapter before printf expansion, audited numeric metadata,
    key-event suppression, fixed unknown-message fallback and synchronized output.
    Native diagnostic localization remains open.
  - [x] Process startup ownership and native stderr/stdout Log activation with
    retained default, transactional preparation, owned descriptors, closed runtime
    admission and post-join sink destruction. No session/file/store replay.
  - [x] Native file Log target: lazy private creation, one backup, nonblocking
    cross-process ownership, redacted stderr fallback and copied C host path.
  - [ ] Remaining logging/help/localization and installed acceptance.
  - [x] Password-file primitives: bounded actor reader, shared caller-owned decoder,
    consuming raw-byte C/Swift reply, password-only prompt gate and buffer wiping.
  - [x] Launch credential owner for PasswordFile/environment precedence, intended
    connection scope, stale/cancelled IO drain, retry and native CLI admission.
  - [ ] Resolve/verify direct Command-Q while the native Save panel is active.
    Current computer-use input leaves it open; the Quit menu and Escape followed
    by Command-Q work. Failed local-event/native-menu experiments were removed.
  - [x] Finder callbacks route cold/warm local-file batches to independent review
    windows, preserve explicit legacy input and stop pending dispatch on quit.
    A real SwiftUI fixture verifies delivery with zero visible windows. CLI,
    reverse/listen/tunnel and installed release/association/consent gates remain open.
- [ ] N4.12 Connection inspector/stats overlay with negotiated properties, throttled updates and redacted copyable diagnostics.
  - [x] Information sheet: desktop name, protocol, negotiated security, actual wire
    pixel format, requested/last received encoding, bandwidth estimate and frames;
    existing throttled snapshots and copied diagnostics omit endpoint/name/secrets.
  - [x] Connection-scoped passive statistics overlay, sharing existing sampled
    information; Connection/toolbar/context menu toggle and lifecycle reset.
  - [x] Passive statistics on every owned fullscreen surface, shared sampled
    values, in-place menu toggles and transition/disconnect cleanup.
  - [x] Actual-app information sheet and statistics overlay, including a live
    server-resize update ([UI-ACCEPTANCE.md](UI-ACCEPTANCE.md), 2026-09-23 full-screen pass).
  - [ ] Broader performance metrics and VoiceOver acceptance.
- [ ] N4.13 Errors/reconnect/permission guidance with correct category, Retry/Cancel and safe context; routing errors do not assert a proven privacy denial.
  - [x] Typed redacted connection/command errors, unexpected-disconnect alerts,
    explicit generation-scoped Retry/Cancel and address/lifecycle guards.
  - [x] Distinct DNS, refused, timeout, routing and suspected network-policy
    guidance; no privacy-denial assertion from a routing error.
  - [x] Actual-app refused-connection alert (Cancel default, Retry) and Cancel of a
    stalled handshake ([UI-ACCEPTANCE.md](UI-ACCEPTANCE.md), 2026-09-23 full-screen pass).
  - [ ] Interactive alert/keyboard/accessibility acceptance and native localization.
- [ ] N4.14 Open/save/import/overwrite confirmations with native panels, cancellation and filesystem error recovery.
- [ ] N4.15 About/credits/help with correct identity, licenses, attribution and support links.
  - Native Help window and Help menu command implemented: getting-started guidance,
    selectable bundled README/licence, project and issue links. Credits.rtf now
    supplies the standard About panel's attribution. App build, sealed resources,
    exact bundled document bytes, RTF parsing and 32 terminal cases pass. Offscreen
    guide layouts inspected at minimum/default sizes in light/dark. Actual Help
    topic switching, About presentation, keyboard and VoiceOver acceptance remain
    open. A later CUA session verified topic loading, About identity/credits and
    dismissal; New Profile again closed the native pipe. See UI-ACCEPTANCE.md.
- [ ] N4.16 Native localization catalog and mapping of structured core errors; preserve retained gettext consumers and translator attribution; test long strings and fallback.
  - Current source coverage: 1052 Localizable and 2 InfoPlist entries. App menus,
    connection/status, file panels, controller/gateway recovery, CLI/Keychain and
    typed startup/desktop recovery now join the earlier settings/import/trust work.
    System privacy/document-type strings have compiled metadata lookup evidence;
    expected/saved trust identities use complete messages over typed values.
    Compiler extraction now verifies 139 current sources / 1353 localization call
    sites against the catalog during the standard app build. Long-text fixtures,
    fallback and literal interpolation checks pass. Finish dynamic text provenance
    and actual window/menu/panel acceptance;
    fixture coverage is not proof of complete localization or VoiceOver operation.
    See LOCALIZATION.md and the latest evidence log.
  - Credential/password-file status, saved-trust storage notices and the trust
    library now add 60 catalog entries (228 total). Complete localized status
    sentences take literal diagnostic arguments; saved fingerprint text has
    separate algorithm/value arguments. Eight focused credential/trust/rendering
    tests pass (40.42 s), plus compiled catalog/fallback/interpolation checks,
    app signature, 32 terminal cases and branding. Synthetic prompt expansion
    and remaining UI localization/accessibility work are still being checked.
    A reusable isolated-bundle expansion runner now exposes truncation beyond the
    existing geometry assertions. Password lifetime and saved-password controls
    were corrected and inspected in light/dark; ordinary/final expanded rendering
    passes. The subsequent follow-up fixes the trust-library destination label
    and expanded save/replace trust actions; see the latest evidence below.
  - Authentication/SSH sheets, trust details, credential-protection guidance and
    certificate/key presentation add 96 entries (168 total). Dynamic trust text
    uses whole sentences with literal arguments. Packaged lookup/fallback and
    interpolation checks pass, as do four focused rendering/credential/trust/SSH
    interaction tests (39.16 s), app build/signature and branding. Expanded prompt
    layouts, actual translations, RTL/accessibility and storage-operation notices
    remain open. Evidence: latest RESUME checkpoint and LOCALIZATION.md.
  - Help guidance, topic/menu/window labels, links and loading/error text now have
    25 stable IDs, plus the explicit About action. Total catalog: 72 source entries.
    A doubled-string offscreen render caught segmented-picker overflow; Help now
    switches to a menu when segments do not fit. Corrected minimum/default
    light/dark layouts and normal English minimum layout inspected. Final app,
    packaged lookups/fallbacks, signature, branding and diff checks pass. This does
    not establish translations, RTL, VoiceOver or interactive Help acceptance.
  - Initial English source catalog now compiles into the app. All 46 structured
    connection diagnostic titles/messages use stable IDs and explicit redacted
    defaults. Packaged lookup, untranslated-language and missing-key fallbacks,
    resource-free error/retry CTest, signature and terminal checks pass. Retained
    gettext files are untouched. Other native UI strings and long-string layout
    acceptance remain open; see [LOCALIZATION.md](LOCALIZATION.md).
- [ ] N4.17 VoiceOver labels, keyboard focus/tab/escape/default actions, light/dark/high contrast and reduced motion on every screen/sheet. Document remote framebuffer accessibility limits.
- [ ] N4.18 Update parity inventory with native screenshots and UI-test/manual evidence for every control and action; record intentional differences explicitly.

Exit: all existing macOS UI behaviors have tested native counterparts; no
unchecked parity rows hidden by a visually complete connection screen.

## N5 — Desktop fidelity, input and performance

- [ ] N5.1 Implement measured CPU/Core Graphics presentation path with existing resampler/cache algorithms; keep pixels off SwiftUI observation and avoid per-view full-desktop copies.
  - [x] Shared frame-tile service and native background actor/scheduler foundation:
    bounded cache/visible tiles, consumed-frame damage history, latest-request
    coalescing, stale suppression, cancellation and asynchronous cleanup tests.
  - [x] Coherent AppKit tile/image/input publication, direct identity path,
    unchanged CG tile reuse, shared damage invalidation and session-owned joined
    renderer cleanup, including detached and released views.
  - [x] Separate replaying AppKit frame/cursor streams from SwiftUI observation;
    publish frame availability and deduplicated control/statistics values only.
  - [x] Integrate shared cursor filtering with bounded native/software cursor
    presentation, stale suppression and session-owned joined cleanup.
  - [x] Measure presentation latency on the production view path (probe above;
    full-frame draw p50 14–16 ms, p95 ≤ 18.5 ms at 30 updates/s, Release), and
    per-frame output copies (14.1 MiB full frame, 0.5 MiB for a 64×64 patch).
  - [ ] Measure complete source/upload/old-frame budgets and set sign-off limits.
- [ ] N5.2 Preserve identity fast path, all scaling modes/filters, logical/device units, fractional pan/scale, scrolling and letterboxing; verify fixtures and displayed pixels.
  - [x] AppKit displayed-pixel fixtures for nearest, bilinear, area and identity,
    coherent asynchronous transforms, damage-only updates and hide/unhide.
  - [x] Expose nearest/bilinear/area filters in the connection scaling sheet.
  - [ ] Finish cursor/pan parity and physical acceptance.
- [x] N5.3 Verify damage coalescing, dropped-presentation recovery, bounded retained frames and resize generation handling with attached/detached views. Covered by automated tests (reviewed 2026-09-23): `FramePublisher.SlowViewsMergeDamageIndependently`, `RetainedFramesBoundMemoryAndSkippedDamageIsRecovered`, `ResizeAndFormatChangesForceFullDamage`, `SkippedResizeAndReconnectCannotLoseInvalidation`, `ConcurrentConsumerRetainsConsistentFramesDuringReset`; `NativePresentation` (damage-only redraw and CG tile reuse, detached-work accounting, 16-slot renderer bound including pending detach, released-view drain, coalesced snapshot invalidations); `NativeDesktop` 12 view removals with a server resize in flight; and the N5.10 reconnect stress test.
- [ ] N5.4 Verify remote/local cursor fallback, shape/hotspot, scaling and pointer mapping at edges and outside letterboxed content.
  - [x] C/Swift shared cursor sampling service: nearest/bilinear/area, premultiplied
    edge filtering, rounded/clamped hotspots, anisotropic/extreme scaling and
    retained-source independence verified.
  - [x] Native/software cursor presentation, hidden/dot/system fallback API,
    backing-scale changes, cancellation/drain and AppKit bitmap checks.
  - [x] Expose connection-local fallback settings with Apply/Cancel.
  - [x] Cursor fallback policy persistence (reviewed 2026-09-23): `cursorFallback`
    is an input default/profile field with strict decoding (`NativeInputPersistenceTests`).
  - [ ] Finish visible cursor/physical-display acceptance.
- [ ] N5.5 Implement AppKit keyboard/pointer/wheel translation, physical/logical key policy, IME/dead keys/repeats, local shortcuts and protocol scancodes without duplicate input.
  - [x] Extract bounded shared shortcut classifier, checked C handles and native
    decision routing, including modifier-only release and Space bypass.
  - [x] Integrate AppKit layout candidates/lifecycle, desktop command dispatch,
    modifier controls and scoped system-key capture.
  - [ ] Verify physical keyboard layouts, IME/dead keys, actual system capture,
    fullscreen/Spaces and interactive shortcut parity.
- [ ] N5.6 Verify release-all on focus loss, disconnect, sleep, capture change and window transitions; one remote input state spans all session views and view-only blocks synthetic input.
  - [x] Native per-surface focus ownership, held input release on transfer, late-event
    suppression, weak command routing, scoped capture status, close/deinit and
    generation reset; loopback tests and injected capture/window backends.
  - [ ] Physical cross-window focus/capture, sleep and fullscreen/Spaces acceptance.
- [ ] N5.7 Preserve current/all/selected-monitor fullscreen, reconnect layout and remote-resize policy; test topology change, unplug/replug, Spaces and missing saved display IDs.
  - [x] Shared per-monitor canvas transform across C/Swift, global fit/pan, coherent
    region pixels/inverse input/damage and independent automatic-resize ownership;
    see [CANVAS.md](CANVAS.md).
  - [x] Scoped focus and command/capture host routing across registered native views.
  - [x] Weak canvas membership, all-surface scaling preflight, shared pan/clamping,
    logical/device remapping and transactional explicit topology reconfiguration.
  - [x] AppKit window-owner prototype with explicit native-Space/borderless
    strategies, current/all/selected IDs, owned delegates and bounded rollback;
    see [FULLSCREEN.md](FULLSCREEN.md).
  - [x] Visible isolated comparison harness, weak fullscreen command routing and
    single-Retina native/borderless entry/exit; multi-monitor comparison remains open.
  - [x] Owned-group exit-then-minimize of the original window, cancellation guards
    and native/borderless single-Retina notification evidence.
  - [x] Experimental app owner binding, connection activation/menu routing and
    deferred source-window settings/error presentation with copied display drafts.
  - [x] Saved startup/display policy and guarded reconnect restoration, including
    missing IDs, delayed foreground entry and explicit exit/failure cancellation.
  - [x] Automatic complete-layout fullscreen requests using the shared rendering
    geometry, token-owned handoff and actual RFB request/reply fixtures.
  - [x] Fullscreen statistics overlay with shared windowed content, transparent
    input routing and independent two-session/lifecycle validation.
  - [ ] Visible app sheet/menu acceptance and physical monitor focus/topology/Spaces
    acceptance (CLI policy mapping is covered under N4.8).
- [ ] N5.8 Run physical 1×/2× and mixed-density/multi-display tests with recorded OS/hardware; simulation alone does not complete this item.
- [ ] N5.9 Run matched FLTK/native benchmarks against N0 budgets; record latency/CPU/memory/copy/damage results and resolve or explicitly review regressions before cutover.
  - Partial (2026-09-23): matched CPU/RSS/throughput per PERFORMANCE.md shows no
    regression on those metrics. Native presentation latency is measured; the FLTK
    latency comparison, copy/damage measurement and review remain.
- [x] N5.10 Stress reconnect, resize, slow consumer and attach/detach cycles; check bounded memory, no stale callbacks and no retained input state. 2026-09-23: `SessionWorker.ReconnectCyclesWithSlowConsumerStayBoundedAndCurrent` runs 50 reconnect cycles with a slow view consumer holding an old lease, a held key at every disconnect and a two-frame (32-byte) publication budget. A fresh frame still publishes after the leases are released (no leaked budget); no event of an earlier generation follows a new connect; held input is not carried into the next attempt; no mailbox wake-ups follow joined drain. Passes on macOS and under Linux ASan+LSan and TSan. Resize and attach/detach cycles: `NativeDesktop.RenderingAndInput` (12 view removals with a server resize in flight), `ProtocolSession` independent-view detach and `FramePublisher.SkippedResizeAndReconnectCannotLoseInvalidation`; the 256-frame decode flood and shutdown under load are under N2.8.

Exit: fidelity and measured responsiveness match the retained native feature
contract. A GPU rewrite is not required unless justified by failed budgets.

## N6 — Build, integration and macOS cutover

- [x] N6.1 Add explicit Apple-only SwiftUI frontend selection and retain FLTK as default until gates pass; unsupported/missing toolchain configurations fail clearly. See [BUILD.md](BUILD.md).
- [ ] N6.2 Script clean CMake core → Xcode app/test/package builds with pinned configuration and generated dependency inputs; one source for identity/version/resources.
  - [x] Shared root/convenience CMake → Xcode build, exported core dependencies and
    checked configuration/SDK/architecture/floor handoff, retaining the release
    identity source. Clean build and failure paths pass; see [BUILD.md](BUILD.md).
  - [x] All-target automated verification with mandatory GoogleTest, complete
    CTest inventories/JUnit, fresh failure-preserving reports and bundle/CLI checks.
    Local full pipeline passes; hosted execution remains N6.4.
  - [x] Local app/DMG assembly with recursive dylib closure, explicit minimum-OS
    rejection, relocation, dependency notices, nested signing, atomic publication
    and mounted-image inspection. Root/convenience build paths and policy tests
    are wired; see PACKAGING.md for the supported single-architecture scope.
  - [x] Clean Release core/app/test build and complete verification on arm64
    macOS 27, followed by dependency assembly and mounted-DMG inspection. The
    package explicitly declares 27.0; see the Release evidence below.
  - [ ] Validate minimum-OS/Intel packages, complete selected dependency
    distribution obligations and intended signing-identity acceptance.
- [x] N6.3 Split FLTK surface-dependent tests from GUI-independent tests; core-only and SwiftUI builds neither discover nor link FLTK. Clean headless/native graph proof and retained FLTK tests are in [BUILD.md](BUILD.md); other-platform CI remains N6.4.
- [ ] N6.4 Add native build/model/adapter/UI CI jobs and retain Windows/Linux FLTK jobs; test chosen minimum/current macOS and supported architectures, recording unavailable runners.
  - [x] Five-job native workflow definition, host/toolchain/dependency evidence,
    failure logs/JUnit/render fixtures and development bundle artifacts. Existing
    FLTK/headless workflows retained; YAML/shell parsing verified locally.
  - [ ] Execute hosted matrix, resolve failures and configure minimum-OS Intel
    coverage; replace retiring minimum-OS runner without waiving that gate.
    **Blocked by owner decision (2026-09-23): hosted CI must not be enabled for
    this project yet; do not push to run GitHub Actions.** Linux jobs are
    reproduced locally in a Podman Ubuntu 24.04 container instead.
  - [ ] Complete actual interactive UI/accessibility and physical/installed checks.
- [x] N6.5 Run all applicable original unit tests, new contract/ABI/service tests, supported sanitizers and full protocol regression matrix through the native frontend. Closed 2026-09-23: retained FLTK 782 unit tests (and the Linux FLTK CI job, 775) plus 776 core/ABI/service and 90 native tests; sanitizers — full core suite under Linux ASan+UBSan+LSan/TSan and macOS ASan+UBSan/TSan, and the native Swift suite under macOS ASan/TSan; protocol — the 55-case baseline through the Debug and packaged Release native executables, encoding round trips for every wire encoding, and 4 actual-app authentication/trust cases. Physical/presentation acceptance is tracked under N4/N5.
  - [x] Reuse the full 55-case scaling/protocol baseline with the actual native
    executable, isolated state, measured viewport resize assertions and retained
    FLTK regression checks. See [PROTOCOL.md](PROTOCOL.md). Broader protocol,
    sanitizers and physical/presentation acceptance remain open.
  - [x] Repeat the 55-case baseline with the packaged Release executable at the
    current implementation commit (2026-09-23 evidence below).
  - [x] Full portable core/unit suite as Linux Debug (-Werror) under ASan+UBSan+LSan
    and TSan, with CI jobs defined. Fixed the upstream TLS description leak and
    null-memcpy UB it found. Native app/Swift and Apple sanitizer coverage remain open.
- [ ] N6.6 Validate bad credentials/trust, clipboard, remote resize, reverse/listen, tunnel, peer disappearance and reconnect; protocol tests supplement native presentation/input evidence.
  - Fixture map (2026-09-23), layers A core / B native wrapper with real sockets /
    C app model / app executable: remote resize covered at all four; reverse/listen,
    SSH tunnel and reconnect at A–C (the app executable only for argument errors);
    clipboard at A–B; bad credentials at A and C; TLS/RSA trust at A (SSH host keys
    at B–C with real sshd); peer loss during authentication at A only. **Gaps:** no
    actual-app case for bad credentials, clipboard traffic, trust, listen, tunnel or
    reconnect; TLS/RSA-AES/DH/MSLogonII never completed end to end outside core.
  - [x] Encoding round trips (2026-09-23): `EncodingRoundTrip.*` encodes a patterned
    framebuffer with the server EncodeManager and decodes it with the client:
    Raw, Hextile, ZRLE and lossless Tight reproduce every pixel; Tight/JPEG and
    standalone JPEG are lossy but bounded; RRE is checked with a hand-built rect.
    Previously no layer decoded ZRLE, Hextile or JPEG. The Linux ASan run found
    uninitialized `seenHuffman`/`seenQuant` flags in `JPEGDecoder` (undefined bool
    read on the first image), now initialized.
  - [x] Actual-app authentication (2026-09-23): `tests/integration/macos-auth-smoke.py`
    launches isolated app copies against a VncAuth-only peer that verifies the DES
    response with openssl. Correct `VNC_PASSWORD` connects and requests updates;
    a wrong one is rejected once with no automatic retry and the app stays up; with
    no credentials the app parks at its prompt while the peer vanishes and survives
    without reconnecting. An `untrusted` case negotiates VeNCrypt X509None with a
    throwaway self-signed certificate: TLS completes but the app never continues
    the RFB handshake, survives the peer leaving and does not reconnect. 4/4 pass
    in two runs; added to the native CI job. Remaining actual-app gaps: clipboard
    traffic (the system pasteboard cannot be isolated), listen/reverse accept and
    Retry/reconnect (both need a UI action), tunnel, and RSA-AES host keys.
- [ ] N6.7 Validate final bundle identity, document associations, localization, credits, Local Network description, signing/resource seal and dependency paths; verify no FLTK linkage/symbols.
  - [x] Local ad hoc package identity/resources/notices/signature, full dylib
    closure, relocated CLI and read-only mounted-DMG inspection; see PACKAGING.md.
  - [ ] Repeat with the final supported deployment/dependency/signing configuration
    and actual installed privacy/Keychain/document behavior.
- [ ] N6.8 Test installed Finder-launched Local Network allow/deny/retry, actual LAN connection and signing-identity upgrade behavior. Do not count Terminal-only smoke tests as privacy validation.
- [ ] N6.9 Test final packaged Keychain identity/access across updates; no developer-only entitlement/signature assumptions or test secrets remain.
- [ ] N6.10 Test sleep/wake/network changes, multi-session prompt isolation and clean app quit with pending IO/auth/store operations.
- [ ] N6.11 Validate rollback to retained FLTK artifact using untouched legacy data and explicit profile export; do not overwrite native stores or transfer credentials automatically.
- [ ] N6.12 Update BUILD-MACOS, migration/user docs, CLI help, package inspection tests, screenshots and other affected plans; distinguish local packaging from distribution portability/notarization.
- [ ] N6.13 Review every parity row and acceptance gate; only then make SwiftUI the default/shipping macOS frontend and remove FLTK from that app's dependency path.
- [x] N6.14 Publish interface handoff documentation with types, state diagrams, thread/lifetime/error contracts and reusable tests for a future separate WinUI plan. Do not claim Windows implementation complete. See [HANDOFF.md](HANDOFF.md) (2026-09-23): layers, ABI conventions, session/listener lifecycle diagram, threading and delivery, data/input/prompt/clipboard contracts, core- versus frontend-owned settings, required services with macOS references, and the reusable suites that already pass on Linux. It states that no Windows frontend or Windows execution exists.

## Deferred beyond this plan

These are boundaries, not implementation checkboxes for this milestone:

- WinUI application, Windows views/windowing/renderer, Windows service backends,
  Windows credential/preferences migration and installer/distribution work.
- Removing the retained Windows/Linux FLTK frontend or converting Linux UI.
- New protocol features, audio backend, GPU-only rendering, cloud sync, App Store
  sandboxing or automatic OS-wide trust integration.
- Release publication and any distribution/notarization work not necessary to
  validate the selected macOS packaging/signing identity.

## Evidence log

### Planning — 2026-09-18

- Inspected baseline `4e07cc16`: FLTK owns socket/timer dispatch and auth dialogs;
  desktop session/pixel ownership still references widgets/platform surfaces;
  mutable session/security settings and saved credentials include global state.
- Recorded source map, portable API/service contracts, storage and credential
  policies, full SwiftUI replacement inventory, phased delivery and test gates.
- Platform references are linked in PLAN §14. No app/core code was changed and
  no implementation, native UI, permission or Keychain test is claimed here.

### N0.3 — source audit and baseline — 2026-09-18

- Commit: `docs(native-ui): audit session isolation and capture build baseline`.
- [STATE-AUDIT.md](STATE-AUDIT.md) maps mutable configuration, credentials,
  crypto/decoder scratch, timers, logging and runtime initialization to owners
  and compatibility obligations. Found additional DES schedule and Tight
  gradient scratch hazards beyond the original plan's named globals.
- Retained FLTK Release build and 304/304 unit tests passed with explicit CLT
  selection; an initial mixed Xcode/CLT link failure and its resolution are
  documented. No application behavior changed in this commit.
- N0.4–N0.6 remain open: screenshots/focus, matched full performance workloads
  and minimum-OS/dependency validation have not been performed.

### N1.4 prerequisite — independent DES schedules — 2026-09-18

- Commit: `fix(rfb): isolate DES key schedules for concurrent authentication`.
- Replaced the private DES process-global key register with an explicit C
  context, used on the stack by both authentication implementations and both
  password-file helpers. Read-only tables are const. Removed unused private
  key-register copy/load functions; repository search found no remaining old
  API callers. No public native ABI or change to VNC algorithms/wire policy.
- Added six low-level/password-file tests and a real `CSecurityVncAuth`
  in-memory stream test covering empty, padded and truncated passwords against
  pre-change response fixtures. Includes a standard DES vector adapted for
  VNC key bit order, deterministic interleaving and four concurrent workers.
- Full retained Release build (including `rfbserver`, `rfbclient`, viewer and
  tools) and **311/311** unit tests passed in 14.93 seconds. Same macOS/CLT
  configuration as the audit baseline. `git diff --check` passed.
- Fresh viewer-disabled Debug build with ASan/UBSan: **7/7** focused tests
  passed in 0.31 seconds. FLTK discovery disabled; NLS/TLS/nettle/H.264/audio
  disabled in this isolated sanitizer configuration. External libraries and
  the prebuilt GoogleTest dependency are not sanitizer-instrumented.
- Initial sanitizer configure could not discover GoogleTest; passing the
  existing local `GTest_DIR` resolved it. The in-memory connection test first
  failed to compile because its test double omitted the abstract `bell`
  method; adding that override resolved it in Release and Debug.
- Logs: `/tmp/tidyvnc-native-des-{build,tests}.log` and
  `/tmp/tidyvnc-native-sanitized-{configure,build,tests}.log` (ephemeral).
- No live TLS/prompt, full protocol matrix, server authentication runtime,
  ThreadSanitizer, native UI, cross-platform runtime or complete concurrent
  session result is claimed. Secret zeroization and the rest of N1.4 remain
  open. The FLTK frontend remains the shipping/default path.

Reproduce the focused sanitizer check from the repository root:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake -S . -B build/native-ui-sanitized -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_VIEWER=OFF \
  -DENABLE_NLS=OFF -DENABLE_GNUTLS=OFF -DENABLE_NETTLE=OFF \
  -DENABLE_H264=OFF -DENABLE_AUDIO=OFF \
  -DCMAKE_PREFIX_PATH=/opt/homebrew \
  -DGTest_DIR="$PWD/build/test-deps/install/lib/cmake/GTest" \
  -DCMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE \
  '-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -Wno-macro-redefined -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' \
  '-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -Wno-macro-redefined -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' \
  '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined'
cmake --build build/native-ui-sanitized --target d3des vncauth --parallel 8
ctest --test-dir build/native-ui-sanitized/tests/unit \
  -R '^(D3DES|VncAuth)\.' --output-on-failure --no-tests=error
```

These host-specific dependency paths describe the tested development setup,
not a portable native release build. The fortify override is confined to this
sanitizer build to avoid Apple's sanitizer macro conflict with Debug `-Werror`.

### N1.4 prerequisite — independent Tight gradient scratch — 2026-09-18

- Commit: `fix(rfb): isolate Tight gradient scratch for concurrent decoding`.
- Replaced the two static scratch rows in the generic Tight gradient filter
  with invocation-local arrays, matching the separate RGB888 path. Storage is
  bounded at 12 KiB per active call; no locks or per-decoder shared scratch.
- Added public-parser/decoder fixtures for 16-bit RGB565, RGB565 in 32-bit
  storage and RGB888, widths 1/17/2048, heights 1/7, uncompressed/compressed
  payloads, direct/translated output, nonzero origins and untouched borders.
- Four concurrent independent decoder sessions (two per generic template
  specialization, different image colours) reproduced corruption **before**
  the fix; the format/stride test passed before the fix. Both pass afterwards.
- Full retained FLTK Release build and **313/313** unit tests passed in 15.04
  seconds; viewer-disabled Debug ASan/UBSan **2/2** decoder tests passed in
  0.59 seconds. Same macOS 27.0 arm64/CLT environment and sanitizer dependency
  limitations as the DES evidence above. `git diff --check` passed.
- Commands: build the default Release target, then run its full unit CTest
  suite as above. For the existing sanitizer configuration, build target
  `tightdecoder` and run CTest with `-R '^TightDecoder\.'`.
- Logs: `/tmp/tidyvnc-tight-before.log`, `/tmp/tidyvnc-tight-{build,tests}.log`,
  `/tmp/tidyvnc-tight-sanitized-{build,tests}.log` (ephemeral).
- This proves the exercised decoder isolation, not the complete concurrent
  session lifecycle. No native UI, ThreadSanitizer, live protocol or physical
  display result is claimed. N1.4 remains unchecked.

### Decoder parity correction and race detection — 2026-09-18

- Commit: `fix(rfb): address packed Tight gradient input by pixel size`.
- The new gradient fixtures exposed an existing byte-offset error in the
  generic filter: it indexed a byte pointer as if each pixel occupied one
  byte. Both the first-pixel-of-row and subsequent-pixel offsets now include
  `sizeof(T)`. The RGB888-specific path is unchanged.
- Added packed-gradient fixtures for 16-/32-bit storage, both byte orders,
  red/green/blue/white, widths 1/3/17 and three rows; verify direct and
  translated output including untouched borders. Before the fix, the test
  failed 72 comparisons; afterwards all comparisons pass.
- Full retained FLTK Release build and **314/314** unit tests passed in 15.20
  seconds. Viewer-disabled Debug ASan/UBSan **3/3** decoder tests passed in
  0.37 seconds. `git diff --check` passed.
- Added a fresh local viewer-disabled **ThreadSanitizer** build: **3/3**
  decoder tests passed in 2.16 seconds, including the four concurrent sessions.
  Explicit `-fsanitize=thread -fno-omit-frame-pointer` C/C++ flags and
  `-fsanitize=thread` linker flags were used; the top-level `ENABLE_TSAN`
  option still excludes Apple. Same macOS 27.0 arm64/CLT environment as above.
  GoogleTest and external dependencies are prebuilt/uninstrumented; this is
  evidence for exercised decoder paths, not all session/service races.
- Logs: `/tmp/tidyvnc-tight-offset-before.log`,
  `/tmp/tidyvnc-tight-offset-{build,tests}.log`,
  `/tmp/tidyvnc-tight-offset-sanitized-{build,tests}.log`, and
  `/tmp/tidyvnc-tight-tsan-{configure,build,tests}.log` (ephemeral).
- N1.4/N1.15 remain open for other global state, service contracts and complete
  session lifecycle validation. No new native UI or live display result.

Reproduce the isolated race-detection configuration:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake -S . -B build/native-ui-tsan -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_VIEWER=OFF \
  -DENABLE_NLS=OFF -DENABLE_GNUTLS=OFF -DENABLE_NETTLE=OFF \
  -DENABLE_H264=OFF -DENABLE_AUDIO=OFF \
  -DCMAKE_PREFIX_PATH=/opt/homebrew \
  -DGTest_DIR="$PWD/build/test-deps/install/lib/cmake/GTest" \
  -DCMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE \
  '-DCMAKE_C_FLAGS=-fsanitize=thread -fno-omit-frame-pointer' \
  '-DCMAKE_CXX_FLAGS=-fsanitize=thread -fno-omit-frame-pointer' \
  '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=thread'
cmake --build build/native-ui-tsan --target tightdecoder --parallel 8
ctest --test-dir build/native-ui-tsan/tests/unit \
  -R '^TightDecoder\.' --output-on-failure --no-tests=error
```

### N1.4 prerequisite — explicit authentication policy — 2026-09-18

- Commit: `feat(rfb): inject per-connection authentication policies`.
- Added a `SecurityClient` constructor taking an owned copy of explicit
  security type IDs without reading/registering global parameters. Rejects
  unknown or uncompiled methods and explicit VeNCrypt wrapper IDs; the wrapper
  is inferred from allowed subtypes. Deduplicates types without reordering.
  An empty list denies negotiation instead of restoring defaults.
- Added a `CConnection` constructor that copies the supplied policy. Existing
  constructors retain FLTK/CLI default behavior. Neither server security
  configuration nor server preference order changed. A static read-only
  `supportedTypes()` query exposes compiled methods independently of settings.
- Nine tests cover snapshots of caller lists/policies and legacy defaults,
  compiled capabilities, unsupported methods, empty-list rejection, RFB 3.3
  and 3.8 negotiation, VeNCrypt advertisement, server ordering and four
  concurrent connections selecting different methods. Negotiation tests use
  the real `CConnection::processMsg` with in-memory streams, not a UI stub.
- Full retained FLTK Release build and **323/323** unit tests passed in 15.11
  seconds. Viewer-disabled Debug **9/9** focused tests passed under ASan/UBSan
  (0.54 seconds) and ThreadSanitizer (1.01 seconds). The Release build includes
  GnuTLS/nettle; both sanitizer builds disable them, exercising rejection of
  uncompiled methods. Same macOS 27.0 arm64/CLT toolchain and prebuilt-library
  instrumentation limitations as earlier evidence. `git diff --check` passed.
- Reproduction: build default target and run the full Release CTest suite;
  build `securityclient` in the existing `native-ui-sanitized` and
  `native-ui-tsan` configurations, then run their unit suites with
  `-R '^SecurityClient\.' --output-on-failure --no-tests=error`.
- Logs: `/tmp/tidyvnc-policy-{build,focused,tests}.log`,
  `/tmp/tidyvnc-policy-sanitized-{build,tests}.log` and
  `/tmp/tidyvnc-policy-tsan-{build,tests}.log` (ephemeral).
- This is the authentication-method selection boundary, not a full immutable
  security/settings model or public C ABI. TLS priority/CA/CRL still use legacy
  globals, and prompt ownership, trust, credentials and runtime initialization
  remain open. No real TLS authentication, prompt cancellation or complete
  concurrent session lifecycle is claimed. N1.2/N1.4/N1.14 remain unchecked.

### N1.4 prerequisite — connection-owned TLS options — 2026-09-18

- Commit: `feat(rfb): snapshot TLS configuration per connection`.
- Added `ClientTLSOptions` with owned priority/CA/CRL strings and no GnuTLS,
  GUI or OS types. Explicit `SecurityClient` policies copy these values and
  every TLS factory branch passes them to `CSecurityTLS`, which retains a
  const snapshot. Embedded NULs are rejected before C-string API use.
- Legacy constructors still use the current CLI/FLTK defaults, now captured
  when the policy/connection is constructed. Editing defaults afterwards no
  longer changes that connection's pending handshake. Explicit allow-list-only
  construction uses library-default TLS priority and no extra CA/CRL files;
  it does not implicitly import legacy paths. Empty file paths skip the file
  loader, while system trust and nonempty-file error handling remain unchanged.
  Server TLS configuration and certificate verification policy are unchanged.
- Added five real in-memory GnuTLS/X509 handshake tests and a TLS-option NUL
  validation test. Fixtures generate a private temporary CA, leaf and CRL;
  private keys stay in memory and temporary public fixtures are removed.
  They never install system trust or read user credentials/trust exceptions.
- Tests verify a successful TLS 1.2 handshake and encrypted application byte,
  caller/global mutation after snapshots, explicit empty-CA rejection,
  invalid-priority failure without fallback, and concurrent connections where
  one succeeds and the other rejects a revoked certificate. The tests exercise
  `SecurityClient`'s factory and `CSecurityTLS`, not just copies of struct fields.
- Full retained FLTK Release build: **329/329** unit tests passed in 15.98
  seconds. New viewer-disabled TLS-enabled Debug builds: **15/15** policy/TLS
  tests passed under ASan/UBSan (0.83 seconds) and ThreadSanitizer (1.46 seconds).
  Existing TLS-disabled ASan/UBSan build: **10/10** policy tests passed in 0.30
  seconds. `git diff --check` passed. Same macOS 27.0 arm64/CLT environment;
  GnuTLS/nettle, GoogleTest and other external dependencies remain uninstrumented.
- The first fixture run expected `tls_error` for rejected trust callbacks;
  the existing API correctly reports `auth_cancelled`. Corrected the test
  expectation and retained assertions on signer-not-found/revoked status bits.
- Reproduce the TLS sanitizer configurations using the earlier sanitizer
  commands with build directories `build/native-ui-tls-sanitized` and
  `build/native-ui-tls-tsan`, respectively, and `ENABLE_GNUTLS=ON` /
  `ENABLE_NETTLE=ON`. Build targets `clienttls securityclient`, then run unit
  CTest with `-R '^(ClientTLS|SecurityClient)\.' --output-on-failure
  --no-tests=error`. `clienttls` is conditional on GnuTLS and non-Windows
  because its private temporary-directory fixture uses `mkdtemp`.
- Logs: `/tmp/tidyvnc-tls-{build,focused,tests}.log`,
  `/tmp/tidyvnc-tls-{sanitized,tsan}-{configure,build,tests}.log` and
  `/tmp/tidyvnc-tls-disabled-{build,tests}.log` (ephemeral).
- Fixture APIs checked against the [GnuTLS X509 API reference](https://www.gnutls.org/manual/html_node/X509-certificate-API.html).
- N1.4/N1.11/N1.14 remain open: this does not implement async prompts, real
  TLS+password authentication, full session teardown, portable trust stores or
  process crypto lifetime ownership. Tests use the existing rejecting trust
  callback and memory transport, not a live socket or native UI. Other mutable
  settings, timers and reconnect credentials still need scoped ownership.

### N1.4 prerequisite — session-owned JPEG negotiation — 2026-09-18

- Commit: `feat(rfb): isolate JPEG negotiation per connection`.
- Added `CConnection::setJpegAllowed`, controlling both standalone JPEG and
  Tight quality hints. Changes schedule a new encoding list at the next update
  boundary; repeated values do not resend it. The saved quality level survives
  disabling/re-enabling JPEG. All encoding negotiation reads instance state.
- The default constructor captures legacy `NoJPEG` on the host thread.
  Explicit-policy construction allows JPEG without consulting that global;
  session callers can set their own value before connecting or during updates.
  The FLTK Options callback applies the legacy value to its connection, fixing
  missing renegotiation when only the JPEG checkbox changes.
- Four tests parse real `SetEncodings` / framebuffer-request wire messages from
  normal connection update callbacks: constructor snapshots, explicit defaults,
  live toggles/quality restoration/no redundant list, and 100 updates each on
  two concurrent sessions with opposing policies. Both preferred JPEG and JPEG
  in the fallback list are covered. Authentication and sockets are outside this
  fixture; the Options dialog itself was not exercised interactively.
- Retained FLTK Release build and **333/333** unit tests passed in 15.96 seconds.
  Viewer-disabled, TLS-disabled Debug builds passed **4/4** new tests under
  ASan/UBSan (0.12 seconds) and ThreadSanitizer (0.24 seconds).
  `git diff --check` passed. Same macOS 27 arm64 / CLT / SDK environment as the
  baseline; no minimum-OS or native UI validation is claimed.
- Reproduce: build `build/tidyvnc-release` with
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build
  build/tidyvnc-release --parallel 8`, then run
  `ctest --test-dir build/tidyvnc-release/tests/unit --output-on-failure
  --no-tests=error`. For the existing sanitizer configurations, build target
  `connectionencoding` and run CTest with `-R '^ConnectionEncoding\.'`.
- Logs: `/tmp/tidyvnc-jpeg-{build,tests}.log` and
  `/tmp/tidyvnc-jpeg-{sanitized,tsan}-{build,tests}.log` (ephemeral).
- N1.4 remains open: timers, reconnect credentials and other viewer globals
  still require scoped ownership. This is not a complete session settings
  contract, native frontend, or full concurrent connection lifecycle test.

### N1.4 prerequisite — connection-owned clipboard limits — 2026-09-18

- Commit: `feat(rfb): snapshot incoming clipboard limits per connection`.
- Added value-only `ClientMessageLimits`, validated to preserve the legacy
  0..INT_MAX range and 256 KiB default. Connections and readers own const copies.
  Explicit-policy construction uses fixed defaults or supplied limits; the
  legacy connection captures `MaxCutText` at construction, before authentication.
  Standalone legacy readers also capture their default at construction.
- Plain text, extended wire payload size and per-format decompressed lengths
  now use the reader snapshot. No incoming clipboard path reads mutable global
  configuration. Existing skip/drain semantics and server reader policy remain
  unchanged. Reject the extended length `0x80000000` before signed negation,
  avoiding undefined integer overflow on malformed input.
- Six tests use real RFB 3.8/None negotiation, ServerInit and clipboard bytes.
  They verify the plain-text boundary/zero limit, construction-time legacy and
  explicit defaults, oversized extended-wire rejection, decompressed format
  filtering while retaining a subsequent valid format, caller-copy isolation,
  invalid policy/length rejection, and concurrent connections with distinct
  caps (20 sessions per worker). A trailing Bell verifies message alignment.
- Retained FLTK Release build: **339/339** unit tests passed in 15.86 seconds.
  Viewer-disabled/TLS-disabled Debug: **6/6** tests passed under ASan/UBSan
  (0.17 seconds) and ThreadSanitizer (0.37 seconds). `git diff --check` passed.
  Same macOS 27 arm64 / CLT / SDK environment as the baseline; no native UI or
  minimum-macOS compatibility result is claimed.
- Reproduce: `DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build
  build/tidyvnc-release --parallel 8`, then `ctest --test-dir
  build/tidyvnc-release/tests/unit --output-on-failure --no-tests=error`.
  For existing `build/native-ui-sanitized` and `build/native-ui-tsan`, build
  `clientclipboard` and run unit CTest with `-R '^ClientClipboard\.'`.
- Logs: `/tmp/tidyvnc-clipboard-{build,tests}.log` and
  `/tmp/tidyvnc-clipboard-{sanitized,tsan}-{build,tests}.log` (ephemeral).
- This cap retains per-message/per-format semantics. It does not bound total
  transport buffering or aggregate decompression work, implement clipboard
  services, or prove full session lifecycle isolation. N1.4 remains open for
  timers, reconnect credentials and other audited globals.

### N1.4 prerequisite — owned security-policy strings — 2026-09-18

- Commit: `fix(rfb): return owned security policy strings`.
- `Security::ToString` now returns `std::string` and is const. It preserves
  ordering, comma separation and omission of unknown IDs without shared output
  storage or a fixed capacity. The old repeated `strncat` calls used the whole
  buffer capacity rather than the remaining space; the full recognized type
  list exceeds that buffer. Updated both callers (FLTK Options and Windows
  authentication registry settings) to pass the temporary string to synchronous
  consumers. This changes the internal C++ return type; it is not a C ABI.
- Four tests cover empty/unknown/ordered/deduplicated types, the complete list
  and parseable names, result lifetime across other calls/mutation/destruction,
  and concurrent formatting of distinct and shared read-only policies.
- Retained FLTK Release: **343/343** tests passed in 16.00 seconds. A final
  explicit standard-header include was followed by a rebuild and focused run.
  Viewer-disabled/TLS-disabled Debug: **4/4** formatting tests passed under
  ASan/UBSan (0.11 seconds) and ThreadSanitizer (0.25 seconds).
  `git diff --check` passed. Same macOS 27 arm64 / CLT / SDK environment as the
  baseline. Windows registry call lifetime was inspected; Windows compilation
  and interactive configuration dialogs were not exercised.
- Reproduce: build `build/tidyvnc-release` with
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build
  build/tidyvnc-release --parallel 8`, then run unit CTest with
  `--output-on-failure --no-tests=error`. For existing
  `build/native-ui-sanitized` and `build/native-ui-tsan`, build target `security`
  and run unit CTest with `-R '^Security\.'`.
- Logs: `/tmp/tidyvnc-security-string-{build,tests}.log`,
  `/tmp/tidyvnc-security-string-final-{build,tests}.log`, and
  `/tmp/tidyvnc-security-string-{sanitized,tsan}-{build,tests}.log` (ephemeral).
- N1.4 remains open. This removes formatting scratch state; it does not make
  concurrent mutation of one policy safe, isolate timers/credentials, or
  implement the native session engine or UI.

### N1.4 prerequisite — session-scoped reconnect credentials — 2026-09-18

- Commit: `feat(rfb): scope reconnect credentials to the logical session`.
- Added GUI-independent `ClientCredentialCache` with explicit recall, retention
  and clear operations. It is noncopyable/nonmovable and owned by the outer
  FLTK reconnect loop; each newly created `CConn` borrows that same session's
  cache. Removed static username/password storage. Authentication failure clears
  only the affected cache, while normal retry keeps it until the host loop ends.
- Cache-owned bytes are overwritten using volatile stores before replacement,
  clear or destruction. Vector storage avoids small-string-buffer remnants in
  this owner. Caller, dialog and protocol copies have separate lifetimes and
  are not covered by this wipe. The cache never reads environment/files/stores.
- Preserve the legacy nonempty username/password reuse rules and credential
  source precedence. Explicit retention opt-out now drops earlier cached values;
  a password-only replacement cannot pair a new password with an old username.
  No Keychain persistence or implicit retention was introduced.
- Six GUI-independent tests cover copied input ownership, repeated retry reuse,
  retention opt-out, pair/password-only replacement, empty values, independent
  failure/teardown and concurrent sessions with distinct credentials. Compile
  assertions enforce stable, noncopyable ownership. Tests do not interact with
  real credentials or claim full authentication/prompt lifecycle validation.
- Retained FLTK Release build: **349/349** tests passed in 15.94 seconds.
  Viewer-disabled/TLS-disabled Debug: **6/6** cache tests passed under ASan/UBSan
  (0.29 seconds) and ThreadSanitizer (0.48 seconds). `git diff --check` passed.
  Same macOS 27 arm64 / CLT / SDK environment as the baseline; interactive retry
  dialogs, Windows/Linux builds and minimum-OS compatibility were not tested.
- Reproduce: `DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build
  build/tidyvnc-release --parallel 8`, then run unit CTest with
  `--output-on-failure --no-tests=error`. In existing `build/native-ui-sanitized`
  and `build/native-ui-tsan`, build `clientcredentials` and run unit CTest with
  `-R '^ClientCredentials\.'`.
- Logs: `/tmp/tidyvnc-credentials-{build,tests}.log` and
  `/tmp/tidyvnc-credentials-{sanitized,tsan}-{build,tests}.log` (ephemeral).
- N1.4/N1.9/N1.11 remain open. Environment and password-file inputs, prompt
  cancellation, credential stores and protocol secret copies still need native
  ownership contracts; timers and other audited globals remain shared. The
  cache requires serialized access within one logical session.

### N1.1 — portable viewer targets and clean headless build — 2026-09-18

- Commit: `refactor(viewer): establish and verify the headless core build`.
- Created `tidyvnc_viewer_core` with the existing transform, monitor layout,
  resampling, tile-cache and cursor code extracted into `viewer/core`.
  Created `tidyvnc_viewer_platform` with the host display-metrics value contract
  and validation. The former depends on the latter and existing RFB/client
  transport libraries; neither depends on FLTK or platform UI implementations.
  FLTK, rendering tests and scaling benchmarks now link the same shared targets.
- `BUILD_PLATFORM_APPS=OFF` skips platform server/configuration directories and
  their dependency discovery. Combined with `BUILD_VIEWER=OFF`, Linux no longer
  requires X11. NLS-disabled macOS core no longer links Carbon. Defaults preserve
  retained application builds and NLS-enabled bundle-localization behavior.
- Added a non-GoogleTest headless consumer exercising RFB connection construction
  and teardown, transport parsing, display metrics, scaling/resampling and the
  credential cache. Added a clean-build driver that refuses existing build
  directories, disables FLTK/X11 discovery, audits the generated transitive
  CMake graph/public headers and runs the smoke and available unit suites.
  Added Linux/macOS CI jobs with protocol/test dependencies only.
- Clean Release with TLS/nettle and GoogleTest: **334/334** headless unit tests
  passed in 14.52 seconds and **1/1** smoke passed in 0.07 seconds. A second
  clean Release without TLS/nettle or GoogleTest passed **1/1** smoke in 0.07
  seconds. Both generated graphs contain only the consumer, two viewer targets,
  `rfbclient`, `network`, `rfb`, `rdr` and `core`; no server or GUI target.
- A third fresh headless Debug build (`build/native-ui-n1-final`) passed
  **334/334** unit tests in 14.46 seconds and **1/1** smoke test, with the
  dependency audit passing. Log: `/tmp/tidyvnc-n1-final.log`.
- Retained FLTK Release rebuild: **349/349** tests passed in 16.37 seconds,
  plus **1/1** smoke in 0.09 seconds. `otool -L` of the headless executable
  confirms no FLTK/Carbon/Cocoa/AppKit/SwiftUI dependency. Branding/attribution
  audit and all seven build-option compatibility checks passed. Attribution
  fixture paths were migrated with the sources; copyright lines were preserved.
- Initial builds found leftover include paths in the monitor widget and missing
  target dependencies for EmulateMB and Cocoa-based test/benchmark consumers.
  Those were corrected before successful validation. CMake's unused-variable
  notices for disabled FLTK/X11 find switches are expected: discovery is skipped.
- Reproduce with `tests/viewer/headless.py` and the commands in
  [viewer/README.md](../../viewer/README.md). Local fresh build directories:
  `build/native-ui-headless-verified` (TLS + tests),
  `build/native-ui-headless-minimal` (no TLS/GoogleTest).
  Logs: `/tmp/tidyvnc-n1-headless-{verified,minimal}.log`,
  `/tmp/tidyvnc-n1-fltk-{build,tests,smoke}.log` and
  `/tmp/tidyvnc-n1-brand-audit.log` (ephemeral).
- Host: macOS 27.0 arm64, AppleClang 21 / CLT SDK 27, Homebrew protocol
  dependencies and local GoogleTest. Linux/macOS CI is added but has not been
  run remotely. Windows builds, minimum-OS compatibility and UI interactions
  remain unverified. This completes the N1.1 build/dependency boundary only;
  service implementations, session lifecycle, C ABI and native UI remain their
  own unchecked items. No full N1 phase completion is claimed.

### N1.8 — retained frame/cursor publication — 2026-09-18

- Commit: `feat(viewer): add bounded retained frame and cursor publication`.
- Added `viewer::FramePublisher` and immutable frame/cursor leases to the portable
  viewer core. Input spans specify byte length/stride, dimensions, BGRA8/RGBA8,
  alpha mode and row origin. Copies normalize row origin to top-left, exclude
  padding and preserve channel/alpha representation. Damage/hotspots are always
  top-left remote pixels. Bounds/stride overflow/truncation/layout/hotspot checks
  happen before data access. The producer must synchronize decoder writes first.
- Payloads survive source-buffer destruction, resize, reconnect and publisher
  teardown. Each frame has session, size/layout and sequence generations;
  cursor leases have session/sequence and hotspot metadata. Generation reset
  clears queued old data and publishes explicit clears. Stale publishers are
  rejected; already-delivered leases keep their original generation for the
  eventual UI bridge to reject when inappropriate.
- Per-view mailboxes retain at most one pending frame/cursor update, union skipped
  damage independently and force full damage on layout change. New subscriptions
  receive current state. Subscriber count is capped; pixel budget includes every
  retained payload, including external/old-generation leases and cursor data.
  Exhaustion returns backpressure without waiting for consumers. Frame damage
  survives failed allocation/reservation until the next successful publication;
  skipped resize also forces full invalidation. Cursor publication requires retry.
- Nine tests cover padded/bottom-up input and lease lifetime, independent fast/
  slow/late consumers, retained-frame backpressure/recovery, resize/format changes,
  skipped resize/reconnect invalidation, cursor alpha/hotspot/shared budget,
  malformed spans and subscriber limits, publication from an RFB pixel buffer,
  and concurrent consumption/release during generation reset. The independent
  headless smoke consumer now also exercises publication/retention/reset.
- Retained FLTK Release: **358/358** unit tests (16.50 seconds) and **1/1** smoke
  (0.09 seconds) passed. Fresh headless Debug build with TLS/nettle and GoogleTest:
  **343/343** tests (14.65 seconds), **1/1** smoke and dependency audit passed.
  Viewer-disabled/TLS-disabled Debug: **9/9** focused tests passed under ASan/UBSan
  (0.34 seconds) and ThreadSanitizer (0.54 seconds). `git diff --check` passed.
- Reproduce with the headless driver in [viewer/README.md](../../viewer/README.md),
  using a new directory (local evidence: `build/native-ui-frames-headless`). For
  existing sanitizer configurations build `framepublisher` then run unit CTest
  with `-R '^FramePublisher\.' --output-on-failure --no-tests=error`.
  Logs: `/tmp/tidyvnc-frames-headless.log`,
  `/tmp/tidyvnc-frames-fltk-{build,tests}.log`, `/tmp/tidyvnc-frames-smoke.log`, and
  `/tmp/tidyvnc-frames-{sanitized,tsan}-{build,tests}.log` (ephemeral).
- Same macOS 27 arm64 / AppleClang 21 CLT environment. The payload budget excludes
  decoder source buffers, allocator metadata and native surfaces. A complete
  snapshot currently copies full pixels; production performance needs its own
  measurement gate. No physical-display/native-renderer or real socket/session
  teardown validation is claimed. Feeding leases from the future session engine,
  C ABI mapping, native presentation and retry scheduling remain N1.7/N2/N1.6;
  the retained FLTK renderer does not incur these snapshot copies.

### N1.7 — window-independent protocol session — 2026-09-18

- Commit: `feat(viewer): connect the protocol session to retained views`.
- Added `viewer::ProtocolSession`, which owns each RFB connection attempt,
  authoritative `ManagedPixelBuffer`, decoder lifetime and retained publisher.
  It has no window/widget/native-surface ownership or GUI loop. The host supplies
  borrowed streams and drives protocol processing on a serialized executor;
  explicit security/TLS, message and buffer policies are copied at construction.
- The source buffer is canonical BGRA32 with opaque alpha semantics. The session
  requests that wire format and uses the existing RFB decoding/conversion path.
  End-of-update joins decoding before publication. Resize preserves overlap,
  zeros exposed pixels and publishes full damage. Cursor callbacks publish
  straight-RGBA leases or explicit hide; retained protocol cursor data supports
  retries without borrowing callback storage.
- Attach returns a current-state subscription; dropping its last reference
  detaches without stopping the session or other views. Publication backpressure
  retains source/damage and can be retried without more network input. Partial
  updates are never published by retry. Close drains on the worker and advances
  the generation/queues clears, while old leases remain valid. Repeated close is
  harmless; reconnect creates a fresh RFB object while retaining subscriptions.
  Processing errors close/invalidate the attempt before propagating.
- Injectable synchronous authentication callbacks are retained by the session.
  Missing handlers cancel credentials/reject trust, and processing/close/retry
  reentry is rejected. This is the seam for N1.10, not an async prompt solution.
- Enforce a per-source-frame byte limit before allocation (64 MiB default) and
  the existing RFB allocator's signed arithmetic limit even with an oversized
  configured budget. Resize temporarily holds old/new source buffers separately
  from the publication budget (128 MiB default), decoder scratch and protocol
  state; these are buffer limits, not a whole-process memory claim.
- Ten tests drive actual RFB client processing via fixture streams: None
  negotiation, raw/CopyRect pixels and independent/detached/late views, resize,
  cursor shape/hide, backpressure retry, close/reconnect/destruction with retained
  leases, oversized allocation, complete-update boundaries, credential rejection
  and the VNC challenge callback path/reentry guard. The VNC fixture supplies a
  successful SecurityResult; it is not a server-side password-verification test
  and does not satisfy N1.11. The headless smoke now consumes `ProtocolSession`
  directly instead of defining its own `CConnection` subclass.
- Retained FLTK Release: **368/368** unit tests passed in 16.51 seconds, plus
  **1/1** smoke (0.09 seconds). Fresh headless Debug with TLS/nettle/GoogleTest:
  **353/353** unit tests (14.69 seconds), **1/1** smoke and dependency audit passed.
  Viewer-disabled/TLS-disabled Debug: **10/10** tests passed under ASan/UBSan
  (0.33 seconds) and ThreadSanitizer (0.69 seconds). `git diff --check` passed.
- Reproduce using [viewer/README.md](../../viewer/README.md) and the headless
  driver with a new directory (local: `build/native-ui-protocol-session`). For
  existing sanitizer builds, build `protocolsession` and run unit CTest with
  `-R '^ProtocolSession\.' --output-on-failure --no-tests=error`.
  Logs: `/tmp/tidyvnc-session-headless.log`,
  `/tmp/tidyvnc-session-fltk-{build,tests,smoke}.log`, and
  `/tmp/tidyvnc-session-{sanitized,tsan}-{build,tests}.log` (ephemeral).
- Same macOS 27 arm64 / AppleClang 21 CLT environment. The retained FLTK adapter
  remains on its existing rendering path for comparison. Socket readiness,
  asynchronous lifecycle/commands/events, prompt rendezvous, input/clipboard
  services, native UI/ABI and asynchronous close/drain remain their own unchecked
  items. No interactive GUI, physical-display, real TLS/password-server or
  Windows/Linux execution result is claimed by this milestone.

### N1.10 — cancellable worker authentication prompts — 2026-09-18

- Commit: `feat(viewer): bridge authentication with cancellable worker prompts`.
- Added `PromptAuthentication`, a per-session `SessionAuthentication` delegate.
  Credential, certificate and host-key callbacks publish owned request metadata,
  notify outside the mutex and park only their worker. UI/service code takes the
  request and replies using its monotonic ID and connection generation. The wait
  releases the bridge mutex; no framebuffer/publication/store lock is held at the
  protocol authentication seam. No GUI loop or main-thread wait is introduced.
- Direct cancellation wakes a parked callback without a queued worker command.
  Cancellation wins over an accepted-but-unconsumed reply, prevents later prompts
  in the same attempt and distinguishes cancellation, timeout and peer closure.
  The monotonic timeout defaults to 60 seconds and is configurable up to 24 hours.
  Reconnect requires worker drain and a newer generation; request IDs never reset.
- Reject stale/duplicate/wrong-kind replies and oversized payloads. Identity data
  is capped at 64 KiB; server names, fingerprints and individual credential fields
  at 4096 bytes. Private credential reply buffers are overwritten after use,
  cancellation or failure. Caller-owned strings retain their ordinary lifetimes.
- `ProtocolSession` begins the delegate attempt and cancels pending work during
  worker close. Hosts must directly call bridge cancellation before queuing close
  on a parked worker; `ProtocolSession::close()` itself remains worker-only.
  The host notification hook must enqueue and return promptly and the delegate
  must remain alive until worker drain. See [viewer/README.md](../../viewer/README.md).
- Fourteen tests cover reply typing/limits, immediate notifier reply without
  deadlock, trust payload ownership, duplicate/stale replies, deadline expiry,
  cancellation before/during wait and after accepted reply, notification failure,
  independent sessions, and actual RFB-client VNC callbacks resumed/cancelled and
  reconnected through the bridge. The fixture supplies SecurityResult; it does
  not verify the server-side password or prove actual TLS/socket cancellation.
- Retained FLTK Release: **382/382** unit tests passed (18.95 seconds), plus
  **1/1** smoke (0.09 seconds). Fresh headless Debug with TLS/nettle/GoogleTest:
  **367/367** unit tests (14.92 seconds), smoke and dependency audit passed.
  Viewer-disabled/TLS-disabled Debug: **24/24** prompt/session tests under
  ASan/UBSan (0.55 seconds) and ThreadSanitizer (0.97 seconds). The initial strict
  Debug build caught an ignored test future return value; it was corrected before
  these passing runs. `git diff --check` and branding/attribution audit passed.
- Reproduce the headless check using the README with a new build directory
  (local: `build/native-ui-prompts-final`). Build `promptauthentication` and
  `protocolsession` in the sanitizer configurations and run unit CTest with
  `-R '^(PromptAuthentication|ProtocolSession)\.' --output-on-failure --no-tests=error`.
  Ephemeral logs: `/tmp/tidyvnc-prompts-{build,test,smoke}.log`,
  `/tmp/tidyvnc-prompts-headless-final.log`, and
  `/tmp/tidyvnc-prompts-{sanitized,tsan}-{build,test}.log`.
- Same macOS 27 arm64 / AppleClang 21 CLT environment; sanitizers instrument project
  code, not all external libraries. Native dialogs/dispatch, trust persistence,
  automatic socket peer monitoring, async lifecycle and real TLS/VNC-server
  cancellation proof remain their unchecked service/frontend/N1.6/N1.11 items.
  No interactive GUI or Linux/Windows execution result is claimed.

### N1.11 — real VNC/TLS authentication and cancellation proof — 2026-09-18

- Commit: `test(viewer): prove authentication cancellation over loopback TCP`.
- Added `authenticationsocket`, an independent loopback TCP RFB peer exercising
  the actual `ProtocolSession` and `PromptAuthentication`. The server compares
  the VNC challenge response with the recorded password known-answer vector
  before sending SecurityResult; an incorrect password receives a real failure.
  No client DES helper computes the server's expected answer.
- TLS cases negotiate VeNCrypt X509Vnc and GnuTLS TLS 1.2 with an ephemeral
  in-memory self-signed certificate, exercise the real trust callback, then
  verify VNC authentication inside the encrypted connection. Tests cover both
  certificate acceptance and rejection and enforce the credential secure flag.
- Sixteen cases cover plain VNC and TLS success, wrong passwords, outstanding
  trust/credential cancellation from host close/quit, monotonic prompt timeout,
  peer disappearance, mismatched replies, reconnect with a new socket/generation
  and rejection of old/duplicate replies. A second session with the other security
  mode completes while the first remains parked, checking that the synchronous
  callback does not monopolize shared crypto/session locks.
- A test host observes TCP FIN using macOS kqueue EV_EOF or Linux POLLRDHUP and
  directly cancels the parked bridge. It does not consume protocol bytes or
  require a command to run on the waiting worker. Teardown cancels prompts,
  interrupts sockets and joins workers before destroying streams/peer resources.
  Prompt, peer and drain waits are bounded, with a 30-second CTest case limit.
- GnuTLS-enabled macOS/Linux builds register these tests in the ordinary unit
  suite, including the existing headless CI matrix. The server binds only IPv4
  loopback on an ephemeral port, uses no external server and persists no key or
  certificate. The initial sandboxed run could not bind loopback; the authorized
  execution outside that restriction passed. An initial compile-time narrowing
  error in the test policy initializer was corrected with an explicit type.
- Headless Debug: **16/16** focused socket tests passed (1.14 seconds).
  GnuTLS-enabled ASan/UBSan: **16/16** (1.62 seconds); ThreadSanitizer:
  **16/16** (2.26 seconds). Full retained FLTK Release: **398/398** unit tests
  (18.45 seconds), plus **1/1** smoke. Full existing headless Debug:
  **383/383** unit tests (16.28 seconds), plus **1/1** smoke (0.13 seconds).
  `git diff --check` and branding/attribution audit passed.
- Reproduce with the [README instructions](../../viewer/README.md): build
  `authenticationsocket` in a GnuTLS-enabled configuration, then run unit CTest
  with `-R AuthenticationSocket --output-on-failure --no-tests=error`. Local
  configurations: `build/native-ui-prompts-final`, `build/tidyvnc-release`,
  `build/native-ui-tls-sanitized` and `build/native-ui-tls-tsan`.
  Ephemeral logs: `/tmp/tidyvnc-authsocket-test.log`,
  `/tmp/tidyvnc-authsocket-{sanitized,tsan}-test.log`, and
  `/tmp/tidyvnc-authsocket-{release,headless}-{tests,smoke}.log`.
- Same macOS 27 arm64 / AppleClang 21 CLT environment; sanitizer instrumentation
  covers project code, not all external GnuTLS/crypto libraries. Linux code is
  wired into CI but was not executed locally; Windows socket coverage is absent.
  This completes authentication/cancellation proof at the core/host boundary.
  The fixture controller/FIN observer is not the production reactor/lifecycle
  adapter: N1.5/N1.6/N1.13 and native close/quit wiring remain open. Other security
  modes/TLS versions and N1.14's full settings/input/clipboard isolation matrix
  remain separate work. No native UI or full application-quit claim is made.

### N1.12 — bounded input queue and release behavior — 2026-09-18

- Commit: `feat(viewer): deliver bounded keyboard and pointer input`.
- Completed the input portion of N1.12. `ProtocolSession::inputQueue()` returns
  a retained thread-safe mailbox; producers submit generation-tagged physical key
  IDs/RFB symbols/QEMU codes and pointer state. Only worker `drainInput()` writes
  protocol messages. Core rejects disconnected, stale, unfocused, view-only and
  invalid input. Mapping native keyboard/shortcut semantics remains host work;
  this path does not repeat the legacy platform-specific keysym normalization.
- Queue count defaults to 256 (configurable 1–65536) and held keys to 64
  (1–1024). Drain work is capped at queue capacity plus one entry per call.
  Adjacent motion with unchanged buttons coalesces, including drag motion; key
  events and button transitions keep order and original transition coordinates.
  Existing RFB writing handles position clamping and negotiated extended input.
- Release-all uses a flag outside normal queue capacity. Focus loss and enabling
  view-only discard unsent input and place release ahead of future input. Queue
  capacity/allocation exhaustion returns `Overflow`, increments the status counter,
  releases held state on drain and suspends input until explicit focus reactivation.
  Held-key exhaustion reports false from drain and releases in that same call.
  Repeat/release uses the original physical key's mapping; chords unwind in
  reverse press order, and pointer buttons are explicitly released.
- Close and protocol/write error invalidate queued input, attempt held-key/button
  release and finish local cleanup even if release writes fail. Reconnect retains
  focus/view-only policy, with a new generation and no old queued/held state.
  Retained mailboxes are safe and disconnected after session destruction. A command
  already dequeued may finish before concurrent policy changes; the next dequeue
  processes the release barrier.
- Fifteen RFB wire tests cover rejection/generation changes, transition/motion
  ordering, repeated keys, QEMU keycodes/extended buttons, coalescing at capacity,
  focus loss, core view-only, queue and held-key overflow/recovery, disconnect,
  retained lifetime, failed writes/protocol errors, input validation/clamping and
  a concurrent producer alongside a session with different input policy.
- Focused Debug **39/39** input/session/prompt tests (0.62 seconds), ASan/UBSan
  **39/39** (0.85 seconds), ThreadSanitizer **39/39** (1.59 seconds). Full retained
  FLTK Release **413/413** unit tests (18.14 seconds), **1/1** smoke (0.16 seconds).
  Full existing headless Debug **398/398** unit tests (16.12 seconds), **1/1** smoke
  (0.09 seconds). Branding/attribution audit and `git diff --check` passed.
  Strict Debug caught a new member shadowing a stream parameter and incorrect
  underrun/EOF assumptions in the new test parser; both were corrected before
  the passing runs.
- Reproduce by building `sessioninput`, `protocolsession`, `promptauthentication`
  and running unit CTest with
  `-R '^(SessionInput|ProtocolSession|PromptAuthentication)\.' --output-on-failure --no-tests=error`.
  Local configurations: `build/native-ui-prompts-final`, `build/native-ui-sanitized`,
  `build/native-ui-tsan`, `build/tidyvnc-release`. Ephemeral logs:
  `/tmp/tidyvnc-input-native-ui-{prompts-final,sanitized,tsan}-{build,tests}.log`
  and `/tmp/tidyvnc-input-{release,headless}-{tests,smoke}.log`.
- Same macOS 27 arm64 / AppleClang 21 CLT environment. Focused sanitizer builds
  disable TLS; full regression builds retain it, including the loopback suite.
  Project code is instrumented, not every external library. No native UI or
  Windows/Linux execution claim. Queue/held-state bounds do not cover transport
  buffers or whole-process memory; a dead transport cannot guarantee remote
  release delivery. Worker wakeup/writable readiness and asynchronous flush/drain
  remain N1.6/N1.13. Native mapping/multi-view focus and general ordered
  event/completion queues/statistics coalescing remain pending. The parent N1.12
  checkbox stays open until that remaining event contract is implemented.

### N1.12 — bounded event stream and completion reservations — 2026-09-18

- Commit: `feat(viewer): bound session events and reserve operation completions`.
- Completed N1.12's remaining event queue portion with `SessionEvents`: owned
  fixed-size records, preallocated event/reservation storage, queue-local sequence
  and operation IDs, generation checks, and an initial current-state snapshot.
  Queued events plus outstanding completion reservations are bounded by capacity
  (128 default, configurable 2–65536), plus one fixed terminal-overflow record.
  Producers run on the owning executor; consumers can take/query on other threads.
  No user callback executes under an event mutex.
- Statistics replace older statistics and append at the tail, preserving reliable
  event order; sequence gaps are intentional. Reliable events and operation
  admission can reclaim statistics slots. If reliable records/reservations fill
  capacity, statistics only update the current snapshot. They never evict a result.
- Reserve a completion slot before accepting an operation. Completion consumes
  that reservation exactly once; unknown/duplicate IDs and stale-generation
  admission are rejected. Pending operations must finish before generation advance.
  Overflow preserves queued records/completions, fails outstanding reservations,
  emits one terminal `Overflow` in the dedicated slot and seals the stream.
  Sequence exhaustion retains headroom for completion/fault delivery. Sealing and
  cancellation finish pending reservations without discarding queued results.
- `ProtocolSession::subscribeEvents()` attaches one lifecycle coordinator, separate
  from view subscriptions, and starts with the current snapshot even after connect.
  Protocol state, desktop size, bells and completed-frame statistics feed the queue.
  Normal subscriptions survive reconnect with generation-tagged events; retained
  streams seal on session destruction and remain readable. Sealed coordinators
  may be replaced; IDs remain scoped to the original stream identity.
- `requestRefresh()` reserves a result before scheduling an RFB refresh and returns
  its operation ID, or zero without changing protocol state when admission fails.
  Completion means scheduled, not receipt of a new frame. Event publication
  overflow closes the affected attempt, invalidates queued input and attempts
  real RFB key/button release; startup overflow also leaves no live attempt.
- Nine queue tests and seven protocol integration tests cover snapshot ownership,
  ordering/coalescing, reserved capacity, overflow with outstanding completions,
  cancellation/sealing, stale/duplicate results, concurrent statistics consumption,
  late subscription, refresh admission/results, held-key release on overflow,
  reconnect, retained lifetime, resize and coordinator replacement/startup failure.
- Full retained FLTK Release **429/429** unit tests (18.48 seconds), **1/1** smoke
  (0.22 seconds). Full existing headless Debug **414/414** unit tests (16.40 seconds),
  **1/1** smoke (0.09 seconds). Final focused input/event/session/prompt suites:
  ASan/UBSan **55/55** (2.05 seconds), ThreadSanitizer **55/55** (3.53 seconds).
  Branding/attribution audit and `git diff --check` passed.
- Reproduce by building `sessionevents`, `protocolsession`, `sessioninput`,
  `promptauthentication` and running unit CTest with
  `-R '^(SessionEvents|ProtocolSession|SessionInput|PromptAuthentication)\.' --output-on-failure --no-tests=error`.
  Local configurations: `build/native-ui-prompts-final`, `build/native-ui-sanitized`,
  `build/native-ui-tsan`, `build/tidyvnc-release`. Ephemeral logs:
  `/tmp/tidyvnc-events-native-ui-{sanitized,tsan}-{build,tests}.log` and
  `/tmp/tidyvnc-events-{release,headless}-{tests,smoke}.log`.
- Same macOS 27 arm64 / AppleClang 21 CLT environment. Focused sanitizer builds
  disable TLS; full suites retain the real loopback authentication checks. External
  libraries are not all instrumented; no Linux/Windows or native UI run is claimed.
  This completes the bounded input/event/coalescing contract, not N1.5's full
  session/listener state machine or operation catalog. Resolving/listening and
  authentication substates, service events, native integration, timer throttling,
  readiness/wakeup and asynchronous drain remain their unchecked N1.5/N1.6/N1.9/
  N1.13 items. Frame/cursor pixel payloads retain their separate N1.8 budget.

### N1.2 — owned endpoints and shared checked address parsing — 2026-09-18

- IDs / commit: N1.2 endpoint subtask; current working tree (not committed).
  The parent N1.2 remains open for typed options, capabilities, general structured
  session errors and settings schema/precedence.
- Added `viewer::Endpoint`: owned original label, transport, canonical host,
  numeric port, exact IPv6 scope, Unix socket path and opaque non-secret route
  identity. Parsing performs no IO or global configuration access. ASCII hostname
  case and numeric IP spellings normalize; aliases, trailing dots, scopes, routes,
  mapped-IPv6/IPv4 and Unix path bytes remain distinct. No IDNA or credential-store
  policy is implied. Getters expose validated values without field mutation.
- Extracted the common VNC syntax into `network::parseHostAndPort`, consumed by
  both the endpoint value and legacy `getHostAndPort` (FLTK connect/history/tunnel
  and the Windows reverse-connection caller). Preserve display/explicit-port,
  bracketed/bare IPv6, leading-plus/padding, empty-host localhost, the 5500 reverse
  base and historical double-colon ambiguity. `[::1]` is IPv6; `::1` is localhost
  port 1. One shared parser prevents native and retained syntax drift.
- Checked numeric accumulation replaces unchecked `strtol` narrowing; empty port
  suffixes, explicit zero, negatives, overflow and malformed host syntax now fail
  explicitly. Empty input no longer dereferences before its buffer. String inputs
  reject embedded NUL. Typed errors omit input; the legacy adapter retains
  localized diagnostics and leaves output values unchanged on parse rejection.
  These malformed-input rejections intentionally tighten prior parser behavior.
- Address and route lengths are independently capped at 4096 bytes by Endpoint.
  Any slash selects Unix transport as in the POSIX viewer, with exact path bytes.
  Hosts explicitly disable unsupported Unix transport; filesystem/path-length
  checks belong to the future transport adapter. No platform handles in headers.
- Twelve new endpoint tests plus ten existing host/port tests verify compatibility,
  canonical identity and alias separation, scopes/routes, Unix paths, typed errors,
  size/port bounds, owned data, concurrent parsing, reverse base and adapter errors.
  The first focused run exposed an incorrect test assumption about unbracketed
  `fe80::1%en0`; the fixture was corrected to preserve the existing double-colon
  rule, with an additional `2001::1` compatibility assertion. Final **22/22**
  focused Debug tests passed (0.18 seconds), **1/1** headless smoke (0.08 seconds).
- Clean headless Debug configured with FLTK/X11 discovery disabled, built client
  and server protocol libraries, passed the dependency audit and **1/1** smoke.
  **426/426** unit tests passed across the initial run and socket-enabled rerun.
  Retained FLTK RelWithDebInfo built successfully, with **441/441** unit tests
  across the same two-stage execution and **1/1** smoke (0.13 seconds).
  Both initial full runs failed only the 16 authentication fixtures at loopback
  bind in the sandbox; rerunning just those cases with authorized local socket
  access passed **16/16** in each build (0.95 / 1.08 seconds). No protocol failure
  was suppressed. Focused ASan/UBSan **22/22** passed (0.30 seconds).
- Reproduce: use the headless command in [viewer/README.md](../../viewer/README.md)
  with a new directory, Debug, Homebrew dependencies and GnuTLS/nettle enabled.
  Local clean directory: `build/native-ui-endpoint-headless`. Retained frontend:
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build build/hidpi --parallel 8`,
  then unit/viewer CTest with `--output-on-failure --no-tests=error`. Where sandbox
  loopback is blocked, rerun unit CTest with `--rerun-failed` and socket access.
  Sanitizers: build `endpoint hostport` in `build/hidpi-sanitized`, then unit CTest
  with `-R '^(Endpoint|HostPort|HostPost)\.' --output-on-failure --no-tests=error`.
  `git diff --check` and branding/attribution audit passed. Extracted parser source
  retains the original RealVNC copyright/license notice.
- macOS 27.0 arm64, AppleClang 21 CLT (`clang-2100.3.34.2`), SDK 27.0; explicit
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools` throughout. Sanitizers cover
  project code, not every external library. Logs are ephemeral under
  `/tmp/tidyvnc-endpoint-{headless,headless-loopback,fltk-build,fltk-tests,fltk-loopback,fltk-smoke,sanitized-build,sanitized-tests}.log`.
- No native connection adapter/UI, Windows/Linux execution, minimum-macOS claim,
  socket readiness, scheduling or credential-key implementation. The Windows
  reverse caller remains source-compatible but was not built on this Mac.

### N1.2/N1.3/N1.4 — scoped encoding settings and shared policy — 2026-09-18

- IDs / commit: encoding/color settings portion of N1.2/N1.3/N1.4; current working
  tree, not committed. Full settings/document/service milestones remain open.
- Added immutable `EncodingOptions` and schema for AutoSelect, FullColor,
  LowColorLevel, PreferredEncoding, CustomCompressLevel, CompressLevel, NoJPEG
  and QualityLevel. Metadata includes defaults, ranges, aliases, persistence and
  live-change semantics. Decoder availability is queried without legacy globals;
  uncompiled choices yield a typed Unsupported error. Input-bearing diagnostics
  are avoided, patches/names/values are bounded, and malformed integers fail.
- Layer resolution implements compiled → app defaults → selected profile → session
  → CLI precedence with per-setting effective-source tracking. Aliases share the
  canonical key; all supplied layers validate. Draft patches produce new values
  atomically without changing defaults or a live session.
- `ProtocolSession` accepts an encoding snapshot and implements worker-only live
  application with completion reservation before mutation. Rejected admission
  changes nothing; successful completion means scheduled, not server acknowledgement.
  Options survive reconnect, while attempt bandwidth starts fresh. RFB writers
  apply format changes at their existing safe boundary; reduced wire colors decode
  into retained BGRA frames. JPEG disabling removes both standalone JPEG and Tight
  quality hints, including when JPEG remains the stored preferred encoding.
- Retained FLTK parameters now derive defaults/ranges/compiled choices and text
  validation from the core schema. Existing aliases and document/Options callers
  retain their interfaces. `CConn` captures policy on construction and Options
  callbacks rather than reading encoding globals during automatic selection.
  Connecting to an old server no longer writes global FullColor. Both frontends
  preserve the pre-3.8 negotiated-format restriction.
- Extracted automatic selection thresholds and the bandwidth weighting policy.
  Both callers use monotonic update durations; samples saturate at 1 Tbit/s to
  avoid overflow. FLTK counts raw socket bytes; core counts active RFB stream bytes
  (decrypted with TLS). This does not establish matched performance budgets.
  FLTK initial negotiation now honors custom-compression off and automatic quality
  consistently with later updates. Empty integer values now fail instead of zero;
  accepted boolean/base-0 integer syntax and case-insensitive aliases are preserved.
- Eleven policy tests, seven RFB wire tests and one FLTK adapter test cover defaults,
  aliases, enum capabilities, provenance/precedence, draft atomicity, ranges/bounds,
  thresholds, concurrent independent snapshots/sessions, initial and live wire
  hints, reduced-color decoding, completion admission, reconnect and old servers.
  Focused policy/session **35/35** passed; adapter/state **12/12** passed. Initial
  strict compilation caught a shadowed member name and a test accessing protected
  PixelFormat fields; the names and test's use of the public conversion API were fixed.
- Full retained FLTK RelWithDebInfo: **460/460** unit tests (15.98 seconds), **1/1**
  smoke (0.12 seconds). Full headless Debug: **444/444** (14.50 seconds), **1/1**
  smoke (0.06 seconds). Full runs used authorized local loopback access for the
  existing authentication fixtures. Focused ThreadSanitizer: **35/35** (1.08 seconds).
  Final ASan/UBSan: **35/35** (0.55 seconds). Clean headless Debug configuration
  with GUI discovery disabled passed the dependency audit. After the final CMake
  include-order correction, rebuild and verification passed **444/444** unit tests
  (14.71 seconds), **1/1** smoke (0.11 seconds) and the retained adapter/state
  **12/12** (0.24 seconds). Branding/attribution audit and `git diff --check` passed.
- ASan first failed during GoogleTest registration with the prebuilt Homebrew
  dependency, before test bodies ran. Built GoogleTest 1.15.0 from existing local
  source with the same CLT compiler and ASan/UBSan flags. That also exposed a real
  test-build include-order problem: broad Homebrew includes selected newer headers
  while linking the chosen local library. Unit CMake now puts the selected GTest
  target's includes first. This fixes dependency consistency without disabling any
  sanitizer checks. The clean ASan build uses the existing macOS fortify-macro
  compatibility flags; an initial macro-redefinition build error was corrected.
- Reproduce full builds using the viewer README. Local configurations:
  `build/hidpi`, `build/native-ui-endpoint-headless` and the clean verification
  `build/native-ui-encoding-headless`. Focused checks: build `encodingoptions`,
  `sessionencoding`, `protocolsession`; run unit CTest with
  `-R '^(EncodingOptions|SessionEncoding|ProtocolSession)\.' --output-on-failure --no-tests=error`.
  Sanitizer configurations: `build/native-ui-encoding-asan` and
  `build/native-ui-encoding-tsan`. ASan uses `GTest_DIR` under
  `build/native-ui-encoding-deps/asan-install/lib/cmake/GTest`; its source was read
  from the existing adjacent flycast checkout, without editing it. Logs:
  `/tmp/tidyvnc-encoding-{focused-tests,adapter-tests,headless-tests,fltk-tests,tsan-tests,asan-clean-tests,clean-headless}.log`.
- Same macOS 27 arm64 / AppleClang 21 CLT / SDK 27 configuration; explicit
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. Sanitizers disable TLS and
  H.264; full suites enable TLS/nettle. External libraries are not all instrumented.
  No Linux/Windows, H.264-enabled, minimum-OS, native UI, display-hardware or
  performance result is claimed. General settings, document transactions, the
  wider capabilities/error/command catalog, scheduling and platform services remain
  unchecked. The full native UI objective remains active.

### N1.6 — session-owned monotonic timers and protocol integration — 2026-09-18

- IDs / commit: N1.6 timer portion and timer-ownership prerequisite of N1.4;
  current working tree, not committed. Production readiness/wakeup adapters,
  executor ownership and asynchronous IO/drain remain open; N1.6 is not complete.
- Added bounded `SessionScheduler`, using `steady_clock` deadlines, one-shot
  callbacks, deadline order with FIFO ties, and a finite dispatch budget. Capacity
  defaults to 64 and accepts 1–4096 queued callbacks; running work adds at most one.
  Caller-selected capture sizes and in-flight producer allocations are not a byte
  budget. Callback allocation/disposal, execution and host notification occur
  outside the mutex. Allocation failure cannot destroy captures under the lock.
- Copyable cancellation tokens weakly reference the owning scheduler, do not
  retain callbacks, and remain safe after shutdown/destruction. Cancellation is
  thread-safe and wins before dequeue; it never waits for a started callback.
  Cancel-all permits future work, shutdown rejects it, and IDs are never reused.
  Callback exceptions consume only that callback, reset dispatch state and
  propagate. Concurrent/reentrant dispatch is rejected. Host drain is still
  required before destroying the scheduler/callback target; shutdown is not a join.
- Injected `SchedulerWakeup` provides a nonblocking, noexcept, thread-safe host
  notification seam without exposing OS descriptors. The host must signal a
  coalescing level-triggered wakeup, recheck queue/deadline state, and serialize
  dispatch on its executor. No platform reactor implementation is implied.
- `ProtocolSession` owns two timer slots: statistics at 100 ms by default and
  backpressured publication retries at 16 ms. Additional frames update a pending
  statistics sample without postponing the deadline. An idle session has no
  periodic statistics work. Retry publishes only complete images, reschedules only
  while blocked, and is cancelled by successful natural/manual publication.
  Host `dispatchScheduled()` permits progress with no new network data.
- `SessionTiming` exposes validated 1–60000 ms intervals, an optional wakeup and a
  worker-only injectable monotonic clock. Callbacks carry attempt generation.
  Close/failure cancels both timers before protocol teardown; reconnect cannot
  execute old timers. Callback/publication failures unwind before failing and
  closing the attempt. Invalid zero-budget dispatch leaves the session active.
  Terminal events retain final counters even if a pending sample was cancelled.
- Ten scheduler tests cover ordering, bounds, token scope/lifetime, cancellation,
  shutdown, callbacks/capture destructors/wakeups outside locks, reentry, bounded
  self-rescheduling, exceptions, concurrent producers/cancellation and independent
  queues while a callback is blocked. Seven added protocol tests use fake time to
  verify throttling, retry without IO, incomplete-update safety, natural retry
  cancellation, close/reconnect, independent sessions and callback failure cleanup.
  The prior coalesced-statistics test now explicitly dispatches its deadline.
- Clean headless Debug configure with GUI discovery disabled: dependency audit,
  **461/461** unit tests (15.02 seconds) and **1/1** smoke passed. Retained FLTK
  RelWithDebInfo: build, **477/477** unit tests (16.15 seconds), **1/1** smoke
  (0.15 seconds). Focused scheduler/session tests: **34/34** ASan/UBSan
  (0.90 seconds), **34/34** ThreadSanitizer (1.80 seconds).
  `git diff --check` and branding/attribution audit passed. Full suites used
  authorized test-only loopback access for the existing authentication fixtures.
- Reproduce headless with the README command and a fresh build directory (local:
  `build/native-ui-scheduler`). Retained build: `build/hidpi`. Focused sanitizers:
  build `sessionscheduler protocolsession` in `build/native-ui-encoding-asan` or
  `build/native-ui-encoding-tsan`, then unit CTest with
  `-R '^(SessionScheduler|ProtocolSession)\.' --output-on-failure --no-tests=error`.
  ASan uses the previously built matching instrumented GoogleTest dependency.
  Logs: `/tmp/tidyvnc-scheduler-{headless,fltk-build,fltk-tests,fltk-smoke,asan-build,asan-tests,tsan-build,tsan-tests}.log`.
- macOS 27 arm64 / AppleClang 21 CLT / SDK 27; explicit
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. Focused sanitizer builds
  disable TLS; full regression builds enable TLS/nettle. External libraries are
  not all instrumented. No native UI, Windows/Linux runtime, production socket
  reactor, IO cancellation, physical-display, minimum-OS or performance claim.
  Legacy `core::Timer`/FLTK scheduling remains for retained consumers. Native input
  emulation timers and other service timers still need adoption of scoped scheduling.

### N1.6 — owned established-socket readiness and cancellation — 2026-09-18

- IDs / commit: established transport portion of N1.6, plus socket initialization
  race prerequisite for N1.4; current working tree, not committed. N1.6 stays open
  for DNS/connect/listen readiness; production lifecycle/drain stays N1.5/N1.13.
- Added portable `SessionTransport`/`TransportControl` contracts with no native
  descriptors, worker-owned streams/flush, explicit writable interest, absolute
  monotonic deadlines, wake/cancel flags and an independent peer-closure wait.
  The scheduler wakeup contract moved to the platform seam; existing scheduler
  callers remain source-compatible through its header include.
- macOS/Linux `adoptSocketTransport()` owns established TCP/Unix stream sockets,
  including failure paths. It validates type/connection, sets nonblocking/CLOEXEC,
  and rejects descriptors outside FD_SETSIZE because legacy streams use select.
  System errors retain native codes and operation labels without endpoint text.
  Readable and peer-closed may coexist; no final buffered bytes are consumed by
  the observer. IO readiness is advisory; FdStreams now retry would-block.
- Bounded nonblocking pipes preserve wake-before-wait, tolerate saturated
  notifications and bound each drain. Worker and peer waits have independent
  cancellation channels. Weak retained controls use raw shutdown without touching
  stream state, survive destruction and cannot affect reused descriptors; an
  in-flight call holds socket/pipe resources until it returns. No UI thread join,
  second protocol reader, detached thread or process-global timer is introduced.
- Peer FIN observation uses persistent kqueue EV_CLEAR/EV_EOF on macOS and
  POLLRDHUP without POLLIN on Linux, ignoring unchanged unread data. Cancellation
  is sticky and wakes both waits. Hosts must separately cancel the authentication
  bridge and drain both callers/protocol work before transport destruction.
  Existing socket initialization is now guarded by `std::call_once`, preserving
  legacy SIGPIPE/Winsock behavior and retry after a thrown initialization failure.
- Replaced the authentication fixture's client polling and test-only FIN watcher
  with this adapter. Sixteen independent-loopback VNC/VeNCrypt TLS tests prove
  password verification, trust/cancel/timeout/peer closure, reconnect/stale replies
  and another session progressing while a prompt is parked. The host controller
  and the peer server's polling loop remain test-only; this is not native UI proof.
- Thirteen new transport tests exercise ownership/flags/byte exchange, deadlines,
  explicit writable interest and actual backpressure, bounded flooded wakeups,
  scheduler integration, FIN behind unread data, dual-waiter cancellation,
  concurrent control/destruction, actual descriptor reuse, failed adoption,
  descriptor-range rejection and concurrent independent socket initialization.
  Focused initial transport/authentication run: **29/29** (1.13 seconds).
- Fresh headless Debug (`build/native-ui-transport`) configured with GUI discovery
  disabled, passed the dependency audit, **474/474** unit tests (14.88 seconds)
  and **1/1** smoke. Retained FLTK RelWithDebInfo (`build/hidpi`) built and passed
  **490/490** unit tests (16.47 seconds), **1/1** smoke (0.06 seconds).
  Focused transport/scheduler/session: **47/47** ASan/UBSan (0.82 seconds),
  **47/47** ThreadSanitizer (1.46 seconds). No failed or skipped transport cases.
  `git diff --check` and branding/attribution audit passed.
- Reproduce fresh headless with the README command, Debug, Homebrew dependencies
  and GnuTLS/nettle enabled. Sanitizers: build `sessiontransport sessionscheduler
  protocolsession` in `build/native-ui-encoding-asan` or
  `build/native-ui-encoding-tsan`, then unit CTest with
  `-R '^(SessionTransport|SessionScheduler|ProtocolSession)\.' --output-on-failure --no-tests=error`.
  ASan uses the matching instrumented GoogleTest built for the encoding step.
  Test-only loopback/socket access was authorized for all relevant runs.
- macOS 27 arm64, AppleClang 21 CLT/SDK 27, explicit
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. Focused sanitizers disable
  TLS; full regression builds enable it. External libraries are not all
  instrumented. Logs: `/tmp/tidyvnc-transport-{headless,focused-build,focused-tests,fltk-build,fltk-tests,fltk-smoke,asan-build,asan-tests,tsan-build,tsan-tests}.log`.
  No Windows backend, Linux runtime, native window, minimum-OS or performance
  claim. Retained FLTK still owns its existing event loop. Whole-transport memory
  budgets and production asynchronous host/drain remain unchecked.

### N1.5/N1.13 — production established-attempt workers and joined drain — 2026-09-18

- IDs / commit: established-attempt worker/drain portion of N1.5/N1.13; current
  working tree, not committed. The full logical-session/listener/command/service
  lifecycle remains open and no N2 native application gate is claimed.
- Added `SessionRuntime` with 1–64 admitted attempts (default 16), one join
  coordinator and no detached threads. `start()` transfers an established
  transport, explicit immutable security/options, and prepares synchronized
  event/view/input/authentication mailboxes before worker publication. Admission
  rejection owns transport disposal; allocation/thread-start failures propagate.
- Each worker serializes input, due timers, up to 64 protocol steps per turn,
  output flush and monotonic readiness waits. It does not wait while buffered
  protocol work remains. An independent peer observer directly cancels a parked
  prompt, and another session continues independently. The real VNC/TLS peer
  fixtures now have four cases through the production runtime, in addition to
  the original sixteen protocol/host-boundary cases.
- Handle release/close cancels the prompt and wakes the worker without joining.
  Cancellation is checked after authentication attempt reset to close the
  startup race. Cleanup attempts held-key/TLS release while the socket is live,
  drains protocol/decoder work, cancels timers, clears views and seals events,
  attempts a final nonblocking flush, then shuts down IO, joins the observer and
  destroys the transport. The coordinator joins the worker before completing
  its shared drain future. Repeated close shares the same completion.
- Worker results distinguish cancellation, FIN, timeout, authentication rejection
  and transport/protocol/resource/internal failure with optional native code;
  server-controlled exception text is not exposed. `ProtocolSession::close(bool
  failed = false)` now supports host-detected readiness failures. Existing
  protocol event states remain narrower than the final lifecycle: prompt
  interruptions still emit protocol Failed while the worker result gives the
  precise cancellation/timeout/FIN reason. State unification remains N1.5.
- Runtime shutdown snapshots/cancels outside its mutex, rejects future admission
  and resolves after joined jobs. The runtime destructor joins its coordinator
  and must run on an application service/shutdown thread; only session-handle
  destruction is a nonblocking UI cleanup path. Native app ownership is not yet
  wired. Final writes are best effort under backpressure, not remote delivery.
- Twelve fake-transport tests cover automatic protocol/input/timer progression,
  retained frames and input release, delayed observer exit versus nonblocking
  handle release, 100 immediate startup cancellations, idempotent close,
  admission bounds, concurrent admission/shutdown, service-thread destruction,
  parked prompts, timeout/FIN, independent sessions, structured IO/protocol
  failures and partial construction cleanup. Four new real-loopback VNC/TLS
  cases verify password authentication, FIN during prompts and joined drain.
- Initial fixture compilation required the standard writable cast for the
  BufferedInStream backing buffer. The first focused run exposed a test wire
  byte-order error (writeU32 uses network order); explicit pixel bytes fixed it.
  Final focused run before the added concurrent-admission case: **31/31**
  (1.42 seconds); that added case passed in all final full/sanitizer suites.
- Fresh headless Debug (`build/native-ui-worker`) with GUI discovery disabled:
  dependency audit, **490/490** unit tests (15.55 seconds), **1/1** smoke passed.
  Retained FLTK RelWithDebInfo (`build/hidpi`): build, **506/506** unit tests
  (17.04 seconds), **1/1** smoke (0.12 seconds). Focused worker/protocol suites:
  **36/36** ASan/UBSan (0.80 seconds), **36/36** ThreadSanitizer (1.26 seconds).
  `git diff --check` and branding/attribution audit passed.
- Reproduce fresh headless with the README command, Debug/Homebrew/GnuTLS/nettle.
  Sanitizers: build `sessionworker protocolsession` in
  `build/native-ui-encoding-asan` or `build/native-ui-encoding-tsan`, then unit
  CTest with `-R '^(SessionWorker|ProtocolSession)\.' --output-on-failure --no-tests=error`.
  ASan uses the matching instrumented GoogleTest from the encoding step.
  Full suites had authorized local-socket access; focused fake transports need
  no networking. macOS 27 arm64 / AppleClang 21 CLT / SDK 27; explicit
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools` throughout. Focused
  sanitizers disable TLS; full suites enable it. Not all dependencies are
  instrumented. Logs: `/tmp/tidyvnc-worker-{headless,focused-build,focused-tests,fltk-build,fltk-tests,fltk-smoke,asan-build,asan-tests,tsan-build,tsan-tests}.log`.
- No DNS/connect/listen, reusable logical-session generation/command catalog,
  native notifications/views, service-request cancellation, C/Swift bridge,
  app-level runtime destruction, Linux/Windows execution or performance claim.
  A reconnect currently creates a new worker/bridge identity; request IDs must
  stay paired with the original handle. The full plan remains active.

### N1.5 — consistent terminal states and asynchronous commands — 2026-09-18

- IDs / commit: established-attempt state/refresh/encoding command portion of
  N1.5; current working tree, not committed. Logical session reuse, connect/listen
  lifecycle and remaining command/service operations stay unchecked.
- `SessionWorker` owns final lifecycle publication and sealing. The new
  `SessionTerminalOwnership::Host` mode preserves immediate protocol cleanup on
  exceptions while deferring terminal events and unexecuted-operation settlement
  to the host. Standalone ProtocolSession uses Protocol ownership by default,
  retaining its existing close/reconnect behavior. Worker-only snapshot access
  preserves final counters even when statistics delivery was still pending.
- Added Authenticating before trust/credential callbacks and Disconnecting
  before worker disposal. Every admitted worker, including cancellation before
  startup, emits one Closed/Failed terminal event after transport disposal, or
  the existing single Overflow terminal record. Cancellation/FIN end Closed;
  timeout/rejection/other failures end Failed. Shared `SessionEndReason` and native
  code in terminal snapshots agree with the drain result. A late close no longer
  rewrites a finalized failure; terminal event overflow remains EventOverflow.
- Added thread-safe refresh/encoding admission and cancellation with typed
  rejection: Closing, NotConnected, StaleGeneration, QueueFull, EventCapacity.
  Rejection returns operation zero and does not mutate policy or owe completion.
  The 1–256 command capacity (default 32) is independent of input and event
  budgets. All slots are preallocated; a completion reservation precedes enqueue.
  A static assertion requires nonthrowing command copies/assignments, preventing
  allocation failure between reservation and admission. Policies/provenance are
  copied values, independent of caller lifetime and other sessions.
- The worker executes bounded FIFO batches outside the command mutex, passing
  the existing reserved ID to protocol operations. Nonzero external reservations
  are validated by ID/generation and leave completion to their host owner;
  existing zero-argument synchronous reservation/completion is preserved. The
  worker updates its synchronized encoding snapshot before publishing success.
  Success means safe-boundary scheduling, not server acknowledgment/frame arrival.
- Cancellation wins before dequeue; started/completed/unknown IDs are NotPending
  and no unbounded result history is retained. Close stops admission and cancels
  queued work directly, including while the worker is busy. Started work finishes;
  failure settles remaining queued work. Reserved completions survive event
  overflow. Completion order follows execution/cancellation time rather than
  requiring an earlier started command to finish before a later queued cancellation.
- Seven new worker cases verify state/generation rejection, command/event bounds,
  no mutation on rejection/cancellation, FIFO copied policies and visibility before
  completion, close cancellation, terminal overflow and concurrent admission/
  cancellation/consumption. Two protocol cases verify reserved-token validation,
  completion ownership and deferred terminal publication after resource cleanup.
  Existing worker cases now check exact terminal counts, authenticating state,
  cancellation/timeout/FIN reasons, native errors and late-close immutability.
  Two additional real-loopback VNC/TLS cases verify password rejection becomes
  one Failed attempt with AuthenticationRejected reason.
- The first build exposed C++11 aggregate initialization rules for the public
  submission value; an explicit constructor resolved it. Final focused core/
  worker/events/encoding/authentication tests: **83/83** (2.37 seconds).
  Clean headless Debug (`build/native-ui-lifecycle`), GUI discovery disabled:
  dependency audit, **501/501** unit tests (15.80 seconds), **1/1** smoke passed.
  Retained FLTK RelWithDebInfo (`build/hidpi`) built and passed **517/517** unit
  tests (19.13 seconds), **1/1** smoke (0.06 seconds). Focused non-TLS suites:
  **61/61** ASan/UBSan (1.85 seconds), **61/61** ThreadSanitizer (3.31 seconds).
  `git diff --check` and branding/attribution audit passed.
- Reproduce clean headless with README's command, Debug/Homebrew/GnuTLS/nettle.
  Sanitizers: build `sessionworker protocolsession sessionevents sessionencoding`
  in `build/native-ui-encoding-asan` or `build/native-ui-encoding-tsan`, then unit
  CTest with `-R '^(SessionWorker|ProtocolSession|SessionEvents|SessionEncoding)\.'
  --output-on-failure --no-tests=error`. ASan uses matching instrumented GoogleTest.
  Full suites used authorized local sockets. macOS 27 arm64 / AppleClang 21 CLT /
  SDK 27, explicit `DEVELOPER_DIR=/Library/Developer/CommandLineTools`; not all
  dependencies are instrumented. Logs:
  `/tmp/tidyvnc-lifecycle-{build,focused-tests,headless,fltk-build,fltk-tests,fltk-smoke,asan-build,asan-tests,tsan-build,tsan-tests}.log`.
- No DNS/connect/listener lifecycle, reusable logical-session generation, desktop
  layout/clipboard command catalog, full SessionError domain/retry policy, native
  notification delivery, C/Swift bridge or app-level service ownership claim.
  No Linux/Windows execution, minimum-OS, hardware/UI or performance result.
  Worker/stream identity still scopes operation and prompt IDs across new attempts.

### N1.6 / N1.5 — cancellable endpoint connection setup — 2026-09-18

- IDs / commit: endpoint connection portion of N1.6 and worker setup states/drain
  in N1.5/N1.13; current working tree, not committed. Parent items remain open.
- Added descriptor-free, prepared `ConnectionAttempt` and explicit
  `SocketConnectOptions`. Construction performs no DNS/connect; runtime admission
  returns mailboxes while setup runs on the protocol worker. Resolving/Connecting
  precede RFB negotiation. Typed resolver/connect failures, stage timeouts,
  unsupported routes/platform capabilities and invalid addresses retain native
  numeric codes without raw input-bearing exception text.
- macOS DNS-SD uses asynchronous family queries, socket readiness and scoped
  deallocation; no resolver thread is detached. Retains at most 16 addresses,
  split 8/8 for dual family, then tries them sequentially with total and
  per-address monotonic deadlines. One slow family does not discard the other's
  available addresses. Default lookup/connect/address budgets: 10s/10s/2s;
  validated range 1–60000ms each. This is not Happy Eyeballs.
- Numeric IPv4/IPv6, checked scope indices/interface names and Unix sockets use
  macOS/Linux POSIX source. Explicit family policy avoids global reads. Linux
  hostname lookup and nonempty tunnel routes reject as Unsupported. Sockets use
  nonblocking/CLOEXEC and transfer ownership once to the established adapter.
  Shared private descriptor/wakeup helpers preserve public handle-free contracts.
  `network::Socket::setFd` stages stream allocations to avoid leaking the first
  allocation if the second fails.
- A stable synchronized worker control preserves cancellation through the
  setup-to-connected transition, including a backend returning a socket after
  close. Setup cancellation directly wakes readiness; connected close preserves
  held-input/TLS cleanup. No virtual callback/disposal runs under the control
  mutex. Setup resources are gone before joined drain completion.
- Added 13 socket-connector tests and five worker cases: IPv4/IPv6/Unix,
  localhost system DNS, validation/rejection, stale controls, real pending-connect
  deadline/cancellation, endpoint-to-RFB handshake, worker-owned setup, ordered
  phases, fake slow resolution/connect, close at handoff, typed errors and mixed
  runtime shutdown. The initial refused-port fixture kept a non-listening bound
  socket open; macOS drops SYNs in that case, correctly reaching a timeout. The
  fixture now closes that socket for refusal and tests the pending behavior
  separately. Initial CMake lookup for a separate dns_sd library was corrected
  to a symbol check: this SDK exports DNS-SD through libSystem.
- Clean `build/native-ui-connect` configure/build and dependency audit passed:
  **519/519** unit tests (15.69s), **1/1** headless smoke. Retained
  `build/hidpi` FLTK rebuild passed: **535/535** unit tests (17.22s), **1/1**
  smoke (0.12s). Focused connector/worker/transport: **50/50** normal (0.88s),
  **50/50** ASan/UBSan (1.19s), **50/50** TSan (1.81s).
  Branding/attribution audit and `git diff --check` passed.
- Reproduce clean build with `tests/viewer/headless.py --build-dir
  build/native-ui-connect --cmake-arg=-GNinja --cmake-arg=-DCMAKE_BUILD_TYPE=Debug
  --cmake-arg=-DCMAKE_PREFIX_PATH=/opt/homebrew --cmake-arg=-DENABLE_GNUTLS=ON
  --cmake-arg=-DENABLE_NETTLE=ON` (use a new directory). Sanitizers: build
  `socketconnector sessionworker sessiontransport` in the existing
  `build/native-ui-encoding-asan` / `build/native-ui-encoding-tsan` configurations,
  then CTest under `tests/unit` with
  `-R '^(SocketConnector|SessionWorker|SessionTransport)\.' --output-on-failure
  --no-tests=error`. ASan uses matching instrumented GoogleTest; dependencies
  are not all instrumented. Runs require authorized local socket/DNS access.
- Host: macOS 27 arm64, AppleClang 21 CLT, SDK 27;
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. Logs (ephemeral):
  `/tmp/tidyvnc-connect-headless.log`, `/tmp/tidyvnc-connect-fltk-{build,tests,smoke}.log`,
  `/tmp/tidyvnc-connect-{focused,asan,tsan}-build.log`, and
  `/tmp/tidyvnc-connect-{native-ui-lifecycle,native-ui-encoding-asan,native-ui-encoding-tsan}-tests.log`.
- No stalled real DNS-daemon, Linux/Windows execution, minimum-macOS, performance,
  native UI/notification, listener/tunnel service or reusable logical-session
  claim. Deadlines bound readiness waits, not arbitrary local DNS-service IPC or
  OS scheduling. TLS verification receives the canonical host without IPv6
  scope; credential-store identity remains a separate concern. The attempt drain
  future reports termination; no separate connect-operation completion token is
  introduced. Reconnect still creates a new worker/bridge/mailbox identity.

### N1.5 / N1.13 — reusable session worker and reconnect operations — 2026-09-18

- IDs / commit: reusable logical-session ownership, connect/disconnect lifecycle
  and completion portion of N1.5/N1.13; current working tree, not committed.
  Listener lifecycle, remaining commands and app/service ownership remain open.
- `SessionRuntime::createSession` admits an Idle logical-session handle with one
  persistent worker. Runtime capacity counts idle and active handles alike. The
  worker sleeps between attempts; no polling/reconnect helper thread is added.
  Existing runtime `start`/`connect` keep their one-attempt behavior.
- Session-level `connect(preparedAttempt)` owns admission, reserves one completion,
  returns the next generation and rejects Busy rather than implicitly queueing a
  retry. Generations advance even for DNS failure and pre-start cancellation.
  RFB Connected completes connect successfully; setup/auth failure or cancellation
  completes it after cleanup. Cancelling a pending connect interrupts setup/prompts
  directly. IDs never wrap and no operation history grows without bound.
- `disconnect(generation)` reserves a completion before cancelling commands and
  IO/prompts. It works immediately after connect admission, even before setup
  state publication. Its completion follows transport/observer/decoder/timer
  cleanup, while leaving the serialized session executor available for reconnect.
  Permanent close/destruction/shutdown stops admission and joins that executor.
  The drain future stays pending between attempts and reports the final attempt's
  termination result, or Cancelled for a session never connected.
- Stable protocol owner, event stream, input/view mailboxes, frame publication
  budget, prompt request IDs and encoding/input policy survive reconnect. Pending
  input/held state and timers do not. Retained old frame leases remain valid and
  consume the same budget. Session security policy remains fixed; editing it on
  reconnect is not yet implemented.
- Terminal publication and retry admission share one gate, with all reserved
  completions settled before another generation advances. Closed/Failed terminate
  an attempt without sealing its event stream; overflow terminates the whole
  logical session. `SessionEvents::reserveAttempt` reserves future-generation
  completion capacity without publishing state from an admission thread. Other
  operations may join that prepared generation, but pending generations cannot mix.
- Cancellation captures an attempt-specific control; generation-scoped prompt
  cancellation prevents a delayed old request from cancelling a later prompt.
  Scheduler wakes use a stable router, with control calls and disposal outside
  locks. All attempts run on the same serialized executor. Command admission and
  cancellation check the admitted generation even before the worker publishes it.
- Added twelve worker tests: stable executor/mailboxes/settings and retained frame
  bytes/budget, prompt IDs and stale replies/cancellation, failed setup retry,
  pre-start and resolving connect cancellation, immediate disconnect, delayed
  observer drain, terminal-triggered retry, concurrent connect admission, overflow,
  idle capacity/close and mixed shutdown. Added one event reservation test and two
  real TCP integration cases (plain VNC and X509Vnc/TLS 1.2), each verifying password
  authentication on two successive sockets through the same logical session.
- Failures resolved: a test initially named an encoding getter incorrectly; fixed
  to the existing `autoSelect()` API. The full regression run then exposed a real
  status bug: cancelling an already-committed disconnect before setup publication
  returned StaleGeneration. Checks now use the admitted generation and consistently
  return NotPending; the repeated immediate-disconnect test verifies this boundary.
- Final validation: clean headless configure/build/dependency audit, followed by
  the final rebuild: **534/534** unit tests (16.58s), **1/1** smoke (0.12s).
  Retained FLTK: **550/550** unit tests (18.09s), **1/1** smoke (0.12s).
  Focused suites: **86/86** ASan/UBSan (2.34s), **86/86** TSan (3.38s).
  All builds succeeded; `git diff --check` and branding/attribution audit passed.
- Reproduce clean configuration/dependency audit with `tests/viewer/headless.py`
  using a new directory, Ninja, Debug, `/opt/homebrew`, GnuTLS/nettle enabled and
  GUI targets disabled as in README. This run used `build/native-ui-reconnect`,
  then rebuilt final changes and reran the full suite. Retained FLTK uses
  `build/hidpi`. Sanitizers build `sessionworker sessionevents protocolsession
  promptauthentication` in the existing `build/native-ui-encoding-asan` and
  `build/native-ui-encoding-tsan` configurations, then CTest under `tests/unit` with
  `-R '^(SessionWorker|SessionEvents|ProtocolSession|PromptAuthentication)\.'
  --output-on-failure --no-tests=error`.
- Host: macOS 27 arm64 / AppleClang 21 CLT / SDK 27;
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. Real socket suites used
  authorized loopback access; sanitizer suites use fake transports and matching
  ASan GoogleTest. Not all dependencies are instrumented; TLS reconnect evidence
  is from the normal build. Ephemeral logs:
  `/tmp/tidyvnc-reuse-headless.log`, `/tmp/tidyvnc-reuse-integration-tests.log`,
  `/tmp/tidyvnc-reuse-{native-ui-reconnect,hidpi,native-ui-encoding-asan,native-ui-encoding-tsan}-final-{build,tests}.log`,
  `/tmp/tidyvnc-reuse-{native-ui-reconnect,hidpi}-smoke.log`.
- No native UI/C ABI, listener, service-request cancellation, credential caching,
  automatic retry/backoff, reconnect security-policy editing, minimum-OS,
  Linux/Windows execution, hardware or performance claim. Logical identity is
  currently the retained C++ handle; explicit ABI IDs remain N2 work.

### N1.5 / N1.2 — remote desktop layout command and server completion — 2026-09-18

- IDs / commit: remote desktop command/catalog and typed geometry/capability
  portion of N1.5/N1.2; current working tree, not committed. Parent items remain
  open for listener, clipboard, other services/settings and native integration.
- Added immutable `RemoteDesktopLayout`/`RemoteScreen`: remote pixel dimensions
  1–65535, 1–255 nonempty enclosed screens, unique IDs, overflow-safe validation,
  preserved flags/IDs and existing ScreenSet overlap/gap semantics. Snapshot
  layout values retain actual server topology independently of later changes.
  `supportsDesktopResize` and `resizePending` are explicit per-attempt state.
- `SessionWorker::requestDesktopLayout(generation, layout, origin)` copies the
  bounded value before admission, reserves completion capacity and uses the
  existing command queue. It rejects view-only, unsupported capability, stale or
  inactive attempts, occupied resize slot and framebuffer/storage budget excess.
  Core rechecks those constraints before writing SetDesktopSize. Queued requests
  can be cancelled; started requests cannot be retracted. One queued/on-wire
  resize prevents ambiguous reply matching. Queue copies remain nonthrowing;
  caller-defined shared-pointer deleters cannot enter the owned command payload.
- Server/other-client changes update topology without settling our request. A
  client-reason ExtendedDesktopSize response updates actual layout before
  completion. Success is a server reply, not merely a buffered write. Rejection
  keeps actual geometry and reports ServerRejected plus the native result code;
  unknown server result codes are preserved. Host `origin` is echoed in all
  reserved completions and is never sent over RFB.
- Added a third bounded per-session timer slot. Resize timeout defaults to 10s,
  validated 1–60000ms; timeout completes Failed/TimedOut but keeps the wire slot
  occupied. RFB has no request ID, so a later client reply clears that slot without
  double-completing or being matched to a newer request. A server that never
  replies requires reconnect for another resize. Close cancels deadline/pending
  completion and clears capability/topology/pending state; retained layouts and
  pixel leases remain safe. A topology-only change is observable at equal size.
- Added eleven geometry/protocol cases and three worker cases: input ownership,
  overflow/bounds/IDs/count/flags, exact wire bytes, server result/native code,
  topology-only changes, other-client changes, timeout/late response, capability,
  view-only before and after queue admission, framebuffer budget, invalid reserved
  IDs, queue cancellation, completion-capacity rejection, write failure and
  deadline/close/reconnect cleanup. Worker fixtures now accept synchronized incoming
  response bytes to test the actual executor/reader/completion path.
- Initial compile failures exposed a missing ScreenSet definition include and an
  omitted initializer for the new command payload under `-Werror`; both fixed.
  All test runs then passed. Clean `build/native-ui-layout` configure/build,
  dependency audit and tests: **548/548** unit (16.79s), **1/1** smoke (0.07s).
  Retained FLTK `build/hidpi`: **564/564** unit (18.61s), **1/1** smoke (0.07s).
  Focused normal: **86/86** (1.80s); ASan/UBSan: **86/86** (2.44s); TSan:
  **86/86** (3.45s). Branding/attribution audit and `git diff --check` passed.
- Reproduce clean headless with README's driver using a new directory, Debug,
  Ninja, `/opt/homebrew`, GnuTLS/nettle enabled. Focused targets:
  `remotedesktoplayout sessionworker sessionevents protocolsession`; unit CTest
  `-R '^(RemoteDesktopLayout|SessionWorker|SessionEvents|ProtocolSession)\.'
  --output-on-failure --no-tests=error`. Sanitizer directories remain
  `build/native-ui-encoding-asan` / `build/native-ui-encoding-tsan`; ASan uses
  matching instrumented GoogleTest. Dependencies are not all instrumented.
- Host: macOS 27 arm64, AppleClang 21 CLT / SDK 27,
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. Full suites used authorized
  local sockets; focused layout tests use fixture streams/transports. Ephemeral
  logs: `/tmp/tidyvnc-layout-headless.log`, `/tmp/tidyvnc-layout-fltk-smoke.log`,
  `/tmp/tidyvnc-layout-{native-ui-reconnect,native-ui-encoding-asan,native-ui-encoding-tsan,hidpi}-{build,tests}.log`.
- No native resize/coalescing/rate-limit policy, local display/window mapping,
  feedback-loop prevention UI, physical topology, real server resize acceptance,
  performance, minimum OS, Linux/Windows runtime, C ABI or clipboard claim. The
  retained FLTK resize policy is unchanged and remains the parity reference.

### N1.5 / N1.9 — bounded session clipboard channel — 2026-09-18

- IDs / commit: clipboard commands and protocol/service boundary portion of
  N1.5/N1.9; current working tree, not committed. Native pasteboard integration,
  active-session arbitration and N3.15 remain open.
- Added thread-safe ClipboardChannel, immutable noncopyable text leases, a single
  coalesced receive update and independently mutable send/receive policy. Queued
  commands, cached local offers and externally retained text share a normalized
  UTF-8 payload budget across reconnect. Defaults: 256 KiB per text, 1 MiB total;
  validated maxima: 16 MiB per text, 64 MiB total. Metadata, capacity and protocol
  conversion/decompression buffers are separate from this payload accounting.
- Local text is owned before admission, validated for UTF-8/no embedded NUL and
  normalized to LF. RFB retains extended UTF-8/CRLF/NUL negotiation and legacy
  Latin-1 fallback. Incoming parser limits remain independent. Eligible remote
  announcements request text automatically; no file/image clipboard format added.
- Worker offer/withdraw commands share bounded command admission, reserved
  completions and queue cancellation. One clipboard command slot is cleared
  before completion publication so immediate follow-up is admissible. Completion
  means protocol announcement/send, without claiming a remote OS write; host
  change IDs return in completion origin. Policy setters update the mailbox and
  wake cleanup directly, without an operation completion.
- Connection generation plus focus/view-only and policy revisions reject stale
  queued text, including a focus/policy round trip before execution. Cached local
  text is revoked on worker wake or before answering a request. Native consumers
  must recheck the route immediately before an OS write on their focus executor.
  Remote-origin leases suppress echoes across reconnect and sessions; foreign
  local leases are rejected. RFB lacks clipboard request IDs, so latest-request
  routing does not claim exact correlation of overlapping remote announcements.
- Retained text remains valid after close and keeps charging the shared budget.
  Backpressure drops/rejects new text without disconnecting the session. Mutable
  policy persists across attempts; queued updates and local caches are invalidated.
  Scoped reader format buffers now free on malformed later-format decoding or
  a throwing delivery callback, fixing an existing exception-path leak.
- Added eleven channel/protocol tests, five worker tests and two reader exception
  tests. Coverage includes legacy/extended wire bytes, newline/UTF-8 validation,
  coalescing, payload pressure/recovery, direction policy, view-only/focus gating,
  stale and foreign leases, echo origins, reconnect/close lifetime, asynchronous
  completion/cancellation and concurrent prepare/receive/policy/consume operations.
- Failures resolved: the concurrent test initially used the worker accessor name
  on ProtocolSession; corrected to inputQueue(). A malformed compressed fixture
  throws the existing decompressor runtime_error rather than protocol_error;
  corrected that expectation. Final focused normal **89/89** (25.26s), ASan/UBSan
  **89/89** (38.58s) and TSan **89/89** (68.73s) passed. Runs overlapped builds;
  elapsed times are validation records, not performance measurements.
- Clean headless build/dependency audit in build/native-ui-clipboard passed:
  **566/566** unit tests (41.42s), **1/1** smoke. Retained FLTK build/hidpi passed:
  **582/582** unit tests (47.40s), **1/1** smoke. Full suites used authorized local
  loopback access. Branding/attribution audit (1650 deferred occurrences) and
  git diff --check passed. Clean headless reproduction uses README's driver with
  a new build directory, Ninja, Debug, /opt/homebrew and GnuTLS/nettle enabled.
- Ephemeral logs: /tmp/tidyvnc-clipboard-headless.log,
  /tmp/tidyvnc-clipboard-fltk-{build,tests,smoke}.log,
  /tmp/tidyvnc-clipboard-{normal,asan,tsan}-tests.log and
  /tmp/tidyvnc-clipboard-native-ui-encoding-{asan,tsan}-build.log (TSan's corrected
  final build uses the -final-build.log suffix).
- Focused targets: sessionclipboard sessionworker protocolsession clientclipboard;
  CTest under tests/unit with
  `-R '^(SessionClipboard|SessionWorker|ProtocolSession|ClientClipboard)\.'
  --output-on-failure --no-tests=error`. Normal directory: build/native-ui-layout;
  sanitizers: build/native-ui-encoding-asan and build/native-ui-encoding-tsan.
  ASan uses matching instrumented GoogleTest; not all dependencies are instrumented.
- Host: macOS 27 arm64 / AppleClang 21 CLT / SDK 27,
  DEVELOPER_DIR=/Library/Developer/CommandLineTools. Focused tests use protocol
  fixtures/fake transports. No native clipboard/UI, global focus arbiter, actual
  remote OS clipboard, physical hardware, minimum OS, Linux/Windows runtime,
  C ABI or performance claim.

### N1.5 / N1.6 / N1.13 — reverse listener lifecycle and peer handoff — 2026-09-19

- IDs / commit: separate listener runtime and TCP readiness/handoff portions of
  N1.5/N1.6/N1.13; current working tree, not committed. Native listen/CLI wiring,
  application quit coordination and other platform services remain open.
- Added prepared ListenerSource and concrete macOS/Linux SocketListener. Numeric
  IPv4/IPv6 or wildcard bind, port 5500 default, shared ephemeral port, V6ONLY,
  nonblocking/CLOEXEC descriptors and cancellable poll stay outside protocol/UI
  types. Scoped IPv6 bind addresses, DNS and Unix listeners are not implemented.
  Unavailable families retain legacy skip semantics; other bind failures roll
  back all descriptors and preserve native error codes. Actual bound addresses
  are reported as immutable snapshot values.
- ListenerRuntime owns 1–16 capacity (default 4), one worker per listener and a
  join coordinator. Listener handles have independent Starting/Listening/Stopping/
  Closed/Failed lifecycle, immutable retained peer/address snapshots and ordered
  events. Restart creates a new handle; monotonic IDs are scoped to that handle.
  Listener shutdown leaves previously accepted sessions alive.
- Pending incoming transports are bounded to 1–64 (default 8), with monotonic
  1–60000ms expiry (default 30s). Full capacity pauses acceptance until a decision
  or expiry. Kernel backlog is separately bounded to 1–64 (default 16). No RFB
  data is consumed before acceptance. Pending FIN waits for expiry or session
  acceptance rather than adding an observer per unclaimed connection.
- Explicit take/reject transfers or closes each peer once. accept convenience
  hands it to the existing SessionRuntime with explicit security/options. Stale,
  duplicate, expired and closing IDs cannot consume another connection. Runtime
  admission failure consumes/closes the claimed peer while leaving the listener
  usable. Numeric peer scope is omitted from the TLS certificate hostname.
- Event queues admit 4–4096 entries (default 32) plus two reserved terminal slots.
  Capacity is checked before host decisions transfer ownership; overflow fails
  the listener, closes unclaimed transports and preserves queued plus terminal
  events. Transport/control calls and consumer-output disposal happen outside
  locks. The output-disposal test verifies a caller deleter can reenter snapshot().
- closeAndDrain cancels readiness/start directly; worker disposal precedes joined
  completion. Handle release never joins. Runtime shutdown is nonblocking, with
  a separate all-workers drain future; runtime destruction joins on an app service
  thread. Admitted workers are covered, not callers still constructing requests.
- Added thirteen fake-source lifecycle tests and eight real socket tests:
  initial/current/retained state, ordered transitions, single ownership, duplicate
  rejection, timeout/full-queue recovery, incoming/decision event overflow, delayed
  disposal, capacity/shutdown, concurrent decisions, validation and reentrant
  output cleanup; IPv4/IPv6, shared port, cancellation/deadline/retained controls,
  single use, bind rollback, explicit reverse RFB/None acceptance, independent
  session lifetime and admission-failure socket cleanup.
- Failures resolved: compiler diagnostics caught a shadowed result name, fixture
  stream-pointer type, enum accessor and GoogleTest same-line labels/indentation.
  The first bind-conflict fixture used specific versus wildcard IPv6 addresses,
  which macOS permits to coexist with reuse; changed it to identical wildcard
  endpoints. Initial 20-test normal/ASan/UBSan/TSan runs passed. Final review added
  output-disposal coverage. Parallel final builds then hit CMake's five-second
  GoogleTest discovery timeout after printing test lists; sequential builds with
  reduced concurrency were used for final verification.
- Final validation after the output-disposal change: clean headless configuration,
  dependency audit and final rebuild passed; **587/587** unit tests (63.05s),
  **1/1** smoke. Retained FLTK final rebuild: **603/603** unit tests (25.15s),
  **1/1** smoke. Focused listener suites: **21/21** ASan/UBSan (1.03s) and
  **21/21** TSan (0.92s), including real socket fixtures. Branding/attribution
  audit (1650 deferred occurrences) and git diff --check passed. Discovery retries
  succeeded with one build job; a direct affected-binary discovery probe exited
  normally in 0.125s. Timing records are not performance measurements.
- Ephemeral logs: /tmp/tidyvnc-listener-headless.log,
  /tmp/tidyvnc-listener-{native-ui-listener,hidpi}-final-{build,tests,smoke}.log,
  /tmp/tidyvnc-listener-{hidpi,asan,tsan}-recovery-build.log and
  /tmp/tidyvnc-listener-{asan,tsan}-final-tests.log.
- Reproduce focused builds with targets listenerworker/socketlistener and unit
  CTest `-R '^(ListenerWorker|SocketListener)\.' --output-on-failure --no-tests=error`.
  Clean headless: README driver, new build/native-ui-listener directory, Ninja,
  Debug, /opt/homebrew, GnuTLS/nettle enabled. Retained FLTK: build/hidpi.
  ASan/UBSan and TSan: existing build/native-ui-encoding-{asan,tsan}; ASan uses
  matching instrumented GoogleTest. Dependencies are not all instrumented.
- Host: macOS 27 arm64 / AppleClang 21 CLT / SDK 27,
  DEVELOPER_DIR=/Library/Developer/CommandLineTools; real socket tests used
  authorized local network access. No native reverse/listen presentation, incoming-peer UI,
  reverse TLS UI, minimum OS, Linux/Windows execution,
  hardware or performance claim. Existing FLTK listen behavior is unchanged.

### N2.1 / N2.2 / N2.5 / N2.9 — initial C ABI and real consumers — 2026-09-19

- IDs / commit: initial C ABI surface, exception/ownership boundary, asynchronous
  disposal and portable C consumer portions of N2; current working tree, not
  committed. Callback delivery/contexts, Swift wrappers, native app/view and the
  remaining listener/settings/clipboard/layout exports remain open.
- Added tidyvnc_viewer_c, the C99-compatible tidyvnc.h header, TidyVNC module map
  and dedicated bridge documentation. Twenty-eight tidyvnc_ exports cover ABI/
  capabilities, option initialization, runtime/session ownership, connect/
  disconnect/refresh/cancel/close/drain, snapshots/events, retained frame/cursor
  images, input/focus/view-only and authentication prompts/replies.
- Explicit fixed-width status/state/end-reason/format values, size/version-tagged
  structs, bounded UTF-8 spans and reserved/required-feature validation keep C++/
  platform types private. Larger structs use only known prefixes. Unknown versions,
  mandatory flags, invalid spans/counts and unsupported security are rejected.
  All exceptions translate to fixed diagnostics, including allocation failures;
  input-bearing exception text is never exported. Async failures preserve end
  reason/native code. Outputs remain unchanged on failure/no-data/pending results.
- Opaque 64-bit handles are checked against a 4096-record typed registry with
  explicit retain/release and IDs that never wrap/reuse. Wrong-type and stale
  handles are distinct rejections. In-flight calls hold implementation references;
  final release initiates close. Image/prompt spans borrow from retained handles,
  and remain valid after session/runtime destruction. Handle/metadata reservation
  precedes protocol admission or mailbox consumption, including allocation failure.
- A bounded application service owns at most eight runtimes and one joined cleanup
  thread. Final release/shutdown never joins on the caller; drain becomes visible
  after the runtime/coordinator is disposed by that service. It sleeps when idle
  and checks closing futures at bounded 20ms intervals. Runtime/session capacities
  remain explicit; a closing runtime holds its slot until joined disposal.
- Security initialization snapshots compiled defaults/allow-lists without mutable
  legacy parameters. TLS policy spans are owned. Replies require session, request
  ID and attempt generation. Mutable username/password buffers (up to 4096 bytes)
  are wiped on every return, including rejection, as are bridge temporaries.
  Caller copies/runtime-wide zeroization and arbitrary invalid addresses cannot
  be guaranteed. No credential persistence or implicit trust acceptance is added.
- Pure C99 smoke checks negotiation, short/extended headers, unknown flags, null/
  oversized/NUL spans, typed/stale handles, output preservation, secret wiping,
  explicit close and 48 caller-thread allocation-failure positions. Test support
  overrides allocation only in that executable; no production injection API.
  Seven loopback/concurrency tests cover actual VNC/None authentication, owned
  endpoint data, frames/input/release barriers, reconnect, retained pixels after
  all parent handles die, prompt metadata, final runtime release while auth is
  parked, simultaneous session progress, concurrent references and capacity recovery.
- Validation: clean build/native-ui-abi configure/build and generated C/C++
  dependency audit passed; **594/594** unit tests (17.61s), **2/2** smoke consumers
  (0.35s). Retained FLTK build/hidpi: **610/610** unit tests (19.53s), **2/2** smoke.
  Focused normal **7/7** (0.23s), ASan/UBSan **7/7** (0.27s), TSan **7/7** (0.34s).
  Pure C allocation-failure consumer also passed ASan/UBSan (0.41s) and TSan
  (0.22s). All 28 declared exports match unmangled C symbols in the built archive.
  Branding/attribution audit (1650 deferred occurrences) and git diff --check passed.
- The controlled VNC fixture uses the independently established password response
  bytes for "password"; its submitted buffer was corrected to that value during
  fixture review before integration execution. No failing integration test remains.
- Reproduce focused targets viewerabi/viewer-c-abi-smoke, unit/viewer CTest with
  `-R '^ViewerABI\.' --output-on-failure --no-tests=error`. Sanitizers remain
  build/native-ui-encoding-{asan,tsan}, with matching instrumented ASan GoogleTest;
  dependencies are not all instrumented. New ABI test discovery has a 30s bound.
  Clean headless uses README's driver, a new directory, Ninja, Debug, /opt/homebrew,
  GnuTLS/nettle enabled. Public C headers contain no native/widget/OS handle types.
- Host: macOS 27 arm64 / AppleClang 21 CLT / SDK 27,
  DEVELOPER_DIR=/Library/Developer/CommandLineTools. Real sockets used authorized
  loopback access. Ephemeral logs: /tmp/tidyvnc-abi-headless.log,
  /tmp/tidyvnc-abi-fltk-{build,tests,smoke}.log,
  /tmp/tidyvnc-abi-native-ui-{listener,encoding-asan,encoding-tsan}-{final-build,tests,c-tests}.log.
- No Swift compilation/wrapper, native UI/main-thread responsiveness, callback
  subscription drain, C ABI reverse TLS presentation, Linux/Windows execution,
  minimum OS, hardware or performance claim. C polling is a working low-level
  interface; it does not replace the planned callback/native presentation contract.

### N2.3 — retained C callback subscriptions and context drain — 2026-09-19

- Added `tidyvnc_callbacks`, CALLBACKS capability and four checked C exports for
  subscribe, unsubscribe, drain polling and generation validation. One active or
  draining subscription per session; 512 fixed service slots, no unbounded task
  queue. Initial readiness may precede subscribe return and carries its own
  borrowed subscription ID. Mandatory retain/release/ready functions have explicit
  caller/dispatcher thread contracts and must return promptly without throwing.
- Event/view mailboxes now accept weak internal wake targets. They signal outside
  mailbox locks; worker prompt publication and the join coordinator signal the
  same target. Targets only wake the independent bridge dispatcher and never run
  user code or reenter the session. Readiness is one coalescing bit per subscription;
  round-robin dispatch prevents hot-session starvation. No frame/prompt polling,
  protocol-thread UI callback, detached task or per-update allocation was added.
- Context retention precedes publication. Unsubscribe/final subscription release
  prevents pending delivery and never waits for a started callback. Final session
  release also invalidates delivery without retaining protocol activity. A running
  callback can read mailboxes, retain/release handles and unsubscribe itself.
  Context release happens after its final return on the dispatcher; only then is
  drain ready and replacement registration allowed. Failed registration balances
  any successful retain on the caller. Foreign ready exceptions cancel/drain that
  subscription without killing the dispatcher; release exceptions are contained.
- Explicit session close/runtime shutdown preserve terminal and joined-drain
  readiness; protocol drain and callback drain are separate obligations. Retained
  images remain valid through both. Delivery validation observes a newly admitted
  connect immediately, closing the gap before the worker publishes new state.
  Consumed events/frames/prompts retain their own generation tags and the reserved
  exactly-once completion stream is not copied or reordered by notifications.
- Six added ABI tests exercise self-unsubscribe and reentrant mailbox access,
  queued/running cancellation, final handle release, BUSY replacement, immediate
  generation rejection, throwing callbacks, retained frames and real VNC/None
  peers. The callback-driven VNC test waits on notifications for authentication,
  server pixels, one connect completion and joined drain. The worker continues
  while a test callback is blocked. Two core tests cover weak readiness ownership
  and frame/cursor/reset/event/completion/seal signals. Pure C99 adds validation,
  self-unsubscribe/context drain and eight subscribe allocation-failure positions.
- A test initially retained the allocation-time cleared framebuffer. It now
  waits for actual server pixel content before close and lifetime verification.
  Initial CTest invocations at the build root/wrong test-name filter found no
  tests; corrected unit/viewer directory invocations ran the suites below.
- Validation: clean build/native-ui-callbacks configure/build and GUI-free
  dependency audit passed; **602/602** unit tests (17.97s), **2/2** smoke consumers.
  Retained FLTK build/hidpi: **618/618** unit tests (20.09s), **2/2** smoke (0.40s).
  Focused callbacks/mailboxes **34/34** normal (0.58s), final ASan/UBSan **34/34**
  (0.79s), final TSan **34/34** (1.21s). Pure C consumer passed both sanitizers
  (0.22s ASan/UBSan, 0.18s TSan). All **32** public declarations match unmangled
  C definitions. Branding/attribution audit (1650 deferred occurrences) and
  git diff --check passed. The full clean/FLTK runs include the final admission
  generation fix; the earlier focused normal run preceded that small fix.
- Reproduce focused builds with targets viewerabi, viewer-c-abi-smoke,
  sessionevents and framepublisher. Run CTest in tests/unit with
  `-R '^(ViewerABI|FramePublisher|SessionEvents)\.' --output-on-failure --no-tests=error`
  and tests/viewer with `-R PureCConsumer --output-on-failure --no-tests=error`.
  Sanitizers use build/native-ui-encoding-{asan,tsan} with matching instrumented
  ASan GoogleTest; not all dependencies are instrumented. Clean driver uses a
  new build directory, Ninja/Debug, /opt/homebrew, GnuTLS/nettle enabled.
- Host: macOS 27 arm64, AppleClang 21 CLT/SDK 27,
  DEVELOPER_DIR=/Library/Developer/CommandLineTools; authorized local loopback
  sockets. Ephemeral evidence: /tmp/tidyvnc-callback-headless.log,
  /tmp/tidyvnc-callback-fltk-{build,tests,smoke}.log,
  /tmp/tidyvnc-callback-{asan,tsan}-{build,tests,c-tests}.log.
- Native Swift/MainActor ownership and executor-queued delivery remain open.
  Host closures must own their captures and validate subscription identity and
  payload generation on delivery; C drain does not join work enqueued by the host.
  No native UI, main-thread responsiveness, Linux/Windows, minimum-OS or performance
  claim is made. N2.3 remains open for that native integration; N2.4 is the next
  owning-wrapper slice. Listener/clipboard/layout exports remain separate work.

### N2.3 / N2.4 / N2.5 — Swift ownership, MainActor delivery and async drain — 2026-09-19

- Added opt-in `TidyVNCNative` in `platform/macos/Bridge` and the independent
  `tests/macos` consumer. Swift 6 strict concurrency and warnings-as-errors check
  the module and tests. `NativeRuntime`/`NativeSession` are MainActor types with
  observable state, async connect/disconnect/refresh, typed admission/operation
  errors, input/focus/view-only and credential/trust replies. Runtime creation
  requires every C capability used by the wrapper. C++ remains behind the C module.
- Immutable, synchronized C handles and image leases have narrow documented
  unchecked-Sendable wrappers. Images expose owned metadata and an explicit Data
  copy, never a borrowed pointer; retaining an image does not copy pixels. Prompt
  identity/fingerprint/server metadata is copied before C handle release. Mutable
  password arrays are wiped on success and rejection, without claims about Swift
  aliases or other runtime copies. No credential/trust persistence is introduced.
- A retained delivery context weakly targets the model. Its locked scheduling
  gate coalesces callbacks into at most one queued MainActor task with its own
  subscription/context ownership. Delivery checks subscription identity, active
  state and attempt generation before updating UI state. Event processing uses a
  128-record budget and reschedules remaining work; views retain latest frames.
  Prompts and snapshots stay on MainActor. Delivery failure closes the model
  rather than leaving an admitted command continuation unresolved.
- Reserved native completions resolve checked Swift continuations by operation ID
  and generation. Pre-admission cancellation creates no native operation; later
  cancellation requests core cancellation and consumes its owed completion.
  Close invalidates delivery before suspension, clears presentation, resumes
  pending callers, cancels the worker and unsubscribes. One shared cleanup task
  awaits joined session, C context and queued host delivery drain, then installs
  the final snapshot. Cancelling the awaiting caller does not cancel cleanup.
  Runtime shutdown begins all session closes before awaiting them. Deinit only
  cancels/releases, with no worker join, semaphore or nested UI loop.
- Added a controlled C++ test peer and six Swift scenarios: actual None/VNC
  handshake and independent password response; wire key input; frame ownership
  across reconnect/shutdown; copied prompts and wiped/rejected credentials;
  cancellation while parked and independent session/MainActor heartbeat;
  cancelled close awaits, typed errors and rejected admission; 80 session cleanup
  cycles with weak-reference checks; 1,000 coalesced readiness signals, queued
  invalidation and stale-generation suppression. Published-value assertions
  execute on the main thread. One CTest executable runs all six scenarios and
  exits unsuccessfully if any assertion/operation fails.
- `BUILD_MACOS_NATIVE` defaults OFF and requires macOS, Swift 6+ and CMake 3.29+.
  Core/FLTK builds do not enable Swift; the clean headless driver explicitly
  disables the option. Native builds accept one architecture per directory and
  propagate an explicit deployment target to Swift as well as C++. All four
  bridge objects report macOS 14.0 in their Mach-O build-version records. Native
  executable linkage has Foundation/Combine and the core dependencies, no FLTK.
- Failures resolved during implementation: CMake's initial Swift probe attempted
  to write the inaccessible home module cache; configure/compiler modules now
  stay in the build tree. Strict Swift compilation caught unused results, weak
  local mutability diagnostics and a throwing short-circuit expression. A later
  imported-module rebuild hit Swift 6.4's missing temporary module path; explicit
  whole-module compilation via CMP0157 and a valid test module name fix this.
  Normal/ASan/TSan builds also passed a second imported-module rebuild. The test
  treats opaque pixel padding as unused rather than requiring alpha byte 255.
- Final native Debug results: **6/6 scenarios** in **1/1 CTest**, normal **0.48s**,
  ASan **0.54s**, TSan **2.57s**. Both Swift and C/C++ are instrumented in the
  sanitizer builds; SDK/frameworks and external dependency dylibs are not all
  instrumented. Sanitizer configurations disable GnuTLS/nettle; normal native
  configuration enables them. This is ASan, not a new Swift/UBSan claim.
- Portable regression: clean build/native-ui-swift-headless configure, dependency
  audit, **602/602** unit tests (**18.18s**) and **2/2** smoke (**0.37s**) passed.
  Retained FLTK build/hidpi: **618/618** unit tests (**20.78s**), **2/2** smoke
  (**0.27s**). Branding/attribution (1650 deferred occurrences) and diff whitespace
  checks passed. No source in the portable core/C ABI changed for this slice.
- Reproduction is in `platform/macos/README.md`. Native tests use
  `ctest --test-dir build/native-ui-swift/tests/macos --output-on-failure --no-tests=error`.
  ASan/TSan sibling directories add matching C/C++ `-fsanitize=address` or
  `-fsanitize=thread` flags and Swift `-sanitize=address` or `-sanitize=thread`;
  ASan disables fortified wrappers as in earlier core sanitizer builds.
  Host: macOS 27 arm64, Swift 6.4, AppleClang 21 CLT/SDK 27, CMake 3.30.2, Ninja;
  DEVELOPER_DIR=/Library/Developer/CommandLineTools; authorized loopback sockets.
  Ephemeral logs: /tmp/tidyvnc-swift[-asan|-tsan]-{configure,build,rebuild,tests}.log,
  /tmp/tidyvnc-swift-headless.log, /tmp/tidyvnc-swift-fltk-{build,tests,smoke}.log.
- Minimum-OS compatibility is **not** established: the installed Homebrew JPEG,
  pixman and crypto dylibs were built for macOS 26/27, and the linker reports that
  mismatch against the provisional 14.0 target. Rebuilt dependencies and actual
  minimum-OS/Intel/universal/Release/signing/packaging validation remain N6 work.
  There is still no SwiftUI app, AppKit desktop view, native UI automation,
  app/window quit coordination or native storage/Keychain/clipboard service.
  N2.6/N2.7/N2.8 and the rest of the full plan remain open.

### N2.6 / N2.7 — Xcode app and AppKit vertical slice — 2026-09-19

- Added `apps/macos` SwiftUI connection windows, an AppKit lifecycle coordinator,
  native credential/one-time trust sheets and connection/refresh/quit commands.
  Each window owns a separate MainActor connection model/session. Window close
  starts asynchronous drain; quit cancels all outstanding operations/prompts,
  awaits runtime shutdown and then terminates. SwiftUI remains the sole event
  loop. Terminal disconnect/failure clears obsolete image/cursor/prompt state.
  No profile, password, trust or preference persistence is added.
- Added `NativeDesktopView`/`NSViewRepresentable`, Core Graphics lease providers,
  native mouse/wheel/key/modifier/text/focus handling and cursor presentation.
  CGDataProvider retains its C image handle until release, with no frame-pixel
  copy. Drawing clips to bounds, treats opaque padding correctly and converts
  row orientation once. The checked GEOMETRY C capability delegates placement
  and inverse input coordinates to `DesktopTransform`; no native type crosses
  the portable ABI. Finite/range/header/span checks leave output unchanged on
  failure; dimension overflow maps to RESOURCE_LIMIT. All 33 C declarations
  have unmangled definitions. Existing special-key table was extracted unchanged
  into an attributed shared include; native code reuses existing Unicode and
  hardware/scancode tables. Legacy FLTK behavior is preserved.
- `apps/macos/build.py` drives a Ninja core build, build-tree dependency export,
  separate CMake-generated Xcode app target and `xcodebuild`. App metadata derives
  from `release/Info.plist.in`; icon/README/license remain shared resources. The
  app preserves io.github.jkeli.tidyvnc and executable vncviewer. Xcode 27 Debug
  build succeeds, plist validation and strict ad-hoc signature verification pass,
  and `otool -L` confirms no FLTK dependency. The local build has external Homebrew
  dylibs and hardened runtime disabled; this is not distribution signing or N6
  packaging approval. Dependency OS-floor warnings remain visible.
- AppKit tests paint a real view and verify red/green above blue/white, opaque
  alpha, black letterboxing, transform placement, pointer coordinates on the wire,
  shared hardware key mapping and a key release after focus loss. They retain an
  old CG image across server resize, detach and runtime shutdown. Twelve further
  iterations remove views with resize delivery in flight and verify weak disposal.
  Existing six Swift ownership/auth/cancellation scenarios still pass. Pure C
  adds geometry placement, clamping, fractional-origin rounding, malformed values,
  scaling syntax and overflow checks.
- Visible app checks through computer use: None and VNC connections, native
  password sheet cancellation, reconnect and successful `password` challenge
  (peer reported verified=1), red/green/blue/white desktop, key A (peer keyA=1),
  server 3×1 resize, native Disconnect menu, independent Cmd-N window, error
  presentation after peer/prompt timeout, ordinary quit, and Cmd-Q while the
  authentication sheet is still outstanding. Final pending-prompt quit exits 0.
  Screenshots in this task show the live desktop and corrected visible toolbar.
- Failures found and resolved: Xcode compiler probes needed its normal cache/
  build-service access; Swift imports needed explicit Xcode Swift include paths
  and an app module name distinct from the C module. Split a multi-variable
  SwiftUI `@State` declaration. Hardened runtime initially rejected ad-hoc Homebrew
  dylibs, so the development target now documents its local-only signing scope.
  A screenshot exposed black drawing outside NSView bounds; clipping fixes it.
  The standard Quit action deferred while an authentication sheet was active;
  the explicit coordinator Quit command cancels the sheet before termination,
  and the repeated visible pending-auth test passes. Tests corrected an expected
  fractional backing-origin rounding value and allowed queued focus work to run
  before explicitly focusing a hidden test window. Swift strict concurrency also
  required a weak-reference holder for the view-disposal assertion.
  The overflow assertion initially used a backing scale outside DisplayMetrics'
  accepted range; using valid 2× scaling isolates the intended dimension overflow.
- Final native suite: **2/2 CTests**, normal **0.73s**, ASan **0.91s**, TSan **5.18s**.
  Both Swift and C/C++ are instrumented; SDK/frameworks/external libraries are not
  all instrumented. Sanitizer configurations disable GnuTLS/nettle; normal and app
  builds enable them. Pure C normal test passes, including the final syntax and
  overflow additions. This slice does not claim new Swift/UBSan coverage.
- Portable regression: clean build/native-ui-desktop-headless dependency audit,
  **602/602** unit tests (**18.38s**) and **2/2** smoke consumers passed. Retained
  FLTK build/hidpi: **618/618** (**20.87s**) and **2/2** smoke passed. Those complete
  suites preceded the final two pure-C-only malformed-scaling assertions, which
  passed in the focused consumer. Branding/attribution audit (1650 deferred
  occurrences), shared-table comparison and diff whitespace checks pass.
- Reproduction: `platform/macos/README.md` has build/app/test commands. App output:
  build/native-app/app/Debug/TidyVNC.app. Host: arm64 macOS 27, Swift 6.4,
  AppleClang 21, SDK 27, CMake 3.30.2, Ninja; app uses Xcode 27 (27A266a), native
  standalone tests use CLT. Loopback/WindowServer/Xcode checks used authorized
  host access. Ephemeral logs: /tmp/tidyvnc-app-build.log,
  /tmp/tidyvnc-desktop-native-ui-swift[-asan|-tsan]-{build,tests}.log,
  /tmp/tidyvnc-desktop-headless.log, /tmp/tidyvnc-desktop-fltk-{build,unit,viewer}.log.
- N2.8 remains open for slow DNS/connect, sustained heavy decode and measured UI
  responsiveness. Native TLS/host-key sheet acceptance, full keyboard/IME/cursor/
  wheel/display matrix, all scaling UI/quality modes, damage/performance budgets,
  storage/Keychain/clipboard/listen/settings wrappers, Linux/Windows execution,
  minimum OS/Intel/universal/Release and distribution validation remain open.
  N2.6/N2.7 are a controlled native vertical slice; the overall plan and shipping
  frontend cutover are not complete. All changes remain uncommitted.

### N2.1 / N2.2 / N3.15 — clipboard C/Swift ownership and notifications — 2026-09-19

- Added CLIPBOARD capability and six C exports for policy, local offer/withdraw,
  mailbox consumption, immutable text inspection and route validation. Independent
  send/receive defaults retain the existing core policy. The ABI uses the current
  256 KiB text / 1 MiB retained-payload limits, validates UTF-8/NUL/spans/headers,
  normalizes LF through the core, and preserves legacy Latin-1 and extended UTF-8
  wire behavior. DISABLED and ECHO are distinct admission statuses. Accepted
  commands use the existing reserved exactly-once completion/cancellation stream;
  change IDs are returned as completion origins. Clear withdraws protocol state,
  never the native OS clipboard. All **39** C declarations match unmangled symbols.
- ClipboardChannel now uses a weak internal readiness target for publication and
  policy invalidation, notified outside its mailbox mutex. Session workers attach
  it to the same independent callback dispatcher used by images/events/prompts.
  The C consumer reserves handle capacity and metadata before taking an update,
  so failed allocation does not discard pending text. Retained text handles keep
  immutable data, budget and remote provenance alive after session/runtime close.
- Route tokens contain the originating session ID as non-owning identity plus
  connection generation, focus revision and policy revision. Review caught that
  counters can coincide across sessions; explicit session identity now prevents
  foreign-token validation. Validation remains advisory, requiring native focus
  changes and deferred writes to share an executor and check immediately before
  writing. Remote-origin handles suppress automatic echoes across sessions and
  reconnects. Tokens are not a cryptographic authorization mechanism.
- Swift adds immutable `NativeClipboardText` (copied String plus owning C lease),
  typed update/route values, callback-driven MainActor publication, async offer/
  clear and policy/validation methods. Session construction applies explicit
  per-session direction settings and requires CLIPBOARD. Observable focus and
  clipboard presentation are cleared at reconnect/terminal state/close. There
  is no raw borrowed pointer in Swift state, native pasteboard access or secret
  persistence. No system clipboard contents were read or written in this slice.
- Added core weak-notification coverage; real C callback-driven remote clipboard
  receipt and retained text after shutdown; pure C malformed flags, headers,
  spans, wrong handles and four take-allocation failure positions with pending
  update recovery. The seventh Swift bridge scenario exchanges synthetic café
  text over real loopback RFB, checks normalization/wire delivery, direction and
  focus enforcement, stale/foreign routes, cross-session echo rejection and
  retained ownership through shutdown. Existing native view/input/resize tests
  continue to pass. No test failure required a production workaround.
- Focused C/core tests **26/26**, normal **0.58s**, ASan/UBSan **0.76s**, TSan
  **1.11s**. Pure C consumer normal **0.39s**, ASan/UBSan **0.36s**, TSan **0.21s**.
  Native Swift/AppKit **2/2 CTests**, normal **0.86s**, ASan **0.83s**, TSan **5.08s**.
  Native sanitizer runs instrument Swift and C/C++; SDK/frameworks/external
  dependencies are not all instrumented, and crypto is disabled in those builds.
  C/core ASan uses matching instrumented GoogleTest; this is separate from the
  Swift address-only sanitizer configuration.
- Clean build/native-ui-clipboard-bridge-headless configure/dependency audit:
  **604/604** unit tests (**18.02s**), **2/2** smoke (**0.30s**). Retained FLTK
  build/hidpi: **620/620** (**20.39s**), **2/2** smoke (**0.36s**). Xcode Debug app
  rebuild succeeds against the updated bridge. Branding/attribution audit (1650
  deferred occurrences) and git diff --check pass. No frontend cutover is made.
- Reproduction: focused `viewerabi sessionclipboard viewer-c-abi-smoke` targets;
  unit CTest filter `^(ViewerABI|SessionClipboard)\.` and viewer filter
  `PureCConsumer`, both with `--output-on-failure --no-tests=error`. C sanitizers
  use build/native-ui-encoding-{asan,tsan}; Swift uses build/native-ui-swift[-asan|
  -tsan] tests/macos. App: `python3 apps/macos/build.py`. Host remains macOS 27
  arm64, Swift 6.4 / AppleClang 21 / SDK 27, CMake 3.30.2, Ninja; CLT for standalone
  tests and Xcode 27 for app. Authorized loopback/WindowServer/Xcode access.
  Logs: /tmp/tidyvnc-clipboard-abi-{build,tests}.log,
  /tmp/tidyvnc-clipboard-swift-tests.log,
  /tmp/tidyvnc-clipboard-native-ui-{encoding,swift}-{asan,tsan}-{build,tests}.log,
  /tmp/tidyvnc-clipboard-native-ui-encoding-{asan,tsan}-c-tests.log,
  /tmp/tidyvnc-clipboard-bridge-headless.log,
  /tmp/tidyvnc-clipboard-fltk-{build,unit,smoke}.log,
  /tmp/tidyvnc-clipboard-app-build.log.
- N3.15 remains open: implement the NSPasteboard adapter and app-wide focus/
  change-count arbitration, preserve remote-write provenance, add direction UI,
  then exercise real native clipboard behavior using isolated test pasteboards.
  Broader service/parity/performance/minimum-OS/distribution gates remain open.
  Changes remain uncommitted and the full plan goal remains active.

### N3.15 — native pasteboard adapter and app-wide routing — 2026-09-19

- IDs / commit: checked the native adapter/integration child of N3.15; parent
  remains open for visible control and actual app/window activation verification.
  Current working tree, uncommitted. No frontend cutover or C ABI change.
- `platform/macos/Clipboard` introduces MainActor `NativePasteboardAccess`, the
  NSPasteboard adapter and one app-owned `NativeClipboardCoordinator`. Weak session
  registrations select exactly one eligible focused, connected, non-view-only
  desktop while the application is active. Ambiguous focus selects none.
  App deactivation clears core focus; desktop notifications restore actual focus.
  Independent per-connection send/receive toggles are available before connecting,
  with fixed, redacted nonmodal error text. Preferences persistence remains open.
- Observation uses one cancellable weak 250ms task only while sending is eligible.
  At most one transfer is admitted and one latest pending job is retained. Jobs
  capture generation, routing epoch and native change count; NativeSession now
  accepts an expected generation for offer/clear admission. Every focus/state/
  policy transition immediately invalidates queued work, even a focus round trip
  before deferred reconciliation. Stop gates all subsequent native access; async
  close joins transfer completion and app quit awaits it after runtime shutdown.
- Remote writes recheck the C route immediately before native publication without
  suspending MainActor. A fresh UUID custom pasteboard type records remote origin
  without endpoint data, suppressing automatic cross-session/reconnect/restart
  echoes. Ordinary local copies replace it. Registration drops cached initial
  updates so they cannot overwrite newer native contents. Non-text/unavailable
  copies withdraw protocol availability without clearing native contents.
- Validation limits protocol admission to 256 KiB UTF-8 and rejects NUL. AppKit
  materializes provider strings before checking size; this is not an OS/provider
  allocation bound. Change-count and origin checks detect observed read/write
  ownership races and retry changed snapshots. NSPasteboard provides no cross-
  process CAS; write failure after clear can alter native contents. These limits
  are documented, not treated as an atomic-write or aggregate-memory guarantee.
- Added `NativeClipboard.PasteboardAndRouting` CTest and a test-only wire message
  counter. Four scenarios cover real disposable named boards, two-session routing,
  independent directions, provenance, app inactivity, view-only, ambiguous focus,
  queued focus loss, byte limits/formats, 100-copy coalescing, changed-read retry,
  read/write failures and redaction, concurrent native ownership, cached-update
  suppression, automatic observation, async close and weak disposal. Tests access
  synthetic named boards and injected fakes, never the user's general clipboard.
- Review resolved a write-count race by verifying each write's unique origin and
  captured count; dropped cached publisher replay; and invalidated jobs immediately
  across coalesced focus transitions. Regression scenarios cover these cases.
  Final native CTests: **3/3 normal (1.88s)**, **3/3 ASan (2.03s)** and
  **3/3 TSan (8.41s)**. Both Swift and owned C/C++ are instrumented in sanitizer
  builds; external frameworks/dependencies are not all instrumented. Normal uses
  crypto enabled; existing sanitizer configurations disable crypto.
- Xcode Debug app build succeeds; `codesign --verify --strict --verbose=2` passes.
  Branding/attribution audit passes (1650 deferred occurrences); `git diff --check`
  passes. Portable production code and C ABI are unchanged in this increment,
  so the preceding 604-test headless / 620-test FLTK results were not rerun.
- Reproduction: build `native-bridge-tests native-desktop-tests
  native-clipboard-tests`, then CTest in build/native-ui-swift[-asan|-tsan]/tests/
  macos with `--output-on-failure --no-tests=error`; `python3 apps/macos/build.py`.
  Host: macOS 27 arm64, Swift 6.4 / AppleClang 21 / SDK 27; Command Line Tools for
  standalone tests, Xcode 27 for the app. Authorized loopback, named pasteboard,
  WindowServer and compiler-cache access. Logs:
  /tmp/tidyvnc-pasteboard-native-ui-swift[-asan|-tsan]-{build,tests}.log and
  /tmp/tidyvnc-pasteboard-app-build.log.
- Attempted UI verification could not capture the app because the Mac was locked;
  requested unlock and continued isolated tests. No visible-control result is
  claimed. The idle test app made no connection and was stopped using its verified
  process ID. N3.15's visible control/activation check remains unchecked. Broader
  services, parity, performance, minimum-OS and distribution gates remain open;
  the full plan goal remains active.

### N3.16 — native display topology and selection — 2026-09-19

- IDs / commit: N3.16 implemented; current working tree, uncommitted. N4.8 chooser
  and N5.7/N5.8 physical/fullscreen acceptance are separate unchecked requirements.
- `platform/macos/Display/NativeDisplayService.swift` adds injected MainActor
  `NativeDisplaySource`, real AppKit/ColorSync capture and immutable Sendable
  snapshots with opaque UUID IDs, names, logical/work rectangles, backing scales,
  explicit primary identity, generation and typed errors. Global logical points
  use primary top-left origin and downward Y; negative/fractional coordinates are
  preserved. Both frame and visibleFrame use the same tested conversion. No
  NSScreen reference or CGDirectDisplayID escapes into the snapshot contract.
- Fresh NSScreen capture responds to screen-parameter and active-Space notifications.
  A maximum of 64 displays is validated as a unit; duplicate/empty IDs, invalid
  geometry/scale, work areas outside bounds or ambiguous primary fail explicitly.
  Empty topology is valid. Failure clears available geometry, recovery publishes,
  and duplicate/reordered equivalent input does not advance generation. Observers
  may reenter refresh safely. No polling task, background thread or async cleanup.
- Selection resolution preserves surviving requested IDs and reports missing IDs;
  only an entirely unavailable selection falls back to current then primary.
  Caller preferences remain untouched, so a returning stable ID restores selection.
  UUID identity comes from the OS; hardware/driver identity changes are not claimed
  impossible. Mirroring follows AppKit drawable screens. Missing/duplicate native
  identity produces an error rather than a fabricated persistent identifier.
- The app owns the service and injects it into each desktop. Topology publication
  refreshes geometry/cursor placement while actual window backing scale remains
  authoritative. Weak subscriptions detach with the view; quit stops observation
  before session/window cleanup. No portable production code or C ABI change.
- Added `NativeDisplay.TopologyAndSelection` CTest. Synthetic cases cover negative
  origins, fractional/mixed scales, immutable old snapshots, reordered notifications,
  remove/replug, partial/all-missing selections, current/primary fallback, no screens,
  malformed/oversized snapshots, failure recovery, synchronous observer reentry,
  both notification paths, stop, desktop delivery/detach and weak disposal. Real
  AppKit/ColorSync capture reports **one drawable display**, stable IDs/values on
  immediate reread and unchanged notification refresh. No display settings changed.
- Strict Swift compile initially caught catch-variable shadowing and the compiler's
  local weak-variable mutability diagnostic; fixed without suppressing warnings.
  An unattached NSView does not provide a reliable redraw-flag assertion; the test
  now verifies delivered generation, absent-frame geometry, detach and disposal.
  Existing real AppKit rendering/input tests continue to pass.
- Final native CTests: **4/4 normal (1.95s)**, **4/4 ASan (2.45s)** and
  **4/4 TSan (11.29s)**. Swift and owned C/C++ sanitizer configurations are retained;
  external frameworks/dependencies are not all instrumented, sanitizer crypto is
  disabled. Xcode Debug app build and strict codesign verification pass. Branding
  audit and whitespace checks pass. Portable headless/FLTK suites were not rerun
  because this increment changes only the opt-in macOS layer and native tests.
- Reproduction: build native-display-tests, native-desktop-tests,
  native-clipboard-tests and native-bridge-tests, then CTest in
  build/native-ui-swift[-asan|-tsan]/tests/macos with --output-on-failure and
  --no-tests=error; `python3 apps/macos/build.py`. Logs:
  /tmp/tidyvnc-display[-asan|-tsan]-{build,tests}.log and
  /tmp/tidyvnc-display-app-build.log. Host remains macOS 27 arm64, Swift 6.4 /
  AppleClang 21 / SDK 27, CLT standalone builds and Xcode 27 app build. Native
  queries/tests use authorized WindowServer/loopback access. No clipboard UI check
  was retried without an unlock response. No physical hotplug, mixed-density,
  Spaces/fullscreen behavior, minimum-OS or distribution claim. Full goal active.

### N3.1 — native preferences storage foundation — 2026-09-19

- IDs / commit: checked the storage-foundation child of N3.1; parent stays open
  for shared-schema expansion and app/Settings integration. Current working tree,
  uncommitted. No portable core/C ABI change and no production preferences access.
- Added `platform/macos/Storage/NativePreferencesStore.swift`: one actor serializes
  reads, compare-revision commits and reset against injected `NativePreferencesBacking`.
  The real backend targets `io.github.jkeli.tidyvnc.native.preferences`, reads only
  its persistent domain and writes one owned Data key without replacing unrelated
  keys. App wiring must provide one writer actor per domain; independent writers/
  processes are not covered by an atomic compare-and-swap guarantee.
- Schema-1 records contain a UUID revision and typed non-secret patch, initially
  optional clipboard send/receive fields. Absence inherits supplied configuration;
  reading missing data does not write. Reset stores an empty patch with a fresh
  revision. Shared settings schema/bridge expansion must supply remaining fields
  before broader UI use; no second Swift table of protocol defaults/ranges added.
- Reads reject corrupt/non-data records, unknown fields, future schemas, wrong
  Boolean types and records above 64 KiB. Failed read/reset preserves bytes, with
  no XDG/global/registration/CLI fallback or implicit migration. There are no
  credential, endpoint, arbitrary dictionary or transient-error preference fields.
- Revisions are checked after a fresh backing read, so same-actor stale drafts
  conflict and observed external edits reconcile. Change streams hold one latest
  snapshot each, max 64 observers. Subscription refresh also publishes observed
  external changes to existing observers. Termination returns capacity through
  bounded weak actor cleanup; close/deinit finish streams without an ownership cycle.
- Cancellation before admission performs no write. Cancellation after acceptance
  returns the committed outcome. A throwing backend write may still have effects;
  fresh read reconciles those before retry, and the old revision then conflicts.
  UserDefaults acceptance/readback is not fsync, crash durability, cross-process
  transaction or full filesystem-denial diagnosis. Actual read-only/inaccessible
  native-store behavior, file-store interrupted commits and broader N3.7 remain open.
- Added `NativePreferences.RevisionAndPersistence` CTest: concurrent stale edits
  (exactly one success, one typed conflict), reset identity, observed external
  replacement/removal, latest-only notifications, strict schema/type validation,
  future/unknown-data preservation, injected denied/unavailable/IO failures,
  uncertain accepted writes, cancellation on both sides of admission, subscriber
  cap/recovery, and weak store disposal. The real adapter test creates a unique
  `io.github.jkeli.tidyvnc.tests.preferences.<UUID>` domain and removes only that
  domain afterward; verifies fresh-adapter readback, registration exclusion,
  unrelated-key preservation, non-data corruption and typed configuration patches.
  It does not establish cross-process/crash persistence.
- Initial lifecycle assertion checked disposal before admitted stream-termination
  cleanup tasks had drained. It now waits with a bounded timeout and proves the
  retained stream does not keep the store alive. Review also fixed subscription
  refresh to update existing observers, with an external-removal regression case.
- Final native suites: **5/5 normal (2.04s)**, **5/5 ASan (2.41s)** and
  **5/5 TSan (12.93s)**. Existing sanitizer scope remains: owned Swift/C/C++
  instrumented, external frameworks/dependencies not all instrumented, crypto off
  in sanitizer configurations. Xcode Debug build and strict codesign verification
  pass. Branding audit passes (1650 deferred occurrences) and git diff --check passes.
  Portable headless/FLTK suites were not rerun for this native-only increment.
- Reproduction: build native-preferences-tests plus native-{bridge,desktop,clipboard,
  display}-tests, then CTest in build/native-ui-swift[-asan|-tsan]/tests/macos with
  --output-on-failure --no-tests=error; `python3 apps/macos/build.py`.
  Logs: /tmp/tidyvnc-preferences[-asan|-tsan]-{build,tests}.log and
  /tmp/tidyvnc-preferences-app-build.log. Host: macOS 27 arm64, Swift 6.4 /
  AppleClang 21 / SDK 27, CLT standalone tests and Xcode 27 app build. Authorized
  disposable UserDefaults domains and existing isolated native fixtures only.
- No preferences UI/default application to new sessions is claimed. Profile/history
  stores, migration, credentials/trust, broader settings and N4.9 remain open.
  The prior locked-screen UI check remains pending; full plan goal stays active.

### N3.1 / N4.9 — app defaults and native Settings draft — 2026-09-19

- IDs / commit: checked the initial clipboard app-default/model children under
  N3.1/N4.9; parents remain open for shared-schema expansion, live-session draft
  sheets and interactive UI verification. Current working tree, uncommitted.
- Added MainActor `NativePreferencesDraft` and `NativeSessionDefaults` in
  `platform/macos/Storage/NativePreferencesModels.swift`. The app now owns one
  store actor and one Settings draft. The SwiftUI Settings scene has independent
  clipboard directions, per-field inherited/app-default labels, Apply, Cancel Edits,
  Restore Built-in Defaults and explicit reload after conflict/uncertain failure.
  Restore changes only the draft; Cancel/window dismissal never saves. Opening/
  activation refreshes clean drafts, preserving dirty edits. Error text is fixed
  and does not contain stored data. Accepted saves are not described as rolled back.
- New connection windows perform one fresh asynchronous defaults read before
  enabling Connect or clipboard controls. Failure offers Retry or explicit
  built-in defaults for that connection, preserving unreadable native data.
  Ready sessions do not subscribe to app defaults, including on reconnect. Live
  direction changes remain scoped to that session; the menu shows per-field
  built-in/app/session provenance. Other sessions and saved defaults are unchanged.
- Model tasks weakly reference their owners and apply results only while active.
  Window close stops/joins defaults loading. Quit starts session shutdown, stops
  Settings operations, awaits model/store completions and clipboard close, then
  terminates. A pending store operation does not block MainActor. No portable core
  or C ABI changes; the existing native bridge configuration/policy methods are used.
- Expanded `NativePreferences.RevisionAndPersistence` with draft edits/cancel,
  two-editor revision conflict and recovery, restore cancellation, actual native
  session initialization from saved values, later-save isolation, field-specific
  session override provenance, explicit corruption fallback, blocked store-read
  cancellation/late-result suppression, MainActor heartbeat and accepted-save join.
  Stores are injected in-memory/disposable domains; tests never touch production
  preferences. The application itself was built but not launched in this increment.
- Added `NativeSettings.DraftRendering`, compiling the actual app Settings view
  into an isolated test host. It renders default/conflict states in light/dark
  appearances in unshown windows, with a bounded fitting-size assertion and PNG
  output. Images were inspected for readable labels, button/error layout and no
  clipping. Initial transparent snapshots needed explicit test appearance/window
  background. Visual review then caught a reused fixture being reset by the real
  view's onDisappear Cancel; independent fixtures and a retained-conflict assertion
  now prevent that false rendering result. This was fixture lifecycle, not a store
  rollback or a change to the intended Cancel behavior.
- Render artifacts: build/native-ui-swift/tests/macos/settings-render/
  defaults.png, defaults-dark.png, conflict.png and conflict-dark.png. These are
  owned-view renderings with synthetic state, not desktop captures. They do not
  establish interactive keyboard focus, VoiceOver, high contrast, localization,
  actual app activation or pending-save app termination. Those gates stay open;
  the previous locked-Mac interactive check still awaits unlock.
- Final native CTests: **6/6 normal (2.50s)**, **6/6 ASan (2.73s)** and
  **6/6 TSan (15.56s)**. Existing sanitizer scope: owned Swift/C/C++ instrumented,
  external frameworks/dependencies not all instrumented, crypto disabled in the
  sanitizer configurations. Xcode Debug app build and strict codesign verification
  pass. Branding audit (1650 deferred occurrences) and git diff --check pass.
  Portable headless/FLTK suites were not rerun for this native-only increment.
- Reproduction: native-{bridge,desktop,clipboard,display,preferences,settings}-tests
  in build/native-ui-swift[-asan|-tsan], then CTest tests/macos with
  --output-on-failure --no-tests=error; `python3 apps/macos/build.py`.
  Logs: /tmp/tidyvnc-settings-final[-asan|-tsan]-{build,tests}.log,
  /tmp/tidyvnc-preferences-model[-asan|-tsan]-{build,tests}.log and
  /tmp/tidyvnc-preferences-model-app-build.log. Host remains macOS 27 arm64,
  Swift 6.4 / AppleClang 21 / SDK 27, CLT standalone and Xcode 27 app builds.
  Broader settings/schema, stores/migration/credentials, full UI parity, physical
  display/performance and distribution gates remain open; full plan goal active.

### N2.1 / N2.2 / N2.4 — shared encoding C/Swift boundary — 2026-09-19

- IDs / commit: checked the encoding child of N2.1; extended N2.2/N2.4 guarantees.
  Current working tree, uncommitted. Listener/layout/remaining settings exports
  and native encoding UI/preferences integration remain open.
- ENCODING feature bit 512 adds seven exports (46 total C symbols verified with
  nm): schema/choice enumeration, immutable snapshot create/patch/get, configured
  session creation, session snapshot query and async live apply. Schema names,
  aliases, defaults/ranges, persistence/live flags and decoder availability come
  from the same `EncodingOptions` implementation used by core/retained FLTK.
  Explicit option/source mappings are compile-time checked against core enums.
- Encoding handles own fixed-size immutable core values in the existing bounded
  typed registry, independent of session lifetime. A zero base starts with compiled
  defaults; a nonzero base is copied before the shared validator applies up to 256
  assignments, each name/value at most 128 UTF-8 bytes. Fixed output structs copy
  NUL-terminated text; no borrowed string escapes. Output/base values remain intact
  on failure. Sources distinguish compiled/app/profile/session/CLI overrides.
  New domain 6 encodes reason plus optional field ID without input-bearing errors.
- `session_create_with_encoding` copies initial options before negotiation;
  original create delegates with a zero encoding handle. Existing session-options
  layout is unchanged. Live apply checks generation, copies the snapshot into the
  existing bounded worker queue and reserves its completion. Session queries return
  independently retained requested options. Execution changes only that session;
  options survive reconnect. Completion means local application, not server ack or
  a displayed-frame guarantee. Safe update timing, auto selection and pre-3.8 pixel-
  format restrictions remain in the core. Cancellation cannot undo executed work.
- Swift `NativeEncodingOptions` owns immutable handles, copies schema/choice/value
  text, exposes typed schema/source/problem enums and assembles patches in one
  bounded contiguous temporary UTF-8 buffer. Configuration accepts initial encoding;
  session query/live apply use owning snapshots and existing async completion/
  cancellation. Strict Swift compilation initially caught an unused buffer-call
  return; explicitly discarded it without suppressing diagnostics.
- Added C ABI tests for schema/aliases/choices, immutable patches and caller-buffer
  mutation, structured invalid-value errors, unchanged outputs, wrong/released
  handles, initial pre-negotiation quality hints, live quality change on the next
  update, immediate caller-handle release, reconnect preservation and stale apply.
  Controlled loopback peers observe actual quality 3 then 5 encoding hints; retained
  values remain readable after runtime shutdown. The test peer can emit an empty
  update to exercise the protocol-safe point without changing desktop pixels.
- Pure C consumer adds version/size/span/count/source rejection, unavailable
  decoder errors, configured-create wrong-type handling, snapshot lifetime and 32
  encoding allocation-failure positions, alongside the existing 48 session-create
  positions. Swift tests cover canonical/shared validation, capability rejection,
  32 concurrent immutable reads, initial and live values/sources, independent
  sessions, stale/cancelled admission and values retained through runtime shutdown.
- Focused normal ViewerABI: **16/16 (0.61s)**; pure C **1/1 (0.62s)**. C/C++
  ASan+UBSan: **34/34 (1.06s)** ViewerABI/EncodingOptions/SessionEncoding plus pure C
  **1/1 (0.38s)**. C/C++ TSan: **34/34 (1.62s)** plus pure C **1/1 (0.21s)**.
  Full native suites: **6/6 normal (2.83s)**, **6/6 ASan (3.52s)**,
  **6/6 TSan (16.13s)**. External frameworks/dependencies are not all instrumented;
  sanitizer configurations disable crypto; normal native/headless/FLTK enable it.
- Clean build/native-ui-encoding-bridge-headless configure/dependency audit:
  **606/606 unit tests (18.18s)** and **2/2 smoke (0.40s)**, with no native/FLTK
  dependencies in the portable consumer graph. Retained build/hidpi frontend:
  **622/622 unit (20.18s)** and **2/2 smoke (0.35s)**. Xcode Debug app rebuild and
  strict codesign verification pass; branding audit (1650 deferred occurrences)
  and git diff --check pass. No shipping frontend cutover.
- Reproduction: viewerabi/viewer-c-abi-smoke/encodingoptions/sessionencoding
  targets and CTest filters `^(ViewerABI|EncodingOptions|SessionEncoding)\.` plus
  PureCConsumer in build/native-ui-encoding-{asan,tsan}; six native test targets
  and tests/macos CTest in build/native-ui-swift[-asan|-tsan]. Clean portable audit:
  tests/viewer/headless.py --build-dir build/native-ui-encoding-bridge-headless
  with Ninja/Debug/Homebrew/crypto arguments; retained cmake build/hidpi then unit/
  viewer CTest. App: `python3 apps/macos/build.py`.
  Logs: /tmp/tidyvnc-encoding-bridge-{build,unit,c,swift,headless}.log,
  /tmp/tidyvnc-encoding-abi-{asan,tsan}-{build,tests,c}.log,
  /tmp/tidyvnc-encoding-native[-asan|-tsan]-{build,tests}.log,
  /tmp/tidyvnc-encoding-bridge-fltk-{build,unit,smoke}.log and
  /tmp/tidyvnc-encoding-app-build.log. macOS 27 arm64, Swift 6.4 / AppleClang 21 /
  SDK 27; CLT standalone, Xcode 27 app. Authorized isolated loopback/native tests.
- No Linux/Windows execution, minimum-OS, full settings UI, encoding preference
  storage or interactive UI acceptance is claimed. Wider parity, service,
  performance and distribution requirements remain open; full plan goal active.

### N3.1 / N4.4 / N4.9 — encoding defaults and pre-negotiation session setup — 2026-09-19

- IDs / commit: checked encoding app-default/storage/UI children; parent items
  remain open for other settings, live-session draft sheets and interactive
  acceptance. Current working tree, uncommitted. No portable core/C ABI edits.
- Added `NativeEncodingPreferences`, a closed optional typed patch for the eight
  shared encoding fields. Canonical values, defaults, ranges and decoder availability
  resolve through `NativeEncodingOptions`; there is no independent Swift protocol
  default/range table. Absent fields preserve the supplied base configuration and
  source; explicit app values carry app-default provenance.
- Preferences read schema 1 without rewriting bytes and write schema 2 only on
  explicit commit/reset, with a fresh revision. Nested unknown/null/wrong-type
  fields, invalid values and unavailable decoders fail before writing; invalid
  stored data remains intact. An invalid draft can be corrected or cancelled
  without reload; conflict/uncertain-write reload requirements remain unchanged.
- `NativeSessionDefaults` now owns its runtime and creates/owns a session only
  after an asynchronous defaults read and validation. Initial encoding reaches
  configured core construction before negotiation, and clipboard registration
  follows session publication. Failed reads offer Retry or explicit built-in
  fallback. Closing during a blocked read suppresses late session allocation;
  ready sessions retain their options across later app-default saves.
- Settings now includes clipboard/encoding sections with source labels, automatic
  selection, compiled decoder choices (unavailable choices disabled), full/reduced
  color, custom compression and JPEG enable/quality. Shared-schema ranges constrain
  numeric controls. Automatic/manual and dependent-field enablement are explicit.
  Apply/Cancel/Restore remain app-default draft operations. The runtime wrapper
  now requires the encoding feature bit used by configured session creation.
- Tests add exact schema-1 preservation and schema-2 upgrade, typed round trip,
  canonicalization, nested invalid-data preservation, unavailable decoder rejection,
  correctable/cancellable drafts, initial idle-session encoding/provenance, later
  session isolation, and no allocation after cancelled blocked loading (including
  a one-slot runtime capacity probe). Existing clipboard/default/failure tests use
  the new deferred creation model. No production preferences are read or written.
- Actual Settings rendering now covers eight independent synthetic fixtures:
  clipboard defaults/conflict and encoding automatic/manual in light/dark. Images
  fit 560×540 or 560×624, within the 620×680 test bound. Representative manual,
  automatic dark and conflict dark images were visually inspected. Native TabView
  labels were unreadable in the owned-view cache capture; section buttons now
  render clearly and expose selected accessibility state. The standalone SDK's
  State macro plugin was unavailable; an explicit ObservableObject selection model
  avoids that macro dependency without compiler-warning suppression.
- Final native CTests: **6/6 normal (4.31s)**, **6/6 ASan (5.38s)** and
  **6/6 TSan (18.17s)**. External frameworks/dependencies are not all instrumented;
  sanitizer configurations disable crypto. Xcode Debug app rebuild and strict
  codesign verification pass. Branding audit passes (1650 deferred occurrences)
  and git diff --check passes. Portable/FLTK suites were not repeated because
  this increment changes only the native layer, native tests and documentation.
- Reproduction: build native-{bridge,desktop,clipboard,display,preferences,settings}-tests
  in build/native-ui-swift[-asan|-tsan] and run CTest tests/macos with
  --output-on-failure --no-tests=error; `python3 apps/macos/build.py`.
  Logs: /tmp/tidyvnc-encoding-settings-final[-asan|-tsan]-{build,tests}.log and
  /tmp/tidyvnc-encoding-settings-final-app-build.log. Render PNGs:
  build/native-ui-swift/tests/macos/settings-render/{defaults,conflict,encoding,
  encoding-manual}[-dark].png. Host: macOS 27 arm64, Swift 6.4 / AppleClang 21 /
  SDK 27, CLT standalone builds and Xcode app build. Tests use authorized isolated
  stores/loopback/native fixtures and unshown owned windows, not desktop capture.
- Interactive keyboard/VoiceOver/app activation and pending-save termination remain
  unverified; the prior locked-Mac check still awaits unlock. Live encoding sheets,
  wider settings, profile/history/credentials/trust, performance, physical display
  and distribution gates remain open. Full plan goal remains active.

### N4.4 / N4.9 — live connection encoding draft and sheet — 2026-09-19

- IDs / commit: checked live encoding model/UI children; parents remain open for
  interactive acceptance and broader settings. Current working tree, uncommitted.
  This increment changes only native Swift/app/test code and documentation.
- Added `NativeSessionEncodingDraft`: immutable baseline/draft snapshots and copied
  sourced values for one connected generation, shared-schema validation, Apply,
  Cancel Edits, explicit reload, and typed fixed errors. Editing never submits.
  Only changed fields gain session provenance; other fields preserve their source.
  It has no preferences store and cannot save app defaults.
- Apply compares a fresh requested snapshot with the baseline and passes the captured
  generation to the existing core command. Observed competing edits preserve the
  draft and require reload. Completion rechecks connection, generation and actual
  requested values before confirming. This comparison is not atomic with the core
  command; the app permits one encoding editor per connection. No server-ack or
  displayed-frame guarantee is added to the existing local completion contract.
- Pending application gates edits, reload and duplicate Apply. Cancel Apply requests
  cancellation but cannot undo an accepted change. Failure/cancellation requires
  reload to reconcile actual state. Weak target/model references, cancellable tasks
  and async close avoid editor retention or blocking MainActor. Connection/close
  observations invalidate a draft; reconnect does not silently revive it.
- Extracted shared `EncodingSettingsFields` for app defaults and live settings,
  using the same schema ranges, decoder choices and automatic/dependent controls.
  Per-field labels cover built-in/app/profile/connection/CLI provenance. A live-only
  field gate honors schema metadata (current encoding fields are all live).
  `SessionEncodingSheet` presents draft/applied/pending/conflict/cancellation states
  with Apply, Cancel/Done, Cancel Apply and explicit discard/reload actions.
- Toolbar and Connection menu target the active connection. `ConnectionModel` now
  lives in its own file, owns the sheet and its cleanup task, and gates reopening
  until prior work drains. Disconnect removes the sheet before another auth flow;
  window/quit drain joins the sheet and session. One SwiftUI sheet route prioritizes
  authentication; delayed encoding dismissal cannot cancel a new authentication
  prompt. No credential, preference or other-session mutation was introduced.
- Added `NativeEncoding.DraftAndSessionIsolation` CTest. Injected targets exercise
  canonical edits/cancel, invalid values, observed competing changes, before/after-
  acceptance failure/cancellation, duplicate gating, generation changes before and
  after submission, weak disposal, MainActor progress and close join. Real loopback
  sessions verify only one changes, overrides persist through reconnect, old drafts
  invalidate and native close suppresses editing. The same target compiles the real
  app ConnectionModel and checks deferred registration, single-editor ownership,
  reopen-after-drain, disconnect dismissal and window-close join; its backing throws
  on any attempt to save app defaults.
- Settings render tests now exercise **18** independent fixtures: prior eight app
  Settings states plus live draft/applied/conflict/pending/cancelled in light/dark.
  Live images fit 590×470 through 590×521 within the 620×680 test bound. Inspected
  live draft, pending and cancelled-dark images plus shared app-default manual-dark
  for readable controls, source labels, status/error text and buttons. PNGs live in
  build/native-ui-swift/tests/macos/settings-render/live-{draft,applied,conflict,
  pending,cancelled}[-dark].png. They are unshown owned-view captures with synthetic
  state, not screenshots of the locked desktop or proof of interactive accessibility.
- Strict builds caught the compiler's local weak-variable mutability diagnostic;
  the test uses the established weak holder without suppressing warnings. Xcode
  identified cross-module actor isolation on immutable sheet identity; it is now
  explicitly nonisolated. Both were fixed before final verification.
- Final native CTests: **7/7 normal (8.44s)**, **7/7 ASan (9.04s)** and
  **7/7 TSan (29.20s)**. External frameworks/dependencies are not all instrumented;
  sanitizer builds disable crypto. Xcode Debug build and strict codesign verification
  pass. Branding audit passes (1650 deferred occurrences); git diff --check passes.
  Portable/FLTK suites were not repeated for this native-only increment.
- Reproduction: native-{bridge,desktop,clipboard,display,preferences,settings,
  encoding-draft}-tests in build/native-ui-swift[-asan|-tsan], then CTest tests/macos
  with --output-on-failure --no-tests=error; `python3 apps/macos/build.py` and strict
  codesign verification. Logs: /tmp/tidyvnc-live-encoding-verified[-asan|-tsan]-
  {build,tests}.log and /tmp/tidyvnc-live-encoding-verified-app-build.log. Host remains
  macOS 27 arm64, Swift 6.4 / AppleClang 21 / SDK 27; CLT standalone, Xcode app.
- Interactive keyboard/VoiceOver, visible sheet/menu/focus behavior and actual app
  quit with a pending Apply remain open, along with the prior unlock-dependent UI
  checks. Wider settings, native stores/credentials/trust, physical display,
  performance and distribution requirements remain incomplete. Full goal active.

### N3.2 / N3.7 — private atomic profile/history file-store foundation — 2026-09-19

- IDs / commit: checked the N3.2 storage-foundation child; parent stays open for
  app ownership/UI integration, remaining settings and host-parent recovery.
  N3.7 broader store/migration/interruption gates remain open. Current working
  tree, uncommitted. No production preferences/Application Support/XDG data access.
- Added `NativeProfileHistoryStore`, an actor with read/list, stable-UUID profile
  lookup/upsert/delete, recent insertion/removal and history clear. Schema-1 JSON
  holds both collections and one fresh UUID revision; stale profile/history edits
  cannot silently overwrite each other. History retains 20 exact address strings,
  newest first with exact duplicate promotion, matching retained history capacity.
  Limits: 256 profiles, 256-byte names, 4096-byte addresses and a 2 MiB record.
- Profiles contain the current closed typed clipboard/encoding patch and optional
  opaque credential UUID only. Applying a profile preserves absent base settings
  and uses profile provenance for explicit encoding values. Shared validation is
  reused. No credential resolution, secret field, arbitrary settings dictionary,
  runtime error or permission state is stored. Address syntax/canonical identity
  remain shared-parser/UI work; storage does not duplicate the endpoint parser.
- Strict envelope/profile/settings key/type/null/schema checks and shared encoding
  validation preserve corrupt, unknown and future data. Duplicate identities and
  duplicate saved history are rejected. All mutations reload/validate first;
  delete/clear cannot silently reset unreadable state. No fallback/import path.
- `NativePrivateFile` selects the dedicated native Application Support directory
  through a factory; read/constructor does not create it. First write creates an
  owned 0700 directory and 0600 data/lock/temp files, clearing inherited ACLs on
  new objects. Existing permissions are never repaired. Current UID, private mode,
  empty extended ACL, regular/single-link leaf and no-follow checks gate access.
  Nonblocking opens prevent FIFO hangs; reads enforce size before and during IO.
  The host Application Support parent must already exist and is trusted.
- A nonblocking advisory lock serializes cooperating processes; contention returns
  busy. Under lock, exact previously read bytes are compared before temp write,
  file fsync, same-directory rename and directory fsync. Readers see old/new complete
  records. Ordinary failures clean owned temps; crash-left temps are ignored and
  never promoted. Uncooperative same-user writers, automatic orphan maintenance
  and hardware power-loss durability are not claimed by this contract.
- Cancellation before rename preserves old data. After rename it cannot roll back;
  late failure has an uncertain accepted outcome, resolved by fresh read and new
  revision. The backend is immutable/Sendable with per-operation descriptors and
  bounded buffers; the actor owns no workers or sessions. App integration remains
  deliberately unwired until connection/history/profile flows are implemented.
- Added `NativeProfiles.AtomicHistoryAndPersistence`: disposable real-file reopen,
  mode checks, stable profile CRUD/provenance, history ordering/cap/dedup/clear,
  schema/type/future/unknown/secret-field preservation, profile/address/file limits,
  pre-admission cancellation and closed-store rejection. Checkpoint faults exercise
  before/after-replacement failures/cancellation, temp cleanup, orphan isolation and
  store-level uncertain-commit reconciliation. Independent adapters/stores and a
  separate test subprocess verify lock contention and stale-writer rejection.
- Actual filesystem tests cover private read-only files/directories, overly broad
  modes, extended ACLs, symlink data/lock paths, hard links, FIFOs and oversized
  sparse files. All permission changes, subprocess arguments and cleanup are limited
  to unique disposable test roots. The native app was built, not launched.
- Strict Swift compilation required explicit Darwin ACL pointer/entry-ID conversions.
  A real test caught Darwin's null/ENOENT result for an absent extended ACL; a tiny
  disposable-file C probe verified it, and the adapter now treats that case as empty.
  The initial combined write/build approval timed out; splitting workspace file
  creation from the build resolved it without changing permissions or user data.
- Broad regression runs exposed the existing AppKit pixel test comparing cached
  Color LCD-profile values as device RGB. Its saved synthetic image was visibly
  correct. Converting NSColor alone did not preserve the bitmap ICC profile;
  converting the captured bitmap to sRGB before sampling fixed the assertion.
  Pixel thresholds, channel/orientation/alpha/letterbox coverage and production
  rendering remain unchanged. Failed captures now retain a diagnostic fixture PNG.
- Final native suites: **8/8 normal (4.69s)**, **8/8 ASan (5.51s)** and
  **8/8 TSan (23.22s)**. External frameworks/dependencies are not all instrumented;
  sanitizer crypto remains disabled. Xcode Debug build and strict codesign check
  pass. Branding audit passes (1650 deferred occurrences); git diff --check passes.
  Portable/FLTK suites were not repeated for this native-only increment.
- Reproduction: build native-{bridge,desktop,clipboard,display,preferences,settings,
  encoding-draft,profile-history}-tests in build/native-ui-swift[-asan|-tsan], then
  CTest tests/macos --output-on-failure --no-tests=error; `python3 apps/macos/build.py`.
  Logs: /tmp/tidyvnc-profiles-verified[-asan|-tsan]-build.log,
  /tmp/tidyvnc-profiles-complete[-asan|-tsan]-{build,tests}.log and
  /tmp/tidyvnc-profiles-verified-app-build.log. Color diagnostic artifact:
  build/native-ui-swift/tests/macos/desktop-failure.png. Host remains macOS 27 arm64,
  Swift 6.4 / AppleClang 21 / SDK 27, CLT standalone and Xcode app build.
- App profile/history wiring, wider typed settings, missing host-parent setup,
  document codecs/import/export/migration, credential-reference scoping, real
  interruption/power-loss acceptance and the prior interactive UI gates remain
  incomplete. Full plan goal stays active; no shipping frontend cutover.

### N3.2 / N4.1 — app recent-history ownership and UI — 2026-09-19

- IDs / commit: checked the shared-history integration children; parent items stay
  open for profile UI, remaining fields, document/import flows and interactive
  acceptance. Work remains uncommitted; the overall implementation goal is active.
- The app owns one `NativeProfileHistoryStore` and `NativeRecentHistory`. Successful
  current-generation connected completions enqueue original endpoint text; failed
  connects and cancelled authentication do not record. Disk work never extends the
  connection await, and save errors leave connected sessions running.
- Added a shared recent-address popover with explicit selection before Connect,
  individual removal, clear, reload and fixed nonmodal error guidance. Clear/remove
  preserve profiles and compare the displayed revision. Conflicting destructive
  actions are never automatically replayed. Failed reads clear the displayed cache.
  Activation and popover opening refresh state; no legacy fallback/import runs.
- One model task serializes operations, with at most 20 pending successful addresses
  and coalesced duplicates/refreshes. Failed records await explicit reload before
  retry. Tasks weakly reference the model. App quit gates new records, cancels
  delivery and joins admitted operations before store close. Accepted writes may
  survive cancellation and are reconciled by reread rather than claimed rollback.
- `NativeApplicationSupportProfiles` resolves the default backend within actor
  operations. Construction/read creates nothing. First write can now create a
  missing host Application Support parent before the private native directory;
  existing access restrictions are preserved. A disposable filesystem test verifies
  deferred creation, private modes and subsequent reading. No production Application
  Support location was read or written by this increment's tests/app build.
- Added ninth CTest `NativeHistory.ModelAndConnectionRouting`: stale deletion and
  reload, profile-preserving clear, uncertain accepted writes, future-schema error
  state, bounded queue/duplicate/refresh coalescing, weak disposal and close during
  held reads and accepted writes. MainActor heartbeat/late-publication checks cover
  pending cleanup. Compiled actual app connection controllers and real two-session
  loopback peers cover successful-only history, invalid endpoint and cancelled auth
  exclusion, independent endpoint fields and nonfatal save failures.
- The existing owned-view render harness now produces **28** fixtures, including
  ten light/dark history empty/recent/connected/error/pending states. Inspected
  populated, connected-dark, error-dark, pending and empty images: addresses,
  truncation, disabled actions and recovery guidance fit without clipping. History
  fitting sizes are 440 points wide and 165.5–307.5 points high. Artifacts:
  `build/native-ui-swift/tests/macos/settings-render/history-*.png`. These synthetic
  unshown-window renders do not establish interactive popover, keyboard or VoiceOver
  acceptance; the Mac remains locked and no desktop-capture bypass was attempted.
- Validation: **9/9 normal (6.41 s), 9/9 ASan (7.59 s), 9/9 TSan (27.23 s)**;
  strict Swift compilation and Xcode app build pass. `codesign --verify --strict
  --verbose=2 build/native-app/app/Debug/TidyVNC.app` confirms valid on disk and its
  designated requirement. External libraries/frameworks are not all instrumented;
  sanitizer builds have crypto disabled, normal build enabled. No portable-core or
  C ABI production code changed in this increment, so full retained/headless suites
  were not repeated. Branding audit passes with 1650 deferred occurrences and
  `git diff --check` is clean.
- Logs: `/tmp/tidyvnc-history-final-{tests,asan-tests,tsan-tests}.log` and
  `/tmp/tidyvnc-history-final-app-build.log`; CTest artifacts remain under each
  `build/native-ui-swift[-asan|-tsan]/tests/macos` tree. All build/test process
  handles completed with exit 0. App was built and signature-checked, not launched
  against production storage for this increment.

### N4.1 / N4.4 / N4.9 / N4.17 — unlocked-app checks — 2026-09-19

- The user confirmed that the Mac was unlocked. CUA accessed the current built app;
  prior locked-screen limitations no longer prevent interactive work. Restarted an
  older running development build before checking the new controls. No parent
  checklist item is complete from this limited manual pass.
- Recent history: empty state showed disabled Clear, Escape dismissed the popover
  and returned focus to endpoint entry. Return connected to a repository-owned
  loopback fixture. Its address appeared in history with selection disabled while
  connected; a new window shared the same entry. Space selected the focused address
  and dismissed the popover without starting a connection. An invalid port produced
  an error and was excluded from history. Quit/relaunch preserved the successful
  address. Accessibility labels exposed address, removal, reload and clear controls.
- Settings: Command-comma opened the window; the live dark appearance fitted its
  content. A clipboard checkbox edit enabled Apply/Cancel; Escape restored the
  inherited value and disabled both actions. Disabling automatic encoding enabled
  dependent fields. Closing with Command-W and reopening discarded that unsaved
  change. No app-default save was performed during these checks.
- Live encoding: Escape cancelled an automatic-encoding draft change, and reopening
  showed the original value. Return applied a second edit and displayed success;
  closing/reopening retained its value and Connection override provenance. Normal
  disconnect disabled the encoding action. Tests used only local synthetic peers;
  both peer processes were stopped and joined with exit 0.
- Found that Return did not acknowledge the single-OK connection-error alert.
  Added an explicit default keyboard action to OK in `TidyVNCApp.swift`. Rebuilt,
  reproduced the invalid-port alert and verified Return now dismisses it. Escape
  does not dismiss this acknowledgement alert; complete keyboard/error behavior
  remains open under N4.17/N4.13. Popover and draft-sheet Escape checks pass.
- Validation: Xcode build passes, signature verification reports valid on disk and
  designated requirement satisfied, and `git diff --check` passes. Build log:
  `/tmp/tidyvnc-ui-unlocked-build.log`. The only production change in this increment
  is the alert shortcut; the earlier nine-test normal/ASan/TSan results remain the
  model/storage baseline and were not rerun for this UI-only edit. CUA sometimes
  lost its native pipe on sheet transitions; reacquiring the app recovered access
  and showed the expected sheet, with no app crash or test failure inferred.
- Unlike the preceding isolated tests/build-only increment, this manual pass used
  the real native Application Support history and left its two generated loopback
  addresses (`127.0.0.1::63919`, `127.0.0.1::64300`). No existing entry was removed;
  history removal/clear, VoiceOver, full tab order, live clipboard focus routing,
  Settings Apply/persistence and broader UI acceptance remain open. Work is still
  uncommitted and the overall plan remains active.

### N3.2 / N4.1 / N4.9 — saved-profile editor and session launch — 2026-09-19

- IDs / commit: checked the initial profile-editor/launch child of N3.2. Parent
  remains open for wider schema fields and complete interactive acceptance; no
  migration, document, Keychain or trust completion is claimed. Work remains
  uncommitted and the full implementation goal remains active.
- Added app-owned `NativeProfileLibrary`: copied profile list, baseline and draft,
  one pending weak-self task, stable IDs, create/select/edit/save/cancel/delete,
  and explicit conflict/uncertain-write reconciliation. Store revisions cover
  profiles and history together. Failed reads clear the list and gate actions;
  dirty drafts survive save failures. Reload never replays a mutation. Stop and
  close gate late publication and join admitted work; accepted saves can survive
  cancellation. Existing opaque credential references are preserved during edits.
- Added Saved Profiles scene and toolbar/File-menu entry (Command-Shift-P), name/
  endpoint fields, inherited/explicit clipboard choices, shared encoding controls
  with source labels and per-field/all-encoding inheritance reset, Save/Cancel,
  explicit Delete confirmation and Open Connection. Dirty profiles cannot be
  switched/opened without save/cancel. The editor scrolls independently of its
  fixed action/error area. It currently covers the closed clipboard/encoding
  schema; endpoint protocol syntax remains checked by the core on Connect.
- Each Open action supplies a unique window UUID plus saved profile UUID. The
  scene restores identifiers, not copied settings; `NativeSessionDefaults` freshly
  reads preferences and the profile before creating its session. Profile explicit
  fields override app defaults and carry profile encoding provenance; missing
  fields inherit. The actual connection controller installs the profile address
  before Connect is available. Open never autoconnects. Ready connections retain
  their initial settings when a profile is subsequently edited/deleted.
- Missing/invalid/inaccessible profiles block session creation with Retry Profile,
  without silent plain-connection fallback. Explicit built-ins after failed app
  defaults still read/apply the chosen profile. That fallback now completes
  asynchronously; the existing test awaits it. Store reads are separate snapshots,
  not a cross-store transaction. Closing during a held profile read suppresses
  late session allocation. App quit joins the library before closing stores.
- Added tenth CTest `NativeProfiles.EditorAndSessionDefaults`: create/edit/cancel,
  source inheritance/reset, credential-reference preservation, history-induced
  stale-save conflict, uncertain accepted-save reload without retry, deletion
  preserving history, future-schema failure, real connection-controller fresh
  profile reads, pre-creation precedence, missing-profile refusal, explicit app-
  default fallback that retains the profile, and existing-session isolation.
  Held reads/accepted writes test MainActor progress, close join, suppressed late
  publication/allocation and weak editor disposal. All stores are test memory
  backings; no test modifies production preferences, profiles or history.
- Render harness now generates **40** fixtures, including twelve profile-library
  empty/saved/editing/conflict/error/pending states in light/dark. All fit the
  940 × 680 point test window; artifacts are
  `build/native-ui-swift/tests/macos/settings-render/profiles-*.png`. Inspected
  empty, editing, conflict-dark, error-dark and pending images. The scrollable
  editor can extend below the viewport; status/actions remain visible. These are
  owned synthetic views, not complete keyboard or VoiceOver acceptance evidence.
- Validation: **10/10 normal (8.20 s), 10/10 ASan (9.97 s), 10/10 TSan (31.80 s)**.
  Xcode app build and strict signature/designated-requirement verification pass.
  Strict Swift concurrency/warnings-as-errors passes. Frameworks/external libraries
  are not all instrumented; sanitizer configurations disable crypto, normal
  enables it. No portable-core/C ABI production changes were made, so retained/
  headless full suites were not repeated. Branding audit passes with 1650 deferred
  occurrences; `git diff --check` passes. Logs:
  `/tmp/tidyvnc-profiles{,-asan,-tsan}-{build,tests}.log` and
  `/tmp/tidyvnc-profiles-app-build.log`. All four final build/test process handles
  were collected with exit 0.
- Interactive evidence: the rebuilt app launched; the new toolbar control was
  present and Command-Shift-P opened an empty Saved Profiles window with correctly
  gated Save/Open/Delete actions. Clicking New Profile was followed by repeated
  computer-control pipe failures, including after session reset. App inventory
  still reported TidyVNC running. A read of
  `SkyComputerUseService-2026-09-19-175947.ips` confirmed the helper's SIGTRAP/
  EXC_BREAKPOINT in `Array.remove(at:)`, not a TidyVNC crash. Create/save/open/delete,
  scene restoration and detailed keyboard/VoiceOver acceptance remain unchecked;
  this tool failure does not block further repository implementation. No profile
  Save/Delete action was taken in the real app during this increment.

### N2.1 / N4.1 — shared endpoint preflight and inline validation — 2026-09-19

- IDs / commit: checked the endpoint-validation children of N2.1/N4.1. Other ABI,
  connection/document/import and full keyboard/accessibility requirements remain
  open. Work is uncommitted; the overall plan remains active.
- Added stateless `tidyvnc_endpoint_validate` and capability bit 1024. The public
  boundary now declares/defines **47** C exports (verified against the static
  archive's global symbols). Validation and Connect share `endpointValue`, which
  applies UTF-8/span bounds and the existing `Endpoint::parse`. No parser was
  duplicated. Validation creates no runtime, handles, workers or callbacks and
  performs no DNS/network/filesystem IO. Original endpoint text is not rewritten.
- Input is a borrowed span capped at 4096 bytes; a uint32 Unix-socket policy must
  be exactly 0/1. Oversize spans return ENDPOINT/TOO_LONG before allocation/access;
  malformed spans, invalid UTF-8 and embedded NUL return BRIDGE/INVALID_ARGUMENT.
  Syntax failures use explicit endpoint detail codes and fixed redacted text.
  Empty input retains the shared parser's localhost:0 behavior; the native empty
  form separately requires entry, matching its prior Connect policy.
- Added `NativeEndpoint` with a temporary UTF-8 buffer capped at 4097 bytes and
  typed `NativeEndpointIssue`. `ConnectionModel` updates the validation result on
  endpoint edits and gates Connect; `NativeProfileLibrary` gates Save using the
  same wrapper. Inline errors explain host/bracket/port/text/length problems;
  field help shows accepted address forms. Invalid actions start no operation and
  write no profile record. Correcting an address enables the action without
  autoconnecting. Existing stored malformed addresses remain readable/editable;
  file decoding intentionally retains its bounded-storage validation contract.
- Added three C++ ABI tests: differential parity with the shared core for valid/
  invalid display, port, IPv6 scope and Unix-path fixtures under both transport
  policies; matching preflight/Connect errors with unchanged operation output and
  idle session; concurrent parsing and byte bounds. Pure-C consumer checks feature
  negotiation, null/oversize/NUL/invalid-UTF8 spans, invalid boolean policy,
  unsupported Unix transport and error-header version/no-write behavior.
- Added eleventh native suite `NativeEndpoint.ValidationAndFormGating`: shared
  address forms and fixed diagnostics, UTF-8 byte boundaries, transport policy,
  empty-field distinction, actual connection-controller action gating and profile
  save refusal without IO. Original Unix path text is preserved on valid save.
  Render harness now produces **42** fixtures, adding light/dark invalid-address
  profile drafts with Save disabled. Inspected the dark inline-error render;
  artifacts: `build/native-ui-swift/tests/macos/settings-render/profiles-invalid-address*.png`.
- Full native validation: **11/11 normal (8.57 s), 11/11 ASan (10.72 s), 11/11 TSan
  (34.43 s)**. Focused C/C++ ABI/parser sanitizers: **31/31 ASan+UBSan (0.91 s)**,
  pure C **1/1 (0.21 s)**; **31/31 TSan (1.42 s)**, pure C **1/1 (0.18 s)**.
  External dependencies/frameworks are not all instrumented; sanitizer builds
  disable crypto, normal builds enable it.
- Clean `build/native-ui-endpoint-preflight-headless` configure and generated
  dependency audit show only the portable core/platform/C ABI consumer graph.
  Final full **609/609 unit (18.14 s)** and **2/2 smoke (0.36 s)** pass. Retained
  `build/hidpi`: **625/625 unit (20.47 s)** and **2/2 smoke (0.28 s)** pass. Initial
  C++ test compilation caught a wrong operation field name and a range-loop copy
  warning; both were corrected before these final runs. The clean headless build
  was resumed in its new directory after the test-only correction, not reconfigured
  over an unrelated build. All final build/test handles completed with exit 0.
- Xcode app build, strict codesign/designated-requirement verification and
  `git diff --check` pass. Branding audit passes with 1650 deferred occurrences.
  Logs: `/tmp/tidyvnc-endpoint-native{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-endpoint-abi-{asan,tsan}-{final-build,tests,c}.log`,
  `/tmp/tidyvnc-endpoint-preflight-{headless,fltk}-{final-build,unit,smoke}.log`,
  clean configure/audit `/tmp/tidyvnc-endpoint-preflight-headless.log`, and
  `/tmp/tidyvnc-endpoint-preflight-app-build.log`.
- Live endpoint UI acceptance remains pending after the prior confirmed
  computer-control helper crash in the open Saved Profiles draft. Requested that
  the user close that window so inspection can resume; no response was received
  during this increment. This does not block independent implementation. No real
  profile/history save, connection or preference change was performed here.

### N2.1 / N4.7 — native connection scaling modes and units — 2026-09-19

- IDs / commit: checked the parser and mode/unit editor children. N4.7 and N5
  remain open for filters/cache, persistence, pan controls, performance and complete
  interactive acceptance. Work remains uncommitted; the overall plan stays active.
- Added `tidyvnc_scaling_parse` with feature 2048 and size-tagged copied mode, x/y,
  fit status and canonical text. It calls the existing `ScalingSettings` parser,
  bounds input to 64 UTF-8 bytes and preserves output on error. It creates no
  runtime, handles, workers or IO. Explicit C IDs are compile-time checked against
  the core; diagnostics contain no input. Verified **48 declarations/48 exported
  definitions**, with no missing/unexpected `tidyvnc_` symbols in the static archive.
- Added connection-owned `NativeScalingState` and copied `NativeScalingDraft` with
  weak ownership, baseline revision checks, per-mode remembered custom text and
  synchronous Apply/Cancel. All eight modes accept the shared dimension/decimal/
  independent-percentage syntax. Percentage 100 canonicalizes to Unscaled. Fit
  modes disable explicit-size units; logical/device choice is retained for later
  explicit sizing. These values survive reconnect in that connection; scaling is
  not yet stored in app defaults or profiles.
- Added toolbar/Connection-menu Scaling Settings sheet with examples, validation,
  disabled invalid Apply, Return/Cancel shortcuts and identifiers. Encoding and
  scaling share the existing authentication-priority sheet route. Dismissals check
  original editor identity so a delayed dismissal cannot cancel a newer editor.
  Disconnect/window close discard the draft; close gates retained old drafts.
- View subscriptions install mode and units atomically and reset pan to the origin.
  Apply preflights against the attached image/viewport/backing scale. Subsequent
  display/remote-size overflow preserves the selected settings while temporarily
  fitting image, cursor and inverse input through the same shared geometry; one
  fixed alert is emitted until recovery, rather than one per frame/layout. Applying
  an already oversized geometry leaves the applied value unchanged and reports
  an inline error. The current nearest Core Graphics renderer remains unchanged;
  no bilinear/area or shared-resampler performance parity is claimed.
- Added two C++ ABI tests for differential shared-parser/canonical values, invalid
  syntax, unchanged output/redacted errors and 4 × 1000 concurrent calls. Pure-C
  tests cover feature negotiation, copied values, null/oversize/NUL/invalid-UTF8
  spans, null/short/versioned outputs and error-header rejection without writes.
- Added twelfth native suite `NativeScaling.DraftGeometryAndIsolation`: all eight
  geometry fixtures, decimal bounds, fractional device scale/pan/inverse mapping,
  draft cancellation/reopen/per-mode retention, wrong-mode rejection, stale/closed
  states and weak owners. Actual connection controller plus real RFB peer verify
  editor gating, unchanged presentation during editing, atomic Apply, pointer wire
  coordinates, disconnect cleanup and view release. An owned unshown AppKit window
  **exercised backing scale 2.0**, preflight rejection, safe fallback, no repeated
  alerts and recovery when changing units. No production data or UI was changed.
- Render harness now produces **54** fixtures, adding fit/exact/percent/independent/
  invalid/conflict sheets in light and dark. Fitting sizes are 520 × 248–334.5
  points. Inspected independent-dark and invalid-light renders; controls, examples,
  inline error and disabled Apply fit. Artifacts:
  `build/native-ui-swift/tests/macos/settings-render/scaling-*.png`. These synthetic
  views do not complete keyboard/VoiceOver or live sheet acceptance. Prior confirmed
  computer-control helper failure remains an interactive limitation; no renewed
  claim that the Mac is locked and no desktop-capture workaround was attempted.
- Final native **12/12 normal (9.65 s), 12/12 ASan (11.63 s), 12/12 TSan (38.12 s)**.
  C ABI focused **21/21 ASan+UBSan (0.81 s)** plus pure C **1/1 (0.27 s)**;
  **21/21 TSan (1.09 s)** plus pure C **1/1 (0.21 s)**. External dependencies/
  frameworks are not all instrumented; sanitizer builds disable crypto, normal
  enables it. No minimum-OS or additional architecture claim.
- Incremental headless `build/native-ui-endpoint-preflight-headless`: full
  **611/611 unit (18.34 s), 2/2 smoke (0.30 s)**. Retained `build/hidpi`: full
  **627/627 unit (20.71 s), 2/2 smoke (0.34 s)**. The prior clean dependency audit
  remains the baseline; this change adds no portable dependency. Xcode app build
  and strict signature/designated-requirement verification pass. Branding audit
  passes with 1650 deferred occurrences; `git diff --check` passes.
- Resolved initial failures before final runs: test weak-local warning under
  warnings-as-errors; immediate AppKit view-release assertion needed to await its
  pending window cleanup; Xcode found that the immutable draft identity needed
  `nonisolated`, matching the encoding draft. Final production source was verified
  after that annotation correction. Existing Xcode simulator/CoreDevice warnings
  and Homebrew minimum-OS linker warnings remain environmental limitations.
- Logs: `/tmp/tidyvnc-scaling-final{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-scaling-abi-{asan,tsan}-{build,tests,c}.log`,
  `/tmp/tidyvnc-scaling-{headless,fltk}-{build,unit,smoke}.log`, and
  `/tmp/tidyvnc-scaling-final-app-{build,signature}.log`. All final process handles
  completed with exit 0; no live app restart or real preference/profile/history
  mutation was performed during this increment.

### N2.1 / N5.1 — shared tile-renderer and native scheduler foundation — 2026-09-19

- IDs / commit: checked the tile-service ABI and background-renderer foundation
  children. N5.1/N5.2 remain open: `NativeDesktopView` still uses its prior nearest
  Core Graphics drawing path. AppKit tile composition, coherent image/geometry
  publication, direct identity path, cursor filtering and filter UI wiring are the
  next integration work. No performance/cutover claim; work remains uncommitted
  and the full implementation goal is active.
- Added portable `FrameTileRenderer` around existing `DesktopTileCache` and
  `resampleDesktop`. It samples bounded tiles with shared nearest/bilinear/area
  algorithms, including the identity-copy branch. Source, generation, size,
  destination dimensions and filter changes invalidate cache. Partial source
  damage preserves unaffected samples only when previous consumed-frame sequence
  matches the renderer's history; skipped frames clear cache. Cache is capped at
  32 MiB and stores no framebuffer lease. Source-frame ownership remains external.
- Added three C exports (`renderer_create`, `renderer_render`, `renderer_clear`),
  feature 4096, explicit filter IDs and size-tagged request/result values. Renderer
  handles serialize calls; source stream identity comes from never-reused C session
  handles. Frame input is retained for each synchronous call; cursor inputs remain
  unsupported. Output is packed opaque BGRA, at most 256 × 256 / 256 KiB per call.
  Dimensions, damage, headers, flags, spans and handles are checked before writing.
  Cache allocation failure returns the rendered pixels, drops cache and allows
  later recovery. Verified **51 C declarations / 51 definitions**, no missing or
  unexpected `tidyvnc_` symbols in the static archive.
- Native images now copy consumed-frame damage and previous sequence plus a stable
  native stream UUID. `NativeTileRenderer` is an actor with default 8 MiB cache;
  it admits only fixed-grid tiles intersecting the visible destination region,
  with a preallocation limit of 64 MiB / 1024 output tiles. A 65535 × 65535 zoomed
  desktop fixture renders only six visible tiles. Empty viewport clears cache.
  Output Data and source images are immutable/retained; no borrowed pixel span
  enters observable state. Payload limits exclude allocator/metadata, source
  publication budget, old displayed batches and future CG upload storage.
- Added MainActor `NativeTileScheduler` with one active and one latest pending
  request. Same-presentation frame updates finish current useful work; changed
  source/generation/size/transform/filter cancels between tiles. Obsolete results
  are suppressed even if a renderer ignores cancellation. Failed current requests
  can be explicitly retried. Tasks weakly reference the scheduler. Stop gates
  admission/delivery; close cancels, asynchronously joins and clears cache. Work
  inside one area-filter tile is not interruptible; its latency remains part of
  the upcoming performance measurement.
- Added five portable renderer tests: shared filter/identity results, partial
  damage and skipped-history recovery, source/generation/resize/filter/budget
  isolation, no retained frame lease, validation preserving output/cache, and
  injected failure of both cache allocation positions with valid pixels and later
  recovery. Reused the existing test-only allocation helper. Added C ABI retained-
  frame pixel checks through session close, 4 × 100 concurrent cached renders,
  damage/output and wrong-handle checks. Pure C covers feature/budget/null/length/
  overflow/header/reserved-field/stale-handle cases and renderer-construction OOM.
- Added thirteenth native suite `NativeRenderer.TilesAndBoundedScheduling`:
  independent bilinear/area/nearest golden pixels, opaque identity, cache reuse,
  extreme zoom/visible-byte bounds, empty viewport, cancellation and rendering
  old images after remote resize/session close/runtime shutdown. Actual native
  publication checks copied damage/history. A held fake renderer proves 500
  updates coalesce to initial + latest, continuous updates make progress, changed
  transforms suppress late results, retry works, close stays responsive and joins,
  and pending work does not retain its scheduler owner.
- Final native **13/13 normal (9.84 s), 13/13 ASan (12.07 s), 13/13 TSan (40.73 s)**.
  ABI/shared-resampler/cache sanitizer set: **31/31 ASan+UBSan (1.23 s)** plus pure
  C **1/1 (0.27 s)**; **31/31 TSan (4.56 s)** plus pure C **1/1 (0.25 s)**. After
  adding allocation-failure coverage, all five renderer tests passed again in
  normal headless (0.08 s), ASan+UBSan (0.11 s), TSan (0.17 s) and FLTK (0.09 s).
  External libraries/frameworks are not all instrumented; normal builds enable
  crypto and sanitizer builds disable it. No minimum-OS or architecture expansion.
- Clean `build/native-ui-tile-renderer-headless` configure/dependency audit/full
  build passed, initially with 616 unit tests and **2/2 smoke (0.39 s)**. The later
  allocation-failure test was built in that same new tree; final full **617/617
  unit (18.39 s)** passes. Retained `build/hidpi` final full **633/633 unit (20.50 s)**
  and **2/2 smoke (0.40 s)** pass. Xcode app build and strict signature/designated-
  requirement verification pass. Branding audit passes with 1650 deferred entries;
  `git diff --check` passes. The empty-viewport cache-clear correction was verified
  in final native runs. No unresolved compilation or test failures remain.
- Logs: `/tmp/tidyvnc-tiles-final{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-tiles-abi-{asan,tsan}-{build,tests,c}.log`,
  `/tmp/tidyvnc-tiles-cache-oom-{native-ui-tile-renderer-headless,native-ui-encoding-asan,native-ui-encoding-tsan,hidpi}-{build,tests}.log`,
  `/tmp/tidyvnc-tiles-headless.log`, `/tmp/tidyvnc-tiles-headless-final-unit.log`,
  `/tmp/tidyvnc-tiles-fltk-{build,final-unit,smoke}.log`, and
  `/tmp/tidyvnc-tiles-app-{build,signature}.log`. All final handles completed with
  exit 0. No live UI restart, production data write or desktop capture occurred.
  Existing 54 synthetic settings/profile/history render fixtures remain unchanged;
  this worker increment adds no new visual UI acceptance evidence.

### N2.1 / N5.1–N5.3 — AppKit tile composition and joined renderer ownership — 2026-09-19

- IDs / commit: checked the shared damage ABI and AppKit composition children;
  current working tree, not committed. Parent N5 items remain open for cursor,
  filter controls, full observation isolation and physical/performance acceptance.
- Added `tidyvnc_desktop_damage` / feature 8192 with copied rectangle output,
  checked headers/bounds/filter/reserved fields and no-write failure behavior.
  Geometry and damage share one transform construction/placement helper. The
  shared filter halo, rounded backing placement and pan drive CG tile reuse and
  logical dirty rectangles. Verified **52 C declarations / 52 definitions** using
  `nm`, with no missing or extra exports. Swift requires the advertised feature.
- `NativeTileRenderer` now constructs immutable CG images over directly retained
  native tile allocations; composition does not copy pixels into Data. It reuses
  unchanged images/storage across contiguous damage and same-frame pan, while
  skipped history or source/size/filter changes disable reuse. Worker tests prove
  CG identity reuse, zero rendered bytes for repeated requests and skipped-damage
  recovery. The original image remains retained independently of the session.
- `NativeDesktopView` now composes visible shared-resampler tiles with explicit
  orientation and no second interpolation pass. Identity immediately draws the
  retained source image without output allocation. Image and inverse input map
  publish together; pending scale changes keep the displayed map, obsolete work
  is suppressed, and source/size changes clear the prior presentation. Shared
  damage limits redraw; history/transform changes invalidate the viewport.
  Hide/unhide clears/restores presentation and resets worker cache.
- A session-owned pool bounds renderers to 16 slots, counting detached slots
  until drain completes. Close/quit joins every renderer asynchronously. Views
  release slots on explicit detach and deallocation; callbacks capture views
  weakly. The deallocation review found and fixed a missing automatic release.
  A held-worker regression verifies cleanup without explicit detach. An initial
  strict Swift warning in that test was corrected; the final build/tests pass.
- Payload admission remains 64 MiB / 1024 visible tiles per batch and 8 MiB C
  cache per native renderer. Conservatively budget three batch payloads: displayed,
  previous successful worker result and in-progress output. Displayed and worker
  tiles normally share allocations, but suppressed/failed presentation can retain
  different batches. Source leases, metadata, allocator overhead and CG uploads
  remain separate; these are bounds, not measured performance acceptance.
- Added the fourteenth native suite, `NativePresentation.CompositionDamageAndDrain`:
  actual AppKit nearest/bilinear/area/identity pixels, partial damage and reuse,
  coherent image/input transforms, obsolete-scale suppression, hidden state,
  retained provider lifetime, held renderers through detach/close, slot capacity
  and automatic view-release cleanup. Existing desktop/scaling tests now await
  asynchronous presentation. Loopback peer fixtures can patch two separate pixels.
- Initial displayed-color assertions exposed host display-profile conversion.
  Tests now compare filtered samples with an independently constructed golden
  CG image under the same conversion; worker tests still check exact raw bytes.
  No production color adjustment was needed. Five synthetic PNGs per build tree:
  `build/native-ui-swift/tests/macos/presentation-render/{nearest,partial-damage,
  bilinear,area,identity}.png`. Bilinear and partial-damage fixtures were visually
  inspected. These use owned unshown windows, not desktop capture or live UI
  acceptance. The existing 54 settings/profile/history fixtures are unchanged.
- Final native **14/14 normal (10.30 s), 14/14 ASan (12.51 s), 14/14 TSan
  (44.06 s)** pass after the deallocation fix. C ABI **23/23 normal (0.62 s),
  ASan+UBSan (0.84 s), TSan (1.21 s)** and pure-C **1/1** in each configuration
  pass. The new differential C++ test covers three filters, fractional backing
  scale/pan and edge/empty damage; pure-C tests cover invalid values and no-write
  failures. External dependencies/frameworks are not all instrumented.
- Incremental headless full build: **618/618 unit (18.91 s), 2/2 smoke (0.36 s)**.
  Retained FLTK full build: **634/634 unit (21.20 s), 2/2 smoke (0.36 s)**. Final
  Xcode app build and strict signature/designated-requirement verification pass.
  Branding audit passes with 1650 deferred entries; `git diff --check` passes.
  Host is macOS 27 arm64 / Swift 6.4 / Apple Clang 21 / SDK 27. Source target 14
  and Homebrew newer-OS dependency warnings do not establish older-OS support.
- Logs: `/tmp/tidyvnc-composition-final{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-composition-final-app-{build,signature}.log`,
  `/tmp/tidyvnc-composition-abi-first-{build,tests,c}.log`,
  `/tmp/tidyvnc-composition-abi-{asan,tsan}-{build,tests,c}.log`, and
  `/tmp/tidyvnc-composition-{headless,fltk}-{build,unit,smoke}.log`.
  No live app restart or production storage write occurred. The Mac is unlocked;
  no lock-state blockage is asserted. Shared cursor sampling, quality controls,
  accessible pan/scroll, complete SwiftUI frame-observation isolation, multi-view
  focus policy, physical display checks and measured budgets remain open.

### N4.7 / N5.2 — native scaling-quality controls — 2026-09-19

- IDs / commit: checked the quality-controls children of N4.7/N5.2; current
  working tree, not committed. Shared cursor sampling, scaling persistence,
  accessible pan, live keyboard/VoiceOver and physical/performance gates remain.
- `NativeScaling` now owns an explicit nearest/bilinear/area filter; drafts copy
  the baseline selection, include it in equality/revision checks and publish it
  with mode/units in one transaction. Filter-only edits enable Apply, Cancel
  discards them and reopening shows the applied selection. Separate connections
  remain isolated. Built-in state and standalone views default to bilinear,
  matching `vncviewer/parameters.cxx`'s retained frontend default.
- The Scaling Settings sheet now exposes all three choices with contextual
  explanations and a stable accessibility identifier. Mode/units changes reset
  pan as before; a filter-only change preserves the current pan and placement.
  The subscribed view submits the selected shared CPU filter; identity still
  bypasses tile allocation while retaining the user's quality preference.
  No new C ABI, persistence format or server-resolution operation was introduced.
- Extended model/controller tests for the default, filter-only Apply, Cancel,
  reopen, stale baseline rejection, connection isolation and preserved pan.
  The AppKit composition test now applies nearest, bilinear and area through
  actual `NativeScalingDraft` transactions, checking displayed pixels against
  independent golden images and atomically applying size/units/filter together.
- Added light/dark nearest and area sheet fixtures: **58 settings PNGs** plus
  the existing **5 composition PNGs** in `build/native-ui-swift/tests/macos`.
  Visually inspected area, nearest-dark and conflict sheets. The original area
  explanation widened the form beyond its intended padding; shortened copy
  restores the normal margins and was re-rendered/inspected. Full interactive
  accessibility acceptance is not inferred from these unshown-window captures.
- First broad runs exposed the older orientation fixture's implicit nearest
  assumption. It now asserts the bilinear default, then explicitly selects nearest
  for its unblended quadrant assertions; filter-specific golden tests remain.
  Final **14/14 normal (9.98 s), 14/14 ASan (11.97 s), 14/14 TSan (43.67 s)**
  pass. Final app build and strict signature/designated-requirement checks pass.
  Branding audit passes with 1650 deferred entries; `git diff --check` passes.
  Portable C++/C sources did not change; prior headless/FLTK evidence is unchanged.
- Logs: `/tmp/tidyvnc-quality-verified{,-asan,-tsan}-{build,tests}.log` and
  `/tmp/tidyvnc-quality-verified-app-{build,signature}.log`; all final handles
  completed with exit 0. Earlier diagnostic runs are under
  `/tmp/tidyvnc-quality-{first,final,layout}*`. macOS 27 arm64 / Swift 6.4 /
  SDK 27; sanitizer coverage excludes some external libraries/frameworks.
  Existing newer-OS Homebrew dependency warnings remain; no older-OS, universal
  build or shipping-cutover claim. No live app restart or production store write.

### N5.1 — frame/cursor streams outside SwiftUI observation — 2026-09-19

- IDs / commit: checked the image-observation child of N5.1; current working
  tree, not committed. Shared cursor sampling and measured presentation budgets
  still keep the parent open.
- `NativeSession.frameUpdates` / `cursorUpdates` now replay one retained image
  each through independent current-value publishers. They replace `$frame` /
  `$cursor`; synchronous `frame` / `cursor` getters remain. AppKit subscribes on
  MainActor with weak view captures. Per-frame/cursor delivery does not send
  `objectWillChange`; SwiftUI uses the lightweight `hasFrame` transition for its
  empty-desktop overlay. Disconnect/close clears streams before renderer drain.
- Duplicate copied snapshots are suppressed, preserving the core's existing
  100 ms statistics cadence instead of invalidating controls on every frame wake.
  Repeated nil prompt checks and unchanged focus/view-only values no longer
  trigger observation. Input setters still call the native validation/policy path.
  No timer, frame queue, pixel copy or C ABI change was introduced.
- Extended the actual AppKit loopback suite through 20 individually consumed
  frame updates and RichCursor show/hide. It counts session object notifications,
  snapshot notifications, image deliveries and availability transitions. In the
  steady-state interval every object notification equals a distinct snapshot
  notification; images and unchanged focus add none. Initial focused run observed
  **20 frames + 2 cursor changes / 4 snapshot invalidations**. Counts are diagnostic,
  not a timing benchmark or a fixed scheduling assumption.
- The same test verifies synchronous replay to new subscribers, real cursor
  dimensions/hotspot, current-value nil on hide, one `hasFrame = false` transition
  on disconnect, immediate AppKit clearing, and retained cursor pixel ownership
  after session/runtime shutdown. Existing close/reconnect/weak-disposal tests
  exercise the new frame streams. A throwing pixel-copy assertion was initially
  placed in a nonthrowing test autoclosure and corrected before execution.
- Focused bridge/presentation tests passed **2/2 (1.75 s)**. Final native
  **14/14 normal (11.60 s), 14/14 ASan (13.73 s), 14/14 TSan (45.42 s)** pass.
  All three final observation cases recorded the same 20/2/4 diagnostic counts.
  Final Xcode app build and strict signature/designated-requirement checks pass.
  Branding audit passes with 1650 deferred entries; `git diff --check` passes.
  Logs: `/tmp/tidyvnc-observation-final{,-asan,-tsan}-{build,tests}.log` and
  `/tmp/tidyvnc-observation-app-{build,signature}.log`; final handles exit 0.
  Host remains macOS 27 arm64 / Swift 6.4 / SDK 27; external frameworks/dependencies
  are not fully instrumented, and newer-OS Homebrew warnings remain. No older-OS
  execution, universal packaging or performance claim. No production C++ or portable ABI change;
  the macOS test peer alone gained controlled RichCursor fixtures. Previous
  headless/FLTK evidence remains unchanged. No live app restart, desktop capture
  or production storage write occurred.

### N2.1 / N5.4 — shared C/Swift cursor sampler — 2026-09-19

- IDs / commit: checked the cursor-sampler ABI and service children; current
  working tree, not committed. N5.4 remains open: `NativeDesktopView` has not yet
  adopted this sampler, and native/software cursor presentation, fallback policy,
  bounded scheduling/drain and visible cursor acceptance are still required.
- Added `cursor_renderer_create` / `cursor_renderer_render`, feature 16384 and
  versioned copied options/geometry/tile values. Verified **54 C declarations /
  54 definitions** with `nm`; no missing or extra exports. Native runtime requires
  the feature. Calls reject non-cursor images, incompatible formats, invalid scales,
  headers, filters, reserved fields, tiles and spans before changing output.
- Each sampler owns only an immutable original-sized premultiplied source copy,
  capped at 4 MiB; it retains no source image/session/runtime lease. Shared
  `CursorRenderer` supplies all filters and rounded/clamped backing-pixel hotspots.
  Nonempty output tiles are <=256 × 256 and spans <=256 KiB, with straight RGBA
  produced after premultiplied filtering. Enlarged rasters are never allocated.
  Concurrent render calls use independent output spans and immutable source.
- Swift `NativeCursorSampler` owns the handle/copied geometry, validates before
  tile allocation, checks cancellation around calls and creates straight-RGBA CG
  images directly over the same retained allocation/provider type used by desktop
  tiles. Construct/sample off MainActor; within-tile work is not interruptible.
  Caller scheduling/output retention, metadata and CG uploads remain outside the
  source/tile bounds and need full presentation budgeting during integration.
- New fifteenth native suite `NativeCursor.SamplingAndOwnership` verifies
  transparent-red/opaque-green edge goldens without color fringes, all filters,
  identity, area reduction, subpixel minimum dimensions, hotspot clamping,
  anisotropic/extreme scale, invalid tiles and frame-image rejection. A
  **131070 × 1000** cursor is sampled across its center boundary from an **8-byte**
  original. Eight concurrent workers sample after source/session/runtime teardown;
  weak-image checks prove the original lease is released independently. Retained
  CG providers survive shutdown, and cancelled tasks reject rendering.
- New C++ ABI loopback test compares all filters at 0.25/1/1.25/2/65535 scales
  against the shared renderer and independent alpha goldens. It checks hotspots,
  edge tiles, stale/wrong handles, unchanged failure outputs, concurrent reads
  after shutdown and eight allocation-failure positions through the existing
  thread-local allocator fixture. Registry/object/source construction failures
  return OUT_OF_MEMORY without publishing either output; subsequent creation
  recovers. Pure-C tests independently cover scales, headers, reserved fields,
  output lengths/nulls, invalid handles and no-write failure behavior.
- Focused Swift cursor/presentation **2/2 (1.19 s)**. Final native **15/15 normal
  (11.66 s), 15/15 ASan (13.93 s), 15/15 TSan (47.70 s)**. C ABI **24/24 normal
  (0.85 s), ASan+UBSan (0.97 s), TSan (1.29 s)** and pure-C **1/1** in all three
  (0.60/0.27/0.35 s). No unresolved build or test failures remain.
- Full incremental headless **619/619 unit (18.77 s), 2/2 smoke (0.31 s)**;
  retained FLTK **635/635 unit (20.97 s), 2/2 smoke (0.41 s)**. Xcode app build
  and strict signature/designated-requirement verification pass. Branding audit
  passes with 1650 deferred entries; `git diff --check` passes. Host remains macOS
  27 arm64 / Swift 6.4 / SDK 27; external libraries/frameworks are not all sanitizer
  instrumented. Existing newer-OS Homebrew dependency warnings remain; no minimum-
  OS, universal, measured-performance or shipping-cutover claim.
- Logs: `/tmp/tidyvnc-cursor-final{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-cursor-abi-{0,1,2}-{build,tests,c}.log` (normal/ASan+UBSan/TSan),
  `/tmp/tidyvnc-cursor-{headless,fltk}-{build,unit,smoke}.log` and
  `/tmp/tidyvnc-cursor-app-{build,signature}.log`. All final handles exit 0.
  Existing 58 settings and five composition fixtures remain; this service test
  creates no cursor screenshot or live-UI evidence. No app restart, desktop capture
  or production storage write occurred.

### N5.1 / N5.4 — native/software cursor presentation and joined jobs — 2026-09-19

- IDs / commit: checked shared cursor presentation and API fallback children;
  current working tree, not committed. Parent N5.4 remains open for app fallback
  controls and visible physical-display/Spaces acceptance. Full budgets/input
  parity and performance remain separate unchecked gates.
- Added a cursor renderer actor and MainActor scheduler: one active plus one
  latest request, cancellation/stale suppression for shape/scale/filter/clip
  changes, and useful completion under pointer-only motion. The actor caches one
  original-sized sampler and completed batch, reusing unchanged immutable CG tiles.
  Visible admission is capped at 64 MiB / 1024 tiles; invalid/nonfinite placement
  is rejected before rendering. Shared tile-grid checks now support the cursor
  sampler's larger raster dimensions without permitting coordinate overflow.
- AppKit uses sampled native cursors up to 128 × 128 backing pixels. Larger
  cursors composite visible tiles after the desktop, clipped to its rectangle;
  old/new cursor rectangles invalidate independently. Hotspots/logical sizes use
  shared backing-pixel geometry and the displayed frame's scale/filter. Pointer
  request position stays with its completed software image; cursor movement can
  lag input while background rendering finishes, pending measured latency gates.
- Letterbox/exit/hide clears software overlays immediately and prevents late work
  from restoring them. Hidden/cleared views discard the remembered pointer; active
  key-window presentation refreshes a missing position from AppKit's window
  coordinates. Cursor generation guards follow displayed-frame ownership.
- Added copied `blank` metadata to cursor geometry (C symbols remain **54**) to
  detect all-transparent shapes off MainActor. Nil/blank cursors select hidden,
  dot or system fallback through the view API; hidden matches retained defaults.
  View-only uses a local arrow. Errors erase old cursor output and report once
  until successful recovery. App settings/profile controls for fallback are still
  open; no global input monitoring or privacy changes were introduced.
- Each of the session's 16 presentation slots now owns both desktop and cursor
  schedulers. Detach/deallocation/close stops both before asynchronously joining
  both; a slot remains counted until all work drains. Conservatively budget three
  cursor tile batches (192 MiB) plus two transient original source copies (8 MiB)
  during replacement, additional to desktop worker bounds. Cache batches retain
  their request image lease; metadata, source leases, NSCursor internals and CG
  uploads are outside those payload bounds and still require measurement.
- Added sixteenth suite `NativeCursor.PresentationAndDrain`, using actual unshown
  AppKit windows and controlled RichCursor fixtures. It checks software red/green
  overlay pixels, letterbox clipping, alpha/filter routing, shared tile identity
  reuse on motion, immediate outside-pointer clearing, native image/hotspot size,
  all-transparent/empty fallback, view-only and hide. Actual Retina-window
  attachment/detachment rebuilds backing geometry and crosses the native/software
  threshold while preserving logical size. Held workers ignoring cancellation
  prove 500-motion coalescing with only the latest pending point, obsolete-filter
  suppression and nonblocking joined close after detach. Numerical overflow and
  oversized visible output fail safely, with later renderer recovery.
- Two synthetic PNGs were visually inspected:
  `build/native-ui-swift/tests/macos/cursor-render/software-nearest.png` and
  `software-alpha-bilinear.png`. They show cursor clipping/overlay and transparent
  edges over the desktop; they are not desktop captures or visible OS-cursor
  acceptance. Existing 58 settings and five desktop composition fixtures remain.
  An initial test helper emitted an actor-isolation warning; annotating it
  MainActor removed that warning. Focused final presentation test **1/1 (0.52 s)**.
- After the hidden-position correction, final native **16/16 normal (12.17 s),
  16/16 ASan (14.28 s), 16/16 TSan (50.77 s)** pass. ABI **24/24 ASan+UBSan
  (1.06 s), 24/24 TSan (1.40 s)** and pure-C **1/1** (0.30/0.22 s) pass; the
  normal ABI cases also pass in the full headless/FLTK runs. Headless **619/619
  unit (19.11 s), 2/2 smoke (0.25 s)**; FLTK **635/635 unit (21.46 s), 2/2 smoke
  (0.28 s)**. Final app build and strict signature/designated-requirement checks
  pass. Branding audit: 1650 deferred entries; `git diff --check` passes.
- Logs: `/tmp/tidyvnc-cursor-ui-verified{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-cursor-ui-verified-app-{build,signature}.log`,
  `/tmp/tidyvnc-cursor-ui-abi-{0,1}-{build,tests,c}.log` (ASan+UBSan/TSan), and
  `/tmp/tidyvnc-cursor-ui-{headless,fltk}-{build,unit,smoke}.log`. All final handles
  exit 0. macOS 27 arm64 / Swift 6.4 / SDK 27; external dependencies/frameworks
  are not fully instrumented and newer-OS Homebrew warnings remain. No minimum-OS,
  universal, measured-performance or shipping-cutover claim. No live app restart
  or production storage write occurred.

### 2026-09-19 — Connection-local Input Settings (N4.6 / N5.4 portion)

- IDs / commit: checked the connection-local input/fallback children in the
  current working tree; no commit. N4.6 and N5.4 remain open for input option
  parity, defaults/profile persistence and interactive/physical acceptance.
- Added `NativeInputState` and copied `NativeInputDraft`, owning only connection
  policy and weak references to session/state. View-only stays authoritative in
  the session. Apply validates revision, generation and connected/nonclosing
  state synchronously before changing core policy and publishing fallback.
  External view-only changes, disconnect/reconnect and close reject old drafts.
  Cancel has no live effects or persistence writes.
- Added the actual Input Settings sheet to the connection menu and toolbar,
  with view-only and hidden/dot/system cursor fallback, contextual help, stable
  accessibility identifiers, Apply/Cancel and conflict/closed errors. It shares
  authentication-priority and identity-guarded dismissal with the existing
  scaling/encoding editors. Those editors are mutually exclusive.
- The desktop subscribes weakly to fallback and cancels on detach. View-only
  clears local held keys/buttons, wheel accumulation and composition while the
  core releases remote keys/buttons. Keyboard/pointer/scroll handlers avoid
  accumulating new local input in view-only mode; a blocked click cannot turn
  into a drag when control resumes.
- Added seventeenth suite `NativeInput.DraftRoutingAndRelease`: actual loopback
  key/button release, input rejection, no phantom drag, copied draft/cancel,
  apply/reopen, session isolation, external-policy conflicts, disconnect/reconnect
  and close invalidation, and weak view/state ownership. Twelve additional
  light/dark settings fixtures cover defaults, view-only, dot/system, conflict
  and closed state (70 total settings images). Visually inspected
  `build/native-ui-swift/tests/macos/settings-render/input-conflict.png` and
  `input-system-dark.png`; these are synthetic unshown-window renders, not live
  menu/keyboard/VoiceOver or physical-display acceptance.
- Initial strict Swift build rejected never-mutated local weak variables in
  test code; weak-reference boxes fixed that warning. Final native **17/17 normal
  (13.78 s), 17/17 ASan (16.26 s), 17/17 TSan (54.77 s)** pass. App build and strict
  code-signature/designated-requirement verification pass. Branding audit passes
  with 1650 deferred entries; `git diff --check` passes. No portable-core/FLTK
  production source changed in this increment; prior core regression evidence
  remains above.
- Logs: `/tmp/tidyvnc-input-full-{build,tests}.log`,
  `/tmp/tidyvnc-input-{asan,tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-input-app-{build,signature}.log`, and
  `/tmp/tidyvnc-input-branding.log`. All final process handles exited 0.
  macOS 27 arm64 / Swift 6.4 / SDK 27. Existing newer-OS Homebrew link warnings
  and Xcode device/simulator plugin warnings remain; app build succeeds.
  No minimum-OS, universal, shipping-cutover or performance claim. No live app
  restart or production storage write occurred.

### 2026-09-19 — Shared middle-button emulation and native setting (N4.6 portion)

- IDs / commit: checked the middle-button child; current working tree, no commit.
  N4.6 remains open for fullscreen system keys, modifier selection, defaults/profile
  persistence and interactive acceptance. No broader input-parity completion claim.
- Extracted the retained 11-state algorithm into allocation-free
  `viewer::MiddleButtonEmulator`, preserving upstream attribution and the existing
  FLTK `EmulateMB` adapter/tests. Fixed output storage holds at most three pointer
  events. Hosts own timing: retained FLTK uses its existing timer; native protocol
  sessions use a scoped 50 ms deadline. Delayed single-button presses preserve
  drag origin; release/repress, late chord, physical middle and other button masks
  retain established behavior. The retained disabled path now discards pending
  emulation rather than allowing a stale delayed press.
- InputQueue applies view-only/emulation atomically under its mutex. An emulation
  change releases held input, discards queued input and advances routing revision.
  Commands snapshot policy/revision on dequeue; protocol release/revision barriers
  reset emulation. Timed work verifies generation, routing revision, connection,
  focus and view-only, and teardown cancels it. The session scheduler now has four
  bounded slots (statistics, publication, resize and middle-button). No native
  global or MainActor emulation timer was introduced.
- Added checked boolean C export `tidyvnc_session_input_policy` and required
  `TIDYVNC_FEATURE_INPUT_POLICY`. Invalid values fail before mutation; legacy
  view-only preserves emulation. Verified **55 declarations / 55 definitions**
  with `nm`, without missing/extra exports. Policy survives reconnect within a
  session; delayed input cannot cross generation/routing boundaries.
- Native Input Settings now includes the emulation toggle/help/stable identifier,
  copied Apply/Cancel, external-change conflict handling and reopen behavior.
  AppKit clears local held input/composition when changing emulation releases core
  input. Actual native loopback checks chord wire events without stray left press,
  delayed single press, release on disabling and absence of a later phantom drag.
  Four deterministic protocol tests cover deadlines/drag origin, chord and button
  masks, cancellation across focus/view-only/policy/overflow/close/reconnect, and
  two independent sessions. ABI validation and atomicity have dedicated coverage.
- Final full headless **624/624 unit (20.06 s), 2/2 smoke (0.45 s)**; retained FLTK
  **640/640 unit (23.02 s), 2/2 smoke (0.41 s)**. C++ emulation/protocol/ABI subset
  **70/70 ASan+UBSan (2.52 s), 70/70 TSan (3.46 s)** and pure-C **1/1**
  (0.25/0.19 s). Native **17/17 normal (14.24 s), 17/17 ASan (16.92 s),
  17/17 TSan (55.27 s)**. App build and strict signature/designated-requirement
  checks pass; branding audit passes (1650 deferred) and `git diff --check` passes.
  Initial fixture compile errors (ABI-info variable and stream rewind API) were
  corrected before these final runs.
- Settings fixtures now total 72, including 14 input light/dark fixtures. Visually
  inspected `build/native-ui-swift/tests/macos/settings-render/input-middle.png`
  and `input-conflict-dark.png`. These are synthetic unshown-window captures;
  physical devices, visible interactive sheet/VoiceOver acceptance and measured
  latency remain open.
- Logs: `/tmp/tidyvnc-middle-{headless,fltk}-{build,unit,smoke}.log`,
  `/tmp/tidyvnc-middle-core-{asan,tsan}-{build,tests,c}.log`,
  `/tmp/tidyvnc-middle-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-middle-app-{build,signature}.log`, and
  `/tmp/tidyvnc-middle-branding.log`. All final process handles exit 0.
  macOS 27 arm64 / Swift 6.4 / SDK 27. Existing newer-OS Homebrew and Xcode
  device/simulator warnings remain; no minimum-OS/universal/shipping/performance
  claim. No live app restart or production storage write occurred.

### 2026-09-19 — Shared shortcut classifier and native routing foundation (N5.5 portion)

- IDs / commit: checked the shared-classifier/native-routing prerequisite under
  N5.5; current working tree, no commit. N4.6/N4.10/N5.5 remain open for actual
  AppKit event/layout integration, lifecycle reset, command dispatch, modifier
  controls and system-key capture. This increment does not intercept live input
  or expose an unfinished modifier control.
- Extracted retained `ShortcutHandler` classification into portable `ShortcutState`
  while leaving localized naming/prefix formatting in the retained adapter.
  Upstream attribution is preserved. Replaced dynamically growing key maps/sets
  with 1024 fixed entries; existing physical IDs repeat without consuming slots.
  Invalid masks/capacity failures preserve state. Reset clears held IDs/fired flags
  while keeping modifiers. No timer/callback/session reference or per-event
  allocation. Measured arm64 state size: **12,304 bytes**.
- Added typed, per-handle mutex-protected create/modifiers/key/reset C APIs and
  required `TIDYVNC_FEATURE_SHORTCUTS`. Standard handle registry ownership and
  4096-handle admission apply. Output action/handle values remain unchanged on
  failure. Verified **59 C declarations / 59 definitions** with `nm`, no extras
  or missing exports. Tests cover unsupported masks, null outputs, invalid boolean,
  wrong/released handles, capacity recovery, allocation-free steps, creation
  allocation failures and four concurrent retained owners.
- MainActor `NativeShortcutState` owns one handle and no session/view.
  `NativeShortcutRouter` implements retained command selection from ordered
  layout candidates, modifier-only unarm and Space bypass. It returns route and
  remote-key-release intent for future host dispatch, with bounded held-ID state
  even during bypass. Reset/reconfiguration drops bypass and old keys; invalid
  changes preserve state. Eighteenth native suite covers all 16 modifier masks,
  repeats, capacity/slot reuse, modifier-only release, candidate selection,
  repeated actions, Space bypass/end/late-Space, isolation and reset/reconfigure.
- Differential verification against `git show HEAD:vncviewer/ShortcutHandler.*`
  matched **1,600,000 deterministic press/release events**, with periodic reset,
  all modifier masks, left/right modifier keysyms, reused IDs and varied ordering.
  Artifact: `/tmp/tidyvnc-shortcut-reference/{compare.cxx,compare,result.log}`.
  Initial compilation needed the configured SDK; final comparison exits 0.
- Final headless **628/628 unit (19.29 s), 2/2 smoke (0.24 s)**; retained FLTK
  **644/644 unit (21.54 s), 2/2 smoke (0.29 s)**. C++ shortcut/ABI subset
  **62/62 ASan+UBSan (1.58 s), 62/62 TSan (2.51 s)**; pure C **1/1**
  (0.24/0.22 s). Native **18/18 normal (14.33 s), 18/18 ASan (15.93 s),
  18/18 TSan (54.56 s)**. App build and strict signature/designated requirement
  pass. Branding audit passes with 1650 deferred entries; `git diff --check`
  passes. Initial reservation-method and C++11 aggregate-initialization build
  errors were corrected before final checks. No new UI screenshot is claimed;
  existing settings/presentation fixtures still run with native regressions.
- Logs: `/tmp/tidyvnc-shortcut-{headless,fltk}-{build,unit,smoke}.log`,
  `/tmp/tidyvnc-shortcut-core-{asan,tsan}-{build,tests,c}.log`,
  `/tmp/tidyvnc-shortcut-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-shortcut-app-{build,signature}.log`, and
  `/tmp/tidyvnc-shortcut-branding.log`. All final process handles exit 0.
  macOS 27 arm64 / Swift 6.4 / SDK 27. Existing newer-OS Homebrew and Xcode
  device/simulator warnings remain; no minimum-OS/universal/shipping/performance
  claim. No live app restart or production storage write occurred.

### 2026-09-19 — Native desktop command menus and information sheet (N4.10 portion)

- IDs / commit: checked the native command-menu child under N4.10; current working
  tree, no commit. N4.10 remains open for shortcut/context-popup dispatch, minimize
  from fullscreen, multi-display transitions, full negotiated metadata and live
  interactive acceptance. Current fullscreen is the native single-window action;
  tests do not establish physical window/Spaces behavior.
- Added connection-owned `NativeDesktopCommands` with weak session/desktop/window
  routing. Connection and toolbar menus share one `DesktopActions` view for
  disconnect, fullscreen, windowed minimize, fit-to-desktop, Control/Alt latches,
  Ctrl-Alt-Delete, refresh, settings, information and About. Fit accounts for
  viewport/chrome, clamps to visible-screen bounds and handles negative origins.
- Synthetic keys require current connection/policy and successful focus of the
  owning desktop, then recheck eligibility to handle changes during focus.
  Commands release prior wire/local input before applying latch/chord changes;
  failures release input and restore previous intent. IDs above physical/IME
  ranges avoid ID collisions. Ctrl-Alt-Delete releases Delete and only retains
  selected menu modifiers. Focus loss releases actual wire keys while preserving
  latch selections; focus/policy recovery reasserts them when eligible. Physical
  release of a selected left modifier reasserts that latch. Disconnect clears
  selection, rebind releases the old session and close cancels/stops all routing.
- Recovery uses one coalesced weak MainActor task, no await in the task body,
  cancellation/stop checks and an identity guard for cleanup. A final refinement
  replaced cancel/recreate scheduling with reuse of the existing pending task so
  a synchronous focus/policy burst cannot accumulate cancelled recovery tasks.
- Added a basic information sheet for existing endpoint, desktop size/frame count,
  resize support, input/emulation and clipboard values. It shares auth-priority,
  mutually exclusive settings/info presentation and identity-guarded dismissal,
  and disconnect closes it. Negotiated server name, protocol/security/pixel-format
  statistics remain to be exposed. Two light/dark long-endpoint PNGs were visually
  inspected under `build/native-ui-swift/tests/macos/settings-render/`:
  `connection-information.png` and `connection-information-dark.png`; 74 settings/
  information fixtures total. No live menu/VoiceOver or desktop capture claim.
- Added nineteenth suite `NativeCommands.RoutingAndModifierLifetime`: actual
  loopback peers verify key press/release/reassertion, exact six-event
  Ctrl-Alt-Delete wire sequence, view-only and focus refusal, policy changes during
  focus, connection isolation, rebind/disconnect cleanup and weak observer/task
  ownership. Window-method spies verify routing, pure geometry checks verify fit
  and screen clamping, and the actual ConnectionModel verifies sheet arbitration.
- Full native **19/19 normal (13.85 s), 19/19 ASan (16.61 s), 19/19 TSan
  (57.33 s)** pass. After the final task-coalescing refinement, focused command
  tests pass **1/1 normal (0.24 s), 1/1 ASan (0.28 s), 1/1 TSan (2.49 s)**.
  Final app build and strict signature/designated requirement checks pass.
  Branding audit passes with 1650 deferred entries; `git diff --check` passes.
  No portable-core or retained-frontend production source changed this increment;
  prior full portable regression evidence remains above.
- Logs: `/tmp/tidyvnc-command-verified{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-command-recovery{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-command-final-app-{build,signature}.log`, and
  `/tmp/tidyvnc-command-branding.log`. All final process handles exit 0.
  macOS 27 arm64 / Swift 6.4 / SDK 27. Existing newer-OS Homebrew and Xcode
  device/simulator warnings remain; no minimum-OS/universal/shipping/performance
  claim. No live app restart or production storage write occurred.

### 2026-09-19 — AppKit shortcut dispatch, native popup and capture lifetime

- IDs / commit: completed implementation children under N4.6/N4.10/N5.5 in the
  current working tree; no commit. Parent items remain open for physical/layout/
  IME/Spaces/global-capture acceptance, input persistence, fullscreen transitions
  and complete negotiated connection metadata.
- AppKit now routes key down/up/modifier events and key equivalents through the
  shared classifier before remote input. Bounded TIS/UCKeyTranslate candidates
  are resolved lazily only for an armed shortcut. Control+Option defaults support
  G capture, M native connection popup, Return fullscreen, modifier-only release
  and Space bypass. Local commands release remote held input; bypass sends one
  remote key pair. View-only still permits local window/menu actions.
- Added connection-local modifier selection and fullscreen system-key controls
  with copied Apply/Cancel drafts, mask validation and routing reset. The expanded
  light/dark settings fixtures total 78; visually inspected `input-shortcuts-all.png`
  and `input-conflict-dark.png` under the normal build's `settings-render/` directory.
- Capture owns a session event tap and main-run-loop source, with no host pointer
  in the C callback. Permission preflight does not prompt. Focus loss, externally
  changed session focus, sleep, view-only, policy reset, disconnect, detach and
  close release resources. Explicit release suppresses automatic recapture until
  a later focus cycle. Automatic failures show recovery status and do not retry
  every frame; disabled taps release held input when detected on input/presentation
  updates. Backend/window injection verifies lifetime without global capture.
- The actual NSMenu popup targets the owning model, rechecks actions at dispatch,
  and retains its controller throughout tracking with `withExtendedLifetime`.
  It exposes desktop actions/settings/info/About and pauses remote focus while
  tracking. Swift strict diagnostics caught an initially temporary weak target
  and an unused popup result; both were corrected before final verification.
- Added generation-checked `InputQueue::releaseAll`, C `tidyvnc_session_release_input`
  and Swift `releaseInput`, preserving focus/policy while discarding queued input,
  releasing held keys and invalidating delayed middle-button routing. The additive
  feature bit is required by the native runtime; `nm` reports 60 exported ABI calls.
  Synthetic menu commands now use this barrier instead of a false/true focus cycle.
- Added twentieth suite `NativeShortcuts.AppKitDispatchAndCaptureLifetime`, using
  actual NSView events, a loopback peer, current layout candidates, an injected
  capture backend and a fullscreen window spy. It verifies dispatch, remote
  release, key-equivalent bypass without duplication, view-only, invalid/changed
  modifiers, capture failure/retry/revocation, focus/sleep/disconnect cleanup.
  Existing command tests also construct/invoke the real popup action. Candidate
  tests verify bounds/deduplication/special keys; router tests verify lazy lookup.
- Final full native **20/20 normal (14.34 s), 20/20 ASan (17.09 s), 20/20 TSan
  (61.01 s)** pass after the external-focus cleanup refinement. Final native app
  build, strict signature/designated requirement checks, branding audit (1650
  deferred entries) and `git diff --check` pass.
- Full portable runs exercised **630 headless / 646 retained-FLTK unit tests**.
  Each initially had one failure in the new test's post-close expectation:
  close advances generation, so an old request correctly returns StaleGeneration.
  Correcting that assertion yielded **1/1 targeted rerun** in each build; every
  other test passed initially. Both smoke suites pass **2/2**. Core protocol/ABI
  sanitizer subsets pass **59/59 ASan (1.55 s), 59/59 TSan (2.35 s)** and pure-C
  consumers **1/1** each. Initial sanitizer filters selected no tests; corrected
  filters with `--no-tests=error` produced the reported executed-test results.
- Logs: `/tmp/tidyvnc-live-native{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-live-{headless,fltk}-{build,unit,fix-build,fix-unit,smoke}.log`,
  `/tmp/tidyvnc-live-core-{asan,tsan}-{build,tests,c}.log`,
  `/tmp/tidyvnc-live-app-final-verified-build.log`,
  `/tmp/tidyvnc-live-app-signature.log`, `/tmp/tidyvnc-live-branding.log`.
  All final process handles collected with exit 0. macOS 27 arm64 / Swift 6.4 /
  SDK 27; existing newer-OS Homebrew and Xcode device/simulator warnings remain.
- User reports Mac unlocked. UI inventory succeeded, but selecting the running
  TidyVNC app failed with “Sky Computer Use native pipe closed before response.”
  No lock-state inference was made. No live app restart, actual global capture,
  production storage write, minimum-OS/universal or physical acceptance claim.

### 2026-09-19 — Input defaults/profile persistence and initial policy

- IDs / commit: completed persistence/source children under N4.6/N4.9 in the
  current working tree, no commit. N4.6/N4.9 remain open for interactive acceptance
  and broader settings coverage; the overall native migration is not complete.
- Added closed `NativeInputPreferences` patches for view-only, middle-button
  emulation, fullscreen capture, modifier mask and cursor fallback. Absence
  inherits fieldwise; zero explicitly disables shortcuts. Raw JSON inspection
  rejects unknown fields, nulls, Boolean/number coercion, fractional/negative/
  out-of-range masks and invalid cursor tokens before decode/write.
- App preference schema 3 reads schemas 1/2 without changing bytes; profile/history
  schema 2 reads schema 1 without changing bytes. Explicit accepted writes upgrade
  the schema and revision. Rejected/invalid/conflicting writes preserve data,
  history, credential references and the existing storage guarantees.
- App Settings now has an Input section. Saved Profiles can inherit or override
  input fields with effective inherited values and an all-input reset action.
  Both reuse copied drafts, Cancel, explicit Apply/Save, and revision-conflict
  gates. Live Input Settings labels compiled/app/profile/session sources; applying
  changed fields preserves the source of untouched fields and writes no store.
- App/profile patches resolve into initial session configuration before a session
  is published. The checked C input-policy call installs saved view-only/emulation
  before Connect; initial cursor/modifier/capture values also reach bare native
  desktops and connection input state. Subsequent saved changes affect newly
  created windows only. Reconnect retains the existing session's live policy.
- NativeSession retains current source metadata for the two mutable core-policy
  fields. A final refinement ensures a late-bound input state keeps live override
  provenance even when the value returns to its original default. Invalid host
  masks are rejected before allocating a session handle.
- Added twenty-first suite `NativeInput.PersistenceAndInitialPolicy`: legacy-byte
  preservation, explicit upgrades, all-field roundtrips including zero masks,
  all 16 supported masks, strict invalid records and write preservation,
  pre-connect policy, loopback view-only rejection, actual ConnectionModel
  app/profile precedence and fieldwise sources, live/save/new-window isolation,
  reconnect, draft cancellation/correctable validation, profile editing and
  invalid configuration without consuming session capacity.
- Eight additional defaults fixtures bring rendered settings/info coverage to
  **86 fixtures**. Inspected light/dark input overrides/conflict, profile inheritance
  and live source labels. Representative files in the normal `settings-render/`:
  `preferences-input-overrides-dark.png`, `preferences-input-conflict-dark.png`,
  `profiles-editing.png`, `input-conflict-dark.png`. Distinct preferences-prefixed
  names prevent collisions with live-sheet fixtures. These are owned unshown
  SwiftUI renders, not live keyboard/VoiceOver/physical acceptance.
- Full native **21/21 normal (17.33 s), 21/21 ASan (20.03 s), 21/21 TSan
  (65.75 s)** pass. After the final source-lifetime refinement, focused input/
  preferences/profile suites pass **4/4 normal (0.76 s), 4/4 ASan (0.97 s),
  4/4 TSan (9.32 s)**. Final native app build and strict signature/designated
  requirement checks pass. Branding audit passes with 1650 deferred entries;
  `git diff --check` passes. No portable-core/ABI/retained-frontend production
  source changed this increment; prior portable regression evidence remains valid.
- Logs: `/tmp/tidyvnc-input-persistence{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-input-persistence-source{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-input-persistence-final-app-{build,signature}.log`, and
  `/tmp/tidyvnc-input-persistence-branding.log`. All final process handles collected
  with exit 0. macOS 27 arm64 / Swift 6.4 / SDK 27. Existing Homebrew newer-OS and
  Xcode device/simulator warnings remain; no minimum-OS/universal/performance
  claim. No production preference/profile writes, live app restart or global
  keyboard capture occurred. The goal remains active for the remaining plan.

### 2026-09-19 — Scaling defaults/profile persistence and first-frame installation

- IDs / commit: completed persistence/source children under N4.7/N4.9 in the
  current working tree, no commit. N4.7 remains open for accessible panning and
  keyboard/VoiceOver acceptance; N4.9 and the full migration retain broader gates.
- Added `NativeScalingPreferences` with optional sizing text, logical/device units
  and stable nearest/bilinear/area tokens. Sizing validation and canonicalization
  use the existing shared parser for all eight modes. Absent fields inherit;
  explicit commits/profile upserts canonicalize only present sizing text. Reads
  preserve original bytes, including valid noncanonical values, and history-only
  mutations preserve profile settings.
- App schema 4 reads schemas 1–3; profile/history schema 3 reads 1–2. Explicit
  accepted writes upgrade schema/revision. Unknown/null/wrong-type fields, invalid
  dimensions/percentages/precision and invalid filter tokens are rejected without
  overwriting saved data. Existing store limits, conflict and cancellation rules
  are retained; earlier encoding/input tests were updated for the current writer
  version while retaining their legacy-version input fixtures.
- Connection Defaults and Saved Profiles expose all eight mode presets, custom
  text, units, filters, inherited values and per-field/all-scaling resets. Invalid
  sizing disables Apply/Save and explains valid ranges inline. Canonical accepted
  preference results reconcile the draft only if its values still equal the
  submitted snapshot; later edits remain intact. Profile saves reconcile through
  the existing committed-baseline path. Cancel remains a copied-draft operation.
- Initial resolved scaling and source values are copied into NativeSession before
  publication. Explicit configuration is installed in NativeDesktopView before
  frame subscriptions; absence preserves a host's explicit pre-bind filter/etc.
  Connection scaling state weakly binds once per session and preserves live values
  on repeated bind/reconnect. A live apply marks only changed fields as session
  overrides and writes neither defaults nor profiles. Later saved changes affect
  newly opened windows only; geometry preflight/fallback stays in the renderer.
- Added twenty-second suite `NativeScaling.PersistenceAndInitialGeometry`: all
  eight modes × three filters, canonical save/reopen, legacy read preservation,
  absent units, strict invalid records and rejected-write preservation, stale
  profiles, invalid Apply/Save gating, canonical draft reconciliation, actual
  ConnectionModel initial values, first loopback frame geometry, fieldwise source
  labels, filter-only source preservation, live/new-session isolation, reconnect,
  profile editing/cancellation and canonical profile baseline.
- Ten new light/dark fixtures bring the settings/info total to **96**. Visually
  inspected `preferences-scaling-invalid.png`,
  `preferences-scaling-custom-dark.png` and `profiles-scaling.png` under
  `build/native-ui-swift/tests/macos/settings-render/`. Existing live-scaling
  fixtures also render the new source labels. These are owned unshown views;
  no physical display/Spaces/VoiceOver acceptance is inferred.
- Full native **22/22 normal (18.97 s), 22/22 ASan (22.37 s), 22/22 TSan
  (70.46 s)** pass. Native app build and strict signature/designated requirement
  checks pass. Branding audit passes with 1650 deferred entries; `git diff --check`
  passes. No portable-core, C ABI or retained-frontend production source changed;
  prior portable regression evidence remains applicable.
- Logs: `/tmp/tidyvnc-scaling-persistence{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-scaling-persistence-app-{build,signature}.log`, and
  `/tmp/tidyvnc-scaling-persistence-branding.log`. All final process handles
  collected with exit 0. macOS 27 arm64 / Swift 6.4 / SDK 27. Existing Homebrew
  newer-OS and Xcode device/simulator warnings remain; no minimum-OS/universal/
  performance claim. Tests used memory stores and loopback peers. No production
  defaults/profile writes, live app restart or global capture occurred.

### 2026-09-19 — Accessible desktop panning (N4.7 portion)

- IDs / commit: completed the menu/accessibility pan-controls child under N4.7
  in the current working tree, no commit. Full interactive keyboard/VoiceOver,
  physical display/Spaces and the broader native migration remain open.
- Connection, toolbar and native context menus expose Pan Desktop with left,
  right, up, down and Return to Top Left. Available directions are also native
  accessibility custom actions on the desktop. Actions move 80% of the viewport
  in selected logical/device units, stop at edges and work in view-only mode
  without acquiring remote focus. Ordinary remote wheel routing is unchanged.
- Pan stays view-local. Shared geometry dimensions and rounded canvas determine
  limits; stored offsets clamp after viewport/remote-size/backing changes, reset
  for new streams/generations or mode/units changes, and survive filter-only Apply.
  Pending moves advance desired geometry, while pointer coordinates continue to
  use displayed geometry until matching pixels arrive through the existing
  bounded renderer. Hidden/disconnected/closing/detached targets reject dispatch.
- Added twenty-third suite `NativeDesktop.AccessiblePanning`: all eight scaling
  modes, fractional backing scales, logical/device limits, actual NSMenu and
  accessibility-selector dispatch, edge gates, view-only/no-focus behavior,
  delayed rendering with real loopback pointer coordinates before/after pan,
  filter preservation, independent views, viewport/server resize, reconnect and
  weak cleanup. Existing scaling test now expects an out-of-range offset on a
  smaller-than-viewport image to clamp to zero; genuine overflowing filter-only
  pan preservation is covered by the new suite.
- Initial test compilation found an optional selector and incorrect cleanup
  method name; corrected before execution. The immediate view-release assertion
  was refined to await AppKit's deferred cleanup, and session-close assertions
  await its asynchronous closing flag. Final focused panning passes 1/1 (0.40 s).
- Full native **23/23 normal (19.36 s), 23/23 ASan (22.85 s), 23/23 TSan
  (73.66 s)** pass. Native app build and strict signature/designated requirement
  checks pass. Branding audit passes with 1650 deferred entries; `git diff --check`
  passes. No portable-core/C ABI/retained-FLTK production source changed in this
  increment; earlier portable regression evidence remains applicable.
- Logs: `/tmp/tidyvnc-panning{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-panning-focused-{build,tests}.log`,
  `/tmp/tidyvnc-panning-app-{build,signature}.log`, and
  `/tmp/tidyvnc-panning-branding.log`. All process handles collected with exit 0
  for final verification. macOS 27 arm64 / Swift 6.4 / SDK 27; existing newer-OS
  Homebrew and Xcode device/simulator warnings remain. No minimum-OS/universal/
  performance claim or production storage write.
- The user reports the Mac unlocked. UI inventory succeeded; selecting TidyVNC
  again failed with “Sky Computer Use native pipe closed before response.” No
  lock-state inference, live app restart, physical keyboard/VoiceOver acceptance
  or global keyboard capture is claimed. Tests use owned unshown AppKit windows,
  in-memory preferences and loopback peers.

### 2026-09-19 — Fullscreen minimize sequencing and input lifetime (N4.10 portion)

- IDs / commit: completed the fullscreen-minimize implementation child under
  N4.10 in the current working tree; no commit. Physical fullscreen/Spaces/Dock,
  multiple displays, complete negotiated information and interactive acceptance
  remain open. The full native migration goal remains active.
- Minimize now releases capture, remote focus/held input and local input state,
  exits fullscreen, waits for the owning window's exit notification, requests
  minimize and waits for completion. Duplicate/conflicting commands are disabled
  while pending. Windowed minimize uses the same completion/lifetime gate.
- The operation stores weak window/host references and session generation, with
  one identity-checked cancellable 15-second deadline. Missing completion clears
  the gate and shows retry guidance; there is no automatic retry. Late or foreign
  notifications cannot complete an invalidated request. Detach, host replacement,
  rebind, disconnect, session/window close, reverse fullscreen entry and a sheet
  appearing before minimize cancel the intent. SwiftUI's delegate is untouched.
- Native desktop focus and capture callbacks remain gated throughout the pending
  operation. Final review also added guards before pointer/wheel/key/modifier/IME
  state mutation, preventing delayed input from accumulating for restoration even
  if an external caller temporarily restores core focus. Deinit cancels deadline
  and existing modifier-recovery tasks; captures/observers do not retain the owner.
- Extended `NativeCommands.RoutingAndModifierLifetime` with AppKit window spies,
  real loopback held-key release, exit/minimize ordering, duplicate/foreign/late
  notifications, timeout/retry, sheets, rebind/disconnect/close and weak lifetime.
  Extended `NativeShortcuts.AppKitDispatchAndCaptureLifetime` with actual desktop
  callbacks and injected capture: no focus/capture reacquisition or pointer/key/
  IME wire input during minimize, and recovery after completion. No global input
  capture or physical window transition was used in tests.
- Full native **23/23 normal (18.54 s), 23/23 ASan (22.66 s), 23/23 TSan
  (73.63 s)** pass. After the final input-entry guards, affected command/shortcut/
  desktop/input/panning suites pass **5/5 normal (1.48 s), 5/5 ASan (1.84 s),
  5/5 TSan (13.55 s)**. Final native app build, strict signature/designated
  requirement, branding audit (1650 deferred) and `git diff --check` pass.
- Logs: `/tmp/tidyvnc-minimize{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-minimize-final{,-asan,-tsan}-full-{build,tests}.log` (the latter
  runs five focused suites), `/tmp/tidyvnc-minimize-final-app-{build,signature}.log`,
  and `/tmp/tidyvnc-minimize-branding.log`. Final process handles collected with
  exit 0. macOS 27 arm64 / Swift 6.4 / SDK 27; existing newer-OS Homebrew and
  Xcode warnings remain. No portable core/ABI/FLTK production changes, production
  preference/profile writes, live app restart, minimum-OS/universal/performance
  or physical interactive acceptance claim.

### 2026-09-19 — Negotiated connection information and Swift C-import dependencies

- IDs / commit: completed information-sheet children under N4.10/N4.12 in the
  current working tree, no commit. N4.12 remains open for a stats overlay, broader
  metrics and interactive acceptance. Full native migration remains incomplete.
- Added immutable, fixed-size core SessionInformation observations: bounded
  desktop name, RFB protocol, negotiated security method, current wire pixel
  format, requested encoding, last received non-CopyRect encoding and the existing
  bandwidth estimate. Name scanning/copying is limited to 1024 content bytes plus
  NUL, with explicit truncation. Metadata clears on teardown/new attempt; retained
  observations remain owned. Live encoding changes reuse the statistics deadline
  to publish requested policy even without a new framebuffer update.
- Added `tidyvnc_session_information` and its required capability. The query copies
  one connected observation and its matching snapshot/counters, checks generation,
  validates headers/handles and preserves output on failures. Existing C layouts
  remain unchanged; there are now 61 exported ABI calls. No new handle or borrowed
  span is returned. The credential-security flag retains the existing policy's
  meaning and is not displayed as a blanket transport/identity assertion.
- Swift owns copied strings/values, replaces incomplete truncated UTF-8 safely,
  exposes a replaying information stream and clears current values across lifecycle
  changes. Metadata is nested in the same deduplicated NativeSnapshot as counters.
  The initial separate @Published property failed the existing presentation
  invalidation-budget test in all three builds; the implementation was corrected,
  preserving that test unchanged.
- The scrollable information sheet now covers the retained viewer's negotiated
  fields and distinguishes requested from last received encoding. Copy Diagnostics
  omits endpoint, desktop name, credentials, certificate material and paths; it
  uses only static descriptions and numeric fields. Automated tests do not invoke
  the general-pasteboard write. Inspected light/dark `connection-information.png`
  and `connection-information-dark.png` under the normal `settings-render/` tree.
  Existing settings/info fixture count remains 96.
- Core tests cover bounded names, initial/no-data values, immutable old records,
  CopyRect semantics and reconnect reset. C ABI tests cover actual loopback values,
  concurrent readers, generation/handle rejection and output preservation. Pure C
  tests cover capability, layout/header validation and disconnected behavior.
  Swift tests cover plain/VNC authentication metadata, copies after shutdown,
  reconnect, UTF-8 truncation, redaction and idle live-encoding publication.
- A normal bridge test then reproduced a stale C-import layout crash in an old
  consumer object: Ninja rebuilt TidyVNCNative but skipped NativeBridgeTests after
  the C record changed. Explicit recompilation of both eliminated the crash.
  CMake now watches ABI/keymap headers/module maps and propagates their content
  fingerprint as a public Swift compile option through the bridge, all consumers
  and the exported Xcode target. Verified the matching fingerprint in normal/
  ASan/TSan/app-core rules and exports, the Xcode project, and header-triggered
  CMake regeneration dependencies. Final full runs rebuild all Swift consumers.
- Final headless **632/632 unit (19.59 s), 2/2 smoke (0.45 s)**; retained FLTK
  **648/648 unit (22.25 s), 2/2 smoke (0.42 s)**. Protocol/ABI/events/worker
  subsets pass **116/116 ASan+UBSan (3.96 s), 116/116 TSan (5.55 s)** and pure-C
  **1/1** (0.23/0.22 s). Full native **23/23 normal (18.55 s), 23/23 ASan
  (22.77 s), 23/23 TSan (74.16 s)** pass. Final native app build and strict
  signature/designated requirement pass. Branding audit passes (1650 deferred);
  `git diff --check` passes.
- Other setup corrections: a new assertion initially expected `Raw` rather than
  the core's `raw` display name; sanitizer scripts initially requested a TLS target
  absent from those configured builds. Both were corrected before final runs.
  Normal headless/FLTK suites include their configured authentication/TLS tests;
  no unsupported sanitizer target execution is claimed.
- Logs: `/tmp/tidyvnc-info-core-final-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
  `/tmp/tidyvnc-info-native-verified{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-info-verified-app-{build,signature}.log`, and
  `/tmp/tidyvnc-info-branding.log`. Observation/crash investigation:
  `/tmp/tidyvnc-info-observation-{build,tests}.log`,
  `/tmp/tidyvnc-info-recompile-{build,tests}.log`. All final handles exit 0.
  macOS 27 arm64 / Swift 6.4 / SDK 27. Existing newer-OS Homebrew and Xcode
  warnings remain. No production storage/pasteboard writes, live app restart,
  physical keyboard/VoiceOver, minimum-OS/universal or performance acceptance claim.

### N4.12 connection statistics overlay evidence (2026-09-19)

- Current working tree, no commit. Added a passive per-connection statistics
  overlay with dimensions, received frames, last encoding, line-speed estimate,
  RFB version and security method. Connection menu, toolbar actions and native
  desktop menu expose the same checked Show Connection Statistics action.
- Visibility belongs to ConnectionModel, resets on disconnect/reconnect/close,
  supports view-only mode and rechecks stale menu invocations. An already visible
  overlay can be hidden while busy. It receives the existing sampled immutable
  information value; no timer, observer, task, per-frame update or C ABI change.
  Overlay placement preserves desktop layout and pointer/keyboard routing.
- Extended the real-loopback command test for idle/busy/view-only gating, menu
  dispatch/checked state, separate-model isolation, stale menu use, reconnection
  and immediate close cleanup. Four new render fixtures cover 320/640-point
  widths in light/dark appearances. Narrow light/dark PNGs visually inspected:
  `build/native-ui-swift/tests/macos/settings-render/connection-statistics-320{,-dark}.png`.
- Focused command/render suite **2/2 (12.51 s)**. Full native suites **23/23
  normal (19.33 s), ASan (23.68 s), TSan (74.39 s)**; all final process handles
  exit 0. Existing presentation invalidation/input/lifetime checks remain passing.
  Native Xcode app build, strict code signature/designated requirement, branding
  audit (1650 deferred occurrences), and `git diff --check` pass.
- Logs: `/tmp/tidyvnc-overlay-focused-{build,tests}.log`,
  `/tmp/tidyvnc-overlay-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-overlay-app-{build,signature}.log`,
  `/tmp/tidyvnc-overlay-branding.log`. macOS 27 arm64 / Swift 6.4 / SDK 27;
  existing newer-OS Homebrew and Xcode warnings remain. Core/C ABI unchanged;
  preceding portable verification remains applicable.
- Mac app inventory succeeded; selecting the running TidyVNC app failed with
  `Sky Computer Use native pipe closed before response`. This is a connector
  failure, not evidence of a locked Mac. No live app restart, production settings
  or clipboard write, physical interaction, VoiceOver, minimum-OS, universal or
  performance acceptance claim. Broader metrics and interactive N4.12 gates remain.

### N4.13 structured connection errors and retry evidence (2026-09-19)

- Current working tree, no commit. Added NativeConnectionIssue's typed, fixed-text
  classification of terminal reasons, command outcomes and ABI statuses. DNS,
  refused service, routing, timeouts, suspected network policy, authentication,
  protocol, resource and unsupported failures have distinct recovery guidance.
  Socket errno interpretation is limited to connection/transport errors; DNS
  native codes cannot imply privacy denial. Unknown/raw error descriptions are
  omitted, including inline authentication reply failures.
- ConnectionModel now observes unexpected terminal snapshots after a successful
  connection and deduplicates errors by generation. Cancel/requested disconnect
  stay silent. Retry uses the existing Connect path with problem UUID, generation,
  unchanged endpoint, ready/default state and busy/close guards. No automatic
  reconnect or credential retention. SwiftUI presentation hiding is separate from
  Cancel's retry revocation so a button can run after automatic alert dismissal;
  late callbacks cannot affect newer errors. Close clears retry/endpoint state.
- Added NativeConnection.ErrorsAndRetry: all terminal categories, socket/DNS error
  code scope, redaction, cancellation and operation outcomes; real loopback refused
  connections, exactly one new generation per explicit retry, changed address,
  stale callbacks, separate-window isolation, unexpected peer closure, silent
  authentication cancellation/requested disconnect and immediate close cleanup.
- Initial test fixture held a bound non-listening TCP socket, which macOS treated
  as a timeout. Corrected it to the existing SocketConnector closed-port fixture
  pattern; the implementation correctly classified both observed outcomes. Final
  focused **1/1 (0.26 s)**. Full native **24/24 normal (19.96 s), ASan (23.95 s),
  TSan (76.64 s)**. Native app build, strict signature/designated requirement,
  branding audit (1650 deferred occurrences) and `git diff --check` pass.
- Logs: `/tmp/tidyvnc-errors-focused-{build,tests}.log`,
  `/tmp/tidyvnc-errors-debug-{build,tests}.log`,
  `/tmp/tidyvnc-errors-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-errors-app-{build,signature}.log`,
  `/tmp/tidyvnc-errors-branding.log`. All final process handles exit 0.
  macOS 27 arm64 / Swift 6.4 / SDK 27. Existing newer-OS dependency/Xcode warnings
  remain. No portable/C ABI changes, production settings/clipboard writes, live
  app restart or privacy-settings changes. Interactive alert focus, keyboard,
  VoiceOver, localization and minimum-OS/universal acceptance remain open. Latest
  UI connector failure is documented separately; the Mac is not presumed locked.

### N3.8 canonical credential identity and authentication context evidence (2026-09-19)

- Current working tree, no commit. Completed the credential-key identity contract:
  shared-parser canonical endpoint/port/transport and exact scope/path/route,
  negotiated security type, password-only versus username/password shape and exact
  username bytes. App-scoped versioned SHA-256 over length-prefixed fields yields
  an opaque account; the key retains no original endpoint/route/user or password.
  No DNS lookup, alias merging, Unicode normalization or tunnel-target inference.
- Added owned endpoint create/get C APIs and required capability. Immutable spans
  are consumed only while a typed reference is retained. Input/route UTF-8 and
  4096-byte bounds, output preservation, kind/released-handle checks, concurrent
  reads and retention independent of caller buffers are covered. ABI exports: 63.
- Native tests pin an independently calculated digest and cover IPv6 spelling/
  scope, aliases/trailing dots, mapped IPv4, Unix path/case/relative distinctions,
  route/tunnel identity, auth/user scope, framed-field collisions, byte-distinct
  Unicode, empty password-only user, bounds, invalid/NUL text and concurrent keys.
- Corrected authentication security wording: the core isSecure flag is a credential
  protection policy, not proof of whole-connection encryption. Four new light/dark
  fixtures cover protected/unassured policy and optional username. Inspected
  `build/native-ui-swift/tests/macos/settings-render/authentication-credentials-unassured.png`
  and `authentication-credentials-protected-dark.png`; long endpoint wraps without
  clipping. No live credential entry, save or clipboard operation was performed.
- Setup failures resolved: Swift rejected the initial 4097-byte fixed C arrays;
  final API uses the established owned-handle/spans contract without reducing
  limits. Strict compilation required discarding an intermediate call result.
  Render tests needed an internal prompt-value fixture initializer and exposed
  SDK 27 State macro selection unavailable in CLT; a private typealias selects
  the existing macOS 14 State property wrapper. Early fixture builds failed;
  final full builds/tests below replace those results.
- Final headless **633/633 unit (20.22 s), 2/2 smoke (0.58 s)**; retained FLTK
  **649/649 unit (23.26 s), 2/2 smoke (0.43 s)**. Core protocol/ABI/events/worker
  subsets **117/117 ASan+UBSan (4.01 s), TSan (5.52 s)** and pure C **1/1**
  (0.23/0.22 s). Full native **25/25 normal (20.79 s), ASan (24.75 s)** and
  **25/25 TSan (80.01 s)** pass. Final native app build, strict signature/designated
  requirement, branding audit (1650 deferred occurrences) and `git diff --check`
  pass. All final driver handles exit 0.
- Logs: `/tmp/tidyvnc-key-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
  `/tmp/tidyvnc-key-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-key-app-{build,signature}.log`, `/tmp/tidyvnc-key-branding.log`.
  macOS 27 arm64 / Swift 6.4 / SDK 27; existing newer-OS Homebrew/Xcode warnings
  remain. No Keychain lookup/save/delete, credential reuse/retention, trust policy
  change, production storage write, live app restart, interactive VoiceOver or
  minimum-OS/universal acceptance is claimed. N3.9–N3.14 and full N4.2 stay open.

### N0.9 / N3.9 Keychain policy and store foundation evidence (2026-09-19)

- Current working tree, no commit. Recorded the Data Protection Keychain decision
  and signing prerequisites in [KEYCHAIN.md](KEYCHAIN.md). Added scoped SecItem
  lookup/create/replace/delete and bounded attributes-only metadata queries, fresh
  per-operation interaction contexts and typed OS outcomes. No upsert, automatic
  deletion, global interaction switch or plaintext fallback.
- Added a bounded actor-owned serial utility queue with cancellation before
  execution, actual committed results after execution starts and shared joined
  close. A final queue barrier ensures backend closures release their captures
  before close completes. Owned secret buffers clear consumed input and their own
  allocation; descriptions are redacted and runtime-copy limitations explicit.
- Injected-client tests cover query/interaction policy, status mapping, malformed
  results, create/replace distinction, metadata bounds, secret clearing, queue
  saturation, MainActor responsiveness, cancellation and concurrent close. Initial
  compile and LAContext fixture failures were resolved: account-prefix validation
  uses starts(with:), and interaction policy is captured at the call boundary
  before LAContext invalidation resets it.
- Full native suite before the final queue barrier: **26/26 normal (20.57 s),
  ASan (24.40 s), TSan (82.04 s)**. After that change, credential identity/store
  tests: **2/2 normal (0.24 s), ASan (0.60 s), TSan (4.43 s)**. Final app rebuild,
  strict signature/designated requirement, branding audit (1650 deferred
  occurrences) and `git diff --check` pass. All final process handles exit 0.
- Logs: `/tmp/tidyvnc-keychain-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-keychain-final{,-asan,-tsan}-{build,tests}.log`,
  `/tmp/tidyvnc-keychain-final-app-build.log`. macOS 27 arm64 / Swift 6.4 / SDK 27;
  existing dependency deployment-target and Xcode warnings remain. Core/C ABI
  unchanged; preceding portable evidence remains applicable.
- Tests used injected backends; no real Keychain entries were accessed. Final
  Debug entitlement inspection still shows get-task-allow only. Provisioned app
  access, upgrade continuity and real OS interaction remain N3.14/N6.9. The store
  is not yet wired into authentication: use-once/session/remember, post-success
  save, rejected-secret recovery, trust-gated reuse and full retention lifetime
  remain open. N3.9 and N3.13 parent items remain unchecked.

### N3.10 / N3.11 / N4.2 authentication retention integration evidence (2026-09-20)

- Current working tree, no commit. Added per-window NativeAuthenticationCredentials
  and app-owned shared store integration. UI defaults to Use once and offers
  session reconnect retention or Remember on this Mac, explicit replacement,
  Use Saved/Session Password and exact-key Forget. Secrets stay private; published
  state contains only status/availability. Username must be re-entered where the
  method requires it; explicit reuse validates the current prompt-derived key.
- Added PROMPT_SECURITY capability and tidyvnc_prompt_security_type (64 exports).
  The protocol worker captures the negotiated type/subtype at the credential
  rendezvous. Existing prompt-info layout and legacy authentication adapters are
  preserved. Native prompt values carry the method needed for credential identity;
  VNC/X509Vnc socket tests verify it, and pure-C/typed tests verify failure outputs.
- Retention becomes eligible only after the matching generation connects. Save or
  explicit replacement then runs once without OS interaction; failure is a separate
  redacted notice and leaves the connection alive. Stored lookup/Forget are explicit
  user actions allowing interaction. Rejected saved secrets neither retry nor delete
  themselves. Session values survive unexpected interruption for explicit reconnect
  but cancel/disconnect/rejection/close clear them. Epoch/prompt/generation guards
  discard late results. Close joins an already running save without wiping its
  buffer underneath the backend or resurrecting UI after completion.
- New NativeCredentials.AuthenticationRetention uses a reusable loopback VNC peer
  and injected vault. Covers all lifetimes, actual rejected authentication, delayed
  server success (no early save), explicit saved reuse and session reuse, duplicate
  create, explicit replacement/Forget, missing-entitlement save failure, isolated
  windows, delayed lookup cancellation, stale reply input wiping and window close
  during a blocked committed save. No real Keychain reads or writes were performed.
- Eight authentication render fixtures cover light/dark, password-only/username,
  use-once and remember controls. Inspected
  `build/native-ui-swift/tests/macos/settings-render/authentication-credentials-unassured.png`
  and `authentication-remember-protected-dark.png`; text and controls fit without
  clipping. Final focused lifecycle/render tests **2/2 (13.08 s)**.
- Resolved verification setup failures: initial native command named a nonexistent
  render target; corrected to native-settings-tests. The new wrong-kind ABI test
  expected InvalidHandle but the established contract returns WrongHandleType;
  corrected test expectation. Sanitizer core configurations disable GnuTLS and do
  not have authenticationsocket; corrected target selection, retaining VNC/X509Vnc
  coverage in both full normal builds. No implementation failure was suppressed.
- Final headless **633/633 unit (19.96 s), 2/2 smoke (0.37 s)**; retained FLTK
  **649/649 unit (22.12 s), 2/2 smoke (0.29 s)**. Core protocol/ABI/events/worker
  subsets **117/117 ASan+UBSan (3.92 s), TSan (5.75 s)**; pure-C **1/1** in each
  (0.44/0.23 s). Full native **27/27 normal (20.37 s), ASan (25.82 s), TSan
  (84.78 s)** after final lifetime changes. A subsequent layout-only adjustment
  places the optional session-password action on a separate row; final render
  **1/1 (12.56 s)** and app rebuild pass. Final strict signature/designated requirement,
  branding audit (1650 deferred occurrences) and git diff check pass.
  All final process handles collected with exit 0.
- Logs: `/tmp/tidyvnc-retention-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
  `/tmp/tidyvnc-retention-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-retention-final-focused-{build,tests}.log`,
  `/tmp/tidyvnc-retention-layout-{build,tests,app-build}.log`,
  `/tmp/tidyvnc-retention-final-signature.log`, `/tmp/tidyvnc-retention-branding.log`.
  macOS 27 arm64 / Swift 6.4 / SDK 27;
  existing newer-OS Homebrew dependency and Xcode warnings remain.
- Live app inventory succeeded, but selecting TidyVNC again failed with
  `Sky Computer Use native pipe closed before response`. No locked-Mac inference,
  live app restart or interactive acceptance claim. Real provisioned Keychain,
  OS prompt/upgrade behavior, ambiguous OS mutation reconciliation, full trust
  storage/context, physical keyboard/VoiceOver and minimum-OS/universal acceptance
  remain open. N3.10/N3.11/N4.2 parents stay unchecked pending those gates.

### N3.12 / N4.3 shared certificate policy and trust presentation evidence (2026-09-20)

- Current working tree, no commit. Inspection found the native reply path could
  approve certificate statuses that retained CConn rejects, and the native sheet
  mislabeled RSA-AES's truncated SHA-1 compatibility fingerprint as SHA-256.
  Added shared CertificatePolicy using the existing seven-bit exception mask;
  CConn and PromptAuthentication now use it. Revoked, signature, constraints,
  purpose, OCSP, critical-extension and unknown/new status bits stay fatal. Zero
  cannot authorize an exception. An affirmative forbidden reply returns
  PolicyRejected/Unsupported and leaves the prompt available for cancellation.
- Added CERTIFICATE_POLICY and the stateless policy query (65 C exports), stable
  reason flags, fatal-status bits and unchanged failure outputs. Swift requires
  the feature and copies typed policy values. Existing prompt layouts and TLS
  verification/CA/CRL behavior are unchanged. GnuTLS enum checks retain the existing
  header floor; newer diagnostic assertions are version-gated.
- Native trust details now include typed problems, subject, full attempted
  destination and SHA-256 over owned certificate/key bytes. The compatibility
  fingerprint has a separate correct label. Fatal/unknown/zero status and malformed
  DER disable approval; Cancel is the default trust action and Escape cancels.
  Connect Once explicitly applies only to this attempt. Descriptions redact
  identity material. No trust database reads/writes or system root installation.
- Core tests cover each status bit, mixed masks, forbidden/duplicate/stale replies
  and one-time acceptance. Pure-C covers the query and preserved outputs. Native
  tests cover all reasons, valid/malformed/bounded DER/key data, independent SHA-256
  goldens, algorithm distinction, redaction and concurrent classification. Existing
  VNC/X509Vnc socket tests continue to pass with trust-before-credentials ordering.
- Fourteen light/dark trust renders cover issuer, expiry/name, revoked, unknown,
  malformed, overflow and host-key states. Final layout uses a bounded scroll area
  with controls outside it; a content-sizing experiment was reverted after preview.
  Inspected original-resolution `settings-render/trust-revoked.png`, plus overflow
  and host-key variants under `build/native-ui-swift/tests/macos/`. Disabled fatal
  approval and visible controls/fingerprint labels were confirmed. Physical
  keyboard/VoiceOver and scrolling interaction remain separate acceptance gates.
- Full headless **636/636 unit (21.08 s), 2/2 smoke (0.32 s)**; FLTK **652/652 unit
  (23.10 s), 2/2 smoke (0.31 s)**. Core prompt/protocol/ABI/events/worker sanitizer
  subsets **134/134 ASan+UBSan (4.38 s), TSan (6.33 s)**; pure-C **1/1** in each
  (0.24/0.19 s). Full native **28/28 normal (24.54 s), ASan (27.90 s), TSan
  (89.49 s)**. After the final layout-only adjustment/overflow fixture, native
  render **1/1 (14.29 s)** and app rebuild pass. Strict signature/designated
  requirement, branding audit (1650 deferred occurrences) and git diff check pass.
  All final process handles collected with exit 0.
- Logs: `/tmp/tidyvnc-trust-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
  `/tmp/tidyvnc-trust-native{,-asan,-tsan}-full-{build,tests}.log`,
  `/tmp/tidyvnc-trust-final-layout-{build,tests}.log`,
  `/tmp/tidyvnc-trust-layout-app-build.log`, `/tmp/tidyvnc-trust-final-signature.log`,
  `/tmp/tidyvnc-trust-branding.log`. macOS 27 arm64 / Swift 6.4 / SDK 27; existing
  newer-OS dependency/Xcode warnings remain. No minimum-OS or universal claim.
- [TRUST.md](TRUST.md) records current legacy host-scoped x509_known_hosts behavior
  and remaining adapter/scoping work. Expected-versus-received identity comparison,
  changed-key and durable decisions, CA/CRL selection, real native TLS/key-sheet
  interaction and trust-store acceptance remain unfinished. N3.12/N4.3 stay open.

### Implementation evidence template

Copy for each completed subtask or phase:

- IDs / commit:
- Behavior delivered and affected interfaces:
- Tests/commands and results (including failures resolved):
- OS/hardware/toolchain/build configuration:
- Screenshots, benchmark data or artifacts:
- Remaining limitations / unchecked dependencies:


### N3.12 / N4.3 read-only legacy certificate trust evidence (2026-09-20)

Working-tree implementation; no commit created. See [TRUST.md](TRUST.md) for scope,
compatibility semantics and remaining durable-store work.

- Added optional exact DER SPKI/digest ownership in core/C ABI (68 exports), a
  bounded read-only g0/c0 adapter at the existing TidyVNC XDG state path, per-window
  generation-safe reuse and expected/received changed-key presentation. The adapter
  never mutates the trust file. Unknown/fatal certificate policy precedes lookup.
- Tests use public disposable certificate fixtures, independently extracted
  OpenSSL SPKI and CryptoKit hashes, actual temporary GnuTLS-written g0/c0 files,
  temporary unsafe files and injected delayed/error backends. No real user trust
  database, credential or root is read/modified by the tests. The new codec test
  exposed a CRLF grapheme parsing error; byte-delimited line parsing fixes it.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27 and macOS 14 deployment setting.
  Command Line Tools builds use `DEVELOPER_DIR=/Library/Developer/CommandLineTools`;
  `python3 apps/macos/build.py` uses the Xcode app toolchain.
- Full headless unit suite: **638/638 (19.56 s)** and viewer smoke **2/2 (0.27 s)**.
  Full retained FLTK suite: **654/654 (21.98 s)** and smoke **2/2 (0.38 s)**.
  Both include exact-key/digest and GnuTLS file-format compatibility tests.
- Core ASan+UBSan: **134/134 (4.22 s)**, pure C **1/1 (0.33 s)**.
  Core TSan: **134/134 (6.47 s)**, pure C **1/1 (0.21 s)**.
  Native suites: **29/29** normal **22.83 s**, ASan **28.04 s**, TSan **91.82 s**.
  Sanitizer configurations disable GnuTLS and test the explicit unavailable-key
  branch plus injected-key codec/controller coverage, not instrumented crypto.
- Final path-boundary/C ABI test additions were followed by native trust **2/2
  (0.28 s)**, pure C **1/1 (0.28 s)** and ASan trust **2/2 (0.30 s)**. TSan's full
  run includes those final native changes. Native testing includes cancelled/stale
  results, independent window policy, joined blocked-read close, missing/unsafe
  files, typed failures, exact host/port/wildcard/expiry compatibility and bounds.
- Built all native `native-*-tests` targets then ran `ctest --test-dir
  build/native-ui-swift{,-asan,-tsan}/tests/macos --no-tests=error
  --output-on-failure`. Core normal configurations used all build targets and all
  unit/viewer tests; sanitizer selections were PromptAuthentication, ProtocolSession,
  ViewerABI, SessionEvents and SessionWorker plus the pure-C smoke test.
- Eighteen light/dark trust renders now include four new changed-key/store-error
  detail fixtures. Inspected original-size changed-key light and store-error dark
  PNGs; expected/received fingerprints, reason text and failure messages wrap
  within the bounded content. This is render verification, not physical interaction.
- Native app build and `codesign --verify --deep --strict` pass. Existing newer-OS
  Homebrew dylib/deployment warnings, ad-hoc signing and Xcode ZERO_CHECK warning
  remain. No Intel/universal/minimum-OS execution or release signing is claimed.
- Unlocked-desktop interactive check: app inventory finds running TidyVNC, but
  native app selection fails with `Sky Computer Use native pipe closed before
  response`. This is a tool transport failure, not a lock-screen finding. No app
  restart, keyboard/VoiceOver acceptance or live TLS-sheet acceptance is claimed.
- Explicit durable add/remove/replace, revision/concurrent-writer recovery,
  dedicated host-key storage, CA/CRL controls and interactive acceptance remain
  unchecked. N3.12 and N4.3 remain open.

Logs: `/tmp/tidyvnc-legacy-trust-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-legacy-trust-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-legacy-final-{native,asan}-{build,tests}.log`,
`/tmp/tidyvnc-legacy-final-c-tests.log`, `/tmp/tidyvnc-legacy-trust-app-build.log`,
`/tmp/tidyvnc-legacy-trust-signature.log` and
`/tmp/tidyvnc-legacy-trust-branding.log`.

### N3.12 / N4.3 scoped certificate persistence evidence (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was verified
progress (legacy read-only trust integration). This step adds durable scoped
certificate decisions; the full native-UI goal remains active and incomplete.

- Added NativeTrustScope/NativeTrustStore with a closed versioned schema, canonical
  endpoint/route key, private dedicated XDG state file, bounded metadata and
  content-revision compare-and-replace. The unchanged legacy x509_known_hosts
  reader remains available only when no scoped decision exists. Forgotten scopes
  suppress broad legacy fallback; corrupt/inaccessible scoped state is not absent.
- Added explicit confirmed Save/Replace and Connect plus the Saved Certificate
  Decisions window's Forget/Ask Again actions. Ask Again supports a destination
  that has only a legacy exception. Management and per-window clients drain before
  shared-store close. A failed, uncertain, stale or cancelled save cannot approve
  another prompt or generation. Core fatal-status policy is checked before writing.
- NativePrivateFile selects fixed profile/trust record kinds with separate lock and
  temporary names. Existing profile behavior is covered by the full native suite.
  Trust writes keep 0600 records/0700 private subdirectory, nonblocking advisory
  lock, exact-byte revision comparison, file fsync, atomic rename and directory
  fsync. A post-rename failure reconciles bytes and reports uncertain durability;
  no automatic destructive retry or rollback is attempted.
- New NativeTrust.ScopedPersistenceAndRecovery covers an independent Python hash
  golden, canonical port/route/IPv6/Unicode isolation, durable add/replace/forget,
  private file/XDG paths, separate profile records, wrong/future schema preservation,
  scope-label validation, content revisions, capacity, independent-writer contention,
  pre/post-rename errors, cancellation boundaries, joined close during writes,
  management removal, legacy-only suppression, fatal policy, stale saves and
  unreadable-scoped-store precedence. Certificate key material and prompt targets
  are injected here; the separate normal NativeTrust.LegacyStoreAndDecisions suite
  continues to check actual GnuTLS extraction against independent OpenSSL SPKI.
- Added eight light/dark renders: scoped add/replace/forgotten trust sheets and the
  management window. Inspected original-size replace/light and management/dark
  PNGs. The bounded scroll area wraps long fingerprints; persistent actions and
  Cancel/Connect Once remain outside it. Confirmation controls compile, but physical
  Return/Escape/VoiceOver behavior remains an acceptance gate.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14.
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build
  build/native-ui-swift{,-asan,-tsan} --target <all native-*-tests> --parallel 2`
  then `ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`:
  **30/30 normal (24.30 s), 30/30 ASan (28.60 s), 30/30 TSan (94.85 s)**.
  Sanitizer builds disable GnuTLS and exercise the unsupported-key branch plus
  injected-key persistence/controller tests. They do not instrument real crypto.
- `python3 apps/macos/build.py`, `codesign --verify --deep --strict --verbose=2
  build/native-app/app/Debug/TidyVNC.app`, branding ledger/attribution audit and
  `git diff --check` pass. Branding has 1650 pre-existing deferred occurrences.
  Existing newer-OS Homebrew dependency warnings, Xcode ZERO_CHECK warning and
  ad-hoc signing limitations remain. No minimum-OS/Intel/universal/release-signing
  execution claim is made. Core/FLTK source and ABI are unchanged in this step;
  their previous evidence is not presented as a fresh run.
- Interactive probe still returns `Sky Computer Use native pipe closed before
  response` on native app selection. This is not a lock-screen finding. No app
  restart or user trust-state mutation was performed for validation. Live native
  TLS persistence, physical confirmation/VoiceOver, RSA-AES host-key persistence
  and CA/CRL controls remain open; N3.12 and N4.3 are not complete.

Logs: `/tmp/tidyvnc-scoped-trust-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-scoped-trust-expanded-{build,tests}.log`,
`/tmp/tidyvnc-scoped-trust-app-build.log`,
`/tmp/tidyvnc-scoped-trust-signature.log` and
`/tmp/tidyvnc-scoped-trust-branding.log`.

### N3.12 / N4.3 RSA-AES host-key persistence evidence (2026-09-20)

Working-tree implementation; no commit created. Dedicated host-key decisions now
use a separate RSA-AES domain, closed schema and private `server-keys.json` file.
Certificate scope hashes and the existing certificate file format are unchanged.

- Added shared allocation-free RSA-AES encoding validation, a checked C export
  and negotiated feature, native typed key ownership, independent SHA-256 and
  compatibility SHA-1 fingerprints. Malformed affirmative replies remain pending
  and cancellable. Protocol validation runs before trust presentation. Byte-rounded
  bit declarations used by the retained server remain accepted; the helper returns
  the actual modulus bit count. Structural validation does not prove key possession.
- Added scoped save/replace/forget and the Saved Server Keys management window,
  reusing atomic revision checks, bounded private storage and joined cancellation.
  Host keys never consult certificate exceptions or the legacy X509 file. Tests
  cover type/domain/port/route isolation, corrupt records, changed keys, stale
  writes, controller recovery, management and no legacy fallback.
- An independent public-key fixture supplies fingerprint goldens. Real loopback
  tests cover RA2, RA2ne, RA256 and RAne256 through owned trust prompts and joined
  rejection, plus malformed wire keys rejected before prompting. Completed RSA
  encryption/authentication and physical native acceptance remain open.
- Headless **642/642 (19.74 s)**, smoke **2/2 (0.41 s)**; retained FLTK
  **658/658 (22.63 s)**, smoke **2/2 (0.39 s)**. Core ASan/UBSan **137/137
  (4.55 s)** plus pure C **1/1 (0.31 s)**; TSan **137/137 (6.73 s)** plus pure C
  **1/1 (0.22 s)**. Native **31/31** normal **24.83 s**, ASan **32.12 s**, TSan
  **99.09 s**. All processes completed successfully. Sanitizer crypto limitations
  from earlier entries still apply; raw RSA encoding validation needs no crypto.
- Headless and native normal/ASan broad runs preceded the final byte-rounded
  declaration compatibility fix. FLTK/core sanitizer/native TSan runs include it.
  Final rebuilt native trust checks passed **4/4 (0.83 s)** normal and **4/4
  (1.08 s)** ASan; rebuilt pure C passed **1/1 (0.40 s)**.
- Eight added light/dark host-key fixtures bring trust renders to 34. Inspected
  original-size replacement/dark and management/light PNGs; fitting checks pass.
  Native app rebuild, strict ad-hoc signature verification, branding/attribution
  audit and whitespace check pass. The bridge now exports 69 C functions.
- The native computer-use probe still fails with `Sky Computer Use native pipe
  closed before response`. This is a transport failure, not a locked-Mac finding.
  No physical interaction, VoiceOver, release signing or minimum-OS execution is
  claimed. CA/CRL controls and full native security acceptance remain open.

Logs: `/tmp/tidyvnc-hostkey-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-hostkey-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-hostkey-final-{native,asan}-{build,tests}.log`,
`/tmp/tidyvnc-hostkey-final-c-tests.log`,
`/tmp/tidyvnc-hostkey-final-app-build.log`, `/tmp/tidyvnc-hostkey-signature.log`
and `/tmp/tidyvnc-hostkey-branding.log`.

### N3.12 / N4.5 explicit CA/CRL selections (2026-09-20)

Working-tree implementation; no commit created. Previous RSA-AES evidence is now
recorded above. This step adds CA/CRL configuration and required-file loading;
the complete native-UI goal remains active, with physical/security gates unchecked.

- Added closed NativeTrustFiles values and independent optional CA/CRL fields to
  defaults schema 5 and profile schema 4. Earlier versions remain readable without
  rewrite; only explicit writes upgrade. Exact absolute paths are bounded, NUL-free
  and validated without filesystem IO. Missing fields inherit; empty strings select
  no additional file. Corrupt/unknown/future records retain their bytes.
- Added Connection Defaults > Trust and saved-profile file controls with asynchronous
  native pickers, explicit None, inline validation and Apply/Save gating. Cancel
  keeps stored values. Paths resolve through app defaults then profile fields before
  constructing the session; existing windows retain their configuration. Picker
  results are guarded against dismissed views, changed contexts and changed drafts.
- The C bridge now enables ClientTLSOptions.requireConfiguredFiles, negotiated by
  REQUIRED_TLS_FILES (16777216), with no new C layout or export. Selected CA/CRL PEM
  files must load at least one matching object during X509 setup before prompts.
  Missing, empty, malformed and wrong-kind files fail. TLS-disabled builds reject
  explicit files at construction. Retained parameter consumers keep their historical
  warning-only load behavior. System trust and fatal certificate policy stay active.
- Added real loopback TLS tests with a private temporary CA and signed leaf: valid
  CA/CRL reaches credentials and Connected without an exception; revoked identity
  yields a non-approvable fatal prompt with cancellation; eight bad-file combinations
  fail before prompts. Native tests cover all prior schemas, typed/path bounds,
  preservation, inheritance, Apply/Cancel, profiles, new/existing-window isolation
  and unavailable crypto. Pure C covers feature, path ownership/admission and NUL/
  unsupported failures preserving the output handle. Fixtures install no roots or
  user trust records.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, configured deployment macOS 14.
  Headless **645/645 (19.68 s)**, smoke **2/2 (0.49 s)**. Retained FLTK
  **661/661 (22.37 s)**, smoke **2/2 (0.30 s)**. Core ASan+UBSan **137/137
  (4.25 s)** plus pure C **1/1 (0.25 s)**; TSan **137/137 (7.39 s)** plus
  pure C **1/1 (0.19 s)**. All configured native targets built and suites passed
  **32/32** normal **25.51 s**, ASan **34.80 s**, TSan **102.02 s**. Sanitizer
  builds disable GnuTLS; actual TLS CA/CRL checks run in normal headless/FLTK builds.
- Final test-only peer-drain assertions were followed by rebuilt authentication
  suites **28/28 headless (1.71 s)** and **28/28 FLTK (1.65 s)**. Final shorter
  validation wording was followed by rebuilt native rendering **1/1 (17.46 s)**.
  Six new light/dark renders cover inherited, selected and invalid file paths;
  inspected original-size selected/dark and invalid/light images, with fitting
  checks throughout. Physical picker interaction is not established by rendering.
- `python3 apps/macos/build.py`, strict deep ad-hoc signature verification,
  branding/attribution audit (1650 deferred occurrences) and `git diff --check`
  pass. Existing dependency deployment warnings and Xcode ZERO_CHECK warning remain;
  no minimum-OS/Intel/universal/release-signing execution is claimed.
- Native app selection still fails with `Sky Computer Use native pipe closed before
  response`; this is not a lock-screen finding. Physical picker/keyboard/VoiceOver,
  complete native TLS/RSA-AES acceptance and encryption/authentication settings remain
  open. General protocol-failure presentation is used for TLS file-load failures;
  finer errors remain in the error-catalog work. Paths are not content pins or
  persistent sandbox bookmarks. The native app remains unsandboxed.

Commands: build all native test targets using `DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`,
then `ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`.
Normal core builds ran all unit/viewer tests; core sanitizer selections were
PromptAuthentication, ProtocolSession, ViewerABI, SessionEvents and SessionWorker
plus the pure-C consumer.

Logs: `/tmp/tidyvnc-trustfiles-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-trustfiles-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-trustfiles-final-{headless,fltk,native}-{build,tests}.log`,
`/tmp/tidyvnc-trustfiles-app-build.log`, `/tmp/tidyvnc-trustfiles-signature.log`
and `/tmp/tidyvnc-trustfiles-branding.log`.

### N1.2 / N4.5 native security method selection (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was
verified progress (CA/CRL controls and required-file loading). This step adds exact
method selection and its shared schema; the full native-UI goal remains incomplete.

- Added shared SecuritySelection/catalog with canonical RFB names, 15 known methods,
  compiled availability and protection/credential metadata. Defaults read immutable
  SecurityClient::supportedTypes, independently of mutable legacy parameters.
  Parsing bounds text to 1024 bytes, rejects unknown/uncompiled methods and malformed
  tokens, canonicalizes case/duplicates and preserves explicit deny-all. A selection
  is an allow-list; server offer ordering and existing crypto/trust policies remain.
- Added two stateless checked C exports and SECURITY_SELECTION (33554432), fixed-size
  owned results and Security-domain errors. Existing layouts are unchanged; the
  static archive now has **71 tidyvnc exports**. Native wrappers own all data and
  require the feature. Unknown/uncompiled saved values never fall back silently.
- Defaults schema 6 and profile schema 5 read all earlier schemas without rewriting;
  explicit saves canonicalize security.types and retain revisions/recovery. Absent
  values inherit; explicit profiles replace the entire list instead of unioning it.
  Session construction captures exact IDs and source before connection. Subsequent
  defaults edits leave existing windows, including their reconnect policy, unchanged.
- Added Connection Defaults > Security method controls and the profile Security
  Methods disclosure, with unavailable choices, explicit inheritance, empty-list
  explanation and invalid Apply/Save gating. Certificate Files remains accessible
  from Security. Per-window reconnect editing and advanced TLS-priority controls
  remain open. Full contracts and proof boundaries are in [SECURITY.md](SECURITY.md).
- Core tests cover compiled-catalog parity, invalid/bounded/canonical selections,
  concurrent reads, independence from modified legacy parameters, and independent
  RFB 3.3/3.8/VeNCrypt offer fixtures preserving server order and denying disabled
  methods. Pure-C tests cover feature, catalog, defaults, headers, bounds, unavailable
  methods, deny-all and unchanged failure outputs. Native tests cover every prior
  schema, strict records, preservation, Apply/Cancel, exact source precedence and two
  independent real loopback sessions: a VncAuth-only default rejects a None-only
  peer while a None-only profile connects. A later empty-list save affects only a
  new window. This is not full native TLS/RSA-AES/DH/MSLogonII authentication proof.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14. Headless
  **649/649 (20.13 s)**, smoke **2/2 (0.34 s)**. Retained FLTK **665/665 (22.74 s)**,
  smoke **2/2 (0.45 s)**. Core ASan+UBSan **141/141 (4.63 s)** and pure C **1/1
  (0.26 s)**; TSan **141/141 (6.72 s)** and pure C **1/1 (0.19 s)**. All native
  targets built; suites passed **33/33** normal **28.09 s**, ASan **35.06 s**, TSan
  **107.37 s**. Sanitizer builds disable GnuTLS and cover unavailable-method behavior;
  they do not claim instrumentation of external crypto dependencies.
- Ten additional light/dark renders cover inherited, custom, empty and invalid
  selections plus the complete method catalog. Inspected original-size custom/dark
  and full-catalog/light PNGs. Wrapping/fitting checks pass; the regular settings
  view scrolls while Apply/Cancel remain outside its scroll area. Physical scrolling,
  focus and VoiceOver still need acceptance.
- Native app build, `codesign --verify --deep --strict --verbose=2`, branding and
  attribution audit (1650 deferred occurrences), and `git diff --check` pass. All
  build/test process handles reached successful terminal states. Existing Homebrew
  dependency deployment warnings, ad-hoc signing and Xcode ZERO_CHECK warning remain.
  No minimum-OS/Intel/universal/release-signing execution is claimed.
- A fresh native app probe still returns `Sky Computer Use native pipe closed before
  response`. This is a tool transport failure, not evidence of a locked Mac. No
  user preferences, credentials or trust state were changed for physical testing.

Commands: build all native test targets with `DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`,
then `ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`.
Normal core configurations ran all unit/viewer suites; sanitizer selections added
SecurityOptions to PromptAuthentication, ProtocolSession, ViewerABI, SessionEvents
and SessionWorker, plus the pure-C smoke consumer.

Logs: `/tmp/tidyvnc-security-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-security-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-security-app-build.log`, `/tmp/tidyvnc-security-signature.log`,
`/tmp/tidyvnc-security-branding.log` and `/tmp/tidyvnc-security-render-tests.log`.


### N1.2 / N4.5 advanced TLS-priority settings (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was
verified progress (security-method selection). This step adds TLS-priority controls;
the full native-UI goal remains incomplete.

- Added shared GnuTLS preflight and a stateless checked C export,
  `tidyvnc_tls_priority_validate`, with TLS_PRIORITY_VALIDATION (67108864), required
  by NativeRuntime. The archive now exposes **72 tidyvnc functions**. Inputs are
  bounded to 4096 UTF-8 bytes with no NUL; invalid expressions use a typed Security
  reason. The validator owns a private priority cache and balanced initialization,
  preserves existing anonymous KX suffix behavior through a shared helper, and
  never changes the legacy global priority. Parser success is not peer compatibility.
- Added independent `security.tlsPriority` inheritance: absent inherits, empty resets
  to library defaults, nonempty is preserved exactly. Defaults schema 7/profile
  schema 6 read earlier schemas without rewriting; old schemas reject the new nested
  field. Store actors preflight on reads and before writes, keeping possible GnuTLS
  configuration IO off the UI thread. Invalid Apply/Save is correctable and leaves
  the revision and bytes unchanged. Session values/sources are captured immutably.
- Advanced TLS Priority is available within defaults and profile security controls,
  with inheritance, explicit library default, custom expression and unavailable-build
  presentation. Nonempty priority values in a TLS-disabled C session now return
  Unsupported instead of being silently ignored. Constructor validation remains
  bounded and free of parsing/IO; real TLS setup stays on the protocol worker.
- Tests cover empty/invalid/oversized/NUL expressions, backend availability, concurrent
  preflight, anonymous-only suites, strict records, schema upgrades, exact persistence,
  independent field precedence, Apply/Cancel, correctable save errors and per-window
  snapshots. A real TLS 1.2-only loopback peer rejects TLS 1.3-only client policy before
  credentials. Initial sandboxed socket tests failed at loopback bind; the authorized
  unsandboxed runs passed. No automatic approval rejection occurred.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14. Headless
  **651/651 (20.09 s)**, smoke **2/2 (0.36 s)**. Retained FLTK **667/667 (22.59 s)**,
  smoke **2/2 (0.31 s)**. Core ASan+UBSan **142/142 (4.32 s)** and pure C **1/1
  (0.27 s)**; TSan **142/142 (6.65 s)** and pure C **1/1 (0.20 s)**. All native
  targets built; suites passed **33/33** normal **28.66 s**, ASan **33.97 s**, TSan
  **106.12 s**. Sanitizer builds disable GnuTLS; actual parser/handshake tests run in
  normal builds. External crypto dependencies are not claimed instrumented.
- Eight new light/dark expanded-form renders cover inherited, custom, explicit default
  and unavailable states. All fitting checks pass; inspected original-size custom/dark
  and unavailable/light PNGs. Physical focus/keyboard/VoiceOver remains unverified.
- Native app build, strict deep signature verification, branding/attribution audit
  (1650 deferred occurrences) and `git diff --check` pass. All process handles reached
  successful terminal states. Existing newer-OS dependency warnings, Xcode device
  plugin/simulator diagnostics and ZERO_CHECK warning remain; the macOS app build
  succeeded. No minimum-OS/Intel/universal/release-signing execution is claimed.
- A fresh native UI probe still fails with `Sky Computer Use native pipe closed before
  response`. This is a tool transport failure, not evidence of a locked Mac. Physical
  picker/keyboard/VoiceOver, per-window reconnect security editing and full native
  authentication acceptance remain open. See [SECURITY.md](SECURITY.md) for contracts.

Commands: build all native test targets with `DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`,
then `ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`.
Normal core configurations ran all unit/viewer suites; core sanitizer selections
were SecurityOptions, PromptAuthentication, ProtocolSession, ViewerABI, SessionEvents
and SessionWorker, plus the pure-C smoke consumer. App: `python3 apps/macos/build.py`.

Logs: `/tmp/tidyvnc-priority-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-priority-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-priority-app-build.log`, `/tmp/tidyvnc-priority-signature.log` and
`/tmp/tidyvnc-priority-branding.log`.


### N1.5 / N4.5 connection-local security reconfiguration (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was
verified progress (TLS-priority settings). This step implements disconnected
security editing and next-attempt application; the full native-UI goal is incomplete.

- Added immutable core security snapshots with revision/generation and synchronous
  compare-and-replace under the worker admission mutex. Only reusable sessions
  between fully drained attempts accept updates. Setup, authentication, connected,
  disconnecting/draining, stale and permanently closing states reject atomically.
  Eight concurrent writers against one revision admit exactly one. The serialized
  worker installs the accepted policy before the next attempt; session identity,
  mailboxes, counters, frame leases and negotiation order remain intact.
- SECURITY_RECONFIGURATION (134217728), required by NativeRuntime, adds owned getter
  and bounded setter C contracts, bringing the archive to **74 tidyvnc exports**.
  Getter text arrays use explicit lengths up to 4096 bytes (canonical method text
  remains NUL-terminated). This avoids Swift’s import limit for 4097-element arrays
  while retaining the complete 4096-byte contract. The setter uses copied spans,
  preserves failure outputs and publishes no asynchronous completion obligation.
  GnuTLS preflight remains a separate off-UI operation; file loading stays on the
  protocol worker during a subsequent X509 attempt.
- Added Connection > Connection Settings > Security and corresponding actions-menu
  and context-menu entries. The sheet edits methods, TLS priority and CA/CRL files
  while disconnected, displays initial sources/connection override, and supports
  restoring each field from the window’s initial snapshot. Apply affects that
  window’s next connection only; Done then Connect starts it. No automatic reconnect
  or durable defaults/profile writes occur. Unchanged initial fields display as
  inherited; duplicate initial method IDs do not create false dirty drafts.
- The native editor preflights on an actor, checks cancellation, then commits with
  both identities. Invalid/unsupported values remain correctable; competing edits
  or attempts require reload. Connect/reopen are gated until editor cleanup joins.
  Close and active-attempt transitions cancel the draft. Authentication keeps sheet
  priority and stale sheet dismissals check identity. Accepted changes clear retained
  reconnect credentials and trust-attempt state, without altering stored secrets or
  saved trust decisions. Cancel does not clear retained credentials.
- Core tests prove immutable old snapshots, concurrent CAS, no completion event for
  synchronous edits, setup/prompt/active/drain exclusion and actual next-attempt
  enforcement. Native tests use four independent real peers: one session connects,
  disconnects, rejects a None-only peer with a new VncAuth-only policy, restores its
  initial policy and reconnects; a second session stays connected throughout.
  Cancellation, stale drafts, controller close/drain, unavailable builds, independent
  durable state and full-length C-to-Swift text copies are covered. Light/dark sheet
  renders pass fitting checks; final dark render inspected at original resolution.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14. Headless
  **653/653 (20.30 s)** and smoke **2/2 (0.35 s)**. Retained FLTK **669/669 (22.34 s)**
  and smoke **2/2 (0.49 s)**. Core ASan+UBSan **144/144 (4.76 s)**, pure C **1/1
  (0.48 s)**; TSan **144/144 (9.10 s)**, pure C **1/1 (0.24 s)**. All native targets
  built; full suites **33/33** normal **27.97 s**, ASan **35.56 s**, TSan **107.14 s**.
  Final editor refinements were followed by rebuilt security/render suites **2/2**
  normal **18.41 s**, ASan **22.52 s**, TSan **29.29 s**. Sanitizer builds disable
  GnuTLS; no external crypto instrumentation is claimed.
- Final app build, strict deep ad-hoc signature check, branding/attribution audit
  (1650 deferred occurrences) and `git diff --check` pass. All process handles are
  terminal. Existing dependency deployment warnings and Xcode device/simulator and
  ZERO_CHECK diagnostics remain; the macOS app build succeeds. No minimum-OS/Intel/
  universal/release-signing execution is claimed.
- A fresh native app probe still returns `Sky Computer Use native pipe closed before
  response`. This is a transport failure, not a lock-screen finding. Physical menu,
  picker, keyboard/VoiceOver and complete native authentication acceptance remain open.

Commands: complete core unit/viewer suites in normal headless and retained-FLTK
configurations; affected SessionWorker/ProtocolSession/PromptAuthentication/ViewerABI/
SessionEvents/SecurityOptions suites and pure-C consumer in core sanitizer builds.
All native targets built with `DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`,
then `ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`.
Final targeted runs used `-R 'NativeSecurity|NativeSettings'`. App build:
`python3 apps/macos/build.py`.

Logs: `/tmp/tidyvnc-reconfigure-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-reconfigure-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-reconfigure-verified-native{,-asan,-tsan}-{build,tests}.log`,
`/tmp/tidyvnc-reconfigure-verified-app-build.log`,
`/tmp/tidyvnc-reconfigure-signature.log` and `/tmp/tidyvnc-reconfigure-branding.log`.

### N4.8 shared access and Retry policy (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was verified
progress (disconnected security reconfiguration). This step completes the shared/
reconnect settings slice; N4.8 and the full native-UI goal remain incomplete.

- Added per-session Shared ownership, a worker admission-mutex snapshot/CAS contract
  and ClientInit application on every attempt. The default remains false. Active,
  setup, prompt, drain, stale and closing edits reject without changing policy.
  SHARED_SESSION (268435456) adds two C exports, bringing the archive to **76**.
  Updates are synchronous and do not create asynchronous completion obligations.
- Added independent optional Shared/Retry fields to defaults schema **8** and
  profiles schema **7**. Older records remain readable without rewriting; explicit
  commits upgrade. Strict Boolean validation, per-field inheritance/source tracking,
  revision conflicts and existing-window isolation remain enforced.
- Added Connection defaults/profile controls and a disconnected Connection Options
  sheet with Apply/Cancel, restoration of initial values, stale-draft reload and
  controller exclusion. Retry defaults on and controls the explicit error action;
  it never reconnects automatically. Turning it off preserves manual Connect.
- Core tests inspect the ClientInit byte over repeated RFB 3.8 handshakes and race
  eight writers against one revision. Pure C covers feature/header/value validation,
  stale revisions and preserved failure outputs. Native loopback peers verify
  simultaneous shared/exclusive sessions, a changed value on reconnect, Retry
  suppression, cancellation, stale drafts, source preservation and new-window-only
  defaults. Every older defaults/profile schema is covered by migration fixtures.
- Visual review caught truncated labels in the expanded section-button row; the
  rendering bounds check then caught excessive height in a two-row alternative.
  A native section picker fixes both. Final light session and dark defaults renders
  were inspected; all final light/dark rendering tests pass.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14. Headless
  **655/655 (21.84 s)** and smoke **2/2 (0.37 s)**; retained FLTK **671/671 (22.84 s)**
  and smoke **2/2 (0.40 s)**. Core ASan+UBSan **146/146 (5.18 s)** plus pure C **1/1
  (0.47 s)**; TSan **146/146 (9.21 s)** plus pure C **1/1 (0.25 s)**. Final complete
  native suites pass **34/34** normal **26.54 s**, ASan **32.33 s**, TSan **107.25 s**.
  Sanitizer builds disable GnuTLS; external crypto instrumentation is not claimed.
- Final app build, strict deep ad-hoc signature verification, branding/attribution
  audit (1650 deferred occurrences) and `git diff --check` pass. All build/test
  process handles are terminal. Existing dependency deployment and Xcode device/
  simulator/ZERO_CHECK diagnostics remain; no minimum-OS, Intel, universal or release
  signing execution is claimed.
- A fresh native app probe still reports `Sky Computer Use native pipe closed before
  response`. This is an automation transport failure, not evidence of a locked Mac.
  Physical menus, keyboard/VoiceOver, server-specific sharing behavior, display
  selection and remote-resize settings acceptance remain open.

Commands: complete core unit/viewer suites in normal headless and retained FLTK
builds; affected SecurityOptions/PromptAuthentication/ProtocolSession/ViewerABI/
SessionEvents/SessionWorker/AuthenticationSocket suites and pure C in sanitizers.
All native test targets built with `DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`,
then full `ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`.
App build: `python3 apps/macos/build.py`. See [CONNECTION.md](CONNECTION.md).

Logs: `/tmp/tidyvnc-connection-options-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-connection-options-verified-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-connection-options-verified-app-build.log` and
`/tmp/tidyvnc-connection-options-signature.log`; branding results are in
`/tmp/tidyvnc-connection-options-branding.log`.

### N2 / N4.8 explicit native remote desktop resize (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was verified
progress (Shared/Retry settings). This step connects the existing portable layout
command to the native application. Automatic resize/display policy and the full
native-UI goal remain incomplete.

- DESKTOP_LAYOUT (536870912), required by NativeRuntime, adds shared stateless
  layout validation, an owned coherent connected layout/snapshot, and async resize
  requests. `nm` confirms **79 tidyvnc exports**. Input arrays are bounded and copied
  before return; output contains up to 255 owned screen records with zeroed unused
  slots. Existing ABI structs/handle ownership are unchanged. IDs/flags/gaps/overlap
  retain the core's protocol semantics; no OS display types cross the boundary.
- Swift exposes immutable layouts and generation-tagged async requests. Completion
  reflects server acceptance/rejection, timeout or close, rather than wire admission.
  Cancellation consumes the eventual result before returning. The existing core
  timeout preserves the occupied wire slot until a late reply or reconnect, avoiding
  ambiguous matching and duplicate completion.
- Added Connection/context-menu Resize Remote Desktop and a local width/height
  sheet. Server capability, view-only, pending work and framebuffer limits gate
  requests. Invalid dimensions remain disabled, rejection is correctable, and the
  successful sheet displays actual server geometry. A multi-screen notice explains
  the explicit action replaces topology with one screen, preserving the first ID/
  flags. Full multi-screen C/Swift support is available for later display mapping.
- Drafts compare current geometry with their baseline before sending and require
  Reload after an observed competing change. This is not server-side CAS. Controller
  gates exclude competing sheets, Cancel before Resize sends nothing, and dismissal
  joins cancelled work before reopening. Disconnect/window close dismiss and drain.
  The action writes no defaults/profile data. Automatic RemoteResize, initial
  DesktopSize, persistence and local-display/fullscreen mapping remain open.
- Pure C validates size/version, bounds/counts/nulls, unique IDs, reserved fields,
  wrong handles, generations and failure-output preservation. An independent RFB
  peer parses full messages (including fragmented reads), holds/rejects/replies to
  requests, and verifies success, rejection code, timeout/late reply, in-flight
  cancellation, close, buffer limits, view-only, unsupported servers, two-session
  isolation and all 255 screen records across the C/Swift/wire boundary. Controller
  tests cover dimension parsing, competing geometry, correctable server rejection,
  Cancel, editor exclusion and joined teardown. Light/dark draft, rejected, pending,
  applied and multi-screen renders pass fitting checks. Final dark pending and light
  multi-screen captures were visually inspected.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14. Complete
  headless **655/655 (19.72 s)** plus smoke **2/2 (0.26 s)**; retained FLTK **671/671
  (22.07 s)** plus smoke **2/2 (0.33 s)**. Affected core ASan+UBSan **157/157 (4.85 s)**
  and pure C **1/1 (0.26 s)**; TSan **157/157 (6.99 s)** and pure C **1/1 (0.26 s)**.
  The sanitizer selection includes RemoteDesktopLayout geometry tests. Sanitizer
  builds disable GnuTLS; external crypto instrumentation is not claimed.
- Final complete native suites pass **35/35** normal **39.82 s**, ASan **49.92 s**,
  and TSan **124.81 s**. All build/test process handles are terminal.
- Final app build, strict deep ad-hoc signature verification, branding/attribution
  audit (1650 deferred occurrences) and whitespace checks pass. Existing dependency
  deployment and Xcode device/simulator/ZERO_CHECK diagnostics remain; minimum-OS,
  Intel/universal and release signing execution are not claimed.
- The fresh rebuilt-app probe still returns `Sky Computer Use native pipe closed
  before response`, an automation transport failure rather than a lock-screen
  finding. Physical menu/keyboard/VoiceOver and broader server acceptance remain
  open. See [REMOTE-RESIZE.md](REMOTE-RESIZE.md) for contracts and remaining work.

Commands: complete core unit/viewer suites in normal headless/retained FLTK;
SecurityOptions/PromptAuthentication/ProtocolSession/ViewerABI/SessionEvents/
SessionWorker/AuthenticationSocket/RemoteDesktopLayout and pure C under core
sanitizers. All native targets built with `DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`,
then full `ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`.
App build: `python3 apps/macos/build.py`.

Logs: `/tmp/tidyvnc-remote-layout-core-{headless,fltk,asan,tsan}-{build,unit,smoke}.log`,
`/tmp/tidyvnc-remote-layout-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-remote-layout-app-build.log`, `/tmp/tidyvnc-remote-layout-signature.log`
and `/tmp/tidyvnc-remote-layout-branding.log`.

### N4.8 automatic remote resize and local policy (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was verified
progress (explicit native remote resize). This step adds the automatic coordinator
and local controls. Durable resize defaults/profile storage and the complete
native-UI goal remain incomplete.

- Added a typed immutable policy with enabled=true and empty initial-size defaults,
  matching the retained viewer's RemoteResize/DesktopSize defaults. Bounded integer
  dimensions canonicalize through shared remote-layout validation. Connect captures
  initial size synchronously with its accepted generation; live initial-size edits
  apply on the next attempt. NativeSessionConfiguration can supply either field.
- A session-owned coordinator coalesces geometry for 100 ms and retains only the
  latest desired size while a request is pending. It respects connection/capability,
  view-only, pending wire work, viewport availability and Unscaled mode. Device
  units floor logical size times backing scale. Invalid/nonfinite/out-of-range
  sizes never reach the wire. Repeated accepted/rejected targets do not trigger
  retry loops. The one initial request bypasses scaling mode while respecting the
  other gates. Initial and accepted manual sizes survive until viewport changes.
- The AppKit view supplies geometry, backing scale, scaling/units, visibility and
  minimization. Fullscreen transitions suspend scheduling, with completion events
  or a bounded 15-second recovery. Each attached replacement has an identity; old
  geometry/detach events cannot take ownership back. Review caught acquisition
  occurring before renderer initialization: it now occurs only after successful
  initialization, with a regression proving a failed view does not steal the source.
  Detached views stop scheduling; session close cancels and joins coordinator work.
- Added Connection Settings/context-menu Remote Resize controls with copied
  Apply/Cancel drafts, initial-value restoration, input validation and host revision
  conflict detection. Turning off the policy cancels queued work where possible;
  sent requests cannot be undone. The sheet explains remote pixels, scaling gates,
  next-attempt initial size and shared-desktop effects. Automatic failures appear
  as nonfatal status text. These controls do not write durable settings.
- Real loopback tests cover coalescing, latest-size follow-up behind a held reply,
  disabling/re-enabling while pending, view-only, device pixel rounding, invalid
  viewport bounds, manual override, rejected-size no-retry behavior, replacement
  identity, detached view, close and simultaneous session isolation. Initial-size
  canonicalization, per-attempt capture/reconnect, stale policy drafts, and AppKit
  geometry/fullscreen/hidden/recovery integration are covered. Notification tests
  are synthetic; no physical multi-display/Spaces acceptance is claimed.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14. All native
  targets built and complete suites pass **36/36**: normal **48.94 s**, ASan **55.23 s**,
  TSan **133.83 s**. The final ownership fix passed the selected desktop/render/
  remote-layout/automatic suites **5/5**: normal **38.54 s**, ASan **43.51 s**, TSan
  **58.45 s**. The panning consumer was separately relinked against the final archive
  and rechecked **1/1** normal **0.33 s**, ASan **0.44 s**, TSan **3.55 s**. All process
  handles are terminal. Sanitizer builds disable GnuTLS; external crypto instrumentation
  is not claimed. C/C++ production code and the **79-export ABI** are unchanged in
  this step; prior core evidence remains applicable.
- Light/dark valid and invalid policy-sheet renders pass bounds checks. Dark valid
  and light invalid captures were visually inspected. Final app build, strict deep
  ad-hoc signature verification, branding/attribution audit (1650 deferred
  occurrences) and whitespace checks pass. Dependency deployment and Xcode device/
  simulator/ZERO_CHECK diagnostics remain; no minimum-OS/Intel/universal/release
  signing execution is claimed.
- A fresh rebuilt-app probe still fails with `Sky Computer Use native pipe closed
  before response`. This is an automation transport failure, not evidence that the
  Mac is locked. Physical keyboard/menu/VoiceOver and actual fullscreen transitions,
  policy persistence/source labels, multi-display mapping and chooser remain open.

Commands: build every native test target using
`DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build
build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`, then full
`ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`. Final
selection: `NativeRemoteResize|NativeRemoteLayout|NativeSettings|NativeDesktop[.]`.
Rebuild/recheck `native-panning-tests` separately. App: `python3 apps/macos/build.py`.

Logs: `/tmp/tidyvnc-auto-resize-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-auto-resize-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-auto-resize-final-pan{,-asan,-tsan}.log`,
`/tmp/tidyvnc-auto-resize-final-app-build.log`, `/tmp/tidyvnc-auto-resize-signature.log`
and `/tmp/tidyvnc-auto-resize-branding.log`. Contracts: [REMOTE-RESIZE.md](REMOTE-RESIZE.md).

### N3 / N4.8 saved resize policy and source tracking (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was verified
progress (automatic remote resize and local policy). This step adds its durable
settings and field sources. Display selection/fullscreen mapping and the complete
native-UI goal remain incomplete.

- Defaults schema **9** and profile schema **8** add optional `remoteResize` with
  optional enabled/initialSize fields. Absence inherits independently; an explicit
  empty size overrides an inherited initial request. Enabled=false preserves the
  size while suppressing automatic requests. Shared layout validation canonicalizes
  dimensions on explicit save. Reads preserve bytes, all older schemas remain
  readable, and old schemas reject the new object. Nulls, numeric/string Boolean
  lookalikes, wrong types, unknown fields and invalid sizes are rejected. Existing
  conflict/future-schema/corruption and profile-file atomic replacement rules remain.
- New connection windows resolve app defaults followed by profile overrides, with
  an owned value/source snapshot for each field. Saving later defaults/profiles
  does not change existing windows. Local policy Apply marks only changed fields as
  connection overrides; untouched fields retain their app/profile/compiled source.
  The local editor previews source changes and never writes durable settings.
- Added Connection Defaults > Remote Resize and a profile Remote Resize group, with
  independent inherit/override controls, explicit blank size, validation-gated
  Apply/Save and help for scaling/device units and shared-desktop behavior. The
  local sheet now shows sources per field and retains a visible initial-size label
  when the text field contains a value.
- New tests read each older defaults/profile schema without writing, explicitly
  upgrade to 9/8, canonicalize values, reject invalid reads/saves without overwriting,
  reject new fields in old schemas, and verify independent precedence/source labels.
  Real peers prove the saved app initial size reaches the wire, a disabled profile
  suppresses it, and an explicit blank profile suppresses a newer app default.
  Existing windows retain old values while newly created windows capture updates.
  Local Apply preserves untouched sources and leaves durable write counts unchanged.
- macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14. All native
  targets built; complete suites pass **37/37** normal **51.02 s**, ASan **60.04 s**,
  TSan **140.97 s**. Additional invalid-save/new-window assertions were subsequently
  rebuilt and checked **1/1** normal **0.64 s**, ASan **0.67 s**, TSan **2.77 s**.
  All process handles are terminal. Sanitizer builds disable GnuTLS; external crypto
  instrumentation is not claimed. C/C++ production code and the **79-export ABI**
  are unchanged; prior core validation remains applicable.
- Light/dark inherited/custom/explicit-blank/invalid defaults, profile overrides and
  source-labelled local sheets pass rendering bounds checks. Dark custom defaults,
  light invalid local policy and light profile override captures were inspected.
  Final app build, strict deep ad-hoc signature verification, branding/attribution
  audit (1650 deferred occurrences) and whitespace checks pass. Existing dependency
  deployment and Xcode device/simulator/ZERO_CHECK diagnostics remain; no minimum-OS,
  Intel/universal or release signing execution is claimed.
- A fresh rebuilt-app probe still reports `Sky Computer Use native pipe closed
  before response`. This is an automation transport failure, not a locked-Mac
  finding. Physical keyboard/menu/VoiceOver, fullscreen display mapping/chooser,
  broader server interoperability and other parent-plan acceptance gates remain open.

Commands: build all native test targets using
`DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build
build/native-ui-swift{,-asan,-tsan} --target <native-*-tests> --parallel 2`, then full
`ctest --test-dir <build>/tests/macos --no-tests=error --output-on-failure`.
Final focused target `native-resize-persistence-tests`, CTest selection
`NativeRemoteResize.PersistenceAndSources`. App: `python3 apps/macos/build.py`.

Logs: `/tmp/tidyvnc-resize-persistence-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-resize-persistence-final{,-asan,-tsan}.log`,
`/tmp/tidyvnc-resize-persistence-app-build.log`,
`/tmp/tidyvnc-resize-persistence-signature.log` and
`/tmp/tidyvnc-resize-persistence-branding.log`. See [REMOTE-RESIZE.md](REMOTE-RESIZE.md).

### N2 / N4.8 shared display mapping and explicit chooser (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn was verified
progress (saved resize settings and source tracking). This step exposes the retained
monitor-layout algorithm and adds an all/selected local-display mode to explicit
remote resizing. The complete native-UI goal remains incomplete.

- Added `tidyvnc_display_layout_compute`, feature DISPLAY_LAYOUT (1073741824),
  required by NativeRuntime; **80 exports**. It checks borrowed 1–64 monitor values,
  signed origins, dimensions and units before coordinate arithmetic, then delegates
  to shared `DesktopLayout`. Owned output contains size, token-labelled regions,
  normalization and zeroed unused entries; failures preserve output. Existing ABI
  structs and the shared mapping algorithm are unchanged.
- Native value mapping preserves UUID identity, logical negative origins/gaps and
  per-display scales. Device units use the shared mixed-density normalization;
  global origins are never multiplied by one display's density. Fractional logical
  bounds, duplicate/mirrored/overlapping displays and out-of-range layouts fail.
  Temporary local tokens are separate from RFB IDs. Exact server geometry matches
  keep IDs/flags, remaining IDs are reused deterministically, and new IDs avoid all
  baseline IDs. Screen enumeration order does not change the mapping.
- Resize Remote Desktop offers custom, all-display and selected-display sources,
  a numbered arrangement with clickable regions and matching checkbox controls,
  device-pixel toggle, requested dimensions/screen count and normalization feedback.
  Topology changes require Reload; missing UUID selections remain visible and cannot
  silently fall back. Apply rereads the source to catch delayed notifications.
  Custom sizing remains usable without monitor information. Both paths retain
  capability/view-only/pending/generation gates and joined cancellation/close.
  No defaults/profile or system display settings are modified.
- Pure C tests exercise normal/mixed mapping, input bounds, integer extremes,
  duplicates, overlaps, bad headers/units/null pointers and unchanged failure output.
  Native tests cover ordering, negative origins, density/gaps, remote IDs/flags,
  invalid geometry and controller-injected topology. Real loopback checks verify
  the complete layout on the wire, rejection, explicit empty selection, unplug
  before notification, Reload/replug and view-only behavior. Twelve new light/dark
  chooser renders cover all/selected/empty/changed/missing/overlapping displays.
  Dark all-display and light missing-display captures were inspected; bounds pass.
- Fullscreen window/current/all/selected policy, persisted display choices,
  per-display presentation and automatic fullscreen mapping remain open. This
  explicit server command is not evidence of local fullscreen/Spaces behavior.
  A fresh CUA probe reports `Sky Computer Use native pipe closed before response`;
  this is an automation transport failure, not a locked-Mac finding. Physical
  keyboard/menu/VoiceOver and real multi-display/server acceptance remain open.

Verification: macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting macOS 14.
All native targets built; normal **37/37 (52.82 s)**, ASan **37/37 (60.52 s)**
and TSan **37/37 (142.27 s)** pass. Pure C consumers pass normal **1/1 (0.33 s)**,
ASan **1/1 (0.39 s)** and TSan **1/1**. All process handles are terminal.
Headless shared-layout/C-ABI regressions pass **34/34 (1.17 s)** plus its pure C
consumer **1/1 (0.24 s)**. App build, strict deep ad-hoc signature verification, branding/attribution
ledger (1650 deferred occurrences) and whitespace checks pass. Sanitizer builds
exclude GnuTLS; external crypto instrumentation is not claimed. Existing dependency
deployment/Xcode diagnostics remain; minimum OS, Intel/universal and release signing
are not established by these runs.

Commands: `/tmp/tidyvnc-verify-display.py [empty|-asan|-tsan]` builds all native test
targets and `viewer-c-abi-smoke`, then runs the complete native directory and focused
pure C consumer with `--no-tests=error`. Headless targets: `viewerabi`, `desktoplayout`,
`viewer-c-abi-smoke`; unit selection `^(ViewerABI|DesktopLayout)\.`. App:
`python3 apps/macos/build.py`. Signature: `codesign --verify --deep --strict`.

Logs: `/tmp/tidyvnc-display-native{,-asan,-tsan}-{full-build,full-tests,c-tests}.log`,
`/tmp/tidyvnc-display-headless-{build,tests,c-tests}.log`,
`/tmp/tidyvnc-display-app-build.log`, `/tmp/tidyvnc-display-signature.log`,
`/tmp/tidyvnc-display-branding.log`. Contracts: [REMOTE-RESIZE.md](REMOTE-RESIZE.md).

### N2 / N5.7 native shared canvas presentation (2026-09-20)

Working-tree implementation; no commit created. The previous goal turn delivered
and verified explicit all/selected remote display mapping. This step enables native
views to present regions of that shared canvas. The full native-UI goal and actual
fullscreen ownership/policy remain incomplete.

- Added CANVAS_GEOMETRY (2147483648) and two checked pure C entry points for canvas
  geometry and damage; **82 exports**. The feature is an unsigned 64-bit macro,
  compatible with strict C and Swift import. Existing public structs/window entry
  points remain unchanged. Shared output helpers call retained DesktopTransform
  for whole-canvas fit, per-region placement, inverse pointer and filter damage.
  Canvas/region bounds and pan/point inputs are checked before arithmetic; failure
  preserves outputs. No alternate Swift transform or OS/session state is introduced.
- NativeDisplayLayout now retains units and produces validated region viewports by
  stable display ID. NativeGeometry carries the viewport through image, input and
  damage calculations, and clamps pan against the full canvas. NativeDesktopView
  preflights candidate geometry/tile budgets before installing canvas/pan intent.
  Its existing renderer publishes new pixels and geometry together. Clearing the
  canvas restores window sizing; invalid candidates preserve the current view.
- A canvas view cannot claim or publish the automatic window-resize source, whether
  configured before bind, attached later, or converted from an existing window.
  Clearing the canvas restores ordinary viewport following. The eventual fullscreen
  owner must issue complete mapped layouts and coordinate all surfaces itself.
- New NativeDesktop.CanvasGeometryAndPresentation checks all eight scaling modes,
  logical/device units, fractional scales, global pan clamping, damage/filter halos
  and exact mixed-density identity/seams. Two AppKit views display different source
  quadrants and send matching pointer coordinates to a real loopback peer. A gated
  renderer verifies old pixels/input stay coherent while a new region is pending.
  Source damage, invalid candidates, clear, pending close and resize ownership pass.
  The pixel fixture waits for the actual source pattern and allows the observed
  macOS display-profile round-trip in secondary color channels; geometry and wire
  coordinates retain exact assertions where shared rounding allows them.
- All native targets built and full suites pass **38/38** normal **53.34 s**, ASan
  **61.96 s**, TSan **145.75 s**. Pure C consumers pass **1/1** normal **0.32 s**,
  ASan **0.29 s**, TSan **0.27 s**, including invalid canvas/null/header/overflow and
  preserved-output cases. Headless shared-layout/C-ABI tests pass **34/34 (1.21 s)**,
  plus the headless pure C consumer **1/1 (0.33 s)**. All process handles are terminal.
- App build, strict deep ad-hoc signature verification, 82-export inspection,
  branding/attribution ledger (1650 deferred occurrences) and whitespace checks
  pass. Environment: macOS 27 arm64, Swift 6.4/Clang 21, SDK 27, deployment setting
  macOS 14. Sanitizers exclude GnuTLS; no external crypto instrumentation claim.
  Existing dependency-target and Xcode diagnostics remain. Minimum OS, Intel/
  universal execution and release signing are not established.
- Fullscreen surface/transition ownership, shared pan/focus/commands, scaling/topology
  reconciliation, complete-layout automatic resizing and persisted display policy
  remain open. Tests do not prove physical fullscreen/Spaces, keyboard capture or
  multi-display hardware behavior. The prior CUA native transport failure remains
  an interactive acceptance limitation; no new locked-Mac finding is asserted.

Commands: `/tmp/tidyvnc-verify-canvas.py [empty|-asan|-tsan]` builds all native test
executables and `viewer-c-abi-smoke`, then runs complete native suites and the pure C
consumer with `--no-tests=error`. Headless targets: `viewerabi`, `desktoplayout`,
`viewer-c-abi-smoke`; selection `^(ViewerABI|DesktopLayout)\.`. App:
`python3 apps/macos/build.py`; signature: `codesign --verify --deep --strict`.

Logs: `/tmp/tidyvnc-canvas-native{,-asan,-tsan}-{full-build,full-tests,c-tests}.log`,
`/tmp/tidyvnc-canvas-headless-{build,tests,c-tests}.log`,
`/tmp/tidyvnc-canvas-app-build.log`, `/tmp/tidyvnc-canvas-signature.log`,
`/tmp/tidyvnc-canvas-branding.log`. Contracts and remaining integration:
[CANVAS.md](CANVAS.md).

### N5.6 / N5.7 scoped native surface focus and command routing (2026-09-20)

Implemented the shared-session focus route needed by multiple native desktop
surfaces. Fullscreen window ownership, shared pan, automatic complete-layout resize
and physical monitor/Spaces acceptance remain open; the full plan is incomplete.

- NativeSession records a surface UUID for native focus. Handoff releases held
  wire keys/buttons before the next surface gains focus, publishing a false/true
  interval so clipboard work cannot survive a change of owner. Background blur,
  hide, close and delayed destruction can revoke only their own scoped interval.
  Disconnect, generation change, global focus loss and close clear ownership.
- NativeDesktopView gates pointer, keyboard, wheel, IME, shortcut and capture
  routes by ownership. Losing ownership clears local input/composition/capture.
  Explicit focus actions refresh eligibility even when AppKit already considers
  the view first responder. Hidden views cannot gain focus through commands.
- Commands weakly register surfaces and activate on focus; background registration
  preserves the active host, and explicit detach selects a surviving host without
  acquiring focus. Capture/status/modifier callbacks from inactive hosts are ignored.
  Repeated activation of the same host does not schedule redundant UI updates.
- The public unscoped focus API remains compatible with existing consumers and
  live-view blur behavior. Deferred deinit never revokes an unscoped interval.
  No C/C++ or ABI changes: the export count remains **82**.
- Added `NativeDesktop.SurfaceFocusAndCommands`: two surfaces and independent
  loopback sessions cover held keys/buttons, stale key/pointer/IME suppression,
  composition/capture cleanup, background hide/render/close, command targeting,
  owner destruction/replacement, session isolation and reconnect/close. Window and
  capture backends are injected; this is not physical capture or Spaces evidence.
- Initial verification caught compatibility loss in the context-menu focus path
  and redundant published focus state in the existing presentation test. Both were
  corrected without weakening those tests. A new repeated-owner assertion also
  verifies that 100 unchanged focus callbacks produce no command UI invalidations.

Interactive app inspection was retried after the user confirmed the Mac was
unlocked. CUA still returned `Sky Computer Use native pipe closed before response`.
That transport error is not evidence of a locked Mac. No user settings, credentials
or trust records were changed. Physical acceptance remains unchecked.

Final verification: all native targets built; complete suites pass **39/39** normal
**51.70 s**, ASan **61.64 s**, and TSan **146.74 s**. The presentation and new focus
tests were also rerun after the final focused build completed (**2/2, 1.20 s**).
The native application build and strict deep ad-hoc signature check pass. Branding
and attribution checks pass with the existing **1650** deferred occurrences;
`git diff --check` passes. Sanitizer builds retain the configured GnuTLS-disabled
variant, and existing dependency deployment-target warnings remain. This does not
establish minimum-OS, Intel, release signing or physical UI acceptance. C/C++ is
unchanged by this slice; the prior canvas ABI/headless evidence remains applicable.

Commands: `/tmp/tidyvnc-verify-surface-focus-verified.py [empty|-asan|-tsan]` builds
all native test executables before running each complete suite with
`--no-tests=error --output-on-failure`; `python3 apps/macos/build.py`;
`codesign --verify --deep --strict --verbose=2`; `python3 tests/rebrand/audit.py`.
Final logs: `/tmp/tidyvnc-surface-focus-verified-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-surface-focus-verified-app-build.log`,
`/tmp/tidyvnc-surface-focus-verified-signature.log`, and
`/tmp/tidyvnc-surface-focus-verified-branding.log`. The initial failed full runs
remain in `/tmp/tidyvnc-surface-focus-native{,-asan,-tsan}-full-tests.log`; they are
superseded by these final runs after correcting redundant focus publication.

### N5.7 shared native canvas coordination (2026-09-20)

Implemented the shared pan/scaling coordinator needed by the fullscreen window
owner. The native app still toggles only its current window; fullscreen selection,
surface/Spaces transitions, automatic complete-layout resizing and physical
multi-monitor acceptance remain unchecked. The full native UI plan is incomplete.

- NativeScalingState now weakly registers every view and preflights all independent
  views and each canvas group before committing values, revisions or per-field
  sources. The most recently attached view can no longer hide an earlier surface's
  stricter backing-size or tile-budget constraints.
- NativeDesktopCanvas owns copied display snapshots, one layout/pan intent and weak
  views/session/scaling references. Configure validates distinct views, session
  membership, mapped topology and every candidate surface before replacing any
  member. Failed configurations preserve the old membership, regions and pan.
- Scaling changes remap the complete group using logical units for fitting modes
  and the requested logical/device policy for other modes. Geometry/unit changes
  reset shared pan; filter-only changes preserve it. Managed views reject direct
  region changes and report/restore direct per-view scale/unit/filter writes.
- Member pan commands and direct pan changes route to the group. Shared geometry
  computes one bound from current session frame dimensions, independent of image
  callback order. Remote shrink discards excess offsets, and later growth does not
  restore them. Disconnect clears shared pan. Each surface retains coherent
  asynchronous pixel/input publication; no atomic multi-window pixel barrier is
  claimed.
- Detach/destruction preserves remaining display coordinates until explicit
  reconfiguration. Stop, close and group destruction restore windowed geometry;
  deferred cleanup checks an owner UUID so it cannot clear a replacement group.
  Window creation and post-transition focus/resize ownership remain integration
  responsibilities of the fullscreen owner.
- Added `NativeDesktop.SharedCanvasCoordination`: controlled AppKit densities and
  real loopback peers cover all-view/group preflight, shared pan commands and
  clamping, filter preservation, mixed-density unit remapping, rejected and accepted
  topology changes, foreign/duplicate members, bypass rejection, weak view/group
  lifetime, replacement cleanup, disconnect/close and server-accepted desktop
  shrink/growth. It does not change physical display settings or prove Spaces.
- No C/C++ or ABI changes; **82** exports remain. No durable settings, credentials
  or trust records are changed. Contracts and remaining integration are recorded
  in [CANVAS.md](CANVAS.md).

The initial full normal/ASan/TSan runs passed **40/40**. Review then added explicit
guards against direct managed-view scaling bypasses, and the focused coordinator
test passed again (**0.26 s**). One subsequent full ASan run timed out in the older
surface-focus fixture, without a stage diagnostic; the coordinator test passed.
That fixture previously accepted an initial blank frame. Its wait now requires the
peer's actual pattern and matching displayed sequences in both views, and timeout
errors include the call-site line. No focus assertions or time limits were removed.
The strengthened fixture passed **10** consecutive ASan runs (**2.21 s** total),
**5** normal runs (**0.87 s**) and **5** TSan runs (**12.80 s**).

Final production verification: all native targets built and complete suites pass
**40/40** normal (**52.91 s**), ASan after fixture synchronization (**57.52 s**) and
TSan (**150.56 s**). The normal/TSan full runs precede only the fixture wait/diagnostic
change, which was separately rebuilt and repeated as above. The final app build,
strict deep ad-hoc signature, branding/attribution check (**1650** existing deferred
occurrences) and `git diff --check` pass. Sanitizer configurations retain GnuTLS
disabled; existing newer-dependency deployment warnings remain. These checks do not
establish minimum macOS, Intel, release signing or physical fullscreen acceptance.

Commands: `/tmp/tidyvnc-verify-shared-canvas-final.py [empty|-asan|-tsan]` builds all
native test targets and runs the complete suite with `--no-tests=error`;
`python3 apps/macos/build.py`; `codesign --verify --deep --strict --verbose=2`;
`python3 tests/rebrand/audit.py`. The final ASan recheck uses the complete rebuilt
suite with `ctest --test-dir build/native-ui-swift-asan/tests/macos --no-tests=error
--output-on-failure`. Repeated focus selections use `--repeat until-fail:10` for
ASan and `--repeat until-fail:5` for normal/TSan.

Logs: `/tmp/tidyvnc-shared-canvas-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-shared-canvas-final-asan-recheck-tests.log`,
`/tmp/tidyvnc-shared-canvas-focus-{normal,asan,tsan}-{build,tests}.log`,
`/tmp/tidyvnc-shared-canvas-final-focused-{build,tests}.log`,
`/tmp/tidyvnc-shared-canvas-final-app-build.log`,
`/tmp/tidyvnc-shared-canvas-final-signature.log`, and
`/tmp/tidyvnc-shared-canvas-final-branding.log`. The final ASan full-tests log retains
the timeout; the recheck log above records the successful synchronized suite.

### N5.7 fullscreen window-owner prototype (2026-09-20)

Implemented NativeFullscreenController and the AppKit window backend as the
comparison prototype required by the plan. Native-Space and coordinated-borderless
strategies remain explicit; no final strategy has been selected and the app's
existing single-window toggle is unchanged. A visible comparison harness, physical
Spaces/multi-monitor checks and app integration remain required. The overall plan
is not complete.

- Current/all/selected stable display identities resolve against a refreshed
  snapshot. Surviving selections take priority; only an entirely missing selection
  falls back to current/primary. Missing IDs and original intent are preserved.
  The backend resolves fresh NSScreen objects and rechecks frame/backing scale.
- Dedicated windows/surfaces share the connection, input/scaling/commands and
  NativeDesktopCanvas. The SwiftUI source and its delegate are preserved. New views
  receive their canvas before window attachment, avoiding ordinary resize ownership.
- Native entry waits with the original window visible and new surfaces hidden;
  success hides the source and activates the group. The source owner token blocks
  focus reacquisition and native input throughout the transition/fullscreen interval.
  Held keys/capture release before entry and exit. Hidden original-window backing
  limits do not reject scaling valid for the active fullscreen canvas.
- Owned primary delegate callbacks implement programmatic and user exits, with
  identity checks against stale/unrelated windows. Cancellable 15-second deadlines,
  native failures, partial factory failure, topology changes, owned-window close,
  disconnect and session close dispose owned resources and restore the source.
  Original-window close does not show it again. Deferred cleanup checks its source
  token before restoration; the existing session close joins renderer cleanup.
- Pointer-entry callbacks operate only in active fullscreen while the app is active,
  asking the backend to focus the relevant surface through scoped input ownership.
  Actual multi-monitor focus/capture behavior still needs physical acceptance.
- Added `NativeDesktop.FullscreenOwnershipAndTransitions` with real loopback input
  and injected window operations. It covers selection/fallback, shared layout,
  held-key release, source-input suppression with a wire barrier, hidden-source
  scaling, native/borderless transitions, stale callbacks, user exit, failure and
  deadline rollback, partial construction, topology change, close and destruction.
  Hidden real AppKit construction checks stable identity, bounds, ownership and
  strategy flags without showing windows or requesting a Space transition.
- The input gate was added during review after the initial **41/41** normal/ASan/
  TSan runs passed. Final verification rebuilds all targets with that gate and its
  regression assertion. No C/C++ or ABI change: **82** exports. No saved preferences,
  trust records, credentials, system display settings or Dock settings are changed.

Remaining integration and prototype contracts: [FULLSCREEN.md](FULLSCREEN.md).

Final verification: all native targets build and complete suites pass **41/41**
normal (**55.90 s**), ASan (**64.36 s**) and TSan (**155.56 s**), including the final
entry focus/input gate. The app build, strict deep ad-hoc signature, branding and
attribution checks (**1650** existing deferred occurrences) and `git diff --check`
pass. Sanitizer builds retain GnuTLS disabled; existing newer-dependency deployment
warnings remain. This is not minimum-macOS, Intel, release-signing or physical
fullscreen/Spaces acceptance. No interactive strategy comparison was performed.

Commands: `/tmp/tidyvnc-verify-fullscreen-owner-final.py [empty|-asan|-tsan]` builds
every native test target before complete CTest runs with `--no-tests=error`;
`python3 apps/macos/build.py`; `codesign --verify --deep --strict --verbose=2`;
`python3 tests/rebrand/audit.py`.

Logs: `/tmp/tidyvnc-fullscreen-owner-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-fullscreen-owner-final-app-build.log`,
`/tmp/tidyvnc-fullscreen-owner-final-signature.log`,
`/tmp/tidyvnc-fullscreen-owner-final-branding.log`. Focused prototype evidence is in
`/tmp/tidyvnc-fullscreen-owner-final-focused-{build,tests}.log`; final full suites
supersede that focused build with the entry-input regression included.


### N5.7 visible fullscreen comparison and command routing (2026-09-20)

Added the signed `native-fullscreen-comparison.app` developer target and
`NativeDesktop.FullscreenComparisonHarness` (42nd native test). The app uses an
owned loopback color pattern, current/all/selected display controls, native-Space
and borderless buttons, scaling/unit controls and restart. It loads no user state;
clipboard and automatic capture are off. Its offscreen verification checks the
actual desktop pixels and controls and renders light/dark PNGs; both were inspected.

Commands now route Exit to the weakly registered fullscreen controller, expose
phase availability, gate transition conflicts and clear routes by ownership token.
Frontend entry policy is optional; ordinary native fullscreen still exits first.
Regression tests cover command entry/exit, legacy exit priority and weak cleanup.

Visible testing on the built-in Retina display found native entry was cancelling
itself when macOS changed the Dock/menu-bar work area. The owner now compares full
display identity/geometry/scale/primary status rather than snapshot generation.
Work-area updates still reach windowed consumers. Entry/active work-area regression
assertions pass alongside the existing actual topology-change cleanup coverage.
Native fullscreen rendered all four quadrants and restored the original desktop
via Control–Command–F. Borderless entry and Desktop-menu exit restored it too.
ScreenCaptureKit temporarily returned -3812 during Space transitions, but subsequent
UI capture verified the resulting desktop. Control–Option–Return sent by automation
did not trigger exit, so physical keyboard acceptance remains open.

A second visible cycle also verified All displays/native and Selected displays/
borderless on the same single monitor, empty-selection rejection and restoration
of the selector after exit. These are selection-control checks, not multi-monitor
evidence.

No strategy is selected for shipping. Multi-monitor Spaces/Dock behavior, physical
keyboard/capture, chooser/persistence, app sheet/minimize integration, reconnect and
complete-layout automatic resize remain required. See [FULLSCREEN.md](FULLSCREEN.md).


Final verification: all native targets (including the new comparison bundle) build
and complete suites pass **42/42** normal (**53.16 s**), ASan (**63.64 s**) and TSan
(**156.41 s**). The app build, strict deep ad-hoc signature checks for the app and
comparison bundle, branding/attribution check (**1650** existing deferred
occurrences) and `git diff --check` pass. No C/C++ or ABI change: **82** exports.
Sanitizer configurations retain GnuTLS disabled; existing deployment dependency
warnings remain. Minimum macOS, Intel and release-signing acceptance are unchanged.

Commands: `/tmp/tidyvnc-verify-fullscreen-comparison-final.py [empty|-asan|-tsan]`
builds every native test plus the comparison target and runs CTest with
`--no-tests=error`; `python3 apps/macos/build.py`; strict deep `codesign --verify`;
`python3 tests/rebrand/audit.py`. Live checks used the native computer-use tool.

Logs: `/tmp/tidyvnc-fullscreen-comparison-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-fullscreen-comparison-final-app-build.log`,
`/tmp/tidyvnc-fullscreen-comparison-final-signature.log`,
`/tmp/tidyvnc-fullscreen-comparison-final-branding.log`,
`/tmp/tidyvnc-fullscreen-comparison-live-verified.log`, and
`/tmp/tidyvnc-fullscreen-comparison-live-selection.log`.


### N4.10 / N5.7 owned fullscreen minimize (2026-09-20)

Minimize now routes through NativeFullscreenController when owned fullscreen is
active. It validates the original window and every owned surface's sheet state,
records connection generation, releases input and exits the group. Successful
native exit or synchronous borderless cleanup restores the original command host
and hands off to its existing bounded minimize operation. Owned windows never
miniaturize. Fullscreen entry is rejected until that operation settles.

Failure/deadline, topology change, sheet arrival, changed ownership, close,
stop/destruction and disconnect discard the intent. Stale callbacks cannot cause
a later minimize. The fullscreen test now verifies native ordering, original
capability/sheet eligibility, real wire held-key release, unrelated/duplicate/late
callbacks, borderless handoff, failure/deadline/topology/sheet cancellation,
disconnect and the minimize-to-new-fullscreen race guard.

The comparison Desktop menu exposes Minimize and Restore Test Desktop. Actual
native-Space and borderless Command–M checks on the built-in Retina display each
emitted NSWindowDidMiniaturizeNotification with original minimized=true. The next
UI automation observation reactivated/restored the window and emitted the matching
deminiaturize notification. Logs preserve this distinction rather than treating
the restored screenshot as evidence of a failed minimize. The test fixture was
closed after verification. Multi-monitor acceptance and app integration remain
open; see [FULLSCREEN.md](FULLSCREEN.md).


Final verification: all native targets build and complete suites pass **42/42**
normal (**53.38 s**), ASan (**63.75 s**) and TSan (**156.28 s**). App build, strict
deep ad-hoc signatures for both the app and comparison bundle, branding/attribution
(**1650** existing deferred occurrences) and `git diff --check` pass. No C/C++ or
ABI changes (**82** exports). Sanitizer configurations keep GnuTLS disabled;
existing dependency deployment warnings do not establish minimum-macOS/Intel or
release-signing acceptance.

Commands: `/tmp/tidyvnc-verify-owned-minimize-final.py [empty|-asan|-tsan]`,
`python3 apps/macos/build.py`, strict deep `codesign --verify`, and
`python3 tests/rebrand/audit.py`. Logs:
`/tmp/tidyvnc-owned-minimize-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-owned-minimize-final-app-build.log`,
`/tmp/tidyvnc-owned-minimize-final-signature.log`,
`/tmp/tidyvnc-owned-minimize-final-branding.log`,
`/tmp/tidyvnc-owned-minimize-focused-{build,tests}.log`, and
`/tmp/tidyvnc-owned-minimize-live.log`.


### N4.8 / N5.7 connection-local fullscreen app integration (2026-09-20)

NativeFullscreenState now binds the source NativeDesktop to the window owner and
installs an identity-scoped entry policy. It preserves the original delegate and
collection behavior, disables independent green-button entry, clears pending work
on detach/stop/rebind and protects replacement command/window ownership. The
experimental app uses native Spaces provisionally after the single-Retina comparison;
the final mixed-monitor/Spaces strategy gate stays open and the comparison harness
retains both implementations.

Global Connection commands follow owned-window activation. Fullscreen and Minimize
have Control–Command–F and Command–M equivalents. Connection settings, information
and statistics actions leave fullscreen before using the original SwiftUI host.
Queued settings requests are singular and generation/window checked; close,
detach, stop and disconnect revoke them. Error alerts wait for the windowed host.
The fullscreen statistics overlay itself remains open.

Fullscreen Displays provides connection-local current/all/selected Apply/Cancel,
a layout diagram, accessible checkboxes and disconnected selections. Drafts retain
missing identities, use surviving selections before fallback, reject invalid or
empty arrangements, compare revisions/generations and require review after display
changes. Apply refreshes topology immediately before committing. The choice survives
disconnect in the same model; durable defaults/profile/CLI persistence and automatic
fullscreen reconnect restoration remain unimplemented.

Added NativeFullscreen.ConnectionAndPresentation as the 43rd native test, using
the actual ConnectionModel with a local pattern peer and injected windows. It
covers draft conflicts/review/fallback, owned command activation, original behavior/
delegate preservation, deferred settings arbitration, failed-exit recovery, desktop
errors, original close/disconnect cancellation and replacement cleanup. Selected/
missing-display sheets were rendered and visually inspected in light/dark. The
app builds, but visible end-to-end app sheet/Space, keyboard/VoiceOver and physical
multi-monitor acceptance are not inferred from hidden/model fixtures.


Final verification: all native targets build and complete suites pass **43/43**
normal (**55.84 s**), ASan (**66.25 s**) and TSan (**160.93 s**). The final native app
build, strict deep ad-hoc signatures for the app/comparison bundle, branding and
attribution check (**1650** existing deferred occurrences) and `git diff --check`
pass. ABI remains **82** exports; durable schemas remain defaults 9/profiles 8.
Sanitizer configurations still disable GnuTLS; existing dependency deployment
warnings do not establish minimum macOS, Intel or release-signing acceptance.

Commands: `/tmp/tidyvnc-verify-fullscreen-app-final.py [empty|-asan|-tsan]`,
`python3 apps/macos/build.py`, strict deep `codesign --verify`, and
`python3 tests/rebrand/audit.py`. Logs:
`/tmp/tidyvnc-fullscreen-app-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-fullscreen-app-final-app-build.log`,
`/tmp/tidyvnc-fullscreen-app-final-signature.log`,
`/tmp/tidyvnc-fullscreen-app-final-branding.log`,
`/tmp/tidyvnc-fullscreen-app-focused-{build,tests}.log`, and
`/tmp/tidyvnc-fullscreen-app-presentation-{build,tests}.log`.
Rendered sheets: `build/native-ui-swift/tests/macos/fullscreen-settings-render/`.


### N4.8 / N5.7 durable fullscreen policy and reconnect (2026-09-20)

Added NativeFullscreenPolicy and optional per-field NativeFullscreenPreferences.
Defaults schema 10/profiles schema 9 preserve old bytes on read and upgrade only
on explicit save. Strict type/key/identity checks reject corrupt values without
repairing stored records. Selected mode may inherit profile IDs; an explicit empty
list clears inactive selections, and effective selected mode requires at least one
saved ID. Missing displays remain selected through fallback. New sessions capture
initial policy and field sources; saved edits leave existing sessions unchanged.

App defaults and profiles now expose startup, current/all/selected mode and an
independent selected-display override. The live fullscreen sheet shows sources,
startup edits and Restore Initial Settings. Saved startup waits for a connected,
attached visible key window in the active app, without a sheet or minimize.
Focus/deminiaturize/sheet-end notifications retry eligibility; each attempt is
consumed before native entry, so a failed transition cannot retry in a loop.

Reconnect restores the retained display choice when fullscreen was active at
network teardown. Explicit exit, settings/minimize, failure and topology changes
clear the intent. A disconnect while explicitly exiting remains windowed on
reconnect. Local startup edits override the next attempt. Close/detach/stop and
replacement cleanup cancel queued entry. Details: [FULLSCREEN.md](FULLSCREEN.md).

Added the 44th native test, NativeFullscreen.PersistenceAndSources, and expanded
ConnectionAndPresentation for startup, foreground/visibility/minimize/sheet gates,
reconnect, stale callbacks, exit/disconnect races, failure/settings/topology
cancellation and stop. Default/selected/invalid controls render in light/dark;
selected and invalid renders plus the live sheet were visually inspected.

The live computer-use transport returned “Sky Computer Use native pipe closed
before response” on app selection, including after resetting its runtime. This is
an inspection-tool failure, not evidence that the Mac is locked. No visible app
interaction acceptance is claimed. The full native UI plan, CLI mapping, physical
multi-monitor/Spaces acceptance, fullscreen statistics and complete-layout automatic
resize remain open.


Final verification: **44/44** native tests pass in normal (**57.71 s**),
ASan (**66.80 s**) and TSan (**163.63 s**) builds. The app build,
strict deep ad-hoc signatures for app/comparison, branding/attribution (**1650**
existing deferred occurrences) and `git diff --check` pass. C ABI remains **82**
exports; schemas are defaults **10** / profiles **9**. Sanitizer configurations
still disable GnuTLS. Existing dependency deployment warnings do not establish
minimum-macOS/Intel or release-distribution acceptance.

Commands: `/tmp/tidyvnc-verify-fullscreen-policy-final.py [empty|-asan|-tsan]`,
`python3 apps/macos/build.py`, strict deep `codesign --verify`, and
`python3 tests/rebrand/audit.py`. Logs:
`/tmp/tidyvnc-fullscreen-policy-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-fullscreen-policy-final-app-build.log`,
`/tmp/tidyvnc-fullscreen-policy-final-signature.log`,
`/tmp/tidyvnc-fullscreen-policy-final-branding.log`,
`/tmp/tidyvnc-fullscreen-policy-focused-{build,tests}.log`, and
`/tmp/tidyvnc-fullscreen-policy-lifecycle-build.log`.
Renders: `build/native-ui-swift/tests/macos/settings-render/fullscreen-*.png`
and `build/native-ui-swift/tests/macos/fullscreen-settings-render/`.


### N4.8 / N5.7 automatic fullscreen remote layout (2026-09-20)

Extended the existing session resize coordinator with an exclusive, token-owned
canvas geometry source. Fullscreen reserves the source during construction,
enables it only after activation and suspends it before exit. Individual temporary
windows cannot claim resize ownership. The original viewport remains remembered;
cleanup restores it after disposing the group, with minimize availability gates.
Stale canvas cleanup cannot remove a replacement. Partial construction/native
failure and topology rollback preserve the ordinary window path.

Unscaled fullscreen requests the complete NativeDisplayLayout used by rendering,
including mixed-density normalization. Mapping uses the fresh server baseline,
retains remote IDs/flags and allocates new protocol IDs without exposing local
UUIDs. Initial size retains once-per-attempt single-screen precedence, even in
scaled mode. View-only, disabled policy, server capability, 100 ms coalescing and
single-operation drain remain shared. A held reply drains before the latest
geometry is sent after ownership or units change. Rejected targets do not loop.

Wire tests exposed and fixed expired manual/initial geometry holds that could
reactivate when returning to an earlier viewport. A manual resize also clears the
previous attempted-target suppression so changing scale away and back can restore
automatic geometry. The settings descriptions now explain the complete fullscreen
arrangement and distinguish single-screen window/initial-size requests.

Added NativeFullscreen.AutomaticRemoteLayout as the 45th native test, using an
independent RFB parser/response peer and injected native windows. Coverage includes
full layouts/IDs/flags, mixed units, per-view suppression, entry/exit transitions,
minimize/deminiaturize, topology/factory rollback, borderless handoff, policy gates,
manual/initial precedence, rejection, held replies, replacement ownership,
reconnect and expired-override regressions. The existing window policy, shared
canvas and fullscreen ownership fixtures also pass focused verification. These
are protocol/model tests, not physical mixed-display/Spaces acceptance.


Final verification: **45/45** tests pass in normal (**67.98 s**), ASan
(**78.90 s**) and TSan (**178.43 s**) builds. The Xcode app build,
strict deep ad-hoc signatures for app/comparison, branding/attribution (**1650**
existing deferred occurrences) and `git diff --check` pass. Updated default/live
resize panels were rendered and visually inspected in light/dark with no clipping.
C ABI remains **82** exports and schemas remain defaults **10** / profiles **9**.
Sanitizer builds still disable GnuTLS; existing dependency deployment warnings do
not establish minimum-macOS/Intel or release-distribution acceptance. No new live
computer-use/physical acceptance is claimed in this step.

Commands: `/tmp/tidyvnc-verify-fullscreen-resize-final.py [empty|-asan|-tsan]`,
`python3 apps/macos/build.py`, strict deep `codesign --verify`, and
`python3 tests/rebrand/audit.py`. Logs:
`/tmp/tidyvnc-fullscreen-resize-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-fullscreen-resize-final-app-build.log`,
`/tmp/tidyvnc-fullscreen-resize-final-signature.log`,
`/tmp/tidyvnc-fullscreen-resize-final-branding.log`,
`/tmp/tidyvnc-fullscreen-resize-regression-{build,tests}.log` and
`/tmp/tidyvnc-fullscreen-resize-wire-tests.log`.
Renders: `build/native-ui-swift/tests/macos/settings-render/resize-*.png` and
`remote-resize-policy*.png` in the same directory. Full goal remains active;
CLI mapping, fullscreen statistics and broader N0/N1/N3/N4/N5/N6 gates remain open.


### N4.12 / N5.7 fullscreen statistics (2026-09-20)

The app's existing value-only statistics panel is now shared from TidyVNCNative.
Each owned fullscreen window uses a container with the full-size desktop and a
separate passive NSHostingView for statistics. Its native hitTest returns nil and
it refuses first-responder status; the statistics accessibility content is a
sibling of the remote-image element. The overlay is positioned at the top right,
uses the same sampled information as the windowed view, and adds no session owner,
frame subscription, timer or presentation lease. Sample updates reuse the host.

ConnectionModel routes visibility directly to NativeFullscreenState/controller,
so the menu/context toggle no longer queues an exit or a settings presentation.
The existing connected/busy/transition gates apply. Statistics enabled before
entry appears on every active surface; entry/exit transitions hide it. Normal
windowed return keeps the connection choice; disconnect, close, stop and rebind
clear it. Controller cleanup removes hosts and copied values before disposing
owned windows. Source-window statistics still uses the same shared SwiftUI panel.

Added NativeFullscreen.StatisticsAndInputIsolation as the 46th native test. Actual
loopback session snapshots drive two simultaneous fullscreen fixtures, sampled
updates and disconnect. It checks overlay hosts, input pass-through, first responder,
unchanged desktop/canvas geometry, bounded resize placement, transition visibility,
re-entry, weak host destruction and independent session state. ConnectionAndPresentation
also verifies the actual model's in-place toggle and disconnect reset. Light/dark
fullscreen overlays are rendered over real fixture pixels. These are model/native
view tests; physical multi-monitor/Spaces and VoiceOver acceptance remain open.


Final verification: **46/46** native tests pass in normal (**69.96 s**), ASan
(**80.08 s**) and TSan (**181.32 s**) builds. App build, strict deep
ad-hoc signatures for app/comparison, branding/attribution (**1650** existing
deferred occurrences) and `git diff --check` pass. Final fullscreen statistics PNGs
were visually inspected in light/dark after correcting the top-right alignment;
the card is readable without clipping. C ABI stays **82** exports; durable schemas
stay defaults **10** / profiles **9**. Sanitizer builds still disable GnuTLS.
Existing dependency deployment warnings do not establish minimum-macOS/Intel or
release-distribution acceptance. No new physical computer-use acceptance is claimed.

Commands: `/tmp/tidyvnc-verify-fullscreen-statistics-final.py [empty|-asan|-tsan]`,
`python3 apps/macos/build.py`, strict deep `codesign --verify`, and
`python3 tests/rebrand/audit.py`. Logs:
`/tmp/tidyvnc-fullscreen-statistics-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-fullscreen-statistics-final-app-build.log`,
`/tmp/tidyvnc-fullscreen-statistics-final-signature.log`,
`/tmp/tidyvnc-fullscreen-statistics-final-branding.log`, and
`/tmp/tidyvnc-fullscreen-statistics-focused-tests.log`.
Renders: `build/native-ui-swift/tests/macos/fullscreen-statistics-render/`.
The full native UI goal remains active; CLI/document/listen/tunnel integration,
remaining service/UI/packaging work and physical acceptance gates remain open.

### N1.3 / N3.3 shared connection-document codec (2026-09-20)

Extracted ConnectionDocument into the toolkit-independent viewer core. It owns
ordered syntax records, preserves both exact headers and historical escape/name/
unknown-entry behavior, provides redacted typed errors, and bounds files to 1 MiB,
4096 entries and the historical 254-byte physical lines. Retained FLTK now uses it
for load/save/import while keeping semantic validation and rollback in its adapter.
No native stores, CLI routing or security migration behavior were changed.

Serialization permits only the historical non-secret export catalog. Complete
escaped-output preflight fixes saves that produced lines the reader could not
reload and preserves the destination on failure. Audio uses its actual persisted
name rather than the C++ variable name. Legacy migration still excludes endpoint
and security choices, never rewrites sources and retains AtomicFile protections.
The exact branding ledger moves the legacy header exception into the shared codec
and records two additional compatibility fixtures. See DOCUMENTS.md for limits,
remaining native bridging/semantic/panel integration and reproduction logs.

Verification: clean no-GUI configure/build and dependency audit; 663/663 portable
unit tests and both smoke consumers pass. After the Audio catalog correction,
focused headless codec tests pass 8/8. Retained Debug FLTK viewer builds and focused
codec/parameter/storage/import tests pass 23/23 (0.36 s). Codec ASan 8/8 (0.15 s)
and TSan 8/8 (0.37 s), branding/attribution audit (1650 existing deferred entries)
and git diff --check pass. No ABI or durable schema change; the existing 46-test
native result was not rerun for this codec-only change. Windows runtime behavior,
native Open/Save, file precedence and launch modes remain open.

The unlocked Mac's computer-use transport also worked again. A visible isolated
comparison-fixture check verified native-Space rendering and Control–Command–F
restoration on the single built-in Retina display. The fixture was quit and its
non-running state verified through the app inventory. This does not close the
physical keyboard, multi-monitor, VoiceOver or native-app acceptance gates.

### N2.1 / N2.2 / N3.3 owned native document bridge (2026-09-20)

Added CONNECTION_DOCUMENT and four C exports (86 total). Parse returns an
immutable retained handle; metadata and raw/decoded entries copy into versioned
structs. Document errors carry reason/source line with input-free diagnostics.
Serialization uses an explicit assignment list, size query and all-or-nothing
buffer output. There is no IO, runtime, callback, store mutation or implicit
unknown-field export. Core opaque-byte compatibility is retained.

NativeConnectionDocument is a Sendable owner with copied metadata, strict UTF-8,
on-demand shared decoding, bounded input spans and exact-sized Data exports.
Construction failures release the adopted handle. Added NativeDocuments.CodecOwnershipAndExport
as the 47th native test, six document ABI tests and pure-C smoke coverage.
Tests cover deferred unknown escapes, lifetime/reference/copy isolation, malformed
spans/versions/flags, typed redacted errors, all byte/count/index boundaries,
export catalog, no-write/capacity failures, output canaries, 48 allocation-failure
positions and concurrent C/Swift readers. See DOCUMENTS.md for the full contract.

Final results: native **47/47** normal (**70.68 s**), ASan (**79.86 s**) and TSan
(**183.65 s**); document ABI **6/6** and pure-C consumer pass in all three builds.
Headless **669/669** units (**20.30 s**) and both smoke consumers pass. Native app
build, strict deep ad-hoc app/comparison signatures, branding/attribution (**1650**
existing deferred occurrences) and git diff --check pass. ABI symbol inspection
confirms **86** exports; durable schemas stay defaults **10** / profiles **9**.
Sanitizers keep GnuTLS disabled. Existing dependency warnings leave deployment
floor/Intel/release-distribution acceptance open.

Command: `/tmp/tidyvnc-verify-document-bridge-final.py [empty|-asan|-tsan]`, plus
headless build/CTest, `python3 apps/macos/build.py`, strict `codesign --verify`,
branding audit and diff check. Logs use `/tmp/tidyvnc-document-bridge-*`; exact
paths are in DOCUMENTS.md. The initial focused CTest invocation used a build root
with no registered tests and failed; corrected explicit tests directories passed.
No empty run is counted. Native semantic file application, review, Open/Save,
launch modes and the full plan's remaining gates stay open.

### N1.3 / N3.3 shared document semantics and native resolution (2026-09-20)

DocumentOptions validates recognized file fields without constructing global
parameters. Retained loading invokes the same validator before its existing
transactional application. Boolean parsing is shared with BoolParameter and
EncodingOptions; the file catalog preserves historical names rather than accepting
CLI-only aliases. The additive document-option query copies canonical results and
redacted line errors; the ABI now has **87** exports and document provenance (5).

NativeDocumentResolution validates every known occurrence, overlays the final
assignments onto an immutable base, applies deprecated migrations after parsing,
and retains effective line provenance and inactive cursor shape. Explicit files
win over an already-resolved CLI base. Missing/empty ServerName both clear the
address. Relative verification paths require an explicit invocation directory;
legacy monitor numbers require caller-supplied stable display mappings. Unknown
and macOS-inapplicable fields stay undecoded and require explicit review before
returning the candidate. Tests include actual independent session ClientInit bytes,
view-only policy and teardown against two controlled loopback peers.

Verification on arm64 macOS 27 / Swift 6.4:

- Normal native suite **48/48 (68.78 s)**. Full ASan and TSan runs each passed the
  other **47** tests; the new document test initially assumed configured CA files
  could create a session in builds without GnuTLS. Corrected only the test: it now
  verifies typed unsupported admission and unchanged configuration, then uses a
  separate document explicitly clearing CA for the wire test. Focused native
  document tests pass **2/2** normal (0.21 s), ASan (0.33 s), TSan (4.43 s).
  Original failed run logs are retained, not reported as successful full runs.
- Shared document syntax/semantics/C ABI **17/17** normal (0.18 s), ASan (0.31 s),
  TSan (0.67 s); pure-C consumer **1/1** in each configuration.
- Headless units **672/672 (20.66 s)** and smoke **2/2 (0.29 s)**. Retained FLTK
  builds and focused document/parameter/state compatibility tests **26/26 (0.43 s)**.
- Native app builds; app and comparison bundle strict deep ad-hoc signatures pass.
  Public archive inspection finds **87** tidyvnc exports. Branding/attribution and
  whitespace checks pass. Sanitizer builds omit GnuTLS; normal/app builds include it.

Commands/scripts: `/tmp/tidyvnc-verify-document-options-final.py` and
`/tmp/tidyvnc-verify-document-options-recheck.py`, each with empty/`-asan`/`-tsan`
argument; `python3 apps/macos/build.py`; retained/headless builds and CTest in their
`tests/unit`/`tests/viewer` subdirectories; strict codesign checks and branding audit.
Logs: `/tmp/tidyvnc-document-options-*`. The recheck logs contain final focused
results after the test-only capability correction. No commit was created.

This completes the semantic/model increment, not N1.3/N3.3 or the full native UI
plan. File IO/services/panels, window/default-loader integration, stale review
identity, fresh monitor mapping, export conversion review, migration and launch
routing remain open. The deployment floor, Intel, physical multi-display,
accessibility and release-signing gates remain unverified.

### N1.9 / N3.3 / N4.1 explicit native file Open (2026-09-20)

Added NativeDocumentReading and actor-backed bounded regular-file reads, plus
unique document window requests and UUID-scoped review in NativeSessionDefaults.
Native Open (Command-O) creates a new review window after defaults/optional profile
resolution. No session exists before acceptance; file endpoint and retained
resolution metadata publish before the new idle session. Unknown/platform fields
are listed without values. Cancel/reload/close revoke review authority and suppress
late reader completion. Display mapping uses fresh x/y ordering, rejects ambiguous
origins and is revalidated before acceptance. App quit cancels its owned picker.
Clipboard provenance includes explicit document fields. Saved state remains unchanged.

Added NativeDocuments.FileReviewAndAdmission with real regular/symlink/directory/
FIFO/oversized/missing/nonfile read cases, injected delayed read, stale review
accept/cancel, topology changes, no-write/default inheritance and actual
ConnectionModel endpoint/Connect gating. All **49/49** native tests pass normal
(**67.79 s**), ASan (**80.40 s**) and TSan (**188.34 s**). Shared document/C ABI
**17/17** and pure-C consumer **1/1** pass in each build. The full script is
`/tmp/tidyvnc-verify-document-open-final.py [empty|-asan|-tsan]`; logs use
`/tmp/tidyvnc-document-open-final-native*`. Sanitizers still omit GnuTLS.

`python3 apps/macos/build.py` passes. A final view-only correction removed a parent
accessibility identifier that was overriding button identifiers; the app was
rebuilt and live AX now exposes document.cancel and document.accept independently.
A separate ad-hoc test copy (org.tidyvnc.document-open-check) verified Command-O,
controlled fixture selection, omission review, explicit acceptance to Ready with
the file endpoint, picker Cancel preserving that window, and review Cancel showing
recovery without Connect. The review screenshot was inspected. No connection was
made and the already-running viewer was left untouched. The test copy was quit.

Strict deep app/comparison ad-hoc signatures, branding/attribution audit (**1650**
existing deferred occurrences) and whitespace checks pass. App/signature/branding
logs: `/tmp/tidyvnc-document-open-final-app-build.log`,
`/tmp/tidyvnc-document-open-signature.log`, `/tmp/tidyvnc-document-open-branding.log`.
No C ABI or durable schema changes; no commit created. Host is arm64 macOS 27,
Swift 6.4, provisional floor 14 with existing newer-target Homebrew warnings.

N3.3/N4.1 stay open: Save/overwrite, exports, Finder/CLI launch and import flows,
persistent grants, detailed monitor preview/manual mapping, accessibility traversal
and physical display validation remain. See [DOCUMENTS.md](DOCUMENTS.md). Full
native UI goal remains active.

### N1.9 / N4.11 Finder delivery and SwiftUI window lifetime (2026-09-20)

Added bounded NativeDocumentLaunchRouter with complete-batch validation, local URL
and absolute filename inputs, captured invocation context, unique per-open request
IDs, FIFO/reentrant dispatch and quit revocation. AppCoordinator implements both
AppKit open callbacks; the modern URL callback is required for SwiftUI/Finder
routing on this host. ConnectionRoot supplies an app-scoped OpenWindowAction.
No file bytes, native preference writes, credentials or relaunch arguments pass
through the router. Existing review handles each file's read/semantic failures;
filename window titles distinguish mixed-batch results. Bundle identity and the
current file association are unchanged; legacy files remain explicit inputs.

The first filename-only callback launched an ordinary app window without delivering
review. An idle main-thread sample ruled out a sampled deadlock; adding the modern
URL callback fixed actual cold Finder delivery. That initial attempt is retained
as failure evidence, not counted as acceptance. Live Finder Open With checks used
org.tidyvnc.finder-check, with Always Open With unchecked, and verified cold review
plus a three-file current/legacy/malformed batch. The final Window menu identified
all three files; the malformed input had its own recovery and both valid files had
independent review. No Connect action was taken. The test copy was quit and the
user's existing viewer remained running.

NativeDocuments.LaunchRoutingAndQuit tests queue/order/bounds, nonlocal URLs,
repeated IDs, action replacement, full-batch rejection, reentrancy and stop during
dispatch. NativeDocuments.SwiftUIWindowActionLifetime is a separate signed fixture
with actual WindowGroup scenes: cold queue delivery, close all owned windows,
assert zero visible NSApp windows, warm batch delivery through the retained scene
action, and a distinct window for a repeated file. This gives direct no-visible-
window evidence independently of desktop automation activation behavior.

Final native **51/51** tests pass in normal (**70.60 s**), ASan (**81.17 s**) and
TSan (**190.32 s**). Shared document/C ABI **17/17** and
pure-C consumer **1/1** pass in each configuration. Command:
`/tmp/tidyvnc-verify-document-launch-verified.py [empty|-asan|-tsan]`.
Logs: `/tmp/tidyvnc-document-launch-verified-native{,-asan,-tsan}-full-{build,tests}.log`
and corresponding `unit-tests`/`viewer-tests` logs. Earlier 50-test runs and
focused URL/window-action reruns remain separate logs under the same launch prefix.

Final `python3 apps/macos/build.py`, strict deep app/comparison/launch-fixture ad-hoc
signatures, branding/attribution audit and whitespace checks pass. Two exact legacy
extension regression lines were added to the branding ledger as retained interfaces;
existing deferred debt stays **1650**. App/signature/branding evidence:
`/tmp/tidyvnc-document-launch-final-app-build.log`,
`/tmp/tidyvnc-document-launch-signature.log`,
`/tmp/tidyvnc-document-launch-branding.log`. Failure sample:
`/tmp/tidyvnc-finder-cold-stall.sample.txt`. No commit was created.

No C ABI or durable schema change; no C++ production changes in this increment.
Host remains arm64 macOS 27 / Swift 6.4 with provisional floor 14 and newer-target
Homebrew dependency warnings. Sanitizer crypto remains disabled. N4.11 and the
full goal remain open for CLI/reverse/listen/tunnel, installed release association,
consent/quarantine, persistent grants and the other plan gates. Save/overwrite and
imports remain document work. See [DOCUMENTS.md](DOCUMENTS.md).

### N1.3 / N3.3 current native connection export (2026-09-20)

Added `NativeDocumentExport`: immutable, owned output with a unique review ID,
explicit non-secret assignments, shared syntax/semantic preflight and typed
failures before any destination access. Compiled security and encoding defaults
are resolved explicitly; empty security allow-lists remain deny-all. Exact CA/CRL
paths, empty settings-only endpoints, clipboard, sharing/reconnect, encoding,
input, scaling and fullscreen policy round-trip through native file resolution.
Unknown source fields and credentials cannot enter the export assignment builder.

All exports disclose the omitted native remote-resize policy, even built-in
values, because a recipient can have different defaults. Stable display IDs map
only through an explicit current monitor ordering and require acknowledgement;
missing/duplicate mappings fail, including dormant Current/All selections.
Ignored original fields add a separate omission notice. The complete loss set
must be acknowledged before obtaining bytes. Nonempty custom TLS priority is
rejected, not silently dropped; native profiles retain it. Empty/default TLS
priority remains dependent on the receiving viewer's defaults.

`ConnectionModel.documentExport` captures current applied owner values on the
main actor and rejects unloaded, busy, prompting, closing, transitional and
conflicting-editor/cleanup states. It uses current session sharing, security,
encoding, clipboard and resize settings plus current native presentation/input
state. A captured export survives subsequent edits unchanged. `NativeInputState`
now preserves its latest Dot/System choice while hidden, seeded from an opened
file's dormant cursor shape rather than reverting to the original on export.

Added `NativeDocuments.LiveExportAndLossReview` (test 52): complete semantic
round trips, defaults and deny-all, hidden/visible cursors and filters, dormant
monitor selection, complete omission review, invalid/unavailable fields,
preflight line bounds, real loopback current-setting edits, copied export
isolation, conflicting editor/busy/close rejection and accepted-document shape /
ignored-input handling. Backings reject persistence; export opens no destination.

Final full native **52/52** pass in normal (**70.19 s**), ASan (**85.35 s**) and
TSan (**195.33 s**). Shared document/C ABI **17/17** and pure-C consumer **1/1**
pass in each configuration. Build/test orchestration:
`/tmp/tidyvnc-verify-export.py [empty|-asan|-tsan] [--build-only]` and
`/tmp/tidyvnc-run-export-sanitizers.py` (sanitizer UI suites run sequentially).
Logs: `/tmp/tidyvnc-document-export-native{,-asan,-tsan}-full-{build,tests}.log`
and corresponding `unit-tests` / `viewer-tests` logs. Focused normal export
checks passed before the full suites.

`python3 apps/macos/build.py` and strict deep app signature verification pass;
app build log: `/tmp/tidyvnc-export-app-build.log`. Branding/attribution audit
passes with unchanged **1650** deferred occurrences; whitespace checks pass.
No C++ production, C ABI or durable-schema change; no commit created. Host remains
arm64 macOS 27 / Swift 6.4, provisional deployment 14, newer-target Homebrew
warnings, sanitizer crypto disabled. These checks do not establish older OS,
Intel or release-signing support.

This closes the export-model/current-capture increment only. Export review UI,
Save panel, explicit overwrite, atomic destination writing, cancellation/quit
coordination, imports and CLI routing remain open under N3.3/N4.1/N4.11. The
full native UI plan remains active. See [DOCUMENTS.md](DOCUMENTS.md).


### N3.3 / N4.1 native Save As, overwrite and cancellation (2026-09-20)

Added `NativeDocumentFileWriter`, `NativeDocumentDestination` and typed Save
errors. Writer-bound metadata receipts check selected parent and target identity.
Only explicit local `.tidyvnc` destinations, absent or owned/writable/single-link
regular files, are accepted. Symlinks, directories, FIFOs, hard links, read-only
files, stale receipts and foreign-writer receipts fail. Loss review and complete
export preflight precede output creation. Exclusive temporary files have an empty
ACL and 0600 permissions before receiving bytes; old public permissions are not
propagated. Bounded writes, file/directory fsync, RENAME_EXCL creation, explicit
atomic replacement and cooperating-writer directory locks protect the commit.
Precommit failure/cancellation preserves the target and removes temporary files;
postcommit failure reports that replacement occurred and requires inspection.
Cancellation after rename cannot pretend to roll back. Parent directories and
persistent access grants are not created by the writer.

`NativeDocumentSaveState` owns one export ID through review, picker and writer
completion. Stale/early callbacks cannot write. Close cancels and joins IO and
prevents late result presentation. ConnectionModel captures before opening review,
gates competing editors/connect/export actions, and joins save cleanup with its
other owners. AppCoordinator holds panels by originating model, uses NSSavePanel's
explicit overwrite confirmation and cancels panels on window close/quit. File →
Save Connection File As… uses Command-Shift-S. Save status overlays preserve the
remote viewport size; connection alerts defer while Save is pending.

Added `NativeDocuments.AtomicSaveAndReviewLifecycle` (test 53): actual creation
and overwrite bytes/0600/empty ACL, review/overwrite authorization, stale and
concurrent edits, foreign receipts, parent replacement, wrong target types and
permissions, pre/postcommit faults, task cancellation on both sides of rename,
competing-writer lock refusal, temporary cleanup, callback identities, state
close/join and a native export-review layout fixture. Extended the export model
test with invalid-address Save gating, review/connect/editor exclusion and
connection-close review revocation.

Full native **53/53** pass in normal (**72.42 s**), ASan (**83.97 s**) and
TSan (**197.73 s**). Shared document/C ABI **17/17** and pure-C consumer **1/1**
pass in each configuration. Build orchestration:
`/tmp/tidyvnc-verify-save.py [empty|-asan|-tsan] --build-only`.
Sequential normal/ASan/TSan test driver: `/tmp/tidyvnc-run-save-sanitizers.py`.
Logs: `/tmp/tidyvnc-document-save-native{,-asan,-tsan}-full-{build,tests}.log`
and corresponding `unit-tests` / `viewer-tests` logs. The test helper's strict
Swift Sendable annotation was corrected before these successful runs.

Live UI used `/tmp/TidyVNC-Save-Check.app` with a distinct development bundle ID
and its file association removed, plus `/tmp/tidyvnc-save-ui`. Verified review
content/layout, Command-Shift-S, native destination selection, Save success,
explicit Replace confirmation, actual changed output bytes, review/picker Escape
cancellation and Quit-menu cancellation. The first menu placement at `.saveItem`
was absent in a WindowGroup app; moving the command into File fixed it. The first
suggested name doubled its extension; setting the bare stem after content types
fixed it. Final UI produced exactly `Connection.tidyvnc` with the current header,
`final-save-ui.invalid`, mode 0600 and no temporary residue. The earlier explicit
overwrite output `UI-Export.tidyvnc` contains `overwrite-ui.invalid`, also 0600.
No real connection, native connection-default/profile change or user-file overwrite was performed.

Direct Command-Q with the system Save panel open did not quit under current
computer-use input. The enabled Quit menu successfully cancels and joins shutdown;
Escape followed by Command-Q also succeeds. Temporary local-event monitoring and
direct native menu routing did not fix the observation and were removed rather
than shipped. A temporary diagnostic confirmed the menu already carried key `q`
and the Command modifier. This remains an explicit N4.11 keyboard acceptance gap;
physical-keyboard behavior is not inferred. One initial computer-control launch
call took about 16 minutes to return; subsequent checks were responsive.

No C++ production, C ABI or durable-schema change and no commit. Host remains
arm64 macOS 27 / Swift 6.4, provisional deployment floor 14 with newer-target
Homebrew dependencies, sanitizer crypto disabled. The complete native UI goal
remains active: imports, mapping recovery, CLI/reverse/listen/tunnel entry paths,
keyboard/physical-device checks and release/packaging gates remain open. See
[DOCUMENTS.md](DOCUMENTS.md).

Final cleanup `python3 apps/macos/build.py` and strict deep signatures for the
app and isolated test copy pass (`/tmp/tidyvnc-save-app-build.log`). The final
build was relaunched after removing the failed keyboard experiments: review,
correct single-extension default name, pending Save panel and Quit-menu shutdown
were checked again. Branding/attribution and whitespace audits pass with unchanged
1650 deferred occurrences. The test app was closed after the checks.

### N3.4 / N3.5 defaults import projection and transactional marker (2026-09-20)

Added `NativeDefaultsImport` with explicit current-XDG/legacy origin, affected
categories, redacted notices and an immutable ordinary-settings candidate. It
accepts the shared bounded document format, validates recognized occurrences,
then projects only an explicit allow-list through the existing native resolver.
Blank-line padding preserves source diagnostics and deprecated migrations; no
source document or excluded raw value survives in the proposal. Settings-only
imports exclude ServerName, security methods/TLS priority, CA/CRL, passwords,
user names, tunnels, trust and unknown/platform-only values. Every omission must
be reviewed. Monitor-number conversion requires supplied stable-ID mapping and
review; missing mappings fail. The unsupported dormant System cursor shape while
hidden has its own review notice. Only represented fields are materialized.

Added `NativePreferencesStore.importDefaults`: fresh native read, absence-only
admission and one same-actor transaction. Existing/reset empty state, corrupted,
future or unreadable native records cannot be overwritten or treated as absent.
Defaults schema **11** adds optional closed-enum `importedFrom` metadata. Values,
fresh revision and marker share one encoded/backing write. Ordinary saves and
resets preserve the marker, preventing reimport. Schemas 1–10 stay readable with
no write-on-read; profile/history schema remains **9**. The store's existing
UserDefaults acceptance and lack of cross-process CAS guarantees are unchanged.

Added `NativeImport.DefaultsProjectionAndCommit` (test 54): explicit origins,
all supported categories, excluded secrets/address/security, unknown/platform
handling, complete review, canonical options, deprecated migrations, mapped
monitor defaults, hidden cursor loss, original error lines, malformed earlier
known fields, maximum-size/no-final-newline input, concurrent import admission,
existing native precedence, reset idempotence, before-admission cancellation,
read/write rejection, uncertain accepted-write reconciliation, closed stores and
strict migration-marker decoding. Updated current-writer schema assertions;
historical fixtures remain historical and unsupported future schema is now 12.

Full native **54/54** pass in normal (**73.70 s**), ASan (**87.07 s**) and
TSan (**202.11 s**). Shared document/C ABI **17/17** and pure-C consumer **1/1**
pass in all three configurations. Commands:
`/tmp/tidyvnc-verify-import.py [empty|-asan|-tsan] --build-only` and
`/tmp/tidyvnc-run-import-tests.py` (UI suites run sequentially).
Logs: `/tmp/tidyvnc-defaults-import-native{,-asan,-tsan}-full-{build,tests}.log`
and corresponding `unit-tests`/`viewer-tests` logs. Focused import/preferences
checks passed before the full runs. `python3 apps/macos/build.py` and strict deep
app signature verification pass; log `/tmp/tidyvnc-import-app-build.log`.
Branding/attribution passes with **1650** unchanged deferred occurrences and
whitespace checks pass. No commit was created.

No C++ production or C ABI change. Host remains arm64 macOS 27 / Swift 6.4,
provisional deployment 14 with newer-target dependencies; sanitizer crypto is
disabled. This does not establish release signing, older-OS or Intel support.

This is the defaults projection/store increment, not completion of N3.4/N3.5.
XDG/legacy candidate discovery, bounded source-read orchestration, fresh preview /
display identities, first-use/explicit UI and separate history import remain open.
No app startup migration or real user-data import was enabled. Future UI tests
must inject a disposable store: changing the bundle identifier alone does not
isolate the fixed native UserDefaults suite. See [IMPORTS.md](IMPORTS.md).


### N3.4 / N3.5 defaults source discovery and review lifecycle (2026-09-20)

Added `NativeImportPaths`, `NativeDefaultsImportService` and
`NativeDefaultsImportState`. Paths take explicit home/environment inputs; absolute
XDG overrides are independent, relative/tilde overrides are ignored, invalid
absolute paths fail, and dot/parent components are preserved across symlinks.
Path construction performs no filesystem probing. Current and ordered legacy
XDG/home defaults/history filenames match retained compatibility policy, but this
service reads defaults only. Four exact legacy filename/test occurrences were
added to the branding ledger as `retain-interface`; deferred debt stays 1650.

Native storage is checked before source inspection and freshly at commit. Existing
current-XDG defaults also block a legacy request. Only absence selects the next
legacy path: malformed, denied, oversized, directory/FIFO and dangling sources
fail without fallback. Component inspection also detects dangling/non-directory
ancestors. Reads use the existing bounded regular-file reader off the main actor.
Regular-file symlinks and read-only sources remain usable without modifying the
source or its permissions. Inspection/open is not a hostile-filesystem snapshot.

Reviews retain an immutable projection, source URL and explicit monitor ordering.
Commit uses exactly the reviewed snapshot even if the source later changes, and
monitor conversion rejects ambiguous/invalid or changed mappings. Request IDs and
preview IDs have separate roles; stale approval/cancellation callbacks cannot
accept another preview. Incomplete acknowledgements preserve review. Cancellation
drains an in-flight read before restart; shutdown cancels/joins, suppresses late
UI delivery and preserves the distinction between pre-write cancellation and a
write already accepted by the backing store. Errors use controlled messages.

Added test 55, `NativeImport.SourceDiscoveryAndReviewLifetime`, with disposable
filesystem roots and an in-memory preferences backing. Coverage includes path
policy and original ordering, no directory creation, missing vs failing source,
current/legacy/native precedence, regular/dangling symlinks and ancestors,
read-only/denied sources, FIFO rejection, 1 MiB limit, malformed native state,
exact reviewed bytes, incomplete acknowledgement, fresh native-state conflicts,
duplicate/reordered monitors, stale callbacks, late source completion, restart,
close/join and cancellation on both sides of accepted-write completion.

This increment does not wire startup/menu imports or read history, create sessions,
copy credentials/trust, alter schemas/C ABI or modify user preferences. Defaults
schema remains 11; profile/history remains 9. First-use/explicit UI and separate
history consent/transactions remain open. See [IMPORTS.md](IMPORTS.md).

Validation: complete native suite **55/55** passes (**72.89 s**), shared document /
C ABI **17/17** and pure-C consumer **1/1** pass. Focused import projection, source
lifecycle and file-review tests pass **3/3 ASan (1.07 s)** and **3/3 TSan (7.64 s)**;
the whole sanitizer suites were not rerun for this increment. Builds use Swift 6
strict concurrency with warnings as errors. `python3 apps/macos/build.py` and
strict deep app-signature verification pass. Branding/attribution and whitespace
audits pass. An initial test-helper autoclosure compile error was fixed before the
successful runs; Xcode emitted existing simulator-service diagnostics while the
native macOS build completed successfully.

Build driver: `/tmp/tidyvnc-verify-import-flow.py --build-only`. Logs:
`/tmp/tidyvnc-import-flow-native-full-{build,tests}.log`, corresponding
`native-unit-tests` / `native-viewer-tests` logs,
`/tmp/tidyvnc-import-flow-{asan,tsan}-{build,tests}.log`, and
`/tmp/tidyvnc-import-flow-app-build.log`. Full suite used AppKit/loopback access
and isolated preference domains; new import tests used only their own fixtures.
No interactive import UI was enabled or exercised and no commit was created.
Host remains arm64 macOS 27 / Swift 6.4; provisional deployment 14 and newer-target
Homebrew dependencies remain, with crypto disabled in sanitizer configurations.
Older-OS/Intel/release-signing and the outstanding native UI gates are unchanged.


### N3.4 / N3.5 defaults import UI and first-use offer (2026-09-20)

Added the File-menu **Import Connection Defaults…** action and a dedicated native
window using the existing source/review/store pipeline. Current and legacy sources
are separate actions. The review shows affected categories, redacted omission
names/lines and the captured display numbering/names; an explicit acknowledgement
is required before Import becomes enabled. Empty ordinary-settings candidates
cannot be committed from the UI. Acceptance refreshes display ordering. Cancel /
Escape returns to choices without writing, and absence/error/success are distinct.
Success offers a new connection because existing windows retain resolved values.

Added `DefaultsImportAvailability`, which observes the owning native store and
refreshes on app activation. Only an absent native record permits the first-use
offer in idle ordinary connection windows; saved, corrupt or inaccessible state
is not absence. Not Now dismisses the offer for this launch without a marker or
source read. File-menu import remains available for explicit review/error recovery.
No compatibility file is read at startup. Paths use the explicit launch home and
XDG environment. Defaults import does not include recent-address history.

Each presentation owns a fresh state; Close revokes callbacks and joins pending
IO before releasing its content. App shutdown joins the import controller and
availability observer before closing the preferences store. AppKit owns window
size so changing from choices to review cannot shrink the window. Scrollable
notices keep acknowledgement/actions outside the scroller. The view follows the
existing StateObject pattern after the current SDK's State macro plugin failed
in both CMake and Xcode builds. No production workaround for app termination was
introduced.

Added test 56, `NativeImport.NativePresentationAndFirstUse`, compiling the actual
production view/controller in `native-import-ui-tests.app`. It injects an in-memory
preferences backing, disposable current/legacy sources and synthetic displays;
it never accesses real preferences, profile/history, trust or credential stores
and never starts a network session. Automated checks cover eligibility updates,
malformed native state, review cancellation, stale preview IDs, changed monitor
order, reviewed values/source preservation, current and legacy commits, precedence,
close/reopen and shutdown. Light/dark review, choices, error and success captures
are in `build/native-ui-swift/tests/macos/import-ui-render`.

The first layout check compared unconstrained intrinsic size to a resizable
window. It was replaced by a bounded `NSHostingController.sizeThatFits` check;
AppKit-owned sizing also fixed the observed width change. Transparent PNG
backgrounds were corrected and light/dark captures inspected. The test initially
hung only when requesting deferred AppKit termination from a Swift task (a dispatch
block had the same behavior). A native run-loop selector now requests termination
like a menu action; the test confirms window and availability shutdown drain.

Live computer-use checks ran only the isolated fixture. Verified Return to review,
Import disabled before acknowledgement, scrolling through monitor conversion,
acknowledgement enabling Import, Return to commit, success text, Escape review
cancellation, Done closing, current-data precedence over legacy, current-source
absence without automatic fallback, explicit legacy review/import and Command-Q
termination. The computer-control tool could not return an accessibility tree
for the windowless fixture after Done (app inventory still reported it live);
Command-Q closed it, and automated close/reopen passed. The first launch tool call
took about 7.7 minutes to return; subsequent launches were responsive. The user's
existing viewer was left alone, no real import was performed, and the fixture
was confirmed exited after live checks.

Defaults-only UI is complete for this increment. History import, full first-use
migration across defaults/history, display-mapping recovery and the remaining
launch/keyboard/physical-device/release gates stay open. Defaults/profile schemas
remain 11/9 and the C ABI is unchanged. See [IMPORTS.md](IMPORTS.md).

Validation: complete native suite **56/56** passes (**73.80 s**), shared document /
C ABI **17/17 (0.20 s)** and pure-C consumer **1/1 (0.22 s)** pass. Focused import
projection/source/UI and file-review tests pass **4/4 ASan (2.62 s)** and
**4/4 TSan (11.73 s)**; entire sanitizer suites were not rerun for this increment.
`python3 apps/macos/build.py` and strict deep app-signature verification pass.
Branding/attribution and whitespace audits pass with unchanged 1650 deferred
occurrences. No commit was created.

Build driver: `/tmp/tidyvnc-verify-import-ui.py --build-only`. Logs:
`/tmp/tidyvnc-import-ui-native-full-{build,tests}.log`, corresponding
`native-unit-tests` / `native-viewer-tests` logs,
`/tmp/tidyvnc-import-ui-{asan,tsan}-{build,tests}.log`,
`/tmp/tidyvnc-import-ui-tests.log` (focused verbose UI lifecycle) and
`/tmp/tidyvnc-import-ui-app-build.log`. Host remains arm64 macOS 27 / Swift 6.4,
provisional deployment 14 with newer-target Homebrew dependencies and crypto
omitted in sanitizer builds. No older-OS, Intel or release-signing claim is made.


### N3.4 / N3.5 separate history projection and transaction (2026-09-20)

Added `NativeHistoryImport` for a separately consented address list. UTF-8 input is
bounded to 1 MiB, each entry to the retained legacy importer’s 254 bytes; LF/CRLF,
blank lines and no final newline are supported. First occurrences retain source
order/spelling/whitespace, with the first 20 unique strings kept. Duplicate and
older-entry omission counts require explicit acknowledgement. Validation includes
all lines after capacity, and errors contain only line numbers/reasons. There is
no option parser, DNS resolution, connection, credential/trust lookup or source
write. Exact-string duplicate comparison matches the native store's Swift String
equality, without endpoint-alias normalization.

Added `NativeHistoryImportService`, independently selecting current or legacy
history paths. Settings-file presence does not imply history consent/precedence.
Native state is checked first; existing current history blocks legacy; only true
absence allows fallback. The existing source inspector was factored for both
services, preserving bounded read/cancellation/failure behavior. Reviews capture
the immutable list, origin, source URL and shared native revision. Source changes
cannot substitute new addresses; intervening native profile/history edits require
fresh review. History service/UI orchestration is not wired into startup or menus.

Profile/history schema **10** adds required closed-enum `historyState`:
uninitialized/native/currentXDG/legacy. An absent record is uninitialized; new
profile-only saves/deletes preserve that eligibility. Recording native history or
explicitly clearing even an empty history initializes it. Imported addresses,
fresh revision and marker share one private-file expected-byte transaction, and
all existing profiles/settings/opaque credential references are preserved. Later
recordings, removals, clears and profile edits retain the first import marker.
Older schemas 1–9 remain read-only compatible and authoritative even when empty,
because they cannot distinguish untouched history from a deliberate prior clear.
Unknown/missing/wrong-type state and uninitialized/nonempty history fail closed.
Defaults schema remains **11**; no C ABI or C++ production change.

Added test 57, `NativeImport.HistoryProjectionAndTransaction`: bounds, UTF-8/CRLF,
exact ordering/spelling, complete validation past capacity, omission consent,
old-schema/no-write reads and upgrades, strict metadata, profile-only eligibility,
profile preservation/deletion, native clear/record precedence, marker retention,
cancelled/denied/rejected writes, independent-store CAS races, private-file faults
before/after rename, uncertain accepted-write reconciliation, 0600 output/temp
cleanup, current/legacy/native source precedence, immutable previews, native edit
conflicts and cancellation during a delayed source read. Updated current-writer
schema expectations and future-schema fixture; historical fixtures stay historical.

The app still exposes defaults import only. History review UI, its own first-use
offer, recent-list refresh after success and complete defaults/history migration
remain open. `NativeRecentHistory` must be explicitly reloaded after import because
the profile/history store has no subscription. See [IMPORTS.md](IMPORTS.md).

Validation: all native consumers rebuilt for the expanded Swift snapshot. Complete
native suite **57/57** passes in normal (**76.15 s**), ASan (**88.59 s**) and
TSan (**211.52 s**). Shared document/C ABI **17/17** and pure-C consumer **1/1**
pass in all three configurations. `python3 apps/macos/build.py` and strict deep
app-signature verification pass. Branding/attribution and whitespace audits pass
with unchanged 1650 deferred occurrences. No commit was created.

Build driver: `/tmp/tidyvnc-verify-history-import.py [empty|-asan|-tsan] --build-only`.
Sequential suite driver: `/tmp/tidyvnc-run-history-import-tests.py`. Logs:
`/tmp/tidyvnc-history-import-native{,-asan,-tsan}-full-{build,tests}.log` and
corresponding `unit-tests` / `viewer-tests` logs;
`/tmp/tidyvnc-history-import-app-build.log`. Focused projection/store/source checks
passed before the full runs. The complete suite used AppKit/loopback access and
isolated stores; new history tests used only temporary sources, in-memory stores
and private disposable file roots. No real user-data history import was performed.
Host remains arm64 macOS 27 / Swift 6.4; provisional deployment 14 with newer-target
Homebrew dependencies, sanitizer crypto disabled. Older-OS/Intel/release signing
and remaining full-plan gates remain unproven.


### N3.4 / N3.5 history import UI and app integration (2026-09-20)

Added `NativeHistoryImportState`, with distinct loading/request and immutable review
identities, omission acknowledgement, controlled history-specific errors, cancelled
read drain and close/join. Accepted writes are never reported as rolled back; closed
presentations suppress late delivery. Added a native history window with independent
current/legacy choices, source path and ordered address list, visible omission counts,
explicit acknowledgement, empty/error/absence/success states and Escape cancellation.
Import is disabled for empty lists. Each presentation owns a fresh state.

The app exposes File → Import Recent Connections and an independent first-use offer
in idle ordinary connection windows. `NativeRecentHistory` derives eligibility from
fresh snapshots and suppresses it during busy/error/closed state. Not Now dismisses
only the launch-local offer. Success and window close reload the shared recent list;
app activation also refreshes it. App shutdown joins the import window before closing
the shared store. History service setup is independent of preferences/runtime setup.
No compatibility source is read merely to display an offer, and no connection starts
as a result of import. Defaults/profile schemas remain 11/10; C ABI unchanged.

Added test 58, `NativeImport.HistoryPresentationAndFirstUse`, compiling the production
view/controller with in-memory native storage and generated temporary sources. Covers
late read suppression, cancellation drain, accepted-write close, stale approval IDs,
omission consent, intervening native clear, exact recent-list refresh, immutable
sources, close/reopen, repeated import, corrupt-native eligibility, current-over-legacy
precedence, current absence without fallback, explicit legacy and empty review.
Light/dark review, choices, conflict, success and empty states render within bounds.

Live computer-use checks on the isolated fixture verified Return to current review,
Import disabled before acknowledgement, address-list scrolling, acknowledgement
activation, Escape cancellation, fresh-review acknowledgement reset, Return to import,
20-address success and Command-Q shutdown. Fixture exit was confirmed. No real
user history, settings, credentials or network sessions were used.

N3.4/N3.5 implementation is now checked complete. Broader end-to-end combined
first-use acceptance on supported OS/architectures, display-mapping recovery,
remaining entry paths, physical-device and packaging/release gates remain open.

Validation: full native suite **58/58 (72.68 s)** passes. Focused native import,
history and profile suites pass **8/8 ASan (6.93 s)** and **8/8 TSan (26.36 s)**;
full sanitizer suites were rebuilt but not rerun for this increment. Shared
document/C ABI **17/17** and pure-C consumer **1/1** pass in normal/ASan/TSan.
App build and strict deep signature verification pass. Branding/attribution
passes with unchanged 1650 deferred occurrences; whitespace audit passes.
No commit was created. Host remains arm64 macOS 27 / Swift 6.4, provisional
minimum 14 with newer-target Homebrew dependencies; sanitizer crypto remains
disabled. This does not establish older-OS, Intel or distributable signing.

Build driver: `/tmp/tidyvnc-verify-history-ui.py [empty|-asan|-tsan] --build-only`.
Focused sanitizer/ABI driver: `/tmp/tidyvnc-run-history-ui-checks.py`. Logs:
`/tmp/tidyvnc-history-ui-native-full-tests.log`,
`/tmp/tidyvnc-history-ui-native{,-asan,-tsan}-full-build.log`,
`/tmp/tidyvnc-history-ui-native-{asan,tsan}-macos-tests.log`, corresponding
`unit-tests`/`viewer-tests` logs and `/tmp/tidyvnc-history-ui-app-build.log`.
Render captures are in `build/native-ui-swift/tests/macos/history-import-ui-render`.


### N3.3 / N4.14 explicit-file monitor mapping recovery (2026-09-20)

Added sparse, bounded monitor-mapping requests and optional explicit stable-ID
assignments to document resolution. The request retains the exact parsed file,
resolved native base and invocation directory; all known-value validation and
ignored-field review remain enforced. Required keys must match exactly, IDs must
be valid, and user-chosen many-to-one assignments use each display once. At most
64 distinct file monitor numbers are offered; Int32 maximum indices never become
array sizes. Inherited stable selections and deprecated all-monitor migration
keep their existing semantics.

Unresolved/ambiguous/mirrored explicit-file numbering now opens a native display
chooser. Automatic review also offers Change Display Assignments. Pickers require
connected displays, show unresolved disconnected choices, preserve connected manual
assignments on edit and explain many-to-one use. Resolve produces a new final
review showing each file-number/display-name pair and the original ignored fields.
No session is created before final acceptance. Current topology is rechecked;
manual mappings follow stable IDs across rearrangement, and changed availability
revokes review and offers recovery using the retained file. Request/review IDs,
cancel/close and ready-session guards reject stale callbacks. No store/source write,
credential/trust lookup or network connection is added.

Added test 59, NativeDocuments.DisplayMappingRecovery, with production mapping/
review views, synthetic mirrored/disconnected displays, in-memory preferences and
a fake reader. It checks sparse/duplicate/invalid/incomplete/extra mappings, implicit
monitor one, inherited selections, legacy all-monitor migration, malformed known
values, a 64-monitor UI bound, immutable changed-source handling, stale IDs, edit
preservation, many-to-one selection, cancellation, topology failure and final idle
session admission. Light/dark chooser, final review and opened states fit renders.

Live fixture checks verified picker choices, disabled Review until complete,
Return to final review with exact display names, re-edit preserving assignments,
Escape cancellation and Command-Q shutdown. Fixture exit was confirmed. The first
computer-use launch took about 15 minutes to return; subsequent interactions were
responsive. Only isolated fixture data/synthetic displays were used. No real
connection was started. Import/export mapping recovery, physical multi-display/
Spaces, remaining launch paths and wider release acceptance remain open.


The first full native run caught a regression in monitor-number extraction:
calling the shared value validator for every field decoded an opaque `Audio=\q`
value that native document review intentionally leaves untouched. The helper now
validates only the three monitor fields; the enclosing resolver still validates
all other supported fields. Existing semantic test 47 detected it, and the mapping
fixture now also checks a platform-only future escape with manual assignments.
The initial failing log is retained at
`/tmp/tidyvnc-monitor-mapping-native-initial-failure.log`; final validation follows.


Final validation after the opaque-field fix: full native suite **59/59** passes in
normal (**78.19 s**), ASan (**91.03 s**) and TSan (**219.05 s**). Shared document/C ABI
**17/17** and pure-C consumer **1/1** pass in all three configurations. App build and
strict deep signature verification pass. Branding/attribution passes with unchanged
1650 deferred occurrences; changed-source and git whitespace checks pass. The C ABI
remains 87 exports and durable schemas remain defaults 11 / profiles-history 10.
No commit was created.

Build driver: `/tmp/tidyvnc-verify-monitor-mapping.py [empty|-asan|-tsan] --build-only`.
Suite driver: `/tmp/tidyvnc-run-monitor-mapping-tests.py`. Logs:
`/tmp/tidyvnc-monitor-mapping-native{,-asan,-tsan}-full-{build,tests}.log`, corresponding
`unit-tests` / `viewer-tests` logs and `/tmp/tidyvnc-monitor-mapping-app-build.log`.
The initial regression log is retained separately; final logs above are green.
Captures: `build/native-ui-swift/tests/macos/document-mapping-ui-render`.
Light/dark chooser and final review captures were visually inspected. Host remains
arm64 macOS 27 / Swift 6.4, provisional minimum 14 with newer-target Homebrew
libraries; sanitizer crypto remains disabled. Older-OS, Intel, physical monitor/
Spaces and distributable signing acceptance are not established by these fixtures.


### N3.3 / N4.14 export monitor-number recovery (2026-09-20)

Added immutable NativeDocumentExportCapture with complete format preflight before UI,
retained session values/endpoint/inactive cursor and display-name/order snapshots.
Save As now offers monitor-number recovery when saved IDs cannot be automatically
numbered. The chooser requires exact coverage, distinct positive decimal Int32
numbers and no fabricated assignments for unavailable displays. Automatic numbering
can be edited too; disconnected and dormant Current/All selections remain represented.
Stable IDs and captured display names remain UI metadata and are not serialized.
Manual numbering changes only the export, never live fullscreen selection or stores.

NativeDocumentSaveState retains one sheet presentation identity across mapping and
final review, while mapping requests and resulting exports have fresh UUIDs. Editing
preserves chosen numbers. Stale resolve/approve/cancel/presentation callbacks are
rejected; only current export approval dismisses toward the existing destination
panel. The review lists each display/number and all existing format-loss notices.
A stable sheet container fixes the initially observed clipping when the shorter
chooser transitioned to final review; scrolling keeps bounded mapping lists usable.
Existing native save/overwrite/cancellation semantics are unchanged.

Added test 60, NativeDocuments.ExportMappingAndSheetLifetime, using the production
SwiftUI sheet inside an AppKit window and an isolated temporary destination. It
covers sparse bounds and malformed/duplicate/extra/incomplete numeric assignments,
immutable captured settings, dormant IDs, custom-TLS/invalid-path preflight, exact
reviewed numbering, re-edit preservation, stale identities, one sheet across steps,
one approved onDismiss handoff, complete saved bytes without display IDs/names,
automatic mapping editing, cancel and shutdown. The fixture substitutes only its
private destination for NSSavePanel; system-panel keyboard acceptance stays separate.
Initial layout validation found the final review was taller than the initial chooser
sheet; a fixed presentation size resolves the mismatch, with light/dark rendering.
Defaults-import mapping recovery and wider launch/physical-device/release gates remain.


Live computer-use checks on the isolated fixture verified duplicate numbers keeping
Review disabled, distinct values enabling Return to review, exact numbers/loss text,
re-edit preservation, Escape cancellation, fresh review and Return through the
fixture-only save handoff to a Saved Fixture.tidyvnc result. Command-Q and fixture
exit were verified. The first launch returned after about 28 seconds. No real
connection, native store, credential/trust source or user destination was used.
Light/dark chooser and final review captures were visually inspected.


Validation: full native suite **60/60 (80.64 s)** passes. Focused document suites
pass **9/9 ASan (6.09 s)** and **9/9 TSan (23.96 s)**, including semantic resolution,
file review, launch, export, atomic saving and both mapping flows. All native
consumers were rebuilt in each configuration; unrelated sanitizer suites were not
rerun for this increment. Shared document/C ABI **17/17** and pure-C consumer **1/1**
pass in normal/ASan/TSan. App build and strict deep signature verification pass.
Branding/attribution passes with unchanged 1650 deferred occurrences; source/git
whitespace checks pass. C ABI remains 87 exports; schemas remain defaults 11 and
profiles/history 10. No commit was created.

Build driver: `/tmp/tidyvnc-verify-export-mapping.py [empty|-asan|-tsan] --build-only`.
Test driver: `/tmp/tidyvnc-run-export-mapping-tests.py`. Logs:
`/tmp/tidyvnc-export-mapping-native-full-tests.log`,
`/tmp/tidyvnc-export-mapping-native-{asan,tsan}-document-tests.log`, corresponding
`unit-tests` / `viewer-tests` logs, full-build logs and
`/tmp/tidyvnc-export-mapping-app-build.log`. Captures are in
`build/native-ui-swift/tests/macos/export-mapping-ui-render`.
Host remains arm64 macOS 27 / Swift 6.4, provisional floor 14 with newer-target
Homebrew libraries and sanitizer crypto disabled. No older-OS, Intel, physical
multi-display, system-panel keyboard or distributable-signing claim is added.


### N3.4 / N4.14 defaults-import display recovery (2026-09-20)

Defaults import now offers a connected-display chooser when legacy monitor numbers
cannot resolve, including mirrored and missing arrangements. Automatic assignments
can be edited too. The shared monitor helper operates on an immutable allow-listed
projection, not the original source document: excluded/unknown values and source
bytes are never retained for recovery. Required sparse positive Int32 numbers are
bounded to 64 distinct choices; multiple file numbers may select one stable display.

Mapping resolution uses current connected IDs and creates a fresh review with all
original redacted omissions/conversions. Editing preserves connected choices and
clears UI acknowledgement. Request, mapping and review identities reject stale
callbacks; cancel/close discard recovery and join pending reads. Automatic final
imports check current legacy order; explicit assignments check current available-ID
membership. Changed availability fails without writing, while same-ID rearrangement
is allowed. Current-over-legacy source precedence and absence-only native commit
remain unchanged. Source changes after projection cannot replace reviewed values.

Added test 61, NativeImport.DefaultsMappingRecovery, compiling the production view
and controller with temporary sources, an injected memory store and synthetic mirrored
displays. It checks sparse bounds, incomplete/disconnected assignments, automatic
editing, exclusion from retained data, immutable source, separate omission consent,
stale identities, topology, many-to-one conversion, origin/value atomicity, competing
native state, cancellation/read drain and close revocation. No real source/store,
credential/trust service or network connection is used by this fixture.

Live computer-use checks verified disabled Review with incomplete choices, native
picker mouse/keyboard selection, exact final display names/numbers, preserved re-edit
choices and reset acknowledgement, Escape cancellation, fresh many-to-one review,
Return to successful fixture-only import, and Command-Q exit. First launch observation
took about 19.6 minutes; the fixture then responded normally. This delay is not evidence
that the Mac was locked. Light/dark chooser captures were visually inspected, and the
scrolling review exposes omissions and exact assignments with fixed footer actions.

Broader CLI/entry-path, physical multi-display/Spaces, supported-OS/architecture and
release gates remain open. No completion of the overall native UI plan is claimed.


Validation: full native suite **61/61 (81.26 s)** passes. Focused import/document
suites pass **15/15 ASan (12.47 s)** and **15/15 TSan (45.45 s)**. All native consumers
were rebuilt in each configuration; unrelated sanitizer suites were not rerun for
this increment. Shared document/C ABI **17/17** and pure-C consumer **1/1** pass in
normal/ASan/TSan. App build, strict deep signature verification, branding/attribution
(unchanged 1650 deferred occurrences) and source/git whitespace checks pass. C ABI
remains 87 exports; schemas remain defaults 11 and profiles/history 10. No commit
was created. The live fixture exited and removed its private temporary directory.

Build driver: `/tmp/tidyvnc-verify-defaults-mapping.py [empty|-asan|-tsan] --build-only`.
Test driver: `/tmp/tidyvnc-run-defaults-mapping-tests.py`. Logs:
`/tmp/tidyvnc-defaults-mapping-native-full-tests.log`,
`/tmp/tidyvnc-defaults-mapping-native-{asan,tsan}-import-document-tests.log`,
corresponding `unit-tests` / `viewer-tests` and full-build logs, and
`/tmp/tidyvnc-defaults-mapping-app-build.log`. Rendered captures are in
`build/native-ui-swift/tests/macos/defaults-mapping-ui-render`.
Host remains arm64 macOS 27 / Swift 6.4, provisional floor 14 with newer-target
Homebrew libraries and sanitizer crypto disabled. No older-OS, Intel, physical
multi-display, system-panel keyboard or distributable-signing claim is added.


### N0.7 / N1.2 / N2 invocation syntax and owned native boundary (2026-09-20)

Extracted the argument lexer from retained Configuration::handleArg into a pure
shared helper, including the exact separate-boolean token rule. The retained
registry now uses it without changing consumed arguments or option mutation.
Added stateless InvocationSyntax with bounded owned argv snapshots, canonical
names/aliases, ordered raw occurrences and option/value argument indices. Syntax
success deliberately does not validate values or authorize actions. Duplicate and
malformed earlier values remain available to the later semantic resolver. Help/
version stop scanning but retain preceding assignments for validation; unused
positional text is discarded. No quoting/escaping, shell/environment/file/network
work, settings mutation or input-bearing diagnostic is introduced.

The explicit viewer option catalog derives encoding metadata from the shared schema
and classifies CLI-only controls, credential-file paths and platform capabilities.
The normal compiled catalog exactly matches all **46** canonical names/aliases in
the retained viewer's --help output. The comparison ran with isolated HOME/XDG
paths, exited before viewer UI startup and preserved the retained help exit status 1. Retained
boolean aliases keep their historical lookahead distinction; tests compare actual
registry consumption. Operands stay unclassified until the host can inspect a file
or Unix socket through the proper service. Unknown unprefixed name=value retains
its positional fallback. No plaintext password or ServerName CLI option is invented.

Four C exports provide parse, metadata, assignment and catalog queries (now **91**
exports, verified from the archive). The immutable handle owns all input; borrowed
value/operand spans remain valid only while retained, and Swift copies them before
release. Output headers/types/bounds, redacted indexed failures, allocation fault
injection and concurrent readers are covered, including a pure-C consumer. New
native test 62 checks copied Unicode/literal values, aliases, positions, catalog,
terminal actions, limits, typed errors and concurrent parsing. C++ remains C++11;
no new OS/UI types enter the public C contract.

The native app still does not consume CLI arguments. Semantic resolution, file-after-
CLI precedence, strict raw-argv text conversion, help/version bootstrap, scoped
password-file/environment handling, reverse/listen and tunnel adapters remain
required. The complete implementation sequence is recorded in [CLI.md](CLI.md).
No parent CLI/parity/release task is marked complete by this foundation.


Validation: full normal native suite **62/62 (80.88 s)**; focused Swift invocation
**1/1 ASan (0.30 s)** and **1/1 TSan (2.26 s)**. ConfigArgs/invocation/C ABI/document
regressions **67/67** pass in normal (1.47 s), ASan (1.91 s) and TSan (2.89 s).
The updated pure-C consumer passes **1/1** in all three configurations. All native
consumers were rebuilt; unrelated native sanitizer suites were not rerun for this
increment. Native app build and strict deep signature verification pass. The retained
FLTK viewer rebuild and its **5/5 ConfigArgs** checks pass using the existing
`build/hidpi-debug-shared` dependency configuration. Branding/attribution (1650
unchanged deferred occurrences) and tracked/new-source whitespace checks pass.
Defaults/profile-history schemas remain 11/10; no stores were migrated or commits
created. No installed launch or physical-device acceptance is inferred.

The initial `build/macos` rebuild had a stale FLTK 1.3 discovery path; the existing
FLTK 1.4 dependency under `build/hidpi-debug-shared` was used successfully. Initial
ASan GoogleTest registration failed before any test body because uninstrumented
Homebrew GoogleTest mixed with instrumented libc++ containers. Reconfigured only
the ASan verification tree to the existing matching instrumented dependency at
`build/native-ui-encoding-deps/asan-install/lib/cmake/GTest`; no sanitizer check was
disabled. The full rebuild and final focused suites above passed. Initial failure
is retained in `/tmp/tidyvnc-invocation-asan-gtest-registration-failure.log`.

Build driver: `/tmp/tidyvnc-verify-invocation.py [empty|-asan|-tsan] --build-only`.
Test driver: `/tmp/tidyvnc-run-invocation-tests.py` (or `--normal-only`, `--asan-only`,
`--tsan-only`). Logs: `/tmp/tidyvnc-invocation-native-full-tests.log`,
`/tmp/tidyvnc-invocation-native-{asan,tsan}-focused-tests.log`, corresponding
`unit-tests` / `viewer-tests` / full-build logs, `/tmp/tidyvnc-invocation-app-build.log`,
`/tmp/tidyvnc-invocation-retained-{build,tests,help}.log` and
`/tmp/tidyvnc-invocation-catalog.json`. Host remains arm64 macOS 27 / Swift 6.4,
provisional deployment floor 14, newer-target Homebrew dependencies and crypto-disabled
sanitizer builds. Older OS, Intel and distributable signing remain unverified.


### 2026-09-20 — CLI value validation and native injected resolution

Implemented an immutable canonical invocation copy, with every occurrence validated
before duplicate folding. `documentOptionValue` now supplies decoded common-field
validation to both document and CLI paths; literal CLI values bypass file escaping
and line bounds. CLI-only booleans/integers and Log structure receive stateless
validation. A fifth invocation C export, `tidyvnc_invocation_validate`, publishes
only complete owned values; C ABI count is now **92**. Swift NativeInvocationOptions
copies validated values and retains typed, indexed, redacted errors.

NativeInvocationResolution applies ordinary connection/encoding/input/security/
scaling/fullscreen settings plus resize policy and checked legacy DesktopSize
spellings. Paths use the supplied invocation cwd without lexical normalization.
NativeSessionDefaults/ConnectionModel accept an injected request after native
preferences/profile and before explicit files, publish metadata before the idle
session, and reject unsupported adapters before file IO. There are no launch-time
store writes or automatic connections. A native error presentation exists for
injected invocation failures; executable bootstrap still does not supply requests.

Factored NativeOptionOverlay shares file/CLI application. Immutable compatibility
metadata preserves hidden System cursor shape and deprecated DotWhenNoCursor /
FullScreenAllMonitors flags through file review, sparse monitor mapping and edits.
Migration repeats after file assignments, including inherited CLI flags, until an
explicit file disables them. Effective provenance remains correct without treating
argv indices as file line numbers. Added regression coverage for these cases,
canonical ownership/failure atomicity, invalid earlier values before help, literal
long paths, unsupported adapters, profile/default/file precedence, ConnectionModel
admission, cancellation and unchanged stores.

Validation: full normal native suite **63/63 (73.20 s)**. Focused native invocation
checks **2/2 ASan (0.11 s)** and **2/2 TSan (4.21 s)**; focused core/C ABI/document/
ConfigArgs checks **70/70 normal (1.51 s), ASan (2.01 s), TSan (3.13 s)**. Pure-C
consumer **1/1** in all three configurations. Affected native document/import
regressions additionally pass **15/15 ASan (12.33 s)** and **15/15 TSan (45.28 s)**.
All native consumers rebuilt in all
three configurations. Retained FLTK viewer/document/config targets build and their
**15/15** selected regressions pass. Native app build, strict deep signature check,
branding/attribution audit (1650 unchanged deferred occurrences), tracked diff and
new-source whitespace checks pass. Native schemas remain defaults 11 / profiles-
history 10. No commits or user-store migrations were made.

The initial broader execution under the sandbox could not bind loopback sockets
(`EPERM`) or access AppKit display services. Re-running the isolated fixtures with
those capabilities passed; no assertion/sanitizer check was disabled. Initial
sandbox failure logs remain `/tmp/tidyvnc-invocation-native-full-tests-sandbox-failure.log`
and `/tmp/tidyvnc-invocation-native-{asan,tsan}-unit-tests-sandbox-failure.log`. Final logs are
`/tmp/tidyvnc-invocation-native-{full,unit,viewer}-tests.log`, equivalent ASan/TSan
focused/unit/viewer logs, all-three full-build logs, and
`/tmp/tidyvnc-invocation-values-{app-build,retained-build,retained-tests}.log`.
Document/import sanitizer logs are
`/tmp/tidyvnc-invocation-values-{asan,tsan}-document-import-tests.log`.

Remaining: complete CLI monitor recovery across file overrides (the injected API
currently requires resolved CLI mapping before file IO), other native option
adapters, strict raw argv decoding, executable/help/version bootstrap, file/socket
classification, password-file/environment ownership, listen/reverse and tunnels.
See CLI.md. No CLI parity or parent plan/release gate is marked complete. Host-only
arm64 macOS 27 validation with provisional macOS 14 target and newer Homebrew
libraries still does not establish older OS, Intel or distributable signing support.


### 2026-09-20 — Deferred CLI/file display resolution and recovery

Closed the explicit-file monitor precedence gap recorded in the previous entry.
NativeInvocationPreparation now carries validated fullscreen values as an internal
NativeFullscreenOptions candidate until file fields settle. It does not publish a
partially resolved invocation or admit a session. File selections replace obsolete
CLI numbers and their host assignments, including disconnected IDs; a file mode can
remove the implicit monitor-1 requirement. Surviving explicit dormant selections
are retained. Shared sparse-number bounds, per-field provenance and both deprecated
migration passes remain intact.

The loader maps only surviving numbers against fresh post-read topology. Inherited
CLI selections use the existing native file mapping/review lifecycle, including
manual edits, stale UUID rejection, connected-ID checks and recovery after removal.
Host-supplied assignments are visible as explicit choices and do not change when
stable IDs merely reorder. Review displays actual resolved assignments instead of
reconstructing them from an array. The chooser and review distinguish command-line
monitor numbers from numbers in the file. Recovery never rereads the source or
writes preferences; cancellation discards pending values before admission.

Added NativeInvocation.FileMonitorPrecedenceAndRecovery (native test 64) covering
file replacement, stale host assignments, implicit selection removal, migration
timing, inherited sparse numbers, source provenance, editing/review identities,
connected-ID recovery, fresh topology after suspended IO, invalid earlier values,
pre-IO non-display failures and close during read. Extended the isolated native
mapping fixture with inherited CLI chooser/review/idle-admission states. Its light,
dark and review PNGs were inspected and fit without clipping. This is fixture UI
verification, not a claim of physical multi-display/keyboard/Spaces acceptance.

Validation: focused native/document tests **6/6 (1.82 s)**; full normal native suite
**64/64 (83.28 s)**. CLI tests **3/3 ASan (0.67 s)** and **3/3 TSan (6.84 s)**.
Affected document/import tests pass **15/15 ASan (12.84 s)** and
**15/15 TSan (45.98 s)**. All native consumers rebuilt in normal/ASan/TSan configurations. Native app build,
strict deep signature, branding/attribution (1650 unchanged deferred occurrences),
tracked diff and new-source whitespace checks pass. No C production code changed;
C ABI remains 92 exports and native schemas remain defaults 11 / profile-history 10.
No commits or user-store migrations were made.

Build driver: `/tmp/tidyvnc-verify-monitor.py [empty|-asan|-tsan] --build-only`.
Logs: `/tmp/tidyvnc-invocation-monitor-full-tests.log`,
`/tmp/tidyvnc-invocation-monitor-{asan,tsan}-focused-tests.log`,
`/tmp/tidyvnc-invocation-monitor-{asan,tsan}-document-import-tests.log`, corresponding
all-three full-build logs, `/tmp/tidyvnc-invocation-monitor-app-build.log`, and
`/tmp/tidyvnc-invocation-monitor-focused-tests.log`. UI renders:
`build/native-ui-swift/tests/macos/document-mapping-ui-render/cli-mapping-light.png`,
`cli-mapping-dark.png`, and `cli-review.png`. AppKit/loopback regression fixtures run
with the required local access; this turn did not repeat known sandbox-only failures.

Next: executable CLI bootstrap, strict raw-argv decoding, help/version before store
initialization, file/socket classification and no-file CLI monitor recovery, followed
by the remaining option/authentication/listen/tunnel adapters. The full plan stays
active. Existing host limitations remain: arm64 macOS 27, provisional target 14,
newer-target Homebrew dependencies, and crypto-disabled sanitizer configurations.


### 2026-09-20 — Native executable CLI bootstrap and no-file monitor recovery

The native app executable now performs bounded strict raw-argv decoding, shared
per-occurrence validation and terminal routing before AppKit/store initialization.
Help/version use stderr and retained exit statuses (1/0); help derives its catalog
and encoding defaults from shared values and marks unsupported native adapters.
Typed errors carry argument positions without reflecting private input. Unsupported
native options fail before operand inspection. Retained-style path classification
keeps bare names as hosts, anchors relative file/socket paths to the captured cwd
and preserves symlink/parent OS semantics. Only actual sockets become Unix endpoints;
other paths use bounded regular-file reading and the existing review flow.

NativeInvocationStartup transfers one immutable process-local request to the first
ordinary connection window. No serialized argv, IPC or relaunch is introduced.
Direct hosts connect after successful admission, with session/address/close guards;
disconnect never replays the request. No-host options open an idle form. File launch
preserves CLI → file precedence, requires review and stays idle for manual Connect.
Successful connections use ordinary recent history; parsing/resolution do not write
settings. Later windows and reopening after all windows close use independent native
defaults instead of replaying the launch.

No-file monitor recovery retains an immutable prepared candidate, bounded sparse
numbers and provenance. The chooser checks exact assignment keys, currently connected
IDs and mapping UUID before admission. Cancellation admits no session; Retry creates
a fresh mapping identity. Valid mapping resumes the direct-host attempt or opens the
no-host form. The existing file chooser shares presentation while keeping file review
semantics. The new direct-CLI chooser PNG was inspected and fits without clipping.

Added NativeInvocation.StrictBootstrapAndConnection (test 65), including strict raw
bytes/bounds, terminal preflight, real Unix socket/FIFO/symlink classification,
one-shot request transfer, real local-peer automatic connection, close/address-edit
revocation and sparse/disconnected/stale/cancelled no-file display recovery. Added
SwiftUIFirstWindowOwnership and SwiftUIFileReviewOwnership (tests 66/67), exercising
custom main → SwiftUI, StateObject ownership, first/new/zero-window reopening and
reviewed file precedence with injected memory stores. Extended the existing mapping
UI fixture. Added invocation-terminal.py to check the actual built app executable
under isolated HOME/XDG without creating state.

Validation: full normal native suite **67/67 (84.17 s)**; affected CLI/document/import
ASan suite **21/21 (15.03 s)** and TSan suite **21/21 (61.05 s)**. Actual app
executable terminal cases **13/13** pass.
All native consumers rebuild in normal/ASan/TSan configurations. Native app build,
strict deep signature, branding/attribution (1650 unchanged deferred occurrences),
tracked diff and new-source whitespace checks pass. No C production changes were
needed; ABI remains 92 exports and schemas remain defaults 11 / profile-history 10.
No commits or user-store migrations were made.

Build driver: `/tmp/tidyvnc-verify-bootstrap.py [empty|-asan|-tsan] --build-only`.
Evidence: `/tmp/tidyvnc-invocation-bootstrap-full-tests.log`,
`/tmp/tidyvnc-invocation-bootstrap-{asan,tsan}-focused-tests.log`, corresponding
all-three full-build logs, `-app-build.log`, `-terminal-tests.log`, and
`/tmp/tidyvnc-invocation-launch-fixture-{build,tests}.log`. Direct chooser render:
`build/native-ui-swift/tests/macos/document-mapping-ui-render/direct-cli-mapping.png`.
AppKit/loopback fixtures ran with their required local access. These fixtures do not
establish installed Finder/LAN/privacy or physical keyboard/multi-display acceptance.

Remaining: native logging, geometry/maximize, network selection, pointer timing and
clipboard-cap adapters; password-file/environment ownership; listen/reverse and
tunnels; complete help/defaults and installed-launch parity. The full plan stays
active. Validation remains host-only arm64 macOS 27 with provisional target 14,
newer-target Homebrew dependencies and crypto-disabled sanitizer configurations.


### 2026-09-20 — Native CLI IPv4/IPv6 session policy

UseIPv4 and UseIPv6 now apply to a copied NativeNetworkPolicy with independent
field provenance. NativeSession captures the policy and supplies both flags to the
existing C connect options on every attempt. Shared connector behavior controls
hostname lookup, disabled numeric families and rejection of TCP when both families
are disabled. Unix sockets remain available with both disabled. Reconnect and address
edits retain policy; no global parameter mutation, persistence or unrelated-session
change is introduced. Explicit-file review and display recovery retain the policy.

These options are outside the connection-file catalog, so raw file entries remain
ignored with review. Save As now discloses omitted IPv4/IPv6 settings alongside
remote-resize policy, even for built-in values that may differ at the recipient.
Serialization requires acknowledgement and emits no unsupported fields. The live
capture carries the session policy. Export review was rendered and inspected without
clipping; no physical-device or installed-launch acceptance is implied.

Added NativeInvocation.NetworkFamilyPolicyAndWire (test 68). It exercises ordered
validation, inherited/per-field sources, file retention, omission acknowledgement,
real IPv4 and IPv6 numeric/localhost connections, three simultaneously connected
independent policies, failures for disabled families, reconnect, Unix with both IP
families off, actual ConnectionModel startup and reviewed-file connection. Extended
the reusable local RFB fixture with IPv6-only loopback and unique temporary Unix
sockets. The fixture removes only its own bound socket and never binds a public
interface. Existing export expectations now include network omission review.

Focused validation: **4/4 (3.36 s)**; full normal native suite **68/68 (82.70 s)**.
All native consumers rebuild in normal/ASan/TSan configurations. The native app
build, strict deep signature and **13/13** actual executable terminal checks pass.
Branding/attribution (1650 unchanged deferred occurrences), tracked diff and
new-source whitespace checks pass. Affected CLI/document/import sanitizer suites
pass **22/22 ASan (15.31 s)** and **22/22 TSan (62.78 s)**.
ABI remains 92 exports; schemas remain defaults 11 / profile-history 10. No C production code, commits or user-store migrations.

Evidence prefix: `/tmp/tidyvnc-network-policy-` (focused build/tests, all-three full
builds, full normal tests, sanitizer focused tests, app build and terminal checks).
Build driver: `/tmp/tidyvnc-verify-network.py [empty|-asan|-tsan] --build-only`.
Updated review render: `build/native-ui-swift/tests/macos/export-mapping-ui-render/review.png`.
Remaining CLI work includes logging, geometry/maximize, pointer timing, clipboard
caps, password-file/environment ownership, listen/reverse and supported tunnels,
plus complete installed-launch/help/defaults parity. The full plan remains active.
Validation remains host-only arm64 macOS 27 with provisional target 14, newer-target
Homebrew dependencies and crypto-disabled sanitizer builds.


### 2026-09-20 — Native PointerEventInterval and worker timing

Native sessions now use the retained 17 ms pointer-event default from one shared
constant. PointerEventInterval overrides it per session, including explicit zero
and values through INT_MAX. CLI provenance and the immutable interval survive file
review, monitor recovery and reconnect. Save As reviews omitted pointer timing,
which the compatibility file cannot preserve. Native storage schemas are unchanged.

The protocol worker owns one pending pointer command and one monotonic timer after
middle-button emulation. Motion updates do not postpone the original deadline.
Button/wheel transitions send immediately and update any pending value; a following
key flushes motion to preserve mailbox ordering. Timer and key-flush paths recheck
current generation/routing/focus state. Revision/release barriers, overflow and
attempt teardown discard pending work. The bounded scheduler now has five slots;
no MainActor timer, process-global state or unbounded motion queue is introduced.

INPUT_TIMING adds checked initialization and session creation with copied timing,
bringing the C ABI to 94 exports. Existing C creation functions preserve their old
zero-delay behavior and layouts. NativeRuntime requires the additive feature;
native creation reads defaults from the C initializer. Retained FLTK uses the same
default constant and still owns its existing GUI timer adapter.

Added four fake-clock ProtocolSession regressions covering fixed deadlines,
transitions/wheel, key ordering, post-emulation timing, routing/attempt cancellation,
zero/max bounds and session isolation. Added checked C++ ABI creation coverage and
pure-C consumer use. Added NativeInvocation.PointerTimingAndWire (native test 69),
covering CLI bounds/defaults/provenance, file retention, export review and real
long-delay/zero-delay local sessions. The wire test verifies focus barriers, key
flushing and reconnect without a narrow timing threshold. Export review was rendered
and inspected; all notices and controls fit.

Focused native/export tests pass **3/3 (3.19 s)**. Final normal native suite passes
**69/69 (83.89 s)**. Rebuilt core/ABI/input/lifecycle suites pass **232/232** normal
(**4.67 s**), ASan (**6.61 s**) and TSan (**9.94 s**). Pure-C consumer passes **1/1**
in all three configurations. Retained FLTK viewer builds and its selected tests
pass **54/54 (0.73 s)**. Full native ASan passes **69/69 (97.62 s)** and TSan
passes **69/69 (247.92 s)**. The app builds and strict deep signature verification
passes. Actual-executable terminal checks pass **13/13** without changing isolated
HOME/XDG stores. Header/export audit matches **94/94**; branding/attribution and
whitespace checks pass.
No commits or user-store migrations.
The core review added an extra route check when a key flushes delayed motion; final
runs above include that guard. The earlier ASan run is kept separately as
`/tmp/tidyvnc-pointer-timing-asan-before-flush-guard-tests.log`.

Evidence prefix: `/tmp/tidyvnc-pointer-timing-` (all-three builds, native/unit/C
suites, app build and executable terminal checks), plus
`/tmp/tidyvnc-pointer-{focused,retained}-{build,tests}.log`.
Build driver: `/tmp/tidyvnc-verify-pointer.py [empty|-asan|-tsan] --build-only`.
Remaining CLI adapters include logging, geometry/maximize, clipboard caps,
password-file/environment inputs, listen/reverse and tunnels. The full plan remains
active; installed launch, physical input/display, performance and release gates
remain open. Host limitations remain arm64 macOS 27, provisional deployment target
14, newer-target Homebrew dependencies and crypto-disabled sanitizer builds.


### 2026-09-20 — Native MaxCutText reader policy

MaxCutText now resolves through the native CLI into an immutable per-session reader
limit and provenance. Nil uses the shared retained 256 KiB default; explicit zero
and values through INT_MAX are valid. Files cannot override this CLI-only option;
file/display review, export capture and reconnect retain it. Save As requires review
of its omission without inventing a compatibility field or changing native schemas.

MESSAGE_LIMITS adds checked initialization and session creation with copied limits,
input timing and encoding, bringing the C ABI to 96 exports. Older creation APIs
retain their layouts and default reader limits. Both the shared parser and C creation
validate bounds; invalid input leaves outputs unchanged. Reader caps apply separately
to plain wire text, complete extended payloads and each decompressed format. Outgoing
text, UTF-8 clipboard retention budgets and pasteboard limits remain independent.

Added ABI and pure-C consumer coverage plus native test 70,
NativeInvocation.ClipboardMessageLimitsAndWire. The bounded loopback fixture sends
an ordered framebuffer marker after each clipboard message so discard tests do not
rely on an arbitrary delay. Coverage includes exact/zero/full bounds, caller snapshot
ownership, Latin-1/newline conversion, outgoing independence, retained-text rejection
and recovery, separate sessions, reconnect, help defaults and file/export review.
Focused native/export tests pass 3/3 (3.41 s); initial ABI/reader tests pass 40/40
(1.27 s). Rebuilt core/ABI/reader/lifecycle suites pass **241/241** normal (4.64 s),
ASan (6.64 s) and TSan (9.99 s); pure-C consumer passes **1/1** in all three.
Retained viewer builds and selected tests pass **25/25 (0.43 s)**. Header/export
sets match **96/96** and branding/attribution checks pass (1650 unchanged deferred
occurrences). Full normal native suite passes **70/70 (84.75 s)**. The app builds,
strict deep signature verification passes, and executable terminal checks pass
**13/13**, including the shared MaxCutText help default, with isolated HOME/XDG
unchanged. Tracked diff and 20 changed/new-source whitespace checks pass. Full ASan
native suite passes **70/70 (100.81 s)** and full native TSan passes
**70/70 (250.61 s)**. All final native runs include the scrollable review fix.

Render inspection found the additional export notice compressed existing content.
The final review now uses one scrollable details area with fixed title/actions,
fully wrapping the introduction and display entries. The AppKit fixture verifies
that long content scrolls to the final notice, preserves one-sheet mapping/save
lifetime, and renders both ends. This layout test passes **1/1 (2.69 s)**; rendered
top/bottom views were inspected. The fixed sheet remains 560 by 600 points.

Evidence prefix: `/tmp/tidyvnc-message-limits-`; build/test drivers:
`/tmp/tidyvnc-verify-message-limits.py` and
`/tmp/tidyvnc-message-limits-final-tests.py`.
The full plan remains active. Remaining CLI work includes logging, geometry/maximize,
credential file/environment inputs, listen/reverse and tunnels; installed/physical/
performance/release gates remain open. Host-only arm64 macOS 27 validation retains
the provisional target 14, newer-target dependencies and sanitizer crypto limitations.


### 2026-09-20 — Native geometry/Maximize and one-shot window placement

Initial geometry and Maximize now resolve into immutable session policy/source
metadata. The shared WindowGeometry parser replaces retained sscanf conversion
while preserving defined signed/whitespace/trailing-text and two/four-conversion
forms. Empty geometry clears the override. Malformed/nonpositive dimensions and
integer overflow are rejected; the retained invalid-input path logs and leaves
original geometry. WINDOW_GEOMETRY adds a stateless checked C parser (97 exports),
with no display or OS handle crossing the C boundary.

NativeWindowStartupState waits for admitted settings and an ordinary window, then
applies AppKit logical content geometry with primary-top-left coordinate conversion,
work-area caps, frame decoration and window min/max constraints. Maximize fills the
chosen work area unless an explicit position was supplied, which stays explicit.
No delegate/focus/order mutation occurs. The owner is consumed once, waits for sheets,
revokes pending work on close and cannot replay on reconnect, view reconstruction,
new windows or display updates. Automatic fullscreen waits for initial placement;
later user resizing survives reconnect/fullscreen cycles. File admission/recovery
preserves CLI policy; unsupported file fields remain reviewed omissions. Save As
reviews window placement in its scrolling details area. Native schemas are unchanged.

Added three differential/boundary shared parser tests, transactional C ABI tests and
pure-C consumption. NativeInvocation.InitialWindowPlacement is native test 71; it
covers resolution/sources, file/export review, pure work-area arithmetic including
negative display origins, actual hidden AppKit sizing/maximization, no-order/delegate
invariants, one-shot lifetime, sheet deferral and close cancellation. SwiftUI launch
fixtures now apply real CLI geometry to the first window after direct/file admission
and verify new/zero-window isolation. Fullscreen tests verify initial placement before
entry and preservation of a later user resize over reconnect.

Focused native tests pass **6/6 (5.13 s)**, including fullscreen, both SwiftUI launch
paths, export and placement. Shared parser/ABI tests pass **36/36 (1.19 s)**. The
retained viewer builds. Rendered export review was inspected with the new omission.
A final review tightened weak-window identity and uses one NSScreen snapshot. Full
normal/ASan/TSan builds pass. Rebuilt core/ABI/geometry/lifecycle suites pass
**245/245** normal (4.83 s), ASan (6.86 s) and TSan (10.23 s); the pure-C consumer
passes **1/1** in all three. Retained geometry/invocation tests pass **20/20 (0.29 s)**.
The app builds and strict deep signature verification passes. Actual-executable checks
pass **17/17** with isolated HOME/XDG unchanged. Header/export sets match **97/97**;
branding/attribution (1650 unchanged deferred entries), tracked diff and 23 changed/new
source whitespace checks pass. The full normal run passed 70/71 (84.47 s); its
only failure was an obsolete assertion that geometry remained unsupported. That
assertion now verifies the resolved size/position/Maximize values, with the affected
resolution/precedence test passing **1/1 (0.34 s)** on its targeted rerun. No product
fix was needed. Full ASan native suite passes **71/71 (100.97 s)**. Full native
TSan passes **71/71 (248.60 s)**; all final builds include the ownership refinements.
The final test-only geometry-support assertion correction is included in both full
sanitizer suites and the targeted normal rerun. No commits or user-store migrations.

Evidence prefix: `/tmp/tidyvnc-window-startup-`; build/test drivers:
`/tmp/tidyvnc-verify-window-startup.py` and
`/tmp/tidyvnc-window-startup-final-tests.py`.
Remaining CLI work includes logging, credential file/environment inputs, listen/reverse
and tunnels. The complete plan stays active. Physical multi-display/Spaces, installed
launch, performance and release gates remain open. Host validation remains arm64 macOS
27 with provisional target 14, newer-target dependencies and crypto-disabled sanitizer
builds; this does not establish older-system or Intel support.

### 2026-09-20 — Shared logging sink concurrency prerequisite

Logger now holds a recursive sink mutex across formatting and all lines of one
record. File/stdio sinks use the same mutex for direct writes, filename/file
replacement and closure, preventing interleaved records and races with stream
ownership changes. Timestamp conversion uses a stack buffer through ctime_r or
Windows ctime_s, removing shared timestamp scratch across separate sinks. The core
target propagates its Threads dependency. Legacy prefixes, wrapping, truncation,
lazy backup rotation and stream ownership are preserved.

Five focused tests pass **5/5** normal (0.10 s), ASan (0.18 s) and TSan (0.26 s).
They cover complete concurrent multiline records, mixed direct/formatted writes
against file replacement, independent sink timestamps and legacy formatting/rotation.
The replacement test compiled against the pre-change logger sources triggers a
confirmed ThreadSanitizer data race, establishing that it exercises the old defect.
All streams/directories are private fixtures. The retained viewer builds and its
logging tests pass **5/5 (0.09 s)**. The native app and rebuilt bridge build;
NativeBridge.OwnershipAndLoopback passes **1/1 (0.95 s)**. Strict deep app signature
verification and actual-executable terminal cases pass **17/17**, with isolated
HOME/XDG unchanged. Evidence prefix: `/tmp/tidyvnc-logging-sinks-`.

This completes only the sink prerequisite. Registry/LogWriter registration and
levels/destinations remain startup-owned, and indent/width must be configured
before writers start. Logger destruction requires joined writers. Native Log
remains unsupported pending policy validation, startup lifetime and redaction work;
there is no new C API or native persistence change. The complete plan remains active,
with credential inputs, listen/tunnels and physical/installed/performance/release
gates still open. Validation remains limited to this arm64 macOS 27 host.

### 2026-09-20 — Owned logging policy and checked invocation levels

Added LoggingPolicy as an owned, bounded startup candidate. Parsing preserves
retained list trimming/empty entries and defined atoi decimal-prefix behavior;
signed overflow is rejected rather than invoking undefined behavior. Resolution
takes explicit host writer/target catalogs, validates every rule including overridden
ones, and returns one canonical route per writer only after success. Ordered wildcard
overrides, case-insensitive names, empty-target disabling and resetting unspecified
writers match retained Log assignments. Invalid/ambiguous catalogs are rejected.
Neither operation consults globals/environment, opens destinations or changes logging.

Invocation value validation now uses this parser, so an overflowing Log level fails
before help/version and cannot disappear behind a later assignment. Typed, fixed
errors cross the existing C ABI without input reflection or publishing a partial
validated owner. There is no ABI export or persistence change. Native Log remains
unsupported until startup application and redacted output are implemented.

Seven LoggingPolicy tests cover bounds/NULs, owned inputs, prefix-level differential
behavior, catalog failures, route ordering, live retained-registry differential
routing through memory sinks, and concurrent resolution without registry mutation.
Added a C ABI regression for redacted overflow and unchanged output/initial owner.
Policy/invocation/ABI checks pass **26/26** normal (0.25 s), ASan (0.44 s) and TSan
(0.77 s). The retained viewer builds; policy/invocation checks pass **19/19 (0.22 s)**.
The native app builds and strict deep signature verification passes. Its expanded
terminal suite passes **20/20**, including overflow-before-help/version, overridden
invalid rules and compatible decimal suffix behavior; isolated HOME/XDG is unchanged.
Evidence prefix: `/tmp/tidyvnc-logging-policy-`.

The full plan remains active. Remaining logging work is process startup ownership,
validated route application, redacted useful diagnostics and lifecycle verification.
Credential inputs, listen/tunnels and physical/installed/performance/release gates
remain open. Validation is still host-only arm64 macOS 27 with the existing newer
dependency targets and crypto-disabled sanitizer limitations.

### 2026-09-20 — Redaction before diagnostic formatting

Added RedactedLogger without enabling native logging. Logger's formatted overload
is virtual so the adapter intercepts before printf sees string/pointer arguments;
the retained default implementation is unchanged. An audited table recognizes 89
core/client templates, keeps event context and substitutes fixed redaction markers.
Unknown formats and already-formatted text receive fixed fallback output; source
names come only from compiled constants. Three keyboard templates are suppressed
entirely. Twenty numeric-only templates retain useful protocol versions, counts,
geometry, flags and status codes. Bounded formatting uses the compiled original,
and a static assertion forbids conversions other than %d/%x in this exception.

The startup constructor captures gettext matches into owned immutable storage;
output does not mutate or consult locale/registry state. Severity is normalized,
destination writes are serialized, and no destination is opened or registered.
Adapter/destination lifetime remains the startup host's responsibility through
joined shutdown. Output is controlled English; native diagnostic localization and
actual process startup route application remain unfinished. Native Log stays
unsupported, with no new C ABI or persistence schema.

Seven new tests cover contextual redaction, audited numeric fields, unknown/dynamic
messages, forged sources, %n rejection, unused invalid string pointers, complete key
event suppression, real LogWriter virtual dispatch, concurrent writes and private
file output. Combined redaction/sink/policy tests pass **19/19** normal (0.21 s),
ASan (0.38 s) and TSan (0.66 s). The retained viewer builds and redaction/sink tests
pass **12/12 (0.18 s)**. The native app and bridge build; bridge ownership/loopback
passes **1/1 (0.82 s)**. Strict deep signature verification and **20/20** actual
executable terminal checks pass, with isolated HOME/XDG unchanged. Branding and
attribution checks pass (1650 unchanged deferred entries), along with tracked/new
source whitespace checks. Evidence prefix: `/tmp/tidyvnc-redacted-logger-`.

The full plan remains active. Logging startup admission/application/lifetime,
credential inputs, listen/tunnels and physical/installed/performance/release gates
remain open. Host validation is arm64 macOS 27 with the existing dependency-target
and sanitizer crypto limitations; no broader platform acceptance is claimed.

### 2026-09-20 — Native stderr/stdout logging and process startup lifetime

StartupLogging now owns the startup candidate, registered writer snapshot and
redacted destinations. All routes and sinks prepare before any nonthrowing writer
mutation. Allocation/factory failure releases staged resources, preserves existing
routes and permits retry. Only destinations used by final routes are created.
Inspection found duplicate TLS writer names when client/server helpers are linked;
LoggingPolicy now preserves retained first-named-match/all-wildcard behavior for
duplicate writer nodes, while duplicate targets and repeated node pointers remain
invalid. Registered-writer snapshots retain legacy lookup order.

PROCESS_LOGGING adds validation/configuration C calls (99 exports). The process
gate serializes configuration against runtime creation and remains closed after
shutdown. Old C consumers that never configure retain their logging and create no
logging snapshot/destination merely by freezing admission. Successful configuration
owns close-on-exec stdout/stderr duplicates at fd >= 3, without altering original
status flags or reopening closed standard descriptors. RuntimeService is created
after the logging owner and joins its workers before that owner detaches every
writer and destroys sinks at process exit.

NativeProcessLogging validates every occurrence, including before help/version,
and selects the last complete policy. The executable starts redacted output only
after launch preflight and before SwiftUI/runtime creation. Default `*:stderr:30`
matches retained behavior. Logging is process-wide, with no session/defaults/profile
field, file precedence or new-window/reconnect replay. Unsupported file/other targets
fail explicitly; file logging remains unfinished. Native help now identifies the
supported targets and default. Error messages remain fixed with typed entry/reason.

Seven startup-owner tests cover transactional routing, duplicate nodes, factory
failure/retry, disabled/overridden destinations, joined destruction and configure/
freeze races. ProcessLoggingABI uses two independent process fixtures for owned
stdio and first-runtime closure. It tests a closed standard descriptor, allocation
failure across setup with descriptor counts, no partial routes, original-stream
independence, redacted output and admission after runtime drain. An initial test
assumed its TLS fixture was the first registered node; it now explicitly uses the
actual legacy lookup result, matching the compiled client TLS writer ordering.
The new native process-logging fixture is native test 72 and exercises Swift
selection, per-occurrence errors, one-time activation and runtime lifetime. The
pure-C consumer covers the feature and closed-admission contract.

Final logging/ownership and existing ViewerABI checks pass **62/62 normal (1.46 s)**.
Focused logging suites pass **29/29 ASan (0.75 s)** and **29/29 TSan (1.13 s)**.
Native logging/resolution/bootstrap checks pass **3/3** normal (0.52 s), ASan (0.90 s)
and TSan (6.87 s); these are focused runs, not the full 72-test native suite. The
pure-C consumer passes **1/1** in all three configurations. The retained viewer
builds and its logging/ownership checks pass **27/27 (0.40 s)**. The native app builds,
strict deep signature verification passes, and executable terminal checks pass
**23/23**, with isolated HOME/XDG unchanged. Header/export sets match **99/99**.
Evidence prefix: `/tmp/tidyvnc-startup-logging-`.

The complete plan stays active. Native file logging, logging/help/localization and
installed acceptance, credential inputs, listen/tunnels and physical/performance/
release gates remain open. Validation remains arm64 macOS 27 with provisional
target 14, newer-target dependencies and crypto-disabled sanitizer limitations.

### 2026-09-20 — Native private file logging and cross-process ownership

Native Log now accepts `file` with the retained `/tmp/vncviewer.log` destination.
PrivateFileLogger validates/copies an absolute path at construction and performs
no file IO until the first emitted record. Suppressed key events and unused sinks
never create or rotate a log. FILE_LOGGING adds a host-path configure call at the
same process startup gate, bringing the C ABI to 100 exports; the existing call
uses the default path. Native help and per-occurrence validation now admit file
logging. There is no new CLI path option, persisted field or session/file replay.

The sink pins an owned/root directory and refuses unsafe write permissions except
root-owned sticky directories. It refuses extended macOS parent ACLs before any
creation, so inherited ACL grants cannot permit an early descriptor to bypass
0600. Log, backup and lock leaves must be owned regular single-link files; symlinks,
hard links and nonregular entries are rejected. File ACLs are removed. Creation
uses exclusive temporary files, no-follow leaf access, and no-overwrite link-based
publication. All owned descriptors use close-on-exec and remain above fd 2.

A persistent private `.lock` sidecar holds a nonblocking advisory lock until sink
closure, including after runtime drain. Another cooperating process falls back to
stderr without rotating the active owner's file. Rotation retains one `.bak`; an
existing backup without a current log keeps its bytes with private permissions.
The old log is backed up before its original entry is removed, but this is not an
atomic multi-entry transaction: publication failure can leave only the backup,
and an earlier backup may already have been removed. Legacy/noncooperating writers
are not serialized. No size cap or periodic rotation is introduced.

Unsafe/unavailable files and failed writes switch once to an owned stderr stream,
with a fixed warning and redacted output; a failed record is retried there. Paths,
errno strings, exception text and private substitutions do not enter the warning.
Destination failure does not fail session workers. Joined process destruction
retains existing startup ownership and detaches routes before destroying sinks.

Ten private-sink tests cover lazy creation, exact backup bytes, permissions/ACLs,
suppressed output, unsafe leaves/directories, concurrent records, lock contention,
real output failure, closed standard descriptors and orphan backup retention. A
public-ABI Python fixture starts separate processes, checks actual redacted output,
verifies the first owner's inode/bytes and lock survive runtime drain, and verifies
rotation only after owner exit. All file tests use private temporary paths. The
translation-enabled retained build exposed its existing unbundled locale warning;
the fixture now requires exactly that known startup message only for that build,
while ordinary native/sanitizer processes must have no successful-owner stderr.

Final logging/ownership plus ViewerABI checks pass **73/73 normal (1.73 s)**.
Focused logging suites pass **40/40 ASan (1.13 s)** and **40/40 TSan (1.61 s)**.
Native logging/resolution/bootstrap checks pass **3/3** normal (0.51 s), ASan (0.81 s)
and TSan (6.77 s); this is not a full 72-test native suite run. The pure-C consumer
passes **1/1** in all three builds. The retained viewer builds and logging checks
pass **40/40 (0.78 s)**. The final app builds, strict deep signature verification
passes, and **24/24** actual executable terminal checks pass with isolated HOME/XDG
unchanged. Header/export sets match **100/100**. Branding/attribution checks pass
with 1650 unchanged deferred entries; tracked and 19 changed/new source whitespace
checks pass. Evidence prefix: `/tmp/tidyvnc-file-logging-`.

The full plan remains active. Logging/help/localization and installed acceptance,
credential inputs, listen/tunnels, physical keyboard/Spaces/multidisplay behavior,
performance and release gates remain open. Validation is arm64 macOS 27 with the
existing provisional target-14/newer-dependency and crypto-disabled sanitizer
limitations; no older-OS, Intel or Linux runtime acceptance is claimed.

### 2026-09-20 — Password-file decoding, consuming replies and native reader

Inspection confirmed retained environment → session cache → password-file → dialog
precedence, with files eligible only for password-only authentication. The existing
native credential reply accepts UTF-8, while legacy decoded passwords can contain
non-UTF-8 bytes. Native launch must therefore not convert file credentials through
Swift String or weaken the ordinary credential text contract.

The shared rfb decoder now has a caller-owned output overload with exact block and
capacity checks before output mutation. It preserves raw bytes and first-NUL
termination and supports in-place decode. The retained string-returning helper
uses it and clears its temporary plaintext block, including allocation failure.
PASSWORD_FILE_REPLY adds a consuming C reply (101 exports). It decodes into a
bounded stack buffer, then checks password-only eligibility, ID, generation,
deadline and cancellation under the existing prompt lock. Username-required/trust
prompts cannot consume it. Bounded input, decoded stack bytes and bridge-owned
plaintext are cleared on success/failure, including stale requests, malformed
error headers and allocation failure. Arbitrary runtime/crypto scratch copies are
outside that ownership guarantee. Ordinary UTF-8 credential replies are unchanged.

NativePasswordFileReader owns scoped URL access and a close-on-exec/nonblocking
descriptor off MainActor. It accepts selected symlinks to regular files, rejects
special/incomplete files, reads only the first eight bytes, checks cancellation and
before/after metadata, and returns a clearable owner of obfuscated bytes. Trailing
and second/view-only blocks are ignored, preserving retained read semantics. The
Swift consuming reply forwards those bytes directly to the core and clears its
submitted array. File errors are fixed and do not echo paths/content. No settings,
Keychain write, plaintext Swift password, or environment lookup was introduced.

New decoder checks cover empty/short/full/non-UTF-8 passwords, in-place output,
capacity/sentinel preservation and invalid inputs. The prompt fixture verifies a
password-only reply cannot consume a username-required request. The public ABI
fixture covers stale/wrong-header/size/allocation failures, wiped submissions,
retry, duplicate rejection and real VNC wire responses, including non-UTF-8 input.
Pure-C coverage verifies capability and invalid-handle cleanup. The new native
fixture (native test 73) covers short/missing/large/trailing files, symlinks,
FIFO/directory rejection, cancelled reads, explicit clearing and actual loopback
authentication through NativeSession.replyPasswordFile. Test files/stores are
isolated; no real user credential file or environment secret was read.

Decoder/prompt/ViewerABI tests pass **61/61** normal (1.59 s), ASan (2.03 s) and
TSan (2.76 s). Native password-file/retention/bridge checks pass **3/3** normal
(1.45 s), ASan (1.84 s) and TSan (7.87 s); this is not a full 73-test native run.
The pure-C consumer passes **1/1** in all three builds. The retained viewer builds
and the same core/ABI checks pass **61/61 (1.80 s)**. The app builds, strict deep
signature verification passes, and **24/24** executable terminal checks pass with
isolated HOME/XDG unchanged. Header/export sets match **101/101**. Branding and
attribution pass with 1650 unchanged deferred entries, plus tracked/new whitespace
checks. Evidence prefix: `/tmp/tidyvnc-password-file-`.

These primitives do not complete native launch credentials. PasswordFile remains
explicitly unsupported by native CLI resolution until a launch owner captures
inputs once for the intended connection, preserves environment precedence, gates
file reads on a current prompt, discards stale/cancelled results, joins pending IO
on close and handles retry/failure. Those integrations remain the next credential
work. The full plan stays active, including logging/localization/installed gates,
listen/tunnels and physical/performance/release acceptance. Host evidence remains
arm64 macOS 27, provisional target 14 with newer dependencies, and crypto-disabled
sanitizer builds; no older-OS, Intel or Linux runtime acceptance is claimed.

### 2026-09-20 — Native launch credential ownership and CLI activation

PasswordFile/passwd is now admitted by the native executable. After strict argv,
terminal handling and launch preflight, startup captures only VNC_USERNAME and
VNC_PASSWORD as bounded raw bytes. Missing and present-empty values remain distinct.
A single-claim owner transfers inputs to the first ordinary connection window and
binds them to its initial resolved endpoint, or the first explicit Connect for an
empty form. Endpoint changes revoke the inputs. New windows cannot reclaim them.
The original process environment is not modified or claimed to be erased.

At a current credential prompt, environment input takes precedence (both variables
are required for username/password authentication). For password-only prompts,
a matching nonempty explicitly retained session credential precedes a launch file
read. Files cannot fill an incomplete username/password pair. Relative paths use
captured launch cwd; every occurrence is validated, the last wins, and empty disables
the file policy. Injected invocations can supply file-only policy without consulting
the process environment. Automatic submissions never access or write Keychain,
preferences, profiles, history or connection documents.

Unexpected same-endpoint reconnects retain the captured environment or reread the
file. Explicit Cancel, Disconnect, security edits, endpoint edits and close revoke
launch inputs. Epoch/prompt/generation checks discard and clear late results even
from a reader that ignores cancellation. Retry remains unavailable until pending IO
returns, and close drains it. File errors leave a fixed, path-free notice and an
interactive prompt; this deliberately replaces the retained viewer's immediate
file-error exit. Kernel reads on network-backed regular files have no claimed hard
deadline. Full ownership and recovery contract: CREDENTIAL-INPUTS.md.

The consuming CREDENTIAL_BYTES capability/API preserves non-UTF-8 legacy environment
bytes without weakening the existing UTF-8 reply API. Both mutable inputs are wiped
on every bounded submission path. Production storage setup now captures only HOME
and the three XDG path variables, avoiding whole-environment Foundation string
copies. Header/export sets match **102/102**; no persisted schema or C struct changed.

New native tests 74–75 cover one-shot handoff, source precedence, endpoint revocation,
raw/empty VeNCrypt Plain pairs, real VNC replies, file failure/manual recovery/session
reuse, injected file policy, cancellation/retry/close drain, and overridden process
environment capture. The C ABI regression verifies raw reply validation, stale
cleanup, UTF-8 API isolation and actual VNC responses. An older bootstrap help
expectation was updated because PasswordFile is now supported. Tests use private
files, memory stores and loopback fixtures; child environment tests explicitly
override both credential variables. No real user credential file or environment
secret was read by these checks.

Focused native checks pass **10/10** normal (1.76 s), ASan (2.12 s) and TSan
(23.42 s); this is not a full 75-test native suite run. ViewerABI checks pass
**35/35** normal (1.22 s), ASan (1.53 s) and TSan (1.94 s), and the pure-C consumer
passes **1/1** in each build. The retained viewer builds and its ViewerABI checks
pass **35/35 (1.41 s)**. The native app builds, strict deep signature verification
passes, and **25/25** actual executable terminal checks pass with isolated HOME/XDG
unchanged, including oversized environment rejection before UI/store startup.
A separate subprocess verifies raw non-UTF-8 process environment capture and VNC
authentication. Branding/attribution passes with 1650 unchanged deferred entries;
tracked and new-file whitespace checks pass. Evidence prefix:
`/tmp/tidyvnc-launch-credentials-`.

The full plan remains active. Remaining CLI work includes listen/reverse/tunnels;
logging/help/localization, installed Finder/LAN privacy, physical input/Spaces/
multidisplay, performance and release acceptance remain open. Evidence is still
arm64 macOS 27, provisional target 14 with newer dependencies and crypto-disabled
sanitizer builds; no older-OS, Intel or Linux runtime acceptance is claimed.

### 2026-09-20 — Reverse listener C ABI, callbacks and Swift ownership

The existing portable listener now crosses the C/Swift boundary. LISTENER adds
nine exports and additive options/address/snapshot/event structs; the header and
archive export sets match **111/111**. Runtime lazily owns a separate four-listener
service. Its reaper waits for both listener and session drain before destroying
either service. No caller/UI thread joins workers. Existing session capacity and
construction structs remain unchanged.

Copied events expose ordered sequence numbers, listener-scoped peer IDs, numeric
addresses, pending counts and typed failure/native codes. The existing bounded
queues, expiry, bind rollback and reserved terminal overflow delivery are preserved.
Explicit acceptance transfers a peer into an already configured reusable session,
using ordinary operation completion, generation, authentication and cancellation.
Preflight-invalid handles/output leave a peer pending; busy/closing admission or
allocation failure after claim closes it. Listener stop closes pending sockets but
leaves accepted sessions alive. Numeric peer host (without IPv6 scope) supplies the
protocol/TLS hostname; the incoming source port is not a stable saved-server key.

Core readiness notifications run outside listener locks. The C bridge reuses the
bounded coalesced callback dispatcher and retained context/unsubscribe/drain APIs.
Listener generation is one because restart creates a new handle. Stop preserves
terminal callbacks; final release cancels delivery. NativeListener uses NativeDelivery
on MainActor, copied pending peers and a source-listener token to prevent same-ID
cross-listener actions. Its close invalidates queued delivery and asynchronously
drains workers, callback context and queued host work. NativeRuntime weakly tracks
listeners and begins all listener/session closes before awaiting any. There is no
native state polling or automatic credential/store access.

The wrapper consumes its initial queued history before being returned, preventing
an older Starting event from following an externally observed Listening snapshot.
Native listener acceptance uses the existing NativeSession operation machinery;
a later explicit reverse peer can reuse a configured session after disconnect.
The private test peer now supports outbound loopback reverse connections in addition
to existing server fixtures. No production UI, user stores or environment credentials
were exercised by these tests. Contract and remaining integration: LISTEN.md.

Nine new ListenerABI tests cover validated defaults/output preservation, typed
handles, ordered events, no pre-admission protocol response, rejection/expiry,
real reverse RFB/None and VNC authentication, numeric prompt identity, listener-stop
independence, post-claim busy/allocation cleanup, runtime/final-release drain,
capacity/bind failure, concurrent single ownership, event overflow, callback
reentry and retained-context drain. A core wake test reenters snapshot directly,
proving notification happens outside the listener mutex. Pure-C coverage exercises
the new capability and API types/invalid-handle paths. Native test 76 covers scoped
peer rejection, incoming expiry, reverse framebuffer delivery/authentication,
reuse/generation advance, initial publication order, weak ownership and runtime drain.

Final focused ListenerABI/ListenerWorker/SocketListener/ViewerABI checks pass
**66/66** normal (2.27 s), ASan (2.76 s) and TSan (3.73 s); the retained viewer builds
and passes the same **66/66 (2.67 s)**. Native listener/bridge tests pass **2/2** normal
(1.10 s), ASan (1.35 s) and TSan (5.50 s), not a full 76-test native suite run. The
pure-C consumer passes **1/1** in each configuration. The native app builds, strict
deep signature verification passes and **25/25** isolated executable terminal
checks pass with HOME/XDG unchanged. Branding/attribution passes with 1650 unchanged
deferred entries, plus tracked and 324 untracked text-file whitespace/conflict
checks. Evidence prefix: `/tmp/tidyvnc-listener-`.

The native app still rejects `-listen` until listener launch/status/incoming-peer UI,
configuration resolution, reverse identity/persistence policy and window/quit routing
are implemented and tested. Tunnel support, localization, physical input/Spaces/
multidisplay, installed Finder/LAN privacy, performance and release gates remain
open; the full goal stays active. Evidence remains arm64 macOS 27 with provisional
target 14/newer dependencies and crypto-disabled sanitizer builds. No older-OS,
Intel, Linux runtime or installed reverse-connection acceptance is claimed.

### 2026-09-21 — Manual listener presentation and independent reverse windows

File > Listen for Connections now opens a native listener window. Port/family
validation precedes bind; Start/Stop, bound ports, pending numeric peers and explicit
Accept/Reject are exposed with accessibility identifiers. A pending peer is reserved
once per window-opening action. Epoch changes revoke starts waiting on a previous
owner; restart joins that owner before rebinding. Bind/queue/start errors have fixed
recovery notices. Listener focus clears the active connection menu target.

Accept creates an independent app-owned NSWindow and a ReverseConnectionRequest
retaining only its listener and copied peer. ConnectionModel uses the existing native
defaults resolution and session-publication path before acceptance; security, sharing,
clipboard, rendering, input and other settings reach the reverse handshake. Closing
before admission rejects the peer. Expiry during preparation produces an unavailable
message. Listener stop leaves admitted sessions alive. App quit revokes listener
actions, begins session/listener shutdown and drains both window classes.

Reverse source ports are temporary observations, not saved destinations. Reverse
models do not attach recent history, Keychain, legacy exceptions or durable trust
stores; passwords are submitted once and trust decisions remain connection-only.
The source field is read-only, document export is unavailable, and outbound Connect/
Retry cannot target that source after disconnect. The remote server must initiate a
new connection to reconnect. Incoming windows have no scene-restoration payload,
and their non-scene roots do not overwrite the app's Finder/open-file routing closure.
Manual listener creation does not consume ordinary launch credentials or argv.

New native test 77 exercises the actual ListenerModel/ListenerWindowController and
ConnectionModel with private loopback peers and memory preferences. It covers invalid
port/family admission, stop during startup, duplicate Accept suppression, two independent
reverse models, None/VNC authentication, inherited sharing/clipboard policy, bind
conflict, stop preserving accepted sessions, disabled outbound reconnect/export and
close before defaults/admission. Closing the fixture window drains its listener.
The fixture is a signed AppKit bundle with a bounded optional preview mode.

Review found that installing NSHostingController could collapse a newly created
window to a 1-by-28 frame. Both listener and incoming-window creation now restore
explicit content/minimum sizes after installation; the fixture checks the listener's
initial size before its render helper can change it. Port labels now use plain digits,
avoiding localized thousands separators. An initial compiler error from applying
@Published to two declarations on one line was fixed by splitting the properties.

Focused native listener/bridge/connection-error/credential-retention/launch checks
pass **8/8** normal (3.53 s), ASan (4.29 s) and TSan (20.91 s). After the final size
fix, the changed UI fixture passes **1/1** again in normal (0.55 s), ASan (0.83 s)
and TSan (3.27 s). This is not a full 77-test native suite run. The native app builds,
strict deep signature verification passes, and **25/25** isolated terminal cases
pass with HOME/XDG unchanged. Branding/attribution passes with 1650 unchanged deferred
entries; tracked and untracked whitespace/conflict checks pass. The C ABI remains
111 exports and no portable core or persisted schema changed in this milestone.
Evidence prefix: `/tmp/tidyvnc-listen-ui-`.

Cached view bitmaps did not capture native control painting reliably. Computer-use
inspection returned AXError.cannotComplete; it was not treated as evidence of a
locked Mac. Its fixture process was confirmed terminal before retrying independently.
An OS window query scoped to the subsequent fixture's observed process ID exposed
the collapsed-frame bug. After the fix, an app-only window capture succeeded with
a 700-by-588 frame. The live dark appearance was inspected: two pending peers,
Accept/Reject, Stop, plain-digit ports and explanatory text were legible without
clipping. Artifact: `/tmp/tidyvnc-listen-ui-images/live-incoming.png`. Preview fixtures
were closed and joined. This establishes limited fixture appearance, not actual-app
menu interaction, light-mode coverage, reverse TLS trust UI or installed acceptance.

The full plan stays active. CLI `-listen` remains explicitly unsupported until its
port/operand/file/network and scoped launch-credential semantics reach this entry
path. Tunnel support, full app interaction, installed Finder/LAN/privacy/firewall,
localization/accessibility, physical input/Spaces/multidisplay, performance and
release gates remain open. Host evidence is still arm64 macOS 27, provisional target
14 with newer dependencies and crypto-disabled sanitizer builds; no older-OS, Intel
or Linux runtime acceptance is claimed.

### 2026-09-21 — Numeric CLI listener startup and launch credential handoff

Native `-listen [port]` now creates a typed listen launch without an outbound
endpoint. Bootstrap resolves the last validated listen/family flags, defaults to
port 5500, accepts checked ASCII decimal 0–65535 (0 ephemeral), and rejects both
families disabled. Empty argv entries remain ignored by the shared parser. Native
port handling deliberately rejects suffixes/nonnumeric operands instead of the
retained viewer's digit-prefix `atoi`/nonnumeric-default behavior. Paths fail with
a specific unsupported-file/socket message before metadata inspection, file IO,
credential capture or binding. Explicit-file listening is still an open adapter.

StartupPresentation uses StateObject to consume argv once per ordinary scene. The
first scene presents ListenerView for a listen request, without constructing an
outbound connection; later ordinary scenes remain normal forms. Finder/profile
scenes never take the request. ListenerModel consumes an appearance-start flag once;
reappearance cannot restart listening after Stop/close. AppCoordinator tracks the
SwiftUI listener window, clears its connection menu target on activation, revokes
its model on window close and awaits its cleanup on quit. The manual listener
controller remains available and the menu focuses an existing CLI listener.

Accepted peers carry the nonsecret invocation into NativeSessionDefaults, so CLI
settings override native defaults before reverse session admission. The listener
owns captured launch inputs until its first successful window-opening callback;
failed opening keeps the owner and releases the peer reservation. Only that first
incoming window claims the environment/password-file owner. Later peers never
recapture environment or recreate PasswordFile from the repeated invocation.
Stop/close clears unclaimed inputs and leaves an admitted window's owner intact.
Reverse history/Keychain/durable trust/export/outbound retry remain disabled.

The listener fixture covers repeated appearance, startup cancellation, one enabled
family, failed window opening, two VNC-authenticated peers, sharing/clipboard CLI
precedence, environment-over-file precedence, no file reads for the later peer,
stop preserving an accepted connection and clearing pending credentials. Bootstrap
adds numeric bounds/invalid forms, flag precedence, no outbound endpoint, disabled
families and explicit-file rejection before path inspection. The existing resolution
fixture now uses the still-unsupported `via` option to verify failure before file IO.
An initial empty-argv expectation was corrected to the existing parser contract.

The full normal native suite ran **77 tests**: **76 passed**, and the old resolution
fixture expecting `listen` to be unsupported failed. After updating that fixture,
its targeted rerun passed **1/1 (0.23 s)**; no production change was needed. The
listener/bootstrap/launch-credential subset passed **4/4 ASan (2.11 s)** and
**4/4 TSan (10.56 s)**, plus the updated resolution test **1/1 ASan (0.29 s)** and
**1/1 TSan (2.26 s)**. Native/app builds succeeded. Strict deep signature verification
and **29/29** isolated actual-executable terminal cases passed with HOME/XDG fixture
contents unchanged. Branding/attribution passed with 1650 unchanged deferred
entries; tracked diff and 341 untracked text-file whitespace/conflict checks passed.
No C ABI or persisted schema changed (111 C exports remain).

An actual built-app launch with `-listen -UseIPv6=off 0` (environment credentials
removed for that process) displayed a 700-wide listener window. A process-scoped
window capture was visually inspected: status/controls/footer were unclipped and
IPv4 port 53382 matched the process's single listening TCP socket. An existing Saved
Profiles window was also restored; no outbound connection window was observed.
Normal termination targeted that exact process and completed with exit 0. This
smoke used the app's ordinary store readers, but did not accept a remote connection,
submit credentials or change settings. It is not evidence for incoming-window UI,
physical menu actions, saved-window restoration policy, reverse TLS, installed
LAN/firewall/privacy or release acceptance. Image: `/tmp/tidyvnc-cli-listen-launch.png`.
Build/test evidence prefix: `/tmp/tidyvnc-cli-listen-`.

Configuration-file listen review/precedence, tunnels and the remaining native plan
stay open. Host scope remains arm64 macOS 27, provisional target 14 with newer
Homebrew dependencies and crypto-disabled sanitizer builds; older OS/Intel/Linux
runtime acceptance is not claimed. All edits remain in the existing working tree.

### 2026-09-21 — Reviewed connection-file listener checkpoint

The current implementation follow-up is uncommitted on top of `0d80192e` (the
clipboard/UI-thread fix preserved on resume). This planning checkpoint records
the working-tree implementation separately from the earlier numeric-listen commit.
File listen startup now classifies file/socket paths, prepares defaults → CLI →
file settings without a session or bind, and requires explicit review. Every
recognized ServerName occurrence uses checked decimal port validation; empty or
absent means 5500. Mapping/re-edit preserves that interpretation. Approval retains
configuration and provenance for incoming windows without rereading preferences
or the source file. Selected displays are checked before accepting each peer;
cancel/close prevents late publication and clears unclaimed launch credentials.

Normal native/app builds passed. The full native suite passed **77/77 (87.91 s)**;
the six affected document/invocation/listener tests passed **6/6 ASan (3.80 s)** and
**6/6 TSan (17.20 s)**. Strict deep signature verification, **29/29** isolated
actual-executable terminal cases and branding checks passed (1650 unchanged
deferred entries). No C ABI or persisted schema changed. Logs use the temporary
prefix `/tmp/tidyvnc-file-listen-`.

The private fixture's review screenshot was inspected: port, enabled families,
ignored-field notice and approval/cancel controls were legible. Its process had no
TCP listener before approval. After approval, two waiting peers and the expected
listening port were observed, but the first capture had incomplete window chrome.
**Post-approval visual acceptance remains pending.** A second preview was started
for a stable capture; RESUME.md records its handle and cleanup steps. These checks
do not establish full-app interaction or installed acceptance.

Resume by completing that visual check and reviewing the implementation diff,
then continue tunnel entry paths and the unchecked plan gates. Host scope remains
arm64 macOS 27, provisional target 14 with newer dependencies and crypto-disabled
sanitizer builds. Older OS, Intel, Linux and release acceptance remain open.

Follow-up visual check: the stable process-scoped capture at
`/tmp/tidyvnc-file-listen-incoming-stable.png` shows the full 700-by-588 window,
header, port/family controls, two incoming peers, Accept/Reject and footer without
clipping. Displayed port 51786 matched that fixture process's listening socket.
The earlier preview and this replacement both exited normally; the two control
files were removed. This resolves the pending post-approval fixture visual check,
without expanding the installed/full-app acceptance claim.

### 2026-09-21 — Separate tunnel target identity from the forwarding socket

The new prepareRoutedSocketConnection accepts a logical TCP endpoint with a
nonempty route identity plus an already prepared local forwarding endpoint. Only
Unix sockets and numeric 127.0.0.1/::1 TCP endpoints without a scope/route are
accepted locally. It dials that local address while preserving the remote hostname
for the existing protocol/TLS path. Direct connect still rejects unhandled routes.
Endpoint copies, setup cancellation, deadlines, single-use admission and transport
drain retain existing connector behavior. Tunnel process lifetime belongs to the
host; this boundary does not start SSH.

The additive C export tidyvnc_session_connect_routed and ROUTED_CONNECT feature
bring the ABI to **112 exports**, without changing existing structs or persistent
schemas. NativeRuntime requires the new feature, and NativeSession exposes the
routed operation. CLI `via` remains unsupported until process startup, review,
credential/trust route scoping and cleanup are wired. See TUNNELS.md for that work.

Focused normal/ASan/TSan checks each passed **15/15 SocketConnector tests**, the
**pure-C ABI consumer**, and **NativeBridge.OwnershipAndLoopback**. They cover real
IPv4/IPv6/Unix socket exchange, logical server-name preservation without remote DNS,
invalid forwarding/route rejection, setup cancellation, admitted-transport ownership,
Swift routed RFB/frame delivery and direct reconnect. These are not end-to-end SSH
or TLS certificate acceptance tests. Native/app builds, strict deep signature,
**29/29** isolated executable terminal cases, branding and whitespace checks passed.
The rebuilt full native regression suite passed **77/77 (88.49 s)**. All build,
test and preview processes completed; none was left running.
Evidence prefix: `/tmp/tidyvnc-routed-connect-`; platform/deployment limitations above
still apply. Implementation and these follow-up docs remain uncommitted.

### 2026-09-21 — Owned SSH service and route-scoped credentials

NativeSSHTunnel now validates gateway/target grammar, derives a stable route digest,
starts an owned private SSH master, checks it, requests forwarding and awaits the
forwarding acknowledgement before returning a private Unix socket. Its process
owner isolates descriptors/environment, uses a fresh process group, cancels with
TERM/KILL, pins the child identity with waitid(WNOWAIT), and reaps before completing
cleanup. Temporary staged control sockets are included in bounded nonrecursive
cleanup. Initial support is existing host keys and noninteractive default-key/agent
authentication; SSH configuration commands, interactive authentication/trust and
app/CLI wiring remain open. TUNNELS.md defines exact scope and remaining work.

The private child fixture covers real RFB forwarding, failure/timeout/cancellation,
ignored TERM, staged socket cleanup, descriptor isolation, separate process groups,
concurrent close, dropped owners and discarded noisy stderr. A separate loopback
sshd fixture uses disposable keys and isolated host-key/authorized-key files to
verify actual SSH unknown-key rejection, public-key authentication, RFB negotiation
and cleanup without changing user SSH settings or stores.

The full normal native run passed **78/79 (90.99 s)**; the sole failure was Python's
missing os.waitid in the new test harness. After a compatibility fix, isolated SSH
passed on rerun. The final two tunnel tests passed **2/2 normal (2.21 s)**,
**2/2 ASan (2.21 s)** and **2/2 TSan (6.41 s)**, with no skips. The full suite was
not repeated after the focused staged-socket cleanup change. Native/app builds,
strict deep signature, 29 executable terminal cases, branding and whitespace checks
passed. Evidence prefix: `/tmp/tidyvnc-ssh-service-`.

NativeAuthenticationCredentials now keys remembered and session credentials by
logical endpoint plus route. Route changes clear retained session passwords.
Launch inputs bind to the first selected route (or an explicit earlier binding);
changing it destroys the inputs, and returning to the old route cannot replay them.
Existing direct accounts keep their empty-route key format. The retention and two
launch-credential tests passed **3/3 normal (1.37 s)**, **3/3 ASan (1.55 s)** and
**3/3 TSan (7.68 s)**, including default behavior and real authenticated loopback
attempts across two gateway identities and a direct identity. The rebuilt app
passed signature verification and **29/29** terminal cases. No further ABI/schema
change; 112 exports remain. Evidence prefix: `/tmp/tidyvnc-tunnel-credentials-`.

All recorded build/test/child/daemon processes completed. Implementation changes
remain uncommitted; the planning checkpoint is committed separately.
Next: app attempt ownership and child-exit handling, route-aware persistence/export,
CLI/file review wiring and honest SSH capability presentation. Parent N3.18/N4.11
and the complete plan remain open; arm64/macOS 27/deployment-floor limits still apply.

### 2026-09-21 — Preserve SSH routes in native storage and export review

NativeSSHGateway now validates without a remote endpoint or IO; request construction
can wait for final file/default target resolution. The gateway Codable boundary
stores a canonical URI and validates it again on decode. Its canonical byte bound
ensures every accepted value can be read back. No supplied route digest is trusted.

NativeConnectionDestination pairs exact UTF-8 target text with an optional gateway.
Profile/history schema **11** stores complete recent destinations and optional
profile gateways. Schemas 1–10 load as direct entries without writes; explicit
mutation atomically upgrades while preserving settings, IDs, credential references,
address ordering and history initialization/import markers. Direct and separate
user/host/port routes coexist, canonical equivalent gateways coalesce, and removal
selects the complete destination. Endpoint equality does not fold distinct Unicode
byte spellings. NativeRecentHistory's bounded queue and reload/clear now retain
complete destinations; endpoint-only compatibility accessors expose direct entries
only. Malformed/unknown route data and unsupported routed targets preserve old bytes.

NativeDocumentExportCapture preserves gateway metadata across monitor remapping.
Export adds a separate SSH gateway omission acknowledgement explaining that the
receiving viewer connects directly unless its gateway is configured separately.
The gateway and digest never enter compatibility-file output.

This is prerequisite storage/export work, not finished app tunnel support.
NativeSessionDefaults rejects routed profiles before publishing a session until
ConnectionModel owns the complete route. Existing profile editing preserves the
new field. Replace that temporary guard during actual app integration; update
recent/profile selection and live export capture together. CLI `via` remains
unsupported; N3.18/N4.11 and the complete plan remain open.

Regression coverage adds fresh private-file reopen, canonical route deduplication,
route-specific delete/conflict, schemas 1–10 migration, invalid-route preservation,
Unicode endpoint identity, queued-route lifetime, profile edit/admission behavior,
and gateway omission review before/after monitor remapping. Final focused tests
passed **7/7 ASan (5.86 s)** and **7/7 TSan (21.52 s)**, including the isolated
real OpenSSH test with no skips. Final full normal native regression passed
**79/79 (87.73 s)** after correcting two stale schema-10 assertions and adding the
UTF-8/URI-bound checks. The app rebuilt, strict deep signature verification and
**29/29** isolated executable terminal checks passed. Branding/whitespace checks
passed (1650 unchanged deferred occurrences). All builds/tests/fixtures completed;
changes remain uncommitted. Defaults schema 11 and C ABI 112 exports are unchanged;
profile/history schema is now 11. Existing arm64/macOS 27/deployment-floor limits
remain. Evidence prefix: `/tmp/tidyvnc-route-storage-final-`.

### 2026-09-22 — Commit initial app route integration and record remaining coverage

At the user's request, accumulated implementation changes were grouped into four
commits: reviewed file listening (`7d80856b`), routed transport identity
(`0913db13`), owned SSH processes and route-scoped credentials (`9cabf307`), and
route-aware storage/export plus initial connection-window integration (`9fcaa879`).
The preceding entries' uncommitted status is historical; planning changes are
checkpointed separately.

ConnectionModel now owns a fresh tunnel per attempt, scopes credentials/trust to
the logical destination and gateway, observes matching child exit, and shares an
uncancelled cleanup task intended to drain RFB before SSH. Recent selection carries
the complete destination; profile/connection gateway fields explain current SSH
limits; live export requires gateway-loss acknowledgement. The temporary routed
profile rejection described above has been removed. A sendable save-closure capture
error discovered during this checkpoint was fixed before committing.

Both normal native and app builds passed. Full native regression passed **79/79
(96.50 s)**, including process/OpenSSH fixtures; strict deep signature verification
and **29/29** isolated executable terminal checks passed. Branding and whitespace
checks passed. All recorded builds/tests/fixtures completed. Evidence prefix:
`/tmp/tidyvnc-commit-check-`. Earlier ASan/TSan evidence predates the new controller
integration; no sanitizer rerun or dedicated app tunnel lifecycle test was added
in this commit checkpoint.

Resume by adding an injected-factory ConnectionModel fixture for startup/admission
cancellation, committed-connect cancellation, remote/child death, stale observers,
disconnect/reconnect, dropped owners and repeated close/quit. Assert RFB drains
before ordinary tunnel teardown, cleanup prevents a new attempt, and startup and
exit observation are joined. Then wire CLI `via` through early gateway validation
and final file target resolution, with explicit listen/Unix incompatibility and
unsupported VNC_VIA_CMD handling. Interactive SSH authentication, host-key review,
configuration policy and installed/deployment acceptance remain open, as do
N3.18/N4.11 and the complete plan. See RESUME.md and TUNNELS.md for the handoff.


### 2026-09-22 — Tunnel controller coverage and CLI routing

Working-tree follow-up to the committed checkpoint; N3.18/N4.11 and the full plan
remain open for interactive SSH, app/installed acceptance and other parity gates.

- Added NativeTunnel.ConnectionControllerLifecycle and
  NativeTunnel.ConnectionControllerOpenSSH. The first compiles production
  ConnectionModel with real private child forwarding and asserts cancellation at
  startup/admission, RFB drain before tunnel close, replacement admission gating,
  remote/child exit, fresh reconnect, repeated close, dropped presentation,
  gateway/direct credential isolation and current-route export omission. The
  second uses disposable keys and the existing isolated OpenSSH daemon harness.
- CLI `via` now validates every occurrence before path/file IO, supports explicit
  empty/direct selection and preserves gateway user/host/port identity. The final
  file target is checked before session creation; routing metadata publishes
  before session/credential binding. Tests negotiate authenticated RFB through
  direct-CLI and reviewed-file launches with correctly scoped launch passwords.
  Listen and Unix-target incompatibilities fail explicitly. VNC_VIA_CMD presence
  rejects an active CLI gateway before credentials/logging/app startup; its value
  is never evaluated or reflected. Help discloses current SSH limitations.
- Clean app configure initially failed because Threads::Threads was visible only
  in child CMake scopes unless optional GoogleTest discovery supplied it. Added
  top-level production Threads discovery. The app now configures/builds with
  GoogleTest absent; no production dependency on the test framework was added.
- Initial full native run: 78/81 (105.35 s). Two pixel checks failed because the
  physical display profile clipped saturated blue before conversion back to sRGB.
  Both now render into sRGB from the start and preserve bitmap logical size; their
  original channel thresholds remain unchanged. Settings input-conflict measured
  680.5 points against a 680-point window. Grouped Reload with the error message;
  focused full settings renders pass, and light/dark conflict PNGs were inspected.
- Focused routing/controller checks passed 6/6 ASan (5.78 s) and 6/6 TSan
  (19.61 s), including actual isolated OpenSSH with no skips. Owned Swift/C/C++ is
  instrumented; external libraries/frameworks are not all instrumented. Crypto is
  disabled in sanitizer builds, enabled in the normal/app builds.
- Native app builds, strict deep signature verification, 32/32 executable
  terminal cases, branding/attribution (1650 unchanged deferred occurrences) and
  whitespace checks passed. CLI test environment uses an inert shell-marker value
  and verifies unchanged private HOME/XDG state. No C ABI/store schema change.
- Environment: arm64 macOS 27.0 build 26A428; CLT Swift 6.4 for native tests,
  Xcode Swift 6.3.1/SDK 26.4 for the app. Target remains provisionally macOS 14;
  Homebrew dylib deployment warnings remain. This does not prove older-OS/Intel,
  signing identity upgrades, installed LAN/privacy or physical keyboard/display
  behavior. Socket/AppKit/Xcode checks required granted sandbox escalation.
- Logs: /tmp/tidyvnc-controller-{asan,tsan}-{configure,build,tests}.log,
  /tmp/tidyvnc-controller-cli-{native-tests,native-final-tests,app-final-build,terminal-final}.log,
  /tmp/tidyvnc-controller-render-{diagnostics,fixed-tests}.log and
  /tmp/tidyvnc-controller-branding-final.log. Initial diagnostic failures remain in
  these logs; use the final evidence below for the completed regression result.
  Renders: build/native-ui-swift/tests/macos/settings-render/preferences-input-conflict{,-dark}.png.

- The next full run passed 80/81 (94.51 s) but exposed an intermittent SIGTRAP
  in NativeClipboard.PasteboardAndRouting. The crash stack identified
  NSPasteboard's mutable type cache during a fixture MainActor string read while
  the asynchronous worker used the same object. The fixture now shares a
  PasteboardWorker for simulated local writes and observations. An internal
  injection initializer preserves production asynchronous queue confinement;
  the prior UI-thread-blocking fix is not reverted. Final validation follows.

- Final current-source validation: **81/81 normal native tests (109.31 s)**;
  focused **7/7 ASan (7.38 s)** and **7/7 TSan (23.29 s)**, now including
  NativeClipboard.PasteboardAndRouting. The clipboard test also passed ten
  consecutive normal runs (16.73 s). Both isolated OpenSSH controller/service
  cases ran without skips in the normal suite; the controller case ran without
  skips in both focused sanitizer suites. Final app build, strict deep signature,
  **32/32** terminal cases, branding and whitespace checks passed.
  Final evidence: /tmp/tidyvnc-controller-cli-native-verified-tests.log,
  /tmp/tidyvnc-controller-{asan,tsan}-verified-tests.log,
  /tmp/tidyvnc-controller-clipboard-repeat.log,
  /tmp/tidyvnc-controller-cli-app-verified-build.log,
  /tmp/tidyvnc-controller-cli-terminal-verified.log and
  /tmp/tidyvnc-controller-branding-verified.log. All recorded builds/tests completed.
  The full native UI goal remains active; this is an implementation checkpoint,
  not a parity, physical-hardware, deployment-floor or release-signing completion.

### 2026-09-22 native SSH prompt integration

N3.18/N4.11 and the complete plan remain open. This follow-up implements the
password/passphrase prompt path; strict existing-host-key checking remains enabled.

- Added a private C askpass helper and bounded versioned Unix-socket protocol.
  Directory ACL/owner/mode, socket owner/mode and peer UID are checked. The helper
  never overwrites an existing leaf. Response framing rejects NUL/CR/LF and values
  beyond 1023 bytes; buffers are cleared. Only SSH's response pipe receives the
  response line. No SSH response enters VNC credentials, argv, environment or files.
- Added NativeSSHInteraction with immutable gateway/target context and per-request
  UUIDs. Stale responses are rejected and consumed. The utility socket worker
  observes peer exit and cancellation; close joins the prompt and socket before
  directory cleanup. ConnectionModel owns one interaction per connection and
  cancels/stops it on cancel/close. Service-only callers retain noninteractive
  behavior unless they supply the typed authentication owner.
- Added SSHAuthenticationSheet for use-once secret responses, permission hints and
  notifications. Untrusted prompt text renders literally in a bounded scroll view.
  Long route labels are bounded with full-text help; Cancel is the default for
  permission/notification prompts. Light/dark renders of all three states pass;
  representative images were inspected. CLI help and profile/connection capability
  text now describe native prompts and the remaining host-key/configuration limits.
- The Xcode app packages the helper in Contents/MacOS and signs it before signing
  the development bundle. Both bundle and helper pass strict signature verification.
  This does not establish distribution signing/hardening or older-OS compatibility.
- Added NativeTunnel.AskpassTransportAndInteraction and AskpassOpenSSH. The first
  uses actual helper subprocesses for bounds, stale answers, route isolation,
  private-file rejection, peer/owner cancellation and joined cleanup. The second
  uses a disposable encrypted key with the isolated daemon, covering actual SSH
  passphrase presentation, cancelled startup and successful RFB forwarding.
  It changes no user SSH configuration, keys, known-host records or passwords.
- Initial helper testing found Darwin's NULL/ENOENT absent-ACL representation;
  preflight now accepts that and still rejects nonempty/unsafe ACLs. Initial UI
  compilation found an uninitialized optional State alias; fixed before validation.
  Initial sanitizer helper checks failed because the fixture omitted PATH and the
  runtime could not find Apple's symbolizer. The fixture now uses production's
  fixed /usr/bin:/bin path and locale; its empty-stderr assertion remains intact.
- Full normal native suite: **83/83 (113.26 s)**. After the test-only environment
  correction, all six tunnel tests passed again: **6/6 normal (6.30 s), 6/6 ASan
  (7.47 s), 6/6 TSan (20.89 s)**. Actual OpenSSH tests ran without skips. Final app
  build, strict helper/bundle signature checks, **32/32** terminal cases, branding
  (1650 unchanged deferred occurrences) and whitespace checks pass. The full suite
  predates only the helper fixture's PATH correction; production sources are final.
- Evidence: /tmp/tidyvnc-ssh-final-native-{build,tests}.log,
  /tmp/tidyvnc-ssh{,-asan,-tsan}-final-tests.log,
  /tmp/tidyvnc-ssh-app-final-build.log, /tmp/tidyvnc-ssh-terminal-final.log,
  /tmp/tidyvnc-ssh-branding.log. Images: build/native-ui-swift/tests/macos/ssh-render/.
  Earlier /tmp/tidyvnc-interactive-ssh-* and sanitizer logs retain intermediate
  results; use the final evidence above. Native C ABI remains 112 exports and
  persisted schemas remain 11. All recorded builds and tests completed.
- Remaining: typed new-host-key review and supported SSH configuration, actual app
  prompt/close/quit interactions, further password/MFA acceptance, route-aware
  trust interactions, and the full inventory/hardware/installed/deployment/release
  gates. An OpenSSH permission hint is not a typed host-key decision. Do not enable
  automatic host-key acceptance or infer trust from untrusted prompt text.

### 2026-09-22 bound SSH gateway-key review

N3.18/N4.11 and the complete plan remain open. Common new-key review is now
implemented; this checkpoint does not claim complete SSH configuration or release
acceptance.

- Extended the private helper protocol with structured key observation. A fixed
  KnownHostsCommand argv template invokes the bundled helper; OpenSSH performs
  token expansion after argv splitting, without a shell. The helper reports
  HOSTNAME/type/public-key data over the private socket and emits no known_hosts
  entries. ORDER and ADDRESS calls leave ordinary lookup unchanged. Helper paths
  containing spaces, single/double quotes, percent and dollar characters are tested.
- NativeSSHHostKey binds the lookup hostname to the immutable gateway, checks the
  wire blob/algorithm, and computes SHA-256. Supported new-key formats are plain
  Ed25519, RSA and NIST ECDSA. A confirmation must match its hostname, algorithm
  and calculated fingerprint. Missing/malformed/mismatched observations and
  unsupported host-key confirmations fail closed instead of using a password field.
- NativeSSHQuestion has a separate host-key kind and immutable key details. Its
  response must be the calculated fingerprint; generic yes is rejected/consumed.
  The sheet shows gateway/desktop context, key type and fingerprint. Cancel is the
  default. Trust and Save returns the fingerprint to OpenSSH, which independently
  verifies the offered key and owns persistence before authentication. Changed and
  revoked saved keys cannot be approved through this new-key flow. Authentication
  prose alone cannot append a trusted key. The helper supplies no trust entries.
- Isolated daemon coverage independently calculates fingerprints in Python and
  verifies cancellation without a file write, explicit approval and exact saved
  key, authentication, reconnect without repeat approval, changed/revoked rejection,
  unchanged rejected files and joined directory/process cleanup. Disposable host
  keys cover Ed25519, RSA and ECDSA; no user keys/configuration/known-host files are
  changed by these fixtures. Light/dark host-key sheet renders passed and were
  inspected alongside the existing three prompt states.
- Final normal native suite: **85/85 (119.13 s)**. All eight tunnel cases passed
  **8/8 ASan (14.05 s)** and **8/8 TSan (33.55 s)**, with no OpenSSH skips. Final
  app build, strict deep bundle plus helper signature verification, **32/32**
  terminal cases, branding (1650 unchanged deferred occurrences) and whitespace
  checks passed. The helper inside the actual signed app bundle also passed the
  isolated encrypted-key/RFB and new/changed/revoked-key acceptance fixture.
- Evidence: /tmp/tidyvnc-hostkey-verified-native-tests.log,
  /tmp/tidyvnc-hostkey-{asan,tsan}-tests.log,
  /tmp/tidyvnc-hostkey-final-native-build.log, /tmp/tidyvnc-hostkey-app-build.log,
  /tmp/tidyvnc-hostkey-terminal.log, /tmp/tidyvnc-hostkey-bundled-helper.log and
  /tmp/tidyvnc-hostkey-branding.log. An early full regression was stopped because
  it started before the complete build finished; it is not counted as validation.
  The verified run began after the build reached exit 0. All recorded processes
  completed. Images: build/native-ui-swift/tests/macos/ssh-render/ssh-4{,-dark}.png.
- Environment remains arm64 macOS 27, CLT Swift 6.4/native and Xcode Swift 6.3.1/app,
  provisional deployment target 14 with newer Homebrew dependency warnings.
  Sanitizer crypto is disabled; system SSH/frameworks are not fully instrumented.
  Native portable C ABI remains 112 exports, persisted schemas remain 11.
- Remaining: supported SSH configuration with correct route/credential identity,
  actual app prompt/close/quit interactions, password/MFA and additional key-format
  acceptance, IPv6/scoped-host review, known-host save-failure reporting and the
  full inventory/physical-device/installed/deployment/signing gates. OpenSSH owns
  the save attempt; this checkpoint verifies successful writes and cancellation,
  not native reporting of unwritable known-host storage. See TUNNELS.md for the
  source-backed protocol rationale and RESUME.md for the current next steps.

### 2026-09-22 owned SSH configuration probe prerequisite

This follow-up advances configuration resolution; user SSH configuration remains
unsupported and the full goal remains active. See SSH-CONFIGURATION.md for the
remaining snapshot, intent, route identity and app-admission work.

- Added NativeTunnelOutput: single-consumer stdout capture, capped at 256 KiB,
  using a nonblocking dispatch read source. Pipe descriptors are close-on-exec,
  kept above stdio, explicitly duplicated/closed in child file actions and closed
  after read-source cancellation. Overflow cancels the existing owned process
  group. Launch failure, child exit and killed descendant writers drain correctly.
  Accumulators/chunks are cleared; stderr remains /dev/null and no temporary output
  files or raw-output diagnostics are introduced. Authentication paths do not use
  this capture option.
- Extended NativeTunnelProcess with optional stdout capture. Activation occurs only
  after PID and process-source ownership are installed, preventing an overflowing
  child from racing uninitialized cancellation/reap state. Existing callers retain
  their prior stdio behavior.
- Added NativeSSHConfigurationProbe and checked NativeSSHResolvedGateway. The probe
  has a deadline, task cancellation and joined cleanup; it returns only validated
  effective hostname/user/port. The baseline is explicitly `ssh -G -F /dev/null`,
  with no user/system configuration admission or app routing change. Duplicate,
  missing, invalid UTF-8/control and malformed routing fields are rejected.
- Extended the private process fixture and NativeTunnel.ProcessOwnershipAndForwarding
  with fragmented writes, exact bounds/backpressure, overflow cancellation, a
  descendant retaining stdout, cancelled silent children, missing executable,
  single-consumer/reuse rejection, real SSH dump parsing, IPv6, malformed/duplicate
  routing data, probe timeout and task cancellation.
- The first integrated probe test exposed OpenSSH's mixed-case
  canonicalizePermittedcnames output name. Option names now accept ASCII case
  variations and routing duplicates are checked after normalization. This fixture
  remains in the regression. No routing validation was removed.
- Final affected regression: **8/8 normal (14.40 s), 8/8 ASan (15.93 s), 8/8 TSan
  (35.28 s)**, including actual OpenSSH fixtures with no skips. App build, strict
  deep bundle/helper signatures, **32/32** terminal cases, branding (1650 unchanged
  deferred occurrences) and whitespace checks pass. The previous complete native
  suite remains 85/85 before this internal probe follow-up; it was not rerun here.
  All changed process/tunnel consumers were rebuilt for these focused tests.
- Evidence: /tmp/tidyvnc-ssh-probe{,-asan,-tsan}-verified-{build,tests}.log,
  /tmp/tidyvnc-ssh-probe-app-verified-build.log,
  /tmp/tidyvnc-ssh-probe-terminal.log and /tmp/tidyvnc-ssh-probe-branding.log.
  Earlier output/probe logs retain intermediate results. All recorded builds/tests
  completed. Platform/deployment/sanitizer limits remain those of the preceding
  host-key checkpoint. No portable C ABI or persisted schema changes (112/11).
- Next: immutable configuration snapshots and supported settings, preserving
  OpenSSH Host/Include/Match semantics; explicit/inherited port intent and storage;
  requested alias versus effective gateway/host-key identities; credential/trust
  binding before RFB admission. Do not enable live config merely by dropping -F:
  `ssh -G` evaluates Match conditions and is not a safe arbitrary-config validator.
  The app's unsupported-configuration disclosure intentionally remains in place.

### 2026-09-22 initial immutable SSH configuration snapshots

Configuration support and the complete goal remain open. This is the first
snapshot implementation, not app admission or completed configuration acceptance.

- Added NativeSSHConfigurationSnapshot with a joined utility task for preparation,
  task cancellation checks, private 0700/empty-ACL temporary directories, generated
  0600 filenames, and bounded inode-checked cleanup. Consumers must retain the
  snapshot and drain before close; it is not yet wired into a connection attempt.
- Capture checks regular-file ownership/mode/ACL, no-follow final components,
  per-file and aggregate bounds, UTF-8/control input and before/after revisions.
  Included files remain separate copies with rewritten absolute Include paths,
  preserving OpenSSH's own Host/Match matching and restoration semantics. Shared
  source inodes are cached, cycles/depth/file/reference limits are checked, and
  source revisions are checked again before publication.
- Initial policy admits enumerated non-command settings and non-exec Match
  criteria. Arbitrary command directives, forwarding, unrecognized options and
  unsupported Include expansions fail rather than falling back to live config.
  Relative and ~/ Includes use explicitly supplied roots; glob expansion has
  directory-entry and match limits. Percent/environment/named-user tilde expansion
  and final-component symlink files are not supported by this initial version.
- The existing NativeTunnel.ProcessOwnershipAndForwarding fixture now compares a
  private live file and its snapshot using actual `ssh -G`, verifies Include/Match
  state restoration, changes source files after capture, and exercises denied
  commands, cycles, revision changes, writable-by-others rejection and joined close.
  Focused normal test passed **1/1 (3.09 s)** after the native target built. Evidence:
  /tmp/tidyvnc-config-snapshot-{build,tests}.log. Both processes completed.
  Whitespace check passes. No C ABI/store schema change; test count remains 85.
- Next, before treating snapshot admission as complete: expand glob/path, missing
  versus inaccessible paths, token/quote, source-alias revision, bounds, symlink,
  ACL, partial-cleanup and deterministic cancellation coverage. Review error
  classification in glob traversal (currently some filesystem failures look like
  no matches) and ensure unsupported-setting diagnostics are actionable without
  exposing values. Add sanitizer/regression/app checks after those fixes. This
  initial snapshot slice has not yet had ASan/TSan or an app rebuild; the preceding
  eight-test evidence applies to the earlier configuration-probe boundary.
- Then implement explicit/inherited port intent, validated persistence, effective
  route/host-key identity and ConnectionModel preparation/credential binding.
  App/help still correctly says user SSH configuration is unsupported. See
  SSH-CONFIGURATION.md; do not simply remove -F /dev/null or consume live files.


### 2026-09-22 snapshot filesystem revisions and boundaries

This continues the internal configuration admission prerequisite; user SSH
configuration remains unsupported by the app and no main plan gate is closed.

- Snapshot expansion distinguishes ENOENT/ENOTDIR from other directory/stat
  failures and checks readdir errors/cancellation. Every visited source pathname
  retains its own revision, including multiple names for one inode.
- Escaped Include patterns reject explicitly instead of losing escape intent
  during tokenization. Oversized source files report the bounded-input limit.
- Real `ssh -G` comparisons verify glob order, hidden files, quoted paths and
  missing patterns. Additional tests reject looping intermediate symlinks, final
  symlink files, FIFO inputs and a moved secondary source path, plus file/line,
  depth and include-reference limits. A deterministic cancellation checkpoint
  confirms that prepared private files are removed before cancellation returns.
- Focused normal tunnel suite: 8/8, 15.90 s. TSan: 8/8, 35.37 s. Initial ASan
  concurrent run: 7/8, process/configuration case failed with a generic probe
  error, without a sanitizer memory report. Isolated recheck: 1/1, 2.74 s;
  subsequent full ASan run: 8/8, 14.49 s. Cause of initial failure remains
  unconfirmed; timing contention is only a hypothesis.
- Logs: /tmp/tidyvnc-snapshot-boundaries-{build,tests}.log,
  /tmp/tidyvnc-snapshot-boundaries-{asan,tsan}-{build,tests}.log,
  /tmp/tidyvnc-snapshot-boundaries-asan-recheck.log and
  /tmp/tidyvnc-snapshot-boundaries-asan-verified-tests.log.
- Native app build succeeds; strict deep app and helper signatures pass;
  terminal invocation checks pass 32/32; branding audit passes with baseline
  1650 deferred occurrences. Logs: /tmp/tidyvnc-snapshot-boundaries-app-build.log
  and /tmp/tidyvnc-snapshot-boundaries-terminal.log. `git diff --check` passes.
  All handles completed. Full 85-test suite was not repeated for this follow-up.
- Next: remaining admission review/coverage (lexer equivalence, ACL, unique-count
  and aggregate bounds, partial failures, restrictive umask/modes and directory
  identity during cleanup), followed by intent migration, effective host-key/route
  identity and credential/trust binding before RFB admission. No app integration,
  physical acceptance or release claims follow from these internal tests.


### 2026-09-22 snapshot ownership and lexical acceptance

- Establish exact private directory/file permissions even when the embedding
  process uses umask 0777. The new separate-process umask fixture initially failed
  and drove a fix: set owner directory access without following a final symlink,
  then open/verify its inode and set the empty ACL. Copied files receive fchmod
  0600. The corrected focused test passes 1/1 (3.10 s).
- Cleanup compares the directory pathname with the owned descriptor's original
  device/inode. A replacement directory is preserved, while owned leaves in a
  moved original directory are removed through that descriptor. Removed the
  redundant per-inode source URL; revisions remain per source pathname.
- Corrected Include tokenization: an unquoted hash inside a word is literal;
  only a hash starting a token introduces a comment. Real OpenSSH comparisons
  cover unquoted, single/double-quoted and trailing-comment forms. ASCII whitespace
  trimming prevents silently normalizing Unicode whitespace into directive syntax.
- Added ACL rejection, exact file-size admission, aggregate-byte and unique-file
  limits, construction-error cleanup and replacement-directory coverage. These
  supplement the prior glob, alias revision, FIFO, symlink, cancellation and other
  boundary cases; configuration remains internal and unwired to app routing.
- Final tunnel suite: normal 8/8 (14.01 s), ASan 8/8 (15.53 s), TSan 8/8 (36.71 s).
  Tests ran after the builds completed. Logs:
  /tmp/tidyvnc-snapshot-final-native-tests.log,
  /tmp/tidyvnc-snapshot-final-asan-tests.log,
  /tmp/tidyvnc-snapshot-final-tsan-tests.log; build logs use
  /tmp/tidyvnc-snapshot-final-native-ui-swift{,-asan,-tsan}-build.log.
  Initial umask failure/corrected focused evidence is in
  /tmp/tidyvnc-snapshot-ownership-{initial,verified}-tests.log.
- App build succeeds (/tmp/tidyvnc-snapshot-final-app-build.log), strict deep app
  and helper signatures pass, terminal invocation passes 32/32
  (/tmp/tidyvnc-snapshot-final-terminal.log), branding audit passes with the same
  1650 deferred occurrences, and git diff --check passes. All handles completed.
  The full 85-test suite was not repeated for this follow-up. The prior transient
  ASan probe failure is retained above; final runs did not reproduce it.
- Next: gateway explicit/inherited port intent and compatible persisted migration,
  then effective route/host-key identity and immutable app attempt preparation
  before credential/trust binding. Keep old stored :22 semantics, reject unsupported
  Include expansions explicitly, and do not enable live configuration-file probes.
  Full native UI, physical/installed acceptance and release gates remain open.


### 2026-09-22 gateway port intent and schema-12 migration

- NativeSSHGateway retains portIsExplicit and omits an inherited port from its
  canonical URI. Codable writes a closed version-2 object with version/uri;
  old string encodings always decode to concrete ports, including hand-authored
  omitted port 22. Gateway validation, IPv6/scope handling and redacted decode
  failures remain. Canonical byte bounds and strict version/key tests are updated.
- Profile/history writes schema 12; schemas 1–11 remain readable without eager
  writes. Schema 11 requires string gateways and schema 12 requires validated
  objects, preventing ambiguous cross-version interpretation. Defaults stay schema
  11 and C ABI stays 112. Existing saved profile and recent gateway ports survive
  migration, while newly inherited and explicit ports remain distinct destinations.
- Tests cover old profile/recent omitted-port migration, byte-preserving reads,
  explicit mutation and reopening, separate history destinations, malformed/new
  gateway versions, unknown fields and failed-load preservation. Updated profile
  schema expectations across settings/history/import tests; defaults expectations
  remain 11. The full native build and all 85/85 tests pass (120.76 s).
- Logs: /tmp/tidyvnc-port-intent-{build,full-build,full-tests}.log. Native app build
  succeeds (/tmp/tidyvnc-port-intent-app-build.log); strict deep bundle and helper
  signatures pass; actual terminal checks pass 32/32
  (/tmp/tidyvnc-port-intent-terminal.log). Branding audit passes with baseline
  1650 deferred occurrences; git diff --check passes. All handles completed.
  Sanitizers were not rerun for this immutable value/storage change; preceding
  snapshot sanitizer evidence remains scoped to that checkpoint.
- This does not enable configuration support: existing tunnel argv and legacy
  route digests still use concrete port 22. Next implement typed effective gateway/
  host-key identity and owned snapshot/probe preparation, then bind credentials and
  trust to the immutable resolved attempt before RFB admission. Do not use a
  requested alias digest as an effective route. Full UI/physical/installed/release
  acceptance remains open.


### 2026-09-22 resolved gateway identity and owned preparation

- NativeSSHResolvedGateway now validates an optional bounded literal hostkeyalias,
  derives the key lookup name and hashes effective host/account/port/key identity
  into ssh-v2. Absent alias, explicit aliases and a literal alias "none" remain
  distinct. Duplicate/malformed/oversized alias fields reject. The namespace is
  separate from requested alias-based scopes, preventing silent reuse of legacy
  VNC credentials/trust when later app integration adopts effective routing.
- NativeSSHConfigurationProbe.resolve consumes an admitted private snapshot, passes
  explicit user/port precedence, and allows configuration Port only for inherited
  intent. NativeSSHPreparedGateway owns requested alias, snapshot and typed result;
  failed resolution awaits cleanup, and close joins/idempotently removes copies.
  It remains internal; master launch, askpass and ConnectionModel are not switched.
- New real OpenSSH tests cover two equivalent aliases, configured versus explicit
  account/port, retained immutable snapshot after source changes, changed effective
  routes, scoped IPv6, alias/default key lookup, separate credential/trust scopes,
  invalid aliases and cleanup after SSH rejects an admitted option value.
- Initial focused case passes 1/1 (3.18 s); final tunnel suite passes 8/8 (14.59 s).
  Logs: /tmp/tidyvnc-resolved-gateway-{build,tests,verified-build,verified-tests}.log.
  App build succeeds (/tmp/tidyvnc-resolved-gateway-app-build.log), strict deep bundle
  and helper signatures pass, terminal checks pass 32/32
  (/tmp/tidyvnc-resolved-gateway-terminal.log), branding passes with baseline 1650,
  and git diff --check passes. All handles completed. Full 85-test and sanitizer
  suites were not repeated for this internal preparation follow-up.
- Next: authoritative prepared master route/key lookup and effective policy,
  canonicalization/Match consistency, absent-default-config handling, askpass key
  binding and atomic app admission before credential/trust/RFB operations. In
  particular, HostKeyAlias=none names an alias and cannot be used to clear it;
  preserve certificate principal semantics as well as lookup names. Configuration
  remains unsupported in app/help, and full UI/installed/physical/release gates
  remain open. SSH-CONFIGURATION.md records this integration boundary and source.


### 2026-09-22 prepared master enforcement and configured RFB acceptance

- Internal NativeSSHTunnel(prepared:endpoint:network:authentication:) launches from
  the owned snapshot and publishes ssh-v2 route identity. Master argv fixes effective
  hostname/user/port and explicit key alias, retains requested alias selection,
  disables further canonicalization and escapes HostName percent bytes for scopes.
- Before launching, a cancellable owned -G preflight compares the typed route plus
  a digest of all emitted settings except native-authoritative controls. Divergent
  Match policy fails with changedPolicy. Match localnetwork is rejected during
  admission because network changes could invalidate verification. No raw config
  dump is retained/logged. Default key lookup is not replaced by a literal alias
  "none", preserving certificate principal semantics.
- Prepared environment retains a bounded SSH_AUTH_SOCK. Askpass key records bind
  to prepared key lookup identity. Close and deinit join preflight, master/control
  children and prompts before closing the snapshot; master exit alone does not
  release config while a control command could still be consuming it.
- Extended real-SSH fixture reaches RFB using config aliases with both default
  lookup and explicit HostKeyAlias. It mutates the original config before startup,
  verifies effective route publication, closes during startup, and drops a live
  prepared owner. Unit/probe coverage rejects re-evaluated Match policy and dynamic
  network matching, verifies scoped IPv6 replay and observer identity binding.
- Initial extended fixture timed out because it reused the one-shot VNC peer.
  Corrected to a fresh peer per case. The killed test left one verified SSH master
  and two private directories; the master was terminated, exit verified, and only
  those known files/directories removed. Final acceptance snapshot scan reports zero.
- Final normal suite 8/8 (15.17 s), ASan 8/8 (17.19 s), TSan 8/8 (37.12 s).
  Logs: /tmp/tidyvnc-prepared-master-{owned-build,owned-tests,asan-build,asan-tests,
  tsan-build,tsan-tests}.log. Earlier timeout evidence:
  /tmp/tidyvnc-prepared-master-initial-tests.log; corrected initial rerun:
  /tmp/tidyvnc-prepared-master-final-tests.log (8/8, 14.74 s).
- App build succeeds (/tmp/tidyvnc-prepared-master-app-build.log), strict app/helper
  signatures pass, terminal cases 32/32 (/tmp/tidyvnc-prepared-master-terminal.log),
  branding passes with unchanged 1650 baseline, and git diff --check passes. All
  recorded handles completed. Full 85-test suite was not repeated for this slice.
- Next: absent default config, explicit network policy during preparation,
  configured interactive/helper acceptance, then app attempt/credential/trust and
  launch-secret/retry integration. Public app factory still uses -F /dev/null;
  supported internal service behavior is not yet a configuration-capable app path.
  Schemas/ABI unchanged. Full native UI/physical/installed/release gates stay open.


### 2026-09-22 default config, network binding and configured interaction

- prepareDefault admits an absent ~/.ssh/config as a private empty snapshot.
  Explicit missing config still fails, as do bad/inaccessible parent paths and
  dangling final or intermediate symlinks. Missing parents are checked without
  treating broken links as ordinary absence; absence/parent safety are revalidated
  before publication. No user configuration file/directory is created.
- Preparation captures NativeNetworkPolicy and applies AddressFamily to the first
  probe. Prepared tunnel construction inherits that policy and rejects an explicit
  mismatch. Disabled TCP families reject before file preparation. Tests cover empty
  defaults under IPv4/IPv6/both, explicit missing files, malformed parents, dangling
  links and config appearance during capture.
- Real helper fixtures now cover configured encrypted-key authentication, prompt
  cancellation and RFB, plus configured HostKeyAlias cancel/save/repeat, independent
  fingerprints, exact saved entries, changed/revoked rejection and snapshot cleanup.
  The helper path still contains spaces/quotes/percent/dollar characters. These run
  for the existing Ed25519/RSA/ECDSA daemon variants; each RFB attempt has a fresh peer.
- Final normal tunnel suite 8/8 (19.91 s), ASan 8/8 (23.08 s), TSan 8/8 (44.56 s).
  Logs: /tmp/tidyvnc-config-defaults-auth-{final-build,final-tests,asan-build,
  asan-tests,tsan-build,tsan-tests}.log. Earlier normal coverage also passed 8/8
  (20.35 s) before adding the dangling-parent boundary regression.
- App build succeeds (/tmp/tidyvnc-config-defaults-auth-app-build.log), strict deep
  app/helper signatures pass, terminal checks 32/32
  (/tmp/tidyvnc-config-defaults-auth-terminal.log), branding passes with baseline
  1650, and git diff --check passes. All recorded processes completed. Full 85-test
  suite was not repeated for this follow-up; ABI/schemas remain unchanged.
- Next: preparation phase in app attempt ownership, useful redacted failure mapping,
  effective credential/trust binding before RFB, separate requested/effective launch
  credential pinning and retry tests. Preserve aliases in history/profiles. The app
  factory still uses -F /dev/null and correctly reports configuration unsupported;
  do not change that disclosure until app integration is verified. Full native UI,
  installed/physical acceptance and release gates remain open.


### 2026-09-22 configured SSH app admission and launch binding

- NativeConfiguredSSHTunnel owns default preparation and joins cancellation/close.
  It maps snapshot/probe errors to fixed native failures. ConnectionTunnelAttempt
  prepares before binding credentials/trust or starting SSH/RFB, then validates
  the returned route against that result. History keeps the requested destination.
- Requested launch scope now uses a separate intent digest, including inherited
  versus explicit :22. The first effective route is pinned independently; changed
  resolution cannot retarget launch inputs. Direct-route behavior is preserved.
- Controller tests exercise a private default config alias through actual SSH/RFB,
  launch authentication, fresh reconnect, unsupported config on a later attempt,
  and cancelled/closed preparation before any SSH process starts. Credential tests
  cover same-intent/effective-route changes and distinct port intent.
- Normal full suite ran 85 cases: 84 passed in 129.04 s. The only failure was the
  added test's invalid bare gateway:22 form; corrected to ssh://gateway:22. The four
  launch/controller cases then passed in 3.69 s. Earlier configured-controller
  timeout was a fixture expectation error: explicit Disconnect clears launch input,
  so reconnect correctly prompted. The fixture now supplies a fresh password.
  Its two failed runs left SSH masters 12192/12668; both were verified, terminated,
  verified exited, and only their four identified private directories were removed.
  The new fixture also joins controller cleanup on failure.
- Final ASan 10/10 passed in 24.63 s; TSan 10/10 in 50.59 s. All builds/tests reached
  terminal success after the fixture corrections. Logs use prefix
  /tmp/tidyvnc-config-app-binding- with full-tests.log, corrected-tests.log,
  asan-final-build.log, asan-tests.log, tsan-final-build.log and tsan-tests.log.
  Full 85 was not repeated after the fixture-only correction. Final help-copy and
  comment edits do not alter the validated controller/credential behavior.
- UI and CLI help now describe the supported ~/.ssh/config subset. Commands,
  proxy hops, dynamic network Match and VNC_VIA_CMD remain unavailable. This replaces
  inaccurate blanket wording without claiming completed native UI acceptance.
- Final app build passes (app-final-build.log); codesign --verify --deep --strict
  passes on the bundle and --strict on Contents/MacOS/tidyvnc-ssh-askpass. Terminal
  acceptance passes 32/32 (terminal.log); branding passes baseline 1650
  (branding.log); git diff --check passes. No ABI/storage schema change.
- Next: app-level configured route changes with saved/session credentials and
  certificate trust, preparation cancellation/deallocation coverage, host-key
  save-failure reporting and actual native/installed interactions. Remaining parent
  plan gates stay open; this checkpoint does not establish parity or release readiness.


### 2026-09-22 configured route-scope controller acceptance

- Added actual SSH/RFB controller acceptance for native saved and retained session
  passwords across an unchanged retry, a changed HostName behind the same requested
  alias, and a direct connection. Only the unchanged effective route permits reuse.
- The same controller's trust adapter is exercised with real DER and a test target:
  the original and unchanged retry match the saved scoped certificate; changed and
  direct routes remain absent and cannot auto-approve. Original trust records are
  preserved. This verifies controller scope publication, not TLS wire behavior or
  native certificate-sheet interaction. Legacy host-wide exception compatibility
  is intentionally unchanged as specified in TRUST.md.
- NativeTunnel.ConnectionControllerLifecycle and ConnectionControllerOpenSSH both
  pass (2/2, 3.51 s), with logs /tmp/tidyvnc-config-scopes-{build,tests}.log. Tests use
  only private config/known-host fixtures and memory credential/trust backings.
- Native UI access is now working through cua_repl. Selecting the exact native app
  path avoids the ambiguous shared bundle identifier. The actual window shows the
  current SSH disclosure, inline invalid-host/port errors and disabled Connect.
  No connection was initiated; the form was restored empty. At the supported
  640-point minimum width, the server field was visibly squeezed to roughly eight
  characters. The two-row toolbar correction was subsequently rebuilt and verified
  in the native window as recorded below.


### 2026-09-22 native connection toolbar visual acceptance

- Corrected the real 640-point connection-window layout: endpoint and connection
  action now occupy their own row; auxiliary controls stay on the second row.
  Native screenshots confirm the address field grows from about eight characters
  to approximately 490 points. Inline errors and SSH disclosure remain readable.
- cua_repl opened the exact built app path, checked valid and invalid form admission,
  and read the actual clipboard menu's Send/Receive controls and source labels.
  No connection was initiated and no clipboard option or saved setting changed.
  Form restored empty. UI-ACCEPTANCE.md records observations and limits.
- Initial toolbar edit failed Swift compilation because a moved block attached to
  the import conditional. It was corrected, rebuilt and inspected natively before
  acceptance. Final build succeeds, strict deep app signature passes, terminal
  acceptance passes 32/32, and git diff --check passes. Logs:
  /tmp/tidyvnc-connection-toolbar-{final-build,terminal}.log.
- No full-suite or sanitizer rerun: production changes only rearrange existing view
  controls; behavior and scope changes this slice are test coverage. Prior sanitizer
  evidence remains historical, not a claim that the expanded fixture ran under it.
- Native UI access is no longer a blocker. Parent UI/clipboard/SSH/installed and
  physical acceptance gates remain open; basic form inspection cannot close them.


### 2026-09-22 SSH host-key save-failure reporting

- NativeTunnelProcess can route stderr to the owned output pipe. Diagnostic mode
  reduces it to a fixed OpenSSH failure-prefix flag, retaining no raw host/path/
  prompt text. Probe stdout remains bounded; diagnostic streams drain in constant
  space, including noisy-process fixtures. Fragmented and embedded-prefix cases
  verify classification and stdout exclusion.
- Master argv owns INFO verbosity and disables LogVerbose overrides. Prepared-policy
  comparison excludes these native-owned values. Readiness drains bytes already
  emitted before acknowledging the master, then rejects a reported initial save
  failure before forwarding/RFB. Error cleanup also reports it if authentication
  ends early; task cancellation remains cancellation. A shared drain task joins
  output ownership for concurrent close and deallocation.
- New error is fixed/redacted and directs the user to check known-hosts access.
  This observes OpenSSH's reported write result, not independent durability or
  file-integrity verification. A spoofed failure line can only deny admission.
  Source: [OpenSSH host verification](https://github.com/openssh/openssh-portable/blob/master/sshconnect.c).
- Real helper fixtures cover failed writes using a regular file in the parent
  position, both configured/unconfigured paths, QUIET/LogVerbose settings, and
  successful versus ended authentication for Ed25519/RSA/ECDSA. Native/system
  known-host files and SSH configuration are untouched.
- Normal SSH suite 8/8 passes in 26.03 s: /tmp/tidyvnc-hostkey-save-verified-tests.log.
  Initial code/test iterations exposed an erroneous fixture edit, diagnostic-volume
  regression and fixture source penalties; all corrected. The isolated daemon now
  probes sshd -T and disables PerSourcePenalties only when supported. This prevents
  intentional authentication failures from suppressing later test prompts. See
  [sshd penalty policy](https://man.openbsd.org/sshd_config#PerSourcePenalties).
- ASan initially passed 7/8 in 27.17 s. The new controller trust-scope fixture needed
  explicit handling of sanitizer builds without GnuTLS: normal builds extract the
  real DER key; unsupported extraction uses public fixture SPKI for scope-only
  checks and prints that limitation. Normal affected controller cases pass 2/2 in
  4.26 s; ASan affected case passes 1/1 in 2.93 s. These are not TLS-codec sanitizer
  tests. TSan full SSH suite passes 8/8 in 51.74 s.
- Logs use /tmp/tidyvnc-hostkey-save- prefix: final-build.log, verified-tests.log,
  asan-final-build.log, asan-tests.log, scope-build.log, scope-tests.log,
  asan-scope-build.log, asan-scope-tests.log, tsan-final-build.log,
  tsan-scope-build.log and tsan-tests.log. All handles completed. Full 85 not repeated.
- App final build succeeds (app-final-build.log); strict deep bundle and strict
  helper signature checks pass; terminal acceptance passes 32/32 (terminal.log),
  branding passes baseline 1650 (branding.log), and git diff --check passes.
- Native profile inspection opened the empty library, then the connector failed
  after New Profile. App remains alive; no crash established and no Save invoked.
  Reset/rebind did not recover access. Draft-screen and installed/save-error UI
  acceptance remain unverified; UI-ACCEPTANCE.md records the exact observations.

### 2026-09-22 — Settings/encoding localization, expanded controls and Help acceptance

The catalog grows from 228 to **304** English source entries: 75 Settings/encoding
entries plus the adaptive trust-review action. Settings sections/clipboard,
defaults diagnostics, encoding controls/source labels and live encoding recovery
use stable IDs and English defaults. Dynamic encoding names/values remain literal
arguments; wire values, schema ranges and behavior are unchanged. Retained gettext
catalogs and attribution are untouched. No C ABI or storage schema changes.

Expanded rendering caught defects beyond fitting-size checks: the destination
placeholder and trust-save button labels truncated; Settings compressed encoding
rows and clipped Restore; live encoding clipped reload; inherited input choices
truncated. The destination now has a wrapping visible/accessibility label. Trust
save/replace actions adapt to full wrapping text plus Review Decision, opening the
existing confirmation with the same safe default. Settings content now scrolls in
a bounded window with visible errors/recovery and action controls. Restore adapts
to a second row, live encoding reload has its own row, and input labels appear
above full-width pickers. Representative ordinary, expanded light/dark and mirrored
RTL screenshots were inspected. Scroller images show their visible content only;
interactive scroll/keyboard/VoiceOver and translated-language acceptance stay open.

Help explicitly selects SwiftUI's macOS 14 State property wrapper rather than the
new SDK macro. The initial sandboxed Xcode build could not start the macro plugin;
the final authorized app build passes. The initial sandboxed renderer could not
create its loopback peer; the authorized isolated-fixture runs below pass. Neither
failure was an automatic approval rejection. New CUA Help/About evidence and the
reproduced New Profile connector failure are in UI-ACCEPTANCE.md; no app crash was
established and no durable profile or trust/credential action was taken.

Validation:

- Focused native targets built. Preferences revision/persistence, encoding draft/
  session isolation and ordinary rendering: **3/3 (26.75 s)**. After the last
  picker/action-row layout changes, final ordinary rendering: **1/1 (27.01 s)**.
- Final expanded and mirrored expanded renderers both exit 0. Prefix selection and
  `--rtl` are now supported by the isolated-bundle runner. PNG review includes
  Settings input-conflict/encoding, live encoding conflict, certificate/server-key
  libraries and save/replace actions. Synthetic padding is never shipped.
- Final app build passes, strict deep signature passes, all **304** packaged values
  and missing-key/untranslated-language/interpolation checks pass; **32/32** actual
  executable terminal cases pass with isolated HOME/XDG unchanged. Branding remains
  **1650** deferred occurrences. Whitespace checks pass.
- Full 85-test suite and sanitizers were not repeated for presentation-only work;
  their prior results remain historical. No minimum-OS, installed-app, physical
  display/input, full accessibility or release acceptance is inferred.

Evidence: `/tmp/tidyvnc-settings-localization-{build,tests,branding}.log`,
`/tmp/tidyvnc-settings-final-{app,render,bundle,terminal,expanded,rtl}.log`,
`/tmp/tidyvnc-settings-final-expanded/`, `/tmp/tidyvnc-settings-final-rtl/`.
All recorded build/test handles completed. The app process retained after the CUA
failure predates the final rebuild; relaunch through CUA when access recovers.
Continue the complete unchecked checklist; next localization includes remaining
settings subfields and must remove English inheritance-label comparisons before
translating their profile reset behavior. N4.15/N4.16/N4.17 remain open.

### 2026-09-22 — Input/scaling/security/certificate-file localization

The catalog grows from 304 to **460** English source entries. Input, scaling,
connection options, security method/TLS priority and certificate-file controls,
connection-local sheets and fixed model errors now use stable catalog IDs with
English defaults. Whole-sentence interpolation preserves literal option/path-like
values and percent signs. Protocol method names and stored enum/wire values remain
unchanged. Input/scaling reset labels use a typed inheritance source; translated
English is no longer compared for reset behavior. Input accessibility IDs are
independent of localized display labels. No ABI or persistence-schema changes.

Expanded rendering found an oversized scaling sheet and then horizontal Form
column overflow despite passing fitting assertions. Scaling now uses a vertical
stack of full-width controls. Inherited selections show a short picker label plus
a wrapping effective-value caption. Input modifiers use two columns; input,
scaling and security scroll regions are bounded, preserving action/recovery space.
Certificate paths occupy their own row, with Choose/None below and explicit
accessibility labels. CA/CRL action labels use complete localized strings instead
of lowercase/concatenated fragments. The final scaling/defaults/trust-file PNGs and
mirrored input/security light/dark examples were inspected. Scroller images show
only the visible viewport; interaction/VoiceOver/translation acceptance stays open.

Validation:

- Focused targets and final app build pass. Profile/input/scaling/security/
  connection model tests: **5/5 (1.60 s)**; configured certificate-file inheritance:
  **1/1 (0.17 s)**. Final ordinary settings renderer: **1/1 (26.61 s)**.
- Final expanded and mirrored expanded fixture runs exit 0. The initial scaling
  height failure and subsequent visually detected Form/picker/path issues were
  fixed before the final builds. An initial CTest command addressed the build root,
  which registers no tests; the reported pass is from `tests/macos` above.
- All **460** packaged catalog values, missing-key/untranslated-language fallback
  and interpolation checks pass. One intermediate bundle check used a newly edited
  catalog with an older app and correctly rejected the absent effective-value key;
  rebuilding the app and rerunning resolves it. The final test directly checks
  effective-value interpolation and preserves literal `100%`/`125%x80%` values.
- Strict deep app signature, **32/32** executable terminal cases with isolated
  HOME/XDG unchanged, branding baseline **1650**, and whitespace checks pass.
- No full 85-test or sanitizer rerun for these presentation changes. No new actual
  app interaction, installed/physical/minimum-OS or release acceptance is claimed.

Evidence: `/tmp/tidyvnc-fields-{model-build,model-tests,trust-tests,captions-build,
final-app,final-render,final-bundle,final-terminal,final-branding,final-rtl}.log`,
`/tmp/tidyvnc-fields-captions-expanded.log`,
`/tmp/tidyvnc-fields-captions-expanded/`, `/tmp/tidyvnc-fields-final-rtl/`.
All recorded process handles completed. Next: fullscreen/remote-resize localization
and the remaining unchecked plan. N4.16 and all parent acceptance gates stay open.

### 2026-09-22 — Fullscreen/remote-resize localization and physical RTL maps

The catalog grows from 460 to **534** English source entries. Fullscreen defaults
and connection-local display selection, resize defaults/policy/request sheets,
display descriptions, fixed draft diagnostics and server results use stable IDs
and English defaults. Profile inheritance labels for the migrated settings groups
are also localized. Display names and formatted numeric results remain literal
arguments; stored IDs, input syntax, protocol admission and persistence are unchanged.
The requested-layout summary uses a screen-count label, avoiding “1 screens.”

Inherited choices expose effective values below short picker labels. Initial-size
blank guidance wraps visibly above the field. Sheets bound their scroll content
and keep recovery/actions outside it. The first expanded screenshots exposed a
truncated resize-source choice and multiline display rows clipped by estimated
single-line heights. The source picker now occupies its own full-width row, and
live display lists use the enclosing sheet scroller. The next mirrored screenshot
exposed SwiftUI reversing the physical map: both diagrams now explicitly retain
left-to-right coordinate order while surrounding controls mirror. Final light/dark
RTL screenshots show the selected left display still on the left. The fullscreen
presentation fixture accepts `--rtl` for repeatable coverage.

Validation:

- Focused native and final app builds pass. Fullscreen presentation/persistence and
  remote-resize policy/persistence: **4/4 (9.09 s)**. After the final geometry fix,
  ordinary settings/fullscreen presentation: **2/2 (27.25 s)**.
- Expanded settings/fullscreen and final mirrored settings/fullscreen fixture runs
  exit 0. Representative defaults, selected-display and policy screenshots were
  inspected. The isolated fullscreen fixture logs an AppKit sandbox-extension
  warning but completes its behavioral/render checks successfully.
- **534** packaged catalog values, missing-key/untranslated-language fallback and
  literal interpolation pass. New checks cover percent/Unicode display names,
  locale-formatted dimensions and UInt32.max server-result text. Scoped view
  defaults also match their catalog values. Strict deep signature, **32/32**
  executable terminal cases, branding baseline **1650** and diff checks pass.
- No full-suite/sanitizer rerun for this presentation-only slice. The existing
  dependency deployment warnings remain: the current macOS/SDK build is not
  proof of the declared macOS 14 floor. No physical/installed/release acceptance.
- A fresh CUA getApp again reports a closed native pipe. No interactive action,
  app crash conclusion or additional keyboard/VoiceOver acceptance follows.

Evidence: `/tmp/tidyvnc-display-{localization-build,model-tests,final-build,
final-app,final-tests,final-bundle,final-terminal,final-branding,final-expanded,
final-rtl}.log`; `/tmp/tidyvnc-fullscreen-{expanded,final-rtl,physical-rtl}.log`.
Images: `/tmp/tidyvnc-display-final-expanded/`, `/tmp/tidyvnc-display-final-rtl/`,
`/tmp/tidyvnc-fullscreen-physical-rtl/`. All process handles completed. Continue
remaining menus/connection/profile/document/history/listener/status localization,
fixed controller errors and the entire unchecked checklist. N4.16 remains open.

### 2026-09-22 — Profile/history/import localization and minimum-window fixes

The catalog grows from 534 to **645** English source entries. Profile/history
labels, storage recovery, endpoint validation, history-import source/review/result
presentation, controlled import diagnostics and relevant source-access errors use
stable IDs. Gateway tooltips and removal labels are complete localized messages;
addresses, gateway names and line numbers remain literal arguments. Count summaries
read correctly for a single entry. Data formats, source precedence, omission
acknowledgement, save/delete behavior and protocol settings are unchanged.

Profile fields now have persistent visible/accessibility labels. Recovery/deletion
and editor actions use separate rows; recent-history actions stack. Clipboard
picker labels wrap above their controls, and encoding reset uses the short shared
Use App Defaults label. Expanded profile/history screenshots pass at default size.
The new minimum fixtures exposed two real constraints problems:

- The profile view preferred 940×680 even when hosted at 900×640. Removing its
  preference entirely exposed unbounded ideal text width; the final view uses its
  900×640 minimum as its fitting preference, while the scene explicitly preserves
  the 940×680 default window. Final expanded mirrored minimum captures pass.
- AppKit reset the import window's manual minimum to (0, 28), allowing zero-sized
  content. The first generic fitting failure was followed by a zero-bitmap failure;
  exact bounds identified the cause. NSHostingController now propagates `.minSize`
  from 640×572 content, producing the intended 640×600 window here. Source content
  scrolls; review/omission acknowledgement/error and confirmation remain visible.
  Tests assert the hosted minimum survives and render choices/review at that floor.
  Resized window captures now force display before caching to avoid stale glyphs.

Validation:

- Focused native targets and final app build pass. Profile editor/isolation, recent
  history routing, import projection/transaction and import presentation/first-use:
  **4/4 (2.50 s)**. Final ordinary settings/import presentation: **2/2 (26.16 s)**.
- Expanded settings/history/profile, final mirrored minimum-size settings/profile,
  and final expanded import source/review/conflict/success/empty runs exit 0.
  The import fixture uses temporary sources and an in-memory destination; original
  fixture source preservation, stale-review rejection and cancellation/close drain
  remain checked. Native user storage and profiles are not used.
- The expansion runner includes profile/history/endpoint/source-error prefixes and
  supports `--named-output` for app-style `--verify --output DIRECTORY` fixtures.
  Import RTL, actual-user-app interaction and VoiceOver remain unaccepted.
- **645** compiled catalog values, missing-key/untranslated-language fallback and
  literal gateway/address/UInt32 line-number interpolation pass. The initial added
  bundle test reused a local variable name and failed to compile; it was renamed
  and the final check passes. Strict deep app signature, **32/32** terminal cases,
  branding baseline **1650** and diff checks pass.
- No full-suite/sanitizer rerun for this presentation-only work. Existing newer
  dependency deployment warnings remain; macOS 14, installed-app, physical and
  release acceptance are not established. No new CUA/user-app interaction claimed.

Evidence: `/tmp/tidyvnc-library-{build,model-tests,expanded,final-app,final-tests,
final-bundle,final-terminal,final-branding,final-layout-rtl}.log`,
`/tmp/tidyvnc-history-import-{minimum-diagnostic2,minimum-fixed,final-render}.log`.
Images: `/tmp/tidyvnc-library-expanded/`, `/tmp/tidyvnc-library-final-layout-rtl/`,
`/tmp/tidyvnc-history-import-final-render/`. All process handles completed.
Continue remaining menus/connection/status/listener, document/defaults-import and
controller/gateway localization. Check other host controllers with empty sizing
options for the same lost-minimum behavior. The entire unchecked plan remains;
N4.16/N4.17 and broader interactive/physical/installed/release gates stay open.


### 2026-09-22 — Defaults/listener/reverse hosted minimum sizes

New assertions reproduced the lost-minimum issue before the production change:
`NativeImport.NativePresentationAndFirstUse` and
`NativeListener.PresentationAndConnectionRouting` both failed with a content minimum
of **(0, 0)** after their hosting views completed layout. Manual `window.minSize`
assignments were being reset by an empty hosting sizing policy.

Defaults import now defines a 640×572 content floor and propagates `.minSize` from
its host. Both listener content branches define 660×472 and use the same policy.
The former manual 640×600/660×500 window minima include this host's title bar;
content dimensions are now authoritative. Tests assert those minima stay constant
through source choices, review, mapping, error, idle, incoming, stopped and reviewed
file-listen states, and capture minimum-size content. Existing import consent,
source-preservation, conflict and drain checks and listener handoff/authentication/
CLI/file-review/reconnect isolation remain in the same fixtures.

The accepted reverse-connection host in AppCoordinator now propagates its existing
ConnectionRoot 640×420 content floor. Startup listener registration relies on its
shared view floor. The app compiles/signs these paths; no new actual-app startup or
reverse-window UI inspection is claimed. Those interactive gates remain open.

Listener screenshots initially lacked their window backing color; ListenerView now
uses the native window background, and the fixture applies appearance to its host
before drawing. Final minimum idle and incoming-dark images have readable controls;
defaults mapping/review minimum images were also inspected. Scroll captures show
only visible content. No broad dark-mode/accessibility acceptance is inferred.

Validation:

- Reproduction: **0/2**, both failing solely on the new zero-minimum assertions.
- Fixed defaults presentation, defaults mapping and listener UI/model tests:
  **3/3 (4.26 s)**. After the background/capture refinement, final listener:
  **1/1 (1.30 s)**. Native target builds and final app build pass.
- Strict deep app signature, **645** catalog values/fallback/interpolation,
  **32/32** actual executable terminal cases, branding baseline **1650** and diff
  checks pass. Catalog, protocol, storage format and persistence policy unchanged.
- Full suite and sanitizers were not rerun for the view/hosting changes. Existing
  newer dependency deployment warnings remain; no macOS 14, physical, installed-app,
  actual user-window, VoiceOver or release acceptance follows.

Evidence: `/tmp/tidyvnc-window-minimum-{repro-build,repro-tests,build,tests,
render-build,final-listener,final-app,terminal,bundle,branding}.log`.
Images: `/tmp/tidyvnc-listen-ui-images/*minimum*.png`,
`build/native-ui-swift/tests/macos/{import-ui-render,defaults-mapping-ui-render}/*minimum*.png`.
All process handles completed. Continue the entire unchecked checklist, including
remaining localization and actual startup/reverse-window/accessibility acceptance.


### 2026-09-22 — Listener localization and expanded scrolling

Localized listener titles/actions/status, preparation guidance and fixed model
recovery errors. Address-family/port messages have whole-sentence catalog entries
with literal protocol/port arguments; TCP port entry syntax remains unchanged.
The catalog has **683** English source entries. Shared document review/mapping
presentation and controller-origin errors remain part of unfinished N4.16.

Network controls and Start/Stop stay above a single scrolling details area;
ViewThatFits can stack controls when needed. Peer actions use a separate row.
The TCP port field has an explicit localized accessibility name. The existing
660×472 content floor remains stable through normal and preparation states.

NativeListenerUITests now accepts `--output DIRECTORY`, so the expansion runner
can use it with `--named-output`; `listener.` is in the default expansion prefixes.
Added minimum-size invalid-port, no-family, bind-error and scrolled incoming
captures. A scroll assertion checks content overflow and a nonzero scroll offset;
visual inspection of the final dark end capture confirms both peer action rows
and the entire waiting/password/trust/history notice are visible. Light expanded
validation/bind errors and file-review viewport were also inspected. Captures show
the current viewport, not all content at once. The fixture does not implement RTL.

Validation:

- Native listener target build passes. Initial UI/model CTest **1/1 (1.62 s)**;
  final run with scrolling assertion **1/1 (1.75 s)**. Final expanded fixture passes.
  Existing real loopback admission, authentication, stopped-listener isolation,
  CLI/file launch consent, one-use credentials and shutdown assertions still run.
- Final app build and strict deep signature pass. Bundle regression verifies
  **683** values, fallbacks and interpolation, including listener ports and family
  states. Actual executable terminal cases **32/32** pass; branding baseline
  **1650** and diff checks pass.
- Expansion emits the existing temporary-app sandbox-extension diagnostic but
  exits successfully with all assertions passed. No full-suite/sanitizer rerun;
  newer dependency target warnings still prevent minimum-macOS acceptance.
- No new actual-user-app, VoiceOver, RTL, physical network/display/input,
  installed-app or release acceptance. No CUA action attempted.

Evidence: `/tmp/tidyvnc-listener-localization-{build,tests,expanded,final-build,
final-tests,final-expanded,app,bundle,terminal,branding}.log`.
Images: `/tmp/tidyvnc-listener-expanded-final/` and
`/tmp/tidyvnc-listen-ui-images/`. All process handles completed. Continue the entire
unchecked checklist; remaining localization includes shared document/defaults-import
flows, app menus/connection/status and controlled controller/gateway errors.


### 2026-09-22 — Connection-file review, mapping, export and diagnostics localization

Added 113 entries (**796** total) covering document review, file/inherited/direct
CLI display choice, exported numbering, loss review, save status and fixed
codec/reader/writer/resolution errors. Shared invocation-resolution failures and
NativeSessionDefaults document/CLI recovery text are also localized. Whole
sentences replace concatenated source labels and line annotations. The packaged
regression checks sparse Int32 monitor numbers, UInt32 line numbers and literal
percent/Unicode names, endpoints and filenames. Unknown field values remain absent
from notices; protocol strings, file serialization and stored identities are unchanged.

Review/mapping details now have a single scroller with actions outside. Display
pickers have visible wrapping labels and matching accessibility names. Document
review actions adapt between a row and column. Export mapping uses the same bounded
scroll layout within its existing 560×600 sheet. Listener preparation hosts review/
mapping directly so their confirmation actions remain visible at 660×472. Its
minimum-size assertions and existing loopback/consent/credential tests still pass.

The document mapping fixture now renders 640×420 content (matching ConnectionRoot),
including mapping errors and file/direct-CLI review. It scrolls overflowing review
content and captures the end. Export adds an invalid-number capture, width checking
and explicit light/dark host appearance. The expansion runner includes `document.`
and runs all three app fixtures via `--named-output`.

Validation:

- Initial document/listener selection: **7/8 (6.84 s)**. The new scroll assertion
  failed because ordinary English review content already fit entirely; the capture
  confirmed complete content. Changed the assertion to require a nonzero offset
  only when content overflows. Final document mapping **1/1 (2.10 s)** passes.
- Invocation resolution/monitor precedence **2/2 (0.46 s)** passes. The eight distinct
  document/listener checks have passing current evidence: codec, resolution,
  admission, live export, atomic save, display mapping, export sheet and listener.
  Their existing identity/consent/topology/private-output checks remain intact.
- Expanded document mapping/review, export mapping/loss review and listener file
  review all pass. Inspected minimum review/top/end, direct-CLI picker, error,
  export light/dark and listener file-review PNGs. English full-content fit and
  expanded scroll reachability are both covered. Captures show only the viewport.
- Final app build, strict deep signature, **796** bundle values/fallback/interpolation,
  **32/32** actual executable terminal cases, branding baseline **1650** and diff
  checks pass. Expansion emits the known temporary-app sandbox-extension diagnostic
  but exits successfully with all fixture assertions passed.
- No full-suite/sanitizer, RTL, actual-user-app, VoiceOver, physical, installed-app
  or release acceptance inferred. Newer dependency deployment warnings remain.
  No CUA action attempted. N4.16/N4.17 and the full unchecked plan remain open.

Evidence: `/tmp/tidyvnc-document-localization-{build,tests,render-build,
invocation-build,invocation-tests,final-review-tests,review-expanded,export-expanded,
listener-expanded,app,bundle,terminal,branding}.log`.
Images: `/tmp/tidyvnc-document-{review,export,listener}-expanded/`, plus native
`document-mapping-ui-render` and `export-mapping-ui-render` fixture directories.
Final screenshot review caught expanded mapping errors below the scroll boundary.
Moved the specific error (or generic unavailable-display guidance when no specific
error exists) above the action controls, with wrapped text. Added a no-connected-
displays fixture. Final expanded error and unavailable-display minimum captures
show the entire notice; final document/listener CTests pass **2/2 (4.09 s)**.
Rebuilt app/signature, **796** bundle values and **32** terminal cases pass again.
Final evidence: `/tmp/tidyvnc-document-localization-final-{layout-build,fixture-build,
layout-tests,review-expanded,app,bundle,terminal}.log`; corrected document captures
are in `/tmp/tidyvnc-document-review-expanded-final/`.

All process handles completed. Next: defaults-import, app menus/connection/status,
file panels and remaining controlled controller/gateway error localization, while
continuing all broader acceptance and release requirements.


### 2026-09-22 — Defaults-import localization and expanded presentation

Added 55 entries (**851** total) for defaults-import categories, omission meanings,
source review, consent, progress/result, first-use offer and fixed state/source
recovery messages. Whole omission rows interpolate literal field names and
localized line/notice arguments. Monitor rows reuse complete document catalog
sentences. No parser, filtering, format, source-precedence or import-policy changes.

Source selection explanations and mapping details scroll; recovery, acknowledgement
and actions stay outside. Mapping labels wrap above their pickers and have matching
accessibility names. Refresh has its own row. First-use actions sit below the offer
text. The 640×572 content minimum still propagates through the host.

Fixtures add minimum-size success, missing-source, native-state error and mapping
error renders; overflow checks/end captures cover long review details. First-use
light/dark renders use 592×160 fixture content. Appearance is applied to the hosting
view as well as the window. Initial mapping capture had a native-control transition
artifact; a 250 ms settling interval produced a clear final control label.

Validation:

- Defaults projection/commit, source discovery/review lifetime, native presentation/
  first use, history projection/transaction and defaults mapping: **5/5 (5.41 s)**.
  Source immutability, private-value exclusion, current/native precedence, stale
  identities, omission consent, topology checks and close/drain assertions remain.
- Expanded defaults import and mapping pass. Inspected source/review/end, first-use
  dark, success, existing-state recovery, mapping dark/end and final mapping-error
  minimum captures. Final mapping expansion uses the longer settling interval.
- App build and strict deep signature pass. **851** packaged values/fallback and
  interpolation checks pass, including UInt32 line limits and literal percent/
  Unicode field names in omission rows. **32/32** actual executable terminal cases,
  branding baseline **1650** and diff checks pass.
- The known temporary-app sandbox-extension diagnostic appears during expansion,
  followed by successful assertions and exit. No full-suite/sanitizer rerun.
  Newer dependency deployment warnings remain; no macOS 14, RTL, VoiceOver,
  combined connection-window, physical, installed-app or release acceptance follows.
  No CUA/user-app action was attempted. N4.16/N4.17 remain open.

Evidence: `/tmp/tidyvnc-defaults-localization-{build,tests,import-expanded,
mapping-expanded,final-fixture-build,final-mapping-expanded,app,bundle,terminal,
branding}.log`. Images: `/tmp/tidyvnc-defaults-import-expanded/`,
`/tmp/tidyvnc-defaults-mapping-expanded-final/`; ordinary images remain in native
`import-ui-render` / `defaults-mapping-ui-render` fixture directories.
All process handles completed. Continue app menus/connection/status, file panels,
remaining controlled controller/gateway errors and the full unchecked plan.


### 2026-09-22 — App menus and integrated connection localization

Added 122 entries (**973** total) for app/window/file-panel presentation, SwiftUI
and AppKit context menus, connection controls and state labels, information/
statistics and fixed app recovery messages. Complete clipboard/profile provenance,
size and speed templates preserve literal percent/Unicode arguments. Display
numbers use locale formatting; protocol versions, server values, diagnostic copy,
shortcuts, action IDs and stored/file data are unchanged.

Extracted ConnectionContent into a shared app/fixture source. The rendering fixture
uses isolated stores and a direct loopback handshake; no user credentials or tunnel
backend are invoked. First-use (both offers), gateway, idle and connected views use
640×420, information 560×650, and statistics a 296-point content width plus padding
inside a 320×300 host. Statistics retain intrinsic height as in fullscreen; no
fixed production height was introduced. The viewport helper disables host resizing,
checks proposed/actual sizes and rejects wholly blank bitmaps. Existing settings
fitting checks remain. The expansion runner supports repeatable `--renderer-arg`.

Initial unconstrained fitting checks produced oversized host images and a false
statistics-width failure. These were fixture errors, not proof of a production
minimum-size regression. Expanded first-use content motivated a compact placeholder
fallback; white text fixes its contrast on the black desktop in light appearance.
One image preview omitted layers, but rereading the same PNG showed the complete
capture; speculative visible-window/cache/warmup workarounds were removed.

Validation:

- Panning/context-menu routing, complete settings rendering and fullscreen statistics
  input/geometry/lifetime checks: **3/3 (30.16 s)** before the final placeholder fix.
  The finalized settings fixture passes **1/1 (33.57 s)**.
- Expanded connection and mirrored connection fixtures pass in both appearances.
  Final light first-use capture shows both offers/actions, address and gateway
  fields, toolbar, compact idle guidance and Ready footer within the minimum size.
  Information and statistics wrap without losing fields. Expanded fullscreen
  statistics pass visibility, input pass-through, session isolation and teardown.
- Final app build, strict deep signature, **973** packaged values/fallback/
  interpolation and **32/32** actual executable terminal cases pass. Branding
  baseline **1650** and whitespace checks pass. Retained gettext/attribution intact.
- No full-suite/sanitizer rerun. Synthetic mirrored English is not translation or
  VoiceOver acceptance. Actual menus/file panels, user-app keyboard navigation,
  physical/network/installed-app/minimum-OS/CI/performance/release gates remain open.
  The known temporary-app sandbox-extension diagnostic accompanies successful
  fixture assertions. Dependency deployment warnings remain. No CUA/user-app action.

Evidence: `/tmp/tidyvnc-app-localization-{tests,fullscreen-expanded,contrast-build,
contrast-app,final-fixture-build,contrast-expanded,complete-tests,complete-rtl,
complete-bundle,complete-terminal,branding}.log`. Final source-equivalent expanded
captures: `/tmp/tidyvnc-connection-contrast-expanded/`; mirrored captures:
`/tmp/tidyvnc-connection-complete-rtl/`. The extra warmup in
`/tmp/tidyvnc-connection-accepted-expanded/` was later removed; its reread first-use
PNG also shows the final production layout. Ordinary captures are in settings-render.

All recorded process handles completed. Continue remaining controller/gateway/status
localization and every unchecked item.


### 2026-09-22 — Localized controller/service recovery and desktop accessibility

Added 36 catalog entries (**1009** total) for fixed connection-controller, tunnel,
clipboard, fullscreen transition/automatic resize and desktop keyboard/scaling
recovery. Desktop label/help and focus accessibility actions use catalog values.
The fullscreen failure sentence preserves its diagnostic as a literal argument.
No typed error, SSH parsing/argv, clipboard route, selector, input policy, stored
identity, protocol value or secret-handling behavior changed. Existing catalog
ordering is preserved; only new keys are appended.

Validation:

- **11/11 normal (60.41 s)**: panning/AX dispatch, clipboard wire/routing, full settings
  rendering, shortcut capture lifetime, connection errors/retry, automatic resizing,
  fullscreen ownership/presentation/remote-layout and tunnel service/controller
  lifetime. Existing private-process, wire, redaction and teardown assertions pass.
- Expanded native panning/menu/AX dispatch, clipboard recovery and fullscreen
  transition tests pass. They now use localized expected presentation values,
  retaining actual selector invocation, edge gating, wire/focus isolation, recovery
  and cleanup checks. These are fixtures, not user-operated VoiceOver acceptance.
- App build and strict deep signature pass. **1009** packaged values/fallback/
  interpolation checks pass, including literal percent/Unicode diagnostics.
  **32/32** executable terminal cases, branding **1650** and diff checks pass.
- No full-suite/sanitizer or actual installed/user-app check. Dependency deployment
  warnings remain. The temporary expansion bundle's sandbox-extension diagnostic
  is followed by successful assertions and exit. All process handles completed.

Evidence: `/tmp/tidyvnc-service-localization-{build,app,tests,panning-expanded,
clipboard-expanded,fullscreen-expanded,bundle,terminal,branding}.log`.
No new view layout is introduced in this checkpoint.

Source audit next: native launch/CLI guidance and initialization failures, Keychain
localized access reasons, and remaining generic diagnostic presentation paths.
Several other raw strings are caught internal diagnostics or protocol/persisted
metadata (configuration header, trust commitment, credential labels); classify
those by use before translating. N4.16 and all other unchecked requirements remain.


### 2026-09-22 — Native CLI and Keychain presentation localization

Added 28 entries (**1037** total) for syntax/initialization/launch-credential errors,
version/help prose, usage/alias/default/unavailable/value annotations, Keychain
access reasons and newly created item labels. Complete templates take literal
command syntax, aliases/defaults, paths and environment names. Syntax argument
numbers use the existing localized argument/message template. No lexer, argv,
precedence, startup ordering, error code, credential identity or access policy
changed; replacing an existing credential does not rewrite its stored label.

Validation:

- Syntax/catalog, strict bootstrap/connection, Keychain store policy/lifetime and
  both launch credential tests: **5/5 (1.60 s)**. Existing strict UTF-8/bounds,
  redaction, file/socket classification, one-shot/first-window ownership, wire,
  scoped queries, cancellation and secret disposal assertions remain.
- Expanded bootstrap and Keychain fixtures pass. Help tests check literal syntax
  examples and aliases with localized annotations. Mock SecItem calls verify the
  localized LAContext reason and new-item label alongside stable account/service
  scope and interaction/access policy. No real Keychain prompt is invoked.
- App build and strict deep signature pass. English help (**3711 bytes**) and
  version (**108 bytes**) are byte-identical to the pre-change app, including exit
  statuses; isolated HOME/XDG remains empty. All **32/32** terminal cases pass.
- **1037** packaged values, fallback and interpolation checks pass, including literal
  percent/Unicode arguments in alias/default/usage templates. Branding **1650** and
  whitespace checks pass. No full-suite/sanitizer or installed/minimum-OS/VoiceOver
  acceptance. Existing dependency warnings remain. All process handles completed.

Evidence: `/tmp/tidyvnc-cli-localization-{build,app,tests,bootstrap-expanded,
keychain-expanded,bundle,terminal,english-comparison}.log`; pre-change English
bytes: `/tmp/tidyvnc-cli-localization-baseline-{help,version}.txt`.

Next audit findings: TidyVNCApp startup and NativeDesktopView/Canvas report raw
String(describing:) failures, including renderer/cursor/input paths; fullscreen
failure detail interpolates one. Map these safely and retain actionable recovery.
Native Info.plist privacy/document-type descriptions need review too. Do not
translate compatibility file headers, persisted trust commitments or internal
exceptions blindly. N4.16/N4.17 and every other unchecked requirement remain open.


### 2026-09-22 — Structured, redacted startup and desktop recovery

Added NativePresentationIssue, selected only by typed error/status and operation
context. Startup distinguishes preferences, incompatible components and resources;
desktop drawing, cursor fallback, layout, input admission, shortcuts, capture,
fullscreen and commands have appropriate fixed recovery. Unknown errors receive
operation-specific text without evaluating descriptions or NSError userInfo.
All raw String(describing:) error callbacks in the app/desktop paths found by the
audit now use this mapping. Existing suppression, focus and lifetime guards remain.

Keyboard capture denial now throws NativeDesktopCommandIssue.keyboardCaptureUnavailable
so both shortcut and menu paths preserve Accessibility guidance without parsing
message text. No C ABI, protocol, persistence or input/cancellation policy changed.
The obsolete arbitrary-fullscreen-diagnostic template was removed; 14 new entries
bring the catalog from 1037 to **1050**. No arbitrary diagnostic argument is added
to these UI messages, while fullscreen still rethrows its original failure.

Validation:

- New injected-failure fixture verifies operation/status mapping, a hostile Error
  whose description must never be evaluated, private NSError/native details,
  renderer alert coalescing and later-frame recovery, local cursor fallback,
  unchanged geometry after invalid canvas intent and renderer drain on close.
- Fullscreen failure injection verifies foreign-error redaction and resource/window
  rollback. Shortcut fixture verifies explicit typed capture denial and localized
  recovery, alongside the existing no-per-frame-retry and focus-release checks.
- A fixture-only ambiguous infinity literal was fixed to CGFloat.infinity. Final
  affected rendering/cursor/input/canvas/fullscreen/connection tests pass **9/9
  (5.13 s)**. Expanded recovery and fullscreen behavior fixtures also pass.
- After rebuilding all native targets, the complete native suite passes **86/86
  (116.31 s)**, including isolated SSH fixtures. The first full run passed 85/86
  and found the SSH identity sheet exceeded its 570-point fixture by 0.5 point.
  The sheet now has one bounded details scroll area with title/actions outside;
  action rows adapt vertically if needed. The fixture disables automatic host
  sizing, checks actual 460×570 bounds and complete scroll reachability. Expanded
  and mirrored renders pass; representative light/dark images were inspected. No skipped tests are claimed as
  acceptance. ASan/TSan were not rerun for this presentation-only change.
- App build, strict deep signature, **1050** packaged values/fallback/interpolation,
  **32/32** executable terminal cases, branding baseline **1650** and diff checks pass.
  Newer dependency deployment warnings remain; this does not prove the macOS 14 floor.
- Fresh CUA app selection fails with the native-pipe error. No follow-up action or
  actual app/VoiceOver acceptance; no app crash or old-draft state is inferred.

Evidence: `/tmp/tidyvnc-presentation-issues-{fixed-build,tests,expanded,
fullscreen-expanded,full-build,full-tests,app,bundle,terminal,branding}.log`.
Final follow-up evidence: `/tmp/tidyvnc-presentation-issues-ssh-{build,expanded,rtl}.log`
and `/tmp/tidyvnc-presentation-issues-{full-tests,app,bundle,terminal,branding}-final.log`.
Expanded SSH images: `/tmp/tidyvnc-ssh-presentation-{expanded,rtl}/`.
The earlier full-tests log retains the 85/86 failure; use the final log for acceptance.
All recorded build/test handles completed. Next: native bundle privacy/document-type
localization review, use-based classification of remaining literals and all unchecked
interactive, parity, physical, installed, CI, performance and release requirements.


### 2026-09-22 — Bundle metadata and complete trust identity messages

Added a native-only InfoPlist.xcstrings resource with **2** entries. Local Network
purpose uses its system key; document display name uses the exact CFBundleTypeName
value as its lookup key. Identity, extension/role/rank registration, copyright and
the shared release template are preserved. The existing packaging test now checks
compiled InfoPlist values, localizedInfoDictionary, object(forInfoDictionaryKey:),
untranslated-language fallback and equality with authoritative release metadata.
This proves bundle lookup, not actual Finder or Local Network prompt acceptance.

The remaining literal audit identified trust UI assembled from English fragments.
NativeLegacyTrustIdentity now stores typed SPKI fingerprints or algorithm/digest
commitments. Matching, duplicate elimination, maximum returned identities and record
parsing use these values independently of localization. Expected identity and saved
certificate/server-key labels use complete messages. Three catalog entries replace
two fragment entries: **1051 UI entries**, plus the separate **2 metadata entries**.
No C ABI, persisted schema, scope, fingerprint algorithm or trust decision changed.

Validation:

- Affected trust policy, legacy decisions, scoped persistence/recovery, host-key
  policy and native settings rendering: **5/5 (33.92 s)**.
- Expanded legacy-policy executable passes mixed/duplicate commitment/SPKI matching,
  literal fingerprint presentation, strict codec/file limits and stale/cancel/drain
  behavior. Expanded trust/settings rendering passes. Representative changed-key
  (SPKI plus commitment), certificate-library and dark server-key-library images
  were inspected; complete messages and fingerprints wrap inside their content.
- Final app build and strict deep signature pass. Packaged tests verify **1051 + 2**
  values, fallback, unchanged metadata and literal percent/Unicode fingerprints
  and a UInt32.max algorithm identifier. **32/32** terminal cases, branding baseline
  **1650** and whitespace checks pass. No fresh full suite or ASan/TSan run: the
  preceding 86/86 result is from the previous structured-recovery checkpoint.
- Newer Homebrew deployment warnings remain; no macOS 14 compatibility is inferred.
- Fresh CUA full-path app selection fails at the native pipe. No follow-up UI action
  was sent and no app/version/draft state inferred. Actual Finder/privacy/keyboard/
  VoiceOver and installed behavior remain open.

Evidence: `/tmp/tidyvnc-bundle-localization-{trust-build,render-build,app-final,
check-final,tests,trust-expanded,expanded-renders,terminal,branding}.log`.
Images: `/tmp/tidyvnc-bundle-trust-renders/`. All recorded process handles completed.
Next: finish use-based dynamic presentation coverage and interactive acceptance;
all unchecked parity/core/services/physical/deployment/CI/performance/release items
remain in scope. N4.16 and N4.17 are not complete.


### 2026-09-22 — Compiler-derived localization build gate

Enabled Swift localization extraction for TidyVNCNative and the Xcode app. Each
CMake target writes its current Swift source manifest. apps/macos/build.py invokes
tests/macos/localization-source.py after Xcode succeeds. The gate requires current
compiler records for every listed source and checks each extracted key's English
default, including compiler-selected interpolation types, against the catalog.
It rejects missing keys, unused entries, stale/missing records, and unexpected
record formats or tables. Records from removed sources and generated App Shortcuts
metadata are ignored; they cannot satisfy a current source. Some synthesized
expressions lack source positions, so those still validate by source/key/value.

The first audit found one orphan (`settings.inheritance.value`) plus implicit
translation keys for TidyVNC, IPv4/IPv6, 5500, monitor numbers and empty field titles.
The orphan was removed (**1050 Localizable**, plus **2 InfoPlist**). Product/protocol/
placeholder values use verbatim Text; monitor labels use locale-formatted numbers.
Empty placeholder titles carry no text to translate and are excluded by the gate;
the affected fields retain explicit localized accessibility labels. No dialog
semantics, persisted values, network routing or credentials changed.

Validation:

- Final standard app build automatically passes **139 Swift sources, 1350 call
  sites, 1050 keys**, with complete current compiler records and matching defaults.
- **13** deterministic checker tests cover valid coverage, missing keys/records,
  stale records, same-basename wrong source, wrong interpolation type, orphan keys,
  empty manifests/titles, missing synthesized locations, implicit literal keys,
  unsupported tables/formats and ignored generated/removed-source records.
- Integrated checker plus affected native settings/listener/fullscreen tests pass
  **4/4 (38.59 s)**. The registered native suite now has **87** tests. No fresh
  full-suite or sanitizer run; the prior full 86/86 checkpoint remains historical.
- Final packaged lookup/fallback/interpolation checks pass **1050 + 2** values;
  app strict deep signature, **32/32** terminal cases, branding baseline **1650**,
  Python compilation and diff checks pass. Dependency deployment warnings remain.
- No new CUA action or actual-app/VoiceOver/physical acceptance is claimed. Latest
  CUA failure remains the preceding bundle/trust checkpoint.

Evidence: `/tmp/tidyvnc-localization-extraction-{final-build,audit-initial,unit,
native-build,fullscreen-build,tests,bundle,terminal,branding}.log`.
This gate verifies calls recognized by Swift localization APIs. It does not prove
that arbitrary dynamic Strings are localized, that all translated layouts fit, or
that OS panels and keyboard/VoiceOver behavior work. Continue those acceptance
requirements and the entire unchecked plan. All recorded process handles completed.

Post-test visual check: fullscreen-settings-render/selected.png and
/tmp/tidyvnc-listen-ui-images/idle-minimum.png were inspected. Display numbers and
the listener port/IP labels fit; this is fixture evidence, not user-app acceptance.


### 2026-09-22 — Dynamic encoding reset names and accessibility limitation

EncodingSettingsFields previously inserted core schema tokens into reset names,
including NoJPEG for the visible Allow JPEG control. All eight reset controls now
receive the same localized label as their visible field; help and accessibility
names use the complete existing inheritance template. Each has a stable ID based
on the typed option's raw value. Callback identity, inversion, enablement, inherited
source and persistence semantics are unchanged. No catalog entries were added.

An experimental isolated NSHostingView fixture could not observe SwiftUI children
through accessibilityChildren(), including after presenting an off-desktop window
and checking a non-prohibited application policy. It never reached activation.
Initial compile errors came from using NSAccessibility instead of Swift's imported
NSAccessibilityProtocol. The exploratory test and CMake target were removed rather
than counted as coverage. This does not prove that the user app lacks accessible
controls. No user-app action, saved preference, credential or trust operation was
performed. Actual VoiceOver naming/activation remains required.

Validation: existing profile editor/inheritance, encoding draft/session isolation
and settings rendering pass **3/3 (35.78 s)**. Expanded settings/profile rendering
also passes. Standard app build checks **139 sources / 1351 call sites / 1050 UI
keys**, and packaged checks pass **1050 + 2** entries with fallback/interpolation.
Strict signature, **32/32** terminal cases, branding baseline **1650** and diff
checks pass. No fresh full-suite or sanitizer run; 87 tests remain registered.
Deployment dependency warnings and all unaccepted plan requirements remain.

Evidence: `/tmp/tidyvnc-encoding-accessibility-{app,render-build,model-build,
tests,expanded,bundle,terminal,branding}.log`. Unsupported AX experiment:
`/tmp/tidyvnc-encoding-accessibility-unavailable-fixture.swift` and
`/tmp/tidyvnc-encoding-accessibility-probe{,2,3}.log` (no passing AX evidence).
All recorded process handles completed. Continue dynamic provenance, actual
keyboard/VoiceOver acceptance and the entire unchecked plan.

### 2026-09-22 — N6.1/N6.3 frontend selection and dependency boundary

This checkpoint adds the explicit FLTK/SWIFTUI selector, shared root/script native
build, generated core configuration handoff and FLTK-only test/benchmark guards.
FLTK remains the default. App/core SDK/architecture/floor mismatches are rejected
before compiler probing; the Xcode project offers only the core configuration.
See [BUILD.md](BUILD.md) and [BUILD-MACOS](../../BUILD-MACOS.md) for code mapping,
commands, output directories and supported configuration constraints.

Clean Debug native build/compiler audit passes (139 sources / 1351 sites / 1050
keys), as do direct root `macapp` and smoke targets. File API audits cover 168 core
and 3 app targets with no FLTK inputs. Five policy-test groups and ten actual
configure rejection checks pass. Clean headless graph/build passes 3/3 viewer
tests and **756/756** unit tests (21.43 s). Retained FLTK viewer/fbperf/surface/
viewerstate build and **19/19** affected tests pass (0.32 s). Final selected bundle
passes **1050 + 2** localized values, strict signing and **32** CLI cases.

Logs: `/tmp/tidyvnc-frontend-{app,root-target,root-final,headless,fltk,fltk-tests,
graph,smoke,configurations-verified,bundle-final,terminal-final,branding-final}.log`.
Initial negative-test logs record a system diagnostic expectation mismatch and
SDK compiler probing before the handoff check; the verified run supersedes them.
The branding audit found an existing unlisted absolute checkout path in an earlier
UI acceptance note; making that reference repository-relative restores the audit
without changing its observation or the **1650** deferred branding baseline.

N6.1/N6.3 are complete; N6.2's full test/package automation, distribution
dependencies, native CI and other-platform builds remain open. No full 87-test
native suite, sanitizers, Intel/minimum-OS execution, UI/VoiceOver or installed
privacy/Keychain acceptance is claimed. Host dylibs still require macOS 26/27;
the declared 14.0 floor remains provisional. All process handles completed, and
the entire original plan remains the goal.

### Native verification/CI definition, SSH exit and localization receipts — 2026-09-22

Commit: `fix(macos): harden SSH completion and automate native validation`.

`build.py --test --parallel 2` now requires GoogleTest, builds all native/core
executables and runs `verify-build.py`. Every run gets a fresh directory, saved
commands/status, discovered CTest inventories and JUnit. Empty/missing/skipped/
failed or mismatched coverage fails, preserving duplicate pretty-name counts.
The driver checks graphs, ten configure failures, packaged localization, strict
signature and the real app CLI. Nine verifier regressions pass. The five-job CI
matrix records dependencies/toolchains and preserves development artifacts;
workflow YAML and all four shell steps parse. No hosted run was dispatched.

An initial verifier incorrectly rejected two distinct parameterized GoogleTests
with identical pretty names. Counter-based matching fixes this without dropping
multiplicity. Report `run-g6r34__1` records that failure despite passing actual
3/756/88 suites. The next report `run-f_dttci7` correctly fails native coverage
87/88 on intermittent real ECDSA startup. Diagnostic repetition and a deterministic
fixture identified NOTE_EXIT preceding waitable child state on Darwin. The process
owner now coalesces 10 ms retries only after exit notification, retaining WNOWAIT
and the lock until descendant termination/reap. The old implementation fails
`early exit notification lost before waitid became ready`; the corrected version
passes. Lifecycle and real ECDSA each pass **20 repetitions** (152.73 s total).
ASan and TSan each pass the isolated regression and full lifecycle fixture
(**1/1, 3.29 s** and **1/1, 7.63 s**). These are targeted sanitizer checks.

A subsequent app rebuild succeeded, but the compiler catalog gate rejected an
unchanged `.stringsdata` timestamp. Swift intentionally preserves that timestamp.
Core/app POST_BUILD now records source and compiler-record SHA256 values, and the
audit requires matching completed receipts plus all existing coverage/default/
interpolation checks. Sixteen checker regressions pass, including changed-source,
changed-record, absent-receipt and old-but-valid unchanged-record cases. The actual
final build accepts the unchanged older record with a valid completed receipt.
Bridge-only builds now also require Python for receipt generation.

Final command: `python3 apps/macos/build.py --build-dir build/native-ui-frontend
--parallel 2 --test`. All-target build and compiler audit pass (**139 Swift
sources / 1351 sites / 1050 keys**). Final report
`build/native-ui-frontend/verification/run-yhdlyz2o/summary.json` is **passed**:
**3/3 viewer, 756/756 unit (21.81 s), 88/88 native (129.47 s)**; **168 core / 3 app**
FLTK-free graphs; **10** configure rejections; **1050 + 2** packaged values;
strict signature and **32** terminal cases. App executable SHA256:
`79c6d0b57af080ef2256f70e893069cc664fded1a429ca4da10f60e3f9bb098a`.
Normal host is arm64 macOS 27, Xcode/SDK 27, Debug, NLS/audio/H.264 off and
GnuTLS/nettle on. Branding baseline **1650** and diff checks pass.

Logs: `/tmp/tidyvnc-verify-build-receipts.log` (final),
`/tmp/tidyvnc-verify-exit-fix-repeat.log`, `/tmp/tidyvnc-verify-early-exit-{before,after}.log`,
`/tmp/tidyvnc-verify-exit-{asan,tsan}{,-build,-lifecycle}.log`. Earlier
`verify-build`, `verify-build-final` and `verify-build-validated` logs record the
superseded checker, real SSH, and mtime failures respectively. All handles ended.
No actual-user-app action, hosted CI, minimum-OS/Intel/Release execution, full
sanitizer/protocol feature matrix, physical/VoiceOver, installed privacy/Keychain
or distribution acceptance is inferred. N6.2 packaging, N6.4 execution and the
remaining original plan stay open. FLTK remains the default.

### N0.1/N0.2 — source parity and compiled capabilities — 2026-09-22

Commit: `docs(native-ui): map parity controls and compiled capabilities`.

Created PARITY.md with **162** control/action/launch rows covering every PLAN §9
row, all eight scaling modes, settings/credential/trust/profile/document/import
flows, active-session menus, shortcuts, listeners/tunnels and global UI acceptance.
Rows map retained source, native replacement, registered evidence and concrete
remaining acceptance actions. CAPABILITIES.md records **47 canonical parameters**,
**three aliases**, defaults/ranges, compiled feature gates and change lifetime.
Intentional default/compatibility differences remain visible and require final
acceptance; inventory completion does not complete any UI/physical/release gate.

Source checkpoint is `6d69ccb5`; no production code changed. A temporary C++ probe
linked with the existing encodingoptions target dependencies queried actual built
encoding/security/invocation catalogs. Result: Tight/JPEG/ZRLE/Hextile/Raw available,
H.264 unavailable, all 15 security leaf methods available and exact default order
recorded. Current native config is Debug arm64/macOS SDK 27, GnuTLS/nettle on and
NLS/audio/H.264 off. Native help has all 47 catalog parameters; retained FLTK help
has the 43 macOS-available canonical names plus three aliases (46 spellings).
Help's exit 1 is expected. No connection/credential/store access occurs.

Both actual `-AlertOnFatalError=off` and `=on` launches exit 1 with the native
unsupported-adapter diagnostic. The retained mainloop demonstrates reconnect
prompts take precedence for ordinary outgoing failures even with alerting off;
fatal/non-retry/reverse failures consult alerting. This determines the next
implementation work and is an explicit unchecked N4.11 subitem. Corrected CLI.md's
stale statement that the now-implemented tunnel adapter was absent.

Checks pass: all relative document links, registered test references, unique row
IDs and every §9 coverage range; complete parameter/canonical/alias comparison;
branding baseline **1650** and `git diff --check`. Logs:
`/tmp/tidyvnc-parity-capabilities.log`, `/tmp/tidyvnc-parity-{native,fltk}-help.log`,
`/tmp/tidyvnc-parity-inventory-check.log`; temporary probe source is
`/tmp/tidyvnc-parity-capabilities.cxx`. All handles completed. No new tests or full
build/suite rerun was needed for this documentation-only change. Latest full
pipeline remains **3 viewer / 756 core / 88 native** from the preceding checkpoint.
No actual UI, physical/VoiceOver, protocol-matrix, CI or installed/distribution
acceptance is inferred. Full original goal remains active with FLTK default.

### N4.11 scoped failure alert policy (2026-09-22)

`AlertOnFatalError` now has a native adapter, defaults on, and is captured in an
immutable launch/session value. Eligible outgoing errors still offer Retry when
ReconnectOnError is on. With alerts off, fatal/non-retry connection and listener
failures request joined owner cleanup, then the app coordinator closes that
window. Reverse failure preserves the accepting listener; unrelated sessions and
the macOS application remain open, including after the last window closes. This
native lifetime adaptation is documented in CLI help; actual window acceptance
remains open. Cancellation, editable validation and credential/trust decisions
retain their existing behavior. See [CONNECTION.md](CONNECTION.md).

Every CLI occurrence is validated; the last valid value wins. Compatibility-file
fields cannot override it and still require ignored-field review. Export review
now explicitly acknowledges that failure-alert policy is omitted. Two localized
messages bring coverage to **139 sources / 1353 call sites / 1052 UI keys**, plus
**2 InfoPlist** entries. The new export-review fixture images were inspected.

The all-target build and first full verification passed (`run-u2u4a5tm`). Review
then added a missing-preferences listener startup case and an explicit initializer
policy check; the final incremental build and full verification passed in
`build/native-ui-frontend/verification/run-bl32lpk7/summary.json`: **3/3 viewer,
756/756 unit (21.50 s), 88/88 native (117.29 s)**, graph checks **168/3**, **10**
configure rejection cases, **1052 + 2** packaged values, strict development
signature and **36** actual executable CLI cases. Real socket fixtures cover all
four alert/retry combinations, healthy-session isolation, cancelled authentication,
bind failure, pre-session failure and reverse-peer loss. The first focused run
caught a fixture missing the required ignored-file-field acknowledgment; correcting
that fixture preserved the production review gate. No sanitizer rerun is claimed.

N4.11 implementation evidence is updated; actual window/keyboard/VoiceOver,
physical/protocol/performance, installed services, minimum-OS/Intel, hosted CI and
distribution gates remain open. The complete original goal remains active and
FLTK remains the shipping default. All build/test handles completed.

### N6.2 / N6.7 native dependency assembly and disk image (2026-09-22)

The native build now has `native-package`/`dmg` targets and `build.py --package`.
One packager recursively copies non-system dylibs, rewrites their load paths,
removes runpaths, checks architecture/deployment floors and preserves dependency
notices. It signs nested binaries before the app seal, audits closure, executes
help from a moved path with spaces and atomically publishes a fresh output.
The reusable inspector checks the actual read-only mounted image and detaches it.
See [PACKAGING.md](PACKAGING.md) for commands, supported scope and limits.

The current Homebrew libraries correctly fail a 14.0 package declaration: nettle
requires macOS 27. Local inspection packages explicitly declare **27.0**, preserving
the original Xcode app's 14.0 declaration and leaving the supported-floor decision
open. This is a dependency portability improvement, not minimum-OS acceptance.
The package contains **13 signed binaries / 11 bundled dylibs**, upstream notices,
resources and an Applications link. No production identity or notarization is used.

Direct `dmg` target and the complete `build.py --test --package` pipeline pass.
Final verification `build/native-ui-frontend/verification/run-mi4r1bps/summary.json`
passes **3/3 viewer, 756/756 unit (21.93 s), 89/89 native (129.43 s)**, graph checks
**170/3**, **10** configure rejection cases, **1052 + 2** packaged localization
values, strict signature and **36** CLI cases. Compiler coverage stays
**139 sources / 1353 call sites**. The new native CTest contains **13** package
policy/failure regressions. Workflow YAML/shell parsing, branding **1650** and diff
checks pass. No sanitizer rerun is claimed for this packaging change.

Final artifact: `build/native-package-pipeline/TidyVNC-1.16.80-arm64.dmg`, SHA-256
`5ce0805d95e166cd644e9df280eca4fde584782fc253e5faa10e75fb9447fc4b`.
`package-report.json` in the same directory records hashes, dependency edges,
minimums and signing mode. The final mounted image passes binary/resource/notice/
identity/signature/symbol checks plus all **36** real CLI cases, then detaches.
No temporary packaging stage remains. All process handles completed.

Native CI now defines host-floor package assembly and mounted-image inspection;
its execution remains unverified. Next: clean Release and supported dependency/
minimum-OS/Intel packages, intended signing identity and installed privacy/Keychain,
plus every remaining interaction, protocol, physical/performance and parity gate.
N6.2's local assembly subitem is complete; parent/distribution acceptance stays
open. The complete original goal remains active. FLTK stays the shipping default.

### N6.2 / N6.5 clean Release build, fixture synchronization and package proof (2026-09-22)

Started from a nonexistent `build/native-release-validation` directory and built
all core, app and test targets with `--configuration Release --test --package`.
The generated handoff and Xcode configuration are Release-only, arm64, SDK 27,
build deployment declaration 14.0. C++ uses `-O3` with the root's existing
`-UNDEBUG` assertion policy; Swift uses `-O`. The package explicitly declares
27.0 for the current Homebrew dependency floors. No production code changed.

The first full report (`run-85kkqfoe`) caught a clipboard-limit wire-fixture race:
an initial-frame publication could satisfy a generic frame-sequence wait before
the clipboard message was sent, leaving the fixture queue occupied. It reproduced
immediately in isolation. The test now checks the exact pixel marker following
each clipboard message, including messages that must be discarded, rather than
any newer frame. Existing admission, boundary, retention, reconnect and isolation
assertions remain. The corrected test passes **30 Release + 30 Debug** repetitions.

The final complete pipeline passes in
`build/native-release-validation/verification/run-mu47vmxj/summary.json`:
**3/3 viewer, 756/756 unit (21.87 s), 89/89 native (124.63 s)**, graph **170/3**,
**10** configure rejection checks, **1052 UI + 2 metadata** localized values,
strict signature and **36** CLI cases. Compiler audit remains **139 sources /
1353 call sites**. No sanitizer rerun is claimed for this fixture-only change.

Release artifact:
`build/native-release-validation/package/Release/TidyVNC-1.16.80-arm64.dmg`, SHA-256
`31684912587385f21ce9eeb21a5c7a376aed0cba241f805926d656151e9fdf6b`.
The mounted read-only image passes all **36** CLI cases plus identity/resources/
notices, closed dependency graph, symbol and strict signature checks. It contains
**13 signed binaries / 11 bundled dylibs** and is detached after inspection.
The adjacent `package-report.json` preserves hashes and minimums. All process
handles completed; branding **1650** and diff checks pass.

The CUA access check still could not inspect the actual app; see UI-ACCEPTANCE.md.
No interactive acceptance is inferred. The 55-case protocol harness still has
FLTK-specific log and process-lifetime assertions and needs a native adapter
before it can establish native baseline coverage. Next: that full native protocol
baseline, supported minimum-OS/Intel dependency packages and intended signing /
installed behavior, plus all remaining service/interaction/physical/performance
and parity gates. The complete original goal stays active; FLTK stays the default.

### N6.5 / N4.11 actual native protocol baseline and AppKit startup (2026-09-23)

The full retained **55-case** baseline now runs through the actual native app with
isolated Foundation paths, unique app/preference domains and a signed temporary
copy. All wire assertions remain: fragmented updates, framebuffer/cursor changes,
scaling suppression, explicit 123×97 size, measured automatic logical/device size
and bounded denial retries. Native peer-close/socket drain is checked separately
from fixture SIGTERM cleanup. It does not establish pixels/input, window dismissal
or interactive app Quit. See [PROTOCOL.md](PROTOCOL.md).

This exposed an actual startup defect: AppKit treated the endpoint operand as a
file and suppressed the scene that consumes the parsed invocation. The entry
point now disables that duplicate interpretation in the volatile argument domain
before SwiftUI starts, without persistent preference or argv changes. The
first-window/file-review fixtures now supply real process operands and use the
same handoff. Their simplified app did not independently reproduce the failure;
the actual-app timeout traces and passing full matrix are the before/after proof.
All temporary startup traces were removed.

An additive numeric-only viewport diagnostic uses the existing redacted debug
route; the C header now has **113 status-returning exports**. Pure-C boundary and
redaction/route checks pass. The ordinary preferences domain is unchanged, while
alternate bundle identities get separate domains. A Foundation probe verifies
HOME/Application Support before each fixture launch; cleanup accepts only exact
UUID-suffixed fixture domains. HOME alone did not isolate CFPreferences.

Final all-target Debug verification:
`build/native-ui-frontend/verification/run-1hqziv5q/summary.json` —
**3/3 viewer, 756/756 unit (21.70 s), 89/89 native (129.15 s)**, graph **170/3**,
**10** configure checks, **1052 + 2** bundled localized values, strict signature
and **36** actual CLI cases. Compiler coverage remains **139 sources / 1353 call
sites**. Focused logging plus pure-C ABI checks pass **11/11 ASan+UBSan** and
**11/11 TSan**; those existing builds disable crypto and retain uninstrumented
system/dependency libraries. This is not a full sanitizer-matrix claim.

Final reports `build/native-protocol-final/summary.json` and
`build/fltk-protocol-final/summary.json` both pass **55/55**, with hashes checked
against the tested executables. Native SHA-256:
`244ea6912a4b5309699fa43b9ece7976f0d071a81e15c61d93db20c40e3b86bf`.
Native measured/wire sizes are 960×525 logical and 1920×1050 device; both explicit
cases send 123×97 and scaled automatic cases send nothing. These dimensions are
observations of this run, not hardcoded acceptance values. The CI definition now
runs/preserves this baseline; hosted execution is still unverified. Workflow
YAML/shell parsing, branding **1650** and diff checks pass. All process handles
completed. This change has not rebuilt the earlier Release DMG.

N6.5's baseline subitem is complete; its broader protocol/sanitizer gate remains
open. Next: remaining contract/global-state audits and broader protocol evidence,
actual interaction/accessibility, physical/performance, supported minimum-OS/Intel,
installed services/signing, hosted CI and final parity/cutover. The full original
goal stays active; FLTK remains the shipping default.

### N6.5 / N1.6 / N1.4 / N1.14 Release revalidation, Linux resolver and full sanitizers (2026-09-23)

**Release at the implementation commit.** Built `8b56c793` into the existing
`build/native-release-validation` tree (`--configuration Release --test --package
--package-minimum-os 27.0`); the compile phase finished before any later source
edit (object timestamps checked). `verification/run-tia1q75j/summary.json` passes
**3/3 viewer, 756/756 unit, 89/89 native** plus graph, configuration, localization,
signature and CLI stages. New package `build/native-release-8b56c793`: DMG SHA-256
`ac238bdcee5e11972bc7ae014e79ae7e7d9b246e6674347d15ba4f86ce9be54a`, packaged
executable `4a4177e336d26d8546dc36a8e9996556dcbee454bd272d4c8a30fdcecac998c8`.
Mounted read-only inspection passes (13 binaries, 11 bundled libraries, closed
dependencies, notices, identity, strict signature, symbols, 36 CLI cases) and
detaches. The 55-case baseline against that packaged executable passes **55/55**
(`build/native-protocol-release-8b56c793/summary.json`, hash matches). The package
floor is still the explicit 27.0 host-dependency floor, not minimum-OS proof.

**Linux hostname lookup (N1.6).** glibc `getaddrinfo_a` with a `SIGEV_THREAD`
notification that signals a pipe polled beside the cancellation wake. The request
and its buffers are shared with the notification; `gai_cancel == EAI_CANCELED`
means no notification follows and the worker releases it. Deadline/cancellation
return immediately without joining or detaching a viewer thread. CMake detects libc
or libanl; non-glibc remains Unsupported. New tests: localhost and single-family
resolution, 64-iteration cancellation race (typed result, listener drained), plus a
manual `stalledlookup` executable (not a CTest case, as verify-build rejects skips).
With nameserver 192.0.2.1 the stalled check passes in 412–420 ms (plain and ASan).

**Linux sanitizers (N6.5 subitem).** Ubuntu 24.04 aarch64 (Podman VM), GCC 13.3,
GnuTLS 3.8.3. Debug adds `-Werror`, which first exposed GCC-only warnings (shadowing,
misleading indentation, dangling else, ignored `fclose` attributes), all fixed.
The first full ASan+UBSan+LSan run found and fixed an upstream TLS description leak
(client and server), null-pointer `memcpy` UB (`Cursor`, `InStream::readBytes`,
`BinaryParameter::getData`) and a test-only nothrow `operator new` mismatch.
TSan cannot instrument glibc's internally created lookup threads (crash in its
allocator); only those three resolver tests skip under TSan, with the reason in code.
Final: Release headless script (graph audit) **3/3 + 759/759**; ASan+UBSan+LSan
**3/3 + 759/759**; TSan **3/3 + 759/759** (3 skips); zero compiler warnings.
`.github/workflows/headless.yml` now defines both Linux sanitizer jobs (with the
runner ASLR adjustment TSan needs on x86_64); hosted execution is unverified.

**Global state (N1.4) and randomness.** STATE-AUDIT.md now reconciles every N0.3 row.
GnuTLS global init/deinit is safe under the ≥ 3.3 reference-counted lifetime; the
native core `static_assert`s that floor and
`ClientTLS.GlobalLifetimeChurnDoesNotDisturbActiveHandshakes` churns security
objects during handshakes. Client key exchange now uses
`RandomStream(RequireSystem)`, which fails closed instead of seeding the shared
`rand()` fallback. In a privileged container with `/dev` hidden, strict mode throws
and legacy (server) mode proceeds. Server behavior is unchanged.

**Two-session isolation (N1.14).**
`SessionWorker.SimultaneousSessionsIsolatePromptSecretInputClipboardAndSettings`:
a VncAuth session parked at its prompt (QualityLevel 2) and a None session that
receives a frame, holds Control_L, sends clipboard text and changes QualityLevel
to 9. The parked transcript stays empty and its settings unchanged; the live
session cannot take or answer the parked prompt. After the reply the parked
transcript is exactly version, selection and a 16-byte response; the plaintext
secret reaches neither wire. Closing the live session releases Control_L on its own
wire only. Passes 10/10 plain, ASan and TSan (Linux) and 10/10 on macOS.

**macOS after all changes.** `build/native-ui-frontend/verification/run-y01wnifx`:
**3/3 viewer, 762/762 unit (22.08 s), 89/89 native (131.08 s)**, graph, configuration,
1052 + 2 localization values, strict signature and CLI stages. Retained FLTK Release
(`build/hidpi-release`) rebuilds and passes 782/782 unit and 3/3 viewer tests.
The 55-case baseline passes again on both frontends after the shared-code fixes:
native Debug `build/native-protocol-shared-fixes` (SHA-256 `afaced6b…60d0`) and FLTK
`build/fltk-protocol-shared-fixes` (`8a31be50…c7c5`), hashes matching the binaries.
Branding audit (1650 deferred) and `git diff --check` pass. macOS sanitizer runs
of the full crypto-enabled suite, native app/Swift sanitizers, hosted CI and every
interactive/physical/installed gate remain open.

### N1.15 / N1.9 / N3.17 Apple sanitizers, bell and pasteboard routing (2026-09-23)

**macOS core sanitizers (crypto on).** New trees `build/macos-core-asan` and
`build/macos-core-tsan` (Debug `-Werror`, GnuTLS/nettle on, headless graph): both
pass **3/3 viewer + 762/762 unit** in three consecutive runs (ASan ≈ 9 s, TSan
≈ 28 s per run). ASan runs with `detect_container_overflow=0`: libc++'s string
annotations report false container overflows during gtest discovery because
Homebrew's `libgtest.a` is uninstrumented. Darwin arm64 has no LeakSanitizer
(leaks are covered by the Linux LSan run).

**Native Swift sanitizers (crypto on).** `build/macos-native-asan` and
`build/macos-native-tsan` (`-sanitize=address`/`thread` for Swift plus C/C++): 88/88
native CTest cases pass under each. The remaining case,
`NativeSettings.DraftRendering`, runs 42–43 s instrumented against its old 40 s
limit; run directly, it passes with no sanitizer report. Its limit is now 120 s,
since it already takes about 31 s uninstrumented. Uninstrumented: AppKit/SwiftUI/
system frameworks, Homebrew GnuTLS/nettle/pixman/jpeg and gtest. No MSan on either
platform; glibc resolver tests skip under TSan (see above).

**Server bell (N3.17).** The native app counted server bells but never sounded
them. `NativeSession.bellHandler` now fires on MainActor when the current attempt's
count advances, at most once per delivery turn. The coordinator injects
`NativeSystemBell` (`NSSound.beep()`, matching FLTK's `fl_beep`) through
`NativeBellSounding`. `native-bridge-tests` covers a 5-bell burst (1–5 rings, all 5
counted), a later single bell (+1), reconnect reset without ringing, the new
attempt's bell and no ring on close. Passes 6/6 repeated runs.

**Pasteboard routing (N1.9).** "Copy Diagnostics" wrote `NSPasteboard.general` on
the main thread, outside the serialized pasteboard worker. It now calls
`NativeClipboardCoordinator.copyLocal`, a new `NativePasteboardAccess.writeLocal`
without the remote-provenance marker; routing then treats it as a local copy.
`native-clipboard-tests` verifies on a private named pasteboard that the text is
written unmarked and sent only to the focused session. No app code writes
`NSPasteboard.general` directly any more.

**N1.9 audit.** Recorded under N1.9: six services have contracts, fakes and typed
errors; trust, document/file and display/window/input are partial; access/
permission and app services are missing, and the production wiring is untested.
N1.9 stays open.

Final macOS Debug verification after these changes:
`build/native-ui-frontend/verification/run-s8ryht58` passes **3/3 viewer, 762/762
unit (22.09 s), 89/89 native (132.99 s)**, graph, configuration, 1052 + 2
localization values, **140 Swift sources / 1353 call sites**, strict signature and
CLI stages. Branding (1650) and diff checks pass.
