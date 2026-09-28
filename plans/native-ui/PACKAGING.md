# Native app and disk-image assembly

Updated 2026-09-22. This implements the local package/dependency assembly part of
N6.2 and adds N6.7/N6.12 inspection evidence. It does not establish minimum-OS,
Intel, installed privacy/Keychain, production identity, notarization or cutover.

## One build and package path

`apps/macos/package.py` consumes the Xcode app, including its generated identity,
version, resources and SSH helper. It never edits that app or installed libraries.
Both the convenience script and root `native-package`/`dmg` targets use it:

```sh
python3 apps/macos/build.py --build-dir build/native-release \
  --configuration Release --parallel 2 --test --package
```

This command requires every dependency to support the declared deployment floor
(13.0 by default). `apps/macos/deps.py` builds the static dependencies for that
floor and checks every object in them; packaging fails if any Mach-O binary
requires a newer OS. Neither check proves the app runs on the floor.
The package floor can be raised explicitly with `--package-minimum-os`, which
changes the staged app's `LSMinimumSystemVersion` and records both build and
package floors. It cannot be lowered below the input app's declaration.

For the current host's macOS 26/27 Homebrew dependencies, the local inspection
command is explicitly restricted to macOS 27:

```sh
python3 apps/macos/build.py --build-dir build/native-ui-frontend \
  --parallel 2 --test --package --package-minimum-os 27.0 \
  --package-output build/native-package-pipeline
```

Default output is `build-dir/package/configuration`. A result contains
`TidyVNC.app`, `TidyVNC-version-architecture.dmg` and `package-report.json`.
Output directories must be new; publication uses an exclusive atomic rename,
including protection from a concurrently created empty directory. Failed assembly
removes only its private temporary stage. It never replaces an existing package.

The direct CMake equivalents are `TIDYVNC_NATIVE_PACKAGE_OUTPUT`,
`TIDYVNC_NATIVE_PACKAGE_MINIMUM_OS` and `TIDYVNC_NATIVE_PACKAGE_SIGN_IDENTITY`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
cmake -S . -B build/native-ui-frontend/core \
  -DTIDYVNC_NATIVE_PACKAGE_OUTPUT="$PWD/build/native-package-target" \
  -DTIDYVNC_NATIVE_PACKAGE_MINIMUM_OS=27.0
cmake --build build/native-ui-frontend/core --target dmg --parallel 2
```

`macapp` continues to build the development bundle. Packaging is explicit, never
part of an ordinary all-target build. Existing FLTK release targets are unchanged.
To package an already built app, use `package.py --app ... --output ... --dmg`.
Without `--dmg`, it assembles and verifies the app/report only.

## Dependency and signing contract

The packager reads Mach-O load commands, recursively resolves ordinary/weak/
re-export/upward dependencies, deduplicates canonical paths and handles loader,
executable and inherited runpaths. It rejects missing/ambiguous resolutions,
destination collisions, escaping bundle symlinks, FLTK dependencies, mismatched
architectures and deployment floors. System libraries remain OS-owned; they may
exist only in the dyld shared cache. Third-party libraries are linked statically
(`apps/macos/deps.py`), so any dynamic library outside the app is rejected, as is
a `Contents/Frameworks` directory in the final package. Fat binaries are
rejected; the native build supports one architecture per build directory.

Loads between the app's own binaries become explicit `@loader_path` paths.
Original runpaths are removed, library IDs are rewritten, and a separate final
audit requires a closed in-bundle dependency graph. Source/final binary hashes, declared
minimums, architecture, dependency edges and signing mode are recorded. No claim
is made that inspecting load commands validates optional runtime plugins or every
TLS/authentication path; native protocol acceptance is still N6.5/N6.6.

`--deps` names the `deps.py` prefix. Its `deps.json` must match the prefix's
libraries, architecture and a floor no newer than the package's. Each package's
upstream licence texts are copied to `Contents/Resources/ThirdParty/<package>`,
with a `README.txt` naming every library's version, source archive URL and
SHA-256; the report records the same with the notice hashes. Missing licence
text is an error. Distributing the corresponding source archives with releases
remains a release-workflow task. No release publication occurs here.

Nested binaries are signed individually before the final app seal; verification
uses `codesign --verify --deep --strict`, never deep signing. Every binary gets
the hardened runtime; no runtime exceptions are needed, since nothing is loaded
dynamically. Ad hoc signing is the default. `--sign-identity` selects a real
identity with a secure timestamp and requires `--provisioning-profile`: the
profile must be a macOS profile for `io.github.jkeli.tidyvnc` that includes the
signing certificate and has not expired. It is embedded, and the main executable
alone gets its application and team identifiers, which the Data Protection
Keychain needs. The disk image is signed too.

With `--notary-key`, `--notary-key-id` and `--notary-issuer`, the app is
notarized (as a zip) and stapled before the DMG is made, so it opens offline
once copied out, then the DMG is notarized and stapled. Gatekeeper must accept
both as notarized; where its assessments are disabled, `codesign
--check-notarization` checks the notarized requirement instead. The report
records the entitlements, submission IDs and verdicts. Only ad hoc signing has
been exercised locally; the Developer ID path runs in `release.yml`. Keychain
access, privacy persistence and upgrade behavior of a signed app remain open.

Before publication, the app is copied to a second path containing spaces. Its
help command must execute with an isolated HOME/XDG environment and no dependency
search overrides. A DMG includes the app, README, licence and Applications link;
`hdiutil verify` must pass. Notarization status is in the report, not the
sealed app, whose manifest is written before signing.

## Inspection and regression coverage

```sh
python3 tests/macos/package-tests.py
python3 tests/macos/package-inspect.py \
  --dmg build/native-package-pipeline/TidyVNC-1.16.80-arm64.dmg \
  --source-app build/native-ui-frontend/app/Debug/TidyVNC.app \
  --report build/native-package-pipeline/package-report.json
