# TigerVNC client scaling checklist

Implementation tracker for [PLAN.md](PLAN.md), based on repository `f885b340`. Shared native work is tracked in [the HiDPI checklist](../hidpi/TODO.md); only implemented items below are checked. Complete phases in dependency order; attach test output, screenshots, benchmark data, or review references as work finishes.

## P1 — Contract, configuration model, and geometry

- [x] Implement typed `ScalingSettings`, mode enum, parser, and canonical serializer in `vncviewer/DesktopTransform.h` and `.cxx`.
- [x] Support no scaling (`100`, alias `None`).
- [x] Support automatic fit/stretch (`Auto`).
- [x] Support aspect-preserving fit (`FixedRatio`).
- [x] Support aspect-preserving fit width (`FitWidth`).
- [x] Support aspect-preserving fit height (`FitHeight`).
- [x] Support exact displayed pixel dimensions (`1920x1080`).
- [x] Support arbitrary uniform percentages, including decimals (`137.5`, `137.5%`).
- [x] Support independent horizontal/vertical percentages (`125%x80%`).
- [x] Implement `ScalingQuality=Nearest|Bilinear|Area`, default Bilinear.
- [x] Implement lexical rules, numeric limits, overflow checks, and error messages from PLAN §3.
- [ ] Implement atomic validation and saved-setting fallback policy.
- [ ] Implement immutable transform/layout output with distinct source, display, available-area, and origin fields.
- [x] Implement rounding rules, effective ratios, and minimum-one-pixel output.
- [ ] Implement stable scrollbar resolution for fit and fixed modes.
- [ ] Implement centering, pan clamping, and center-anchor preservation.
- [ ] Handle zero-area/minimized windows and runtime dimension-limit fallback/recovery.
- [x] Define coordinate units and document platform DPI conversion boundaries.
- [ ] Add parser, serialization, geometry, scrollbar, and transform unit tests.
- [x] Create shared native/Java contract fixtures.
- [x] Register sources and GoogleTest targets in CMake; verify test discovery.

P1 exit evidence:

## P2 — Decouple framebuffer storage and display geometry

- [x] Add explicit `Viewport::resizeFramebuffer()` using existing connection ownership.
- [x] Make `Viewport::resize()` affect only local presentation.
- [ ] Replace remote-size assumptions in `DesktopWindow::resizeFramebuffer()`.
- [x] Preserve source contents and initialization through `CConnection::setFramebuffer()`.
- [ ] Audit all uses of viewport width/height and classify source versus displayed dimensions.
- [ ] Centralize layout recomputation and pass one transform to rendering/input/cursors.
- [ ] Retain existing no-scaling window auto-size behavior.
- [ ] Verify default sessions, framebuffer resize, reconnect, and teardown without scaling.

P2 exit evidence:

## P3 — Rendering, quality, synchronization, and damage

- [ ] Implement a headless `Resampler` and viewer `ScalingRenderer`.
- [ ] Retain the original identity draw path in both `Viewport::draw()` overloads.
- [x] Implement clipped visible-tile rendering with absolute sampling coordinates.
- [x] Reuse bounded scratch `PlatformPixelBuffer` tiles without attaching them to the connection.
- [ ] Support both direct window drawing and offscreen composition.
- [x] Implement nearest-neighbor pixel-center sampling.
- [x] Implement separable bilinear interpolation and edge clamping.
- [x] Implement area downsampling and linear upsampling per axis, including mixed-axis transforms.
- [ ] Handle source pixel format/stride, opaque desktop output, and premultiplied cursor alpha.
- [ ] Implement reusable weight tables and bounded intermediate buffers.
- [x] Add the narrow decoder-flush hook and viewer wrapper.
- [ ] Make exposure, option-change, and slow-update rendering safe against decoder writes.
- [ ] Harvest newly committed damage after synchronization and invalidate cache tiles before drawing.
- [ ] Verify synchronization does not reenter protocol dispatch or introduce deadlock.
- [ ] Implement bounded tile caching, generation keys, eviction, and allocation-failure recovery.
- [x] Map source damage through filter support with outward rounding and clipping.
- [ ] Invalidate affected tiles for source changes and all relevant generations for settings/size changes.
- [ ] Repaint exposed background and old/new image bounds after layout changes.
- [ ] Preserve CopyRect and X11 source/tile upload correctness.
- [ ] Verify GDI drawing, macOS orientation/CTM handling, and X11 upload paths.
- [x] Keep viewer overlays and statistics at normal UI size.
- [ ] Add golden resampler, tile-seam, incremental-versus-full-repaint, and cache lifecycle tests.
- [ ] Add decoder-concurrency and allocation-failure tests.

P3 exit evidence:

## P4 — Input, cursors, resizing, and fullscreen

- [x] Map pointer coordinates once, before emulation/throttling, using the shared inverse transform.
- [ ] Keep pending pointer positions in remote coordinates; clamp after server resizing.
- [ ] Verify motion, button press/release, dragging, wheel pairs, and leave events.
- [ ] Ignore interactions initiated in letterboxes or viewer controls.
- [ ] Preserve outside-image drag capture and release without stuck buttons.
- [ ] Audit touch-generated pointer events for exactly one transform.
- [ ] Retain original server cursor pixels and rescale cursor dimensions/hotspots on changes.
- [ ] Preserve blank, dot, system-cursor, and view-only behavior.
- [ ] Implement bounded software-cursor fallback for native cursor limits.
- [ ] Invalidate old/new software-cursor bounds and verify composition order.
- [ ] Forward-transform accepted server cursor positions and ignore offscreen warps.
- [ ] Update scrollbars, virtual fullscreen offsets, and edge scrolling for displayed dimensions.
- [ ] Recompute fits after local/server resizing and fullscreen/monitor transitions.
- [ ] Preserve fixed-mode dimensions without automatically resizing the outer window.
- [ ] Suspend automatic remote resizing in every non-default scaling mode without overwriting the preference.
- [ ] Split explicit initial `DesktopSize` handling from automatic window-driven resizing.
- [ ] Cancel unsent automatic work and handle in-flight responses without feedback loops.
- [ ] Verify unsupported/denied resize requests and view-only sessions.
- [ ] Add protocol/input integration tests for coordinates, releases, timers, and SetDesktopSize behavior.

