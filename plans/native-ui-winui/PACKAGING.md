# Windows build, packaging and standalone install

Recorded 2026-09-23. Phase W7, with the build script started in W3. The macOS
counterpart is [PACKAGING.md](../native-ui/PACKAGING.md); the same principles
apply: one scripted path, a closed and audited dependency graph, licence notices
for everything shipped, exclusive publication of outputs, and no claim that a
package works until it has been installed and used.

Owner decisions that shape this document (2026-09-23): per-user install (D5),
Windows 11 only (D6), releases signed with Artifact Signing (D23, updated 2026-09-26), and
no automatic updater yet (D22).

## 1. Deliverables

| Artifact | Contents |
| --- | --- |
| `TidyVNC-<version>-x64.msi` | Per-user installer for x64 (signed for releases) |
| `TidyVNC-<version>-arm64.msi` | Per-user installer for ARM64 (not released yet; needs an ARM64 packaging host) |
| `TidyVNC-<version>-<arch>-symbols.zip` | PDBs for the app, helper and core DLLs (not installed) |
| `package-report.json` | Versions, hashes, dependency edges, signing state, notices, toolchain |

A portable ZIP (the same payload without an installer) is easy to add but is not
a release artifact until the owner asks: without the installer there is no file
association or Start menu entry, and users have to manage updates themselves.

## 2. Build pipeline

`apps/windows/build.py`, modelled on `apps/macos/build.py`:

1. **Check the environment.** MSVC toolset and Windows SDK versions, .NET SDK,
   the vcpkg baseline, WiX, and `signtool` only when signing. Missing
   tools fail with a clear message.
2. **Core.** `cmake -S . -B <build>/core -G Ninja -DTIDYVNC_UI=WINUI` with the
   vcpkg toolchain and the target architecture, build the core DLL and helper
   DLL, run `ctest` when `--test` is given.
3. **App.** `dotnet publish apps/windows/TidyVNC` with `-r win-x64` or
   `-r win-arm64`, `SelfContained=true`, `WindowsAppSDKSelfContained=true`,
   `WindowsPackageType=None`, `PublishTrimmed=true`, and `PublishAot=true` if
   DECISIONS.md D1 adopts Native AOT. The CLI launcher (`apps/windows/TidyVNC.Cli`,
   C#, sharing `TidyVNC.Native` so help text and argument handling have one
   implementation) is published into the same directory and shares the runtime
   files. The askpass helper is native C built by CMake, like the macOS one.
4. **Assemble.** Copy the published app, the native DLLs, dependency DLLs, the
   app-local Visual C++ runtime DLLs, resources and notices into a staging
   directory.
5. **Audit** (§5). Then, only when a signing identity is configured, **sign**
   (§7) and re-audit the signatures; otherwise record `signed: false` and
   continue.
6. **MSI.** Build the WiX project from the staged payload.
7. **Publish.** Rename the staging directory into a new output directory. As on
   macOS, the output directory must not exist; failure removes only the private
   staging directory.

Direct CMake users get equivalent targets (`winui-app`, `msi`), but packaging is
never part of an ordinary build. Versions come from the one CMake `VERSION`
(currently 2.0.0): assembly and file versions, the MSI `ProductVersion`, the
About window and `--version` all read it, so there is no second version source.

## 3. Installed layout

```text
%LOCALAPPDATA%\Programs\TidyVNC\
  TidyVNC.exe                 GUI app (self-contained .NET + Windows App SDK)
  vncviewer.exe               console command-line launcher
  tidyvnc-ssh-askpass.exe     SSH prompt helper
  tidyvnc_viewer.dll          core and C ABI
  tidyvnc_windows.dll         helper (presenter, keyboard, cursor, displays)
  gnutls, nettle, hogweed, gmp, pixman, jpeg, zlib DLLs
  vcruntime140.dll, vcruntime140_1.dll, msvcp140.dll   (app-local VC++ runtime)
  Microsoft.WindowsAppRuntime.*, WinRT and .NET runtime files
  resources.pri, Strings\…, Assets\…
  README.rst, LICENCE.TXT
  ThirdParty\<component>\…    licence and notice texts
```

The install directory is writable by the user, as with any per-user install.
User data stays separate, in `%LOCALAPPDATA%\TidyVNC` (SERVICES.md §2), so a
reinstall or upgrade never touches it.

## 4. Identity

