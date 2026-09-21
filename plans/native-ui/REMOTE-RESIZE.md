# Native remote desktop resizing

N2/N4 now expose the portable remote-layout command to the native application.
Connection > Resize Remote Desktop and the desktop context menu open a
connection-local width/height sheet. It requires a connected server advertising
ExtendedDesktopSize, input access, and no outstanding resize. This requests remote
pixels; scaling and Resize Window to Desktop remain independent local operations.

## Wire and bridge contract

DESKTOP_LAYOUT (536870912), required by NativeRuntime, adds three exports. The
archive now has 82 `tidyvnc_` exports (including the display mapper below and
the two [canvas geometry exports](CANVAS.md)):

- `tidyvnc_desktop_layout_validate` uses the portable `RemoteDesktopLayout`
  validator, without a runtime or IO.
- `tidyvnc_session_desktop_layout` copies the actual connected layout plus a
  snapshot from the same publication, including generation, size, capability and
  pending state. It works for servers without resize support as well. It returns
  STALE for another generation and NOT_CONNECTED without connected geometry.
- `tidyvnc_session_request_desktop_layout` validates and copies the complete
  request before returning, then uses the existing worker admission/operation path.

Dimensions are 1–65535 remote pixels. There are 1–255 positive enclosed screens
with unique RFB IDs. Gaps and overlaps are permitted, and all flags are preserved.
IDs are remote protocol identities, never local display indices. Input is a bounded
borrowed screen array; output is an owned fixed-capacity array with unused entries
zeroed. Structs are size/version tagged, reserved fields are checked, and errors
preserve output. Existing public structs and handle ownership remain unchanged.

Admission rechecks generation, lifecycle, server capability, view-only, command
capacity, one pending request and the session's framebuffer limit. Completion
means server response, timeout or teardown. Success includes actual geometry;
server rejection includes its numeric result and leaves the old layout intact.
Cancellation can remove a queued request, but cannot retract a wire request.
Swift consumes the eventual completion before returning CancellationError.

The existing 10-second core timeout reports TimedOut while keeping the wire slot
occupied. Since RFB responses have no request IDs, a late response must be consumed
before another resize is admitted. It updates actual geometry without completing
the timed-out operation twice. A server that never replies requires reconnect.

## Native editor

The sheet validates whole-number dimensions, reports server rejection and resource
limits, and shows actual size after acceptance. It offers Reload, Resize and
Cancel/Done. The explicit dimensions request creates one screen, retaining the
first current remote screen's ID/flags; a multi-screen baseline displays that the
request replaces its topology with one screen. The server may affect other viewers.
The all/selected local-display mode uses full multi-screen requests as described below.

The editor checks a fresh layout against its baseline before submitting and
requires Reload after an observed competing change. This is not server-side CAS:
remote topology can change after that check. The server remains authoritative.
Drafts are scoped to a session generation. View-only changes disable Resize.
Controller gates prevent competing sheets, and dismissal cancels the await and
joins its completion before reopening. Disconnect/window close invalidate and
dismiss the draft; session close drains pending work. Cancel before Resize sends
nothing. Cancel after submission cannot undo a server change. No defaults/profile
records are written by this action.

## Local-display chooser and shared mapping

The explicit sheet can derive its request from all or selected local displays.
A numbered arrangement and matching checkboxes show current logical placement;
clicking a monitor also toggles selection. Device-pixel sizing is optional. The
summary reports the requested canvas and screen count, with an explanation when
mixed pixel densities require an adjusted remote arrangement. This command changes
the server topology; it does not enter fullscreen or move local windows.

DISPLAY_LAYOUT (1073741824), required by NativeRuntime, adds the pure
`tidyvnc_display_layout_compute` export. It borrows 1–64 checked monitor values,
then invokes the retained C++ `DesktopLayout` algorithm. Its owned output contains
canvas size, per-monitor regions, echoed caller tokens and a normalization flag.
No OS calls, session handles, state mutations or duplicate Swift layout algorithm
are involved. Existing ABI structs are unchanged and failure preserves output.

Logical coordinates are integral, top-left-based points. Device dimensions use
floored per-display logical size × backing scale. Nonfinite/fractional logical
boundaries, duplicate IDs, invalid scales, overlap/mirroring and out-of-range
layouts fail. Device mapping preserves left/right, above/below and logical gaps,
shifting regions when needed; it never multiplies a global origin by one density.
The chooser retains UUID selections, not screen-array indices. Temporary numeric
mapping tokens do not cross onto the RFB wire. Remote IDs/flags first follow exact
geometry matches, then remaining server IDs in numeric order. New screens receive
the lowest unused ID and zero flags; all baseline IDs are reserved during assignment.

A topology change disables submission until Reload. Missing selected UUIDs remain
selected and visible until explicitly removed or reconnected; this explicit command
does not silently substitute a fallback display. Apply rereads the display source
before admission, catching changes even when notifications are delayed. This is
observational validation, not an OS/server atomic transaction; geometry can still
change after submission. The server response remains authoritative. Custom sizing
continues working without local display geometry. Both paths share existing
view-only, capability, generation, pending-operation and joined-close behavior.
No defaults, profiles or system display settings are written.

## Automatic resize policy

Each native session now owns an automatic resize coordinator and a typed policy.
Enabled defaults to true, matching the retained viewer. An optional initial size
is parsed as bounded integer `widthxheight` and normalized through the shared
remote-layout validator. Empty means no explicit initial request.

Connection Settings > Remote Resize edits a copied policy for this window. Apply
uses a host revision check; Cancel sends nothing and Restore Initial Settings uses
the window's captured configuration. Enabling/disabling affects automatic work;
changes to initial size apply on the next accepted connection. NativeSession captures
that policy synchronously when Connect receives its new generation. These connection-local controls write no durable defaults or profiles; the separate
Connection Defaults and profile editors provide saved settings.

Automatic requests need a connected capable server, input access, an attached
available viewport and no outstanding wire request. Ordinary window following is
limited to Unscaled mode; fit/percentage/exact modes suppress it. Logical units use
viewport points; device units floor points times the backing scale. Nonfinite,
zero or out-of-range dimensions never reach the wire. An initial size bypasses the
scaling-mode restriction once per attempt, but still respects the other gates.

Viewport changes coalesce for 100 ms, and only the latest geometry is considered
after a pending request finishes. Repeated notifications at the same rejected or
accepted target do not create retry loops. An initial request holds its size until
the viewport changes; an accepted manual request also suppresses automatic updates
until then. Turning off the policy cancels queued work when possible; sent requests
must finish or time out. Failures produce a nonfatal status message and leave the
explicit Resize Remote Desktop action available.

The AppKit view supplies viewport size, scaling/units, backing-scale and availability.
Hidden/minimized/detached views stop scheduling. Fullscreen will-change notifications
suspend requests until completion, with a bounded 15-second recovery if completion
never arrives. Synthetic notification tests cover this boundary; real Spaces
transitions remain an acceptance gate. View identities prevent an old detached view
from invalidating its replacement. Session close joins coordinator and protocol work.
Window following requests one remote screen. Owned fullscreen uses the complete
canvas layout, as described below.

## Saved defaults, profiles and sources

Defaults schema **9** and profile schema **8** add an optional `remoteResize` object
with optional `enabled` Boolean and `initialSize` string fields. Each field inherits
independently. Missing initialSize inherits, while an explicit empty string requests
no initial change and overrides an inherited size. Enabled=false preserves the
configured size but suppresses requests. Numeric/string Boolean lookalikes, nulls,
unknown fields and invalid dimensions are rejected before write. Valid dimensions
canonicalize only on explicit save; reads preserve the original bytes.

Defaults versions 1–8 and profile versions 1–7 remain readable without rewriting.
Old schemas reject the new object. Existing revision/conflict, future-schema,
corruption-preservation and atomic profile-file rules continue to apply. Connection
Defaults > Remote Resize and the profile Remote Resize group use inherit/override
controls with validation before Apply/Save. They affect newly created windows.

New windows resolve built-in configuration, app defaults, then profile overrides,
capturing the value and source per field. Existing windows keep their snapshots
when defaults or profiles change. The local policy sheet displays built-in/app/
profile/connection/command-line source labels; a pending changed field displays a
connection override. Apply changes only modified fields' sources. Untouched fields
retain their inherited source, and local Apply never saves defaults or profiles.

## Remaining plan requirements

Saved fullscreen startup/current/all/selected policy and owned per-display surfaces
are implemented; see [FULLSCREEN.md](FULLSCREEN.md). The explicit remote chooser
and injected automatic-resize fixtures are not physical fullscreen evidence. Physical
menu/keyboard/VoiceOver and real multi-monitor/server acceptance are separate gates.

## Verification scope

The pure-C consumer checks headers, bounds, null/count mismatches, duplicate IDs,
reserved fields, wrong handles, stale generations and unchanged failure outputs.
Native tests use an independent message-parsing RFB peer for acceptance, rejection,
held reply, timeout/late reply, in-flight cancellation, maximum 255-screen layouts,
view-only/capability/resource gates, coherent retained snapshots and two-session
isolation. Controller tests cover invalid dimensions, correctable rejection,
competing geometry, cancellation before Apply, editor exclusion and joined close.
Light/dark AppKit fixtures cover draft, rejected, pending, applied and multi-screen
sheets. These are not physical UI or broad server interoperability evidence.

Persistence tests cover every older schema, explicit upgrade/canonicalization,
strict types, preserved invalid data, empty-versus-absent precedence and independent
sources. Real peers verify that saved policies reach the initial-size wire path,
a disabled profile suppresses its inherited size, and an explicit blank profile
suppresses a newer app default. Saved changes leave existing windows unchanged;
local changes preserve untouched sources without durable writes.


## Automatic fullscreen layout ownership (2026-09-20)

The fullscreen controller reserves automatic-resize ownership while creating its
canvas and enables it only after native entry completes (or borderless activation).
The canvas publishes the same NativeDisplayLayout used for rendering, including
mixed-density normalization. In Unscaled mode, the coordinator maps every selected
region to the fresh remote baseline using remoteLayout(matching:); available server
IDs/flags are retained and new remote IDs are allocated without exposing local UUIDs.
Window size callbacks from individual fullscreen views never submit independent
requests. A configured initial size still takes precedence once per attempt and
uses one remote screen, even in fit/custom scaling.

The original window's viewport is remembered behind the canvas reservation.
Temporary views cannot replace it, including while leaving the canvas for disposal.
Exit suspends the canvas before its native transition begins. Completed cleanup
restores the original source and its latest viewport; minimize keeps it unavailable
until the original is restored. Factory failure, native rollback, topology change,
stop and destruction release the reservation with an owner token. Stale cleanup
cannot revoke a replacement. Detaching a canvas member makes the group unavailable
until its owner explicitly configures a complete group again.

The existing single operation, 100 ms coalescing, view-only/capability/scaling gates
and joined cancellation remain shared. Releasing/replacing geometry ownership can
cancel queued work, but a sent request drains before any new geometry is submitted.
Only the newest complete layout is considered afterward. Rejected targets are not
retried by repeated notifications. Explicit manual and initial-size holds expire
when eligible geometry changes; returning later to an earlier geometry does not
reactivate an expired hold or suppress a necessary request because that target was
attempted before the manual resize.

NativeFullscreen.AutomaticRemoteLayout uses an independent RFB message-parsing
peer and injected native windows. It verifies complete layouts/IDs/flags, mixed
units, per-surface suppression, held replies/latest follow-up, initial-size and
manual precedence, fit/view-only/disabled gates, rejection, entry/exit/minimize/
topology/factory rollback, borderless handoff, replacement tokens and reconnect.
It also checks the expired-hold regression through actual window-size requests.
These tests do not establish physical multi-monitor/Spaces or broad server
interoperability acceptance.
