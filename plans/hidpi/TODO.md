# Full HiDPI support checklist

Scope update (2026-09-17): the user has excluded Java parity and deferred Windows/Linux work. Continue implementation and validation for macOS. Cross-platform and Java checkboxes below are retained as deferred history, not gates for this macOS effort. macOS mixed-density fullscreen remains in scope.

Track implementation of [PLAN.md](PLAN.md), baseline `9cb71cda`. Work in progress. Only completed work with evidence is checked. Record evidence under each milestone. Coordinate shared work with [client scaling](../client-scaling/TODO.md); completion of one helper must not be counted as completion of platform integration.

## H1 — Upgrade FLTK and establish the 1× baseline

- [x] Capture the existing FLTK 1.3 build/test/rendering baseline; preserve its build directory.
- [x] Pin FLTK 1.4.5 source/version/checksum and dependency-cache inputs for CI.
- [x] Require the tested 1.4 baseline and reject unsupported versions clearly.
- [x] Move FLTK discovery to the config package and imported image/core targets.
- [x] Update the CMake minimum and static/shared selection consistently.
- [x] Update viewer and framebuffer-performance target linkage.
- [x] Rework `cmake/StaticBuild.cmake` to avoid mixing old library strings with imported targets.
- [x] Update Linux, Windows, macOS, and all-disabled CI dependency recipes.
- [x] Update distro package requirements and `BUILDING.txt`.
- [x] Preserve viewer-off/server-only configuration without requiring FLTK.
- [ ] Audit explicit headers, private FLTK dependencies, platform handles/contexts, image overrides, and timers.
- [ ] Replace unsupported API use and remove superseded workarounds only with regression coverage.
- [ ] Force the supported X11 runtime for hybrid Linux builds; fail clearly if unavailable.
- [x] Distinguish viewer backend selection from the existing Wayland server option.
- [x] Disable FLTK keyboard GUI zoom before display initialization; retain remote/viewer shortcut behavior.
- [ ] Build/run native clients and original tests at 1× on macOS, Windows, and Linux.
- [ ] Verify keyboard grabs, clipboard, gestures, side buttons, fullscreen, and slow-update timers.

H1 evidence / review references:

- 2026-09-17: macOS arm64 RelWithDebInfo viewer and framebuffer benchmark compile with FLTK 1.4.5; all original 269 tests pass. Pinned dependency project and native CI recipes added; Windows/Linux CI and package-container validation remain pending.

- 2026-09-17: preserved `build/macos` (FLTK 1.3.11, 269 passing tests). Official FLTK 1.4.5 archive downloaded and SHA-256 verified; upgrading in separate `build/hidpi-deps` and `build/hidpi` directories.

## H2 — Shared coordinate and settings contract

- [x] Reconcile this plan with the scaling plan's FLTK, pixel-unit, identity, and fractional-pan assumptions.
- [ ] Implement proposed display metrics snapshots and one shared desktop transform.
- [ ] Distinguish remote pixels, logical units, backing pixels, and native screen coordinates in interfaces.
- [ ] Implement per-target effective logical-to-backing mapping without guessed/doubled DPI factors.
- [ ] Implement native conversions with negative origins and per-monitor coordinate conventions.
- [x] Separate remote framebuffer allocation from viewport display geometry.
- [x] Add `DesktopPixelUnits=Logical|Device`, default Logical, with typed parsing.
- [x] Define no-scaling, percentage, independent-percentage, exact-size, and fit semantics for both policies.
- [x] Implement fractional logical extents/pan with exact backing-pixel alignment.
- [ ] Implement consistent allocation/damage rounding, pixel-center sampling, inverse mapping, and overflow checks.
- [x] Handle minimized/zero-size windows and invalid metrics without division by zero.
- [x] Define single-window and multi-view remote-resize/topology policy.
- [x] Add headless unit/serialization/geometry fixtures shared with client scaling and Java.
- [x] Register tests and verify they are discovered.

H2 evidence / review references:

- 2026-09-17: `DesktopTransform` parser/geometry and `DesktopResampler` tests discovered and passing (8 new tests). Fractional Device bounds, six DPI factors, fit-unit invariance, invalid inputs, area averages and tiled/full equality covered. Platform integration remains in progress.

## H3 — Backing-resolution rendering and input

