# Native UI implementation checklist

Tracker for [PLAN.md](PLAN.md). Baseline: `4e07cc16`, inspected 2026-09-18.
**Completed: N0.3 audit, N1.1 headless build boundary, N1.7 window-independent session and N1.8 retained publication contract. N1.4 is in progress.** Check an item only after
its code and stated validation are complete;
record commit, commands/results, platform/build and remaining limitations in the
evidence log. A blocked hardware/signing check stays unchecked, not waived.

Scope: portable session/service interfaces and macOS SwiftUI replacement.
No WinUI application or Windows backend implementation is included. Preserve
Windows/Linux FLTK builds. The Java client remains removed.

## N0 — Inventory, baseline and decisions

- [ ] N0.1 Create an exhaustive parity inventory mapping each dialog/control/menu/shortcut/launch path to source, option, native replacement and acceptance test; include every row of PLAN §9.
- [ ] N0.2 Record actual security/encoding/audio/H.264 capabilities, compiled defaults, aliases, validation ranges and live-change versus reconnect semantics.
- [x] N0.3 Audit reachable global configuration, static credentials, timer lists, logging and crypto initialization; identify per-session ownership and compatibility obligations to server/FLTK consumers. See [STATE-AUDIT.md](STATE-AUDIT.md).
- [ ] N0.4 Capture baseline native FLTK screenshots and keyboard/focus behavior; record hardware, OS, SDK, dependency versions, build flags, test totals and protocol results.
- [ ] N0.5 Capture matched performance workloads and budgets: idle/scrolling/1080p/4K/multi-view, p50/p95 latency, CPU, memory, copies and damage. Record existing scaling budget requirements and provisional 10% regression threshold.
- [ ] N0.6 Validate provisional macOS 14 deployment floor, Xcode/Swift/C++ versions, architecture matrix and dependency targets; record final supported configurations.
- [ ] N0.7 Confirm C ABI/module-map/Swift wrapper and CMake-to-Xcode build arrangement; decide CLI app-executable versus launcher behavior without relaying secrets in arguments.
- [ ] N0.8 Prototype AppKit desktop view/fullscreen coordination in SwiftUI, including mixed displays and Spaces; record chosen window strategy.
- [ ] N0.9 Select Keychain backend, item attributes/access policy, local-only behavior and signing prerequisites; document development versus production limitations.
- [ ] N0.10 Review service/ABI contracts for OS-specific types, ownership, cancellation and errors; resolve gaps before extraction. Record decisions in PLAN or a linked decision log.

Exit: reviewed inventory and decision record; baseline evidence exists. No screen
may disappear merely because it is absent from an initial mockup.

## N1 — Portable session engine and services

- [x] N1.1 Create GUI-independent core/service targets with clear dependency direction; prove clean configure/build without FLTK, SwiftUI, AppKit or WinUI. See the N1.1 evidence below and [build instructions](../../viewer/README.md).
- [ ] N1.2 Extract endpoint parsing/normalization, typed options, capabilities, structured errors and settings schema; preserve endpoint syntax, option aliases/ranges and precedence.
- [ ] N1.3 Extract shared configuration/document validation from FLTK/global parameter mutation; distinguish app defaults, profiles, session overrides and CLI inputs.
- [ ] N1.4 Replace mutable session-global options, security configuration, timer ownership and reconnect credentials with scoped state. Preserve compatible legacy consumers without introducing races.
  - Completed prerequisites: caller-owned DES schedules for client/server VNC
    authentication/password-file helpers, invocation-owned Tight gradient
    scratch rows, explicit per-connection authentication/TLS policies, and
    session-owned JPEG negotiation and incoming clipboard limits, plus owned
    security-policy serialization and session-scoped reconnect credentials;
    see evidence below. Other audited globals remain open.
- [ ] N1.5 Implement session/listener lifecycle, commands, operation completion and generation-tagged ordered events; test invalid transitions and initial snapshot subscription.
- [ ] N1.6 Separate socket readiness/monotonic scheduling from UI loops; implement cancellation/wakeup and test timer teardown. Public contracts do not expose POSIX descriptors.
- [x] N1.7 Remove window/widget ownership from the session; introduce attach/detach view subscriptions and presentation-independent framebuffer ownership. Implemented by the portable `ProtocolSession`; see evidence below. Retained FLTK remains a comparison adapter.
- [x] N1.8 Implement retained frame/cursor leases, explicit pixel format/stride/origin, damage and size generations; bound memory and merge skipped damage correctly. See N1.8 evidence below; session/frontend integration remains in N1.7/N2.
- [ ] N1.9 Define and inject PreferencesStore, ProfileHistoryStore, CredentialStore, TrustStore, document/file, clipboard, display/window/input, access, tunnel and app services with typed errors.
- [ ] N1.10 Bridge synchronous authentication/trust callbacks with the cancellable worker rendezvous; hold no shared locks and never block the main thread. If pausing is unsafe, implement/test resumable security states first.
- [ ] N1.11 Prove real VNC/TLS authentication, prompt cancellation, timeout/peer closure and close/quit while a request is outstanding; reject stale/duplicate responses after reconnect.
- [ ] N1.12 Implement bounded input/event queues, coalescing rules and release-all on focus loss/overflow/disconnect; keep view-only enforcement in core.
- [ ] N1.13 Implement disconnect/drain with cancelled IO/prompts/timers/subscriptions and joined decoder work; repeated close and partial construction failure are safe.
- [ ] N1.14 Test two simultaneous sessions with different security/settings, one awaiting credentials while the other continues; no secret, modifier, clipboard or option leakage.
- [ ] N1.15 Run existing applicable unit suites plus deterministic core/service tests with fake stores, transport, scheduler and event sink; run supported sanitizers and record limitations.
- [ ] N1.16 Keep the FLTK frontend building and exercising the extracted logic during transition; shared server behavior remains unchanged.

Exit: headless, reusable session engine; lifetime and authentication boundaries
are proven before substantial SwiftUI screen work begins.

## N2 — C ABI, Swift bridge and working native slice

- [ ] N2.1 Define versioned `tidyvnc_` C exports, opaque handles, size-tagged structs, explicit enum values, spans and release functions; document each call's thread/ownership contract.
- [ ] N2.2 Catch all exceptions at the boundary; validate lengths/overflow/versions/handles and return structured errors. Test failure paths from a pure C caller.
- [ ] N2.3 Implement callback context retention, subscriptions, exactly-once completions and drain semantics; test destruction with queued callbacks and retained old frames.
- [ ] N2.4 Add module map and Swift owning wrappers with async commands, typed errors and MainActor state; prevent unsafe borrowed pointers escaping callbacks.
- [ ] N2.5 Implement explicit async close and safe nonblocking cleanup; no main-thread worker join or nested event loop.
- [ ] N2.6 Create SwiftUI app shell with AppKit lifecycle coordinator and `NSViewRepresentable` desktop view; link the C++ core without FLTK.
- [ ] N2.7 Connect to a controlled loopback server, show/cancel authentication, display updates, send keyboard/pointer and disconnect/reconnect using the native path.
- [ ] N2.8 Verify UI responsiveness during slow DNS/connect/auth/decoding and quit; test active frame resize while view/session is removed.
- [ ] N2.9 Compile/exercise a mock non-Apple consumer of the same interface, checking no Foundation/Objective-C/Swift/POSIX/widget types leak into public contracts. No WinUI frontend is required.

Exit: an end-to-end native vertical slice with proven bridge ownership and
cancellation; not yet permission to replace the shipping frontend.

## N3 — Native storage and platform adapters

### Preferences, profiles and documents

- [ ] N3.1 Implement app-domain non-secret defaults with schema/revision and serialized writes; define conflict behavior without claiming UserDefaults supplies database transactions.
- [ ] N3.2 Implement versioned profile/history storage under native Application Support with private permissions, atomic writes, bounded history and safe future-schema/corruption handling.
- [ ] N3.3 Implement connection document codecs and native open/save/overwrite flows; retain both accepted headers and new `.tidyvnc` exports. Never export secrets.
- [ ] N3.4 Implement explicit current-TidyVNC XDG defaults/history import with preview, no-overwrite/new-native-state precedence, cancellation, idempotence and post-success migration marker.
- [ ] N3.5 Preserve separate legacy import rules; exclude security/credentials/trust/tunnel commands and never modify original sources.
- [ ] N3.6 Document/test native-store versus explicit XDG/CLI/file precedence, no dual writer and intentional export back to FLTK; malformed native data must not trigger fallback import.
- [ ] N3.7 Test missing/read-only/inaccessible/corrupt/future-schema stores, interrupted commits and concurrent stale edits in isolated domains/temp roots.

### Credentials and trust

