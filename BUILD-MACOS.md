# Building TidyVNC on macOS

## Experimental SwiftUI build (2026-09-22)

`TIDYVNC_UI=FLTK|SWIFTUI` selects the viewer frontend. **FLTK remains the
default** until the [native acceptance gates](plans/native-ui/TODO.md) pass.
SwiftUI requires macOS, full Xcode with Swift 6, CMake 3.29+, Ninja, Python 3,
pkg-config and Meson. Command Line Tools alone can build the native
bridge/tests, but cannot build the Xcode application. Bridge-only builds also
require Python for completed-build localization receipts. The deployment target
is macOS 13.0 on Apple silicon; the app has not yet been run on macOS 13.

### Dependencies

The app links GMP, Nettle, libidn2, GnuTLS, pixman and libjpeg-turbo
statically. `apps/macos/deps.py` builds them from upstream release archives with
pinned SHA-256 hashes, for Apple silicon and macOS 13.0, into
`build/native-deps/arm64`; `build.py` runs it first and it returns at once
while the prefix matches its recipe. Homebrew supplies only build tools and, for
`--test`, GoogleTest:

```sh
brew install cmake ninja pkgconf meson googletest
python3 apps/macos/deps.py --check
```

`--check` also runs the GMP, Nettle and libjpeg-turbo test suites. The build is
isolated from Homebrew libraries, and the script fails if any library object
requires a newer macOS than the target. GnuTLS reads the macOS Keychain as its
system trust store and is built without p11-kit, TPM or certificate compression.
`deps.json` in the prefix records each package's version, source and hash, and
`share/licenses` holds their licence texts. Update a package by changing its
entry in `PACKAGES`, after checking the new archive's upstream signature.

The convenience command configures one CMake core and uses its `vncviewer` target
to configure/build the separate Xcode app, then checks compiler localization
records against the catalog:

```sh
python3 apps/macos/build.py --configuration Debug
```

Add `--test` to require GoogleTest, build every test executable and run the full
automated core/model/adapter/render-fixture and bundle checks. `--parallel` limits
concurrent build jobs; CTest suites run serially to avoid competing AppKit fixtures:

```sh
python3 apps/macos/build.py --configuration Debug --parallel 2 --test
```

Each invocation saves a fresh `build/native-app/verification/run-*/summary.json`,
JUnit reports and logs. Every registered test must run and pass; skipped tests
fail this verification rather than silently satisfying coverage. Failed stages
do not prevent collection of the remaining test and bundle evidence. These checks
do not establish interactive keyboard/VoiceOver, physical-display, installed
privacy/Keychain or distribution acceptance.

Output: `build/native-app/app/Debug/TidyVNC.app`. Use `--configuration Release`,
`--build-dir`, `--developer-dir`, `--deps`, `--prefix` or `--deployment-target` to
select another configuration, directory, Xcode, dependency prefix, GoogleTest
prefix or deployment floor.
The script retains its existing output layout. Core and app share the SDK,
architecture and deployment target; the Xcode project offers only the core's
configuration, preventing a Release app from linking a Debug core.

For direct CMake use, after `deps.py` (pkg-config must see only its prefix):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PKG_CONFIG_LIBDIR=$PWD/build/native-deps/arm64/lib/pkgconfig \
cmake -S . -B build/native-selected -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=$PWD/build/native-deps/arm64 \
  -DTIDYVNC_UI=SWIFTUI -DBUILD_VIEWER=ON -DBUILD_PLATFORM_APPS=OFF \
  -DENABLE_NLS=OFF -DENABLE_AUDIO=OFF -DENABLE_H264=OFF \
  -DENABLE_GNUTLS=ON -DENABLE_NETTLE=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE
cmake --build build/native-selected --target macapp --parallel 4
```

The direct output is `build/native-selected/native-app/Debug/TidyVNC.app`.
`vncviewer` and `macapp` both build the development bundle. `native-package` and
`dmg` assemble a separate relocatable app and disk image; see below.
`TIDYVNC_NATIVE_APP_BUILD_DIR` can select a separate generated Xcode
directory. The SDK and host architecture are selected from the configured
toolchain; explicit `CMAKE_OSX_SYSROOT`, `CMAKE_OSX_ARCHITECTURES` and
`CMAKE_OSX_DEPLOYMENT_TARGET` values are supported. Use one `arm64` or `x86_64`
architecture per build directory and matching dependencies. Only the arm64
development-host result is currently verified; see the [build evidence](plans/native-ui/BUILD.md).

`BUILD_VIEWER=OFF` disables both viewer applications. `BUILD_MACOS_NATIVE=ON`
remains available independently for bridge/model tests with Command Line Tools.
The FLTK surface/viewer-state tests and `fbperf` are enabled only for the FLTK
frontend. Portable unit tests, protocol benchmarks and smoke consumers remain
available without FLTK. Neither core-only nor SwiftUI builds discover FLTK.

These are ad hoc signed development bundles. Installed
privacy/Keychain behavior, minimum-OS and architecture coverage, production signing,
notarization, interactive parity and cutover remain open.
See [native build validation](plans/native-ui/BUILD.md) for reproducible checks.

### Opt-in actual-app checks

These run a built app, or isolated copies of it (`tests/macos/isolated-app.py`,
which uses a UUID bundle identifier and fresh HOME/XDG roots), against loopback
fixtures. They need WindowServer and are not part of `--test`. Replace `APP` with
`build/native-ui-frontend/app/Debug/TidyVNC.app`.

| Command | Checks |
| --- | --- |
| `python3 tests/integration/macos-scaling-smoke.py APP/Contents/MacOS/vncviewer --frontend swiftui` | 55 protocol/lifecycle cases |
| `python3 tests/integration/macos-auth-smoke.py APP` | VncAuth accepted, rejected and vanished; untrusted TLS |
| `python3 tests/integration/macos-security-smoke.py APP [--accept-prompts]` | VncAuth, TLS and CA-trusted X509 against the project's server-side handlers; with `--accept-prompts`, also all RSA-AES variants and Retry reconnect |
| `python3 tests/integration/macos-tunnel-smoke.py APP` | `-via` through a loopback `sshd` |
| `python3 tests/integration/macos-rollback-smoke.py APP FLTK-vncviewer` | FLTK and native data stay separate; FLTK opens a native export |
| `python3 tests/macos/accessibility-audit.py APP` | VoiceOver labels on 27 screens |
| `python3 tests/macos/fltk-baseline.py (FLTK-vncviewer \| APP --native) DIR` | Window-only baseline screenshots |
| `python3 tests/perf/viewer-workloads.py --native APP --fltk FLTK-vncviewer [--alloc-trace]` | Matched CPU, memory, throughput and allocation rate |
| `python3 tests/perf/viewer-workloads.py --probe <core>/tests/macos/native-presentation-probe` | Native presentation latency, copies and damage |

`--accept-prompts` and the accessibility audit drive the app only through the
accessibility API, so the caller must be an accessibility client. The draw and
allocation traces use `DYLD_INSERT_LIBRARIES` and work only with local,
non-hardened builds. See [UI-ACCEPTANCE.md](plans/native-ui/UI-ACCEPTANCE.md),
[PERFORMANCE.md](plans/native-ui/PERFORMANCE.md) and
[BASELINE.md](plans/native-ui/BASELINE.md) for the recorded results. The user
guide is [doc/macos-native-viewer.md](doc/macos-native-viewer.md).

### Native package and DMG

Add `--package` to the convenience build to assemble and verify a self-contained
app and DMG after the requested tests. The app may link only libraries and
frameworks macOS provides; packaging fails on any other dynamic library. The
licence texts of the static dependencies go to `Contents/Resources/ThirdParty`
with a README naming each one's source archive. The input app remains
unchanged. Output defaults to `build-dir/package/configuration` and must not
already exist. `--package-output` selects another fresh directory:

```sh
python3 apps/macos/build.py --configuration Release --parallel 2 --test --package
```

The package checks every binary's architecture and minimum macOS version, so it
declares the app's deployment target. Running on that macOS version is not yet
verified. Ad hoc
signing is the default; `--sign-identity` selects a configured signing identity.
No notarization or publication occurs. The [packaging contract and inspection
commands](plans/native-ui/PACKAGING.md) document root CMake targets, dependency
notices, failure behavior, mounted-DMG checks and remaining installed-app gates.

## Retained FLTK build (default)

The commands below supersede the historical commands retained further down.
Use a separate FLTK 1.4.5 dependency build; the main project never downloads code.
Install native dependencies as described in the historical requirements section
(except FLTK 1.3, which is no longer supported). GoogleTest is required to run the
unit suite; provide its install prefix alongside the other dependencies.

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake -S cmake/FLTK -B build/fltk-dependency -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/build/fltk-install"
cmake --build build/fltk-dependency --parallel 8
cmake -S . -B build/tidyvnc-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DFLTK_DIR="$PWD/build/fltk-install/share/fltk" \
  -DCMAKE_PREFIX_PATH="$PWD/build/test-deps/install;/opt/homebrew/opt/gettext;/opt/homebrew" \
  -DBUILD_VIEWER=ON -DENABLE_NLS=ON \
  -DENABLE_GNUTLS=ON -DENABLE_NETTLE=ON -DENABLE_H264=OFF -DENABLE_AUDIO=OFF
cmake --build build/tidyvnc-release --parallel 8
ctest --test-dir build/tidyvnc-release/tests/unit --output-on-failure --no-tests=error
cmake --build build/tidyvnc-release --target dmg
```

`macapp` stages `build/tidyvnc-release/TidyVNC.app` without making a disk image.
`dmg` stages the same app and creates
`build/tidyvnc-release/release/TidyVNC-2.0.0.dmg`. Both targets build required
catalogs first; no separate translation build or manual copy step is needed.
Use `TIDYVNC_FLTK_SHARED=ON` for shared FLTK; the old option remains a deprecated
alias and conflicting values are rejected. Repeat with `build/tidyvnc-debug` and
`CMAKE_BUILD_TYPE=Debug` for development checks.

The app uses `io.github.jkeli.tidyvnc`, a complete 1x/2x iconset, and the `tidyvnc`
gettext domain. New .tidyvnc documents are registered; legacy documents remain
readable through the command line and file dialog. See
[the migration policy](plans/rebrand/MIGRATION.md) and
[rebrand evidence/open gates](plans/rebrand/TODO.md).

These are local development artifacts with Homebrew dylib dependencies, without
distribution signing or notarization. Packaged visual review and physical display
checks remain open; a passing build is not a portability or visual-quality claim.

### Local Network permission

The packaged app includes `NSLocalNetworkUsageDescription` and is signed after
its plist and resources are assembled, using `io.github.jkeli.tidyvnc` as its
signing identifier. `TIDYVNC_MACOS_SIGN_IDENTITY` defaults to `-` (ad hoc) for
local builds. For reliable privacy identity across updates, configure an
Apple-issued code-signing identity with
`-DTIDYVNC_MACOS_SIGN_IDENTITY="Your signing identity"`. This does not add
notarization or make the Homebrew-dependent app distributable.

Launch the installed `.app` from Finder and connect to a local VNC server.
macOS requests consent when that connection requires it. Allow TidyVNC in the
prompt, then retry if the first connection failed while consent was pending.
If previously denied, enable TidyVNC under System Settings > Privacy & Security
> Local Network and reconnect. If already enabled, check the address, routing
and firewall; “No route to host” alone does not establish a privacy denial.

See [Apple's Local Network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
Shell-launched loopback tests do not verify Finder-launched consent behavior.
The local machine currently has no valid signing identity; ad hoc builds still
need interactive consent and permission-persistence validation.

---

## Historical TigerVNC build evidence

The remainder records earlier measured builds and original checkout paths.
Their artifact names, commands, timestamps and hashes are intentionally retained.

# Building the native TigerVNC client on macOS

This document records both the original FLTK 1.3 baseline and the subsequent
FLTK 1.4 / HiDPI implementation builds. For the current code, start with
[FLTK 1.4 / HiDPI implementation build](#fltk-14--hidpi-implementation-build-2026-09-17)
and the later validation findings. The FLTK 1.3 instructions below apply only
to the historical baseline.

The baseline was verified on 2026-09-17 against commit `9cb71cda` (TigerVNC
1.16.80). Its native client, unit tests, and macOS DMG built successfully
without source changes, before client scaling and HiDPI were implemented.

## Results and artifacts

All paths below are relative to the repository root, `/Users/kyle/Projects/tigervnc` on the tested machine.

| Artifact | Path |
| --- | --- |
| Native arm64 executable | `build/macos/vncviewer/vncviewer` |
| Ready-to-open local app bundle | `build/macos/TigerVNC.app` |
| Disk image containing the app | `build/macos/release/TigerVNC-1.16.80.dmg` |
| Configure log | `build/macos/configure.log` |
| Compiler/linker log | `build/macos/build.log` |
| Unit-test results | `build/macos/tests.log` |
| Packaging log | `build/macos/package.log` |
| Bare executable help output | `build/macos/viewer-help.log` |
| App-bundle help output | `build/macos/bundle-help.log` |

Validation completed:

- Full default CMake build, including the viewer, performance tools, translations, and unit-test executables.
- **269/269 unit tests passed**, using CTest in `build/macos/tests/unit`.
- `file` identified the viewer as a Mach-O 64-bit arm64 executable.
- `otool -L` resolved its linked libraries; the executable started and printed its version/help.
- The generated bundle's `Info.plist` passed `plutil -lint`.
- The local app launched and visibly rendered the VNC connection dialog. No remote-server connection or authentication session was tested.
- The repository's `dmg` target completed successfully outside the restricted execution sandbox.

The app was left at the connection dialog. To open it again:

```sh
open build/macos/TigerVNC.app
```

## Tested environment

| Component | Version / selection |
| --- | --- |
| Host | Apple Silicon, macOS 27.0, build 26A428 |
| Developer tools | `/Library/Developer/CommandLineTools` |
| Compiler | Apple Clang 21.0.0, clang-2100.3.34.2 |
| SDK | MacOSX27.0.sdk |
| CMake | 3.30.2, from `/Applications/CMake.app` via `/opt/homebrew/bin/cmake` |
| Ninja | 1.13.2 |
| FLTK | 1.3.11 (`fltk@1.3`) |
| pixman | 0.46.4 |
| libjpeg-turbo | 3.2.0 |
| gettext | 1.0 |
| GnuTLS | 3.8.13, Homebrew revision 2 |
| Nettle | 4.0 |
| GMP | 6.3.0 |
| GoogleTest | 1.18.0 |
| zlib | SDK library, CMake-reported version 1.2.12 |

Build type: `RelWithDebInfo`. TLS, RSA-AES, and native-language support are explicitly enabled. H.264 is disabled because FFmpeg was not installed. Audio is disabled because this revision has no macOS audio backend. Java is disabled for this native-client build.

This is a **local development build**, dynamically linked to Homebrew libraries. `vtool -show-build` reports minimum macOS **27.0** and SDK **27.0** because no older deployment target was requested. It is neither an Intel/universal build nor a self-contained release for other Macs. Packaging does not bundle the Homebrew dylibs, sign with a distribution identity, or notarize the app.

## Prerequisites

Start with working Apple Command Line Tools or Xcode and Homebrew. The standard dependency installation command is:

```sh
brew install cmake ninja pkgconf fltk@1.3 pixman jpeg-turbo gettext \
  gnutls nettle gmp googletest
```

Use **FLTK 1.3**, not an unversioned newer FLTK. Although `BUILDING.txt` says “1.3.3 or later,” the actual top-level CMake check requires major 1 and minor 3. The repository's macOS CI also installs `fltk@1.3`. See the [FLTK download page](https://www.fltk.org/software.php) and [Homebrew's versioned formula](https://formulae.brew.sh/formula/fltk%401.3) for the dependency sources.

On this machine, CMake, Ninja, pixman, gettext, GMP, and JPEG support were already installed. The build effort installed `fltk@1.3`, `gnutls`, `nettle`, and `googletest`. Homebrew also installed their missing dependencies (`json-c`, `libidn2`, `libtasn1`, and `p11-kit`) and upgraded `jpeg-turbo` to 3.2.0 and `ca-certificates` to 2026-08-13. Automatic update, cleanup, and installed-dependent checking were disabled for that installation. No TigerVNC system-wide install was performed.

## Working configure, build, and test commands

Run from the repository root. These are the settings used for the successful build:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

mkdir -p build/macos
# Ignore generated files locally without changing the repository's .gitignore.
printf '*\n' > build/macos/.gitignore

cmake -S . -B build/macos -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH='/opt/homebrew/opt/fltk@1.3;/opt/homebrew/opt/gettext;/opt/homebrew' \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_VIEWER=ON \
  -DBUILD_JAVA=OFF \
  -DENABLE_NLS=ON \
  -DENABLE_GNUTLS=ON \
  -DENABLE_NETTLE=ON \
  -DENABLE_H264=OFF \
  -DENABLE_AUDIO=OFF

cmake --build build/macos --parallel 8
ctest --test-dir build/macos/tests/unit --output-on-failure --parallel 8

build/macos/vncviewer/vncviewer --version
```

The explicit prefix path locates FLTK 1.3 and gettext without force-linking them into Homebrew's global prefix. `BUILD_VIEWER=ON` makes missing viewer dependencies fatal instead of allowing automatic viewer disablement. The security/NLS options similarly prevent silent feature loss.

GoogleTest is discovered automatically; no `BUILD_TESTING=ON` switch is needed here. Always check that GTest was found and CTest actually runs tests. This tree calls `enable_testing()` in `tests/unit`, so use that directory explicitly, as macOS CI does. A top-level CTest invocation is not the verified command.

For incremental viewer-only development:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/macos --target vncviewer --parallel 8
```

For Debug, use a separate build directory and the same configure options with `CMAKE_BUILD_TYPE=Debug`. Debug enables `-Werror`; that configuration was not tested during this effort. Likewise, H.264 can be requested with `ENABLE_H264=ON` after providing FFmpeg development libraries, but was not tested here.

When changing architecture, SDK, dependency versions, or FLTK paths, prefer a fresh build directory. CMake caches package paths and feature-check results, including the FLTK compatibility check.

## Xcode license prompt and Command Line Tools workaround

The machine's global `xcode-select -p` points to `/Applications/Xcode.app/Contents/Developer`, but Xcode reports that its license has not been accepted. Consequently, plain `clang`, `xcrun`, and even `otool` fail through that selection.

The separately installed Command Line Tools work. A per-command or exported `DEVELOPER_DIR` selects them without changing `xcode-select` or accepting a license:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools xcrun --show-sdk-path
DEVELOPER_DIR=/Library/Developer/CommandLineTools clang --version
DEVELOPER_DIR=/Library/Developer/CommandLineTools otool -L build/macos/vncviewer/vncviewer
DEVELOPER_DIR=/Library/Developer/CommandLineTools vtool -show-build build/macos/vncviewer/vncviewer
```

An additional wrinkle: the installed Homebrew 6.0.17 launcher filters its environment and drops `DEVELOPER_DIR`. Thus `DEVELOPER_DIR=... brew install ...` still hit the Xcode license prompt. Inspection of `/opt/homebrew/bin/brew` and `Library/Homebrew/brew.sh` established the cause.

The exact host-specific workaround used for dependency installation was to call Homebrew's shell entry point with its required bootstrap variables and the CLT selection:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
HOMEBREW_PREFIX=/opt/homebrew \
HOMEBREW_REPOSITORY=/opt/homebrew \
HOMEBREW_LIBRARY=/opt/homebrew/Library \
HOMEBREW_BREW_FILE=/opt/homebrew/bin/brew \
HOMEBREW_ORIGINAL_BREW_FILE=/opt/homebrew/bin/brew \
HOMEBREW_USER_CONFIG_HOME=/Users/kyle/.homebrew \
HOMEBREW_NO_AUTO_UPDATE=1 \
HOMEBREW_NO_INSTALL_CLEANUP=1 \
HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
/bin/bash /opt/homebrew/Library/Homebrew/brew.sh \
  install fltk@1.3 gnutls nettle googletest
```

This uses Homebrew internals and is recorded as the working workaround for this specific installation, not a stable Homebrew API. Prefer ordinary `brew install` when the selected developer tools are working. No Homebrew scripts or system toolchain settings were modified. Network/package installation required execution outside the restricted sandbox; its initial DNS failure was environmental, not a missing formula.

## Packaging and the local app bundle

The project's DMG target stages the app, translations, license, and README, then invokes `hdiutil`:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake --build build/macos --parallel 8
cmake --build build/macos --target dmg
```

Build the default target first. `release/makemacapp.in` unconditionally copies every translation named in `po/LINGUAS`, but the `dmg` target only directly depends on the viewer and packaging inputs. Building only `vncviewer` and then `dmg`, or disabling NLS, can leave those `.mo` files missing.

Inside the execution sandbox, packaging failed with `hdiutil: create failed - Device not configured`. Retrying the same target with disk-image access outside the sandbox succeeded. macOS 27 also emits a deprecation warning for `hdiutil create -volname`; it is currently nonfatal. The packaging target's temporary app directory is removed after creating the DMG.

A persistent local `build/macos/TigerVNC.app` was separately staged from the same executable, generated plist, icon, and translations. To recreate or refresh that local bundle after rebuilding, use:

```sh
python3 - <<'PY'
from pathlib import Path
import shutil

root = Path.cwd()
build = root / 'build/macos'
contents = build / 'TigerVNC.app/Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Resources').mkdir(parents=True, exist_ok=True)
shutil.copy2(build / 'vncviewer/vncviewer', contents / 'MacOS/vncviewer')
shutil.copy2(build / 'release/Info.plist', contents / 'Info.plist')
shutil.copy2(root / 'media/icons/tigervnc.icns',
             contents / 'Resources/tigervnc.icns')
for lang in (root / 'po/LINGUAS').read_text().split():
    dest = contents / 'Resources/locale' / lang / 'LC_MESSAGES'
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(build / 'po' / (lang + '.mo'), dest / 'tigervnc.mo')
PY

plutil -lint build/macos/TigerVNC.app/Contents/Info.plist
build/macos/TigerVNC.app/Contents/MacOS/vncviewer --version
open build/macos/TigerVNC.app
```

The local app contains a **copy** of the binary. Rebuilding the executable does not refresh this copy automatically; rerun staging before testing it. Quit a running instance before replacing its bundle contents. The DMG also needs rebuilding after code changes.

## Findings useful for future work

- **Bare executables print a locale warning.** `Failed to determine locale directory` appeared during test discovery and bare viewer startup. On macOS, `common/core/i18n.cxx` searches the main app bundle for `Resources/locale`; it does not use the usual Unix locale path. The warning disappeared when running the staged app's executable. It did not prevent any tests or the viewer from running.
- **Use `--help` or `-h`, not `-help`.** The latter is rejected. The viewer's help routine exits with status 1 even when it successfully prints help. Use `--version` for an exit-zero startup check.
- **DPI behavior is explicitly configured.** `release/Info.plist.in` sets `NSHighResolutionCapable` to false. Preserve/understand that setting when implementing scaling or diagnosing Retina behavior; do not assume the packaged viewer requests native high-resolution backing pixels. A bare executable and app-bundle launch should both be considered during future DPI testing.
- **No macOS audio backend exists in this revision.** `ENABLE_AUDIO=ON` is a configure-time error on Apple platforms; `OFF` makes the intended build explicit.
- **The shipped sanitizer switches exclude macOS.** `ENABLE_ASAN` and `ENABLE_TSAN` are guarded by `NOT APPLE` in top-level CMake. Setting those switches alone does not instrument this build; macOS sanitizer work will require a separate supported configuration.
- **FLTK discovery may mention X11 on macOS.** The configure log found local Homebrew X11 libraries while resolving FLTK, but `otool -L` for the resulting viewer showed the Cocoa/Carbon path and no direct X11 dependency. The macOS backend remained selected.
- **Observed build warnings were nonfatal.** Italian translation metadata was incomplete; the linker ignored duplicate static libraries in performance tools; test discovery emitted the bundle-related locale warning. There were no compiler errors and no required source patches.
- **Dependency compatibility is verified only to the exercised extent.** Nettle 4.0 and GnuTLS 3.8.13 compiled and linked successfully here. Unit tests and startup are not evidence of a completed encrypted VNC session.
- **Build products are local and ignored.** `build/macos/.gitignore` ignores the entire generated directory, including logs. Preserve logs separately if needed for CI/review. Only this Markdown document is intended as a new repository deliverable; unrelated `.DS_Store` files were left alone.

For another Mac or a distributable release, explicitly choose and validate a deployment target, supply matching architecture/minimum-OS dependencies, and address dylib bundling, signing, and notarization. Changing `CMAKE_OSX_DEPLOYMENT_TARGET` alone cannot make newer Homebrew dylibs compatible with older macOS versions.

## FLTK 1.4 / HiDPI implementation build (2026-09-17)

The implementation in `plans/hidpi/TODO.md` is in progress. These commands
preserve the original FLTK 1.3 build in `build/macos`.

The new standalone dependency project pins FLTK 1.4.5 and verifies SHA-256
`eede1fb2b8e9c2e581e77082e15252145855c79aad30070ee3b24aabe2f926f1`.
It builds Cocoa on macOS and disables FLTK's native Wayland backend on Linux.
The TigerVNC server Wayland option remains independent.

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake -S cmake/FLTK -B build/fltk-dependency -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PWD/build/fltk-install"
cmake --build build/fltk-dependency --parallel 8
cmake -S . -B build/hidpi -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DFLTK_DIR="$PWD/build/fltk-install/share/fltk" \
  -DCMAKE_PREFIX_PATH='/opt/homebrew/opt/gettext;/opt/homebrew' \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_VIEWER=ON -DENABLE_NLS=ON \
  -DENABLE_GNUTLS=ON -DENABLE_NETTLE=ON \
  -DENABLE_H264=OFF -DENABLE_AUDIO=OFF
cmake --build build/hidpi --parallel 8
ctest --test-dir build/hidpi/tests/unit --output-on-failure --no-tests=error
```

For an offline dependency build, pass
`-DFLTK_ARCHIVE=/absolute/path/fltk-1.4.5-source.tar.gz` to the dependency
configure step. The checksum is still enforced. Build shared FLTK with
`-DFLTK_SHARED=ON`; select it in TigerVNC with `-DTIGERVNC_FLTK_SHARED=ON`.
The shared install and application build must use separate build directories
from an existing static configuration. `BUILD_STATIC` cannot be combined
with shared FLTK.

Findings:

- Generic Homebrew include directories can put installed FLTK 1.3 headers
  before the selected FLTK 1.4 package. The viewer and `fbperf` explicitly
  order the chosen FLTK include directory first while retaining system-header
  treatment. A successful `find_package()` alone does not prevent this mix.
- FLTK 1.4 requires an explicit platform header for macOS application-menu
  customization. The About callback now uses `Fl_Sys_Menu_Bar::about()`.
- macOS window drawing must retain FLTK's CGContext transform and clip.
  FLTK applies GUI scale independently of Cocoa backing scale; the viewer
  measures both and combines them once. FLTK's half-unit stroke origin must
  be adjusted when copying images whose coordinates describe pixel edges.
- `Fl_Image_Surface::image()` retains a high-resolution raster and separate
  logical dimensions in 1.4. Use `data_w()/data_h()` for storage/stride and
  `w()/h()` for UI placement. Treating them as interchangeable breaks overlays.
- The staged app has `NSHighResolutionCapable=true`. A live local RFB fixture
  displayed a 320×240 framebuffer at 160×120 logical units in Device mode on
  a display reporting a 2× backing ratio. This verifies basic placement and
  orientation, not raw-pixel fidelity, pointer automation, or mixed-monitor
  behavior. The screenshot tool presents a logical-size image.
- A sandboxed launch could not connect even to loopback and produced macOS
  service errors. The local fixture and GUI launch required approved execution
  outside the sandbox. Do not mistake those service errors for render failures.
- The original 269 tests passed after upgrading FLTK. The first renderer test
  pass had 277 tests; later fixture/parameter tests increase that count.
  Final counts and build evidence belong in `plans/hidpi/TODO.md`.
- `build/hidpi-viewer-off` builds with `BUILD_VIEWER=OFF` and
  `CMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE`. The source dependency bootstrap also
  built static and shared FLTK into `build/hidpi-shared-deps`; a Debug shared
  viewer builds in `build/hidpi-debug-shared`.

Current release limits: macOS per-monitor fullscreen has an implementation but
still needs physical mixed-display, hotplug, seam-input and Spaces verification.
Allocation-failure/leak testing and end-to-end performance sign-off remain open.
The user excluded Java parity and deferred Windows/Linux work.
The staged app is a development artifact, not a signed/notarized release.

The live grid fixture is now checked in as
`tests/integration/rfb-scaling-fixture.py`. Run it with Python 3, then launch
with `-RemoteResize=0 -ViewOnly=0 -SendClipboard=0 -AcceptClipboard=0
-DesktopPixelUnits=Device -ScalingFactor=100 127.0.0.1:5909`. It binds only
loopback, draws a known 320×240 image and logs pointer protocol coordinates.
It is a manual fixture, not an automated input or screenshot test.

The focused `scalingperf` executable measures the portable resampler without
native composition or decoding. On this host, specializing nearest/bilinear
sampling reduced 1080p→4K median times from 34.00/72.40 ms to 3.79/29.70 ms.
Area uses the bilinear path when enlarging both axes (29.65 ms here). Record
end-to-end rendering separately before accepting a frame-time budget.

Earlier local checks (before the macOS continuation): 282/282 tests passed in
RelWithDebInfo/static and Debug/shared configurations; viewer-off built with
FLTK discovery disabled. `git diff --check` passed. Options-page navigation
and pointer protocol assertions were not successfully exercised by GUI
automation and remain manual validation tasks. The staged development app
was refreshed with the current binary and Retina-capable plist.

## macOS continuation: rendering, display changes and fullscreen

The continuation adds `DesktopSession`, `DesktopView`, `DesktopLayout`,
`DesktopTileCache`, and `CursorRenderer`. Each fullscreen monitor has a native
window and its own backing scale; the primary viewport retains session input
and clipboard state. The connection owns one framebuffer. Source damage is
harvested once and broadcast before any view reuses cached tiles.

Useful findings:

- FLTK 1.4.5's Cocoa `Fl_Image_Surface(..., high_res=1)` consults
  `Fl::first_window()` for Retina status, rather than the intended drawing
  target. Calling `make_current()` alone is insufficient. Overlay/statistics
  surfaces now allocate explicit measured backing dimensions and scale only
  their bitmap CGContext. A native bitmap test verifies exact pixel edges.
- FLTK's integer widget enclosure must be separate from the image's fractional
  logical position. Backing-pixel scrollbar values allow half-logical-unit pan
  at 2× and expose the last column of odd-width Device images correctly.
- A fullscreen window has one backing scale. Independent windows remove that
  restriction; Cocoa backing/screen/resize notifications enqueue a coalesced
  refresh. Observers and timers must be removed before their owner disappears.
- `CConn::~CConn()` closes the connection and frees its framebuffer before
  deleting the desktop window. Teardown must destroy secondary consumers
  without calling the ordinary fullscreen-exit layout path, which reads the
  framebuffer dimensions.
- CoreGraphics display IDs provide stable RFB screen IDs. Never multiply a
  desktop origin by one display's scale. Device canvases normalize overlaps
  caused by unequal monitor pixel sizes; the options preview uses the same
  layout. Fit modes use a logical canvas regardless of fixed-unit preference.
- Scaled output tiles retain at most 32 MiB per view and 128 MiB aggregate CPU
  cache. Native composition retains at most 4 MiB per view. The fixed sampling
  grid permits panning/exposure reuse. Cache-entry allocation failure drops the
  cache and preserves the already computed scratch output. Original remote
  framebuffer/cursor storage is separate from this cache accounting.
- Oversized cursors retain original premultiplied source pixels and generate
  only visible 256×256 tiles. The tests include a virtual 100,000-pixel-wide
  cursor without allocating that output image. Native auth banner icons now
  draw vector shapes; the existing app icon contains 128/256/512-pixel assets.

The opt-in integration test launches the supplied viewer against an ephemeral
loopback RFB peer. It sends fragmented updates, an odd framebuffer resize,
large/blank cursors, and rejected desktop-resize replies:

```sh
python3 tests/integration/macos-scaling-smoke.py build/hidpi/vncviewer/vncviewer
# Representative subset, useful during development:
python3 tests/integration/macos-scaling-smoke.py build/hidpi/vncviewer/vncviewer --quick
```

For the experimental SwiftUI frontend, add `--frontend swiftui` and pass its app
executable. `--report-dir` records a fresh run; see
[the native protocol baseline](plans/native-ui/PROTOCOL.md) for isolation and scope.

All 55 full-matrix protocol/lifecycle cases passed locally (48 scaling/quality/
unit combinations, one oversized-cursor case and six resize-policy cases).
The fixture checks the automatic Device request against the viewer's measured
backing ratio, preserves explicit 123×97 DesktopSize, checks scaling suppression,
and detects repeated requests after denial. It does not inspect displayed pixels
or synthesize user input. The GUI requires WindowServer/loopback access outside
this task's sandbox; the Mac was locked during visual inspection, so no new
interactive or physical mixed-monitor result is claimed.

Current unit evidence: 293/293 passing in both RelWithDebInfo/static and
Debug/shared, including native Quartz bitmap tests. See `plans/hidpi/TODO.md`
for final sanitizer, performance and packaging evidence. Logs remain in the
ignored `build/hidpi/` directory. Development app bundles are unsigned and do
not establish compatibility with older macOS releases.

Sanitizer check (pure helpers only):

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake -S . -B build/hidpi-sanitized -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_VIEWER=OFF \
  -DENABLE_NLS=OFF -DENABLE_GNUTLS=OFF -DENABLE_NETTLE=OFF \
  -DENABLE_H264=OFF -DENABLE_AUDIO=OFF -DCMAKE_PREFIX_PATH=/opt/homebrew \
  '-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -Wno-macro-redefined -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' \
  '-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -Wno-macro-redefined -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' \
  '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined'
cmake --build build/hidpi-sanitized --parallel 8 --target \
  desktoptransform desktopresampler desktoplayout cursorrenderer desktoptilecache
ctest --test-dir build/hidpi-sanitized/tests/unit \
  -R 'DesktopTransform\.|DesktopResampler\.|DesktopLayout\.|DesktopTileCache\.|CursorRenderer\.' \
  --output-on-failure --no-tests=error
```

All 20 selected tests pass. AppleClang's sanitizer build predefines
`_FORTIFY_SOURCE=0`; the project's unconditional `=2` caused a macro-redefinition
error under Debug's `-Werror`. The override above applies only to this isolated
sanitizer build. Production hardening flags remain unchanged. The existing
`ENABLE_ASAN` option excludes macOS, so explicit flags are necessary here.

The refreshed app bundle and the Debug/shared viewer also pass the eight-case
protocol subset. `otool -L` confirms no FLTK 1.3 linkage in the static viewer;
Homebrew runtime dependencies remain, so staging is not distribution packaging.
Physical monitor testing, signing/notarization and minimum-OS validation remain
separate release tasks.

Latest `scalingperf` measurement on this macOS arm64 host (six runs after
warmup, CPU resampling/cache only): 1080p→4K full resampling medians were
4.65 ms Nearest, 28.18 ms Bilinear and 28.04 ms Area. A cached 4K exposure
cost 0.46–0.48 ms; a one-source-pixel change cost 0.53–0.75 ms. The cache
retained 31.64 MiB. Full-damage cache runs measured 4.12/28.64/28.65 ms.
These numbers exclude decoding, native composition, presentation and input
latency; they do not satisfy the identity-regression or end-to-end frame-budget
gates. Raw output: `build/hidpi/scalingperf.log`.

## Commit-boundary validation (2026-09-18)

The implementation was split into dependency, geometry, rendering-helper,
native-surface, viewer-integration and standalone-fix commits. Staged snapshots
were exported into a temporary source tree, using the existing static FLTK
1.4.5 install and a fresh macOS Debug build with the Command Line Tools:

- The dependency-upgrade snapshot alone built `vncviewer` and `fbperf`.
- The geometry snapshot built and passed 12 transform/settings/layout tests.
- The rendering-helper snapshot built `scalingperf` and passed eight
  resampler/cache/cursor tests.
- The native-surface snapshot built `vncviewer` and `fbperf` and passed four
  bitmap tests.
- The viewer-integration snapshot completed a full build and passed all
  293 unit tests in 13.24 seconds.

These checks establish that the earlier commits do not require files from
later implementation commits. They do not add physical-display or
cross-platform runtime evidence beyond the validation recorded above.

## Explicit Release build (2026-09-18)

Built commit `33556c96` with `CMAKE_BUILD_TYPE=Release` in
`build/hidpi-release`, preserving the earlier RelWithDebInfo and Debug builds.
This is an arm64 build using static FLTK 1.4.5, with TLS, RSA-AES and
translations enabled; Java, H.264 and audio are disabled.

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cmake -S . -B build/hidpi-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DFLTK_DIR="$PWD/build/hidpi-deps/install/share/fltk" \
  -DCMAKE_PREFIX_PATH='/opt/homebrew/opt/gettext;/opt/homebrew' \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_VIEWER=ON -DBUILD_JAVA=OFF -DENABLE_NLS=ON \
  -DENABLE_GNUTLS=ON -DENABLE_NETTLE=ON \
  -DENABLE_H264=OFF -DENABLE_AUDIO=OFF
cmake --build build/hidpi-release --parallel 8
ctest --test-dir build/hidpi-release/tests/unit \
  --output-on-failure --no-tests=error
cmake --build build/hidpi-release --target dmg
```

Artifacts:

- Executable: `build/hidpi-release/vncviewer/vncviewer`
- Persistent app: `build/hidpi-release/TigerVNC.app`, staged using the app
  bundle procedure above with `build/hidpi-release` as the build directory.
- Disk image: `build/hidpi-release/release/TigerVNC-1.16.80.dmg`

All 293 unit tests passed in 13.21 seconds. The staged app passed the
eight-case `macos-scaling-smoke.py --quick` protocol/lifecycle suite. Its
plist passes validation and enables Retina support; its executable matches
the built binary and starts successfully with `--version`. Executable SHA-256:
`34443efbdf670ecc473761389243601efcdf8534f7e7bdbdb1062d3723c202fe`.
`hdiutil verify` reports a valid DMG checksum. Logs are in the build directory:
`configure.log`, `build.log`, `tests.log`, `package.log`,
`protocol-smoke.log`, and `dmg-verify.log`.

This is a local Release configuration, not a portable distribution build.
It still links Homebrew runtime libraries, targets macOS 27.0, and has not
been distribution-signed or notarized. Physical-display and interactive
validation remain open. The existing `hdiutil -volname` deprecation warning
is nonfatal; disk-image creation required access outside the sandbox.