- [ ] Add explicit logical/backing target bounds, origin, scale, clip, and ownership to rendering interfaces.
- [x] Preserve a single connection-owned remote framebuffer in remote pixels.
- [ ] Implement both direct and offscreen drawing through the target contract.
- [x] Compose desktop zoom and DPI before one resampling pass.
- [x] Restrict identity blits to the complete aligned remote-to-backing identity transform.
- [x] Allocate composition surfaces at backing resolution with checked arithmetic.
- [x] Rebuild overlays/statistics text at target resolution after metrics changes.
- [x] Extend tile/cache keys with backing dimensions, sampling origin, format, and metrics generation.
- [x] Map filter-aware source damage to backing pixels and outward to FLTK damage coordinates.
- [x] Clear old bounds/letterboxes and handle exposures without new server updates.
- [x] Preserve decoder synchronization and harvest damage before cache reuse.
- [ ] Enforce cache/compositing budgets, bounded scratch storage, and allocation-failure behavior.
- [x] Map FLTK pointer events to remote coordinates exactly once.
- [x] Keep throttled positions in remote coordinates through transform changes.
- [ ] Preserve outside-image drag releases, leave behavior, wheel deltas, keys, and view-only rules.
- [x] Rescale original server cursor images/hotspots with premultiplied alpha and native-size awareness.
- [ ] Implement/verify software cursor fallback and old/new cursor damage.
- [ ] Map server warps through native screen conversion while preserving capture/offscreen policy.
- [ ] Add image-reference, incremental-damage, cache, input, cursor, and failure-path tests.

H3 evidence / review references:

- 2026-09-17: single-view desktop rendering composes scale and DPI into the backing raster, uses 256×256 resampling scratch and at most 1024×1024 composition storage (4 MiB). The connection still owns the source buffer. `syncFramebuffer()` joins decoders before CPU reads; damage harvested on an expose is retained for the next update. Software cursors use premultiplied filtering. This was first-pass evidence; the macOS continuation below adds caching and direct-path cursor composition. Failure injection and interactive rendering tests remain open.

## H4 — Platform awareness and runtime transitions

- [x] Add coalesced display-metrics refresh after realization, resize, fullscreen, topology, and backing changes.
- [x] Compare metrics before drawing to cover missed native notifications.
- [ ] Preserve center anchor, fixed-unit semantics, fit layout, and scroll position during transitions.
- [ ] Cancel obsolete work and prevent recursive resize/scale callbacks.
- [x] Enable `NSHighResolutionCapable` in the macOS bundle alongside corrected rendering.
- [x] Implement Cocoa view/window backing conversions and backing-change detection.
- [x] Replace unconditional macOS CTM resets; preserve orientation, translation, scale, and clipping.
- [x] Separate bitmap/window CGContext behavior and validate color-space/state handling.
- [ ] Verify Retina/non-Retina, scaled modes, Spaces, fullscreen, and packaged app launches.
- [ ] Verify Windows process/window awareness before window creation and inspect packaged declarations.
- [x] Let FLTK own Windows DPI resize handling; avoid duplicate suggested-rectangle application.
- [x] Replace Win32 global graphics-context swapping with explicit HDC targets.
- [ ] Normalize Windows touch/button/wheel/native-screen conventions exactly once.
- [ ] Preserve supported Windows API/OS fallbacks; validate live DPI and RDP transitions.
- [ ] Convert X11/XRender/XShm geometry and clipping consistently to native pixels.
- [ ] Audit X11 window-manager geometry, RandR monitor labels, pointer warps, and XInput synthesis.
- [ ] Verify native X11 scale behavior and forced-X11 operation under XWayland.
- [x] Document compositor limitations without advertising a native Wayland backend.
- [ ] Implement Logical/Device automatic remote-resize dimensions and DPI-only transition policy.
- [ ] Preserve explicit DesktopSize units, pending-request/rate-limit rules, capability checks, and denial behavior.
- [ ] Verify density-only transitions, hotplug, negative monitor origins, and minimized restore.

H4 evidence / review references:

- 2026-09-17: macOS live fixture: a 320×240 remote grid at 100% Device occupies 160×120 logical units with a reported 2× backing factor in the staged Retina-capable app. This is a visual smoke test, not a raw pixel comparison or mixed-monitor test. Native warps now use window/client conversions rather than multiplying desktop origins.
- FLTK 1.4.5 `Fl_win32.cxx` requests Per-Monitor V2 awareness with older API fallbacks before opening the display. Runtime/installer awareness on Windows still needs verification.

