# TigerVNC client scaling implementation plan

Status: proposed implementation; no viewer code has been changed.

Repository baseline: `f885b340`, inspected on 2026-09-17. Track implementation in [TODO.md](TODO.md). Paths below are relative to the repository root. Names of new classes, files, and settings are proposals.

## 1. Scope and intended behavior

Implement all eight scaling modes and selectable resampling quality in the native FLTK viewer on Windows, macOS, and X11. Bring the Java viewer to the same feature contract in a separate, required parity phase. The native implementation is the primary workstream; Java already has partial scaling and must retain compatibility with its existing settings.

Scaling changes the local presentation of the decoded desktop. Framebuffer allocation, protocol coordinates, encodings, CopyRect, and server screen layouts remain in remote pixels. No server or RFB extension is needed. Preserve the current native rendering path when the effective transform is identity.

Explicit decisions:

- **Automatic fit** stretches the desktop to fill the available client area; horizontal and vertical factors may differ. **Fit preserving aspect ratio** contains the whole desktop with letterboxing. This matches Java's existing `Auto` versus `FixedRatio` distinction.
- Fit modes may enlarge as well as shrink. Fit width and fit height preserve aspect ratio and permit scrolling on the other axis.
- Exact dimensions describe the entire displayed desktop, not the window's outer dimensions, a crop, or a server resolution request. They may distort aspect ratio.
- Arbitrary percentages accept decimal values; they are editable values, not a fixed preset list.
- Remote cursors scale with the desktop. Viewer controls, scrollbars, menus, status overlays, and statistics retain their normal UI size.
- Default behavior stays at no scaling. Scaling quality is independent of JPEG `QualityLevel`, compression, and bandwidth auto-selection.

Non-goals: rotation, fractional pan coordinates, new pinch-to-zoom gestures, server-side scaling, a GPU rendering rewrite, FLTK upgrades, and changing transport/encoding quality.

## 2. Current implementation and integration points

| Area | Observed behavior and required change |
| --- | --- |
| `vncviewer/Viewport.cxx`, `.h` | Creates the server-sized `PlatformPixelBuffer`. `resize()` currently reallocates it whenever widget dimensions change. Both `draw()` overloads copy pixels at 1:1. Split framebuffer resizing from display geometry before adding scaling. |
| `Viewport::updateWindow()` | Takes source damage and adds widget offsets directly. It must map damage through the display transform and filter footprint. |
| `Viewport::handle()`, `handlePointerEvent()`, `sendPointerEvent()` | FLTK positions are currently translated only by the widget origin. Add one inverse mapping before pointer filtering, throttling, and protocol transmission. |
| `Viewport::setCursor()`, `showCursor()` | Copies a server cursor into an FLTK cursor without scaling. Retain source cursor data and rebuild presentation on transform/quality changes. |
| `vncviewer/DesktopWindow.cxx`, `.h` | `resizeFramebuffer()`, `repositionWidgets()`, scrolling, edge scrolling, and cursor warping assume widget size equals remote size. Introduce a single layout result with distinct remote, displayed, and available sizes. |
| `DesktopWindow::draw()` | Supports direct drawing and an offscreen composition path. Both must render the same scaled desktop, while overlays remain in window coordinates. |
| `vncviewer/PlatformPixelBuffer.cxx`, `.h` | Tracks source damage with a mutex. X11 uploads damage to its pixmap in `getDamage()`. That mutex does not protect pixel reads against decoder writes. |
| `vncviewer/Surface*.cxx`, `.h` | Existing operations are unscaled copies/composites: GDI, CoreGraphics, and XRender backends. Their width/height arguments do not constitute a general scaling API. Reuse them to present already-resampled tiles. |
| `vncviewer/CConn.cxx`; `common/rfb/CConnection.cxx` | `framebufferUpdateEnd()` flushes decoders. The viewer's slow-update timer also draws mid-update. `setFramebuffer()` flushes, preserves overlap, and deletes the previous framebuffer. Preserve this ownership contract. |
| `vncviewer/parameters.cxx`, `.h` | No native scaling parameter. `RemoteResize` defaults to true. Only a selected list of GUI parameters is persisted; add scaling parameters to that list. |
| `vncviewer/OptionsDialog.cxx`, `.h` | Display page already contains monitor controls. Add a dedicated Scaling tab to avoid crowding it. Validate before `storeOptions()` invokes callbacks. |
| `CMakeLists.txt`, `tests/unit/CMakeLists.txt` | Native build checks for FLTK 1.3; unit tests use GoogleTest and are added only when GTest is available. Keep new geometry/resampling tests independent of a display server. |
| `java/com/tigervnc/vncviewer/` | `Parameters.java` has `ScalingFactor=100`, `Auto`, and `FixedRatio`. `Viewport.java` handles scaled painting, input, and cursors; `DesktopWindow.java` has zoom actions. Current remote resizing takes precedence over scaling. Audit all string-based assumptions when expanding the grammar. |

