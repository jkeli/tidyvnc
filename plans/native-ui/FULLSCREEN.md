# Native fullscreen ownership and application integration

`NativeFullscreenController` owns dedicated AppKit desktop windows for one
connection. It takes the existing windowed desktop plus that connection's display,
scaling, input and command services. It does not replace the SwiftUI window's
delegate or move the SwiftUI view into another window. All owned desktop surfaces
share the existing session and `NativeDesktopCanvas`.

The plan requires a physical comparison before selecting the final strategy.
Both `.nativeSpace` and `.borderless` remain explicit arguments to `enter`. The
experimental app now uses native Spaces through NativeFullscreenState, based on
the successful single-Retina comparison. This is provisional, not the final
multi-monitor/cutover decision. The developer comparison app keeps both strategies
for the remaining physical tests.

## Selection and windows

Selection supports current, all and explicit stable display IDs. Entry refreshes
the display service, rejects unavailable/invalid mapping, keeps surviving selected
IDs and falls back to the current/primary display only when none survive. Missing
IDs and the original selection remain available to the caller; no saved preference
is rewritten. Empty explicit selection is rejected. If selected, the source
window's current display becomes the primary surface; otherwise the selected
primary display or first selected display is used.

The AppKit backend resolves UUIDs against fresh NSScreen objects and checks logical
bounds/backing scale again before construction. It creates hidden, independently
owned windows. Native Spaces uses a resizable fullscreen-primary window and
borderless fullscreen-auxiliary windows. The comparison strategy uses coordinated
borderless windows in the active Space. No system display or Dock setting is changed.
Their actual Spaces/Dock behavior remains a physical acceptance question.

The controller binds each surface to the same session/settings/commands, installs
its canvas before attaching to a window so it cannot claim ordinary automatic
resize ownership, and preflights the complete canvas. Hidden windowed-source
backing limits do not veto scaling valid for all active fullscreen surfaces.
Returning to that window uses the existing safe scaling fallback if its current
backing limits cannot represent the selected scale.

## Transition and cleanup contract

Phases are windowed, entering, active and exiting. Entry releases held remote input
and capture. The source's owner token gates focus and input for the whole interval,
including while its window remains visible during native entry. New surfaces stay
hidden until completion. Successful entry hides the source and activates the owned
surfaces; native entry failure leaves the original visible. Borderless activation
completes synchronously.

Programmatic and user-initiated native exits gate input before waiting for the
primary window. Delegate callbacks apply only to the current owned primary window.
Callbacks from previous/disposed or unrelated windows cannot complete a newer
transition. Owned-window delegates are separate from the original window delegate.
Both transitions have a cancellable 15-second deadline and rollback guidance.

Factory/preflight failure, native entry/exit failure, timeout, topology change,
owned-window close, disconnect and session close dispose the owned windows and
restore windowed geometry/command routing. A physical topology change exits rather than
continuing with stale display geometry; choosing and re-entering the revised
arrangement remains explicit. Work-area changes alone do not exit: native Space
entry hides the Dock/menu bar and changes NSScreen.visibleFrame without changing
the fullscreen canvas. The owner compares stable IDs, full bounds, backing scales
and primary-display status; the display service still publishes work-area updates
to other consumers. Closing the original window cleans up without
showing it again. Destruction schedules MainActor cleanup with an owner token so
restoration cannot clear replacement ownership. View detach and session close keep
the existing renderer-drain contract.

Owned views track pointer entry while this application is active. Entry into a
surface asks the backend to make its window key and uses the existing scoped focus
route, which releases the previous surface's held input. The callback is gated by
active fullscreen phase and application activation; it does not activate another
application. Physical cross-monitor input/capture acceptance remains open.

## Evidence and remaining integration

`NativeDesktop.FullscreenOwnershipAndTransitions` uses a real loopback peer and
injected windows to exercise selection/fallback, shared canvas, held-key release,
source input suppression during entry, hidden-source scaling, transition success,
user exit, failure/deadline rollback, stale callbacks, partial factory failure,
topology changes, owned-window close, destruction and disconnect. It checks that
the original delegate is preserved. Hidden construction tests also exercise the
real AppKit backend's display resolution, window bounds and strategy flags without
requesting a Space transition or showing a test window.