## H5 — UI, settings, assets, and scaling integration

- [x] Keep FLTK fonts/layout metrics logical; eliminate accidental double scaling.
- [ ] Audit every viewer dialog, menu, tooltip, suggestion popup, and custom monitor widget.
- [x] Provide suitable-resolution icons and correct logical-versus-raster image sizes.
- [x] Add the desktop-unit selector with clear labels and fit-mode inactive state.
- [ ] Preserve atomic Apply/OK, Cancel behavior, startup configuration, and live updates.
- [x] Persist the unit preference in native config files/defaults/registry with Logical fallback for old files.
- [x] Keep desktop pixel units, scaling quality, JPEG quality, and OS GUI scale independent.
- [x] Add effective logical/backing/remote size, scale, backend, and metrics-generation diagnostics.
- [x] Integrate all eight scaling modes and three qualities through the shared transform/resampler.
- [ ] Verify that fit output is unchanged by the unit selector alone.
- [ ] Verify quality-only changes do not alter geometry, remote resolution, or pan.
- [x] Preserve scaling-mode suspension of automatic remote resizing without overwriting preferences.
- [ ] Test long translations, keyboard navigation, focus indicators, and multiple sessions on different-DPI monitors.

H5 evidence / review references:

- 2026-09-17: native Scaling page provides eight modes, retained per-mode values, quality and Logical/Device selectors. Parsing runs before any options are committed. Native parameters are included in the existing persistence list. GUI navigation, translations, registry persistence and protocol behavior still need the listed integration checks.

## H6 — Fullscreen across mixed-density monitors

- [x] Separate connection/session ownership from native desktop views.
- [x] Create one backing-aware borderless view per selected monitor where supported.
- [x] Make each viewport a non-owning consumer of the single remote framebuffer.
- [x] Fan source damage out to all views before clearing it.
- [x] Centralize keyboard/button state, clipboard ownership, grabs, and connection lifetime.
- [x] Build the canonical logical/device desktop-canvas layout and per-view remote region map.
- [x] Normalize incompatible monitor layouts deterministically and show the resulting arrangement.
- [x] Validate nonoverlap, bounds, gaps, screen IDs, and ScreenSet protocol limits.
- [x] Use the same region map for drawing, pointer mapping, cursor warps, and remote resizing.
- [ ] Preserve key/button holds and cursor position across monitor seams without duplicate events.
- [ ] Handle hotplug, primary-display changes, fullscreen exit, view close, and Spaces restrictions.
- [x] Preserve coherent single-window straddling behavior and document its native backing-scale limitation.
- [ ] Verify per-monitor full-resolution output and seam input continuity on mixed-density setups.
- [x] Label unsupported/fallback cases explicitly; do not call single-window fallback full per-monitor support.

H6 evidence / review references:

- macOS implementation: `DesktopSession` installs/replaces the connection framebuffer once, synchronizes decoders and fans harvested damage to registered viewports. Input/clipboard/keyboard state remains in the primary viewport; secondary `DesktopView` windows share it. Focus loss is deferred until FLTK completes cross-window focus transfer. Captured drags route via the view under the global pointer; held button masks survive leave events.
- `DesktopLayout` builds a deterministic canvas with stable CoreGraphics display IDs, normalized negative origins, preserved directional separation and protocol bounds checks. `DesktopTransform::placeOnCanvas()` is shared by rendering and inverse input. Remote resize and cursor warps use this map. Fit modes use a logical canvas independent of the pixel-unit preference. The macOS monitor selector previews the resulting layout.
- Four new topology/mapping tests pass. Physical mixed-display seam holds, hotplug and separate-Spaces behavior remain **unverified**, so the corresponding integration checkboxes remain open.

## H7 — Java HiDPI audit and shared policy parity (excluded by user)

- [ ] Establish and record the supported JDK/platform test matrix separately from the source-language target.
- [ ] Audit Graphics2D transforms and logical/image-raster dimensions for double scaling.
- [ ] Audit GraphicsConfiguration bounds, Robot coordinates, fullscreen borders, and cursor limits.
- [ ] Add `DesktopPixelUnits` parsing, controls, persistence, and legacy Logical default.
- [ ] Apply the same desktop-scaling and remote-resize semantics.
- [ ] Fix DPI/monitor-transition, cursor, input, and fullscreen issues exposed by the audit.
- [ ] Run shared geometry/serialization/rendering fixtures with appropriate image tolerances.
- [ ] Test Java GUI behavior on the supported OS/JDK combinations.
- [ ] Document runtime limitations and explicitly review any required runtime-floor change.