## 3. Scaling contract and configuration

Let the remote framebuffer be `Fw × Fh`, the usable local area after scrollbar reservation be `Aw × Ah`, and the final displayed desktop be `Dw × Dh`. All dimensions are positive integers while the window is drawable.

| UI mode | `ScalingFactor` value | Requested display size |
| --- | --- | --- |
| No scaling | `100` (accept `None` as an alias) | `Fw × Fh` |
| Automatic fit (stretch) | `Auto` | `Aw × Ah` |
| Fit preserving aspect ratio | `FixedRatio` | Uniform factor `min(Aw/Fw, Ah/Fh)` |
| Fit width | `FitWidth` | Width `Aw`; height from `Fh * Aw/Fw` |
| Fit height | `FitHeight` | Height `Ah`; width from `Fw * Ah/Fh` |
| Exact pixel dimensions | `1920x1080` | Exactly `1920 × 1080` |
| Percentage | `137.5` or `137.5%` | Factors `1.375, 1.375` |
| Independent horizontal/vertical percentages | `125%x80%` | Factors `1.25, 0.8` |

Reuse the Java parameter name and legacy values in both clients rather than introducing competing mode parameters. Add `ScalingQuality=Nearest|Bilinear|Area`, default `Bilinear`. These are stable serialized tokens; translate only UI labels.

Implement a shared native parser/serializer in proposed `vncviewer/Scaling.cxx`, `.h`, producing typed `ScalingSettings` with an enum and mode-specific data. Port the contract to Java. Runtime layout and rendering must not interpret raw strings.

Parsing and limits:

- Accept case-insensitive named modes, an optional single trailing `%` for uniform percentages, and lowercase or uppercase `x` separators. Strip outer whitespace only; reject internal whitespace and trailing garbage. Canonical serialization uses the values in the table, omitting `%` for uniform percentages.
- Require positive integer dimensions. Both `%` markers are required for independent percentages, so `125x80` unambiguously means pixels.
- Accept percentages from `0.01` through `10000`, with up to two decimal places, parsed as integer hundredths of a percent. Reject zero, negatives, exponents, NaN, infinity, excess precision, missing axes, and overflow. This supports arbitrary user-entered percentages within documented resource bounds.
- Limit computed display axes to `65535` each initially; keep this separate from the remote framebuffer's existing limits. Use checked 64-bit products and `size_t` allocation arithmetic. Never allocate `Dw * Dh` pixels merely because these dimensions are valid.
- Normalize uniform `100`/`100%` to no scaling, preserving the existing default. An exact-size mode remains exact-size even when its current result happens to be identity. Independent percentages retain their mode.
- An invalid UI value blocks OK, marks the field, and preserves all live options. An invalid explicitly supplied command-line value fails startup with a useful diagnostic. Invalid saved scaling settings fall back as a pair to `100`/`Bilinear` with one warning, following existing load error handling.
- If a subsequent server resize makes a previously valid percentage exceed display limits, retain the requested setting but use no scaling temporarily and show one explanatory status message. Re-evaluate it on the next relevant change; do not silently clamp percentages or exact dimensions.

Proposed examples (after implementation):

