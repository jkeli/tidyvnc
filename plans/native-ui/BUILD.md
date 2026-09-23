# Native frontend build boundary

Updated 2026-09-22. This records N6.1/N6.3 and the implemented build portion of
N6.2. Full packaging, CI, installed-app acceptance and cutover remain open.

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

After `python3 apps/macos/build.py`, build the optional test executables and run
their separate CTest directories (the root directory does not aggregate tests):

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

## Observed result and limits

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

No full native suite or sanitizer rerun is claimed for this build-only change;
the native suite remains 87 tests. The prior full native result was 86/86 before
the compiler/catalog test was added. The declared 14.0 floor is **not** validated:
Homebrew dylibs on this host report macOS 26/27 minimums. A universal build, Intel
execution, minimum/current-OS CI, bundled relocatable dependencies, production
signing, Finder/Keychain/privacy acceptance, DMG/install/rollback and cutover all
remain unchecked in TODO. These development results do not waive those gates.