```

The inspector mounts the DMG read-only without opening Finder, compares binaries
against the report, checks the closed dependency graph, compares original app
resources/identity except the explicit floor, verifies notices and strict signing,
checks undefined FLTK symbols and runs all 36 actual executable CLI cases. It also
checks the image's README/licence/Applications link and detaches in a `finally`
block. `--app` performs the same bundle checks without mounting an image. These
are terminal checks, not Finder-launched Local Network or Keychain acceptance.

Sixteen policy regressions cover malformed/unsupported Mach-O metadata, weak and
re-export loads, transitive cycles/aliases, inherited runpaths, ambiguity, missing
libraries, name collisions, architecture/floor/FLTK rejection, escaping symlinks,
system-path normalization, final relocation audit, rejected dynamic third-party
libraries and `Contents/Frameworks`, the dependency manifest checks, recorded
notices and sources, input immutability, failed-stage cleanup and exclusive
publication. They are registered
as `NativePackage.DependencyClosureAndPolicy`.

The native CI definition runs build/test/package and mounted-image inspection;
the package declares the app's deployment floor. Artifacts include the
DMG/report and inspection log. A current-OS runner does not stand in for a
minimum-OS runner.
Hosted execution remains unverified. See RESUME/TODO for final local run evidence.

## Local checkpoint

Direct CMake `dmg` and the complete convenience build/test/package pipeline pass
on arm64 macOS 27/SDK 27, Debug, GnuTLS/nettle on and NLS/audio/H.264 off. The final
`build/native-package-pipeline` result contains **13 binaries / 11 bundled dylibs**,
explicitly declares macOS **27.0**, and passes the mounted-DMG inspector including
**36** CLI cases. The DMG is
`TidyVNC-1.16.80-arm64.dmg` (SHA-256
`5ce0805d95e166cd644e9df280eca4fde584782fc253e5faa10e75fb9447fc4b`).
The image is detached and no private staging directory remains. Final full test
report is `build/native-ui-frontend/verification/run-mi4r1bps/summary.json`, with
**3/756/89** passing tests. Thirteen package policy regressions, generated graph
checks (**170/3**), workflow YAML/shell parsing, branding and diff checks pass.

The first no-override packaging attempt correctly failed before publication on
nettle's 27.0 minimum versus the app's 14.0 declaration. Subsequent local packages
raised the declared package floor explicitly. This is not evidence for macOS 14,
Intel, a clean Release package, production identity or Finder-launched behavior.

## Clean Release package (2026-09-22)

A new `build/native-release-validation` tree builds the optimized core, native
bridge, Xcode app and all test targets. After fixing a clipboard test's ambiguous
frame-publication wait, the full Release pipeline passes **3 viewer / 756 unit /
89 native** tests. The corrected fixture separately passes 30 Debug and 30 Release
repetitions; no application-code change was required.

Artifact: `build/native-release-validation/package/Release/TidyVNC-1.16.80-arm64.dmg`
(SHA-256 `31684912587385f21ce9eeb21a5c7a376aed0cba241f805926d656151e9fdf6b`).
Its report records **13 signed binaries / 11 bundled dylibs** and the explicit
**27.0** package floor. Read-only mounted inspection passes resources/notices,
identity, dependency closure, symbols, strict signature and all 36 CLI cases; the
image is detached afterward. Source/compiled English localization remains 1052 UI
plus two metadata entries. Full evidence is in
`build/native-release-validation/verification/run-mu47vmxj/summary.json`.

The clean Release package gate is now locally verified on arm64 macOS 27. The
minimum-OS/Intel, intended signing identity, real installed services, distribution
obligations and full protocol/UI/physical/performance gates remain open.

## Release package at the implementation commit (2026-09-23)

`build/native-release-validation` was rebuilt at `8b56c793` (all targets, `--test
--package --package-minimum-os 27.0`) and published `build/native-release-8b56c793`.
Full verification `verification/run-tia1q75j` passes **3/756/89**. DMG SHA-256
`ac238bdcee5e11972bc7ae014e79ae7e7d9b246e6674347d15ba4f86ce9be54a`; the mounted
inspector passes 13 binaries / 11 bundled libraries, closure, notices, identity,
strict signature, symbols and 36 CLI cases, then detaches. The packaged executable
passes the 55-case protocol baseline. Minimum-OS, Intel, production identity and
installed behavior remain open.

## Release package after the 2026-09-23 fixes

Rebuilt at `621dd02a` (after the sanitizer, secret-wiping, JPEG, grammar and
bell changes): verification `build/native-release-validation/verification/run-1py7qpl5`
passes **3/776/90**. Package `build/native-release-621dd02a`: DMG SHA-256
`85b496bfa0495340e9d5989e076df66bd210f284bf9169cd2792013d3f0437a5`, packaged
executable `a39372919c6c366783e185001100b6c35d310885027ca2d3263c6f02f8198646`.
The mounted-image inspection passes (13 binaries, 11 libraries, 36 CLI cases), the
packaged app passes the 4 actual-app authentication/trust cases and the 55-case
protocol baseline (`build/native-protocol-release-621dd02a`, hash matched). The
package floor is still the explicit 27.0 host-dependency floor.