```sh
vncviewer -ScalingFactor=Auto host
vncviewer -ScalingFactor=FixedRatio -ScalingQuality=Area host
vncviewer -ScalingFactor=FitWidth host
vncviewer -ScalingFactor=FitHeight host
vncviewer -ScalingFactor=1920x1080 host
vncviewer -ScalingFactor=137.5 host
vncviewer -ScalingFactor=125%x80% -ScalingQuality=Nearest host
vncviewer -ScalingFactor=100 host
```

## 4. Geometry, layout, scrolling, and DPI

### 4.1 Separate storage from presentation

Add `Viewport::resizeFramebuffer(width, height)` for server-driven allocation through `cc->setFramebuffer()`. Make the widget's `resize()` change presentation only. Compare source dimensions, not `viewport->w()/h()`, when handling a server resize. Do not delete the old buffer in the viewport; `CConnection` owns replacement/deletion.

Introduce an immutable `ScalingTransform`/`ScalingLayout` result containing source size, displayed size, image origin, drawable clip, effective factors, and scrollbar state. `DesktopWindow` calculates it; `Viewport`, rendering, input, cursor placement, and damage consume the same result. Keep pure calculations in `Scaling.cxx` so they can be tested without FLTK.

### 4.2 Rounding and layout policy

Use integer rational calculations where possible. Fit-both uses floor on the unconstrained dimensions so the result cannot exceed the available area; fit-width/height set the constrained dimension exactly and floor the other. Percentages use round-half-up. Clamp a positive result below one pixel to one pixel. Exact dimensions need no rounding. Derive effective factors from final integer dimensions (`Dw/Fw`, `Dh/Fh`), not the requested percentage. Aspect-preserving modes may differ by at most one destination pixel due to rounding.

Calculate scrollbar state and available area together:

1. Auto and FixedRatio reserve no scrollbars; compute against the entire client area.
2. FitWidth first computes without a vertical scrollbar. If its height overflows, reserve the vertical scrollbar and recompute once. Never introduce a horizontal scrollbar. FitHeight uses the symmetric rule.
3. Fixed-size, percentage, independent-percentage, and no-scaling modes calculate displayed dimensions independently of window size. Start with no scrollbars and monotonically add bars required by overflow until stable, at most two additions.
4. Fullscreen reserves no scrollbar space and hides bars. Keep clamped virtual scroll offsets for overflowing axes so edge scrolling still works. FitWidth/Height can overflow in fullscreen.
5. Center an image smaller than the available area independently on each axis; clamp pan offsets on overflowing axes. Exclude scrollbar tracks and the corner from drawable/input areas.

Preserve the remote point under the available area's center across zoom/mode changes when possible. During ordinary pan, only the origin changes. Recompute fit modes on local resize, fullscreen transition completion, monitor-layout changes, and remote framebuffer resize. Fixed modes keep their requested size. In scaled modes, local layout must not resize the outer window as a side effect; preserve existing unscaled auto-size behavior only for no scaling.

For minimized/zero-area windows, defer computation and drawing; keep the last valid transform and never divide by zero. On restore, compute once and repaint.

“No scaling” means the existing viewer's 1:1 coordinate behavior; exact pixel dimensions refer to the same local drawing units. Do not claim one remote pixel always equals one physical panel pixel under OS scaling. Audit each FLTK 1.3 platform's drawing/event coordinate conversion, especially macOS's existing CTM reset. Apply any logical-to-backing conversion at the platform boundary exactly once. Test Retina, Windows fractional DPI, and mixed-DPI monitor moves; this work does not require changing FLTK versions.

## 5. Rendering and configurable quality

### 5.1 Portable baseline

Implement proposed `ScalingRenderer.cxx`, `.h` and a toolkit-independent `Resampler.cxx`, `.h`. Choose a deterministic CPU resampler as the initial portable implementation so all quality options have defined behavior on all platforms. Native acceleration can be a later optimization after measurements; it is not required for feature completion.

