# Native UI work handoff

Updated 2026-09-21. Read this first when resuming, then use [TODO.md](TODO.md)
for the full checklist and historical evidence. The objective is still the entire
[PLAN.md](PLAN.md); this checkpoint does not establish parity or release readiness.

## Committed checkpoint

`1ba1fe0e` — `feat(macos): add native viewer app and portable session bridge`
contains the accumulated implementation, tests and documentation: 404 files,
64,831 insertions and 1,381 deletions. The branch was `master`, and the worktree
was clean after that commit. This handoff is a subsequent documentation update.
Inspect current Git state before making further changes.

The latest implemented feature is native `-listen [port]` startup, alongside
File > Listen for Connections. Startup consumes argv once in the first ordinary
scene and opens a listener instead of an outbound connection. Numeric ports are
checked decimal 0–65535, default 5500; zero is ephemeral. UseIPv4/UseIPv6 control
binding. Incoming peers require explicit Accept and open independent windows with
resolved native defaults plus CLI settings. Launch credentials belong only to the
first successfully opened incoming window. Stop/close clears unclaimed inputs;
later peers cannot recapture environment credentials or recreate PasswordFile.
Reverse windows do not persist history/credentials/trust or reconnect outbound to
the observed source port. See [LISTEN.md](LISTEN.md) and
[CREDENTIAL-INPUTS.md](CREDENTIAL-INPUTS.md).

## Work interrupted before this checkpoint

The next implementation was **connection-file listening**, for example
`vncviewer -listen ./connection.tidyvnc`. Preliminary edits to the bootstrap,
document resolution and monitor-mapping types were interrupted by the request to
commit. Only those incomplete edits were removed before committing, restoring the
validated numeric-listen implementation. They are **not present in the commit**.

In particular, `NativeListenPort`, `NativeDocumentEndpointUse`, an `endpointUse`
mapping property, and the proposed `listenSocketUnsupported` error do not exist.
The current bootstrap still raises `listenFileUnsupported` for any listen operand
containing a slash/backslash, before path inspection. Do not merely remove that
guard: there is no listener file-review/admission path behind it yet.

## Next implementation steps

1. Reuse the existing defaults → CLI → explicit-file resolution, bounded reader,
   ignored-field review and display mapping. Refactor preparation so a listener
   can obtain a reviewed immutable configuration **without creating an unused
   NativeSession**. `NativeSessionDefaults.acceptDocument` currently creates a
   session immediately; preserve ordinary connection behavior while adding the
   preparation path. Proposed API names from the interrupted work are not binding.
2. Classify a listen path using the existing captured-cwd/file-versus-socket rules.
   Continue to reject Unix socket listeners explicitly. Read regular configuration
   files asynchronously with `NativeDocumentFileReader`; preserve relative-path,
   symlink, cancellation, size and special-file protections.
3. Give file `ServerName` a listener-port interpretation for this launch only.
   The intended checked native rule is empty/absent → 5500, decimal 0–65535 → that
   port, invalid/out-of-range → a redacted field error. Validate applicable duplicate
   occurrences and carry this interpretation through mapping/review reconstruction.
   Keep ordinary document endpoints unchanged. Retained FLTK instead uses
   digit-prefix `atoi` and defaults nonnumeric values to 5500; document the native
   difference, and do not claim complete CLI parity. Unsupported file fields retain
   existing ignored-field review; do not silently expand the file format.
4. Present file review and any required display mapping in the listener scene.
   Make the port, enabled families and Start Listening action clear. Do not bind
   until review is accepted. Preserve review identity and topology revalidation;
   close/cancel or a late reader result must never start a listener.
5. Retain the approved configuration as a value and pass it to each accepted peer.
   Do not reread the file or reapply newer preferences over reviewed file settings
   at acceptance. Preserve configuration provenance, inactive cursor shape, display
   choices and session-publication ordering. Explicitly decide and test behavior
   when a display disappears after review. Keep the existing single-owner launch
   credential handoff and connection-only reverse identity.
6. Add tests for file/CLI/default precedence, port validation/defaults, ignored
   fields, sparse display mapping and topology changes, malformed/special files,
   cancellation during IO/review, no pre-review bind/session, configuration reuse
   across two incoming peers, no credential replay, and listener/session shutdown.
   Update executable help and terminal expectations only when the route works.
   Inspect the actual review/listening UI, then update the contracts and TODO
   evidence with the exact checks performed.

## Files to start with

- `platform/macos/Settings/NativeInvocationBootstrap.swift`: typed launch,
  preflight, current listen-path rejection and terminal help.