| Item | Value |
| --- | --- |
| Product name | TidyVNC |
| Publisher | Set with the owner under the rebrand plan (publisher versus upstream attribution is an open R5 item) |
| AppUserModelID | `io.github.jkeli.tidyvnc` (matches the macOS bundle identifier) |
| File type | `.tidyvnc`, ProgID `TidyVNC.ConnectionFile.1`, description from the Windows catalog, icon from `media/icons/tidyvnc.ico` |
| MSI `UpgradeCode` | One GUID per architecture, generated once (2026-09-24, `apps/windows/package.py`): x64 `7B0E6C1A-3D52-4F7C-9A36-58E1C0B4D2F1`, ARM64 `C4A1F9E2-8B37-4D05-A1C6-2E9F7B3D5A48` |
| Version resources | Company, product, description, copyright and original file name for each EXE and DLL, from the rebrand ledger. No TigerVNC strings except required upstream attribution |
| App manifest | Per-monitor v2 DPI awareness, `longPathAware`, the Windows 10/11 supported-OS GUID (Windows 11 has no separate one), `asInvoker`, UTF-8 active code page |
| OS check | The MSI refuses to install below Windows 11 (build 22000) with a message pointing to the FLTK build. `TidyVNC.exe` and `vncviewer.exe` also check the build at start-up, so a copied folder on Windows 10 exits with the same message instead of failing unpredictably |
| Icons | `media/icons/tidyvnc.ico` (16–256 px) for the executables, shortcut and file type; PNG assets for the window and taskbar at 100–400% scale |

The rebrand audit (`tests/rebrand/audit.py`) covers the new Windows files. The
FLTK installer script is still TigerVNC-branded (rebrand R5); that is separate
from this plan and does not block it, but the two installers must not share
names, install directories or registry keys.

## 5. Dependency audit

The Windows counterpart of the macOS Mach-O closure check, run on the staged
payload:

- Read every PE file's import table (`dumpbin /dependents` or a Python PE reader),
  including delay-load imports, and resolve each import to a file in the payload
  or an allow-listed Windows system DLL (API sets resolve through the OS).
- Reject: an unresolved import; a DLL in the payload that nothing loads (unless
  listed as loaded dynamically, such as the core DLL loaded by .NET); an
  architecture mismatch; any FLTK import or symbol; debug CRT DLLs (`*d.dll`); a
  MinGW runtime DLL (`libstdc++`, `libgcc_s`, `libwinpthread`) unless the D3
  fallback is active and the DLL is listed.
- Record every file's hash, architecture, signing state and imports in
  `package-report.json`.
- Check that `tidyvnc_viewer.dll` exports exactly the functions declared in
  `tidyvnc.h`.