- If `Dw == Fw` and `Dh == Fh`, use existing framebuffer copies for both `Viewport::draw()` overloads. Quality has no effect at identity.
- Otherwise, intersect transformed desktop bounds with the current window clip and render visible destination tiles, initially `256 × 256`.
- Read source pixels with their actual stride and pixel format. Resample each tile using its absolute position in the complete displayed image; never resize an independently cropped dirty rectangle. This avoids tile seams and sampling phase changes.
- Reuse a scratch `PlatformPixelBuffer` as the presentation tile, independent of the connection framebuffer. Write via `getBufferRW()`/`commitBufferRW()`, call its `getDamage()` to upload on X11, and use existing `Surface::draw()` to copy it to the window or offscreen target. Never pass scratch buffers to `cc->setFramebuffer()`.
- Keep tile origin, source sampling origin, and offscreen destination coordinates explicit. Preserve existing clips and platform graphics state. The macOS Y conversion must occur exactly once.
- Cache visible resampled tiles with a hard initial budget of 32 MiB including CPU/native duplicate pixel storage estimates; scratch/intermediate storage is separately bounded. Evict least-recently-used tiles. No full-sized enlarged framebuffer or per-frame unbounded surface allocations.
- Cache keys include source-buffer generation, displayed dimensions, quality, and tile coordinates. Source damage invalidates intersecting tiles; exposure/panning reuse valid tiles. Resize and quality changes invalidate affected generations.
- Allocation failure first drops caches and retries bounded scratch rendering. If even scratch allocation fails, report an error and temporarily use no scaling with matching input/layout, while preserving the requested setting. Never show scaled input over unscaled pixels.

### 5.2 Quality definitions

| Setting / UI label | Required algorithm |
| --- | --- |
| `Nearest` / Nearest neighbor (sharp pixels) | Sample nearest source pixel using destination pixel centers; useful for integer zoom and pixel art. |
| `Bilinear` / Bilinear (smooth) | Separable linear interpolation using destination pixel centers. Fast default for ordinary scaling. |
| `Area` / Area (best for shrinking) | Average source-pixel coverage over each destination footprint on shrinking axes; use linear interpolation on enlarging axes. Handle mixed shrink/enlarge transforms axis by axis. |

Use `sourceCenter = (destinationIndex + 0.5) / scale - 0.5` for nearest/linear reconstruction. Clamp source samples to the image edge. Implement area coverage and linear passes with reusable weight tables and bounded intermediates; avoid a naive repeated scan of the entire source for every output pixel. Document that filtering operates on encoded color components, not linear-light color.

Desktop framebuffer alpha is not meaningful transparency: output opaque pixels. Cursor filtering uses premultiplied alpha to avoid dark/colored fringes. Use the same rounding and filter conventions across native and Java implementations. Do not silently substitute quality modes or change quality while resizing; add an explicit policy only in a later feature if needed.

### 5.3 Decoder synchronization

CPU resampling accesses neighboring source pixels, including outside the original damage rectangle. The damage mutex alone is insufficient. Add a narrow protected synchronization method to `common/rfb/CConnection.h`, `.cxx` that flushes pending decoder work, exposed to rendering by a viewer-level `CConn` wrapper. Do not expose the decoder object itself.

Before scaled update processing reads/uploads source pixels or a scaled draw samples them, quiesce decoder work on the UI thread; do not resume protocol dispatch until synchronous resampling finishes. After flushing, harvest newly committed source damage and invalidate affected cached tiles before serving a draw from the cache. Share this synchronization/damage step between update and expose paths so damage is consumed once and no newly completed decode leaves a stale cached tile. Cover exposure-driven draws, option changes, and the slow-update timer, not only `framebufferUpdateEnd()`. No extra flush is needed when the frame is already known complete. Inspect decoder callbacks for reentrancy and measure the effect on slow-network responsiveness. Do not introduce a background renderer without adding a separate snapshot/ownership design.

## 6. Damage and repaint correctness

Keep decoder damage in remote coordinates. For a changed source rectangle, find every destination pixel whose filter footprint overlaps it, round destination bounds outward, add the current image origin, and clip to the visible image. For nearest this needs no extra reconstruction halo; bilinear includes neighboring source samples; area uses the actual destination coverage interval on shrinking axes. Derive the invalidation bounds from the resampler's support definition, rather than a fixed one-pixel destination expansion.

