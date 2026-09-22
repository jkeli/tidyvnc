# Native UI work handoff

Updated 2026-09-21. Read this first when resuming, then use [TODO.md](TODO.md)
for the full checklist and historical evidence. The objective remains the entire
[PLAN.md](PLAN.md); this checkpoint does not establish parity or release readiness.

## Current state

- `1ba1fe0e`: accumulated native app, portable session services, C/Swift bridge,
  settings, credentials/trust, documents/imports and numeric CLI listening.
- `26fd7022`: previous planning handoff.
- `0d80192e`: a subsequent clipboard/UI-thread fix found on resume; preserved.
- `00f39b26`: reviewed file-listener planning checkpoint committed at user request.
- Current uncommitted follow-up: **reviewed connection-file listening**, including
  preparation without a session, immutable configuration reuse, UI and tests.
  A subsequent uncommitted **routed local socket boundary** now preserves a
  tunnel target's hostname independently of its forwarding socket (TUNNELS.md).
  The uncommitted **owned SSH process service** now validates gateway syntax,
  establishes acknowledged private Unix forwarding, and cancels/drains its own
  master/control child processes. It is not yet wired into app/CLI startup.
  Credential retention and launch inputs now accept route identity; the app must
  pass the selected tunnel route when its connection lifecycle is integrated.
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

That count describes the file-listener follow-up. The subsequent tunnel transport
boundary adds ROUTED_CONNECT and one C export (112 total), preserving existing ABI
structs and persisted schemas. Normal/ASan/TSan each passed the 15 socket connector
tests, pure-C ABI consumer and Swift bridge loopback test. Native/app builds,
signature verification and 29 terminal cases passed. The full native regression
rerun passed **77/77 (88.49 s)**, logged in
`/tmp/tidyvnc-routed-connect-native-tests.log`. All build/test/preview processes
from this follow-up completed; none was left running.

The later SSH service adds two native tests (79 total). The full normal run had
**78/79 pass (90.99 s)**; only the isolated SSH harness failed because CMake's
Python lacked os.waitid. The harness was corrected without changing production
code, and that test passed on rerun. After the final temporary-control-socket
cleanup fix, both tunnel tests passed **2/2 normal (2.21 s), 2/2 ASan (2.21 s),
2/2 TSan (6.41 s)**, including actual OpenSSH authentication/RFB forwarding (no
skips). The full 79-test run was not repeated after that focused cleanup change.
Logs: `/tmp/tidyvnc-ssh-service-*`.

Route-aware credential follow-up: retention and both launch-credential tests passed
**3/3 normal (1.37 s), 3/3 ASan (1.55 s), 3/3 TSan (7.68 s)**. The app rebuilt,
passed strict deep signature verification and **29/29** executable terminal cases.
No further ABI or schema change (112 C exports). All recorded builds, tests,
private children and isolated daemon fixtures completed. Latest credential evidence:
`/tmp/tidyvnc-tunnel-credentials-*`. The complete native suite has not been rerun
after the credential API change; the affected tests above cover its default and
route-specific authentication behavior.

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
   The post-approval listener screenshot check is now complete: the stable capture
   shows the full window and both peers, with displayed/socket port 51786 matching.
   Both recorded previews exited normally; preview control files were removed.
2. Continue N4.11 with supported tunnel entry paths. First inspect retained `via`/
   `tunnel` parsing and execution, connection-file precedence, process ownership,
   cancellation, effective endpoint identity and credential routing. Define an
   argv-based subprocess contract; do not interpolate shell strings or place secrets
   in relaunch arguments. Unsupported cases must fail explicitly. The new routed
   socket boundary is implemented and has focused normal/sanitizer validation; see
   [TUNNELS.md](TUNNELS.md). CLI `via` is still unsupported until its complete path
   is wired, including credential/trust route identity and process drain.
   The owned service and isolated real-SSH fixture are now implemented too.
   NativeAuthenticationCredentials now accepts routeIdentity in beginAttempt/key
   and optional early launch binding; focused normal/ASan/TSan tests pass. Preserve target/route through file
   review and ConnectionModel startup, cancellation, reconnect and quit. Trust
   already accepts an explicit routeIdentity. Add attempt-scoped child-exit
   handling, honest SSH capability presentation, and `via`/listen incompatibility
   checks before advertising support. Interactive SSH authentication/host-key and
   configuration support remain open; see the service's current limits.
   Extract gateway validation into an endpoint-independent value for CLI preflight
   before file IO; build the complete tunnel request only after final file target
   resolution. Define route-aware history/profile persistence and explicit export
   omission review before enabling `via`, so reopening a saved destination cannot
   silently replace a tunneled connection with a direct one.
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
