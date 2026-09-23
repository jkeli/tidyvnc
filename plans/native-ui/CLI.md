# Native invocation and command-line compatibility

Status: shared argument syntax and per-occurrence value validation, explicit option
catalog, C ABI, Swift ownership and ordinary native session resolution are implemented.
The executable decodes raw argv strictly, handles help/version before app/store
initialization and consumes one process-local request in its first ordinary window.
Resolution applies defaults/profile → CLI → explicit file without writing stores.
Direct hosts connect when ready; explicit files retain review and manual Connect.
File/socket classification and no-file monitor recovery are implemented. Remaining
option parity and installed/native interaction acceptance remain required. SSH
authentication and admitted ~/.ssh/config settings use the owned native tunnel path;
see TUNNELS.md for restrictions. Numeric `-listen [port]` and reviewed
`-listen ./file.tidyvnc` startup are implemented; see LISTEN.md for checked-port policy.
Launch credential inputs are
implemented with connection-scoped ownership; see CREDENTIAL-INPUTS.md.
This document does not declare CLI parity or authorize shipping SwiftUI as default.

## Syntax and retained behavior

`core::splitParameterArgument` is extracted from `Configuration::handleArg` and is
used by both the retained registry and `viewer::InvocationSyntax`. It splits the
first equals sign, strips at most two leading dashes, and leaves literal values
untouched. The shared boolean helper distinguishes a separate empty argument from
an empty equals value. No shell quoting, escaping, expansion, abbreviation,
whitespace trimming or `--` terminator is introduced.

The invocation parser takes argv without the executable. It preserves ordered
occurrences, canonical names, literal values, option/value argument positions and
one positional operand. Arguments may appear before or after that operand.
Case-insensitive option names and aliases remain supported. Positional text stays
unclassified: no endpoint parsing, stat, file reading, DNS or connection occurs.
The retained fallback of unprefixed unknown `name=value` to a positional operand is
preserved. Empty positional strings do not occupy the operand slot. Extra nonempty
operands are diagnosed rather than silently ignored or truncated.

Boolean lookahead consumes the exact separate tokens `0`, `1`, `on`, `off`, `true`,
`false`, `yes`, `no`, without case sensitivity. Otherwise a bare boolean enables
itself. The retained AliasParameter distinction is preserved: `-FullColour off`
enables color and leaves `off` as an operand, while `-FullColour=off` disables color.
Use the equals spelling to avoid this legacy ambiguity. A value-taking option can
consume a following `--help` as its literal value. The exact terminal flags are
`-h`, `--help`, `-v`, `--version`; they stop at their position after prior syntax
succeeds. Preceding assignments remain available for semantic validation; the
unused positional operand is discarded. Help/version bootstrap respects prior shared semantic failures; the separate
value-validation operation checks them. Host-only strings stay literal on terminal
paths, so help does not read a preceding password-file path.

Every input is preflighted for at most 4096 arguments, 65536 bytes per argument,
1 MiB total and no embedded NUL. These bounds apply even after a terminal flag.
They are independent of the compatibility document's 254-byte line bound. Errors
carry a closed reason and one-based argv index, never raw arguments or values.
Syntax success is deliberately not semantic success: malformed/duplicate values
remain in order. `validatingValues()` validates each occurrence and returns a
canonical owned copy without changing the raw syntax snapshot.

## Catalog and capabilities

The catalog records canonical name, alias, boolean/value syntax, category and
compiled/platform availability. Encoding entries derive from `encodingSchema()`.
The remaining catalog is audited against `vncviewer/parameters.cxx`,
`CConnection`, `CMsgReader`, `SecurityClient`, `Security`, `CSecurityTLS`,
`TcpSocket` and `LogWriter`. It includes ordinary GUI options plus CLI-only
PointerEventInterval, AlertOnFatalError, PasswordFile/passwd, Maximize, DesktopSize,
geometry, listen, RemoteResize, via, GnuTLSPriority, MaxCutText, UseIPv4, UseIPv6 and
Log. Audio, X11 primary-selection/display, TLS files/priority and tunnels have
explicit availability flags. No plaintext password, username or ServerName option
is invented. Known unavailable options have a distinct diagnostic.

Compiled availability is not frontend implementation readiness. Applying an option
requires an implemented native adapter. Native startup must not silently accept and
ignore catalog entries. PasswordFile is classified separately but is only a literal
path at this layer; it is never read, imported into Keychain or logged here.
No environment variable is read, and no tunnel command is evaluated. Values and
operands can contain private input and must never be dumped in diagnostics.

