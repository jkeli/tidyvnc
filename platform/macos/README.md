# Native macOS bridge

`TidyVNCNative` is the owning Swift layer over the checked `TidyVNC` C module.
It uses Swift 6 strict concurrency and MainActor observable models. It is an
experimental opt-in target; the shipping viewer remains FLTK. The native app in
`apps/macos` now provides a connection/authentication/render/input vertical slice.
Native platform services and full frontend parity remain subsequent plan work.

## Build and exercise

From the repository root, with Ninja, CMake 3.29 or later and the existing core dependencies:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake -S . -B build/native-ui-swift -GNinja \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=/opt/homebrew \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_MACOS_NATIVE=ON -DBUILD_VIEWER=OFF -DBUILD_PLATFORM_APPS=OFF \
  -DENABLE_NLS=OFF -DENABLE_AUDIO=OFF -DENABLE_H264=OFF \
  -DENABLE_GNUTLS=ON -DENABLE_NETTLE=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE
DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build build/native-ui-swift \
  --target native-bridge-tests native-desktop-tests native-clipboard-tests native-display-tests native-preferences-tests native-settings-tests native-encoding-draft-tests native-profile-history-tests native-recent-history-tests native-profile-library-tests native-endpoint-tests native-scaling-tests native-tile-renderer-tests native-presentation-tests native-cursor-tests native-cursor-presentation-tests native-loopback-peer --parallel 4
DEVELOPER_DIR=/Library/Developer/CommandLineTools ctest --test-dir build/native-ui-swift/tests/macos \
  --output-on-failure --no-tests=error
```

The toolchain selection can instead point to the intended Xcode installation.
Native builds require macOS and Swift 6 or later; compiler errors identify missing
support. The small Swift targets use explicit whole-module compilation in Debug
and Release while retaining their respective optimization/debug-info settings.
This avoids the observed Swift 6.4 incremental executable failure after an
imported module changes (`cannotResolveTempPath(main-1.swiftmodule)`).
Generated compiler modules stay in the build tree, including configure
probes when no module-cache environment override is supplied. Normal core/FLTK
builds do not enable or discover Swift. The headless audit explicitly disables
the native target. The current native CMake path accepts one architecture per
build directory and propagates an explicit deployment target to Swift and C++.

The current verified host is arm64 macOS 27, Apple Swift 6.4 / AppleClang 21 and
SDK 27. Compilation targeting macOS 14 checks source/API availability only. The
installed Homebrew dependency dylibs target newer OS versions; their linker
warnings are retained. Compatible dependency builds, minimum-OS execution,
Intel/universal builds, signing and distributable packaging remain N6 gates.

## Xcode application

Run `python3 apps/macos/build.py` from the repository root. The script uses
`/Applications/Xcode.app` by default (override with `--developer-dir`), builds the
core/bridge with Ninja, imports CMake's generated transitive dependency graph into
a separate Xcode project, and runs `xcodebuild` on the TidyVNC scheme. The result is
`build/native-app/app/Debug/TidyVNC.app`. Launch its `Contents/MacOS/vncviewer`
executable for local testing. `--configuration Release` is available but is not
yet a validated distribution configuration. The build accepts one host architecture.
Version, bundle identity, icon, copyright, document association and local-network
description derive from the existing release template/resources; the native plist
removes the Carbon requirement and uses the numeric project version as build version.

This is an ad-hoc-signed development bundle. Its external Homebrew libraries are
not embedded. Hardened runtime is disabled for this local target because those
libraries do not share an application signing identity. Bundling, hardened runtime,
notarization, Intel/universal and minimum-OS execution remain N6 work. Xcode's build
services and compiler probes may require access to its normal caches outside the
repository. No developer account or provisioning profile is required for this build.

The SwiftUI app owns the event loop. Its AppKit coordinator registers window
notifications without replacing SwiftUI window delegates. Window close cancels
and drains that session. Quit first cancels prompts and all windows' operations,
awaits runtime shutdown and then terminates; the explicit Quit command also works
while SwiftUI presents an authentication sheet. Independent windows share only the
runtime capacity, with separate sessions and connection models. Credentials and
one-time trust choices are not saved.

`NativeDesktopView` draws a retained CGImage provider without copying frame pixels.
The provider owns its C lease until Core Graphics releases it, including after
resize, detach or shutdown. Drawing clips to view bounds, respects opaque alpha
padding and flips row orientation once. The portable `DesktopTransform` supplies
both placement and inverse pointer mapping through the checked GEOMETRY C API.
Backing-scale/window-size changes recalculate placement. Shared legacy special-key,
Unicode and hardware/scancode tables feed AppKit key/text events; pointer, wheel,
modifier and focus events use the existing core input policy. Full IME, keyboard,
scaling quality/performance and display-topology acceptance matrices remain N5.

The desktop consumes `NativeSession.frameUpdates` and `cursorUpdates` on MainActor.
These independent current-value publishers replay one retained image each, including
nil on invalidation, without sending `objectWillChange`. The `frame` and `cursor`
properties remain synchronous read accessors; `$frame`/`$cursor` are replaced by
the explicit streams. Do not enqueue image events on an unbounded consumer queue.
SwiftUI observes `hasFrame` for the empty-desktop overlay, which changes only when
availability changes. Snapshot equality suppresses duplicate notifications; frame
counters arrive with the core's existing throttled statistics events. Unchanged
focus/view-only values and repeated nil prompt checks do not invalidate the shell.
Stream callbacks use weak view ownership and are cancelled on detach; retained image
values can outlive the session. Close clears stream values before joining renderers.

For manual UI checks, run `build/native-ui-swift/tests/macos/native-loopback-peer`
in a terminal. Add `auth` to require the test password `password`. It prints the
loopback endpoint and paints red/green above blue/white. Type `resize` on the peer's
stdin to publish a 3×1 desktop, `status` to inspect password/key-A evidence, and
`quit` to stop. Each peer accepts one connection; start a fresh peer for reconnect.
The pattern fixture allows 120 seconds per handshake read for manual interaction;
the app's own prompt timeout still applies.

## Ownership and execution

`NativeRuntime` owns a C runtime and maintains weak session records. Each
`NativeSession` owns its runtime, session and subscription handles. Immutable
`NativeHandle` and `NativeImage` objects are explicitly Sendable because their
only shared state is synchronized or immutable in the C boundary. Image geometry,
format/alpha and generation metadata are Swift values. Clipboard text similarly
owns a C lease and copies bounded UTF-8 into an immutable String, retaining origin
metadata and the core byte budget. `copyPixels()` makes an
explicit Swift `Data` copy; image retention itself does not copy pixels. Opaque
images' unused alpha byte must not be interpreted as transparency.

Prompt metadata is copied into a Sendable Swift value before releasing its C
prompt handle. Password submission accepts mutable byte arrays and wipes the
submitted buffers on success/rejection; it does not promise to erase Swift
copy-on-write aliases, other strings, runtime copies or cached credentials.
There is no implicit trust decision, persistence or Keychain lookup here.

The C dispatcher retains a `NativeDelivery` context whose action weakly targets
the model. A lock protects only its scheduling gate. At most one MainActor task
is queued, retaining its context and its own subscription handle. It coalesces
readiness and validates active subscription identity and generation before
touching the model. Events are consumed in order with a 128-record per-delivery
budget; reaching the budget schedules another turn even without a new producer
wake. Views coalesce to the latest image; prompt and snapshot values stay on
MainActor. The Swift model never runs on the protocol executor; decoding stays
off the UI thread. Delivery failure initiates close instead of stranding waiters.

Connect/disconnect/refresh expose async results backed by reserved native
operation completions, keyed by operation ID and generation. Rejected admission
throws `NativeError`; asynchronous protocol failure throws `NativeCommandFailure`
with typed reason and terminal snapshot. Task cancellation before admission does
not create an operation. After admission it requests native cancellation and
consumes the owed completion before resuming with `CancellationError`; already
committed protocol work cannot be undone. Focus, view-only, key/pointer and prompt
reply methods preserve the C validation and routing policy.

`NativeEndpoint.validate` calls the shared C/core parser with a bounded temporary
UTF-8 buffer. It performs no DNS/network/filesystem IO and needs no runtime. The
connection controller revalidates each address edit and disables Connect on invalid
syntax; profile drafts use the same result to gate Save. Inline fixed text explains
invalid hosts/brackets/ports, overlong or malformed input and unavailable transport.
Display-number, explicit-port, scoped IPv6 and Unix-path forms retain shared parser
semantics and original text. Native empty fields require entry even though the core
accepts empty text as localhost:0. The file store retains its storage-admission
validation so existing malformed addresses can still be opened and corrected.

`NativeEncodingOptions` owns an immutable core encoding snapshot. Its schema and
choice queries expose core names/aliases/defaults/ranges and compiled decoder
availability. `applying` creates a new snapshot through the shared validator and
preserves per-field compiled/app/profile/session/CLI source metadata; no Swift
default/range table is introduced. Values and schema strings are copied, and patch
assembly uses a bounded contiguous UTF-8 buffer whose spans live only during the
C call. `NativeError.encodingProblem` and `.encodingOption` expose structured
validation details without input-bearing diagnostics.

Set `NativeSessionConfiguration.encoding` before creating a session to affect
initial negotiation. `encodingOptions()` returns a retained requested snapshot;
`applyEncoding` asynchronously applies a complete validated snapshot to that session
and preserves it across reconnect. Reserved completion means local application,
not server acknowledgement or proof of displayed pixels. Protocol-safe hint and
pixel-format timing, auto selection and pre-3.8 behavior remain in the core. Late
cancellation can leave an already executed change applied; reread the snapshot to
reconcile. App-default controls and the live connection sheet share schema-driven
encoding fields and per-field source labels.


`NativeSessionEncodingDraft` keeps an immutable baseline and editable snapshot for
one connected session generation. Edits only change the draft; Apply compares a
fresh requested snapshot with the baseline, then submits through the async command
path with the captured generation. Untouched fields keep their original provenance;
edits carry session provenance. Confirmation rereads the requested options and
checks generation, connection state and equality before advancing the baseline.
Observed competing edits preserve the draft and require reload. This is not a core
atomic compare-and-swap: the app permits only one encoding editor per connection.

Cancel before Apply changes no live options. Cancel Apply requests cancellation;
an already executed change may remain applied. Failed/cancelled completions require
explicit reload to reconcile, without claiming rollback. Pending Apply gates editing,
reload and duplicate submission. Weak model tasks and weak target references avoid
retaining dismissed editors; close cancels and joins admitted work. Connection and
close observations invalidate old drafts, and reconnect requires a fresh baseline.

The toolbar and Connection menu open `SessionEncodingSheet` for the selected
connected session. `ConnectionModel` owns the sheet and its asynchronous cleanup;
reopening is disabled until the previous operation drains. Disconnect removes the
sheet before another authentication flow. Window/quit cleanup also awaits its join.
One SwiftUI sheet route prioritizes authentication, whose explicit Cancel action
prevents an old encoding dismissal from cancelling a new prompt. Live overrides
survive reconnect and never save app defaults or mutate another connection.

Clipboard offer/clear use the same reserved async command completion machinery.
Send and receive policies are independent configuration/live values. A clipboard
route identifies its originating session, connection generation, focus revision
and policy revision; call `validateClipboard` immediately before a deferred native
write on the same executor that controls focus. Passing a remote `NativeClipboardText`
as offer origin suppresses echoes, including into another session. The wrapper
publishes callback-driven `NativeClipboardUpdate` values and observable focus;
terminal state/close/reconnect clears obsolete presentation.

`NativePasteboardAccess` is an injected MainActor contract, implemented by
`NativePasteboard` using NSPasteboard. The app owns one `NativeClipboardCoordinator`
and registers each window's session weakly. Only one focused, connected, non-view-only
desktop in the active app may share clipboard text. Ambiguous focus routes to none.
Every focus/state/policy transition immediately invalidates queued host work, even
when focus leaves and returns before deferred reconciliation. App deactivation also
clears core focus; AppKit restores it only for the active key window's desktop.
The toolbar's Clipboard sharing menu controls send and receive independently for
each connection, including before connecting. Both default on, matching the core.

A cancellable task observes change count every 250ms only while sending is eligible.
There is at most one admitted transfer and one pending latest value. Jobs capture
session generation and a routing epoch, recheck native change count before admission,
and use checked async offer/withdraw. Native remote writes validate the receive route
immediately before writing, without suspending MainActor. A custom type with a fresh
UUID marks remote origin without storing an endpoint; focus changes, reconnects or
app restarts cannot turn that copy into a local offer to another session. An ordinary
new local copy replaces the marker. Registering a session never replays cached remote
text. Unavailable/non-text copies withdraw protocol availability without clearing the
native board. Fixed, nonmodal errors contain no clipboard contents.

Read/write change-count checks detect observed ownership races; a changed snapshot
is retried. NSPasteboard has no cross-process compare-and-swap, so these checks cannot
make a remote write atomic with other applications. A write failure after clearing
can change the board. Text admission is limited to 256 KiB of UTF-8 with NUL rejected;
AppKit may materialize a provider's whole String before validation, so this is not an
OS/provider allocation bound. `stop()` immediately gates subsequent native access,
cancels observation and pending work, and drops registrations; async `close()` also
joins the admitted transfer's completion handling. App quit stops it before session
shutdown and awaits its close before termination.

`close()` first invalidates UI delivery and clears prompt/frame/cursor state,
cancels outstanding Swift awaits, closes the core and unsubscribes. Its shared
cleanup task then awaits session join, C callback/context drain and queued
MainActor delivery. The final snapshot reflects the joined native state. Repeated
close shares that task, and cancelling a caller's await does not cancel cleanup.
Runtime shutdown starts every session close before awaiting any of them and
then awaits runtime disposal. Drain polling suspends at 2ms intervals only during
cleanup; steady-state presentation is callback-driven. `deinit` only cancels and
releases; it never joins a worker or spins a nested event loop.

## Preferences storage foundation

`NativePreferencesStore` serializes reads, compare-revision commits and resets on
one actor. `NativePreferencesBacking` allows isolated adapters and failure injection;
`UserDefaultsPreferencesBacking` targets the dedicated domain
`io.github.jkeli.tidyvnc.native.preferences`. The app owns one writer actor shared
by Settings and new connection windows. The record supports optional clipboard
directions, all eight shared encoding fields, five native input fields, three
scaling fields, two optional CA/CRL paths, a security method list, TLS priority,
shared access, whether connection errors offer Retry, and automatic resize/initial size.
`NativeEncodingPreferences` is a
closed typed patch; resolution, canonicalization, ranges and decoder availability
come from the core schema. There is no separate Swift table of protocol defaults.

Schema-1 clipboard, schema-2 encoding, schema-3 input, schema-4 scaling, schema-5
CA/CRL, schema-6 security method, schema-7 TLS priority and schema-8 Shared/Retry records remain readable without rewriting their
bytes. An explicit commit writes schema 11 with a fresh UUID revision and a typed
non-secret patch, including TLS priority, optional Shared/Retry Booleans and the typed remoteResize patch. Unknown nested keys, nulls, wrong
types, invalid ranges and unavailable decoders are rejected before writing. Absent fields inherit the supplied session configuration; reading a missing
domain creates no data. Reset commits an empty patch with a new revision, so a
previous draft cannot become current again after reset. Every commit rereads the
persistent domain and rejects an observed revision conflict. Unknown fields,
future schemas, corrupt/non-data records and records over 64 KiB are preserved and
return typed errors; reset cannot silently overwrite them. There is no XDG/CLI/
global-domain fallback, arbitrary key bag, endpoint, credential or runtime-state
field. Only the owned record key is written; other domain keys are preserved.

The adapter acknowledges acceptance into
[UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults),
whose disk persistence is asynchronous. It does not promise cross-process atomic
compare-and-swap, fsync, crash durability or complete filesystem-denial diagnosis.
Serialization and conflict checks apply to the owning actor; concurrent independent
writers/processes are not a database transaction. Cancellation is checked before
admission; cancellation after acceptance returns the committed outcome. A throwing
backend write may have effects, so callers reread before retrying.

Change subscriptions buffer one latest immutable snapshot each, with at most 64
subscribers. Fresh reads, commits and observed conflicts publish changed snapshots;
opening another subscription also reconciles existing observers. Dropping streams
returns capacity asynchronously, close finishes all streams, and subscriptions do
not retain the store. External changes are refreshed by explicit reads. No cross-
process notification guarantee is implied. Full schema coverage and live-session
sheets for remaining settings stay N3.1/N4.9 work. Remaining profile fields,
migrations, credentials and trust stores remain separate requirements.

The native Settings scene edits a `NativePreferencesDraft`. Opening/activation
refreshes a clean draft; dirty edits remain intact. Apply is the only save action.
Cancel Edits/window dismissal discard unapplied edits; Restore Built-in Defaults
only changes the draft until Apply. Conflicts or uncertain writes preserve the
draft and require an explicit reload before another save. Fixed error text does
not include stored content. Per-field labels distinguish inherited built-in
defaults from explicit app defaults. Encoding controls include automatic selection,
available/unavailable decoder choices, full/reduced color, custom compression and
JPEG enable/quality. Dependent controls are disabled while automatic selection or
other fields supersede them. Invalid edits can be corrected without discarding the
draft; conflict and uncertain-write failures still require reload.

Each new connection owns `NativeSessionDefaults`, which holds its runtime and
performs one fresh read before creating the core session. The validated encoding
snapshot is passed into session construction, before negotiation can begin. The
model then owns the created session; Connect and clipboard controls become available.
For profile launches it also freshly reads the selected profile by UUID and applies
its explicit fields after app defaults, before constructing the session. The
controller receives the profile address before Connect becomes available. A missing,
corrupt or inaccessible profile blocks creation and offers Retry Profile; it never
silently becomes a plain connection. Explicit built-in fallback for failed app
defaults still reads/applies the selected profile. Both reads are asynchronous,
and closing during either suppresses late session creation. A failed defaults read blocks readiness
until Retry succeeds or the user explicitly chooses built-in defaults for that
connection; the unreadable store is preserved. Ready sessions never subscribe to
app-default changes, including during reconnect. Live clipboard controls affect
only that session and record per-field override provenance shown in the menu.
Window close cancels/joins its defaults load without allocating a late session, and quit stops Settings, joins pending
reads/saves and closes the store as well as the runtime. An accepted save is not
described as rolled back if the Settings window/app closes while it completes.

Model tests prove draft isolation, stale-edit conflicts, new-versus-existing session
behavior, explicit failure fallback and MainActor progress/cleanup during pending
store operations. The actual Settings view is rendered in unshown synthetic-data
windows for clipboard default/conflict and automatic/manual encoding states in
light/dark appearances. These images verify
layout, not interactive accessibility, keyboard navigation or app activation.
An unlocked-app check now covers Settings draft cancellation, dismissal without
save and encoding dependent controls. Full interactive/accessibility acceptance
remains open.

## Profile and history file store

`NativeProfileHistoryStore` is an actor over an injected byte backing, with list/read,
stable-UUID upsert/delete, recent-endpoint insertion/removal and explicit history
clear. One schema-10 record (with schema-1 through schema-9 read compatibility) holds profiles and most-recent-first history with a UUID
revision. Every accepted mutation produces a new revision. The complete record is
compared, so profile and history writers cannot silently overwrite each other.
History keeps 20 exact address strings, matching the retained viewer's history
limit; insertion moves an exact duplicate to the front. Names/aliases are not DNS
resolved or canonicalized by storage. Profiles are limited to 256, names to 256
UTF-8 bytes, addresses to 4096 bytes, and the file to 2 MiB.

Schema 10 records history initialization separately from profile existence.
New profile-only writes retain `uninitialized`; native history insertion or an
explicit clear marks it `native`. A separately reviewed history import commits
the imported list, fresh revision and `currentXDG`/`legacy` state together while
preserving profiles. Later edits and clears retain that origin, preventing
reimport. Historical schemas cannot distinguish untouched history from a prior
clear, so they remain authoritative even when empty. Reads never migrate bytes.
The explicit-source history parser/service are implemented; history import UI
and app integration remain open. See [IMPORTS.md](../../plans/native-ui/IMPORTS.md).

Profiles contain names, original endpoint text, the current typed clipboard/encoding/
input/scaling patch and an optional opaque credential UUID. They do not contain secret fields,
arbitrary setting dictionaries, transient errors or permission guesses. Applying
a profile preserves absent base values and labels explicit encoding/input/scaling fields with
profile provenance. Protocol address validation remains the shared parser's job,
not a second parser in the store. Broader setting fields and credential-reference
resolution/scoping are still separate work. Unknown envelope/profile/settings keys,
wrong types/nulls, duplicate IDs/history, unsupported decoder values, corrupt and
future records fail without rewriting them; clear/delete never bypass validation.

`NativePrivateFile.applicationSupport()` selects the user Application Support
location and the dedicated `io.github.jkeli.tidyvnc.native/profiles-history.json`
path. Construction/read does not create storage. First write creates the private
owned directory and, if missing, its host Application Support parent. Parent setup
is deferred until that write; inaccessible storage returns a typed failure without
preventing connections. The generic injected-directory backend requires an existing
parent unless explicitly configured to prepare it.

The backend creates directories with mode 0700 and record/lock/temporary files with
0600, clearing inherited extended ACLs on newly created objects. Existing objects
must belong to the current effective user, be private and have no extended ACL;
permissions are never silently repaired. Private read-only files remain readable,
but replacement requires writable private directory/data/lock objects. Directory
and leaf opens use no-follow flags; data/lock files must be regular, single-link
files. Nonblocking opens reject FIFOs without waiting for another process. Reads
check size before allocation and while reading. The app-owned parent is trusted;
this is not a defense against an uncooperative process with the same user identity.

Writers use a private advisory lock with nonblocking contention (`busy`), compare
exact previously read bytes under that lock, then write a unique same-directory
temporary, fsync it, rename over the record and fsync the directory. Cooperating
processes share the lock; uncooperative external writers are not covered by an
atomic CAS guarantee. Readers see a complete old or new inode. Ordinary pre-rename
failures remove their temporary file. Crash-left temporary files are ignored and
never promoted; automatic orphan cleanup is not implemented. No power-loss or
storage-hardware durability guarantee is inferred from successful fsync calls.

Cancellation is checked before admission and again before rename. After rename,
cancellation cannot undo the accepted change. A later error (including directory
sync) has an uncertain committed outcome; callers reread before retrying, and the
old revision conflicts if replacement succeeded. This store has no XDG fallback,
automatic import, secret backend or connection-document export path. Complete
migration/profile-settings flows remain open.

The app owns one store through `NativeApplicationSupportProfiles` and one shared
`NativeRecentHistory` model. Only a successful connection completion with the
current connected generation enqueues its original address. Storage work never
extends the connection await or changes a successful connection into an error.
The toolbar popover selects an address for a subsequent Connect action, removes
individual entries and clears history without deleting profiles. Failed loads or
saves expose fixed, nonmodal guidance and an explicit Reload History action.

The model serializes one operation and at most 20 pending successful addresses,
coalescing exact duplicates and refresh requests. Failed records remain bounded
for retry after an explicit reload; no automatic retry loop runs. Remove/clear use
the displayed revision and are never queued or replayed after conflict. Failed
reads clear the displayed cache rather than presenting stale state as current.
App activation and popover opening refresh shared state. Stop gates new work and
cancels delivery; async close joins accepted operations before the app closes the
store. Accepted writes may survive cancellation. Remaining typed settings,
migration and complete interactive keyboard/accessibility acceptance remain open.

`NativeProfileLibrary` owns one app-wide list/editor with one pending operation.
Saved Profiles is available from the toolbar or Command-Shift-P. New/Edit/Save,
Cancel Edits, confirmed Delete and Open Connection use copied typed profiles.
Clipboard fields can inherit app defaults or explicitly enable/disable each
direction. Encoding fields reuse the shared schema/controls and label their source;
individual and whole-encoding reset actions restore inheritance. Existing opaque
credential references survive edits; this UI does not look up or save credentials.
Dirty drafts must be saved or cancelled before switching or opening a profile.
Conflicts and uncertain writes keep the draft and require explicit reload; reload
reconciles without replaying a save/delete. A failed read clears the list and gates
editing. Closing the editor discards unsaved changes, while accepted saves may still
finish. Quit stops the editor and joins its operation before closing either store.

Each Open Connection action creates a distinct window request containing only its
window/profile UUIDs. Restoration rereads the profile rather than restoring copied
settings. Existing connections retain their initial snapshot even if the profile
is edited or deleted. Profile UI currently covers clipboard and encoding only;
remaining schema fields, documents, migrations and full interactive acceptance are
still tracked in the plan.

## Display topology

The app owns one `NativeDisplayService`, backed by the injected MainActor
`NativeDisplaySource` contract. Snapshots contain immutable Sendable values: opaque
display IDs, names, logical bounds/work areas, backing scales, primary identity,
generation and a typed error. Coordinates use logical points with the primary
display's top-left as origin and positive Y downward; screens above/left retain
negative coordinates. Full and visible AppKit rectangles pass through the same
conversion. Device pixel bounds never enter this contract.

`AppKitDisplaySource` rereads NSScreen objects on screen-parameter and active-Space
notifications. The primary screen comes from the first entry of
[NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens),
which differs from the screen containing the key window. IDs use ColorSync's
[display UUID](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid%28_%3A%29?language=objc),
not screen array positions or current numeric display IDs. If identity is unavailable
or ambiguous, the service reports an error instead of inventing a persistent ID.
OS UUID identity is not a guarantee against hardware/driver identity changes; missing
saved IDs are always handled explicitly. Mirroring follows AppKit's drawable-screen
list, not a promise to expose every physical panel independently.

Topology validation rejects duplicate IDs, missing/ambiguous primary identity,
nonfinite/invalid geometry or scale, work areas outside bounds and more than 64
displays. Failed reads publish an empty error snapshot rather than stale routing
geometry; zero available displays is a valid empty snapshot. Semantic changes
increment generation, including failure/recovery; mere reordering or duplicate
notifications do not. Selection resolution keeps surviving requested IDs, reports
missing ones, and falls back to the current then primary screen only if none survive.
It never rewrites a saved selection, allowing reappearance to restore it.

Desktop views subscribe weakly and refresh geometry/cursors on topology publication;
window backing scale remains authoritative for rendering. Detach cancels delivery.
Service stop unregisters notifications and gates refresh; there is no polling timer
or worker. Quit stops observation before closing windows. Actual host capture and
synthetic topology tests pass; fullscreen strategy, fullscreen chooser UI, physical hotplug,
Spaces behavior and mixed-density acceptance remain N4/N5 work.

## Tests and remaining integration

The separate C++ loopback peer is test-only and has no application ABI symbols.
The Swift executable tests real None/VNC authentication, owned and wiped prompts,
pixel leases through reconnect/shutdown, wire key input, async completions,
cancellation while prompting, independent sessions and a MainActor heartbeat.
It also tests cancelled close awaits, 80 session cleanup cycles using weak
references, rejected admission/typed errors, and 1,000 readiness signals coalesced
into one host task. Queued invalidation and generation changes suppress delivery.
Assertions verify observed published values arrive on the main thread.
The seventh scenario checks clipboard normalization, retained ownership,
independent directions, focus enforcement, session-scoped/stale routes, async
wire delivery, cross-session echo rejection and clipboard lifetime after shutdown.
Encoding checks cover shared schema/aliases/capabilities, immutable canonical
patches, typed errors, concurrent snapshot reads, configured initial values,
async application, session isolation, stale/cancelled admission and retained values
after shutdown. Separate C ABI loopback tests verify actual initial/live/reconnect
quality hints; pure C checks exercise malformed spans and allocation failures.

The second executable creates a real AppKit view and checks rendered channel/row
orientation, letterboxing, pointer/key wire input, focus-loss release, resize and
retained CG image lifetime. Twelve iterations remove views with a resize in flight
and verify weak disposal. The third executable checks isolated real NSPasteboards,
two-session wire routing, independent directions, remote provenance, focus/app
activation, view-only and queued focus loss. Injected fakes cover rapid-copy
coalescing, read/write failures, concurrent ownership changes, cached-update replay,
automatic observation and weak disposal. Tests use synthetic text on disposable
named pasteboards, never the user's general clipboard. A fourth executable checks
real NSScreen/ColorSync capture plus injected topology generations, negative origins,
fractional scale, remove/replug selection, malformed snapshots, failure recovery,
notification delivery, view detach and weak service disposal. A fifth executable
checks preferences revisions, concurrent stale edits, reset, bounded subscriptions,
weak disposal, strict schema/type validation, failure/uncertain-write recovery and
cancellation. Its real UserDefaults test creates and removes a unique test domain;
it never writes the production app domain or the user's existing preferences.
It also exercises the Settings/session-default models and pending-store cleanup.
A sixth executable renders the actual Settings view and connection encoding sheet
with independent in-memory fixtures: light/dark clipboard default/conflict,
automatic/manual encoding, live draft/applied/conflict/pending/cancelled states,
recent-history empty/recent/connected/error/pending states, and profile-library
empty/saved/editing/invalid-address/conflict/error/pending states; scaling adds twelve light/dark fixtures: 54 fixtures total.
PNGs are written under each build's tests/macos/settings-render directory. A seventh
executable tests encoding drafts with injected acceptance/completion faults, before/
after-acceptance cancellation, generation changes, weak disposal and asynchronous
join; real two-session loopback checks prove isolation and reconnect persistence.
It also compiles the actual app ConnectionModel to check one editor, deferred
session registration, reopen drain, disconnect dismissal and window-close join.
An eighth executable exercises profile/history storage in unique disposable roots:
real modes/ACLs, symlink/hard-link/FIFO/oversize refusal, independent and separate-
process lock contention, stale revisions, failure/cancellation around replacement,
uncertain outcome reconciliation and interrupted-temporary isolation. No production
Application Support data is accessed. A ninth executable checks the shared recent-
history model, bounded pending work, stale deletion, explicit uncertain-write retry,
weak disposal and close during pending reads/accepted writes. Actual connection
controllers with loopback sessions prove successful-only recording, failed/auth-
cancelled exclusion, independent endpoints and nonfatal storage errors.
A tenth executable checks profile drafts, inherited/explicit fields, preserved
credential references, stale/uncertain-save reconciliation, deletion/history
isolation and weak editor lifetime. Actual connection controllers verify fresh
profile loading before session creation, precedence, missing-profile refusal,
explicit defaults fallback and close during a pending profile read/accepted save.
An eleventh executable verifies shared address syntax, typed errors, UTF-8 byte
bounds, transport policy and redacted diagnostics. It compiles the actual connection
controller and checks that invalid input starts no operation and writes no profile
data; valid corrections enable actions without autoconnecting.
A twelfth executable covers scaling syntax, all eight geometry modes, decimal and
fractional device units, copied drafts, stale/closed owners, per-connection isolation,
actual connection-controller gating, live desktop presentation and RFB pointer
mapping. An owned, unshown Retina window checks display-limit preflight and recovery.
A thirteenth executable checks exact native filter samples, retained frame rendering,
extreme zoom with bounded visible tiles, cache clear, empty viewport, cancellation,
500-update coalescing, stale transform suppression, retry, joined close and weak
scheduler disposal. Immutable image metadata preserves consumed-frame damage history.
The fourteenth executable verifies AppKit composition and joined renderer teardown.
The fifteenth executable verifies shared cursor alpha/filter samples, hotspot and
extreme-zoom geometry, concurrent reads, cancellation and source independence.
A sixteenth executable verifies native/software cursor presentation, fallback,
backing changes, coalesced motion and joined teardown.
All sixteen executables pass normal/ASan/TSan configurations;
frameworks and external dependencies are not all instrumented. These tests need a
macOS GUI login and loopback sockets. Visible app checks additionally exercise
password cancellation/success, connection menus, independent windows and pending-
prompt quit. They do not establish performance, full input parity or minimum-OS
compatibility. Visible clipboard-control and real app focus/activation checks remain
open. A later unlocked-app check verifies recent-history sharing, selection without
autoconnect, keyboard dismissal, failed-connect exclusion and restart persistence;
Settings draft cancellation; and live encoding Cancel/Apply/reopen. The single-OK
connection alert now explicitly supports Return. VoiceOver, complete tab order,
history removal/clear and remaining error/recovery interactions still need coverage.
The profile library opens in the live app, but create/save/open acceptance remains
open: the computer-control helper crashed while inspecting a draft. The helper's
crash report identifies `SkyComputerUseService`; it is not evidence of an app crash.
Storage/Keychain/trust,
layout and remaining settings
wrappers are tracked in `plans/native-ui`. The C ABI stays portable; AppKit,
Foundation, Combine and SwiftUI remain in the macOS layer.

## Connection scaling controls

Each connection owns `NativeScalingState`; the toolbar and Connection menu open a
copied `NativeScalingDraft`. Eight modes expose exact dimensions, decimal percentage
and independent percentages with contextual help. Size units select logical points
or device pixels; fit modes ignore that selection and disable its control. Custom
text is retained when switching modes in one draft. The C ABI's shared parser owns
syntax and canonicalization. A 100% percentage becomes the canonical unscaled mode.

Scaling quality selects nearest neighbor, bilinear or area averaging independently
of mode and units. Bilinear is the built-in default, matching the retained FLTK
frontend. The choice is copied into the connection draft; filter-only changes enable
Apply, Cancel discards them, and reopening shows the applied selection. Rendering
uses the shared CPU filter and preserves the original-image identity fast path.

Apply checks the baseline revision and the attached view's current framebuffer,
viewport and backing scale synchronously on MainActor, then publishes one immutable
value. The view installs mode/units/filter together. Mode or unit changes reset pan;
filter-only changes preserve it. Rendering,
cursor placement and inverse input mapping use the same geometry. Cancel, sheet
closure, disconnect and window close discard the draft; a delayed sheet dismissal
only closes its original editor. State/editor/view links avoid retaining closed
connections. The values belong to the current connection and survive reconnect;
app defaults and profiles now persist scaling with fieldwise inheritance (below).

If a later remote resize or backing-scale change makes the selected geometry too
large, the view temporarily uses FixedRatio for both image and input, preserves the
selected setting and reports the issue once until recovery. Apply rejects an
already oversized geometry inline, without changing the active setting. The shared
resampler/cache now supplies scaled AppKit tiles. Shared cursor sampling and
accessible pan actions are implemented below. Performance budgets and full
interactive keyboard/VoiceOver acceptance remain open.

## Background tile rendering and AppKit composition

`NativeImage` now copies the view update's source damage and previous consumed
sequence alongside its retained immutable pixels. Each native session supplies a
stable local stream identity for presentation routing. The C renderer separately
uses its own session identity to prevent cross-session cache reuse. A skipped
native rendering request is safe: the shared cache detects the history gap and
invalidates instead of applying incomplete damage.

`NativeTileRenderer` is an internal actor around the C renderer, with an 8 MiB
cache by default. It samples only fixed-grid 256 × 256 tiles intersecting the
requested visible portion of the destination raster. Output admission is capped
at 64 MiB / 1024 tiles before allocation, independent of total zoomed desktop size.
An empty visible region clears the cache. Each rendered tile owns one allocation,
written before publication, then retained directly by an immutable CG image's data
provider. Unchanged tiles reuse that same image/storage when damage history is
contiguous. Gaps and source/size/filter changes force resampling. Results retain
their source image; there is no full enlarged desktop allocation. Diagnostic
`pixels` access explicitly copies into Data; production composition does not.

A conservative per-renderer payload bound is three 64 MiB batches (displayed,
previous successful worker result and in-progress output) plus the 8 MiB C cache.
Usually displayed and previous tiles share allocations, but suppressed or failed
presentation can leave them different. This excludes Swift metadata, allocator
overhead, retained source-frame budgets and Core Graphics upload storage. Full
memory and latency measurements remain an acceptance gate.

`NativeTileScheduler` admits one active render and one latest pending request.
A newer frame using the same presentation allows current work to finish, avoiding
starvation under continuous updates. Changed source/generation/size/transform/filter
cancels between tiles and suppresses obsolete results, even if an in-flight renderer
ignores cancellation. Failed current requests can be explicitly retried. Stop gates
admission and delivery; close asynchronously joins running work then clears cache.
Tasks weakly reference the scheduler so destroying a view owner need not retain it.

`NativeDesktopView` now publishes prepared tile images and their inverse input
geometry together on MainActor. During a scale change the displayed image retains
its own input map; obsolete render results cannot replace it. Source/size changes
clear the old presentation. Identity draws the original retained CG image directly
with no output tile allocation. Shared `tidyvnc_desktop_damage` supplies filter
halos, rounding and placement for logical dirty regions; history gaps or transform
changes redraw the viewport. Hidden views clear presentation and worker caches.

Each session owns a `NativePresentationPool` capped at 16 view slots, each owning
a desktop and cursor scheduler/worker, including
detached slots still draining. Views release their slot on detach or deallocation;
close/quit cancels admission and asynchronously joins every slot before returning.
Callbacks reference views weakly, and late results after detach/close are ignored.

The fourteenth native suite, `NativePresentation.CompositionDamageAndDrain`, checks
actual unshown AppKit bitmap output, coherent geometry, damage reuse, identity,
hide/unhide and held-worker teardown. Five synthetic PNGs are written under
`tests/macos/presentation-render` in each build tree. Filter golden images undergo
the same host display conversion as the view. Physical-display and performance
acceptance remain open. These fixtures do not establish live UI
acceptance or a shipping cutover.

## Shared cursor sampler foundation

`NativeCursorSampler` wraps the immutable C cursor sampler. Construct and sample
it off MainActor; cancellation is checked before/after native work, but an individual
area-filter tile is not interruptible. The sampler owns one original-sized
premultiplied source copy (at most 4 MiB), not a source image/session lease. Copied
backing-pixel geometry includes rounded dimensions and a clamped hotspot. Scales
are independent per axis, and an enlarged raster is never allocated as a whole.
Each requested tile is at most 256 × 256 and directly backs an immutable straight-
RGBA CG image, using the same allocation/provider ownership as desktop tiles.
Concurrent calls with independent tiles are safe; native presentation uses the
bounded actor/scheduler described below.

`NativeCursor.SamplingAndOwnership` checks independent transparent-edge goldens,
all filters and identity, area reduction, anisotropic scale, a 131070 × 1000 cursor
sampled from an eight-byte original, invalid regions, cancellation, concurrent
sampling after shutdown and release of the original native image. No extra screenshot
fixture is produced by this service test.

`NativeCursorRenderer` samples cursors up to 128 × 128 backing pixels into one
native cursor image; larger shapes render only fixed-grid tiles intersecting the
desktop clip. Software tiles composite after desktop drawing, with shared sampled
hotspots and explicit backing-to-logical conversion. Pointer motion reuses unchanged
CG tiles; old and new cursor rectangles are invalidated. The displayed request's
point and geometry stay together while the newest pointer request waits. Software
cursor motion can therefore lag input while rendering is in flight; physical
latency/performance acceptance remains open.

`NativeCursorScheduler` admits one active and one latest request. Shape, scale,
filter and clip changes invalidate obsolete results, while pointer-only movement
lets useful work finish. Letterbox/exit/hide clears overlays immediately and guards
against late visible results. Session-owned slots include cursor jobs in detach,
deallocation and close/quit drain. Visible tile admission is 64 MiB / 1024 tiles.
Conservatively budget three cursor batches plus up to two original 4 MiB source
copies during sampler replacement, in addition to desktop renderer bounds. Source
leases, metadata, NSCursor internals and CG uploads require separate measurement.

The view's `cursorFallback` API selects hidden (the retained frontend default), dot
or system behavior for nil/all-transparent cursors. View-only uses the system arrow.
The connection Input Settings sheet exposes this policy with Apply/Cancel;
defaults/profile persistence remains open. Errors show a local
arrow and report once until recovery. `NativeCursor.PresentationAndDrain` verifies
actual software bitmap pixels/clipping, alpha, native image/hotspot size, motion
reuse, blank/empty fallbacks, view-only, hide, Retina-window attach/detach, numerical
and allocation admission bounds, 500-motion coalescing and held-worker cleanup.
Two synthetic PNGs are written under `tests/macos/cursor-render` in each build tree.
These unshown-window tests do not establish visible system-cursor behavior across
physical displays/Spaces, full input fidelity or measured memory/latency budgets.


`NativeInputState` belongs to one connection and holds view-only/middle-button/cursor fallback
policy. It weakly observes the actual session, which remains authoritative for
view-only and middle-button emulation. `NativeInputDraft` copies values, generation and revision and weakly
references that state. Apply checks connected/closing status and baseline validity
synchronously on MainActor, calls the atomic core input-policy setter, then publishes the
combined policy. External view-only changes, lifecycle changes and replacement
sessions invalidate old drafts. Cancel makes no live changes or storage writes.
The connection menu and toolbar share one input sheet; authentication has priority,
and scaling/encoding/input editors are mutually exclusive.

Enabling view-only releases held input through the core and clears local AppKit
held keys, buttons, wheel accumulation and text composition. Pointer/key/scroll
handlers avoid collecting new local input while viewing, so re-enabling control
cannot turn a blocked click into a drag. Cursor fallback updates existing desktop
views through weak subscriptions that detach cancels. `NativeInput.DraftRoutingAndRelease`
checks real loopback wire release, blocked input, copied drafts/cancel/reopen,
connection isolation, external changes, reconnect/close guards and weak cleanup.
Fourteen input settings render fixtures cover light/dark defaults, view-only,
middle-button emulation, dot/system fallback, conflicts and closed state.
Fullscreen key handling, modifier choices, defaults/profile persistence and
interactive input/cursor acceptance remain open.


Middle-button emulation defaults off. When enabled, left/right presses within a
50 ms chord window emulate the middle button. Delayed single presses preserve
the initial drag position. Both frontends consume the same allocation-free
`MiddleButtonEmulator` state machine; Swift does not duplicate it or own a timer.
The native session worker schedules one optional deadline through its scoped
scheduler, guarded by connection generation and input routing revision. Focus
loss (even followed immediately by focus gain), view-only, policy changes,
overflow and close invalidate pending presses. Changing emulation releases held
remote input and clears AppKit's local held input/composition. The option remains
connection-local and survives reconnect, while pending presses do not.

The checked C `tidyvnc_session_input_policy` export atomically validates and sets
view-only/emulation; feature bit `TIDYVNC_FEATURE_INPUT_POLICY` is required by the
Swift runtime. The legacy view-only export preserves emulation. Core fake-clock
tests cover deadlines, chord/release/drag wire bytes, wheel and physical middle
buttons, routing/overflow/close/reconnect cancellation and independent sessions.
Native loopback tests exercise the actual setting, chord and delayed press, and
release/local-state clearing when emulation is disabled. Retained emulation tests
and full FLTK regressions still pass. Physical button-device acceptance remains.


`NativeShortcutState` owns a checked shared-classifier handle on MainActor, without
retaining a session or view. `NativeShortcutModifiers` uses Control, Shift, Option
and Command bits; the built-in selection is Control+Option, matching the retained
viewer. `NativeShortcutRouter` adds the retained command selection and temporary
Space bypass. It returns remote/suppress/release-keyboard/capture-keyboard/context-
menu/fullscreen decisions and an explicit remote-key-release intent. Ordered
layout candidates let a host identify shortcut letters independently of modified
text. Held-ID bookkeeping is bounded to 1024 even during bypass; failed modifier
or capacity changes preserve routing state. Reset drops bypass and held keys.

`NativeShortcuts.ClassificationAndRouting` is the eighteenth native suite. It
checks every modifier set, reset/repeat/capacity recovery, action/release routing,
Space bypass and its end condition, late Space after firing, separate surfaces,
reconfiguration and failure preservation. AppKit now consumes the router before
remote keyboard translation, including modifier events and key equivalents.
Bounded, lazy TIS/UCKeyTranslate candidates match shortcut letters across layout
variants. Control+Option is the default: G captures the keyboard, M opens the native
connection popup, Return toggles fullscreen, and the modifiers alone release
capture. Space begins temporary remote bypass until all held keys are released.
Input Settings can change the modifier set or disable local shortcuts entirely.


`NativeDesktopCommands` is connection-owned and weakly references the session and
its desktop/window host. The Connection menu and toolbar actions share one SwiftUI
menu implementation for disconnect, fullscreen, windowed minimize, fit-to-desktop,
Control/Alt latches, Ctrl-Alt-Delete, refresh, connection settings, information and
About. Window fitting accounts for desktop viewport versus window chrome, keeps
the top edge where possible and clamps to the current screen's visible frame.
It handles negative display origins and rejects missing/nonfinite geometry.

Synthetic commands require a connected, nonclosing, non-view-only session and
successful focus of the owning key window; eligibility is rechecked after focus.
Commands first release wire/local held input. Menu latch selections persist across
focus changes: core focus loss releases actual keys, and a coalesced weak MainActor
task restores selected keys only after the new focus/policy state is visible.
Ctrl-Alt-Delete uses distinct IDs above physical/IME ranges, releases Delete and
retains only selected menu modifiers. Errors release input and restore prior
selections. Physical release of a selected left modifier reasserts the menu latch.
Disconnect resets selections, rebind releases the old session, and stop cancels
subscriptions/recovery and prevents later work. Recovery performs no await; an ID
guard prevents an older task from clearing a newer task's ownership.

`NativeCommands.RoutingAndModifierLifetime` is the nineteenth suite. Actual local
RFB peers verify modifier press/release/reassertion, exact Ctrl-Alt-Delete bytes,
focus/view-only (including policy change during focus) guards, session isolation,
rebind/disconnect cleanup and weak ownership. Window method spies verify target
routing; geometry checks cover screen clamping. They do not establish actual
fullscreen animations, Spaces or physical multi-display behavior.

The information sheet displays endpoint, desktop size, frame count, resize support,
input/middle-button and clipboard policies from existing values. It participates
in the authentication-priority, identity-guarded sheet arbitration and closes on
disconnect. Light/dark render fixtures cover long endpoints and expanded input
settings (96 settings/info fixtures total). Negotiated name/protocol/security/
pixel-format statistics, minimizing from fullscreen and live interactive acceptance
remain unfinished; N4.10 is still open.


`NativeShortcuts.AppKitDispatchAndCaptureLifetime` is the twentieth suite. Actual
NSView events and a loopback peer verify local dispatch, wire key release, one-pair
Space bypass, view-only local commands, modifier-draft validation/reset and layout
candidate bounds. An injected capture backend verifies automatic fullscreen
capture, explicit release suppression, permission failure without retry loops,
revocation, external focus changes, sleep notifications and disconnect. Window
spies avoid entering Spaces. Command tests construct the actual native popup and
invoke its owning-model action. These tests never activate the real global tap.

The capture adapter preflights Accessibility permission without prompting. It
owns one session tap and main-run-loop source, disposing both on focus loss,
policy/lifecycle reset and close. The Connection menu can capture or release the
keyboard; status shows active capture or recovery guidance. Fullscreen capture is
connection-local and defaults on, matching the retained viewer. Input defaults and
profile overrides are persisted as described below. Physical system-key/layout/IME
acceptance remains open.
`NativeSession.releaseInput()` uses the additive input-release ABI feature to
clear queued/held input and delayed routing while preserving focus and policy.


### Saved input settings and initial policy

`NativeInputPreferences` is a closed patch with optional view-only, middle-button
emulation, fullscreen capture, shortcut-mask and cursor-fallback fields. Absence
inherits; mask zero explicitly turns shortcuts off. Stores validate nested keys,
JSON types, mask range 0–15 and the three cursor tokens before decoding or writing.
Schema upgrades happen only on accepted explicit writes. Old reads, rejected saves,
unknown fields and invalid/future records preserve their original bytes.

Connection Defaults has an Input section, and Saved Profiles can inherit or
override each input field (the modifier mask is one setting). Inherited picker
choices show the effective value. Reset-to-inherited, Apply/Save and Cancel use the
existing copied-draft and revision-conflict handling. Live Input Settings shows
built-in/app/profile/connection sources. Only edited fields become connection
overrides; external core policy changes also update their source.

Resolved app and profile patches enter `NativeSessionConfiguration` before session
creation. NativeSession installs view-only/emulation through the checked C policy
API before it is published or can connect. Host-only cursor/shortcut/capture values
and sources are copied into the connection input state and directly bound desktops.
Later saves affect newly opened windows only. Reconnect keeps the existing session's
live policy. Live changes write neither preferences nor profile/history files.

The twenty-first suite, `NativeInput.PersistenceAndInitialPolicy`, verifies legacy
byte preservation, explicit schema upgrades, every input field, strict nested
validation, conflict/invalid-write preservation, pre-connect core policy, host
configuration, app/profile precedence and fieldwise sources. Actual ConnectionModel
and loopback tests verify view-only rejection, live/new-session isolation, reconnect,
profile draft cancellation/save and invalid configuration before runtime admission.
Eight additional light/dark defaults render fixtures bring the total to 86.


### Saved scaling and initial presentation

`NativeScalingPreferences` optionally overrides sizing text, logical/device units
and a stable filter token (`nearest`, `bilinear`, `area`). The existing shared
parser handles all eight modes, aliases, precision and bounds. Resolved values
preserve absent fields; explicit preference commits/profile upserts canonicalize
only present sizing text. Reading older or noncanonical records does not rewrite
them. History-only mutations preserve profile settings. Unknown/null/wrong-type
fields, invalid sizes and unavailable filter tokens cannot overwrite saved data.

Connection Defaults and Saved Profiles include scaling controls, all eight mode
presets, custom text, inherited values, per-field override/reset and inline invalid
input guidance. Invalid scaling disables Apply/Save. An accepted canonical result
replaces the preference draft only when it still matches the submitted draft, so
normalization does not leave a false unsaved-change indicator or discard newer
edits. Profile saves use their existing committed-baseline reconciliation.

Resolved scaling/source values enter the native session configuration. Explicit
initial scaling reaches a desktop before frame subscriptions; absent configuration
preserves a host's pre-bind rendering choices. Connection-owned scaling state binds
once per session and retains live choices across reconnect. Changed live fields
get session source labels; untouched inherited fields keep app/profile sources.
Later default/profile saves affect newly opened windows only. Renderer preflight,
visible-tile bounds and display-limit fallback remain unchanged.

The twenty-second suite, `NativeScaling.PersistenceAndInitialGeometry`, covers all
modes/filters, legacy byte preservation, canonical saves/reopen, strict records,
stale writes, invalid-save gating, draft cancellation/reconciliation, initial
loopback frame geometry, fieldwise sources, live/new-window isolation, reconnect
and profile editing. Ten new light/dark fixtures bring the settings/info total to
96. Physical display/Spaces and live VoiceOver acceptance remain.

### Accessible desktop panning

Connection, toolbar and context menus include a Pan Desktop submenu with left,
right, up, down and Return to Top Left actions. Available directions also appear
as accessibility custom actions on the remote desktop. Each move advances 80% of
the visible viewport with overlap, stopping at the shared transform's edge.
Actions are local and work in view-only mode without acquiring remote input focus.
Ordinary scroll events continue to reach the remote computer.

Offsets belong to each desktop view and are expressed in its selected logical or
device units. Viewport, remote-size and backing changes clamp stored offsets;
mode/units changes and reconnect reset them. Filter-only changes preserve valid
pan. When rendering is pending, pointer input keeps the displayed image's transform
until replacement pixels and geometry publish together. Hidden, disconnected,
closing and detached views reject actions. No pan values are persisted.

`NativeDesktop.AccessiblePanning` verifies all eight modes and fractional backing
scales, native menu/accessibility dispatch, view-only behavior, delayed rendering
with real loopback pointer coordinates, edge availability, unit changes, independent
views, resize/reconnect and weak cleanup. This does not establish physical keyboard,
VoiceOver navigation or mixed-monitor acceptance.

### Minimize from fullscreen

The native Minimize action works in fullscreen by exiting first and waiting for
the owning window's `didExitFullScreen` notification before requesting minimize.
It then waits for `didMiniaturize`; duplicate and conflicting commands stay
disabled during the sequence. Remote held input and keyboard capture are released
before transition. Desktop focus/capture callbacks cannot re-enable input while
minimization is pending.
Pointer, wheel, key and IME callbacks also ignore input during the pending
operation, so delayed events cannot accumulate a button, wheel delta or composition
to replay after restoration.

The operation keeps weak window/host references, checks the session generation,
and cancels on detach, rebind, disconnect, session/window close or a new fullscreen
entry. A sheet appearing during exit cancels minimization. A single cancellable
15-second deadline handles missing completion/failure notifications with visible
retry guidance; it never retries automatically or minimizes on a late exit.
No window delegate is replaced. Owner destruction cancels the deadline.

Command tests use AppKit window spies and real loopback held-key release to verify
ordering, duplicate/foreign/late notifications, timeout/retry, sheets, cancellation
and weak lifetime. Actual native-view tests use an injected capture backend to
verify focus/capture suppression and recovery. Physical fullscreen/Spaces/Dock
transitions remain an interactive acceptance gate.

### Negotiated connection information

Connection Information shows the server-provided desktop name, RFB protocol,
negotiated security method, actual wire pixel format, requested encoding, last
received data encoding, line-speed estimate, desktop dimensions and frame count.
CopyRect does not replace the last data encoding, matching the retained viewer.
No data encoding/estimate is claimed before a received update. The estimate uses
the existing automatic-encoding bandwidth estimator, not a new network benchmark.

The portable session publishes immutable fixed-size metadata with a desktop-name
limit of 1024 bytes. Long names are marked truncated, and Swift safely replaces
incomplete UTF-8. `tidyvnc_session_information` copies one connected observation
with matching state/counters and requires the current generation; it introduces
no borrowed spans or handles. Existing ABI structs retain their layouts, and the
new query has its own required capability. The credential-security flag preserves
the authentication policy's meaning; the UI does not treat it as proof of all-
traffic encryption or verified identity.

Swift includes metadata in the same deduplicated observed snapshot as statistics,
and offers a replaying `informationUpdates` stream. Disconnect, reconnect and close
clear exposed information; retained Swift values remain valid. Live encoding
changes schedule the existing statistics deadline even on an idle desktop. Image
delivery still does not invalidate the SwiftUI shell for every frame.

The sheet scrolls and supports selectable values. Copy Diagnostics excludes server
address, desktop name, credentials, certificate material and filesystem paths;
the copy action is the only new pasteboard write. Core/C/Swift tests cover bounds,
immutable ownership, generation and handle validation, concurrent readers, wire
metadata, authentication, idle encoding changes, redaction and the existing
invalidation budget. Light/dark information fixtures are rendered and inspected.
Broader metrics, live clipboard-copy and VoiceOver acceptance remain.

Imported C header and module-map content now contributes a public Swift compile
fingerprint. CMake watches those inputs and propagates the fingerprint through
the bridge and exported Xcode target. This forces all Swift consumers to rebuild
when a C struct changes, even if CMake considers the Swift module interface
unchanged. The information tests exposed and reproduced an otherwise stale
generic ABI conformance in an old test object; rebuilding both sides resolved it.

### Connection statistics overlay

Show Connection Statistics is available in windowed and owned fullscreen presentation
through the Connection menu, toolbar
connection actions and desktop context menu. Each window owns its visibility;
disconnect, a new attempt and close hide it. View-only connections can show it.
Menu actions recheck current connection state, and an already visible overlay can
be hidden during a pending operation. This is transient UI state, not a stored
preference or remote input command.

The passive SwiftUI overlay receives the existing copied, throttled information
value: desktop dimensions, frames received, last data encoding, line-speed
estimate, RFB version and security method. It adds no timer, subscription, frame
stream consumer, session owner or per-frame invalidation. It preserves the desktop
layout and pointer/keyboard routing. Its combined accessibility label has a hint
to the menu toggle; live VoiceOver acceptance remains. No FPS, latency or measured
throughput claim is made by the line-speed estimate.

### Connection failures and explicit retry

NativeConnectionIssue maps structured terminal/operation/status values into fixed
redacted UI text. The connection model now reports unexpected server closure as
well as failed Connect, with Retry/Cancel for reconnectable categories. Retry uses
the normal connection path only when the problem identity, generation and address
still match. Editing the address requires a new Connect action; cancelling,
closing or starting another attempt invalidates old alert actions. No automatic
reconnection is introduced; credential lifetime is controlled separately by the
authentication choices below.

DNS failures, refusal, routing, timeouts, authentication, protocol and resource
limits are distinct. EACCES/EPERM receive conditional network/system-policy and
Local Network guidance; routing errors do not assert a privacy denial. Native and
unknown error descriptions are not displayed by these flows, including inline
authentication reply errors. Loopback lifecycle and exhaustive classification
tests are registered as NativeConnection.ErrorsAndRetry. Interactive alert focus,
keyboard/VoiceOver and localization remain acceptance work.

### Credential identity foundation

NativeCredentialKey is the canonical identity for credential storage and
session retention. It uses the shared endpoint parser through a temporary owned
endpoint handle and returns a v1 SHA-256 account under the app-scoped service
io.github.jkeli.tidyvnc.credentials.v1. Length-prefixed fields distinguish transport,
host/scope/port/path, non-secret route, negotiated security type, credential shape
and exact UTF-8 username. DNS case and numeric IP spellings normalize; aliases,
trailing dots, scopes, paths, routes and username bytes stay distinct. Password-only
authentication requires an explicit empty username. Tests pin the digest format
and exercise Unicode byte distinctions, boundaries, routes and concurrency.

Callers must use the logical target endpoint and actual route identity for tunnels;
a local forwarding port cannot establish remote identity. This value does not
verify server trust or authorize credential reuse. The per-window authentication
controller below uses it only for explicit credential choices. The authentication sheet now labels the core policy as credential
protection and avoids the previous blanket encrypted/not-encrypted claims.

### Keychain adapter and credential store

NativeCredentialStore runs NativeKeychainBacking on a bounded serial utility queue.
It supports lookup, explicit create/replace, exact delete and bounded metadata-only
listing. Interaction defaults to forbidden, and typed failures distinguish missing,
unavailable, denied, interaction-required, cancelled and signing-related outcomes.
Queued cancellation prevents backend work; running operations report their actual
outcome. Close asynchronously drains operations and the queue.

NativeCredentialSecret owns a bounded mutable allocation, with explicit copying,
input/clear/deinit wiping and redacted descriptions. Swift/Foundation/OS copies
cannot all be guaranteed erased. The storage layer itself does not decide when
server authentication permits credential reuse or persistence.
See [the Keychain policy](../../plans/native-ui/KEYCHAIN.md) for the selected backend,
attributes, signing requirements and acceptance limits. Tests use injected adapters;
no real Keychain or packaged-upgrade acceptance is claimed.

### Authentication retention and recovery

AppCoordinator shares the credential store across windows. Each ConnectionModel
owns a NativeAuthenticationCredentials controller whose pending/retained secrets
are private, with only status and availability published. Use once is the default;
retain-for-session values survive unexpected interruption but are cleared by manual
cancel/disconnect, rejection or close. Reconnect submission is an explicit button
at a matching current prompt, with username re-entry where needed. Remember saves
only on a matching connected generation. Persistence errors leave the VNC session
alive and report a fixed, redacted notice.

Use Saved Password performs one explicit lookup, allows OS interaction and checks
prompt/generation/epoch again before submission. A rejected saved value never
retries or deletes itself. Replace is explicit and successful-authentication-only;
Forget deletes the exact key. A saved value may be retained for session reconnect
without rewriting it. Close cancels pending work and joins running operations;
late results cannot restore UI state or credentials. App shutdown drains window
controllers before closing the shared store. Real packaged Keychain/OS interaction,
interactive keyboard/VoiceOver and dedicated trust storage remain open.


### Certificate policy and one-time trust presentation

NativeCertificatePolicy reads the shared C ABI classifier used by FLTK and native
PromptAuthentication. Fatal, unknown and zero-status certificate exceptions cannot
be approved through the prompt reply API, even if a frontend attempts it. SwiftUI
shows typed problems, certificate subject, full attempted destination and SHA-256
fingerprint; malformed DER also disables approval. Cancel is the default trust
action, and Connect Once describes its current-attempt-only scope.

NativeTrustPresentation computes SHA-256 over the owned certificate/key bytes.
RSA-AES's existing truncated SHA-1 compatibility fingerprint is shown separately
with the correct label. Debug descriptions redact identity material. These values
do not establish server trust automatically. NativeLegacyTrustStore now reads the
existing TidyVNC x509_known_hosts path. It preserves exact host/service/wildcard
matching and compares the exact DER SPKI through an owned optional GnuTLS C helper.
NativeCertificateTrust reuses a saved match only after certificate-policy checks
and only for the current prompt/generation. Changed keys display expected and
received public-key fingerprints; typed read errors remain visible. Window close
drains in-flight reads before shared-store shutdown. Parsing and file access are
bounded and fail closed on malformed, unknown or unsafe records. The legacy adapter is
read-only. NativeTrustStore now persists explicit scoped certificate decisions with
revision-checked writes and recovery. RSA-AES uses a separate kind/file with explicit
key decisions. CA/CRL defaults/profile controls are implemented; physical acceptance
remains open;
see [TRUST.md](../../plans/native-ui/TRUST.md). No user trust database or system
roots are modified by the tests.


### Scoped certificate persistence and management

NativeTrustScope uses the shared canonical endpoint parser and a separate X509-SPKI
hash domain. NativeTrustStore keeps bounded, versioned accepted-key or forgotten
records under the retained TidyVNC state directory's `native-trust` subdirectory,
honoring absolute XDG_STATE_HOME overrides. It uses NativePrivateFile's fixed
trust-exceptions record kind with a dedicated lock, exact-byte comparison, private
permissions, atomic rename and fsync. Profile record behavior is unchanged.

NativeCertificateTrust checks this scoped record before the legacy host-wide store.
Explicit changed/forgotten decisions and read failures cannot silently fall back.
Save/replace confirms the full attempted destination and approves the current prompt
only after confirmed persistence; conflicted or uncertain outcomes require reload.
The separate Saved Certificate Decisions window supports Forget and Ask Again for
legacy-only destinations. Removed key bytes are replaced by a suppression record
so a broad historical exception does not return. These records remain bounded and
are never silently evicted. Existing connections and ordinary successful CA
verification are unaffected. No system roots or legacy trust files are written.

NativeTrustLibrary and each window serialize one task and drain on shutdown before
the shared actor closes. Tests cover atomic failures, independent writer contention,
pre/post-commit cancellation, stale generations/revisions, closed schema/capacity,
canonical scope isolation and light/dark renders. Real UI confirmation/VoiceOver,
live native TLS/RSA-AES and file-picker acceptance remain separate gates; see [TRUST.md](../../plans/native-ui/TRUST.md).


### RSA-AES server keys

NativeTrustKind.hostKey uses a separate hash domain and server-keys.json record at
the dedicated XDG trust path. The certificate file's v1 shape and scope keys remain
unchanged. Closed kind/identity fields prevent treating a certificate record as an
RSA-AES approval. No certificate or legacy X509 lookup runs for a host-key prompt.

NativeHostKey calls shared rfb/RSAAESKey validation through HOST_KEY_ENCODING. This
checks canonical field widths and public-number constraints, preserves the retained
server's byte-rounded header, and returns actual modulus bits. Nettle preparation
and the RSA-AES private-key/hash proof remain in the protocol. Malformed affirmative
host replies are denied at the core boundary. Native SHA-256 and compatibility SHA-1
fingerprints are independently computed over the exact encoding and redacted from
descriptions. The app provides Save Server Key/Replace and Connect and a separate
Saved Server Keys management window. Cancellation/revision/atomic-write semantics
match certificate persistence; there is no cross-kind fallback.

Tests use public-only generated RSA fixtures, C ABI failures, malformed reply policy,
separate stores/scopes and native controller/render checks. Core loopback tests cover
all four RSA-AES security variants through the trust prompt and reject malformed
wire keys before prompting. Completion of the encrypted exchange and physical native
confirmation/VoiceOver remain acceptance gates, not implied by those tests.

### CA/CRL selections

Connection Defaults > Security > Certificate Files and saved profiles support independent CA/CRL PEM
file choices. `NativeTrustFiles` distinguishes absent/inherited from empty/no
additional file; default system trust remains enabled. Exact absolute paths are
bounded to 4096 UTF-8 bytes and validated without file IO. CA/CRL fields were introduced in preferences schema 5 and profile schema 4;
current writers use 8/7 and also support security selections and TLS priority. Older records are
read without rewriting. Apply/Save
and Cancel retain their existing revision and recovery behavior.

Paths are merged before constructing a session and held unchanged for that window.
A new window sees new defaults/profile values. For each X509 attempt the core reads
selected files on its protocol worker, and the bridge requires each selected file
to load successfully. Nonempty selections in a GnuTLS-disabled build are rejected.
No system roots or exception records are installed by this selector. The current
app stores local paths, not sandbox bookmarks. More detailed load-error presentation
and physical picker/keyboard/VoiceOver acceptance remain open. See
[TRUST.md](../../plans/native-ui/TRUST.md) for the complete policy and proof boundary.

### Security method defaults and profiles

`NativeSecuritySelection` reads the shared catalog and resolves canonical names
through checked C functions. Preferences/profile `security.types` is absent for
inheritance or an explicit list, including empty/deny-all. Profiles replace the
whole inherited list, never union it. Source and exact IDs are captured before
session construction and remain immutable as restoration baselines. Explicit local
security edits can replace the next-attempt policy while disconnected. Current store
schemas are defaults 11 and profiles 10; canonicalization occurs only on an explicit
write. Unknown/uncompiled selections are preserved and rejected.

Connection Defaults > Security and each profile's Security Methods disclosure
show exact methods, protection/authentication categories and disabled uncompiled
choices. The shared core keeps server offer ordering. Saving applies to new
connection windows; active connections and same-window reconnects retain their
policy. Advanced TLS Priority supports inheritance, an explicit library-default reset
and custom expressions. Storage actors preflight with GnuTLS before writes; invalid
expressions remain correctable without changing saved data. Empty uses the library
default, nonempty requires GnuTLS, and valid syntax does not guarantee peer
compatibility. Connection > Connection Settings > Security edits methods, TLS priority
and CA/CRL files while disconnected. Apply changes only this window’s next attempt;
Done then Connect starts that attempt. The core atomically checks generation and
revision and rejects active/stale edits, while the controller joins editor cleanup
and clears retained reconnect credentials after an accepted policy change. Initial
settings remain available for restoration. Physical acceptance remains open. See [SECURITY.md](../../plans/native-ui/SECURITY.md) for
method semantics, the C feature contract and the test proof boundary.

### Shared access and Retry

Connection Defaults > Connection, saved profiles and the disconnected window’s
Connection Settings > Connection sheet expose inherited/on/off choices for shared
access and Retry after errors. Shared defaults to false (the retained viewer default)
and sets the RFB ClientInit byte on each attempt; the server decides whether to honor
it. Retry defaults to true and offers an explicit action on recoverable errors, never
automatic reconnection. Manual Connect remains available when Retry is off.

Defaults schema 8/profile schema 7 add independent optional Boolean fields `shared`
and `reconnectOnError`. Old schemas remain readable without rewriting. Session-local
edits compare generation/revision, refuse active/draining attempts, preserve untouched
sources and never save durable settings. Native construction sets explicit sharing
before any connection. See [CONNECTION.md](../../plans/native-ui/CONNECTION.md).

## Explicit remote desktop resize

`NativeSession.desktopLayout()` returns a coherent owned remote-screen layout;
`requestDesktopLayout(_:expectedGeneration:)` awaits the server's response through
the normal completion/cancellation path. The wrapper uses shared C validation and
preserves all 255 possible screen IDs, rectangles and flags. Live capability,
view-only, one pending request and framebuffer limits are enforced by the core.

The native Resize Remote Desktop sheet offers an explicit resolution request,
actual-server-result feedback and joined dismissal. It is separate from local
scaling and window fitting. Automatic resize and initial-size policy now run through a per-session coordinator
with 100 ms coalescing, scaling/units/capability gates, manual-request suppression,
view identity/lifecycle handling and joined close. A local policy sheet applies
revision-checked settings; initial-size edits take effect on the next connection.
Resize defaults schema 9/profile schema 8 add independent optional enabled/initial-size
fields. Absence inherits; explicit blank size overrides an inherited request. Shared
validation/canonicalization, per-field sources and new-window isolation are preserved.
Full-screen display mapping remains pending. See [REMOTE-RESIZE.md](../../plans/native-ui/REMOTE-RESIZE.md).


### Explicit local-display layout chooser

Resize Remote Desktop now offers custom dimensions or all/selected local displays,
with a numbered visual arrangement, checkbox selection and logical/device units.
`NativeDisplayLayout` calls the shared C++ `DesktopLayout` through the checked pure
`tidyvnc_display_layout_compute` export (DISPLAY_LAYOUT); it does not implement a
second geometry algorithm. UUID selection, normalized mixed-density regions,
remote ID/flag reuse, missing-display review and admission-time source refresh are
covered by synthetic topology and real loopback wire tests. The display mapper was the 80th export; the current canvas-enabled ABI has
82 exports. This is explicit remote topology configuration, not local fullscreen
presentation or saved fullscreen preferences. See
[REMOTE-RESIZE.md](../../plans/native-ui/REMOTE-RESIZE.md) for limits and remaining gates.


### Per-monitor canvas presentation

The checked `NativeCanvasViewport` and `NativeDisplayLayout.viewport(for:)` values
now feed `NativeGeometry` and `NativeDesktopView.setCanvasViewport`. Rendering,
inverse input and damage all use the retained C++ `DesktopTransform` canvas path;
fit modes size against the whole canvas, and pan limits are global. Canvas units
are explicit and separate from ordinary window settings. Region changes preserve
old displayed pixels/input until replacement tiles arrive. Canvas views cannot
claim or publish the ordinary automatic window-resize source; clearing restores it.

CANVAS_GEOMETRY adds two pure exports, bringing the current ABI to 82. AppKit tests
verify separate regions on two views and wire pointer coordinates, delayed rendering,
source damage, invalid candidates, resize ownership and joined close. Fullscreen
window lifetime and policy integration remain separate work;
see [CANVAS.md](../../plans/native-ui/CANVAS.md).


### Multiple native surfaces and input ownership

Native view focus now carries a session-local surface token. Transfer releases
held remote input and invalidates the previous clipboard focus interval before
admitting the next view. Background rendering, blur/hide/close and late input cannot
revoke or send through another view's scoped route. Deferred deinit releases only
its own token. Session generation changes, disconnect/global focus loss and close
clear ownership. Public unscoped focus keeps its existing live-view behavior for
other consumers; native focus acquisition always uses the scoped path.

Commands keep weak surface registrations and follow focus rather than the latest
attachment. Capture/status/modifier reports from inactive hosts are ignored, and
explicit detach recovers another registered command host without taking focus.
Repeated focus callbacks for the same owner do not enqueue command recovery or
publish redundant UI changes.
Loopback tests exercise held keys/buttons, late IME/key/pointer events, background
rendering, command window targeting, capture cleanup and destruction/reconnect.
Injected window/capture backends do not establish physical multi-display behavior.
Full details and fullscreen integration work: [CANVAS.md](../../plans/native-ui/CANVAS.md).

`NativeDesktopCanvas` now coordinates weak surface membership, whole-layout
scaling/unit mapping and shared pan. Configure preflights every surface before
replacing an arrangement. Scaling Apply validates all registered independent views
and canvas groups before committing state. Pan commands from any member update the
group, with common bounds derived from the current remote frame; shrink/growth do
not restore discarded offsets. Close and scoped deferred destruction restore
windowed geometry. The fullscreen window-owner prototype creates these groups and handles actual
display changes. The experimental app now binds this owner as described below.

### Fullscreen window-owner prototype

`NativeFullscreenController` creates dedicated per-display desktop windows over a
shared session/canvas, preserving the original SwiftUI window and its delegate.
Current/all/selected stable IDs and explicit native-Space/borderless strategies
support the plan's pending physical comparison. Entry/exit gate input; owned native
delegate callbacks and bounded deadlines drive completion/rollback. Topology change,
disconnect and close release the owned windows and restore the original host.
Hidden construction exercises the actual AppKit backend; injected transition tests
do not move the user's Spaces. Visible app interaction acceptance, durable policy/
reconnect integration and physical strategy selection remain open. See [FULLSCREEN.md](../../plans/native-ui/FULLSCREEN.md).


The `native-fullscreen-comparison` CMake target builds a signed developer app with
an owned loopback color-pattern desktop and current/all/selected display controls.
It compares native Space and borderless strategies without loading user settings;
clipboard and automatic capture are off. `--verify` runs offscreen construction
and light/dark rendering as `NativeDesktop.FullscreenComparisonHarness`. Interactive
single-Retina entry and exit exposed and fixed work-area changes cancelling native
entry. The controller now compares full geometry/identity/scale, while preserving
work-area notifications for other consumers. Commands route Exit to the weakly
registered owner and gate transition conflicts. Physical multi-monitor/keyboard
acceptance and durable app policy remain open; see FULLSCREEN.md above.


Owned fullscreen Minimize now exits the temporary window group and minimizes its
original window through the existing bounded command operation. Native Spaces
waits for the owned primary's successful exit; borderless cleans up synchronously.
Sheets, failure/deadline, topology/lifecycle changes or changed ownership cancel
the pending intent. Entry is blocked while the original minimize completes.
The comparison menu exposes Minimize and Restore Test Desktop; real single-Retina
checks recorded original-window miniaturize/deminiaturize notifications for both
strategies. This does not select the final multi-monitor strategy or complete
visible application acceptance.


### Connection-owned fullscreen in the experimental app

NativeFullscreenState now connects NativeDesktop's source lifecycle to the owner,
with scoped entry callback/window-behavior tokens and owned-window activation
routing. The experimental app uses native Spaces provisionally, exposes a copied
current/all/selected display draft with topology review and missing-ID fallback,
and defers settings/info/error presentation until the original window returns.
Minimize uses the same owner; statistics actions return to the windowed host.
New tests exercise the actual ConnectionModel and render the display sheet in both
appearances. Durable policy/source tracking, reconnect restoration, fullscreen
statistics overlays and visible mixed-monitor/Spaces acceptance remain open.


### Automatic fullscreen remote layouts

Owned fullscreen now reserves automatic-resize ownership for the complete canvas.
Entry/exit transitions suspend requests; active Unscaled mode uses all selected
regions from the shared logical/device layout. Initial-size requests retain their
single-screen, once-per-attempt precedence. Temporary surfaces never replace the
original window's viewport; cleanup restores it, with minimize and sent-request
drain gates. Manual/initial holds expire on changed eligible geometry and cannot
silently reactivate when returning to an earlier arrangement. See
[REMOTE-RESIZE.md](../../plans/native-ui/REMOTE-RESIZE.md) for wire behavior and
NativeFullscreen.AutomaticRemoteLayout coverage. Physical multi-monitor/Spaces
acceptance remains separate.


### Statistics in owned fullscreen windows

The windowed panel is shared as NativeConnectionStatisticsOverlay. Every owned
fullscreen content container adds a passive sibling hosting view when enabled;
its native hitTest returns nil and it cannot become first responder. The existing
controller snapshot subscription distributes copied sampled values, with no new
frame subscription or timer. Menu toggles remain in fullscreen. Entry/exit hide the
hosts, ordinary window return retains visibility, and disconnect/stop/close clear
it. See [FULLSCREEN.md](../../plans/native-ui/FULLSCREEN.md) for tests and limits.

## Connection-document bridge

NativeConnectionDocument exposes the shared portable codec as an immutable
Sendable owner. Initialize it with bounded Data to copy ordered names, escaped
values and source lines, then call decodedValue(at:) only for understood fields.
The native wrapper rejects invalid UTF-8 explicitly. NativeDocumentFailure carries
a typed reason and source line; diagnostics contain no supplied values.

serialize accepts explicit NativeDocumentAssignment values, uses the shared
non-secret catalog and returns owned Data with the current file header. Unknown
and deprecated records are not exported implicitly. The wrapper performs no IO,
settings mutation, credential lookup or preference migration. Semantic file
application, native review/panels and launch routing remain pending.

The C bridge adds CONNECTION_DOCUMENT and four exports (86 total), with immutable
retain/release handles, size/version-tagged copied outputs, deferred value decode,
size-query serialization and no-write failures. See
[DOCUMENTS.md](../../plans/native-ui/DOCUMENTS.md) for contracts and limitations.

NativeDocumentResolution now converts a parsed explicit file into an isolated
NativeSessionConfiguration. It validates all recognized occurrences, applies
last-assignment and deprecated-field rules, retains inactive cursor metadata and
records file provenance. Supply an already-resolved defaults/profile/CLI base,
explicit legacy monitor-to-ID mapping and invocation directory for relative CA/CRL
paths. Unknown/platform-only fields require notice acknowledgement; invalid known
values cannot be skipped. Missing ServerName clears the endpoint. The resolver
performs no IO. Explicit Open and Finder use it for review before idle session
admission; Save As uses the corresponding non-secret compatibility export.
DOCUMENT_OPTIONS adds the semantic query (87 C exports) and DOCUMENT source.

NativeDocumentLaunchRouter queues bounded local-file requests until the app supplies
its SwiftUI window action. Modern URL and filename delegate callbacks share this
entry point; repeated explicit opens have distinct IDs and quit revokes pending
work. NativeDocuments.SwiftUIWindowActionLifetime is an isolated signed test app,
not part of the shipped viewer, and proves routing after all app windows close.
Finder requests use the same review/session admission as explicit Open, and window
titles identify each file. CLI invocation and release association/consent remain
separate gates. See plans/native-ui/DOCUMENTS.md for evidence and limitations.


Explicit-file monitor recovery uses NativeDocumentMonitorMapping to retain the
parsed document/base/directory while a native chooser maps up to 64 distinct file
numbers to connected stable display IDs. Sparse Int32 indices are dictionary keys,
not allocation sizes. Mapping cannot bypass ordinary field validation or final
ignored-field review. NativeSessionDefaults validates connected assignments, gives
final review a fresh identity and checks topology again before creating an idle
session. Automatic mappings are editable; closed/cancelled/stale drafts never
create sessions or write stores. The production mapping/review views have an
isolated synthetic-display fixture. Import/export recovery is described below;
physical multi-display/Spaces acceptance remains open. See DOCUMENTS.md.


Save As also supports explicit export numbering through NativeDocumentExportCapture
and NativeDocumentExportMapping. Preflight rejects unsupported/security-loss cases
before UI; a captured configuration never rereads live values while assigning IDs
to unique positive file ordinals. Saved disconnected and dormant selections can be
represented without modifying live fullscreen policy. Final review lists exact
numbers and existing loss notices, then one sheet dismissal admits the destination
panel. Stable IDs/names never enter compatibility bytes. NativeDocuments.ExportMappingAndSheetLifetime
uses a production sheet with fixture-only private output. The existing system-panel
and physical-display acceptance gates stay open.


Defaults import supports manual monitor recovery and editing through
NativeDefaultsImportProjection/NativeDefaultsImportMapping. Only filtered allowed
entries, original lines and redacted notices survive initial parsing. Exact connected
assignments create a new final review; omission consent is always separate. Automatic
acceptance checks legacy order, while manual acceptance checks current available IDs.
No source reread/write or session creation occurs during recovery, and native storage
still admits only an absent record. NativeImport.DefaultsMappingRecovery exercises
production UI with temporary sources, synthetic displays and injected memory storage.
See [IMPORTS.md](../../plans/native-ui/IMPORTS.md) for contracts and limitations.


NativeInvocationSyntax wraps the shared bounded CLI parser/catalog through four C
exports and copies every returned span before release. It preserves literal values,
ordered occurrences, aliases and source positions without global registry access,
IO or environment lookup. Syntax success does not validate options or authorize
startup operations. The app executable is not yet wired to consume CLI inputs;
[CLI.md](../../plans/native-ui/CLI.md) tracks semantic resolution, bootstrap and
credential/listen/tunnel integration required for parity.


Native input now uses the shared 17 ms pointer-event interval by default.
PointerEventInterval CLI values (including explicit zero) are captured with source
metadata and sent through INPUT_TIMING session creation. Delayed motion stays on
the protocol worker after middle-button emulation; native focus, view-only,
release and close keep the same generation/routing barriers. File review preserves
CLI timing, while Save As reviews its omission from the compatibility format.
The wrapper requires the additive input-timing feature. The message-limit addition
and window-geometry parsing bring the C ABI to 97 exports.

Native MaxCutText CLI values now reach each session's incoming reader through
MESSAGE_LIMITS. Nil configuration reads the shared 256 KiB default; explicit zero
and INT_MAX are valid, with provenance retained across review and reconnect. This
limits incoming wire/decompressed clipboard data; UTF-8 mailbox and pasteboard
retention budgets remain separate. Save As reviews the omitted limit. No preferences
or profile schema changes, process-global policy mutation or general-pasteboard
access occurs during invocation resolution.

Initial `geometry`/`Maximize` CLI policy now uses a checked shared geometry parser
and one ordinary-window placement owner. It waits for session admission, converts
primary-top-left coordinates to AppKit logical content coordinates, accounts for
window decoration/work areas and consumes placement once before automatic fullscreen.
Closing revokes pending placement; reconnect/view reconstruction cannot override a
later user resize. No-host CLI forms and reviewed files use the same admission path.
Native stores are unchanged and compatibility export reviews the omitted policy.

## Reverse listener bridge

NativeRuntime.makeListener creates a separate bounded listener; NativeListener owns
copied MainActor snapshots and pending peer values. Readiness arrives through the
existing coalesced NativeDelivery path rather than recurring polling. Peer values
are scoped to their originating listener. Explicit accept transfers one peer into
a caller-configured NativeSession and awaits its ordinary connect completion;
reject and pending expiry close unclaimed sockets. Stop preserves accepted sessions.
Close and runtime shutdown drain listener workers, subscriptions and queued host
work without a UI-thread join. Initial event history is consumed before the wrapper
is exposed, keeping published state ordered.

The C ABI exposes numeric addresses and typed errors. Reverse source ports are not
stable saved-server keys; this wrapper performs no credential/history/trust-store
routing. App launch/presentation implements the scoped reverse policy described in
[LISTEN.md](../../plans/native-ui/LISTEN.md)
and native test 76 for the current boundary and fixture evidence.

The app's File > Listen for Connections action now owns a ListenerModel/window with
explicit Start/Stop, port/family selection and pending Accept/Reject controls.
Acceptance opens an app-owned connection window and resolves native defaults before
handoff. Reverse models use connection-only credentials/trust decisions and suppress
history, address editing, outbound retry and document export. Stopping the listener
preserves accepted sessions. App quit revokes incoming actions and drains both window
classes. Numeric CLI `-listen [port]` opens this presentation in the first ordinary
scene and binds once, with checked port and family settings. Accepted sessions
inherit CLI options; only the first successfully opened incoming window receives
the launch credential owner. Stop/close revokes unclaimed inputs. Reappearing views
and later incoming peers cannot recapture credentials or replay the launch. Explicit
file/socket listen operands still fail before IO. Native test 77 covers model/window
lifetime and loopback routing; TODO.md records the limited visual/installed scope.