- `platform/macos/Storage/NativePreferencesModels.swift`: NativeSessionDefaults,
  document review/mapping, publication and cancellation.
- `platform/macos/Settings/NativeDocumentResolution.swift` and
  `NativeDocumentMonitorMapping.swift`: field validation, precedence and mapping.
- `platform/macos/Storage/NativeDocumentFile.swift`: bounded file reader/review.
- `apps/macos/TidyVNC/ListenerModel.swift` and `ListenerView.swift`: listener start,
  peer reservation, credential transfer, state and window ownership.
- `apps/macos/TidyVNC/ConnectionModel.swift`: ReverseConnectionRequest and session
  preparation before reverse admission.
- `apps/macos/TidyVNC/TidyVNCApp.swift`: StartupPresentation, listener scene/window
  registration, incoming windows and quit drain.
- `apps/macos/TidyVNC/DocumentReviewView.swift` and
  `DocumentMonitorMappingView.swift`: existing review and mapping presentation.
- `tests/macos/NativeListenerUITests.swift`, `NativeInvocationBootstrapTests.swift`,
  `NativeInvocationResolutionTests.swift`, and the document/open/mapping fixtures.

## Validation checkpoint and commands

Before the commit, the normal build succeeded and the affected native selection
passed **15/15 (2.61 s)**. Staged whitespace and branding/attribution checks passed
(1650 deferred branding occurrences remain). Earlier numeric-listen evidence:
77-test normal run had one stale unsupported-listen expectation, subsequently
corrected and passed on targeted rerun; focused ASan/TSan checks passed; the app
built and passed strict deep signature verification and **29/29** terminal cases.
The full 77-test run was not repeated after that test-only correction.

The built app was also launched with `-listen -UseIPv6=off 0`, without environment
credentials. Its visible listener port matched the process's listening socket,
and normal process-targeted quit completed with exit 0. A Saved Profiles window
was restored too. This was limited startup/appearance evidence, not incoming app
interaction, restoration-policy acceptance or installed network/privacy testing.
Temporary evidence may disappear: `/tmp/tidyvnc-native-ui-commit-{build,tests}.log`,
`/tmp/tidyvnc-cli-listen-*`, and `/tmp/tidyvnc-cli-listen-launch.png`.

From the repository root, the current normal validation commands are:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build build/native-ui-swift -j 4
ctest --test-dir build/native-ui-swift/tests/macos --output-on-failure --no-tests=error -R '^(NativeInvocation\.|NativeListener\.|NativeDocument\.|NativeCredentials\.Launch)'
python3 apps/macos/build.py
codesign --verify --deep --strict build/native-app/app/Debug/TidyVNC.app
python3 tests/macos/invocation-terminal.py --app build/native-app/app/Debug/TidyVNC.app
python3 tests/rebrand/audit.py
git diff --check
```

For changed shared preparation code, rebuild and run the affected suites in
`build/native-ui-swift-asan` and `build/native-ui-swift-tsan` too. Expand selection
to the full native suite when shared lifecycle changes justify it. Test targets and
names are in `tests/macos/CMakeLists.txt`; unit and pure-C tests are under each
build's `tests/unit` and `tests/viewer`, respectively. App builds use the Xcode
developer directory selected by `apps/macos/build.py`; normal CMake Swift builds
above use Command Line Tools. Existing evidence is arm64 macOS 27, provisional
deployment target 14, dependencies built for newer OS versions, and crypto-disabled
sanitizer builds. It does not establish older-OS, Intel or Linux runtime support.

No build/test/app process from the completed checkpoint was left running. On
resume, revalidate any subsequently recorded live process handles before starting
duplicates. Do not run concurrent builds in one build directory or edit compiled
Swift sources while their builds run. AppKit/socket/build tools have needed sandbox
escalation; no approval rejection blocked this checkpoint. The user said the Mac
was unlocked. Slow tools or AXError.cannotComplete are not evidence of a lock.

## Work after connection-file listening

Continue N4.11 with supported tunnel entry paths and explicit ownership, cancellation
and identity policy; do not introduce shell-string interpolation or secret-bearing
relaunch arguments. Then address the remaining unchecked inventory/option coverage,
localization/accessibility, actual app interactions (including Save-panel quit),
physical keyboard/fullscreen/Spaces/multidisplay, installed Finder/LAN/privacy/
firewall, performance, deployment/architecture and signing/release gates. The full
numbered checklist remains authoritative; these priorities do not shrink its scope.