`Viewport::updateWindow()` should ignore empty damage, invalidate scaled cache tiles, and mark mapped window damage. Retain the current bounding-rectangle behavior initially; sparse-region optimization is separate. Identity rendering keeps its current upload path. Only optimize away X11 source-pixmap uploads after both identity/scaled transitions are proven correct.

Transform, filter, framebuffer, or origin changes repaint the union of old and new visible image bounds and exposed background. Remove old letterboxes, cursor fragments, and stale edge strips. An expose event must repaint correctly even without a new server update. CopyRect remains a source-space operation; invalidate its resulting destination damage normally.

## 7. Input and cursor behavior

### 7.1 Pointer mapping

Convert local window coordinates to image coordinates by subtracting the current image origin (which already includes letterboxing/panning), then map once to remote coordinates. For nonnegative image coordinates use `floor(imageX * Fw / Dw)` and the corresponding Y expression, with checked intermediate products, then clamp to `[0, Fw-1] × [0, Fh-1]`. This edge-based mapping retains existing identity behavior; subpixel round trips are necessarily approximate when shrinking.

Apply this in one helper before `EmulateMB` and pointer throttling. Store pending/throttled positions in remote coordinates so a later zoom cannot reinterpret them. Include mouse move, down/up, dragging, wheel press/release pairs, leave events, and touch-generated pointer events. Wheel deltas/button masks remain unchanged.

Do not send clicks or wheel events initiated on letterboxing, scrollbars, or outside the desktop. A drag begun on the desktop continues with edge-clamped coordinates when outside; always send its release to avoid stuck remote buttons. Preserve intentional leave-event behavior. On remote resize, clamp pending remote coordinates to the new framebuffer bounds before sending them.

### 7.2 Cursor presentation and server warps

Scale server cursor size and hotspot per axis from original cursor data whenever the transform or quality changes. Enforce a minimum 1-pixel image and clamp hotspots to valid pixels. Repeated zoom changes must never resample an already-resampled cursor. Keep the existing blank, dot, system-cursor, and view-only policies; synthetic dot/system cursors may retain their normal local size.

Audit platform cursor-size limits. Use a software cursor fallback when the scaled server cursor cannot be represented by the native cursor API, hiding the native cursor over the image. Composite it after the desktop and before viewer overlays, and invalidate old/new cursor bounds on movement and changes. Include the resource cost and a bounded allocation check; very large software cursors should render clipped tiles rather than allocate their entire scaled image.

`DesktopWindow::setCursorPos()` must map the remote pixel center through the forward transform, then add window/root coordinates before native warping. Preserve existing acceptance policy. Ignore warps to offscreen remote points instead of warping into viewer controls or another monitor. Software cursor tracking must use the same remote position and transform.

## 8. Interaction with remote resizing

Native `RemoteResize` defaults to true, so scaling cannot simply be layered onto the current unconditional resize path. Adopt this explicit policy in both viewers:

| Selected scaling mode | Automatic window-driven server resizing |
| --- | --- |
| No scaling (`100`) | Preserve stored `RemoteResize`, including capability and view-only checks. |
| Any other scaling mode | Suspend automatic remote resizing; only local presentation changes. |

Do not overwrite the user's stored `RemoteResize` preference. Explain in the Scaling tab that it is suspended while scaling is selected; switching back to no scaling restores it. A temporary no-scaling fallback for an invalid/failed rendering request does not reactivate remote resizing.

Split the one-time explicit `DesktopSize` request from window-driven resize logic. Preserve its existing `RemoteResize`, capability, and view-only gates, but permit that explicit request even with a scaling mode selected. Calculate its requested remote size directly from `DesktopSize`, never from a scaled widget. After the server responds, recalculate local scaling from the actual accepted framebuffer size. Rejected requests must not prevent local scaling.

Handle already-pending remote requests and resize timers when changing modes: cancel unsent automatic work, accept any in-flight response, and do not send another automatic request from `setDesktopSizeDone()` while scaling is active. Keep rate limiting and fullscreen transition handling intact. Other clients and the server may still resize the framebuffer at any time.

