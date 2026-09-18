# Full HiDPI support and FLTK upgrade

Rebrand update (2026-09-18): the native fork is now identified as TidyVNC.
See [the rebrand checklist](../rebrand/TODO.md) for implementation and open
migration/packaging/visual gates. Earlier TigerVNC build evidence below remains
historically accurate.

Scope update (2026-09-17): the user has excluded Java parity and deferred Windows/Linux work. Continue implementation and validation for macOS. Cross-platform and Java checkboxes below are retained as deferred history, not gates for this macOS effort. macOS mixed-density fullscreen remains in scope.

Status: implementation in progress; see TODO.md for completed code, evidence, and remaining release requirements. Baseline: `9cb71cda`, inspected 2026-09-17. Track work in [TODO.md](TODO.md). Repository paths below are relative to the repository root; proposed filenames and parameters are identified as such.

Read alongside [the client-scaling plan](../client-scaling/PLAN.md) and [the macOS build findings](../../BUILD-MACOS.md). The current macOS FLTK 1.3.11 build passes 269 unit tests and opens the connection dialog; that is a baseline, not evidence of HiDPI correctness.

## 1. Outcome, scope, and dependency order

Deliver sharp, appropriately sized viewer UI and correct remote-desktop rendering/input on macOS Retina, Windows at integer/fractional DPI, and Linux/X11 at the scale supported by the desktop. Upgrade the native viewer to FLTK **1.4.5** as the initial tested dependency baseline. Require at least that patch release within the 1.4 series; assess later minor series separately instead of accepting them untested.

“Full” means more than enabling a DPI-awareness flag:

- Dialogs, menus, text, icons, scrollbars, overlays, and custom widgets render at the window's current backing resolution.
- Desktop rendering, filtering, clipping, damage, pointer events, cursor images/hotspots, and server cursor warps use consistent coordinate conversions.
- Moving windows between displays, changing system scale, connecting/disconnecting monitors, and entering/leaving fullscreen work without restart or loss of remote input state.
- Both logical-size presentation and true one-source-pixel-to-one-backing-pixel presentation are available and clearly distinguished.
- The eight planned desktop-scaling modes and all three quality modes compose correctly with display DPI, using one resampling step.
- Remote desktop resizing and multi-screen layout requests use an explicit resolution policy, not accidental widget dimensions.
- Build, packaging, regression tests, and platform verification cover the upgrade.

Primary scope is the native FLTK client on macOS, Windows, and X11, including operation through XWayland. A native Wayland viewer backend is a separate project: the current viewer directly uses Xlib, XRender, XInput, and XShm. Do not silently enable FLTK's Wayland runtime during this upgrade. XWayland compositor scaling can impose output-resolution limits beyond the client's control; document them rather than claiming physical-panel pixel identity where it is unavailable.

The Java client does not use FLTK. Include a separate compatibility/audit phase for its HiDPI behavior and the shared desktop-pixel-unit contract, with fixes and tests where needed; no Java-to-FLTK rewrite is proposed. Server applications and protocol extensions are outside scope.

Implement the shared geometry/refactoring portion of the scaling plan before, or together with, HiDPI rendering. Neither project should create a second independent coordinate transform, cursor scaler, or framebuffer owner. During implementation, reconcile the older plan's “FLTK upgrades” non-goal and its pixel-unit/identity statements with this plan. This planning change itself leaves those historical documents intact.

## 2. Findings in this checkout