## C and Swift boundary

The additive INVOCATION_SYNTAX feature provides parse/get/assignment/catalog
exports. The C parser owns a bounded immutable snapshot with ordinary retain/release
lifetime. Metadata and catalog names are copied; assignment values and the operand
are borrowed immutable spans valid while the caller retains the owner. No source
argv pointer survives parse. Invalid inputs, ABI headers, types, out-of-range
indices and allocation failures leave outputs unchanged. Error detail packs a
one-based argument in the upper bits and a closed reason in the low byte.
Category/action/reason values are compile-time checked against C constants.

`NativeInvocationSyntax` copies every borrowed span into owned Swift values before
releasing the temporary C owner. It is Sendable, preserves all occurrences and
publishes the same catalog without a Swift option-name table. The wrapper accepts Swift strings; the executable first performs bounded scans
of original argv and strict UTF-8 decoding, including unused trailing arguments
after a terminal flag. Invalid bytes never become replacement characters. The portable C layer accepts opaque non-NUL bytes.
There is no serialization/relaunch facility for invocation values.

## Value validation and ordinary session resolution

`documentOptionValue` shares decoded ordinary-field validation with explicit files;
CLI values never pass through file escaping or physical-line limits. Booleans,
encoding ranges, security availability, scaling, monitor numbers and modifiers are
canonicalized independently for every occurrence. CLI-only booleans and bounded
integers are checked too. Log triples and level bounds use the pure LoggingPolicy
parser; writer/target admission belongs to the logging adapter. Host-only strings
remain literal. Earlier invalid values cannot disappear behind duplicates or help.
The additive `INVOCATION_VALUES` feature provides `tidyvnc_invocation_validate`,
which publishes a new immutable owner only after success. NativeInvocationOptions
copies canonical values into Swift. The C ABI now has **111 exports** with the input-timing, message-limit, window-geometry and process-logging additions below.

NativeInvocationResolution applies supported ordinary settings with command-line
provenance, plus remote-resize and initial DesktopSize policy. DesktopSize retains
useful `%dx%d` decimal/sign/whitespace/trailing-text spellings with checked positive
16-bit dimensions. TLS-priority text is bounded; shared session admission still
performs library validation. Relative CA/CRL paths retain the captured invocation
cwd and dot components. The caller supplies the classified endpoint and monitor
mapping; this resolver performs no file lookup, DNS, store write or connection.

NativeOptionOverlay shares application rules with explicit files. Its immutable
NativeCompatibilityState preserves the inactive cursor shape and deprecated
DotWhenNoCursor/FullScreenAllMonitors flags across CLI → file overlays. Retained
migration runs again after file fields; inherited true flags continue to override
modern fields until explicitly disabled. The effective provenance remains CLI and
argv indices never become file line numbers. Document review, mapping edits and
recovery retain the same compatibility state without rereading source data.

NativeSessionDefaults and ConnectionModel accept an injected NativeInvocationRequest.
They apply native defaults, selected profile, CLI and finally an explicit file,
validate native adapter support before file IO, publish metadata before the idle
session, and reject late results after close. Explicit files still require their
existing review, and absent ServerName still clears the address. The executable
constructs the request before entering SwiftUI. PasswordFile is now admitted through
the scoped launch credential owner described in CREDENTIAL-INPUTS.md. Tunnel
options now use the native adapters in TUNNELS.md; AlertOnFatalError remains the
recognized but unimplemented native option. Catalog availability alone is insufficient.

## Display resolution after explicit-file precedence

The explicit-file loader prepares CLI values without prematurely constructing a
fullscreen policy. NativeFullscreenOptions holds validated mode/start values,
sparse numeric selections, per-field provenance and optional host assignments.
This internal candidate cannot be exposed as a resolved invocation/session. All
ordinary CLI validation and unsupported-adapter checks still precede file IO.

After the file read, the resolver overlays its validated fields and maps only the
surviving numbers against the fresh display snapshot. A file selection replaces
the complete CLI selection and its host assignments, so an obsolete/disconnected
CLI choice cannot reject an otherwise valid file. A file mode can remove an
implicit selected-monitor requirement; explicit dormant selections are preserved.
Deprecated all-monitor migration still runs both before and after file overlay.