This intentionally changes Java's existing precedence, where `RemoteResize` disables scaling. Document the migration: a saved non-100 `ScalingFactor` now takes effect even if `RemoteResize` is true; reset it to `100` to retain automatic server resizing. Preserve legacy parsing of `100`, integer percentages, `Auto`, and `FixedRatio`.

## 9. Options, persistence, and documentation

Add a Scaling tab with an eight-choice mode selector, appropriate dimension/percentage fields, a quality selector, and a read-only effective-size summary when connected. Show only relevant input fields, label horizontal/vertical axes, and include clear text that Auto and exact dimensions may distort aspect ratio. Offer percentage presets as editable suggestions. Preserve inactive field values while the dialog is open, but serialize only the active mode.

Validate all option changes into a temporary settings object before modifying any global parameter or invoking callbacks. OK commits once, updates layout/cursor/cache, and redraws without reconnecting; Cancel changes nothing. A quality-only change must not resize the server or alter window/pan geometry. The options callback must also apply settings before connecting.

Register `ScalingFactor` and `ScalingQuality` in native parameter declarations and the persisted `parameterArray`; use the existing file/registry machinery. Cover saved defaults, connection files, startup arguments, and the repository's existing precedence rules. Add `ScalingQuality` to Java's persistence list. Old files without settings retain default behavior; never serialize translated strings. A short read-only diagnostic should show requested mode, actual displayed dimensions, effective X/Y percentage, and selected quality.

Update `vncviewer/vncviewer.man`, Java's viewer README/help and parameter descriptions, release notes in the project's normal location, and translation extraction inputs as needed. Explain pixel units, mode semantics, validation limits, quality versus JPEG quality, remote-resize precedence, and all examples above. Do not hand-edit translated messages for languages not maintained by the implementer.

## 10. Java parity

Add proposed `ScalingSettings.java` and `ScalingTransform.java` and replace scattered string/regex mode decisions in `Parameters.java`, `OptionsDialog.java`, `Viewport.java`, and `DesktopWindow.java`. Keep existing zoom menu/keyboard actions: stepping from a fit/exact/anisotropic mode switches to a uniform percentage based on effective X scale, clamped to configured bounds; reset returns to `100`, and fit returns to `FixedRatio`. Update enablement for the new remote-resize policy.

Use the same geometry and parser fixtures as native. Preserve Swing event-thread rules and synchronize framebuffer access using the existing image lock. Use explicit Java2D interpolation selection for nearest/bilinear only after validating the sampling convention; implement a deterministic bounded resampler for Area, and use the portable Java implementation for any mode where Java2D cannot meet the contract. Use tolerance-based cross-client image comparisons where platform color conversion affects output.

Port filter-aware damage, inverse pointer mapping, server cursor warps, cursor scaling/fallback, scrollbar layout, and resize precedence. Update preferences/config saving and make editable options round-trip new values. The current tree does not expose a Java unit-test suite in the inspected paths: add a headless test harness under `java/tests` and wire it into CMake/CTest, keeping tests out of the production jar and compatible with the existing Java 8 source target. Interactive cursor/window tests still require a GUI.

## 11. Implementation sequence and deliverables

| Phase | Deliverable | Dependency / exit condition |
| --- | --- | --- |
| P1 | Contract, typed parser, geometry/transform helpers, pure tests | Eight modes, limits, rounding, scrollbars, and serialization are unambiguous and pass fixtures. |
| P2 | Separate remote framebuffer from widget geometry | Existing no-scaling sessions behave unchanged; local widget resize cannot replace the remote buffer. |
| P3 | Bounded renderer, quality modes, synchronization, damage | Both native draw paths work on Windows/macOS/X11, with no seams or stale pixels. |
| P4 | Input, cursor, layout, fullscreen, remote-resize integration | Coordinates and button state remain correct through scale/size transitions. |
| P5 | Native controls, persistence, help | All eight modes and quality work before and during a connection, without reconnecting. |
| P6 | Java parity and migration | Same contract and fixtures; legacy values and zoom actions work. |
| P7 | Cross-platform validation, performance, release documentation | Acceptance matrix completed and no unresolved correctness failures. |