H7 evidence / review references:

- 2026-09-17: [JAVA-AUDIT.md](JAVA-AUDIT.md) records concrete integration points and the distinction between the existing JDK build matrix and the required runtime matrix. Java code/parity is not implemented.

## H8 — Validation, performance, packaging, and documentation

- [ ] Run original and new native tests with actual discovery; make relevant CI failures blocking.
- [x] Build Debug and RelWithDebInfo, viewer-off, and supported static/shared configurations.
- [ ] Verify macOS Retina/non-Retina, scaled modes, mixed monitors, Spaces, and packaged app behavior.
- [ ] Verify Windows 100/125/150/175/200/300%, mixed displays, fullscreen, live DPI, and RDP reconnect.
- [ ] Verify native X11 and XWayland with recorded compositor/scale/backend settings.
- [ ] Exercise all eight modes × three qualities × two unit policies.
- [ ] Test odd/tiny/large images, fractional factors, clipping, tile seams, and one-pixel checkerboards.
- [ ] Verify sharp overlays and UI independently of remote framebuffer sharpness.
- [ ] Test native direct/offscreen output and compare incremental updates with full reference renders.
- [ ] Test slow decode, scale-change redraws, server resize/rejection, pending events, and teardown.
- [ ] Test mouse/wheel/touch, remote warps, cursor variants, and held input through transitions/seams.
- [ ] Compare old/new 1× performance and resolve repeatable render-time regression above 5%.
- [ ] Measure 4K/multi-monitor frame times, input latency, CPU, throughput, and allocation behavior.
- [ ] Establish and meet scaled-frame budgets on recorded reference hardware.
- [ ] Verify tile/compositing caps and no leaks across repeated DPI/hotplug cycles.
- [ ] Inspect packaged FLTK linkage, DPI declarations, resources, architecture, and minimum OS compatibility.
- [ ] Refresh app/DMG/installer artifacts and validate through the normal release process.
- [ ] Update BUILD-MACOS.md, BUILDING.txt, viewer help/man page, translations, release notes, and package metadata.
- [x] Cross-link shared implementation completion in the client-scaling plan/checklist.
- [x] Record capability limits and deferred work; do not mark unfinished native/Java requirements complete.

H8 evidence / review references:

- Earlier local check: 282/282 tests pass for RelWithDebInfo/static (13.39 s) and Debug/shared (13.16 s), including 18 shared geometry fixtures and native bitmap tests. `git diff --check` passes. The new manual Python fixture passes syntax compilation. No Windows/Linux runner or mixed-display hardware was used.
- GUI automation could inspect the live grid but did not successfully exercise the FLTK Options controls or pointer protocol assertions; those checks remain open.

- Added `scalingperf`: on this macOS arm64 host, 1920×1080→3840×2160 resampling alone measured median 3.79 ms Nearest, 29.70 ms Bilinear and 29.65 ms Area (enlargement), six runs after warmup. Before weight/index specialization: 34.00/72.40/72.64 ms. These are not end-to-end frame budgets or the required old/new identity benchmark.

- 2026-09-17: macOS RelWithDebInfo build and 277 discovered tests pass. Viewer-off build passes with FLTK discovery disabled. Separate pinned FLTK bootstrap builds and installs static/shared libraries. Logs are under ignored `build/hidpi/`; reproducible commands are in `BUILD-MACOS.md`.

## Completion record

