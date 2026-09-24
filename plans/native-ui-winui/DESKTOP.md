# Desktop presentation, input and displays on Windows

Recorded 2026-09-23. Phases W3 (first working view) and W6 (fidelity). The
shared rules are in the macOS plan §8, [CANVAS.md](../native-ui/CANVAS.md),
[FULLSCREEN.md](../native-ui/FULLSCREEN.md) and the scaling plan: the core owns
frame leases, damage, the transform, the resampler, the tile cache, the cursor
sampler and input policy. This document covers how Windows presents and feeds
them.

## 1. Rendering pipeline (DECISIONS.md D11)

```text
core frame lease (immutable, damage, generation)
  └─ render worker (one per desktop view, off the UI thread)
       ├─ tidyvnc_renderer_render → scaled CPU tiles at device resolution
       ├─ helper: copy changed tiles into a persistent D3D11 texture
       ├─ helper: CopyResource into the current back buffer
       └─ helper: Present1 with dirty rectangles
SwapChainPanel (XAML) ← flip-model DXGI swap chain for composition
```

- **Swap chain.** Created with `CreateSwapChainForComposition`,
  `DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL`, BGRA8, two buffers, associated with the
  panel through `ISwapChainPanelNative` on the UI thread. Its size is the panel's
  size in physical pixels (`ActualSize × CompositionScaleX/Y`), and
  `IDXGISwapChain2::SetMatrixTransform` applies the inverse composition scale so
  one swap-chain pixel is one screen pixel.
- **Pixels match macOS.** The core's tile renderer does all scaling and filtering
  (all eight modes; nearest, bilinear, area), so the image is the same one the
  macOS app draws. The identity fast path uploads the original frame without
  resampling. No GPU filtering in this plan, as Metal was deferred on macOS.
- **Damage.** Only tiles covered by mapped damage are rendered and uploaded; the
  persistent texture keeps everything else. A skipped frame is allowed only when
  the next lease carries merged damage, exactly the macOS rule.
- **Threads.** The Direct3D device is created per render worker (or with
  multithread protection, if the spike shows that one device is cheaper); the
  immediate context is never shared across threads unprotected. Presents happen
  on the render worker, which is allowed for composition swap chains; resizes are
  requested by the UI thread and applied by the worker between frames.
- **Budgets.** One active and one pending render job per view, as on macOS. A
  detached view frees its leases and Direct3D resources. Session close joins the
  worker.
- **Device loss.** `DXGI_ERROR_DEVICE_REMOVED`/`RESET` recreates the device and
  swap chain and re-renders the full frame; a repeated failure shows the macOS
  presentation-issue recovery text.
- **Letterboxing** is cleared to opaque black in the swap chain, not left to the
  XAML background.
- **Secure desktop and remote sessions.** Presentation errors while the
  workstation is locked, during a UAC prompt, or while the viewer itself runs
  inside a Remote Desktop session that reconnects at a new size or DPI are
  tolerated and recovered from, as `Surface_Win32.cxx` tolerates them today.

## 2. DPI and units

- WinUI 3 processes are per-monitor DPI aware (v2). The app manifest declares it
  anyway, with `longPathAware`.
- **Logical units** are effective pixels (1/96 inch at 100% scale); **device units**
  are physical pixels. The panel reports its scale through `XamlRoot.RasterizationScale`
  and `CompositionScaleChanged`; a change republishes geometry to the core the same
  way a macOS backing-scale change does.
- **Fractional scales.** Windows commonly runs at 125%, 150% and 175%; macOS
  only at 1× and 2×. The shared transform supports fractional scale, but W6 tests
  every mode and filter at 125%, 150% and 175%, including pan positions and inverse
  input mapping at non-integer scales, and a window dragged between monitors of
  different scale. The retained default (100% in logical units) upscales the remote
  image on a 150% display, as FLTK does; Help explains when to choose device units.
  Defaults do not change.
- Controls, overlays and the status bar stay at normal UI size; only the remote
  image follows desktop scaling.

## 3. Cursor (DECISIONS.md D13)

- The core's cursor sampler produces the scaled cursor image and hotspot for the
  view's current transform, as on macOS.
- Up to the largest size Windows accepts for the display (checked with
  `GetSystemMetrics(SM_CXCURSOR)` and the scale), the helper builds an `HCURSOR`
  with `CreateIconIndirect` and shows it while the pointer is over the view.
  Cursors are cached per shape and scale and destroyed when replaced.
- Larger cursors, and the fallback if the spike cannot set a real cursor on the
  WinUI input window, are drawn as software cursor tiles with the system cursor
  hidden over the view, using the macOS clipping and motion-reuse rules.
  *As built (W6.3):* the view draws the core's 256-pixel tiles as bitmaps in a
  layer above the swap chain panel, on the device-pixel grid, clipped to the
  visible desktop. They are not composited into the presenter's frame, so
  desktop updates never redraw them. Over the letterbox the system arrow shows.
- Empty or invisible remote cursors follow the fallback policy (hidden, dot or
  system arrow). View-only shows the system arrow, as on macOS.

## 4. Pointer, wheel and pen

- WinUI pointer events on the view (`PointerPressed/Moved/Released/Canceled`,
  `PointerWheelChanged`, `PointerCaptureLost`). The view captures the pointer
  while any button is down, so drags that leave the view keep working.
- Buttons: left, middle, right, X1 and X2 map to the retained RFB button bits.
  Vertical and horizontal wheel deltas accumulate to whole notches (120 units),
  with high-resolution wheels and precision touchpads producing partial deltas
  that carry over.
- Coordinates go through the shared inverse transform from panel effective
  pixels, converted once at one tested boundary, as on macOS.
- Pen input behaves as a mouse (tip = left, barrel = right, eraser ignored).
- Middle-button emulation and pointer-event timing are the core's; they only
  need the raw events.

## 5. Keyboard (DECISIONS.md D12)

**Path.** While a desktop view has keyboard focus, a `WH_GETMESSAGE` hook on the
UI thread takes keyboard messages addressed to that window's input window before
XAML dispatches them, passes them to the translator, and turns them into
`WM_NULL`. When the desktop does not have focus, the hook does nothing and normal
XAML keyboard handling, accelerators and access keys apply. The W0.4 spike
compares this with XAML routed events before it is final.

**Translation** is extracted from `vncviewer/KeyboardWin32.cxx` into
`platform/windows/Native/Keyboard*` as FLTK-independent C++ with the 100 ms AltGr
timeout driven by an injected clock:

- Scan codes become QEMU key codes (the extended bit sets 0x80), with the Pause,
  Num Lock, Break and SysRq fix-ups.
- Keysyms come from `ToUnicodeEx` with the foreground layout, preserving dead-key
  state the way the retained code does.
- AltGr: a left Ctrl followed within 50 ms by a right Alt is merged into
  `ISO_Level3_Shift`; `hasAltGr` probes each layout once.
- `VK_PACKET` input (touch keyboard, emoji panel, some IMEs) becomes keysyms,
  including surrogate pairs.
- Japanese and Korean IME keys get their synthetic releases; the Shift-release
  workaround and the touch-keyboard Alt scan code fix are kept.
- Lock-key LED state is synchronized with the remote side as the retained viewer
  does, ignoring the viewer's own `0xaa` synthetic events.

The retained FLTK viewer keeps its own copy until cutover. A table-driven test
feeds the same message sequences to the old and new translators and requires
identical RFB output.

**Shortcut classification** stays in the core's shortcut state (shared with
macOS). The translator hands it modifier state after AltGr merging, so AltGr
cannot trigger the Ctrl+Alt chord (UX.md §7).

**System keys.** With keyboard capture active, the `WH_KEYBOARD_LL` hook
(SERVICES.md §8) takes Alt+Tab, the Windows key, Alt+Esc, Ctrl+Esc and similar,
and posts them to the view, as `win32.c` does. Without capture those keys keep
their Windows meaning. Ctrl+Alt+Del and Win+L can never be captured; *Send
Ctrl+Alt+Del* in the Connection menu covers the first.

**Release-all** on focus loss, window deactivation, capture revocation, session
lock, suspend, disconnect and close, handled by the core's input queue.

**IME.** The desktop view is not a text control, so no IME composition runs for
it; IME mode keys are forwarded as keys. The input spike checks Japanese, Korean
and Chinese IMEs active in another control while the desktop is focused.

## 6. Touch

The retained viewer turns touch gestures into mouse and keyboard events through
a shared gesture model (`vncviewer/BaseTouchHandler.cxx`), fed on Windows by
`WM_GESTURE` in `Win32TouchHandler.cxx`. The WinUI app keeps the same gesture
meanings, fed by WinUI pointer and manipulation events on the view:

| Gesture | Remote event (retained `BaseTouchHandler`) |
| --- | --- |
| One-finger tap | Left click at the touch point |
| Two-finger tap | Right click |
| Three-finger tap | Middle click |
| One-finger drag | Left-button drag (after the retained 50-pixel single-pan threshold) |
| Long press, then drag | Right-button drag |
| Two-finger drag | Wheel buttons 4–7 (vertical and horizontal scroll) |
| Pinch | Ctrl held with wheel up/down |

The gesture-to-event logic has no FLTK dependency beyond its event types, so W6
either extracts it for shared use or reproduces it with a table-driven test
against the retained class. Touch coordinates are converted exactly once (the
HiDPI plan's rule). The touch keyboard is reachable from the fullscreen
connection bar. Touch is Windows-only; it is a Windows PARITY row, not a macOS
gap.

## 7. Fullscreen and multiple monitors (DECISIONS.md D14)

- **Modes.** Current display, all displays and selected displays, with the macOS
  selection, fallback and "missing ID" rules (FULLSCREEN.md "Selection and
  windows").
- **Current display.** The connection window's `AppWindow` switches to
  `FullScreenPresenter`; the title bar, menu, toolbar and status bar are
  collapsed and the desktop fills the display.
- **All or selected displays.** One borderless owned window per display
  (`OverlappedPresenter` with no border or title bar, sized to the display's full
  bounds, above the taskbar), each with its own `SwapChainPanel` bound to the
  shared canvas via `tidyvnc_desktop_canvas_geometry`. The source window hides
  while they are active, as on macOS. Each surface renders at its own monitor's
  scale.
- **Transitions.** Entering releases held input and capture, preflights the whole
  canvas, creates hidden surfaces, then shows them; failure leaves the original
  window visible. Exits restore windowed geometry and command routing. A
  topology change (display added or removed, arrangement or scale changed) exits
  full screen rather than continuing with stale geometry; a work-area change alone
  does not. The macOS 15-second transition deadline is kept for asynchronous
  steps.
- **Focus.** Moving the pointer into another surface makes it the key surface
  and releases the previous surface's held input, as on macOS.
- **Connection bar and dialogs.** See UX.md §7.
- **Automatic remote resize.** The complete display layout is submitted from the
  owned surfaces, with the macOS coalescing and ownership rules
  ([REMOTE-RESIZE.md](../native-ui/REMOTE-RESIZE.md)).
- **Startup and reconnect.** Saved fullscreen policy and guarded reconnect
  restoration behave as on macOS.

## 8. Window placement

`geometry` and `Maximize` from the command line set the initial placement of the
first window through `AppWindow.MoveAndResize` and `OverlappedPresenter.Maximize`,
using the shared geometry parser, once, before automatic fullscreen, and never
again after the user moves the window (the macOS `NativeWindowStartupPolicy`
rules). Ordinary window positions are saved in `window-state.json`, separate
from settings, and restored only onto displays that still exist.

## 9. Performance measurement (W6)

- Port `tests/perf/viewer-workloads.py` to Windows: idle, full 1080p, full 4K and
  scrolling workloads at an offered 30 updates per second through a loopback
  scripted peer, for both the FLTK (GDI) and WinUI executables on the same
  machine.
- Measure CPU, working set, sustained update rate, allocation rate, damage size
  and decode-to-present latency p50/p95. Present timing comes from PresentMon or
  ETW (`Microsoft-Windows-DxgKrnl`) plus a presenter probe equivalent to the macOS
  `native-presentation-probe`.
- Apply the macOS provisional budget: reject a regression of more than 10% in
  p95 latency, CPU or retained memory against FLTK on the same workload unless
  reviewed with a measured benefit.
- Repeat on a mixed-DPI two-monitor setup and on ARM64 hardware when available;
  keep those gates open until run.