Keep each phase reviewable. Add new native sources to `vncviewer/CMakeLists.txt`; register geometry/resampling tests in `tests/unit/CMakeLists.txt`, and performance workloads in `tests/perf` using its existing conventions. Restrict common RFB changes to the synchronization hook unless investigation proves another change necessary. Platform `Surface` changes are optional optimizations, not prerequisites for the portable renderer.

## 12. Verification and acceptance criteria

### Automated coverage

- Table-driven parsing/serialization for every mode, decimals, aliases, malformed values, overflow, bounds, and saved-setting fallback.
- Geometry fixtures for odd dimensions, single-pixel axes, tiny windows, large dimensions, portrait/landscape, all scrollbar combinations, zero-area deferral, and all eight modes.
- For `1920×1080` into `1000×800` without scrollbar reservation: Auto gives `1000×800`, FixedRatio gives `1000×562`, FitWidth gives `1000×562`; FitHeight begins at `1422×800` and recomputes its height if a horizontal scrollbar must be reserved. Uniform `137.5` gives `2640×1485`; `125%x80%` gives `2400×864`; exact `800x600` gives `800×600`.
- Transform tests at corners, pixel centers, letterbox boundaries, negative pan offsets, and after resize. Verify clamping, monotonicity, identity mapping, and mathematically bounded round-trip error under shrinking.
- Golden tiny-image tests for each quality, mixed-axis scaling, edges, opaque desktop output, transparent cursor filtering, and strided source buffers. Constant-color images remain constant.
- Compare a full repaint with incremental updates for individual pixels, adjacent rectangles, source edges, tile boundaries, CopyRect, filter changes, and pans. Final pixels must agree with the full reference render.
- Instrument/fake protocol output to prove scaling sends no automatic SetDesktopSize, emits valid pointer coordinates, releases outside drags, and handles an in-flight resize without a feedback loop.
- Test cache eviction/invalidation, allocation failure, display-size fallback and recovery, minimized restore, and teardown while timers or pointer events are pending.
- Exercise slow-update callbacks and exposure drawing while decoder jobs are pending; use sanitizer builds where supported. Test the synchronization boundary, not just the geometry helper.
- Native GoogleTest/CTest and Java headless fixtures must actually be discovered and run; a build that silently omits GTest is not sufficient validation.

### Interactive matrix

Test native Windows, macOS, and X11 plus Java on each supported desktop platform. Cover all modes and qualities, windowed/maximized/fullscreen, one and multiple monitors, Retina/fractional/mixed DPI, mouse/wheel/touch-generated input, view-only, blank/large/transparent cursors, and server pointer warps. Include a server with resize support, one without, a denied explicit resize, another viewer resizing the server, and rapid local/server resizing while dragging.

Use text, grids, diagonals, photographs, moving windows, scrolling terminals, and cursors on image edges. Inspect both direct and offscreen composition paths, overlays, exposed letterboxes, nearest-neighbor integer zoom, and substantial downscaling with Area. Confirm saved options after restart and documented command-line precedence.

### Performance and resource gates

Capture baseline native no-scaling CPU/frame time before changes. Measure identity, 50%, 137.5%, 200%, anisotropic, and 4K-to-1080p rendering with each quality, using full-motion and sparse-damage workloads. Record median/p95 render time, input latency, decoded throughput, and incremental memory per platform; compare on the same machine and build type.

Identity must avoid the resampler/cache and show no repeatable regression above 5% in render time. Extra scaling cache stays within its budget; memory must not grow with invisible enlarged desktop area or repeated zoom changes. Set platform-specific scaled-frame budgets from measured supported hardware before sign-off; report missed budgets and optimize weights, tiles, or native upload paths without weakening output correctness. No benchmark result is claimed by this planning work.

Completion means all eight modes, every advertised quality, input/cursor correctness, persistence, and resize policy are verified in both viewers; the checklist records evidence and any explicitly deferred optimization. Native-only completion must be described as such until Java parity is done.