P4 exit evidence:

## P5 — Native controls, persistence, and help

- [ ] Add the dedicated Scaling tab with eight mode choices and mode-specific editable fields.
- [ ] Add the quality selector and effective-size/X/Y-scale diagnostic.
- [ ] Add mode explanations, percentage suggestions, pixel-unit labels, and remote-resize status.
- [ ] Validate before changing any options; OK applies once and Cancel preserves live state.
- [ ] Apply changes during a connection without reconnecting.
- [ ] Verify quality-only changes preserve window size, pan position, and remote resolution.
- [x] Register native parameter declarations and persisted `parameterArray` entries.
- [ ] Test connection files, saved defaults, Windows registry, and startup argument precedence.
- [ ] Verify old configuration files and invalid saved-value recovery.
- [ ] Update native man page, parameter help, and translation extraction inputs as needed.
- [ ] Check dialog layout, keyboard navigation, labels, and long translated strings.

P5 exit evidence:

## P6 — Java feature parity and compatibility (excluded by user)

- [ ] Add typed Java scaling settings and transform classes using the same contract.
- [ ] Replace string/regex assumptions in Parameters, OptionsDialog, Viewport, and DesktopWindow.
- [ ] Implement all eight modes and identical limits/rounding/scrollbar rules.
- [ ] Preserve legacy `100`, integer percentages, `Auto`, and `FixedRatio` parsing.
- [ ] Implement explicit nearest/bilinear quality selection and deterministic Area resampling.
- [ ] Validate Java2D sampling against fixtures; use the portable resampler where required.
- [ ] Implement bounded rendering/caching and filter-aware damage.
- [ ] Preserve framebuffer locking and Swing event-thread requirements.
- [ ] Port pointer mapping, outside drags, cursor scaling/fallback, and server warps.
- [ ] Apply the same remote-resize and explicit DesktopSize policy.
- [ ] Update zoom step/reset/fit actions and enablement for every mode.
- [ ] Update editable controls and preferences/config persistence, including quality.
- [ ] Add a Java 8-compatible headless test harness under `java/tests`, wired into CMake/CTest and excluded from the production jar.
- [ ] Run shared contract fixtures and cross-client rendering comparisons.
- [ ] Document changed precedence for saved non-100 scaling with RemoteResize enabled.
- [ ] Update Java viewer README and help.

P6 exit evidence:

## P7 — Validation, performance, and release readiness

- [ ] Run and record native unit/integration tests; confirm GTest was found and tests actually ran.
- [ ] Run and record Java headless tests.
- [ ] Run supported sanitizer/concurrency checks for scaled source reads and lifecycle changes.
- [ ] Complete the eight-mode/three-quality matrix on native Windows.
- [ ] Complete the eight-mode/three-quality matrix on native macOS.
- [ ] Complete the eight-mode/three-quality matrix on native X11.
- [ ] Complete Java GUI parity checks on supported Windows, macOS, and Linux desktops.
- [ ] Check windowed, maximized, fullscreen, multi-monitor, and monitor-change transitions.
- [ ] Check Retina, fractional DPI, and mixed-DPI monitor moves.
- [ ] Check mouse, wheel, touch-generated input, view-only, transparent/large/blank cursors, and server warps.
- [ ] Check resize-capable/incapable servers, denied requests, and another viewer changing resolution.
- [ ] Check rapid resizing while dragging, mid-update exposures, minimized restore, and teardown with pending work.
- [ ] Inspect text, grids, photographs, motion, tile boundaries, letterboxes, and both composition paths.
- [ ] Capture pre-change no-scaling performance baseline and post-change identity results.
- [ ] Benchmark 50%, 137.5%, 200%, anisotropic, and 4K-to-1080p scaling for every quality.
- [ ] Record median/p95 render times, input latency, throughput, and incremental memory per platform.
- [ ] Verify no repeatable identity render-time regression above 5%.
- [ ] Verify cache budget and bounded memory across repeated zooming and huge invisible output areas.
- [ ] Establish and meet measured scaled-frame budgets on supported reference hardware.
- [ ] Verify every documented command-line example and persistence round trip.
- [ ] Complete release notes, quality descriptions, resource limits, DPI wording, and migration guidance.
- [ ] Review the final diff for unintended server/protocol or unrelated rendering changes.
- [ ] Record any deferred optimization separately; do not mark required Java parity or correctness work complete prematurely.

P7 exit evidence:

## Completion record

- Implementation/review references:
- Native test evidence:
- Java test evidence:
- Platform/manual test evidence:
- Performance and memory evidence:
- Deferred optimizations:
- Remaining required work:

## Shared macOS continuation — 2026-09-17

See [HiDPI TODO](../hidpi/TODO.md) for the active macOS scope and evidence. Java parity
is excluded by the user; Windows/X11 work is deferred. Shared additions include the
bounded tile cache, fractional backing-pixel pan, tiled oversized cursors, session
source/damage ownership, per-monitor canvas transforms and native fullscreen views.
The opt-in macOS protocol smoke test covers all eight modes × three filters × two
unit policies, plus oversized cursors and resize-policy checks. Interactive input,
physical mixed-monitor checks and end-to-end performance remain release gates.
