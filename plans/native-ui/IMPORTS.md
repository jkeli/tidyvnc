# Native settings and history import

Status: defaults and history each have explicit current/legacy source choices,
immutable review, separate consent, native precedence and transactional markers.
Both have native review windows, File-menu actions and independent first-use
offers. Defaults monitor assignments support manual recovery and editing.
History success refreshes the shared recent-address list.
This is not an automatic startup migration or a new XDG writer.

## Review projection

`NativeDefaultsImport` accepts bounded document bytes, an explicit origin
(`currentXDG` or `legacy`) and an explicit legacy monitor ordering. Both origins
use the same ordinary-settings allow-list. The shared document parser validates
syntax and every recognized occurrence, including earlier duplicate assignments.
Malformed recognized values fail even if that known field is excluded. Unknown
values and macOS-unavailable audio/primary-selection values remain undecoded.

Server addresses, security methods, TLS priority, CA/CRL paths, passwords, user
names, tunnel routes and other non-allow-listed fields cannot enter the native
preferences candidate. Notices contain names and original line numbers, never
source values. The proposal retains no source document or original byte buffer.
Its output is a closed `NativePreferences` value containing only explicitly
represented connection, clipboard, encoding, input, scaling and fullscreen fields;
it does not materialize unrelated compiled defaults. The origin is a caller's
explicit choice, not a guess based on the file header.

Allowed raw entries are projected into a bounded document with blank-line padding
that preserves original source positions. The existing native document resolver
then handles aliases, canonical values, post-file deprecated migrations and
monitor mapping. This shares conversion semantics with explicit Open instead of
adding another option parser. A valid limit-sized file without its final newline
stays within the same byte limit during projection.

The review exposes affected categories and notices. Every ignored/excluded field
must be acknowledged before obtaining the candidate. Converting monitor numbers
to stable display IDs requires explicit supplied mapping and acknowledgement.
The native defaults representation cannot retain a hidden System cursor's dormant
shape, so that conversion also requires a loss notice; the hidden behavior itself
is preserved. Unresolved monitor numbers open an explicit display chooser. Automatic
assignments can also be edited. `NativeDefaultsImportState` retains exact request,
mapping and review identities; completing a mapping creates a fresh review and does
not acknowledge omissions. Automatic imports check the reviewed legacy ordering;
manual imports check the current available-ID set. The UI supplies a fresh display
snapshot at resolution and acceptance.

## Source discovery and review lifetime

`NativeImportPaths` takes an explicit home directory and launch environment.
Absolute XDG config/state overrides are honored independently; relative and tilde
values are ignored. Invalid absolute paths fail rather than falling back. The
current defaults/history paths and ordered legacy XDG then `~/.vnc` candidates
match the retained migration policy. Path construction does not touch disk or
standardize parent components across symlinks. History uses those state paths
through its own service; no history bytes are read by the defaults service.

`NativeDefaultsImportService` first checks native storage, then inspects sources
on its actor. Only real absence advances to the next legacy candidate. Errors,
malformed contents, dangling links, non-directory ancestors, directories, FIFOs
and oversized files fail without selecting another source. An existing current
TidyVNC defaults path also blocks legacy import, including when it is malformed or
a dangling link. Current-XDG requests never fall back to legacy implicitly.
Sources are read by `NativeDocumentFileReader`, with its 1 MiB regular-file bound,
descriptor consistency checks and cancellation. Source symlinks resolving to
regular files are allowed, as with explicit Open. This is not a hostile-filesystem
snapshot guarantee: pathname inspection and descriptor opening are separate.

The resulting review owns an immutable projection, source URL and monitor ordering;
approval imports exactly that reviewed snapshot, even if another application has
since changed the source. No second source read can substitute unreviewed values.
Source files are never written or deleted. The preferences store freshly checks
native precedence at commit, and the reviewed mapping must still match before a
monitor conversion can be accepted.

`NativeDefaultsImportState` distinguishes loading, mapping, review, writing, no source,
failure and success. Request IDs cancel reads; only the exact preview ID can
approve a proposal. Missing acknowledgements keep the review open. Cancellation
invalidates the preview, drains the in-flight read before another starts, and
suppresses late delivery. Closing cancels and joins pending work. Once a write is
accepted, shutdown does not pretend it rolled back; closed UI suppresses its
result. Errors expose controlled messages rather than arbitrary backend values.
The app's File menu exposes **Import Connection Defaults…**, which presents
separate **Review Current TidyVNC Defaults** and **Review Legacy Defaults** choices.
An idle ordinary connection window offers the same action while native defaults
are absent. **Not Now** dismisses that offer for the current launch; it does not
write a migration marker or hide the File-menu action. A native-store observer
removes the offer after saved native state appears. Corrupt/inaccessible state is
never eligibility for the offer, and app activation refreshes external changes.
No compatibility source is read until the user chooses it in the import window.

## Native import window

The review lists affected categories, omitted fields by source line and monitor
conversions with the captured display names/order. Values excluded from import
are not displayed. The user must acknowledge all listed omissions/conversions
before **Import Defaults** becomes available; an empty ordinary-settings candidate
cannot be imported from the UI. Display availability/order is refreshed at acceptance.
Cancel/Escape returns to source choices without writing. Missing files and errors
are distinct outcomes and permit an explicit new review. A successful import
offers **New Connection**, because existing connection windows retain their
already-resolved settings. Files are a one-time copy, not synchronized stores.

Each window presentation owns a new import state. Close revokes callbacks and
drains pending work, then releases the window content; reopening cannot revive a
closed review. App shutdown stops and joins the import window and availability
observer before closing the preferences store. AppKit owns window size so content
changes do not shrink the window during review. Long notices use a scroll view;
acknowledgement and action buttons remain outside it.

## Display mapping recovery

`NativeDefaultsImportProjection` retains only allowed entries, original line numbers,
redacted notices and origin. Raw source bytes, excluded values and opaque unknown
values are discarded before retaining a mapping request or review. The proposal
itself still owns only the closed candidate, categories and notices. Recovery uses
`NativeDocumentMonitorMapping` on the filtered document, with sparse positive Int32
keys and at most 64 distinct monitor numbers. It never sizes an array from a file
number or rereads the source after the initial projection.

The native chooser requires a currently connected display for every required number.
Several numbers can select one display, which is persisted once. Refresh shows
changed availability; disconnected assignments cannot advance. Final review lists
the exact number/display pairs and offers **Change Display Assignments…**. Editing
retains connected manual choices but clears omission acknowledgement. Every resolve
creates a new proposal UUID. Stale mapping/review callbacks and cancelled or closed
states cannot write. A topology mismatch at commit fails without a native record;
the user must start a fresh review. Rearrangement with the same available IDs remains
valid for explicit assignments. Native absence-only admission and current-over-legacy
source precedence are unchanged.

`NativeImport.DefaultsMappingRecovery` exercises the production view/controller with
synthetic mirrored displays, temporary sources and an injected in-memory store. It
covers sparse bounds, incomplete/disconnected assignments, automatic editing,
filtered retention, changed source bytes, separate consent, stale callbacks,
availability changes, many-to-one conversion, same-record origin, competing native
writes, cancellation/read drain and window close. It renders light/dark chooser and
review states. This does not establish physical multi-display or supported-OS parity.

## Commit and marker

`NativePreferencesStore.importDefaults` freshly reads the native record and only
admits an absent record. Existing empty/reset values win too. Corrupt, future,
unsupported or inaccessible native records fail; they are never treated as
absence and never trigger fallback import. An ordinary save racing an import
uses the same owning store actor and revision rules. Only one absence-based
operation can win within that actor.

Defaults envelope schema **11** adds optional `importedFrom` metadata with the
closed origin enum. Imported values, a fresh revision and the marker are encoded
in **one** backing write. Regular saves and resets retain the marker. Repeated
import refuses to overwrite the stored record, preventing reapplication even
after reset. Invalid/unknown marker values fail closed. Schemas 1–10 remain
readable without write-on-read; normal successful saves upgrade to 11. The separate
profile/history schema is now **11** (route persistence in TUNNELS.md); the C ABI is unchanged.

Cancellation and validation failure before write do not mark migration. A backend
failure before acceptance leaves no record. If a backend accepts the write and
then reports failure, rereading reveals the values and marker together; retry
cannot overwrite that state. UserDefaults acknowledges acceptance rather than
fsync/crash durability and does not provide cross-process compare-and-swap.
Those existing storage limits also apply to import; a separate marker file would
not improve them and would introduce a second-write failure window.

No source path, source address, excluded value, credential or trust record is
stored in the marker. The projection/store transaction performs no source-file IO
or deletion, creates no session and calls no credential/trust service. The separate
discovery service reads only explicitly requested defaults sources. History
has its own separate UI consent and app integration, described below.

## Separate history import

`NativeHistoryImport` accepts explicit-origin UTF-8 history bytes with a 1 MiB
whole-file bound and the retained legacy import's 254-byte per-entry bound. It
accepts LF/CRLF and a final line without a newline, ignores blank lines, keeps the
first occurrence of each exact string and retains the first 20 unique entries in
source order (most recent first). Duplicate and over-capacity counts require
explicit omission review. Every line is validated, including entries beyond the
retained 20; invalid UTF-8, NUL and overlong lines fail with line-only diagnostics.
Whitespace, case, host/display/port spelling and IPv6 scopes are not normalized.
Duplicate comparison follows the native store's Swift String equality; it does
not resolve DNS or collapse endpoint aliases. This is an address-text format,
not an option/credential parser. Protocol validation remains at connection entry;
import creates no connection and reads no credential or trust source.

`NativeHistoryImportService` independently selects current history or legacy XDG /
home history. Current settings files have no effect on history-source selection.
Existing current history blocks legacy history, and only absence allows fallback.
The shared source inspector and bounded file reader retain the defaults service's
failure/cancellation behavior. The review retains exactly the parsed list and the
native profile/history revision observed before reading. Source edits cannot
substitute unreviewed addresses at commit; native profile or history edits require
fresh review. Sources are read only after an explicit current or legacy choice.

Profile/history schema **10** adds required `historyState`: `uninitialized`,
`native`, `currentXDG` or `legacy`. It describes first history initialization and
is preserved by later edits. An absent record starts uninitialized. New
profile-only saves and deletes preserve that state, allowing a history import
without losing profiles. Recording a native recent address or explicitly clearing
history initializes it as native. Imports atomically save addresses, fresh
revision and origin state in the same record. Later recordings, clears and profile
edits preserve the import marker, so clearing cannot silently re-enable import.
Uninitialized state with nonempty history is corrupt; unknown/missing/wrong-type
state metadata fails closed. Defaults schema remains **11**.

Schemas 1–9 remain readable without writes and are treated as already initialized,
including an empty history list: those records cannot distinguish an untouched
history from a deliberate prior clear. Explicit later writes now upgrade them to 11
while preserving that precedence. No historical emptiness is inferred as consent.
Schema 10 introduced this marker. Schema 11 retains it while representing recent
connections with their routes; imported compatibility addresses remain direct.
Older native builds reject newer schemas rather than silently dropping state.

History import preserves the complete native profile array, including opaque
credential references already there. It checks the shared revision and uses the
existing private-file expected-byte commit under the cooperating-writer lock.
Validation/cancellation/precommit failure cannot set an import marker. If rename
succeeds but later confirmation fails, rereading reveals addresses and marker
together; retry cannot reapply the import. The existing private-file permissions,
atomicity and uncoordinated-writer limitations remain in effect. The app reloads
`NativeRecentHistory` on successful import and after the import window closes,
including uncertain writes. This store has no change subscription or automatic
cross-process synchronization; app activation also reloads it.

## History review and app lifetime

**File → Import Recent Connections…** opens a separate window with current and
legacy source actions. The review shows the source path and the exact ordered list
of up to 20 addresses. Duplicate and older-entry omission counts stay visible
outside the scrolling list and require acknowledgement before **Import History**
is enabled. An empty source can be reviewed but cannot be imported from the UI.
Escape cancels review, and a new review resets acknowledgement. Import never opens
a session, changes defaults or selects an endpoint in an existing connection.

`NativeHistoryImportState` owns exact request/review identities. Cancelled reads
must drain before another request starts; late results cannot revive a review.
Closing stops callbacks, cancels and joins IO before releasing the presentation.
A write accepted before cancellation remains accepted, even if the window closes
before its result. Errors use controlled history-specific messages, never arbitrary
backend descriptions. Fresh native revision checks reject intervening profile or
history edits. The window can be reopened with a new state after drain.

An idle ordinary connection window independently offers history import while a
fresh native snapshot says history is uninitialized. Busy, failed, closed,
initialized and older-schema stores never qualify. **Not Now** dismisses only the
launch-local offer; the File-menu action remains available. This model reads native
storage, not compatibility sources. App shutdown revokes and joins the history
import window before closing the shared profile/history store.

## UI test isolation

A different test-app bundle identifier does **not** isolate native preferences:
`UserDefaultsPreferencesBacking.applicationDomain` is a fixed suite name. Future
live import UI fixtures must inject a disposable backing or unique explicit suite,
as well as fixture-only source paths. They must not exercise successful import
against the user's real native defaults or profile/history stores.

`native-import-ui-tests.app` uses the production view/window controller with an
in-memory preferences backing, generated temporary current/legacy sources and
two synthetic displays. `--verify --output <directory>` exercises and renders the
flow automatically. Without arguments it opens the same isolated fixture for
interactive checks; its Fixture menu resets only its own state, selects legacy
fixtures or changes its synthetic display ordering. It has no connection-file
association and never creates a network session or accesses production stores.

`native-history-import-ui-tests.app` similarly injects in-memory profile/history
storage and temporary sources. It compiles the production history view/controller,
exercises request cancellation and accepted-write shutdown, stale review refusal,
omission consent, explicit legacy precedence and shared recent-list refresh, and
renders light/dark review, choices, conflict, success and empty states. Its Fixture
menu supports interactive checks without real native-store access or connections.
