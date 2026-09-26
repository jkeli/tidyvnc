# Building TidyVNC on Windows

## Native Windows 11 viewer (WinUI 3)

The Windows 11 viewer is a WinUI 3 app on .NET 10 over the portable C++ core
and its C ABI (`viewer/bridge/tidyvnc.h`). Its plan, decisions and evidence are
in [plans/native-ui-winui](plans/native-ui-winui/README.md). It runs on Windows
11 only, x64 and ARM64. Windows 10 and older keep the FLTK viewer, whose MinGW
build is described in `BUILDING.txt`.

### Requirements

| Tool | Version used | Notes |
| --- | --- | --- |
| Visual Studio 2022 Build Tools | MSVC 14.44, C++ x64 tools | ARM64 builds also need *MSVC v143 C++ ARM64/ARM64EC build tools* |
| Windows SDK | 10.0.26100 | |
| .NET SDK | 10.0.1xx | |
| CMake, Ninja | 4.0, 1.13 | |
| Python | 3.13 | build, strings and packaging scripts |
| MSYS2 | CLANG64 (x64) or CLANGARM64 (ARM64) | gnutls, nettle, gmp, pixman, libjpeg-turbo, zlib and their closure (`apps/windows/deps.py` lists them) |
| vcpkg | baseline in `vcpkg.json` | GoogleTest, for `--test` only |
| WiX Toolset | 5.0.2, as a `dotnet` global tool | the `package` stage only |

NuGet package versions are pinned in `Directory.Packages.props`. The Windows
App SDK's AI, ML and Widgets components and its runtime MSIX are excluded on
purpose, so self-contained builds carry only the components the viewer uses.

### Build

```bat
python apps\windows\build.py --configuration Debug
```

This stages the MSYS2 DLLs into `build\winui\deps\<arch>` on first use
(`apps\windows\deps.py`: headers, MSVC import libraries, licence texts), then
configures and builds the core DLLs in `build\winui\<arch>-<configuration>`.
`--stages core,app` also publishes the app, the `vncviewer.exe` console
launcher and the SSH askpass helper, self-contained, into
`build\winui\app-<arch>-<configuration>`. Visual Studio or
`dotnet build -c Debug -p:Platform=x64` on `apps\windows\TidyVNC.slnx` works for
day-to-day development once the core is built.

Options: `--arch arm64`, `--configuration Release`, `--test` (build and run the
core suites, and the .NET suites with the `app` stage), `--asan`, `--build-dir`,
`--parallel`. An output directory is reused only if `build.py` created it for
the same configuration.

### Tests

- Core: `python apps\windows\build.py --test`.
- .NET services and models:
  `dotnet test --project tests\windows\TidyVNC.Native.Tests -c Debug -p:Platform=x64`.
  They use isolated state roots, test-only Credential Manager prefixes and
  disposable `HKCU\Software\TidyVNC-test-*` keys, never your own data.
- UI automation (FlaUI, Axe.Windows): `tests\windows\TidyVNC.UITests`. These
  tests take over the desktop, so they run only with `TIDYVNC_UI_TESTS=1`, and
  only when nobody has used the desktop for a minute. Some need a display that
  is switched on.
- Strings: `python apps\windows\strings.py audit` checks the generated catalog
  against the macOS catalog and the sources. `generate` rewrites
  `Strings\en-US\Resources.resw` from `Strings\windows.json`. `pseudo` writes
  the qps-ploc and qps-plocm layout-check catalogs, which only Debug builds
  include.

Environment variables for development and tests:

| Variable | Effect |
| --- | --- |
| `TIDYVNC_STATE_ROOT` | Moves every store, the registry import root and the log to an isolated folder |
| `TIDYVNC_UI_LANGUAGE` | Selects a catalog, such as `qps-ploc` or `qps-plocm` |
| `TIDYVNC_TEST_WINDOWS_BUILD` | Simulates another Windows build for the start-up check |
| `TIDYVNC_CRASH_LOG` | Appends unhandled UI exceptions to a file |

`TIDYVNC_STATE_ROOT` works only in Debug builds and in measurement builds.
Measurement builds are Release publishes for timing runs, built into their own
folder, `build\winui\app-<arch>-measurement[-trimmed|-aot]`:

```bat
python apps\windows\build.py --configuration Release --stages app --measurement [--runtime trimmed|aot]
```

The package stage refuses them. `--runtime` publishes the WinUI app trimmed or
with Native AOT, for comparison with the shipped JIT build (D1). A trimmed build
holds the app alone, because trimming rewrites framework files the launcher
shares. The measurements use `tests\perf\windows-viewer-workloads.py`: the
workloads, or `--startup N` for start-up times, with `--direct` to start
`TidyVNC.exe` itself (required for a trimmed build). Like the UI tests, they run only with `TIDYVNC_UI_TESTS=1` on an
idle desktop.

### Package

```bat
python apps\windows\build.py --configuration Release --stages package
```

The `package` stage (`apps\windows\package.py`) does the following:

1. Assembles the payload, adding the app-local Visual C++ runtime and every
   component's licence texts under `ThirdParty\`.
2. Audits the payload's PE files:
   - architectures;
   - import closure;
   - no debug runtime, MinGW runtime or FLTK;
   - no DLL that nothing loads;
   - the core's exports match `tidyvnc.h`;
   - a licence text for every binary.
3. Checks that a copy in a path with spaces and non-ASCII characters starts.
4. Builds and validates the per-user MSI.

It publishes the results to a new folder, `build\winui\release\TidyVNC-<version>-<arch>`
(or `--output`), containing:

- `TidyVNC-<version>-<arch>.msi`;
- `TidyVNC-<version>-<arch>-symbols.zip`;
- `package-report.json`.

An existing output is never replaced. Other options:

- `--no-msi` skips the installer.
- `--sign-dlib <Azure.CodeSigning.Dlib.dll> --sign-metadata <metadata.json>`
  signs through Artifact Signing, as the release workflow does (RELEASING.md).
  `--sign <thumbprint>` signs with a certificate from the certificate store
  instead. Either one signs the project's binaries, every shipped binary nobody
  else signed (the MSYS2 DLLs), and then the MSI. `--timestamp-url` overrides
  the timestamp server. Without a signing option the build is unsigned.

### Continuous integration

`.github/workflows/windows-winui.yml` runs on every push and pull request:

- the core and .NET suites in Debug;
- the unsigned Release package, uploaded as a workflow artifact that is not a
  release;
- an ARM64 cross-build of the core and app.

UI automation and desktop tests need an interactive desktop, so they run only
locally. ARM64 tests need ARM64 hardware.

### Install

The MSI installs for the current Windows user only, with no administrator
rights, into `%LOCALAPPDATA%\Programs\TidyVNC`. It needs Windows 11. It adds
the following:

- a Start menu shortcut;
- the `.tidyvnc` file type (Windows still asks which app opens it by default);
- an uninstall entry.

To put `vncviewer` on your PATH, install with `msiexec /i TidyVNC-<version>-x64.msi ADDLOCAL=Main,CommandLine`.

Upgrades install over the older version; downgrades are refused. Uninstalling
keeps your data: `%LOCALAPPDATA%\TidyVNC` and the TidyVNC entries in
Credential Manager.

Release MSIs are signed. Your own builds and CI builds are not:

- Windows SmartScreen warns about a downloaded unsigned MSI (*More info* >
  *Run anyway*). A signed MSI can also get this warning while the signing
  identity is still new.
- Smart App Control, where it is on, blocks unsigned builds.