This is window ownership/prototype evidence, not physical fullscreen acceptance.
Still required: physical all/selected multi-monitor and Spaces behavior; final
strategy selection; broader app interaction acceptance; CLI policy mapping; actual topology
reconciliation/re-entry UX; edge panning and physical keyboard/capture/VoiceOver
acceptance. N4.8/N5.7 and the full native UI plan remain incomplete.

## Visible comparison harness and command routing (2026-09-20)

Build target `native-fullscreen-comparison` in the native Swift CMake build. Open
`build/native-ui-swift/tests/macos/native-fullscreen-comparison.app` to compare
current/all/selected displays, native Spaces versus borderless, scaling and device
units. The signed developer app owns a local color-pattern peer and has Restart
Test Desktop for a disconnected fixture. It reads no user settings, credentials,
trust records or saved connections. Clipboard and automatic keyboard capture are
off. The source window's green button cannot bypass the comparison controller.

The Desktop menu exits the owning controller (Control–Command–F), and desktop
actions use the same connection command route. The controller registers weakly
with an ownership token, publishes transition availability and clears its route on
cleanup. Entry/exit gate conflicting commands; fit remains disabled while fullscreen.
Minimize exits the owned group and then minimizes the original window. A frontend can provide an entry policy callback; an
existing owned or ordinary native fullscreen window always exits before invoking
that callback. Tests cover routing, weak destruction, transition gates and legacy
native exit priority.

`NativeDesktop.FullscreenComparisonHarness` runs `--verify` offscreen, verifies
actual fixture pixels/configuration/control availability and renders light/dark
PNGs under `tests/macos/fullscreen-comparison-render` in the build. Both renders
have been visually checked. Interactive status changes are written to
`$TMPDIR/tidyvnc-fullscreen-comparison-events.txt` for diagnosis; only local fixture
state is recorded. The fixture times out after inactivity and can be restarted.

Interactive checks on the built-in Retina display (1800 × 1169 logical, 2×) found
and fixed the work-area cancellation bug described above. After the fix, native
Space entry displayed all four quadrants and Control–Command–F restored the
original controls and desktop. Borderless entry and Desktop-menu exit also
restored the source. A second cycle verified All displays with native Spaces and
Selected displays with borderless on that same single monitor, including empty
selection rejection and preservation of the selector on return. UI capture briefly
reported ScreenCaptureKit -3812 during Space transitions; a subsequent capture verified the desktop. The automation
tool's Control–Option–Return chord did not trigger exit in either strategy;
physical keyboard/shortcut acceptance remains open. Multi-monitor behavior,
mixed-density physical mapping, topology changes, Dock/Spaces policy and final
strategy selection are not established by these single-display checks.


## Minimize across owned fullscreen windows

Minimize is available in active fullscreen when the original window supports it,
remains attached to the same desktop/session and neither it nor an owned surface
has an attached sheet. The temporary fullscreen windows never miniaturize. Native
Spaces waits for the current primary's exit callback; borderless disposes the
whole group synchronously. Both restore the original command host and use its
existing bounded minimize operation, including completion notification and input
suppression. Fullscreen entry remains unavailable during that final operation.

The pending intent belongs to this controller and connection generation. Only
successful exit completion can carry it into the windowed minimize operation.
Topology change, native failure/deadline, owned/original close, stop/destruction,
disconnect, command routing outside the owned group or a sheet appearing during
exit cancels it. Late
callbacks cannot minimize a restored or replacement window. Returning from failed
exit restores the normal window instead of unexpectedly hiding it in the Dock.
The comparison app's Desktop menu exposes Minimize and Restore Test Desktop for
interactive verification; visible app interaction and multi-monitor acceptance
remain separate.


Single-Retina interactive Command–M checks for both strategies recorded actual
original-window miniaturize notifications with isMiniaturized=true. A subsequent
UI automation observation restored the app and recorded deminiaturize=false;
this explains why simply inspecting its next screenshot showed a normal window.
The notification trace is `/tmp/tidyvnc-owned-minimize-live.log`. Multiple monitors
and the shipping SwiftUI shell are still outside this verification scope.


## Connection-local app integration (2026-09-20)

NativeFullscreenState connects the original NativeDesktop view to the window
owner without changing SwiftUI's window delegate. It installs a token-owned entry
callback, creates the controller once the view has a window, suppresses the source
window's independent green-button fullscreen role and restores its original
collection behavior on detach. Stop/rebind/detach invalidate pending work; deferred
destruction cannot clear a replacement entry callback or source ownership.
The existing single-window fallback remains available to consumers without this
state. Entry through the configured policy requires a connected desktop.

The experimental app's Connection menu, toolbar/context actions and desktop
shortcuts now share this owner. Control–Command–F toggles fullscreen and Command–M
uses the owned minimize path. Owned-window key activation identifies the correct
ConnectionModel for the global menu, including when another connection was active.
The global app window registry still owns only the original connection windows,
so closing a temporary fullscreen surface does not unregister the session.

Fullscreen Displays is a connection-local Apply/Cancel sheet with current/all/
selected choices, a layout diagram and keyboard-accessible display checkboxes.
Missing IDs remain selected and explicitly identified. Available selected monitors
win; only an entirely missing selection falls back to current/primary temporarily.
An empty selection, invalid/overlapping mapping, more than 64 saved IDs, changed
connection/revision or unreviewed display generation prevents Apply. Apply refreshes
the display source again before committing. Selections survive disconnect within
the same connection model. Durable storage and automatic restoration were added
in the following step described below.

A settings/info request during active fullscreen first exits and waits for the
original window to be visible. Only one deferred request is admitted, and it must
still match the connection generation, source window and sheet eligibility before
retrying the model's normal editor arbitration. Original-window close, detach,
stop or disconnect cancels it. An exit failure that successfully restores the
original window can still present the requested editor. Desktop error alerts wait
for the windowed host too. Statistics actions now toggle in place on every owned fullscreen surface, as
described below.

NativeFullscreen.ConnectionAndPresentation exercises the actual ConnectionModel
with a local pattern peer and injected window transitions. It covers selection,
missing IDs, topology review, revision conflicts, activation routing, source
behavior/delegate preservation, deferred sheet arbitration, failure/error/close/
disconnect handling and replacement cleanup. The actual sheet renders in light
and dark under `tests/macos/fullscreen-settings-render` in the build; both selected/
missing-display renders were visually inspected. These tests do not establish
visible end-to-end SwiftUI sheet/Space behavior, physical multi-monitor acceptance
or full keyboard/VoiceOver acceptance. Physical acceptance and CLI policy mapping remain required.


## Saved startup policy and reconnect restoration (2026-09-20)

NativeFullscreenPolicy captures startup mode, current/all/selected display mode
and a separate sorted set of stable display identities. NativeFullscreenPreferences
stores each field optionally: profiles can inherit IDs independently of mode,
and an explicit empty list clears inactive selections. Selected mode must resolve
to at least one saved ID. Missing physical displays remain valid saved selections;
temporary fallback never rewrites them. IDs are unique, bounded to 64 entries and
256 UTF-8 bytes each, and reject empty/control-character values.

Defaults schema 10 and profiles schema 9 add the typed fullscreen patch. Old
records remain readable and byte-for-byte unchanged until an explicit commit.
Wrong types, nulls, unknown fields, malformed IDs and invalid effective defaults
are rejected while preserving stored data. Profile storage validates independent
patches; profile drafts and session loading validate their effective inheritance.
Existing sessions capture immutable initial policy/sources, so later saved edits
only affect newly created sessions. The live sheet tracks each edited field as a
connection override and can restore its captured initial values.

Startup waits for a connected generation and an attached, visible, foreground key
source window with no sheet or minimize operation. Notifications retry eligibility;
there is no polling or automatic retry of a failed Space transition. A startup
preference edit applies to the next connection attempt without entering immediately.
Subsequent reconnects restore fullscreen when it was active at disconnect, using
the retained display choice and fresh topology. Explicit exit, settings presentation,
minimize, topology cancellation and native failure clear that intent. Exit intent
is cleared at the beginning of the transition, so a disconnect before the native
exit callback cannot accidentally restore fullscreen. Detach, stop, close and
replacement ownership cancel queued entry. The controller distinguishes a network
teardown from an explicit windowed return independently of subscriber ordering.

Defaults and profiles expose startup, display mode and independent selected-ID
inheritance. The live sheet shows per-field sources. NativeFullscreen.PersistenceAndSources
covers strict codec behavior, old-schema read/explicit upgrade, field inheritance,
missing selections and new-session isolation. ConnectionAndPresentation additionally
covers startup before source attachment, background/hidden/minimized/sheet gates,
reconnect restoration, stale callbacks, explicit-exit disconnect races, native
failure, settings/topology cancellation and stop with queued entry. Hidden fixtures
and offscreen renders do not establish physical multi-monitor or final Spaces
strategy acceptance. CLI mapping and physical acceptance remain open. Complete-layout automatic resizing is described in the following step.


## Automatic remote layout integration (2026-09-20)

The fullscreen canvas now reserves session resize ownership throughout construction
and transitions. Active Unscaled fullscreen publishes its complete canonical layout,
using the same logical/device mapping as rendering. Individual surfaces cannot
claim window resize ownership. Native exit suspends automatic requests; disposal
releases the lease and restores the original window after cleanup. Minimize gates
that restoration until deminiaturize. Initial-size/manual precedence and all existing
wire/policy gates remain shared. See [REMOTE-RESIZE.md](REMOTE-RESIZE.md) for the
ownership contract and wire-test scope. Physical mixed-monitor/server acceptance
remains required.


## Fullscreen statistics presentation (2026-09-20)

The existing Connection menu/context action now changes statistics visibility
without leaving fullscreen. NativeFullscreenState forwards the connection's
transient choice to its current controller. NativeConnectionStatisticsOverlay is
the same value-only SwiftUI view used by the source window and every owned surface.
The controller reuses its existing snapshot subscription, distributing copied
sampled information only; there is no new timer, frame consumer or session owner.

NativeFullscreenContentView holds the full-size desktop plus a sibling hosting
view. That sibling relationship keeps statistics outside the accessible remote
image leaf. The host refuses first responder and returns nil from native hitTest,
so even its transparent area passes pointer input to the desktop. Its SwiftUI
content also disables hit testing. Hosts are reused across sampled updates and
bounded to the content area at the top right. They do not change the desktop's
frame, canvas viewport, input mapping, resizing source or focus host.

Entry retains the choice but shows no overlay until activation. Native exit removes
it before transition. A normal return to the original window preserves the choice
and re-entry restores current values. Disconnect clears it; stop/close/rebind
remove hosts and cached controller values. The original source still owns its
ordinary windowed overlay. Controls keep the existing connected/busy/transition
gates; information/settings sheets continue to leave fullscreen before presentation.

NativeFullscreen.StatisticsAndInputIsolation and the actual ConnectionModel fixture
cover two sessions, real sampled updates, pass-through hit testing, first responder,
geometry, resize placement, transition/disconnect/re-entry and host destruction.
Light/dark PNGs render the overlay over retained fixture pixels under
`tests/macos/fullscreen-statistics-render` in the native build. This does not prove
physical VoiceOver or multi-monitor/Spaces behavior; those gates remain open.

### Visible inspection resumed (2026-09-20)

Computer-use app selection is working again on the unlocked Mac. The isolated
comparison app entered native Spaces on the built-in 1800 × 1169, 2× Retina display;
all four fixture quadrants were visibly rendered. Control–Command–F restored the
original selector and connected windowed desktop, verified by AX state and a
screenshot. ScreenCaptureKit briefly returned -3812 during entry, then recovered
on the next observation. The test app was quit afterward. This is a repeat visible
single-display check, not multi-monitor, physical-keyboard, VoiceOver, statistics
or full native-app acceptance.
