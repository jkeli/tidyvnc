# Native UI work handoff

Updated 2026-09-21. Read this first when resuming, then use [TODO.md](TODO.md)
for the full checklist and historical evidence. The objective remains the entire
[PLAN.md](PLAN.md); this checkpoint does not establish parity or release readiness.

## Current state

- `1ba1fe0e`: accumulated native app, portable session services, C/Swift bridge,
  settings, credentials/trust, documents/imports and numeric CLI listening.
- `26fd7022`: previous planning handoff.
- `0d80192e`: a subsequent clipboard/UI-thread fix found on resume; preserved.
- Current uncommitted follow-up: **reviewed connection-file listening**, including
  preparation without a session, immutable configuration reuse, UI and tests.
  Inspect current Git state before editing; do not remove another task's changes.

Native `-listen [port]` and File > Listen for Connections already worked. The new
path is `vncviewer -listen ./connection.tidyvnc`. It classifies files versus sockets,
reads files through the bounded reader, applies defaults → CLI → file precedence,
and shows review/display mapping before any bind or session allocation. File
ServerName is a checked decimal 0–65535 port; empty/absent means 5500 and zero is
ephemeral. Invalid duplicate occurrences fail. Unix socket listeners remain
unsupported. This checked policy differs from retained digit-prefix `atoi` and
nonnumeric-default handling; full CLI parity is not claimed.

Approval retains NativePreparedSessionDefaults: configuration plus inherited,
document and invocation metadata. Incoming windows consume the exact reviewed
value without rereading preferences or files. Mapping retains the listener-port
interpretation; stale reviews and changed display topology cannot bind. Selected
reviewed display IDs must still be connected at explicit peer acceptance. Reconnect
those displays, or close/reopen the file to review a different selection; ordinary
session/fullscreen topology handling applies after admission.

The listener's captured credential owner still transfers to only its first
successfully opened incoming window. Cancel review, Stop or close clears unclaimed
inputs; reload and later incoming peers never recapture them. Reverse windows keep
history, Keychain, durable trust, document export and outbound retry disabled.
See [LISTEN.md](LISTEN.md), [CLI.md](CLI.md), and
[CREDENTIAL-INPUTS.md](CREDENTIAL-INPUTS.md).

The earlier four-file prototype was removed before `1ba1fe0e`; it is historical.
The new implementation now does contain NativeListenPort, NativeDocumentEndpointUse,
monitor-mapping endpointUse, and listenSocketUnsupported. Do not follow the older
handoff's statement that these APIs are absent or restore listenFileUnsupported.

## Files and ownership to preserve

- `platform/macos/Storage/NativePreferencesModels.swift`: NativeSessionDefaultsPurpose
  distinguishes ordinary session creation from listener preparation. Its approved
  snapshot bypasses store/file reads on incoming-session creation. Metadata is
  published before the session. Existing ordinary document behavior stays intact.
- `platform/macos/Settings/NativeDocumentResolution.swift`: listener-specific
  per-occurrence ServerName validation and typed listenPort; ordinary endpoints
  keep their existing meaning. The persisted file catalog is unchanged.
- `NativeDocumentMonitorMapping.swift` in that directory: endpointUse survives
  mapping, re-edit and topology recovery.
- `NativeInvocationBootstrap.swift` / `NativeInvocationResolution.swift`: typed
  listen launch, file/socket classification, checked numeric ports and help/errors.
- `apps/macos/TidyVNC/ListenerModel.swift`: prepare once, approve before bind, retain
  snapshot, check displays before Accept, transfer credentials once, drain on close.
  Only a display service created by this model is stopped by it.
- `ListenerView.swift` / `DocumentReviewView.swift`: file review, recovery and
  listening presentation. The listener UI test target now includes both document
  review and monitor-mapping view sources.
- `ConnectionModel.swift`: ReverseConnectionRequest carries the approved snapshot;
  NativeSessionDefaults installs it before reverse handoff.
