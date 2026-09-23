# Native protocol baseline

The opt-in `tests/integration/macos-scaling-smoke.py` runs the actual viewer
executable against an ephemeral loopback RFB 3.8 peer. Both frontends retain the
same 55 wire cases: eight scaling modes × three filters × two pixel-unit choices,
one oversized-cursor case, and six automatic/explicit resize-policy cases.

```sh
python3 tests/integration/macos-scaling-smoke.py \
  build/native-ui-frontend/app/Debug/TidyVNC.app/Contents/MacOS/vncviewer \
  --frontend swiftui --report-dir build/native-protocol-report

python3 tests/integration/macos-scaling-smoke.py \
  build/hidpi-release/vncviewer/vncviewer \
  --report-dir build/fltk-protocol-report
```

Report directories must be new. `--quick` selects eight representative cases.
WindowServer, a Swift compiler, codesign and loopback access are required. The
report contains executable hash, OS/architecture, per-case status, requested
sizes, measured automatic-resize expectations and process exit codes. Per-case
logs are retained; a connection timeout also samples the owned process if alive.

## Assertions and limits

The peer sends fragmented raw updates, changes 320×240 to 321×241, replaces a
128×128 cursor with an empty cursor, and rejects desktop-size requests. The
fixture requires continued framebuffer requests for the new size, suppresses
automatic resize while scaling, preserves explicit 123×97 requests, compares
100% automatic logical/device requests with measured viewport dimensions, and
rejects repeated resize-denial loops. Clipboard transfer is disabled and the
fixture explicitly selects unauthenticated security on loopback.

The native frontend remains alive after peer disappearance. The fixture waits
for socket EOF before terminating/reaping its owned child. SIGTERM cleanup is
not evidence of interactive Quit, joined app shutdown or window dismissal.
FLTK retains its original process-exit and startup/backing-metric assertions.

This baseline does not inspect displayed pixels, inject input, establish
physical display/Spaces behavior, measure performance, or cover the complete
encoding/security/clipboard/listen/tunnel/reconnect matrix required by PLAN §12.
Those gates remain open. Fixture signatures do not establish installed-app,
Keychain, local-network consent or production signing acceptance.

## Isolation

For SwiftUI the harness copies the app, assigns a UUID-suffixed bundle identifier,
and ad hoc signs/verifies that copy. Native preferences derive their domain from
the bundle identifier; the ordinary app retains exactly
`io.github.jkeli.tidyvnc.native.preferences`. Each case has fresh HOME/XDG roots.
`CFFIXED_USER_HOME` relocates Foundation home/Application Support; the compiled
`native-isolation.swift` helper verifies these paths before launching the app.

A probe showed that changing HOME alone did not isolate CFPreferences. Therefore
the harness uses explicit unique domains, verifies they are initially empty, and
cleans only the exact fixture application/preferences domains. The helper rejects
any domain without the required prefix and valid UUID suffix. No user domain,
Keychain entry or trust record is deleted. Inherited credential/tunnel environment
inputs are removed and the peer never requests authentication or trust.

## Startup and diagnostics fixes found by this baseline

The first actual-app runs timed out before connecting. Temporary numeric/control
traces showed AppKit delivering one `openFiles` callback and creating zero windows:
it treated the endpoint operand as a document, preventing the scene from consuming
the already parsed native launch request. Before entering SwiftUI,
`NativeInvocationBootstrap.prepareAppKit()` now disables
`NSTreatUnknownArgumentsAsOpen` in the volatile argument domain, preserving other
entries and writing no durable preference. The same-process native parser owns
CLI endpoints/files; Finder document callbacks retain their existing router.
The real-app baseline failed before this change and passes after it.

The isolated window-ownership fixtures now supply real process operands, use the
same handoff and check that no synthetic file-open event replaces startup. These
fixtures alone did not reproduce the actual-app failure on this host; the real-app
before/after baseline is the regression evidence. They retain file review,
independent new-window and zero-window reopening checks.

The additive `tidyvnc_logging_viewport` C API accepts four checked numeric
measurements only. At debug level 100, `NativeDesktop` logs logical and backing
width/height through the existing redacted process route. The resize coordinator
emits a measurement when attempting a window resize; it never changes logging
policy and ignores logging failure. This preserves the FLTK baseline's measured
size comparison without exposing endpoints, display identities or input data.

## Local evidence — 2026-09-23

On macOS 27 arm64 with the Debug native app, the quick **8/8** and full **55/55**
matrices pass. The retained FLTK executable also passes **55/55** through the
updated harness. Initial reports are `build/native-protocol-startup-fixed`,
`build/native-protocol-full` and `build/fltk-protocol-adapter-regression`.
Final reports `build/native-protocol-final/summary.json` and
`build/fltk-protocol-final/summary.json` also pass **55/55** and retain wire sizes
and measured expectations. Their executable hashes match the tested binaries.
See RESUME.md and TODO.md for the full rebuilt and sanitizer verification.
The default frontend remains FLTK.

## Release and shared-fix evidence — 2026-09-23

The packaged Release executable from `8b56c793`
(`build/native-release-8b56c793/TidyVNC.app`) passes **55/55**
(`build/native-protocol-release-8b56c793`). After the shared-code sanitizer fixes
(empty-cursor copy, zero-length stream reads, TLS description logging), the native
Debug app and retained FLTK executable pass **55/55** again
(`build/native-protocol-shared-fixes`, `build/fltk-protocol-shared-fixes`). Each
report's executable hash matches the tested binary. Scope is unchanged: wire and
lifecycle assertions only.