- Implementation/review references: uncommitted working-tree implementation in `DesktopTransform`, `DesktopResampler`, `DisplayMetrics`, `Viewport`, `DesktopWindow`, `Surface*`, settings, CMake and CI; tests in `tests/unit` and `tests/fixtures`.
- Native test and CI evidence: 293/293 tests pass in both macOS RelWithDebInfo/static and Debug/shared builds. Viewer-off builds without FLTK; 20 selected new tests pass with ASan/UBSan. All 55 protocol/lifecycle cases pass; the refreshed app bundle and Debug/shared viewer each pass the eight-case subset. Remote Windows/Linux CI is deferred.
- Java runtime/test evidence: audit retained as history; parity excluded by the user.
- Per-platform DPI and mixed-monitor evidence: macOS single Retina display smoke test only; mixed monitors and Windows/X11 interactive matrix unverified.
- Performance/memory evidence: bounded 256×256 scratch, 1024×1024 composition tiles, 32 MiB per-view / 128 MiB aggregate CPU cache; latest resampler/cache results recorded below. End-to-end, identity comparison and failure/leak testing remain required.
- Packaged-artifact evidence: updated development app in `build/hidpi/TigerVNC.app`; Retina declaration and a 2× local-grid smoke test. No release DMG, signing/notarization or Windows/Linux package verification for this implementation.
- Documented platform/compositor limitations: one backing scale per ordinary straddling window; new per-monitor macOS fullscreen implementation still needs physical mixed-display verification; XWayland work is deferred.
- Remaining required work: macOS physical mixed-monitor/Spaces/hotplug/input validation, allocation-failure/leak tests, end-to-end performance gates, UI/translation audit and final release packaging/sign-off. Windows/Linux validation and packaging are deferred; Java parity is excluded by the user. This is not yet full HiDPI support as defined by PLAN.md.

## macOS continuation — 2026-09-17

- [x] Add a 32 MiB LRU CPU tile cache per view, with a 128 MiB aggregate CPU-cache cap, fixed image sampling grid and filter-aware invalidation.
- [x] Compare incremental cached output against fresh renders for all filters, enlargement/shrink/mixed axes; test eviction, zero budget, quality/generation invalidation.
- [x] Replace the oversized unscaled cursor fallback with visible 256×256 premultiplied cursor tiles; cover a 100,000-pixel-wide virtual cursor without allocating that raster.
- [x] Add software cursor composition to the direct drawing path.
- [x] Retain a fractional backing-aligned image origin separately from the integer FLTK widget; scrollbars step in backing pixels.
- [x] Observe Cocoa backing/screen/resize/topology changes, coalesce refreshes and remove observers/timeouts on teardown.
- [x] Build the macOS per-monitor fullscreen/session integration and pass 292 unit tests in the static configuration.
- [x] Finish the refreshed Debug/shared build/test, packaged-app protocol smoke checks and documentation evidence for this continuation. Visual inspection is blocked by the locked Mac, as recorded below.

Continuation verification:

- 293/293 unit tests: RelWithDebInfo/static in 12.89 s, Debug/shared in 12.88 s.
- 20/20 selected new tests under AddressSanitizer + UndefinedBehaviorSanitizer (0.62 s); this instruments the pure helpers, not the full GUI/session lifecycle.
- `macos-scaling-smoke.py`: all 55 protocol/lifecycle cases pass. Refreshed `build/hidpi/TigerVNC.app` and Debug/shared viewer each pass the eight-case subset. Tests validate measured backing-size resize requests, fixed explicit dimensions, source/cursor replacement and absence of denial loops; they do not assert displayed pixels or inject mouse/keyboard events.
- Rebuilt viewer-off successfully with FLTK discovery disabled. Static/shared binaries link the intended FLTK; the development app retains the Retina declaration. The app still depends on Homebrew libraries and is not a portable signed release.
- UI audit: native dialogs, menus, suggestion popups, monitor widget and tooltip/font layouts retain logical coordinates. Authentication icons draw vector shapes. The macOS `.icns` includes 128/256/512-pixel artwork. Long translations, focus/navigation, drag/seam holds and actual visual sharpness remain interactive checks.
- The live fixture connected at a reported 2× backing ratio. Computer-use inspection returned “The Mac is locked”; no new screenshot/physical mixed-monitor result is claimed. The test processes were closed.
- Found and fixed a teardown hazard: connection close frees the framebuffer before DesktopWindow destruction, so destroying fullscreen views must not run the normal exit relayout.
- `git diff --check` passes. No implementation commit was created.

Latest `scalingperf` measurement on this macOS arm64 host (six runs after
warmup, CPU resampling/cache only): 1080p→4K full resampling medians were
4.65 ms Nearest, 28.18 ms Bilinear and 28.04 ms Area. A cached 4K exposure
cost 0.46–0.48 ms; a one-source-pixel change cost 0.53–0.75 ms. The cache
retained 31.64 MiB. Full-damage cache runs measured 4.12/28.64/28.65 ms.
These numbers exclude decoding, native composition, presentation and input
latency; they do not satisfy the identity-regression or end-to-end frame-budget
gates. Raw output: `build/hidpi/scalingperf.log`.
