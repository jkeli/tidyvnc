# macOS compatibility after the Windows native UI

Reviewed 2026-09-25, comparing the pre-Windows checkpoint `931baffb` with
`372e2678`. The review covers the shared core, C bridge, platform selection,
TLS file handling, and macOS build/verification paths.

## Findings and fixes

- The Windows UTF-8 path test target was duplicated into the macOS/Linux test
  block. A fresh macOS Release build reproduced the `windows.h` compilation
  failure. Removed that duplicate; the Windows/MSVC registration is retained.
  The native build-graph audit now rejects Windows-only targets as well as FLTK.
- The macOS configure-rejection test still expected the old two-frontend error
  message. Updated it for WinUI and added a real configure check that selecting
  WinUI on macOS fails explicitly.
- The same test implicitly selected the Command Line Tools SDK even with a
  different Xcode selected. On this host that paired SDK 27 with Xcode 26.4.1's
  linker and failed before testing frontend policy. Its disposable configurations
  now inherit the built core's explicit SDK, with deliberate mismatch cases
  still overriding it. All 11 configure-rejection cases pass.

No macOS runtime compatibility defect was found in the reviewed changes.
All 117 existing C function declarations retain their signatures; 16 exports
are additive. The socket capability definition reaches the macOS static bridge.
The endpoint separator and extended TLS-path changes are Windows-guarded;
macOS retains its existing socket adapters and file paths. The invocation-value
validator's extraction into `canonicalParameter` retains the macOS CLI behavior.
The new policy modules do not automatically replace the existing Swift adapters.

## Release build

The build uses Apple Silicon, Xcode 26.4.1 / Swift 6.3.1, SDK 26.4, and a macOS
14 source deployment target. The relocatable package explicitly requires macOS
27.0 because of the installed dependency binaries. It is ad-hoc signed and not
notarized; no public release, installation, or remote publication was performed.

```sh
python3 apps/macos/build.py \
  --build-dir build/native-windows-compat-release \
  --configuration Release \
  --prefix '/opt/homebrew;/Users/kyle/Projects/tidyvnc/build/test-deps/install' \
  --test --package --package-minimum-os 27.0
```

Xcode needs its normal build services/cache access. After correcting the SDK
test, verification and packaging were invoked directly against the already-built
Release app; no source rebuild was needed for that Python-only correction.

Artifact: `build/native-windows-compat-release/package/Release/TidyVNC-1.16.80-arm64.dmg`.

SHA-256: `e98e6ad409d4eb78f2cf22e137733bed9bf71841d4f597ff6212358feff22a5d`.

The adjacent `package-report.json` records all 13 signed binaries, 11 bundled
libraries, minimum OS requirements, dependency edges, notices, and hashes.
Read-only mounted-DMG inspection passes dependency/resource/signature/symbol
checks and all 36 CLI cases, then detaches the image.

## Verification evidence

`build/native-windows-compat-release/verification/run-zit_c5h2/summary.json`
is the final passing report: **3/3 viewer, 791/791 shared-core, 90/90 native**,
frontend build graphs, **11** configure-rejection cases, bundled localization,
strict bundle signature, and **36** executable CLI cases. The earlier report is
retained as evidence of the SDK-selection test failure.

The packaged app also passes **55/55** protocol/lifecycle cases
(`protocol/summary.json`), **4/4** authentication cases (`authentication.log`),
**5/5** noninteractive security handshakes (`security.log`: VncAuth, TLSNone,
TLSVnc, X509None, X509Vnc), and VncAuth through an isolated loopback OpenSSH daemon
(`tunnel.log`). These paths are relative to `build/native-windows-compat-release`.
All app launches use isolated temporary copies and preference domains.

These automated results do not establish interactive keyboard/VoiceOver,
physical display, installed-service, Intel, or older-macOS acceptance. Prompt-driven
RSA-AES/reconnect interaction tests were not run in this review.