- Check that every third-party binary has a licence text under `ThirdParty\`.
  Sources: vcpkg's `share/<port>/copyright`, NuGet package licences, the Windows
  App SDK and .NET redistribution terms. Missing licence text is an error.
- Release review still has to meet each licence's obligations. GnuTLS, nettle and
  GMP are LGPL; shipping them as separate DLLs keeps them replaceable.

## 6. Launch and relocation checks

Before publication, as on macOS:

- Copy the staged payload to a path containing spaces and non-ASCII characters and
  run `vncviewer.exe --help` and `--version` there, checking output and exit codes.
  Help and version read no stores (PARITY.md L05), so this touches no user data.
- Start `TidyVNC.exe` from that copy and confirm the first window appears and
  exits cleanly (UI automation, TESTING.md). Release builds ignore the test
  state-root override, so this runs in a dedicated test Windows account or VM,
  never the owner's own account.

## 7. Signing

Releases are signed with Azure Artifact Signing (DECISIONS.md D23); every other
build is unsigned. The step is configuration only:

- `build.py --sign-dlib <Azure.CodeSigning.Dlib.dll> --sign-metadata <json>`
  signs through Artifact Signing. `--sign <thumbprint>` signs with a certificate
  from the store instead. Without either, the step is skipped and the report
  records `signed: false`.
- When enabled: sign every EXE and DLL built by the project, and every shipped
  binary nobody else signed (the MSYS2 DLLs), with the newest Windows SDK
  `signtool sign /fd SHA256 /tr <RFC 3161 timestamp URL> /td SHA256`. Microsoft's
  runtime files keep their own signatures. Verify with `signtool verify /pa /all`,
  run the payload audit again, and fail if any binary is unsigned. The MSI is
  signed last and verified the same way. The report records the method and the
  timestamp server.
- `.github/workflows/release.yml` runs this for `vX.Y.Z` tags, after CI and an
  approval on the `release` environment. A manually started run on `master` is a
  dry run that keeps only the package report (RELEASING.md).

For unsigned builds, and for signed ones while the identity is new:

- Downloaded MSIs show the SmartScreen "Windows protected your PC" warning; users
  continue with *More info* > *Run anyway*. A new signing identity starts with no
  SmartScreen reputation, so signed releases may get the warning for a while.
  That is expected and recorded, not worked around.
- Smart App Control, where turned on, blocks unsigned apps with no per-app
  override.
- The README and Help explain both. Unsigned results are never used as evidence
  for signed-app behaviour; those W7.4 checks stay open until the first signed
  release.

## 8. MSI behaviour

| Area | Behaviour |
| --- | --- |
| Scope | Per user (WiX `Scope="perUser"`), installed to `%LOCALAPPDATA%\Programs\TidyVNC`; no administrator rights or UAC prompt. Per-user MSI rules apply: components under the user profile use `HKCU` key paths and remove their folders explicitly (validation checks ICE38/ICE64). A per-machine MSI is a possible later channel (D5) |
| OS | Refuses to install below Windows 11 (§4) |
| Start menu | *TidyVNC* shortcut in the user's Start menu with the AppUserModelID; no *Listening TidyVNC* shortcut, because the Jump List has *Listen for connections* |
| File association | `.tidyvnc` registered for the user (`HKCU\Software\Classes`) with the ProgID and `OpenWithProgids`. Windows asks the user to choose the default app; the installer does not force it. `.tigervnc` is not registered |
| Command line | Optional feature (off by default): add the install directory to the user's `PATH` (`HKCU\Environment`) so `vncviewer` works in new terminals |
| Uninstall entry | Under the user's *Installed apps*, with product name, version, icon and project URL |
| Upgrades | Major upgrade on every release, no elevation; downgrades blocked with a message; settings, profiles, trust and Credential Manager entries untouched. There is no updater (D22); users install the newer MSI |
| Repair | Restores files and registry entries |
| Uninstall | Removes files, shortcuts, association and PATH entry. Leaves `%LOCALAPPDATA%\TidyVNC` and Credential Manager entries; Help explains how to remove them |
| Other users | Unaffected; each Windows user installs separately |
| Firewall | No rule created (SERVICES.md §10) |
| Coexistence | Installs beside the FLTK TidyVNC installer (`%ProgramFiles%\TigerVNC` today, per-machine) and upstream TigerVNC without conflict; distinct product names, directories, shortcuts and upgrade codes |
| Running app | Files in use trigger the standard Restart Manager prompt; the app closes its windows through the normal shutdown path when asked |

## 9. Installed-app acceptance (W7)

Recorded in TODO.md with dates, machines and build hashes. Each item needs a
real install, not a development run:

1. Clean install as a standard (non-administrator) user with no UAC prompt, first
   launch from Start, first-use import offer with a populated
   `HKCU\Software\TigerVNC\vncviewer`; a second Windows user on the same machine
   is unaffected.
2. Double-click a `.tidyvnc` file in File Explorer with the app closed, then open;
   multiple files at once.
3. Jump List tasks; pinning to the taskbar; taskbar grouping of several windows.
4. `vncviewer` from cmd.exe and PowerShell with the PATH option, including help,
   version, errors, a direct host, a file and `-listen`.
5. Remember a password, upgrade to a newer MSI, confirm the saved password is still
   used; repair; uninstall and confirm data is kept.
6. Listener behind Windows Defender Firewall: first prompt, allowed, denied.
7. Sleep, lock and wake with a connection open; sign out with a connection and a
   dialog open.
8. Windows 11 x64 and ARM64, on the Windows 11 releases still serviced when W7
   runs (D6), each at 100% and 150% scale. The installer's refusal below Windows 11
   is checked once on a Windows 10 VM, or by testing the launch condition directly
   if no VM is available.
9. Unsigned build: the SmartScreen warning and *Run anyway* path observed and
   recorded; Smart App Control behaviour recorded where it can be turned on in a
   test VM.
10. When signing is added (D23): signature verification, SmartScreen observation
    and the reputation state recorded. Open until then.

## 10. Later: updates and other channels

No updater is built now (D22). When one is wanted, the options are an in-app
update check that downloads a newer MSI and verifies its signature (so it needs
D23 signing first), a winget manifest, or the MSIX channel below. The per-user
install means none of them needs elevation.

**Optional MSIX channel.** Not part of this plan's exit. If the owner later wants
automatic updates through App Installer or Store-like install and uninstall, an
MSIX package can reuse the payload with `WindowsPackageType=MSIX`. Known work
items: a trusted signing certificate on target machines, file-system write
virtualization for
`%LOCALAPPDATA%` (disable it for the app or accept the redirected location), the
askpass helper's launch path, an execution alias for `vncviewer`, and firewall
rules declared in the manifest.
