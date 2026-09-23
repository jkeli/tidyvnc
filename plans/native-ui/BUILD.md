# Native frontend build boundary

Updated 2026-09-22. This records N6.1/N6.3 and the implemented build/test portions
of N6.2. Native CI jobs are defined; hosted results are not yet verified. Full
packaging, installed-app acceptance and cutover remain open.

## Selection and ownership

`cmake/ViewerFrontend.cmake` defines `TIDYVNC_UI=FLTK|SWIFTUI`, default FLTK.
Unknown values and non-Apple SwiftUI selections fail rather than falling back.
`BUILD_VIEWER=OFF` disables either app; `BUILD_MACOS_NATIVE=ON` remains an
independent bridge/test option. Derived frontend flags do not overwrite the
caller's cached viewer/bridge preferences. FLTK AUTO detection retains its prior
missing-package behavior. Platform server/tool selection is unchanged.

SwiftUI application builds require the single-configuration Ninja generator,
Debug or Release, full Xcode/Swift 6, CMake 3.29+, Python and one arm64/x86_64
architecture. The deployment target defaults to 14.0 and cannot be lower. The
selected developer directory is captured for the Xcode commands. Bridge-only
builds still work with Command Line Tools.

The root `vncviewer` target builds the C++/Swift dependencies once, configures a
separate Xcode project, builds its bundle, and runs the compiler/catalog audit.
`macapp` is an alias; ordinary all-target builds also include the app. No nested
invocation builds the core directory. `apps/macos/build.py` delegates to this same
target, retaining its existing app output directory. The app never starts during
these build checks. Xcode continues to own resource compilation and development
signing; native app/bridge source manifests are generated from target sources.

The exported `NativeBuild.cmake` records source/version, configuration, SDK,
architecture and deployment floor. The app rejects mismatched inputs **before**
compiler probes and limits its configuration list to the core configuration.
`NativeTargets.cmake` supplies libraries and transitive dependency paths. The
release plist remains the identity/version metadata source, transformed by the
existing native plist helper; no parallel identity file is introduced.

FLTK discovery, application/release resources, `surface`, `viewerstate` and
`fbperf` use the derived FLTK selection. The shared protocol/core tests and
benchmarks are independent of it. See [BUILD-MACOS](../../BUILD-MACOS.md) for
the convenience and direct CMake commands and their output paths.

## Reproduce validation

The complete scripted path is:

```sh
python3 apps/macos/build.py --test --parallel 2
```

This requires GoogleTest, requests the core/app File API graphs, builds all
targets, then invokes `tests/macos/verify-build.py`. It runs all three CTest
directories serially (120-second default timeout for tests without their own
limit) and performs graph, configure-rejection, packaged
localization, strict signature and actual CLI checks. Each run gets a fresh
directory under `build/native-app/verification`, with per-stage logs, JUnit and
`summary.json`. The summary records toolchain/host information, executable hash,
commands, counts and explicit exclusions from acceptance. Stages continue after
a failure to preserve diagnostic evidence, but the overall exit is nonzero.

The verifier compares JUnit cases with the complete discovered CTest inventory,
including repeated GoogleTest display names. Missing/extra tests, skips, disabled
tests, failures, malformed reports and command failures cannot produce a pass.
Nine failure/coverage tests are registered as `NativeBuild.CompleteTestEvidence`.
CTest skips for an unavailable isolated SSH fixture remain incomplete acceptance;
the job does not silently waive them.

For individual investigation after building all targets, use the separate CTest
directories (the root directory does not aggregate tests):

```sh
cmake --build build/native-app/core --parallel 4
ctest --test-dir build/native-app/core/tests/viewer --output-on-failure --no-tests=error
ctest --test-dir build/native-app/core/tests/unit --output-on-failure --no-tests=error
ctest --test-dir build/native-app/core/tests/macos --output-on-failure --no-tests=error
python3 tests/macos/frontend-configuration.py build/native-app/core
python3 tests/macos/invocation-terminal.py --app build/native-app/app/Debug/TidyVNC.app
xcrun swift -module-cache-path /tmp/tidyvnc-bundle-check \
  tests/macos/localization-bundle.swift build/native-app/app/Debug/TidyVNC.app \
  apps/macos/Localizable.xcstrings
codesign --verify --deep --strict build/native-app/app/Debug/TidyVNC.app
```

`frontend-configuration.py` uses disposable configure directories, leaving the
supplied core untouched. Pass `--developer-dir` for another full Xcode. It verifies
invalid selector, generator, configuration, deployment floor, missing Swift/Xcode,
CLT-only selection when installed, and app/core SDK/architecture/floor mismatch
diagnostics. An invalid developer directory may be rejected by CMake's initial C
compiler probe with the system's missing-DEVELOPER_DIR diagnostic.

For generated dependency inspection, request the CMake File API before configuring
both the core and app directories, then rebuild/reconfigure:

```sh
mkdir -p build/native-app/core/.cmake/api/v1/query build/native-app/app/.cmake/api/v1/query
touch build/native-app/core/.cmake/api/v1/query/codemodel-v2
touch build/native-app/app/.cmake/api/v1/query/codemodel-v2
python3 apps/macos/build.py
python3 tests/macos/frontend-graph.py build/native-app/core build/native-app/app
```