| Location | Finding / implication |
| --- | --- |
| `CMakeLists.txt` | Explicitly rejects FLTK unless major=1, minor=3. Uses the legacy FindFLTK variables; changing only the version test is insufficient. |
| `.github/workflows/build.yml` | Linux, Windows, and macOS jobs install FLTK 1.3 packages. Test steps currently allow failure; HiDPI release gates must not silently pass failures. |
| `contrib/packages/`, `BUILDING.txt`, `cmake/StaticBuild.cmake` | Package dependencies, build guidance, and hand-built FLTK link flags need migration. |
| `release/Info.plist.in` | `NSHighResolutionCapable` is false. The tested app therefore does not request native Retina backing resolution. |
| `vncviewer/Surface_OSX.cxx` | Screen draw/blend reset the CoreGraphics transform to identity, use FLTK window height for Y conversion, and assume a bitmap color space can be obtained. Audit all three assumptions with FLTK 1.4. |
| `vncviewer/Surface_Win32.cxx` | Uses GDI device coordinates and temporarily replaces global `fl_gc` to reuse its screen-copy method for offscreen copies. Replace that context swapping with explicit target contexts. |
| `vncviewer/Surface_X11.cxx`, `PlatformPixelBuffer.cxx` | Source pixmaps/images and native copy operations use pixel coordinates; widget geometry cannot be substituted directly once FLTK scales it. |
| `Viewport.cxx`, `DesktopWindow.cxx` | Widget size, source framebuffer size, offscreen allocation, damage, scrolling, and pointer mapping assume matching units. The scaling plan already targets this coupling. |
| `DesktopWindow::setCursorPos()` | Adds remote coordinates directly to FLTK/root positions before native pointer warps. This breaks once those coordinate spaces differ. |
| `DesktopWindow::remoteResize()` | Builds RFB dimensions and ScreenSet rectangles from window and FLTK monitor geometry. Requires a shared policy and topology conversion. |
| `Win32TouchHandler.cxx`, `XInputTouchHandler.cxx` | Consume/synthesize native-coordinate events. Conversion must happen exactly once before the ordinary pointer path. |
| `fltk/Fl_Monitor_Arrangement.cxx`, `x11.cxx`, `cocoa.mm`, keyboard backends | Use platform screen/window handles and native monitor geometry; audit beyond the main drawing classes. |
| `fltk/theme.cxx`, dialogs, suggestion widgets | Local metrics are currently based on a 96-DPI font convention. Keep layout in FLTK units and prevent applying scale twice. |
| `java/.../Viewport.java`, `DesktopWindow.java` | Swing scaling and monitor bounds are handled separately; fullscreen code notes DPI-sensitive border assumptions. Verify against the same semantic fixtures. |

## 3. FLTK 1.4 migration

### Dependency and build policy

Pin the initial CI source archive/tag and checksum for FLTK 1.4.5, with a reusable dependency cache keyed by OS, architecture, compiler, linkage, and FLTK options. Use source builds in CI where distro packages cannot provide the baseline; do not guess that an unversioned package is new enough. Developers may use a matching installed package. Retain existing native platform choices and server build options.