- [ ] N3.8 Implement CredentialKey normalization for endpoint/port/transport/route/auth kind/user; test IPv6 scope, aliases, password-only auth and tunnel identity collisions.
- [ ] N3.9 Implement Keychain lookup/save/delete/metadata with interaction policy and distinct not-found/locked/denied/cancelled/failure results; no plaintext fallback.
- [ ] N3.10 Implement use-once, session reconnect and explicit “remember on this Mac”; save only after successful auth and reconcile store failure without failing the live session.
- [ ] N3.11 Implement replace/forget flow and bounded retry for rejected stored secrets; no automatic destructive delete and no cross-session static secret cache.
- [ ] N3.12 Retain trust verification and dedicated exception storage; explicit scoped certificate/key decisions, changed identity handling and CA/CRL selection. Never install implicit system-wide trust.
- [ ] N3.13 Limit secret buffer lifetime/copies, redact logs/snapshots/exports and clear owned mutable buffers; document runtime zeroization limits.
- [ ] N3.14 Test real Keychain operations using disposable scoped entries and packaged app identity, including upgrade/access-policy behavior; remove only test entries.

### Remaining native services

- [ ] N3.15 Implement clipboard offer/read/write, size/encoding limits, focus/session routing and loop prevention; independently enforce send/receive settings.
- [ ] N3.16 Implement display topology/scale snapshots, stable IDs and generation notifications; handle missing monitors and negative coordinates.
- [ ] N3.17 Implement window/presentation lifecycle, bell/URL/help and structured redacted diagnostics.
- [ ] N3.18 Implement explicit file access and existing supported tunnel invocation/cancellation without shell-string interpolation; report unsupported features honestly.
- [ ] N3.19 Implement platform capability/permission guidance and retry flow. Preserve Local Network metadata; do not require global input monitoring for ordinary view input or modify privacy settings.
- [ ] N3.20 Run shared service contract tests against fake adapters and macOS implementations; document unsupported future-Windows semantics without implementing its backend.

Exit: platform integration is exercised through the same interfaces the native
UI uses, with migration and credential behavior verified independently.

## N4 — Complete SwiftUI replacements

- [ ] N4.1 Connection window: endpoint validation, recent hosts, Open/Save, Connect/Cancel, separate import choices and keyboard-first operation.
- [ ] N4.2 Authentication sheet: required fields, endpoint/security context, secure entry, three retention choices and cancellation per session.
- [ ] N4.3 Trust sheets: reason/details/expected and received identity, safe default, scoped decision and reconnect generation handling.
- [ ] N4.4 Encoding/color/compression settings: auto select, all supported encodings, full/reduced color, JPEG enable/quality and compression range.
- [ ] N4.5 Security settings: encryption/authentication options, CA/CRL pickers and reconnect-required changes with unchanged negotiation policy.
- [ ] N4.6 Input/clipboard/shortcut settings: view-only, middle button, fallback cursor, fullscreen system keys, modifiers and separate clipboard directions; omit X11-only options on macOS.
- [ ] N4.7 Scaling settings: eight modes, custom dimensions/decimal percentages, validation/help, filters and logical/device units.
- [ ] N4.8 Display/miscellaneous settings: window/current/all/selected screens and visual chooser, remote resize policy, shared/reconnect settings and capability-gated optional features.
- [ ] N4.9 Separate app Settings defaults from live session override sheets; draft/apply/cancel and effective-source display; no mutation of other sessions.
- [ ] N4.10 Desktop commands/context menu: disconnect, fullscreen/minimize/resize-to-session, Ctrl/Alt toggles, Ctrl-Alt-Del, refresh, options, info and About; route to focused session.
- [ ] N4.11 Native app menus/Dock/new connection/open document/quit; Finder, CLI, explicit file, reverse/listen and supported tunnel entry paths work without secret-bearing relaunch arguments.
- [ ] N4.12 Connection inspector/stats overlay with negotiated properties, throttled updates and redacted copyable diagnostics.
- [ ] N4.13 Errors/reconnect/permission guidance with correct category, Retry/Cancel and safe context; routing errors do not assert a proven privacy denial.
- [ ] N4.14 Open/save/import/overwrite confirmations with native panels, cancellation and filesystem error recovery.
- [ ] N4.15 About/credits/help with correct identity, licenses, attribution and support links.
- [ ] N4.16 Native localization catalog and mapping of structured core errors; preserve retained gettext consumers and translator attribution; test long strings and fallback.
- [ ] N4.17 VoiceOver labels, keyboard focus/tab/escape/default actions, light/dark/high contrast and reduced motion on every screen/sheet. Document remote framebuffer accessibility limits.
- [ ] N4.18 Update parity inventory with native screenshots and UI-test/manual evidence for every control and action; record intentional differences explicitly.