Surviving CLI numbers use the existing document mapping/review lifecycle, labeled
as command-line options. Recovery retains immutable values, provenance, sparse
bounds and cursor metadata without rereading source data. Explicit host mappings
are checked against connected IDs, are shown in review, and use the same topology
and stale-identity guards as manual choices. The review displays actual resolved
assignments instead of reconstructing them from an older monitor-order array.
No session is admitted until required mapping and final file review finish.

## Executable startup and first-window ownership

The native app executable owns bootstrap in the same process. Before AppKit and
store initialization, it copies bounded raw argv, validates syntax and every shared
value occurrence, and routes help/version to stderr. Help exits 1 and version exits
0, matching the retained viewer. The help catalog identifies unimplemented native
adapters and compiled/platform-unavailable entries; encoding defaults come from the
shared schema. Errors carry only typed reasons and argument positions.

Ordinary launch checks native adapter support before inspecting an operand. As in
the retained viewer, a bare name remains a hostname even when it ends in `.tidyvnc`;
use `./file.tidyvnc` for a relative file. Operands containing a slash or backslash
receive startup-only metadata inspection. Actual Unix sockets become cwd-anchored
endpoints; other paths enter the bounded regular-file reader and review flow.
Symlink and parent components retain OS path semantics. No file contents, settings
stores or connection sockets are opened by classification.

NativeInvocationStartup holds one immutable request, consumed once by the first
ordinary connection window. View reconstruction, New Connection and reopening after
all windows close do not reuse it. Quit discards an unopened request. No argv IPC,
Codable payload, restoration data or relaunch is introduced. A direct-host request
automatically connects only after session admission; close or an intervening address
edit revokes that attempt. Disconnect does not replay it. No-host options open an
idle form. Successful direct connections use the ordinary recent-history writer;
parsing and resolution themselves do not persist settings.

No-file CLI monitor selections resolve against fresh connected displays. Unresolved
numbers open a connection-scoped chooser, retaining the validated candidate and
original option provenance. Sparse bounds, exact mapping keys, connected IDs and
stale-UUID guards apply before admission. Cancel never creates a session; retry
creates a fresh mapping identity. A valid mapping resumes the direct-host attempt
or opens the idle form when no host was supplied. Explicit-file launches retain the
separate mapping and review lifecycle described above and stay idle after review.

## Outgoing network-family selection

`UseIPv4` and `UseIPv6` now overlay an owned NativeNetworkPolicy with per-field
command-line provenance. NativeSession captures it once and passes both flags to
the existing C connect options on every attempt, including reconnects and address
edits. Different sessions do not share mutable family state. The shared connector
filters hostname lookup and rejects numeric addresses from disabled families.
Both families disabled remains valid for Unix sockets; TCP is rejected before an
attempt starts. No silent fallback re-enables a family.

Explicit-file review and display recovery preserve this CLI policy. These options
are outside the compatibility file's supported field catalog, so raw file entries
remain ignored with review; they cannot overwrite the policy. Save As discloses
omitted IPv4/IPv6 settings and requires acknowledgment, including built-in values
that may differ from the receiving viewer. Native stores and file schemas are
unchanged. The listener now applies the same family flags at bind time; see
LISTEN.md. For SSH forwarding these flags select the gateway address family; the gateway resolves the target.

## Pointer-event timing

PointerEventInterval now configures worker-owned motion throttling after middle-
button emulation. The native default is the same shared 17 ms constant used by the
retained viewer; zero disables the delay and values through INT_MAX are accepted.
Each session captures its interval and command-line provenance once, preserving it
through file review, display recovery and reconnect. No native-store field is added.

Successive motions replace one bounded pending value without postponing its first
deadline. Button/wheel transitions send immediately and update the pending value,
matching the retained timer behavior. Keys flush pending motion to preserve the
mailbox's motion-before-key ordering. Focus/release/view-only/emulation changes,
overflow, disconnect, close and generation changes discard obsolete motion. Timer
callbacks validate current generation, routing revision, connection and focus before
writing; no input is delayed in a SwiftUI task or process-global timer.

The additive INPUT_TIMING C feature supplies checked default initialization and
session creation with a copied interval. Existing create calls retain their former
unthrottled behavior; native sessions pass timing into the message-limit-aware
creation function below. Save As reviews
omitted pointer timing because the compatibility file has no matching field. Help
reads the default from the C initializer rather than duplicating it in Swift.

## Incoming clipboard message limits

`MaxCutText` supplies an immutable per-session reader limit, including explicit zero
and all values through INT_MAX. Its 256 KiB default comes from the same constant as
the retained reader. CLI provenance, file/display review and reconnect preserve the
captured value. Compatibility files cannot set this CLI-only option; Save As requires
review of its omission. No native preference/profile schema field is introduced.

The existing reader applies the cap to plain clipboard wire bytes, the complete
extended clipboard payload and each decompressed format independently. Oversized
messages/formats are skipped with protocol alignment preserved. Zero accepts empty
plain text. This cap does not bound outgoing offers, total transport buffering or
aggregate decompression. Native UTF-8 text retention (256 KiB per text, 1 MiB total)
and pasteboard limits remain independent: raising MaxCutText may admit a message
that is subsequently rejected by the clipboard mailbox's resource budget. Latin-1
to UTF-8 expansion occurs after the plain wire limit. No 2 GiB allocation is made
merely by choosing INT_MAX.

The additive MESSAGE_LIMITS C feature provides checked default initialization and
creation with copied message limits, input timing and encoding. Existing APIs retain
their default reader limits and layouts. Native creation requires the feature; help
reads the default through the C initializer. Wire fixtures verify rejection versus
retention rejection, exact/zero bounds, outgoing independence and reconnect.

## Initial window geometry and maximization

`geometry` and `Maximize` now produce an immutable initial-window policy with CLI
provenance. Geometry is parsed by the shared checked WindowGeometry parser used by
the retained viewer, exposed through the stateless WINDOW_GEOMETRY C feature. Empty
text clears the override; accepted forms are `+x+y`, `WxH` and `WxH+x+y`. Numbers keep
C whitespace/sign parsing and retained trailing-text behavior, including size-only
acceptance when two conversions succeed. Three-conversion positions are invalid.
Coordinates are signed absolute values (`+-100+-20`), not right/bottom-edge offsets.
Dimensions must be positive and representable; overflowing integers now fail without
undefined scanf writes. Every native occurrence is checked before operand inspection.
The retained invalid-input path still logs and keeps its original geometry.

The native host applies geometry once after session admission to the first ordinary
connection window, including a no-host idle form. File review must finish first.
Content sizes and positions use AppKit logical points; signed coordinates are relative
to the primary screen's top-left. The target screen's work area caps size, subject to
native window minimum/maximum constraints, and frame decoration is accounted for.
Maximize fills the selected work area; an explicit geometry position remains explicit.
Size-only geometry preserves the window's content top-left. AppKit still owns its
platform window constraints. No window delegate, ordering or focus is replaced.

The placement owner waits for admission/window attachment and any active sheet,
revokes pending work on close, and never replays on reconnect, view reconstruction,
display notifications or fullscreen exit. Automatic fullscreen waits for initial
placement, so the ordinary window restores with that frame; later user resizing is
preserved. New windows and zero-window reopening do not inherit the process launch
request. Compatibility files cannot override this CLI-only policy, and Save As reviews
its omission. Native stores remain unchanged. Multi-display/Spaces physical acceptance
and installed-launch gates still apply.

## Logging sink prerequisite (2026-09-20)

Shared file/stdio sinks now serialize complete formatted records, direct writes and
file replacement/closure using one recursive mutex. Timestamp conversion uses
caller-owned storage, including across independent sinks. Existing wrapping,
truncation, lazy rotation and stream ownership remain unchanged. Registry mutation,
writer levels/destinations and formatting configuration still require startup
ownership; logger destruction requires joined writers. Native startup now supplies
that ownership for stderr/stdout/file as described below.

The owned LoggingPolicy candidate now parses bounded lists and resolves against
explicit host writer/target catalogs without touching global registration, streams
or files. It preserves comma-entry trimming, empty entries, case-insensitive names,
ordered wildcard overrides, empty-target disabling and resetting unspecified writers
for each assignment. Every rule must resolve even if a later rule overrides it.
Resolution returns canonical, owned routes only after complete success. Errors expose
only a fixed message, typed reason and entry number.

Level parsing preserves defined retained atoi behavior: signed decimal prefixes,
leading C whitespace, ignored suffixes and zero when there are no digits. Decimal
overflow is now rejected during invocation value validation, including before help
or version and before later Log assignments. The pure parser does not activate
logging or read a registry; native startup separately validates registered names.

RedactedLogger provides the output adapter used by native startup. The shared
Logger formatted entry point is virtual so the adapter intercepts messages before
expanding string/pointer arguments. An explicit table recognizes 89 current core
templates; unknown formats and preformatted text receive fixed fallback output.
Known sources use compiled names; arbitrary source text is not forwarded. Three
keyboard event templates are suppressed entirely. Twenty audited numeric templates
retain protocol versions, counts, sizes, flags and status codes; a compile-time
check restricts these templates to `%d`/`%x`. Other substitutions are redacted.
Core translations are captured at construction before workers and output uses
controlled English text. Native diagnostic localization remains part of its own
acceptance work. No destination opens or registry changes occur in this adapter.

## Process logging startup (2026-09-20)

Native Log supports stderr, stdout, file and an empty target to disable output. The
default is `*:stderr:30`, matching the retained viewer. Unknown targets fail
explicitly before launch or help/version output. Every assignment is
validated, including one replaced by a later assignment. The final complete policy
is applied after launch preflight and before SwiftUI constructs the first runtime.
Logging is process-wide; it is not stored in session/defaults/profile configuration,
overridden by connection files or replayed by new windows/reconnects.

StartupLogging captures the registered writer order. Duplicate names can occur
when client/server helpers are linked: named rules affect the first match, while
wildcards affect every node. All used destinations and redacting adapters are
prepared before any writer changes. Failed preparation closes staged streams and
preserves existing routes/admission. Unused/overridden destinations never open.
Streams own close-on-exec descriptor duplicates, leaving original stdout/stderr
open. Startup commits once; the runtime creation gate closes admission permanently,
even after runtime shutdown. The process owner is constructed before the runtime
service and destroyed after it joins workers, detaching all writers before closing
sinks. Existing C consumers that never configure logging preserve their routing.

PROCESS_LOGGING adds checked validation/configuration calls with fixed typed errors.
The entry point uses the default for ordinary launch and does not configure output
for help/version/preflight failures. Diagnostic localization and installed/physical
launch acceptance remain open.

The file destination retains `/tmp/vncviewer.log` and one `.bak`. Configuration
copies and validates the path without file IO; only the first emitted (non-suppressed)
record creates a file. The sink requires owned regular single-link leaves, pins the
parent directory, uses no-follow leaf operations, and publishes without overwriting
an unexpected entry. File/backup/lock permissions are 0600; macOS extended ACLs are
removed from files and refused on the parent before creation. The parent must be
owned by this user or root, with no group/world write except a root-owned sticky
directory. A private persistent `.lock` sidecar takes a nonblocking advisory lock
until sink closure, including after runtime drain. Another native process falls
back to stderr without rotating the active owner's log. Noncooperating writers,
including the retained legacy file sink, do not participate in that lock.

Unavailable/unsafe destinations or failed writes switch once to an owned stderr
duplicate with a fixed warning; no path, exception text or unredacted record is
included. A failed record is retried on stderr. Rotation preserves the prior log
bytes in `.bak` before removing its original entry. This is not an atomic transaction
across multiple directory entries: a publication failure can leave the previous log
in `.bak`, and an earlier backup may already have been removed. A safe existing
backup is retained when no old log exists. This feature does not impose a size cap
or periodic rotation. File errors do not prevent sessions from proceeding.

FILE_LOGGING adds `tidyvnc_logging_configure_with_file` for embedding hosts to
supply a copied absolute path at the same one-time startup gate (100 C exports).
The native executable uses the default path; no CLI path option or persisted
session/profile/defaults field was added. Tests use private temporary paths.

## Remaining implementation sequence

1. Complete diagnostic localization and logging/help/installed acceptance.
2. Complete SSH authentication/host-key/configuration interaction and installed
   listen/tunnel acceptance. Initial native listener and prompt-capable `via` adapters
   are implemented with explicit limitations and no shell interpolation.
3. Finish help/defaults parity and installed cold/warm Finder/LAN/privacy acceptance,
   failed/cancelled launch cleanup and independent process invocations, including
   authentication and remaining adapters. Preserve ordinary successful-connection
   history while verifying that parsing/resolution and terminal paths do not write
   settings or import legacy stores.

## Current evidence

Core tests cover lexical forms, literals, aliases, boolean lookahead, differential
retained-registry consumption, all ordered occurrences, unclassified operands,
terminal actions, capability errors, bounds and concurrent parsing without global
mutation. C ABI tests cover owned inputs/borrowed lifetime, redacted errors, unchanged
outputs, opaque bytes, catalog metadata, fault injection and concurrent reads. A
pure-C consumer and native Swift tests exercise all five exports and owned copies.
The resolution tests additionally cover canonical ownership, CLI/file precedence,
inherited migrations and explicit off overrides, manual mapping edits, defaults and
profile inheritance, no-store writes, idle session admission and cancellation. See
the latest TODO entry for exact configuration/result evidence. These tests do not
prove remaining option adapters, installed launch acceptance, authentication,
listen or tunnel flows. Bootstrap tests cover actual Unix-socket classification,
strict raw bytes, symlink paths, local-peer automatic connection, cancellation and
no-file display recovery. Isolated SwiftUI app fixtures verify first-window
ownership, file review and new-window/zero-window reopening without user stores.
A separate script tests help/version/errors on the actual built app executable.


The normal compiled catalog was compared to actual retained `--help` output under
isolated HOME/XDG directories: all **46** available canonical names/aliases match.
The retained lexer regression tests pass, as do the normal native suite and focused
normal/ASan/TSan core, ABI and Swift tests recorded in TODO. C ABI has 97 exports after window geometry;
native storage schemas remain unchanged.

## Password-file authentication primitives (2026-09-20)

The shared codec now offers a caller-owned eight-byte decode buffer. Its existing
string-returning entry point uses that same implementation and clears its temporary
plaintext block. A new PASSWORD_FILE_REPLY C feature provides a consuming reply
for one legacy obfuscated block, without a plaintext UTF-8 conversion. It verifies
a current password-only prompt under the authentication lock; username-required
and trust prompts cannot consume the block. The input, temporary decoded block and
bridge-owned plaintext are wiped on success and failure within their owned bounds.
The ordinary mutable UTF-8 username/password reply contract stays unchanged.

NativePasswordFileReader reads exactly the first eight bytes of a selected regular
file on its actor, with scoped URL access, close-on-exec/nonblocking open, bounded
reads, cancellation checks and before/after metadata checks. A selected symlink can
resolve to a regular file; FIFOs/devices/directories and incomplete blocks fail.
Second/view-only blocks and trailing bytes are ignored, matching the retained
viewer. It returns an explicitly clearable owner containing only obfuscated bytes;
NativeSession.replyPasswordFile passes those to the shared core and clears the
submitted array. The legacy format is obfuscation, not encryption. No password is
decoded into a Swift String, stored in settings/Keychain, or exposed in errors.

These primitives are now integrated with the launch owner described in
[CREDENTIAL-INPUTS.md](CREDENTIAL-INPUTS.md). PasswordFile is admitted, environment
inputs are captured once after preflight, and current-prompt/endpoint ownership,
precedence and cancellation/drain gates control use. Help and preflight continue
to do no credential-file IO or environment credential capture.

The listener C ABI and NativeListener owner are now available (LISTEN.md), including
explicit handoff into configured reusable sessions and callback/runtime drain.
Numeric `-listen [port]` now uses this boundary through the native listener scene.

Manual listening is now available from File > Listen for Connections, with separate
incoming windows and connection-only reverse identity. This does not consume the
ordinary launch request or its captured credential owner. CLI `-listen [port]`
consumes startup in a listener scene, binds once using UseIPv4/UseIPv6, and passes
CLI settings to accepted windows. Only the first opened incoming window can claim
launch credentials. Stop clears unclaimed credentials; later peers never recapture
the environment or PasswordFile policy. Ports use checked decimal 0–65535, default
5500; unlike retained `atoi`, suffixes/nonnumeric values fail explicitly. File paths
now prepare defaults → CLI → file settings and monitor choices for explicit review
before binding. File ServerName supplies the checked port (empty/absent → 5500).
Incoming windows reuse the approved settings without rereading files/preferences.
Unix socket listeners fail explicitly. LISTEN.md records the remaining scope.

## SSH invocation routing (2026-09-22)

`via` accepts a validated `[user@]host` or `ssh://[user@]host[:port]`. Every
occurrence is validated; the last valid occurrence wins, and an explicit empty
value selects direct routing. Preflight rejects an active gateway with `listen`
before path inspection. Known Unix-socket operands fail before session creation;
explicit files retain review, then validate their final target before allocating a
session. Gateway identity is published before the session and launch-password scope.
The compatibility file has no gateway field and export continues to require an
explicit gateway-loss acknowledgement.

The executable checks only the presence of `VNC_VIA_CMD`; when a CLI gateway is
active, it reports an unsupported customization before credentials, logging or app
startup. Its contents are never copied, evaluated, logged or passed to SSH. An empty
`via` does not use SSH and does not consult that customization. Help documents the
key/agent-only, existing-known-host-key behavior and missing interactive/configuration
support. See TUNNELS.md for ownership, tests and remaining parity work.