Move discovery to FLTK's CMake config package and imported targets, with explicit static/shared selection. Link image support using `fltk::images` or its shared counterpart, allowing its core dependency to propagate. Raise the repository CMake floor to at least 3.15 as part of the supported build recipe, and validate every platform/toolchain. Update `vncviewer/CMakeLists.txt`, `tests/perf/CMakeLists.txt`, and `StaticBuild.cmake` together. Avoid mixing imported targets with the old manually assembled FLTK library string. These choices follow FLTK's [CMake build documentation](https://raw.githubusercontent.com/fltk/fltk/release-1.4.5/README.CMake.txt).

Use fresh build directories: never reuse the known 1.3 cache or overwrite its working app. Verify the linked FLTK version and include paths in configure output and binaries. Preserve `BUILD_VIEWER=OFF` and server-only builds without introducing a mandatory GUI dependency.

### Source migration

Audit explicit includes, platform access, image subclasses, event dispatch, and timers. Replace private FLTK internals with supported APIs, adding a small compatibility adapter only where necessary. Inspect every use of `fl_gc`, `fl_display`, `fl_window`, `fl_xid`, `fl_visual`, `Fl_X`, and `<FL/x.H>`; avoid blindly renaming globals or depending on driver implementation classes. Remove old-version workarounds only after their replacement is tested.

FLTK's migration notes cover changed header dependencies, timer behavior, const image-copy methods, and the danger of running X11-specific code through its hybrid Wayland backend. Force the X11 runtime through FLTK's documented mechanism when linking a hybrid build; an X11-only dependency build is also acceptable. Fail clearly if no supported backend is available. See the [1.3-to-1.4 migration guide](https://www.fltk.org/doc-1.4/migration_1_4.html).

Before opening any display, disable FLTK's built-in keyboard GUI scaling with `Fl::keyboard_screen_scaling(0)`. Reserve existing remote key forwarding and viewer shortcut meanings; system/desktop GUI scale still applies. Do not add another viewer-wide GUI zoom setting in this project. Recompute on explicit runtime scale changes if introduced elsewhere. FLTK documents GUI scale and keyboard behavior in its [screen APIs](https://www.fltk.org/doc-1.4/group__fl__screen.html).

First migration milestone: all existing clients/tests compile and run at 1× before enabling new rendering behavior. Verify clipboard, keyboard grabs, side buttons, gesture timing, dialogs, fullscreen, and slow-update timers as well as rendering.

## 4. Coordinate contract and user-visible policy

### 4.1 Separate four spaces

| Space | Meaning | Examples |
| --- | --- | --- |
| Remote `R` | Server framebuffer pixels, integer bounds | Decode, CopyRect, RFB pointer messages, ScreenSet |
| Logical `L` | FLTK layout/event units, floating-point internally where needed | Window content bounds, widget layout, scrollbars |
| Backing `B` | Actual integer pixels in a particular rendering target | Offscreen bitmaps, destination tiles, pixel-perfect sampling |
| Native screen `N` | Coordinates expected by the specific OS API | Native cursor warps, monitor placement, native touch events |

Introduce proposed `DisplayMetrics.{h,cxx}` plus platform implementations/adapters. A snapshot contains logical client bounds, backing bounds, logical-to-backing mapping, screen identity, native conversion methods, and a generation number. Introduce a small pure `DisplayTransform` helper or extend the scaling plan's `ScalingTransform`; do not maintain competing transforms.

FLTK 1.4's GUI scaling factor and macOS Retina backing factor are distinct. Its documentation explicitly distinguishes FLTK units, drawing units, and pixels. Obtain the **effective target mapping** from documented FLTK/native APIs instead of assuming `Fl::screen_scale()` always equals pixels per logical unit or multiplying by a guessed Retina factor. See [FLTK drawing units](https://www.fltk.org/doc-1.4/drawing.html).

For one axis, describe the composed mapping as:

```text
L = imageOriginL + R * desktopScaleL
B = targetOriginB + L * pixelsPerLogicalUnit
```

The actual implementation must retain target translations and clipping, not just scale factors. Keep forward/inverse mappings in the same snapshot. Native-screen conversion is a separate adapter: never multiply an entire virtual-desktop origin by the scale of whichever monitor contains the window. Use native window/client conversions and per-monitor origins; support negative screen positions.

### 4.2 Explicit desktop pixel units

Add proposed `DesktopPixelUnits=Logical|Device`, default `Logical`, persisted through native/Java options and configuration. This selects the unit used by no scaling, percentages, and exact dimensions; it does not scale the viewer UI or change the server's own text/UI DPI.

| Policy | No scaling / 100% | Exact `1920x1080` |
| --- | --- | --- |
| Logical (default) | One remote pixel per FLTK layout unit; preserve established logical-size behavior | 1920×1080 logical units |
| Device (pixel-perfect) | One remote pixel per local backing pixel | Exactly 1920×1080 backing pixels |

Uniform/independent percentages multiply the respective base unit. Fit/stretch, aspect-fit, fit-width, and fit-height always use the available logical rectangle and produce its required backing raster; their visual result does not change merely because the unit selector changes. Label the selector as inactive for these fit modes, retaining the saved preference.

Example at an effective 2× backing factor, with RemoteResize disabled: a 1920×1080 remote desktop at 100% Logical occupies 1920×1080 logical units and 3840×2160 backing pixels. At 100% Device it occupies 960×540 logical units and 1920×1080 backing pixels. At 150% Device it occupies 1440×810 logical units and 2880×1620 backing pixels. At 1.25×, 100% Device uses a logical extent of 1536×864. These are target-pixel claims, not physical-millimeter guarantees or promises about later compositor scaling.

This extends the scaling plan while retaining its default interpretation and serialized `ScalingFactor` values. Never silently redefine existing saved 100% settings to device pixels. Keep `DesktopPixelUnits` independent of `ScalingQuality` and JPEG quality. Show both logical and backing output sizes in connected-session diagnostics.

### 4.3 Fractional geometry and rounding

Use floating-point/rational image extents internally. The enclosing FLTK widget can have integer bounds, but must not determine the exact drawable image extent. At 1.5×, a one-backing-pixel increment is two-thirds of a logical unit; rounding the image to an integer widget size would destroy pixel identity.

Round backing coverage outward for allocations/damage and use a single documented boundary rule for visible content. Snap pixel-perfect content origins to backing-pixel boundaries. Use destination pixel centers for resampling and one inverse transform for hit testing. Maintain actual raster dimensions separately from requested sizes. Check multiplication/addition overflow and empty/minimized targets. Permit fractional logical pan internally when needed to move by whole backing pixels; this refines the scaling plan's earlier fractional-pan non-goal, without adding smooth pan gestures.

## 5. Rendering, surfaces, and UI assets

### Shared architecture

Retain one connection-owned remote framebuffer in remote pixels. DPI or local zoom never reallocates it or changes decode/CopyRect dimensions. Implement the scaling plan's explicit framebuffer-resize method before changing viewport size semantics.

Make proposed render targets describe both logical bounds and backing storage size, scale, origin, clip, and ownership. Update `Surface` APIs so source rectangles are clearly pixel rectangles and destination coordinates explicitly name their space. Remove implicit dependence on the globally current context for offscreen work. The same target contract must cover direct drawing, offscreen composition, overlays, and software cursors.

Compose DPI and desktop zoom **before resampling**. Render source pixels directly into the final backing-pixel destination using the scaling plan's shared resampler and quality settings. Do not resize to logical dimensions and then let another layer enlarge that bitmap. A blit is valid only when the complete remote-to-backing transform is identity and aligned; logical 100% alone is not an identity test.

Extend the proposed tile/cache keys with display-metrics generation, final backing size, target format, and sampling origin. Invalidate old/new visible bounds on scale changes. Damage starts in remote coordinates, expands for the selected filter, maps to backing pixels, and converts outward to FLTK damage coordinates only at that API boundary. Preserve nonrectangular clips where supplied. Repaint exposures without requiring a fresh server update.

Source reads must obey the synchronization boundary described in the scaling plan. A scale-change repaint or cursor rebuild can occur mid-decode; the existing damage mutex alone is not sufficient. Flush/snapshot through the agreed connection interface before resampling, and harvest newly committed damage before using cache entries.

### Backing-sized composition and resources

Allocate offscreen storage in backing pixels, not `window->w() × window->h()` logical units. Render overlays/text directly at target resolution using FLTK's supported drawing surface/context facilities. Existing `addOverlay()` and statistics rendering create raster `Surface` objects; rebuild them when metrics change instead of stretching old 1× text. Logical margins/font sizes remain unchanged.

Use resolution-appropriate raster assets or supported vector assets for local icons. If using FLTK images, explicitly manage logical display size versus image data size. Audit dialog icons, monitor-arrangement labels, suggestion popups, authentication errors, clipboard dialogs, tooltips, and focus indicators. Keep UI colors and rendering independent of remote-desktop quality settings.

Keep the scaling plan's bounded tile cache and account for backing resolution and CPU/native copies. A 2× surface has four times the pixel area. Use checked allocation arithmetic and a documented compositing budget, initially 128 MiB per view with a session-wide cap of 256 MiB; render in strips/tiles when a full surface would exceed the cap. Native textures/pixmaps and scratch buffers count toward the accounting. Failure should drop caches/retry bounded work or show an explicit error, never leave input mapped to pixels different from those displayed.

## 6. Platform implementation

### macOS

- Change `NSHighResolutionCapable` to true in the packaging template as part of the completed rendering change, not as an isolated release fix.
- Add metrics/native-conversion helpers in `cocoa.mm/.h` using the window/view's actual backing conversion. Detect backing-property changes even if logical size is unchanged.
- Replace unconditional identity-CTM resets in screen `Surface::draw()` and `blend()`. Preserve the provided CTM or reconstruct a verified equivalent mapping, including scale, origin, orientation, and clip; test performance before choosing a fast path.
- Separate bitmap contexts from window contexts and avoid assuming a window CGContext supports bitmap-only queries. Use a defined color-space policy and balanced graphics-state ownership.
- Verify Retina/non-Retina moves, “scaled” display modes, fullscreen/Spaces transitions, and offscreen images. Update app copies and DMGs when testing plist changes; stale bundles are easy to launch accidentally.
- Retain the CLT/toolchain workaround in `BUILD-MACOS.md` if needed. Choose a supported deployment target and matching dependencies separately; the existing macOS 27 build is not evidence of compatibility with older systems.

### Windows

- Verify process/window DPI awareness before any window exists. FLTK 1.4 defaults to per-monitor awareness V2 and adapts to manifest declarations; inspect the final executable and remove conflicting DPI-unaware declarations if present. Do not add a competing late `SetProcessDPIAware()` call. See [FLTK Windows integration](https://www.fltk.org/doc-1.4/osissues.html).
- The inspected viewer resource file has no DPI declaration; manifests under `win/winvnc` belong to the server and must not be mistaken for the viewer's configuration. Add a viewer manifest only if required for the chosen distribution/initialization policy.
- Let FLTK handle its native DPI-change resize lifecycle. Observe the resulting window metrics and invalidate once; do not independently apply the suggested native size a second time.
- Use explicit source/destination HDCs for GDI copies/composition. Destination rectangles use backing pixels, with the logical clip converted consistently. Restore native objects/state on every path.
- Convert native touch/client/screen coordinates at the platform boundary, including wheel events whose native coordinate convention differs from ordinary button events. Use signed intermediates for monitors left/above primary.
- Verify 100%, 125%, 150%, 175%, 200%, and higher scales, mixed-DPI moves, maximization, fullscreen, and RDP reconnect/DPI changes. Preserve the current Windows minimum unless a documented, separately reviewed requirement forces a change; dynamically available DPI APIs need appropriate fallback on older supported systems.

### Linux/X11 and XWayland

- Keep X11 explicit until rendering, keyboard grabs, clipboard, and touch are separately ported to native Wayland. The top-level `ENABLE_WAYLAND` flag currently concerns the Wayland **server**, not the viewer runtime.
- Treat X pixmap/image dimensions and XRender/Xlib rectangles as native pixels. Convert FLTK geometry/clips at the boundary; retain XShm upload lifetime guarantees.
- Audit `x11_win_get_coords()`, maximization heuristics, XWarpPointer, RandR monitor labels, and XInput synthetic events for mixed native/logical use.
- Use FLTK's reported scaling capabilities and the scale actually supplied by the desktop. Support fractional factors when exposed, but do not invent a per-monitor DPI value where X11 supplies one global factor.
- Verify a native X11 desktop and an XWayland session. Record compositor/version/settings when judging sharpness; document any compositor-side resampling. No claim of native Wayland support should appear in the release notes.

## 7. Runtime changes, input, cursors, and topology

Create a coalesced `refreshDisplayMetrics()` path on each view. Trigger it after realization, resize, fullscreen transitions, monitor-configuration changes, and native backing/DPI changes. FLTK's `FL_SCREEN_CONFIGURATION_CHANGED` describes monitor topology and `FL_ZOOM_EVENT` describes GUI zoom processing; neither alone is a universal backing-change signal. Use native notifications and a cheap metrics comparison before drawing as needed. See [FLTK event definitions](https://www.fltk.org/doc-1.4/Enumerations_8H.html).

On a change, preserve the remote point under the viewport center, publish one new transform generation, update fit/layout/scrollbars, recreate scale-dependent surfaces/cursors, and repaint. Fixed Logical modes preserve logical extent; fixed Device modes preserve backing extent. Defer minimized windows. Do not repeatedly rescale previously scaled images or let resize callbacks recurse indefinitely.

FLTK pointer coordinates enter in logical units and map once into remote pixels. Native/synthetic events first enter that same logical path through their platform adapter. Keep pending/throttled positions remote, preserve drag capture and releases over letterboxes or during monitor moves, and keep wheel deltas unchanged. Never DPI-scale the server's coordinate range or keycodes.

Scale original remote cursor images using the composed remote-to-backing transform, including hotspots and alpha. Account for whether the native cursor API accepts logical or pixel sizes. Use the scaling plan's software fallback when limits are exceeded. UI/system cursors follow OS conventions independently. Convert accepted server warps through remote → logical → native screen coordinates while retaining the existing mouse-capture gate; ignore offscreen destinations rather than warping into controls.

### Mixed-density fullscreen

A single native window generally has one backing-scale policy at a time. Its portion on another-density monitor may be resampled by the OS. Support ordinary straddling windows coherently under that native policy and refresh when the owning scale changes; do not advertise simultaneous pixel identity on both displays for such a window.

For full-resolution fullscreen across mixed-density monitors, plan a `DesktopSession`/`DesktopView` separation: one session/framebuffer/input-state owner and one borderless native view per selected monitor, each with its own metrics and remote subrectangle. `Viewport` becomes a non-owning framebuffer consumer; do not call `setFramebuffer()` once per view. Reuse one damage stream, fan it out before clearing, and coordinate input focus/grabs/clipboard through the session so crossing a seam cannot release keys spuriously or duplicate events. Close/hotplug/Spaces transitions must not destroy the shared connection prematurely.

Use one canonical desktop-canvas layout to assign nonoverlapping remote regions to views. In Logical units preserve the normalized logical monitor arrangement; in Device units use device-pixel monitor sizes and deterministic nonoverlapping placement. Prefer a valid native pixel topology where available; if logical adjacency cannot be preserved with unequal pixel dimensions, normalize by monitor order/adjacency, preserve relative direction, and shift overlapping rectangles minimally to an edge. Show the resulting layout in the existing monitor arrangement UI. Validate bounds/gaps/IDs before sending anything to the server. Reuse the same region map for painting and input.

This multi-view work is a required later milestone for claiming full mixed-density fullscreen support on platforms that expose independent backing surfaces. A single-window fallback must be identified as such in interim builds. Respect existing OS restrictions such as macOS separate-Spaces behavior and compositor limitations; never silently claim an unavailable capability.

## 8. Remote resize, settings, and scaling-plan integration

Preserve the scaling plan's policy: non-default desktop scaling suspends automatic remote resizing without overwriting the stored preference. `DesktopPixelUnits` alone does not suspend it when `ScalingFactor=100`.

With automatic RemoteResize active:

- Logical policy requests the usable logical desktop dimensions in remote pixels, preserving established layout density.
- Device policy requests the available backing dimensions in remote pixels, permitting full-resolution server content. A DPI-only transition can therefore trigger one debounced remote resize in this policy.
- Do not send resize requests for unchanged computed dimensions/layout. Keep the existing one-pending-request/rate-limit rules, capability checks, view-only behavior, and denial handling.
- Explicit `DesktopSize` always remains a remote-pixel request. It does not get multiplied by DPI.
- Multi-monitor ScreenSet requests use the canonical view-region layout, translated to nonnegative remote coordinates with valid stable IDs and protocol bounds. They never mix logical offsets with device-pixel widths.
- Unsupported/rejected resizes leave the actual server framebuffer authoritative. Recompute local presentation and allow scrolling/fitting; do not pretend the requested size was accepted.

If the HiDPI work lands before the rest of client scaling, provide the minimal shared transform/resampler and unit selector needed for both policies; do not gate basic HiDPI correctness on all eight mode controls being implemented. Conversely, joint completion must test every scaling mode/quality with both unit policies.

Add the unit selector and explanatory labels to Display/Scaling options, with atomic validation, Cancel semantics, live changes, startup parameters, file/registry persistence, and old-config defaults. Diagnostics should report FLTK version/backend, screen identity, GUI scale, effective backing ratio, logical/backing viewport sizes, remote size, unit policy, and effective desktop transform. Log changes once per metrics generation, not per frame.

## 9. Java compatibility phase (excluded by user)

Audit Java's default Graphics2D transform, image raster sizes, GraphicsConfiguration monitor bounds, native cursor limits, and Robot pointer coordinates on the supported JDKs. Do not apply the OS factor twice to a Graphics2D context that already includes it. The existing Java 8 source target does not itself establish which runtime/platform combinations have complete HiDPI support.

Carry `DesktopPixelUnits` and its default/migration semantics into the Java scaling plan, with shared geometry/serialization fixtures. Fix logical/device mixing, cursor hotspots, monitor transitions, and fullscreen border assumptions found by those tests. Use an explicit supported-JDK matrix and record runtime limitations. Do not change the Java runtime floor implicitly as part of a native dependency update; document and review any necessary floor change before calling Java parity complete.

## 10. Files, milestones, and review boundaries

| Phase | Deliverable / likely files | Exit condition |
| --- | --- | --- |
| H1 | Dependency upgrade: CMake, CI, packaging specs, platform includes/adapters, `BUILDING.txt` | Native builds/tests work at 1× with FLTK 1.4.5 on all three platforms; viewer-off build remains valid. |
| H2 | Coordinate contract: proposed `DisplayMetrics`, shared scaling transform, parameter/UI contract | Pure tests establish units, fractional geometry, inverse mapping, and resize semantics. |
| H3 | Single-view renderer: `Surface*`, `PlatformPixelBuffer`, `Viewport`, `DesktopWindow`, cursor/overlay paths | Correct backing-sized rendering, damage, and input on one monitor in both unit policies. |
| H4 | Platform awareness/transitions: plist, Windows awareness, `cocoa`, `win32`, `x11`, touch/monitor helpers | Live DPI/monitor changes preserve position, image/input alignment, and remote resize policy. |
| H5 | UI/settings/assets and eight-mode integration | Sharp UI, persistence, diagnostics, and all zoom/filter combinations verified. |
| H6 | Mixed-density fullscreen/session-view split | Independent per-monitor rendering, valid topology, single input/session ownership, hotplug handling. |
| H7 | Java audit/parity | Shared contract tested; required fixes and supported-runtime behavior recorded. |
| H8 | Performance, packaging, full matrix, documentation | No outstanding correctness failures; release gates and capability limits documented. |

Keep upgrade-only changes separate from geometry/rendering changes for review. Do not maintain indefinite parallel FLTK 1.3/1.4 implementations. Update the scaling PLAN/TODO during implementation to mark shared work once, with cross-links, rather than duplicating checkboxes as independent work.

## 11. Validation and release gates

### Automated

Add headless tests to `tests/unit/CMakeLists.txt` for logical/backing/native transforms, fractional image bounds, alignment, overflow, zero sizes, negative monitor origins, deterministic topology, screen IDs, and unit serialization. Use scales 1, 1.25, 1.5, 1.75, 2, and 3, odd framebuffer dimensions, and asymmetric desktop percentages. Include fixtures where GUI scale and macOS backing scale differ.

Compare reference full renders with incremental/tiled renders for each quality, source-edge damage, scrolling, exposures, and DPI changes without server updates. Verify 100% Device produces exact source pixels at aligned origins and that Logical mode maps to the computed backing raster without double resampling. Test premultiplied cursors, hotspot rounding, oversized fallback, overlay resolution, and both native direct/offscreen paths.

Instrument protocol output: input maps once, pending remote coordinates survive transitions, outside drags release, wheel/key events retain meaning, explicit DesktopSize remains unchanged, and automatic resize follows the selected unit policy without loops. Test source replacement while views/caches exist, slow-update redraws during decode, multi-view damage fan-out, and one-session teardown.

Retain the original 269-test baseline as a minimum regression reference, not a fixed future total. Exercise actual test discovery. Make relevant CI test failures blocking, including the new tests. Build Debug and RelWithDebInfo, viewer-off configurations, static/shared packaging paths where supported, and native GUI smoke tests. Headless unit tests cannot prove OS DPI correctness.

### Interactive matrix

| Dimension | Required coverage |
| --- | --- |
| macOS | Retina/non-Retina, scaled display modes, single/multiple monitors, separate Spaces settings where supported, fullscreen, hotplug, packaged app |
| Windows | 100/125/150/175/200/300%, mixed-DPI displays, negative origins, maximize/fullscreen, live scale change, RDP reconnect; awareness verified in the running process |
| Linux | Native X11 at 1× and exposed fractional/integer factors, XWayland under a recorded compositor; forced X11 backend verified |
| Viewer windows | Server/auth/options/clipboard/error dialogs, menus/popups/tooltips, monitor arrangement, desktop overlays/statistics |
| Remote rendering | Text, one-pixel checkerboards, diagonals, photos, motion, all eight scaling modes × three quality modes × two unit policies |
| Input/cursors | Mouse, wheel, synthetic touch, remote warps, transparent/blank/large cursors, view-only, drag/key hold across DPI and view seams |
| Lifecycle | Resize, minimize/restore, display move, density-only change, disconnect/reconnect, server resize/rejection, two sessions on different-DPI monitors |

Record effective metrics with screenshots so a sharp UI cannot mask a low-resolution remote surface. Test the same source content at known output sizes; do not infer pixel identity from a screenshot resized by an image viewer. For mixed fullscreen, validate both per-view raster sizes and seam input continuity.

### Performance and memory

Measure the old FLTK 1.3 build and upgraded 1× build on the same hardware. Require no repeatable render-time regression above 5% at identity, or a reviewed explanation/optimization before release. Benchmark 4K and multi-monitor desktops, sparse/full damage, mixed zoom/DPI, and cursor motion. Report median/p95 frame time, input latency, CPU, decoder throughput, and actual allocations; high-DPI work should scale with dirty backing area rather than total remote area.

Verify cache/compositing caps, repeated monitor transitions without leaks, and no full enlarged-frame allocation for invisible regions. Set per-platform frame budgets from measured reference hardware before final sign-off; this plan claims no new benchmarks.

### Packaging and completion

Verify the final app/executable uses the intended FLTK, DPI declaration, resources, and architecture. Test the packaged app, not only an unbundled binary. Preserve supported OS/dependency targets and handle bundling/signing/notarization through existing release procedures. Update `BUILD-MACOS.md`, `BUILDING.txt`, viewer help/man page, translation inputs, release notes, and distro specifications with the new baseline and actual limits.

For the current user-directed scope, completion requires the macOS matrix, both desktop-unit policies, shared scaling integration, and macOS mixed-density fullscreen capability as defined above. Windows/Linux work is deferred and Java parity is excluded. Interim releases must name unfinished capabilities. No success claim should rely solely on a plist change, successful compilation, or a sharp connection dialog.

## macOS implementation notes — 2026-09-17 continuation

`DesktopSession` now coordinates the connection-owned framebuffer and source damage;
`DesktopView` supplies secondary fullscreen windows sharing the primary viewport's
input and clipboard state. `DesktopLayout` uses CoreGraphics display IDs and validates
nonoverlapping logical/device canvases. Fit modes always use the logical canvas, so
changing fixed pixel units cannot change fit output. A failed setup logs and displays
the explicit single-window fallback. Physical mixed-monitor/Spaces validation remains
an exit gate; implementation is not proof of that matrix.

`DesktopTileCache` keeps at most 32 MiB per view and 128 MiB of CPU cache per session.
Native composition retains at most 4 MiB per view, with 256×256 resampling/cursor
scratch. Original framebuffer/cursor storage is separate. Window pan does not change
the sampling origin: cached tiles are anchored at zero in the whole output image.
Allocation failure when storing a cache entry discards the cache and uses the already
rendered scratch tile. Original cursor data is premultiplied and only visible enlarged
cursor tiles are generated; no full enlarged cursor allocation is needed.

Cocoa notifications enqueue one refresh instead of resizing from native callbacks.
The paint path still compares metrics to catch missed notifications. Overlay image
surfaces use explicit target backing dimensions and a bitmap-only Quartz scale:
FLTK 1.4.5's `high_res=1` uses the first window's Retina status, which is insufficient
when multiple windows occupy different-density displays.

Opt-in `tests/integration/macos-scaling-smoke.py` exercises the built viewer with a
local synthetic RFB peer. It checks the scaling/filter/unit matrix, fragmented updates,
source/cursor replacement, automatic/explicit resize policy and denial suppression.
It does not assert physical output or synthesize input; those remain separate checks.
