# Portable viewer targets

`tidyvnc_viewer_core` contains the shared desktop transform, monitor layout,
resampling, tile cache and cursor renderer. It links the existing RFB client
and transport libraries. The retained FLTK application, rendering unit tests
and scaling benchmark consume this same target instead of compiling separate
copies of the implementation.

`tidyvnc_viewer_platform` contains the initial host/service value contract:
display metrics and its validation. It has no dependency on protocol code or a
UI toolkit. The FLTK adapter obtains actual window/display values in
`vncviewer/DisplayMetrics.cxx`. Future native adapters supply the same values.
Storage, scheduling, clipboard and authentication services remain later work;
this target does not yet implement those interfaces or the session lifecycle.

Dependency direction:

```text
FLTK frontend / headless consumer
  -> tidyvnc_viewer_core
       -> tidyvnc_viewer_platform
       -> rfbclient / network -> rfb / rdr / core
```

Public includes use `<viewer/core/...>` and `<viewer/platform/...>`. Neither
target imports `vncviewer`, FLTK, AppKit, SwiftUI or WinUI. No GUI event loop is
initialized by the headless consumer. This is the build boundary for N1.1, not
a completed session engine or a stable public ABI.

## Reproduce the headless check

Install a C/C++ compiler, CMake, zlib, pixman and libjpeg-turbo. GnuTLS/nettle
are optional protocol dependencies; GoogleTest enables the full unit suite.
No FLTK or display server is needed. Then run from the repository root:

```sh
python3 tests/viewer/headless.py --build-dir build/headless
```

The directory must not already exist. The script never deletes an existing
build. Use `--cmake-arg=-DNAME=VALUE` to select dependencies/toolchains. For
example, on the development Mac with Homebrew and the existing GoogleTest:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
python3 tests/viewer/headless.py --build-dir build/headless-check \
  --cmake-arg=-GNinja \
  --cmake-arg=-DCMAKE_PREFIX_PATH=/opt/homebrew \
  --cmake-arg=-DGTest_DIR="$PWD/build/test-deps/install/lib/cmake/GTest" \
  --cmake-arg=-DENABLE_GNUTLS=ON --cmake-arg=-DENABLE_NETTLE=ON
```

The script configures with `BUILD_VIEWER=OFF`, `BUILD_PLATFORM_APPS=OFF` and
NLS/audio/H.264 disabled. It explicitly disables FLTK and X11 discovery,
checks the generated CMake dependency graph and portable headers for GUI
dependencies, builds all enabled targets, runs the independent smoke consumer,
and runs unit tests when GoogleTest is available. The smoke executable uses
the real RFB connection constructor, transport parser and rendering routines.
CI requires GoogleTest and repeats this check on Linux and macOS.

`BUILD_PLATFORM_APPS` defaults to `ON`, preserving legacy server/tool builds.
Setting it to `OFF` avoids platform application directories and their X11,
Wayland, PAM, SELinux, systemd and password-quality discovery. It does not
disable reusable `rfbserver` protocol code or protocol benchmarks. NLS-disabled
macOS core builds no longer link Carbon; retained translated builds keep the
existing bundle-localization behavior.
