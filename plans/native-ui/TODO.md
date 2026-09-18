# Native UI implementation checklist

Tracker for [PLAN.md](PLAN.md). Baseline: `4e07cc16`, inspected 2026-09-18.
**Started: N0 source audit and first N1.4 isolation prerequisite.** Check an item only after
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

- [ ] N1.1 Create GUI-independent core/service targets with clear dependency direction; prove clean configure/build without FLTK, SwiftUI, AppKit or WinUI.
- [ ] N1.2 Extract endpoint parsing/normalization, typed options, capabilities, structured errors and settings schema; preserve endpoint syntax, option aliases/ranges and precedence.
- [ ] N1.3 Extract shared configuration/document validation from FLTK/global parameter mutation; distinguish app defaults, profiles, session overrides and CLI inputs.
- [ ] N1.4 Replace mutable session-global options, security configuration, timer ownership and reconnect credentials with scoped state. Preserve compatible legacy consumers without introducing races.
  - Completed prerequisites: caller-owned DES schedules for client/server VNC
    authentication/password-file helpers, and invocation-owned Tight gradient
    scratch rows; see evidence below. Other audited globals remain open.
- [ ] N1.5 Implement session/listener lifecycle, commands, operation completion and generation-tagged ordered events; test invalid transitions and initial snapshot subscription.
- [ ] N1.6 Separate socket readiness/monotonic scheduling from UI loops; implement cancellation/wakeup and test timer teardown. Public contracts do not expose POSIX descriptors.
- [ ] N1.7 Remove window/widget ownership from the session; introduce attach/detach view subscriptions and presentation-independent framebuffer ownership.
- [ ] N1.8 Implement retained frame/cursor leases, explicit pixel format/stride/origin, damage and size generations; bound memory and merge skipped damage correctly.
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

### Implementation evidence template

Copy for each completed subtask or phase:

- IDs / commit:
- Behavior delivered and affected interfaces:
- Tests/commands and results (including failures resolved):
- OS/hardware/toolchain/build configuration:
- Screenshots, benchmark data or artifacts:
- Remaining limitations / unchecked dependencies:
