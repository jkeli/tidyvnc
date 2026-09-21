# Connection documents

Status: shared syntax/serialization, owned C/Swift bridge and native configuration
resolution, new-window integration, review UI, explicit Open panel and Finder file
routing implemented. Immutable loss-aware export and live connection capture are
implemented, with native Save As review, destination selection and atomic
create/overwrite. Explicit Open now has manual monitor mapping and recovery.
Separate defaults/history imports, including defaults monitor mapping recovery,
are documented in IMPORTS.md. CLI routing and physical display acceptance remain
open; Save As also supports explicit exported monitor numbers.

## Shared codec

`viewer/core/ConnectionDocument` owns a document's ordered entries and header
kind. It depends only on the C++ standard library. Parsing performs no IO,
parameter mutation, credential lookup, environment lookup or migration. Errors
contain a reason and one-based line number, never source text. The returned
document owns its bytes independently of the caller and can be read concurrently.

Both existing version-1 headers remain accepted exactly. Lines preserve historical
LF/CRLF handling, column-zero comments, case-sensitive stored names, the first
equals separator, duplicate assignment order and final lines without a newline.
The consuming frontend matches names without ASCII case and applies understood
entries in order. There is no whitespace trimming or new alias interpretation.
Values use the existing backslash, newline and carriage-return escapes.

Unknown entries remain syntax records and are not automatically decoded. This
preserves the retained reader's behavior: an unknown option with a future escape
is ignored, while an invalid escape in an understood option fails the transaction.
Syntax success is deliberately **not** semantic validation. The retained adapter
still validates option values, honors compiled availability and migrates the two
deprecated fields after applying the document. Its snapshot restores global
parameters if any understood value fails.

The historical line bound is 254 bytes including terminators. New whole-document
limits are 1 MiB and 4096 assignments; exceeding either fails without truncation
or adopting partial settings. The retained file adapter reads bounded chunks,
closes its input through RAII and never treats malformed/inaccessible state as
absent. The limits also apply to comments and ignored options where relevant.
The portable syntax layer preserves non-NUL bytes; the native text bridge rejects
invalid UTF-8 explicitly rather than replacing bytes silently, including invalid
text in comments and ignored fields.

## Export and retained integration

The serializer always emits the current header. Its explicit catalog contains
ServerName and the historical GUI-persisted fields, including platform-dependent
Audio/primary-selection fields. It rejects unknown fields, deprecated fields,
password/password-file/user inputs and tunnel commands. It does not round-trip
unknown input records. Public security types and CA/CRL paths remain valid for
explicit connection-file saves; that does not authorize preference migration or
saved trust/credential export. The existing legacy importer continues to exclude
ServerName, SecurityTypes and CA/CRL paths and preserves original sources.

Save validates the complete escaped output **before** opening the destination.
This fixes a retained-viewer bug where the 255-byte value buffer could fit a
value whose full name/value line was too long for the reader. Such saves now fail
and preserve the existing destination. Every successful serialization can be
parsed by the same syntax codec. POSIX replacement still uses AtomicFile, private
permissions and existing symlink/overwrite protections. Windows explicit saves
also preflight before opening; existing registry routing is unchanged and shares
the escape helpers. Windows execution has not been validated here.

The catalog is a file-format boundary, not the complete native settings schema.
For example, native display UUIDs must not be written as legacy monitor indices,
and settings absent from the historical file reader need an explicit compatibility
decision. No native defaults/profile schema changes are needed for the codec.

## C and Swift ownership

The additive CONNECTION_DOCUMENT feature provides four exports: parse, metadata,
entry copy and serialize. A parsed C handle owns an immutable document; normal
retain/release and the synchronized registry protect concurrent readers. Metadata
and entries are copied to size/version-tagged structs; no borrowed spans escape.
Entry queries choose raw or decoded values explicitly, with NO_CHANGE for an
index beyond the document. A failure never modifies output handles or structs.
Document-domain errors pack the reason and one-based source line into detail and
keep diagnostics free of supplied text. Resource errors distinguish size/line/
entry limits. No runtime, session, callback or event loop is required.

Serialization accepts decoded name/value spans and uses the shared catalog. A
null/zero buffer queries the required size; a real buffer must fit the entire
result. Preflight, allocation, invalid input and capacity failures leave both the
buffer and returned size unchanged. Success copies exactly the document bytes,
without a terminator. The interface accepts opaque bytes for retained compatibility;
the Swift wrapper explicitly rejects invalid UTF-8 before parsing.

NativeConnectionDocument is an immutable Sendable owner with copied String
metadata and ordered NativeDocumentEntry records. decodedValue(at:) invokes the
same C++ escape decoder on demand. Negative/out-of-range Swift indices produce a
typed failure. The handle is adopted before copying metadata, so construction
failure also releases it. serialize uses a bounded flat buffer for input spans,
queries the exact output size and returns owned Data after checking the final size.
No file read/write, store update, preference migration or option application occurs
in this wrapper. A caller must explicitly build an understood export assignment
list; there is deliberately no automatic parsed-document export method.

## Remaining integration

1. Verify physical mixed-display/Spaces behavior. Explicit Open and defaults import
   have manual display choosers; Save As has an export-numbering chooser. Synthetic
   fixtures do not establish physical display acceptance.
2. Integrate invocation options and CLI launch routing. Explicit Open and Finder apply
   files after native defaults/optional profiles and retain resolution metadata for
   the connection lifetime. Opening does not auto-connect.
3. Verify the remaining Save-panel keyboard/quit and persistent file-grant/bookmark
   recovery gates. Native Save/overwrite and separate current/legacy defaults/history
   imports are implemented, with native precedence and post-success markers.

## Verification (2026-09-20)

Eight codec unit tests cover exact headers, line endings, comments, raw bytes,
duplicates, unknown/deferred escapes, typed redacted failures, all resource
boundaries, allow-listed exports, escaped-output reloadability and concurrent
independent documents. Retained-viewer regressions cover actual load/save/import,
semantic rollback, duplicate/case handling, ignored unknown escapes, destination
preservation on oversized save, private permissions and no fallback on corrupt
or oversized current state.

The clean headless dependency audit and 663 unit tests plus both smoke consumers
passed. The final Audio catalog correction was rechecked by the focused codec
suite. Retained Debug viewer/codec/parameter suites pass 23/23; codec ASan and TSan
pass 8/8 each. The retained FLTK viewer builds. No native UI, ABI, defaults schema
or profile schema changed, so the previous 46-test native result remains separate
evidence; it was not rerun for this codec-only extraction.

Logs: `/tmp/tidyvnc-document-headless.log`,
`/tmp/tidyvnc-document-headless-final-{build,tests}.log`,
`/tmp/tidyvnc-document-fltk-{build,tests}.log`,
`/tmp/tidyvnc-document-{asan,tsan}-{build,tests}.log`, and
`/tmp/tidyvnc-document-branding.log`.

### Bridge coverage

The 47th native test, NativeDocuments.CodecOwnershipAndExport, exercises the
actual Swift owner against the C++ codec: copied input lifetime, both headers,
ordered duplicates, deferred unknown escapes, strict UTF-8, typed/redacted errors,
byte/entry/index boundaries, canonical exports, secret-field rejection, exact-size
round trips and shared/independent concurrent tasks.

Six DocumentABI tests cover copied C outputs after release, normal retained
lifetimes, wrong/released handles, malformed spans/flags/versions, opaque bytes,
untouched extended-struct tails, no-write failures, exact-capacity canaries,
serialization query semantics, typed errors, concurrent readers and 48 injected
allocation-failure positions for both parse and export. The pure C99 smoke
consumer also parses, decodes, exports and reparses documents using the new
feature. This is codec/ownership evidence; no native panel or semantic application
acceptance is inferred from it.

Reproduction: `/tmp/tidyvnc-verify-document-bridge-final.py [empty|-asan|-tsan]`
builds every native test, the comparison app, document ABI tests and pure-C smoke
consumer, then runs CTest in each actual tests directory with `--no-tests=error`.
The first focused command pointed CTest at the repository build root, which has
no registered tests; it failed and was corrected to the explicit tests folders.
No empty test run is counted as validation.

Bridge final verification (2026-09-20): **47/47** native tests pass in normal
(**70.68 s**), ASan (**79.86 s**) and TSan (**183.65 s**) builds. All three also
pass **6/6** document ABI tests and the expanded pure-C consumer. The headless
configuration passes **669/669** unit tests (**20.30 s**) and **2/2** smoke
consumers. The native app builds; strict deep ad-hoc signatures for the app and
comparison fixture, branding/attribution audit (**1650** existing deferred
occurrences) and `git diff --check` pass. Symbol inspection matches the **86**
public C declarations. Durable schemas remain defaults **10** / profiles **9**.
Sanitizers retain GnuTLS disabled; the existing dependency deployment warnings
still leave minimum-macOS, Intel and release-distribution acceptance unproven.

Logs: `/tmp/tidyvnc-document-bridge-final-native{,-asan,-tsan}-full-{build,tests}.log`,
`/tmp/tidyvnc-document-bridge-final-native{,-asan,-tsan}-{unit,viewer}-tests.log`,
`/tmp/tidyvnc-document-bridge-headless-{build,unit,smoke}.log`,
`/tmp/tidyvnc-document-bridge-final-app-build.log`,
`/tmp/tidyvnc-document-bridge-final-signature.log`, and
`/tmp/tidyvnc-document-bridge-branding.log`.

## Shared semantics and native resolution

DocumentOptions validates one understood historical file field independently of
legacy global parameters. It returns a canonical name/value, leaves unknown
fields undecoded and reports invalid/unavailable values at their source line.
Encoding, scaling and security use their existing shared validators. Boolean
syntax is now extracted into core/ParameterValue.h and shared by BoolParameter,
EncodingOptions and document validation; empty enables a boolean and whitespace
is not trimmed. Enum/list syntax preserves historical case, whitespace, aliases,
empty-list and base-0 monitor-number behavior. File names use the historical
catalog, so CLI-only aliases/options are still unknown in a file.

Retained load validates recognized fields through DocumentOptions before applying
the original value through its existing parameter. Applying the original retains
legacy list spelling/order; transactional rollback remains in ParameterSnapshot.
Native canonicalization may normalize shortcut aliases and duplicate modifiers
without changing their mask. Direct comparison tests exercise the shared validator
against actual retained parameter objects. No new parameter objects are constructed
or registered during document validation.

DOCUMENT_OPTIONS adds one C query for canonical semantic entries and enables the
additive DOCUMENT option source (5). The ABI now has 87 exports. NativeConnectionDocument
exposes validatedOption(at:); unknown fields return nil. NativeDocumentResolution
validates every recognized occurrence, then resolves duplicate assignments in
order into a copy of the supplied NativeSessionConfiguration. An invalid earlier
value cannot be hidden by a later valid duplicate. Known unsupported security or
encoding choices fail; they never fall back to inherited/compiled choices.

The supported settings cover encoding/color, scaling/filter/units, security types,
CA/CRL paths, connection sharing/reconnect policy, clipboard, input/cursor/shortcuts
and fullscreen. Absent settings retain the supplied base. Existing typed setting
sources become document where overridden, with Connection file labels in editors.
fieldLines records effective document provenance, including migration. Clipboard
and verification paths have line provenance in this resolution; their existing
session APIs do not yet expose independent source enums. Native stores and runtime
settings are not mutated by resolution. The candidate can create an ordinary
native session; tests verify independent actual ClientInit sharing bytes and input
policy against controlled loopback peers.

Special compatibility rules:

- The retained CLI loads an explicit file after parsing CLI options. Callers must
  pass a base with defaults/profile/invocation options already resolved, then apply
  the explicit document. Later user edits are ordinary session overrides. This is
  deliberate explicit-file precedence, not a hidden migration/defaults layer.
- Missing and empty ServerName both return an empty endpoint, matching the retained
  file reader. A settings-only file must not auto-connect to another profile's host.
  The final nonempty endpoint is checked by the shared parser without DNS/network IO.
- DotWhenNoCursor=true and FullScreenAllMonitors=true apply after all assignments,
  overriding modern cursor/mode fields regardless of order. A later duplicate false
  disables that migration. The resolution retains the inactive cursor shape even
  when AlwaysCursor=false; the window/export model must retain this metadata too.
- Legacy monitor indices are one-based, positive base-0 integers. The host supplies
  their explicit mapping to stable display IDs. Duplicates collapse; missing mappings
  fail rather than invent IDs or select another display silently. Selected mode with
  no explicit indices uses mapped legacy monitor 1 when no inherited IDs exist.
  Empty selected-mode arrangements require resolution. Deriving the mapping from
  fresh topology, detecting ambiguous/missing mappings and previewing it remains
  native file-UI work; the resolver never guesses from arbitrary snapshot order.
- Relative CA/CRL paths require an explicit absolute invocation working directory.
  They are joined without expanding '~' or lexically removing dot/parent components,
  which could change the OS meaning through symlinks. No path is read during resolution.
  Absolute paths and explicit empty paths remain exact. Picker grants and stale file
  access remain part of the pending document service.
- Unknown fields, plus Audio/SendPrimary/SetPrimary on macOS, remain undecoded and
  produce notices containing name/line but no value. Returning the candidate requires
  explicit acknowledgement of all notice lines. Other recognized but unmapped native
  fields fail closed. The immutable resolution cannot change after review; the future
  UI must scope acknowledgements to that resolution and clear them on replacement.

This is the semantic/model layer, not a completed Open/Save flow. It does not read
files, decide automatic connection, write preferences/profiles, implement migration,
perform tunnel/listen launch or export a live session with unrepresentable settings.
The native app must keep resolution metadata through its window lifetime and show
review/recovery before applying omissions; those integration gates remain open.

Semantic-layer verification (2026-09-20): normal native 48/48; headless unit
672/672 and smoke 2/2; retained FLTK compatibility 26/26. The first full sanitizer
runs passed the other 47 native tests but exposed a test assumption that nonempty
CA paths could create a session without GnuTLS. The corrected test asserts typed
unsupported admission, preserved configuration and separate explicit empty-CA
file resolution for the wire fixture. Final focused native document tests pass
2/2 in normal, ASan and TSan builds; shared document/ABI tests pass 17/17 and the
pure-C consumer 1/1 in all three. These are focused reruns, not replacement claims
for the initial full sanitizer logs. Configured verification files remain a session
admission check, consistent with existing native defaults/profile behavior.

The app builds and app/comparison strict deep ad-hoc signatures pass; archive
inspection finds 87 exports. Logs: `/tmp/tidyvnc-document-options-*`, including
`recheck{,-asan,-tsan}-{macos,unit,viewer}.log`. See TODO evidence for exact times,
commands and remaining platform/release limitations.

## Explicit native Open and connection-window admission

The File menu's Open Connection File command (Command-O) presents NSOpenPanel.
Selection creates a distinct value-addressed connection window with a unique
request ID. Cancelling the panel leaves existing connections unchanged. The app
owns at most one picker and cancels it during quit; late picker completion cannot
open a window after quit starts. Selection does not connect automatically.

NativeDocumentFileReader is an injected actor service. It holds the selected URL's
security scope only during reading, opens a descriptor with close-on-exec and
nonblocking flags, requires a regular file and reads bounded chunks up to 1 MiB.
Directories, FIFOs, devices, oversized files and IO failures return fixed errors.
Explicitly selected symlinks to regular files are accepted. The descriptor fixes
read identity; before/after size, modification and change timestamps detect common
concurrent edits. This is not a filesystem snapshot or a guarantee against hostile
same-metadata mutation. Cancellation is checked before/between chunks; an OS file
call itself is not preempted. No write, export, store update or network connection
is part of this service.

NativeSessionDefaults reads defaults and an optional selected profile first. For
an explicit document it then reads/parses/resolves into a review, without creating
a session. Every successful file gets a review showing its endpoint (or missing
address), ignored field names/lines and omission consequences. Raw ignored values
are not shown. The review has a fresh UUID on every read; only that exact review
can be accepted/cancelled. Reload discards old review authority. Acceptance
acknowledges precisely that resolution's notices, creates one idle session and
publishes retained resolution metadata before the session. ConnectionModel installs
the document endpoint before Connect admission, including clearing an absent/empty
address instead of inheriting a profile endpoint. Clipboard source labels now also
report connection-file provenance. No successful Open writes native defaults,
profiles, history, credentials or trust. History still updates only after Connect
succeeds through the existing connection path.

Display mapping starts with a fresh NativeDisplayService snapshot sorted by x then
y, matching retained monitor ordering. Coincident origins, including mirrored
screens, cannot provide automatic numbering. Files requiring unresolved numbers
now open a manual mapping chooser; ordinary files can still resolve. The final
review shows each file monitor and its connected display name, and offers editing
even when automatic numbering succeeded. Relative verification paths use the
request's captured invocation working directory, not an implicit document-directory
rewrite. These identity checks do not establish physical multimonitor/Spaces behavior.

Close stops publication, clears pending review and cancels the loader. Tests use a
suspended reader that deliberately returns after cancellation to verify it cannot
publish a review/session. Invalid/corrupt files produce recovery text and Reload;
Use Built-in Defaults cannot bypass a file failure. Existing corrupt-default and
missing-profile recovery still precede file loading.

Verification: NativeDocuments.FileReviewAndAdmission is the 49th native test. It
covers actual regular/symlink/directory/FIFO/oversize/missing/nonfile URL reads,
late read suppression, replaced review accept/cancel, topology invalidation,
no session before review, no automatic connect, one-time metadata publication,
no preference writes, and actual ConnectionModel address/Connect gating. Geometry
fixtures verify left-to-right/top-to-bottom order and ambiguous-origin rejection.
Full native suites pass normal 49/49 (67.79 s), ASan 49/49 (80.40 s), TSan 49/49
(188.34 s); shared document/ABI 17/17 and pure-C 1/1 pass in each build. Production
C++ is unchanged in this increment. Logs use `/tmp/tidyvnc-document-open-*`.

A separate ad-hoc test bundle with identifier org.tidyvnc.document-open-check was
used for live UI verification, leaving the running viewer untouched. Command-O,
selection of a controlled fixture, ignored-field review, explicit acceptance into
a Ready window with the selected endpoint, and picker cancellation were observed.
The review screenshot was inspected. No Connect action was taken. The initial
review container inherited its accessibility ID into child buttons; that was
corrected by assigning IDs to title/individual controls. VoiceOver traversal,
Finder/CLI launches, persistent grant recovery, file Save and physical multimonitor
mapping are not inferred from this check.

Final live AX recheck confirms distinct document.cancel/document.accept identifiers.
Review Cancel shows the cancellation message and Reload Connection File with no
Connect control. Final app build and strict deep app/comparison signatures pass;
branding/attribution (1650 existing deferred entries) and whitespace checks pass.

## Finder and window-action lifetime

AppCoordinator implements both AppKit document-opening callbacks, including the
modern URL callback that takes precedence over openFiles. Local file URLs and
absolute filenames enter NativeDocumentLaunchRouter; URL schemes and nonlocal file
authorities are rejected. The complete batch is checked before dispatch. At most
64 requests may wait for a window action, with bounded filename lengths and no
NUL bytes. Every explicit request has its own UUID, including repeated opens of
the same file. The queue stores URLs and captured invocation context, not file
contents, sessions, passwords or a command-line relaunch string.

ConnectionRoot supplies a SwiftUI OpenWindowAction after it appears. Only the
action is captured; the router does not capture that root or its connection model.
Early Finder requests wait until an action is available. Replacing the action
never replays completed requests, and reentrant routing preserves FIFO order.
Quit revokes the action and pending queue before closing sessions. OS success
means the request was accepted for review; file IO/parse/semantic failures stay
in each file's recovery window. Valid members of a mixed batch can still be
reviewed when another file is malformed. Document window titles use the filename.

The existing current-extension association and application identity are unchanged.
Legacy-extension files remain explicit inputs; no old-extension default association
was installed or changed. CLI host/options, URL schemes and reverse/listen/tunnel
invocations are not implemented by this callback. Installed release association,
quarantine, persistent grants and consent checks remain packaging/OS gates.

NativeDocuments.LaunchRoutingAndQuit covers early/warm batches, order, repeated
file identities, full-batch rejection, bounds, local URL validation, action
replacement, reentrancy and stop during dispatch. NativeDocuments.SwiftUIWindowActionLifetime
is a separate, signed fixture app with real WindowGroup scenes. It dispatches a
cold batch, closes all owned windows, asserts NSApp has zero visible windows,
opens a warm batch through the retained action and opens a repeated file in a
new window. It does not activate the app between closure and dispatch. This
isolates the no-visible-window boundary from desktop automation's activation
behavior. It performs no file reads, session creation or preference writes.

Live Finder verification used an explicitly selected ad-hoc test bundle with
identifier org.tidyvnc.finder-check. Always Open With remained unchecked. The first
filename-callback-only version launched an ordinary window but did not deliver
review; it is not counted as a passing launch. Sampling showed an idle event loop,
not a main-thread deadlock. Adding the modern callback fixed cold Finder delivery.
The corrected app visibly reviewed the requested endpoint with no Connect action
taken. A later three-file Finder batch independently displayed current/legacy
reviews and the malformed-file error; the final Window menu showed distinct
filenames for all three windows. The separate fixture proves the zero-visible-window
case, while the live checks prove Finder event delivery and real review presentation.

Final launch verification: native 51/51 normal (70.60 s), ASan (81.17 s), TSan
(190.32 s); document/C ABI 17/17 and pure-C 1/1 in each. App build and strict deep
ad-hoc signatures for app/comparison/launch fixture pass. Branding/attribution
passes with 1650 existing deferred entries and exact retained-interface entries
for the legacy launch regression. Final logs:
`/tmp/tidyvnc-document-launch-verified-native{,-asan,-tsan}-full-tests.log`,
`/tmp/tidyvnc-document-launch-final-app-build.log`,
`/tmp/tidyvnc-document-launch-signature.log` and
`/tmp/tidyvnc-document-launch-branding.log`. The live test app was verified stopped;
the existing viewer remains running. These checks do not establish an installed
release association, minimum deployment OS, Intel or production signing acceptance.

## Native compatibility export and current connection capture

`NativeDocumentExport` captures only understood, non-secret file fields into an
immutable, preflighted byte buffer with a unique review identity. It resolves
compiled security and encoding defaults explicitly, preserves an empty security
allow-list as deny-all, and serializes the endpoint, public security methods,
exact CA/CRL paths, clipboard, sharing, reconnect, encoding, input, scaling and
fullscreen policy. Every emitted assignment is checked again by the shared file
semantic validator. Invalid endpoints, unavailable security methods, invalid
paths/modifier masks and output line limits fail before any destination access.
An empty endpoint intentionally produces a settings-only file. Provenance becomes
explicit-file provenance when reopened; it is not a second preferences format.

The format cannot preserve native remote-resize, IPv4/IPv6 or pointer-timing policy, so **every**
export requires those omissions to be reviewed, including built-in values: a
receiving viewer may have different resize, network or pointer-timing defaults. Stable display IDs require
a reviewed monitor-number mapping and a separate loss acknowledgement. Automatic
numbering uses current legacy order; missing or ambiguous mappings, including dormant
Current/All selections, now enter the export-numbering chooser described below. Ignored original input fields add another omission notice and are never
copied. Review acceptance must cover the candidate's complete loss set before
its bytes can be obtained. Nonempty custom TLS priority expressions are rejected
rather than silently weakened; native profiles remain the format for preserving
that policy. Empty/default TLS priority continues to depend on the receiving
viewer's TLS defaults. Engine timeouts, queue/buffer budgets, credentials, saved
trust decisions and invocation context are outside connection-file export.

`ConnectionModel.documentExport` snapshots current owner values synchronously on
the main actor. Applied session sharing/security/encoding/clipboard/resize edits
and native scaling/input/fullscreen state are captured rather than initial values.
Unloaded, closing, busy, prompting, transitional or conflicting-editor/cleanup
states cannot export. Captured bytes remain unchanged after later edits. Hidden
cursor fallback now retains its last selected Dot/System shape in `NativeInputState`,
including the dormant shape supplied by an opened document. This prevents exporting
an old original shape after a user changes it and hides fallback again.

The initial export-model increment performed no destination IO. The Save As flow
below now retains its exact export identity through omission review and destination
selection. No defaults/profile schema or C ABI change is needed.


## Native Save As and atomic destination writes

File → **Save Connection File As…** (Command-Shift-S) captures the current
connection settings, presents the export limitations, then opens an NSSavePanel
restricted to `.tidyvnc`. Cancel at either step discards the pending request.
The panel supplies its normal explicit existing-file replacement confirmation.
A save writes the reviewed snapshot even if its source subsequently changes;
it does not adopt that file as a defaults/profile store or start a connection.
An empty endpoint permits a settings-only export; a malformed nonempty endpoint
disables Save As. Native settings editors and new connection attempts are gated
while export review, destination selection or writing is pending.

`NativeDocumentSaveState` owns the candidate identity, review/picker transitions,
write task and outcome. Old or premature callbacks cannot write. Close revokes
pending callbacks, cancels the task and joins it; cancelled/late work cannot publish
a result into a closed window. AppCoordinator owns each window's panel and cancels
panels on window close/quit. Connection alerts defer until the Save flow ends.
Save progress/results appear in an overlay, preserving desktop viewport geometry.

`NativeDocumentFileWriter` performs selected-file IO on an actor. `prepare` returns
a writer-bound receipt containing the parent inode/device and target metadata;
it creates nothing. `write` first requires complete loss acknowledgement, then
checks the receipt and explicit overwrite authorization before creating output.
It accepts only local `.tidyvnc` paths in existing folders, regular owned writable
single-link targets or absent targets. Symlinks, directories, FIFOs and other
special targets fail; parent identity changes and stale target metadata fail.
The destination is never opened for truncation.

A random, exclusive sibling temporary file receives an empty ACL and mode 0600
before any content. Writes check cancellation in bounded chunks, fsync the file,
then revalidate target/parent identity. New-file installation uses RENAME_EXCL;
replacement uses atomic rename after explicit overwrite authorization. A directory
flock serializes cooperating writers without leaving a lock file. Temporary files
are removed on precommit failure/cancellation. Successful replacement tightens old
public permissions to 0600 and does not modify the parent folder's permissions.
Directory fsync completes the commit. Failure after rename has a distinct
**already replaced / final check failed** result; cancellation after rename does
not pretend to roll it back.

These are atomic replacement and cooperating-writer guarantees, not a filesystem
compare-and-swap against uncoordinated external programs. Metadata is checked
immediately before rename, but a writer ignoring the directory lock can still
race that final check. Security-scoped access is held only during each IO call;
no bookmark or persistent grant is created. Validation here covers the local,
unsandboxed development app with local temporary directories; sandbox packaging, persistent grants,
network-volume behavior and release signing remain separate acceptance gates.


Current keyboard acceptance gap: computer-use Command-Q leaves the system Save
panel open on this host. The Quit menu cancels it and completes joined shutdown;
Escape followed by Command-Q also works. Local-event and direct native-menu
experiments did not change the observation and were removed. Physical-keyboard
behavior is not established, so this remains open under N4.11.


## Explicit-file monitor mapping recovery (2026-09-20)

`NativeDocumentMonitorMapping` retains an immutable parsed document, resolved native
base and invocation directory. It extracts canonical unique file monitor numbers,
including retained implicit monitor 1 for Selected mode without inherited IDs.
Deprecated all-monitor migration and dormant explicit selections retain their usual
semantics. Numbers are dictionary keys, never array sizes; sparse positive Int32
values do not allocate up to the largest number. The interactive chooser admits at
most 64 distinct file monitors, matching the native display-service bound. An
explicitly empty selected-monitor list in Selected mode remains a semantic error;
recovery does not invent a file monitor number or bypass that validation.

`NativeDocumentResolution` accepts an optional explicit number-to-stable-ID mapping.
Its keys must match the required numbers exactly, and IDs must satisfy native policy
validation. Duplicate source numbers collapse. Several numbers may explicitly map
to one display, which is used once; the chooser explains that consequence. All other
known-field validation, ignored-field review, endpoint/security/scaling behavior and
relative-path semantics remain in force. No document or stored configuration is
rewritten to repair mapping.

`NativeSessionDefaults` retains the exact document/base through mapping and final
review. Changing source bytes or saved defaults does not substitute new content.
Initial unresolved/mirrored numbering opens **Choose Displays for This File**.
Resolvable automatic numbering can be changed from the final review. Pickers show
connected displays, disconnected selections remain visibly unresolved, and Review
stays disabled until every number has a connected assignment. Editing preserves
previous connected manual assignments. Refresh only reads native display topology.

Resolve validates current connected IDs and produces a fresh review UUID; no session
exists yet. Final review shows the endpoint, ignored field names and chosen display
assignments. Open acknowledges that exact review and creates one idle session. An
automatic review still requires unchanged ordered IDs; a manual review requires the
same available-ID set, so rearranging stable connected IDs does not reinterpret
explicit choices. Topology changes revoke final review and offer mapping of the
retained document when it has file monitor numbers. Missing selected IDs cannot be
accepted. Stale mapping/review/cancel callbacks cannot affect a new draft or ready
session; cancellation/close discard retained recovery state without writing stores.

`native-document-mapping-ui-tests.app` compiles both production views and uses
synthetic mirrored/disconnected displays, in-memory defaults and a fake file reader.
It never reads the user's connection files, writes native stores or connects to a
server. Automated checks cover sparse numbers, incomplete/extra/invalid mappings,
known-value validation, inherited selection, deprecated all-monitor migration,
many-to-one choices, retained source bytes, manual edit/cancel, topology invalidation
and final idle admission. Light/dark chooser, review and opened states are rendered.
Without arguments it opens the same isolated UI for live picker/keyboard checks.
Defaults-import and export mapping recovery remain separate integration work.


## Exported monitor numbering and sheet lifetime (2026-09-20)

Save As now captures a `NativeDocumentExportCapture` before presenting UI. It owns
all current non-secret session settings, endpoint, dormant cursor shape, ignored-input
flag, source display ordering and available display names. All representability
checks run before recovery is offered, including the custom-TLS-priority rejection.
Later session edits or topology changes cannot replace the captured values. Encoding
options retain their immutable owned option handle; no session/store object is kept.

When a saved selected display has no automatic ordinal, or the arrangement is
ambiguous, the app opens **Choose Exported Monitor Numbers**. Connected IDs receive
available ordinal suggestions; disconnected/ambiguous IDs have no guessed number.
Every saved selected ID—including dormant selections in Current/All mode—must have
a distinct positive decimal number within the format's positive Int32 range. Exact
key matching, range and uniqueness are enforced independently at the export boundary.
Stable IDs and display names are review metadata only and never enter serialized
connection-file bytes. The chooser does not edit live fullscreen policy or stores.

Automatic mappings can also be edited from final export review. Mapping requests
have fresh identities, retain previous choices on edit and produce a fresh immutable
export on resolution. The final review lists every saved-display/number pair, offers
another edit, and still requires explicit Continue to Save for all existing loss
notices. The receiving viewer interprets those numbers using its own arrangement;
manual numbering need not describe displays currently connected to this Mac.

`NativeDocumentSaveState` owns one presentation identity across the mapping and
review steps. SwiftUI changes the content inside the same sheet rather than
presenting competing sheets. A stable 560×600-point container with scrolling lists
prevents the original shorter chooser size from clipping final review; action
buttons and loss notices remain visible. Only approval of the current export UUID
ends presentation and admits the destination panel. Cancel, stale mapping/review/
presentation IDs and close cannot advance to a write. Existing destination receipts,
private atomic writes, overwrite policy and write cancellation remain unchanged.

`native-export-mapping-ui-tests.app` renders the production sheet inside an AppKit
host, using captured fixture settings and a private temporary destination. It checks
number bounds/uniqueness, disconnected/dormant IDs, immutable settings, security
preflight, stale callbacks, re-editing, one sheet identity, no premature dismissal,
one approved destination handoff, final serialized bytes and cancel/close. Its
onDismiss handler substitutes a fixture-only destination for NSSavePanel, so this
test does not establish new system-panel keyboard or privacy behavior. Without
arguments the same isolated fixture is available for live interaction; approval
saves only its temporary fixture file, removed at quit.

MaxCutText remains CLI-only and cannot be restored from compatibility files. Every
Save As review now also discloses the omitted incoming clipboard size limit, alongside
remote resize, IP-family selection and pointer timing. CLI policy and provenance
survive explicit-file review and export capture; no unsupported field is serialized.

Initial window geometry and maximization are also outside the compatibility field
catalog. CLI policy survives file admission and display recovery; exports disclose
the omitted window placement. The scrollable review keeps all omissions reachable.