- `TidyVNCApp.swift`: the startup listener receives preferences and the shared
  display service. Startup/quit/window ownership otherwise uses the existing path.
- `tests/macos/NativeListenerUITests.swift`: file precedence, no pre-review bind or
  session, sparse mapping/re-edit, topology changes, stale approval, two peers with
  closed preferences/changed source, cancellation during IO/review, and port errors.

## Validation for this follow-up

Normal native/app builds passed. Full normal native suite: **77/77 (87.91 s)**.
Six affected document/invocation/listener tests: **6/6 ASan (3.80 s)** and
**6/6 TSan (17.20 s)**. Strict deep app signature verification and **29/29** actual
executable terminal cases passed. Branding/attribution checks passed with 1650
unchanged deferred occurrences. See the latest TODO evidence for visual scope.
No C ABI or persisted schema changed; the existing 111 C exports remain.

Evidence prefix: `/tmp/tidyvnc-file-listen-`. Temporary logs/images can disappear;
rerun checks when needed. The test fixture uses memory preferences and private peers.
Its `--file-preview` mode displays review and can transition to a live listener:
create `/tmp/tidyvnc-file-listen-preview-accept` to approve, and
`/tmp/tidyvnc-file-listen-preview-stop` to close. It also exits after 120 seconds.
Remove those two fixture control files before another preview. The normal tests do
not use them. Do not confuse a fixture screenshot with full installed-app acceptance.

## Next steps

1. Inspect the current diff and latest evidence. Resolve any newly found file-listener
   issue before moving on; retain the complete ordinary/native regression coverage.
   Finish the post-approval listener screenshot check: the first capture had
   incomplete window chrome, so visual acceptance is still pending. Check whether
   preview PID 33132 (exec session 70935) has exited before starting another fixture;
   stop/drain it if still running and clear the two preview control files.
2. Continue N4.11 with supported tunnel entry paths. First inspect retained `via`/
   `tunnel` parsing and execution, connection-file precedence, process ownership,
   cancellation, effective endpoint identity and credential routing. Define an
   argv-based subprocess contract; do not interpolate shell strings or place secrets
   in relaunch arguments. Unsupported cases must fail explicitly.
3. Continue the unchecked parity inventory and option coverage, localization and
   accessibility, actual app interactions (including quit while Save is presented),
   physical keyboard/fullscreen/Spaces/multidisplay, installed Finder/LAN/privacy/
   firewall, performance, deployment/architecture and signing/release gates. These
   priorities do not replace or narrow the numbered checklist.

## Commands and environment

From the repository root:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build build/native-ui-swift -j 4
ctest --test-dir build/native-ui-swift/tests/macos --output-on-failure --no-tests=error
python3 apps/macos/build.py
codesign --verify --deep --strict build/native-app/app/Debug/TidyVNC.app
python3 tests/macos/invocation-terminal.py --app build/native-app/app/Debug/TidyVNC.app
python3 tests/rebrand/audit.py
git diff --check
```

Focused native test names are in `tests/macos/CMakeLists.txt`; the document prefix
is **NativeDocuments**, plural. For shared preparation changes, rebuild affected
executables in `build/native-ui-swift-asan` and `build/native-ui-swift-tsan` before
running their matching CTests. Unit and pure-C tests live under each build's
`tests/unit` and `tests/viewer`. App builds use the Xcode developer directory chosen
by `apps/macos/build.py`; normal CMake Swift builds above use Command Line Tools.

Evidence is arm64 macOS 27, provisional deployment target 14, dependencies built
for newer OS versions, and crypto-disabled sanitizer builds. It does not establish
older-OS, Intel or Linux runtime support. Revalidate recorded process handles before
starting duplicates; observation delay alone does not mean a process stopped.
Never build concurrently in one directory or edit compiled Swift sources while its
build runs. AppKit/socket/build checks have needed sandbox escalation; no approval
rejection blocked this work. The user said the Mac was unlocked. Slow tools or
AXError.cannotComplete are not evidence of a lock.