Exit: all existing macOS UI behaviors have tested native counterparts; no
unchecked parity rows hidden by a visually complete connection screen.

## N5 — Desktop fidelity, input and performance

- [ ] N5.1 Implement measured CPU/Core Graphics presentation path with existing resampler/cache algorithms; keep pixels off SwiftUI observation and avoid per-view full-desktop copies.
- [ ] N5.2 Preserve identity fast path, all scaling modes/filters, logical/device units, fractional pan/scale, scrolling and letterboxing; verify fixtures and displayed pixels.
- [ ] N5.3 Verify damage coalescing, dropped-presentation recovery, bounded retained frames and resize generation handling with attached/detached views.
- [ ] N5.4 Verify remote/local cursor fallback, shape/hotspot, scaling and pointer mapping at edges and outside letterboxed content.
- [ ] N5.5 Implement AppKit keyboard/pointer/wheel translation, physical/logical key policy, IME/dead keys/repeats, local shortcuts and protocol scancodes without duplicate input.
- [ ] N5.6 Verify release-all on focus loss, disconnect, sleep, capture change and window transitions; one remote input state spans all session views and view-only blocks synthetic input.
- [ ] N5.7 Preserve current/all/selected-monitor fullscreen, reconnect layout and remote-resize policy; test topology change, unplug/replug, Spaces and missing saved display IDs.
- [ ] N5.8 Run physical 1×/2× and mixed-density/multi-display tests with recorded OS/hardware; simulation alone does not complete this item.
- [ ] N5.9 Run matched FLTK/native benchmarks against N0 budgets; record latency/CPU/memory/copy/damage results and resolve or explicitly review regressions before cutover.
- [ ] N5.10 Stress reconnect, resize, slow consumer and attach/detach cycles; check bounded memory, no stale callbacks and no retained input state.

Exit: fidelity and measured responsiveness match the retained native feature
contract. A GPU rewrite is not required unless justified by failed budgets.

## N6 — Build, integration and macOS cutover

- [ ] N6.1 Add explicit Apple-only SwiftUI frontend selection and retain FLTK as default until gates pass; unsupported/missing toolchain configurations fail clearly.
- [ ] N6.2 Script clean CMake core → Xcode app/test/package builds with pinned configuration and generated dependency inputs; one source for identity/version/resources.
- [ ] N6.3 Split FLTK surface-dependent tests from GUI-independent tests; core-only and SwiftUI builds neither discover nor link FLTK.
- [ ] N6.4 Add native build/model/adapter/UI CI jobs and retain Windows/Linux FLTK jobs; test chosen minimum/current macOS and supported architectures, recording unavailable runners.
- [ ] N6.5 Run all applicable original unit tests, new contract/ABI/service tests, supported sanitizers and full protocol regression matrix through the native frontend.
- [ ] N6.6 Validate bad credentials/trust, clipboard, remote resize, reverse/listen, tunnel, peer disappearance and reconnect; protocol tests supplement native presentation/input evidence.
- [ ] N6.7 Validate final bundle identity, document associations, localization, credits, Local Network description, signing/resource seal and dependency paths; verify no FLTK linkage/symbols.
- [ ] N6.8 Test installed Finder-launched Local Network allow/deny/retry, actual LAN connection and signing-identity upgrade behavior. Do not count Terminal-only smoke tests as privacy validation.
- [ ] N6.9 Test final packaged Keychain identity/access across updates; no developer-only entitlement/signature assumptions or test secrets remain.
- [ ] N6.10 Test sleep/wake/network changes, multi-session prompt isolation and clean app quit with pending IO/auth/store operations.
- [ ] N6.11 Validate rollback to retained FLTK artifact using untouched legacy data and explicit profile export; do not overwrite native stores or transfer credentials automatically.
- [ ] N6.12 Update BUILD-MACOS, migration/user docs, CLI help, package inspection tests, screenshots and other affected plans; distinguish local packaging from distribution portability/notarization.
- [ ] N6.13 Review every parity row and acceptance gate; only then make SwiftUI the default/shipping macOS frontend and remove FLTK from that app's dependency path.
- [ ] N6.14 Publish interface handoff documentation with types, state diagrams, thread/lifetime/error contracts and reusable tests for a future separate WinUI plan. Do not claim Windows implementation complete.

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

### Implementation evidence template

Copy for each completed subtask or phase:

- IDs / commit:
- Behavior delivered and affected interfaces:
- Tests/commands and results (including failures resolved):
- OS/hardware/toolchain/build configuration:
- Screenshots, benchmark data or artifacts:
- Remaining limitations / unchecked dependencies:
