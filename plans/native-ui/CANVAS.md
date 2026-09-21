# Native shared desktop canvas

Per-monitor fullscreen surfaces must show regions of one desktop transform. The
native view now supports that region mapping; fullscreen window ownership and
policy are not yet implemented by this step.

## Shared geometry boundary

CANVAS_GEOMETRY (2147483648), required by NativeRuntime, adds
`tidyvnc_desktop_canvas_geometry` and `tidyvnc_desktop_canvas_damage`. There are
**82** `tidyvnc_` exports. The feature uses an unsigned 64-bit macro so strict C
consumers do not require out-of-range enum constants. Existing public structs and
windowed geometry entry points are unchanged.

The new `tidyvnc_canvas_viewport` describes a canvas and one positive enclosed
region, each bounded by 65535. Inputs are checked before coordinate arithmetic;
null pointers, bad headers, invalid dimensions, nonfinite points/pan and out-of-range
damage fail with unchanged outputs. Calls are stateless, thread-safe value operations
with no OS objects, handles or session state. Both old and new entry points share
the same output helpers and the retained C++ `DesktopTransform` implementation.

Canvas dimensions/region/pan use the selected logical or device units. The transform
fits the entire canvas, translates its image into the monitor region and maps local
logical pointer coordinates through that same transform. Damage/filter halos use
that exact placement too. Native pan limits use the full canvas, rather than stopping
at the edge of one monitor. Identity sampling is preserved for device-pixel canvases
across 1×/2× display seams. The native fullscreen owner must choose logical layouts
for fitting modes to match the retained fullscreen policy; this low-level API also
accepts explicit device-unit fitting for callers that choose it.

## Native presentation

`NativeDisplayLayout` retains its unit choice and produces validated
`NativeCanvasViewport` values by stable display ID. A viewport owns no display or
session objects. `NativeGeometry` uses it for image placement, inverse pointer and
damage mapping. Its unit choice overrides the normal window sizing units while the
canvas is installed, preventing a region from being interpreted in another unit.

`NativeDesktopView.setCanvasViewport` validates a candidate transform and visible
tile budget before changing the canvas/pan intent. Clearing it restores normal
window sizing. The existing asynchronous renderer publishes the new geometry with
its pixels; a delayed region change leaves input mapped to the pixels still shown.
The view uses the same global transform for cursor scale and its existing local
cursor clip. Only visible global image tiles are requested. No per-monitor remote
framebuffer or duplicate Swift scaling algorithm is introduced.

A canvas view detaches its automatic window-resize source and cannot claim that
source when binding or attaching to a window. Its local region is never advertised
as the desired size of the entire server desktop. Clearing the canvas reattaches
normal window-following behavior. The eventual fullscreen owner will submit the
complete mapped layout through its own coordinated policy path.

## Evidence and remaining work

Pure C tests cover global fitting, exact device identity, translated pointer/damage,
pan clamping, invalid regions, integer extremes, nulls, bad headers and unchanged
failure outputs. Native tests exercise all eight modes, logical/device units,
fractional backing scales, shared pan bounds, damage halos and exact mixed-density
seams. Two AppKit surfaces display distinct source quadrants and send corresponding
pointer coordinates to a loopback peer. A gated renderer proves old pixels/input
remain coherent until the new region is ready. Tests also cover source damage,
invalid candidate preservation, clearing, pending close and resize-source ownership.
Displayed-color assertions allow the observed macOS display-profile round trip;
geometry and wire-coordinate assertions remain exact where the shared rounding
permits exact values.

This is not proof of physical fullscreen/Spaces, physical keyboard capture across
windows, automatic fullscreen resizing or persisted display policy. A fullscreen
window-owner prototype now manages dedicated windows and bounded transition rollback
(see [FULLSCREEN.md](FULLSCREEN.md)). It still needs physical strategy comparison,
app command/sheet integration, actual topology re-entry policy and complete-layout
resize requests. Those
N4.8/N5.7 gates remain open. Interactive CUA access failed again at its native transport, independently
of whether the Mac is locked.

## Scoped focus and command ownership

NativeSession now records the UUID of the native surface holding focus. Every native
view focus gain uses that route. Transfer releases the old remote held keys/buttons,
publishes a false/true focus interval (invalidating clipboard work), clears old
local input/composition/capture, then admits the new surface. Blur, hide, window
close and detach can revoke a scoped interval only when their token owns it.
Deferred view destruction also checks that token, so it cannot revoke a surface
that acquired focus while cleanup was queued. Generation change, disconnect,
explicit global focus loss and close clear the token. Closing sessions reject gains.

Pointer, key, wheel, IME and shortcut routing reject a surface when another native
surface owns focus. Capture/status/modifier notifications are also scoped to the
active command host. Command hosts are weakly registered; adding a background view
does not steal the active target. Focus activates its host, and detach chooses a
remaining registered surface without acquiring remote focus. Explicit focus actions
refresh eligibility even if AppKit already considers the view first responder.
Hidden surfaces cannot acquire input through a command.
Unchanged focus/owner callbacks do not publish redundant session state or schedule
command recovery, keeping frame delivery independent of SwiftUI invalidation.

The public `setFocused` API remains available for consumers that do not use native
view ownership. Explicit unscoped focus retains its previous live-view blur
behavior. This compatibility path intentionally has no exclusive surface identity;
native focus gains always install one. Deferred destruction never revokes unscoped
focus. Global revocation still clears any native owner and capture synchronously.

A two-view loopback test checks held input release, stale input suppression, capture
and IME cleanup, background hide/render/close, focus-driven window command dispatch,
weak lifetime cleanup, replacement-owner preservation, reconnect/close and session
isolation. Capture and fullscreen commands use injected backends/window spies; they
do not alter the user's foreground app or prove physical capture/Spaces behavior.
The fullscreen owner must still coordinate surface transitions and whole-layout
resizing, including pointer-driven focus policy across real monitors.

## Shared canvas coordination

`NativeDesktopCanvas` associates weak native view references with a complete set of
display snapshots for one session and its scaling state. `configure` checks distinct
views, session ownership, shared display mapping, candidate geometry and visible
tile budgets before changing any member's intent. An invalid selection/topology or
one rejected surface leaves the previous layout, pan and membership intact. Direct
region replacement on a managed view is rejected; direct per-view scale/unit/filter
writes are restored and reported through the view's error callback. Scaling changes
must use the shared state. The owner supplies the next complete arrangement.
Detach/destruction leaves surviving monitor coordinates in
place until the next explicit configuration, rather than silently reflowing them.

Scaling state now weakly registers every view instead of validating only the last
attachment. Apply preflights all independent views and each coordinated group once
before changing revisions, per-field sources or the published value. Coordinated
surfaces receive scaling/filter/region intent together. Fitting modes use logical
monitor geometry; other modes honor device units through the retained mixed-density
mapper. Geometry/unit changes reset shared pan; filter-only changes preserve it.

Pan commands or direct pan changes from a member route through the coordinator.
It validates all members before distributing one offset. Current session frame
dimensions determine the common bound, independent of individual image-subscriber
order. Remote shrink clamps discarded offsets, and later growth cannot restore
them. Disconnect resets pan. Each view retains its existing asynchronous publication
contract: its new pixels and inverse input geometry become visible together. There
is no atomic multi-window pixel-presentation barrier.

Group and scaling registrations do not retain views. Stopping, session close or
group destruction restores ordinary window geometry. Deferred destruction checks
an owner UUID before clearing a view, protecting a replacement coordinator. These
operations do not create windows or choose which window should own resize/focus
after a fullscreen transition; that responsibility remains with the fullscreen
owner. The window-owner prototype uses the coordinator; the native app fullscreen
command has not yet been switched to it.

`NativeDesktop.SharedCanvasCoordination` uses controlled AppKit backing scales and
real loopback sessions to cover multi-view preflight, pan commands, shared clamping,
mixed-density unit changes, failed and successful topology replacements, weak
lifetimes, replacement cleanup and actual server-accepted resize/shrink/growth.
This extends the canvas/focus prerequisites without claiming physical multi-monitor
or Spaces acceptance.