The checker requires the native and smoke targets, checks that the root viewer is
an Xcode-delegating utility target, rejects FLTK-only targets, and inspects each
generated configuration's source/compile/link inputs. Run the independent
[clean headless check](../../viewer/README.md) too. The frontend policy test is
registered as `ViewerBuild.FrontendSelection` when Python is available.

## Frontend selection checkpoint and limits

On the arm64 macOS 27 development host with Xcode's macOS 27 SDK:

- Clean `build/native-ui-frontend` Debug core/app succeeds through `build.py`;
  direct `macapp` and portable smoke targets succeed. Compiler localization audit:
  139 Swift sources, 1351 call sites, 1050 catalog keys.
- Native core/app File API graphs contain 168/3 targets with no FLTK source,
  compile or link inputs. Discovery is disabled explicitly. All three viewer
  tests pass (0.67 s), including the five policy-test groups.
- Ten real configure failure checks pass. The initial SDK mismatch test exposed
  compiler probing before the handoff check; moving validation before `project()`
  fixed the diagnostic ordering. The configuration script also now expects the
  system diagnostic when DEVELOPER_DIR itself does not exist.
- Clean headless configure/dependency audit/full build passes, followed by 3/3
  viewer tests and **756/756** unit tests (21.43 s). No GUI dependency enters its
  portable graph.
- Retained `build/hidpi-release` FLTK viewer, `fbperf`, `surface` and `viewerstate`
  build; the 19 affected surface/state tests pass (0.32 s). Existing source and
  platform behavior are retained. No Windows/Linux build was run on this host.
- The selected app passes 32 actual executable CLI cases, 1050 UI + 2 InfoPlist
  bundle values/fallback/interpolation checks, and strict deep signature validation.

No full native suite or sanitizer rerun was claimed for the selection checkpoint;
its native suite contained 87 tests. The earlier full result was 86/86 before
the compiler/catalog test was added. The declared 14.0 floor is **not** validated:
Homebrew dylibs on this host report macOS 26/27 minimums. A universal build, Intel
execution, minimum/current-OS CI, bundled relocatable dependencies, production
signing, Finder/Keychain/privacy acceptance, DMG/install/rollback and cutover all
remain unchecked in TODO. These development results do not waive those gates.

## Native CI definition

`.github/workflows/native-macos.yml` runs the same `build.py --test` path with two
build jobs. It preserves the existing Windows/Linux/macOS FLTK and headless
workflows. The new matrix is:

| Role | Runner | Architecture | Xcode | Configuration |
| --- | --- | --- | --- | --- |
| Provisional minimum OS | macos-14 | arm64 | 16.2 | Debug |
| Current stable OS | macos-26 | arm64 | 26.6 | Debug |
| Current stable Intel | macos-26-intel | x86_64 | 26.6 | Debug |
| Optimized app/core | macos-26 | arm64 | 26.6 | Release |
| Next toolchain/OS preview | xcode-27 | arm64 | image default | Debug |

Runner labels and architecture follow GitHub's [hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Xcode paths were checked against the official [macOS 14 ARM](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-arm64-Readme.md),
[macOS 26 ARM](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
and [macOS 26 Intel](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
image inventories. The [Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
is a preview and follows its default toolchain. These pages were checked on
2026-09-22; actual toolchain, host and installed dependency versions are saved per
run. The macOS 14 inventory announces retirement on 2026-11-02. Before retirement,
provide a suitable minimum-OS runner; do not remove the gate to make CI green.

The workflow checks the actual architecture, requires all suites, retains failure
logs/JUnit/summary/rendered fixtures, and archives the development bundle when one
exists. That ZIP is for inspection, including failed runs; it is not a distribution
package or release. No deployment, publication, signing credential or secret is
required. Homebrew dependencies are recorded but remain unbundled.

No hosted job was run or result inspected in this checkpoint. Workflow YAML and
its shell steps were parsed locally. Minimum-OS/Intel execution and older Swift
compatibility remain unproven until real jobs pass. The provisional minimum on
Intel also lacks a configured runner. Actual keyboard/VoiceOver, Finder/privacy/
Keychain, mixed physical displays, production signing/dependency portability and
notarization remain separate gates. N6.4 is still unchecked.

## Automated verification checkpoint — 2026-09-22

The final `build.py --build-dir build/native-ui-frontend --parallel 2 --test`
finishes successfully. `verification/run-yhdlyz2o/summary.json` records **3/3
viewer, 756/756 core (21.81 s), 88/88 native (129.47 s)**, FLTK-free graphs with
168 core/3 app targets, 10 configure rejection cases, 1050 UI + 2 metadata bundle
entries, strict signature and 32 executable CLI cases. The build's compiler audit
passes 139 Swift sources/1351 call sites. Nine verifier regressions, workflow YAML
and shell parsing, branding baseline 1650 and diff checks also pass.

The pipeline uncovered a real SSH early-exit notification race, now fixed with a
deterministic regression, 20 repetitions each of lifecycle/real ECDSA and targeted
ASan/TSan lifecycle proof. A second rebuild exposed Swift's unchanged localization
record timestamps; completed-build content receipts now establish freshness, with
16 checker regressions. See [TUNNELS.md](TUNNELS.md), [LOCALIZATION.md](LOCALIZATION.md)
and [TODO.md](TODO.md) for failed-run history and final evidence. This is Debug on
arm64 macOS 27/SDK 27 with GnuTLS/nettle and without NLS/audio/H.264. It does not
establish the unexecuted CI matrix, dependency portability or manual acceptance.
