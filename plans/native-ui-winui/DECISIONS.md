# WinUI decisions

Recorded 2026-09-23. A technical decision is **proposed** until its confirming
spike or review in [TODO.md](TODO.md) passes and the evidence is logged; then it
is **accepted**, or **revised** with a note explaining what changed. Decisions
marked **owner-decided** record the project owner's choice (2026-09-23); a spike
can still be needed to prove the chosen option works, but not to choose it.

| ID | Topic | Status | Confirmed by |
| --- | --- | --- | --- |
| D1 | UI language and runtime | Accepted: self-contained JIT; Native AOT deferred (W7.8) | W0.2, W7.8 |
| D2 | Core toolchain and library form | Accepted for x64; ARM64 cross-build pending | W0.3 |
| D3 | Third-party dependency source | Revised: MSYS2 CLANG64/CLANGARM64 DLLs; vcpkg for GoogleTest only | W0.3 |
| D4 | Deployment model | Proposed | W0.9 |
| D5 | Installer technology and scope | Scope owner-decided (per-user); WiX proposed | W0.9 |
| D6 | Supported Windows versions and architectures | Owner-decided (Windows 11 only) | W7.7 |
| D7 | UI threading | Accepted | W3.2 |
| D8 | Process and instance model | Proposed | W0.10 |
| D9 | Executables and command-line console behaviour | Proposed | W0.10 |
| D10 | Moving shared policy out of Swift | Proposed | W2 review |
| D11 | Desktop renderer | Proposed | W0.5 |
| D12 | Keyboard input path | Proposed | W0.4 |
| D13 | Remote cursor | Route chosen (InputCursor from HCURSOR, software tiles above 1024 px); on-screen checks pending | W0.6 |
| D14 | Fullscreen and multi-monitor windows | Proposed | W0.7 |
| D15 | Credential storage | Proposed | W0.8 |
| D16 | Preference, profile and trust storage | Accepted | W4.1 |
| D17 | SSH gateway tunnels | Proposed; forwarding shape chosen (`ssh -W` with an app relay) | W0.11 |
| D18 | Unix-domain socket endpoints | Accepted (enabled) | W1.6 |
| D19 | H.264 and audio | Audio owner-decided (none); H.264 proposed off | W0.1 |
| D20 | Localization format | Proposed | W5.18 |
| D21 | Remote clipboard and Windows cloud clipboard | Owner-decided (excluded from cloud sync) | W4.6 |
| D22 | Updates | Owner-decided (no updater for now) | – |
| D23 | Code signing | Owner-decided (unsigned for now; signing added later) | W7.4 |

---

## D1 — C# on .NET 10 with WinUI 3, plus a small C++ helper

**Decision.** Write the app and its platform layer (`TidyVNC.Native`) in C# on
.NET 10 LTS with WinUI 3. Put the few pieces that need deterministic native
lifetime or tight Win32 message handling in a C++ helper DLL
(`platform/windows/Native`): the Direct3D 11 presenter, keyboard translation
and the low-level hook thread, HCURSOR creation and display-topology queries.
The helper exposes a small C API with the same conventions as `tidyvnc.h`.

**Alternatives.**
- *C++/WinRT for everything.* Direct calls into the C ABI and no marshalling. But
  XAML binding needs MIDL/IDL for view models, build times are long, and most new
  WinUI samples, templates and toolkit libraries target C#; C++/WinRT itself
  receives little new feature work.
- *C# for everything, with Vortice or Win2D for Direct3D.* Workable, but adds a
  large dependency and puts COM lifetime rules on the managed side.

**Rationale.** The Swift platform layer (async operations, owned handles,
MainActor delivery, typed errors) maps closely onto C# (`Task`, `SafeHandle`,
`DispatcherQueue`, records). The performance-critical work (decoding, scaling,
tile rendering) already runs in the C++ core, so the C# layer only moves
pointers and small values.

**Confirm (W0.2).** A throwaway WinUI 3 app on .NET 10 calls `tidyvnc_get_abi`
and a parser export through `LibraryImport`, receives a `ready` callback on the
dispatcher thread, and marshals it to the UI thread. Build it trimmed and with
Native AOT; record startup time, size and any trimming warnings. Adopt Native
AOT only if the full app later builds without warnings (tracked in W7).

**Final (W7.8, 2026-09-24): ship self-contained JIT; Native AOT not adopted yet.**
- The full app (TidyVNC.exe, vncviewer.exe and the askpass helper) publishes with `PublishAot=true` with
  no trimming or AOT warnings.
  - Release x64 gives a 12.9 MB native TidyVNC.exe in a 140 MB, 175-file folder, against the JIT
    payload's 186 MB and 407 files.
- A Debug AOT publish passes the 8-case quick protocol smoke and all 10 security smokes. It also passes
  12 of the 19 gated UI tests.
  - The 4 display-dependent failures are the same as with JIT, and saved profiles passed on rerun.
  - The qps-ploc and qps-plocm pseudo-locale runs failed under AOT only. After opening and closing the
    settings, profiles, listener, import and help windows, the app did not exit, and the next run hit a
    UI Automation timeout. The same test passes on the JIT build.
- Adopting AOT would need that hang found and fixed, and the full suite rerun with the display on. Until
  then the MSI ships the JIT build, which runs the same automated evidence. The `build.py` stages keep
  AOT one property away.
- Startup (W0.2, 2026-09-24; Release x64, TidyVNC.exe started directly, warm medians of 10 launches;
  time to the first frame):
  - JIT: 442 ms;
  - trimmed: 589 ms. The trimmed framework assemblies lose their ReadyToRun code, and a trimmed app
    cannot share its folder with the untrimmed launcher;
  - Native AOT: 248 ms.
  - Trimming is therefore not pursued. AOT's roughly 190 ms is the gain on offer once its hang is fixed.
- The AOT hang explained (2026-09-24):
  - It is a .NET Native AOT runtime self-deadlock. A static constructor runs inside a GC reference-tracking
    callout and allocates during the GC.
  - It happens only in unoptimized (Debug) AOT builds. Optimized builds pre-initialize that type.
  - Release AOT ran the same UI sequences without hanging.
  - It also exposed an AOT-only app bug in the `OverlappedPresenter` type tests, now fixed.
  - Release AOT now matches JIT on the automated evidence: UI suite 15/20 with the same display-dependent
    failures, protocol smoke 55/55, security smokes 10/10.
  - What remains before adopting AOT is the full suite with the display on. Debug builds stay JIT.

## D2 — Build the core with MSVC as a DLL

**Decision.** Build `tidyvnc_viewer_core`, `tidyvnc_viewer_platform` (with new
Windows adapters) and `tidyvnc_viewer_c` with MSVC (`cl`), linked into one
`tidyvnc_viewer.dll` that exports only the `tidyvnc_` C functions. The
`if(MSVC) FATAL_ERROR` in `CMakeLists.txt` becomes a rule that the *FLTK*
frontend and the Windows server still require MinGW, while `TIDYVNC_UI=WINUI`
and headless core builds require MSVC. The retained FLTK viewer keeps building
with MinGW, unchanged.

**Alternatives.** Keep MinGW (or llvm-mingw) for the core DLL and consume only
the C ABI from .NET. This is the smallest build change and is the fallback. It
costs PDB debugging, MSVC AddressSanitizer, Control Flow Guard/CET flags, a
single ARM64 cross toolchain, and it requires shipping or statically linking
libstdc++ and winpthreads inside the DLL.

**Rationale.** The handoff recommends MSVC, it is already installed here
(14.44, with ARM64 cross tools), and the WinUI helper needs MSVC anyway.

**Confirm (W0.3).** `headless.py` configures and builds the core with MSVC for
x64, and cross-compiles for ARM64, with GCC-only flags moved behind
compiler checks. Record every warning class that had to be adjusted.

**Outcome (W0.3, W1, 2026-09-23): accepted for x64.**
- MSVC builds the core, the bridge and `tidyvnc_viewer.dll`, with `/W4` and the reviewed list in
  `cmake/MSVCWarnings.cmake`, `/WX` in Debug, `/guard:cf` and `/CETCOMPAT`.
- The FLTK viewer and the server still require MinGW, and the FLTK build still passes.
- The ARM64 cross-build waits for the Visual Studio component "MSVC v143 C++ ARM64/ARM64EC build
  tools", which is not installed here. Installing it is an elevated change for the owner.

## D3 — Dependencies from a pinned vcpkg manifest

**Decision.** Get zlib, libjpeg-turbo, pixman, GMP, nettle and GnuTLS from a
`vcpkg.json` manifest with a pinned baseline, for `x64-windows` and
`arm64-windows` triplets, as DLLs (dynamic linking keeps LGPL relinking simple).

**Fallback.** If GnuTLS or nettle cannot be built reliably with MSVC for both
architectures, build those two (and GMP) with MSYS2 UCRT64 clang as DLLs,
generate import libraries, and link them from the MSVC core. Their C APIs make
that safe; record the exact MSYS2 package versions.

**Confirm (W0.3).** Both triplets build; the core's TLS and RSA-AES unit tests
pass against the result; a loopback TLS/X.509 handshake succeeds. Record
versions and licences for PACKAGING.md.

**Outcome (W0.3, 2026-09-23): revised to the fallback.**
- vcpkg's gnutls port rejects MSVC, and its ARM64 triplet needs the missing MSVC ARM64 tools.
- All C dependencies therefore come from MSYS2 CLANG64 (and CLANGARM64 for ARM64) as UCRT DLLs, with
  MSVC import libraries generated by `apps/windows/deps.py`. It also records their versions and
  licence texts.
- vcpkg supplies only GoogleTest, for the test suites.
- The TLS and RSA-AES unit tests pass, and so does a VeNCrypt X509Vnc/TLS 1.2 handshake through the
  DLL (`ViewerABI.EndToEndThroughDLL`).

## D4 — Unpackaged, self-contained deployment

**Decision.** Ship the app unpackaged, with `WindowsAppSDKSelfContained=true` and
a self-contained .NET runtime, so installing it never requires the Windows App
Runtime installer or a shared .NET runtime.

**Alternatives.** Framework-dependent unpackaged deployment (smaller, but needs
runtime installers and admin rights to service them). MSIX packaging (see D5).

**Rationale.** None of the planned features needs package identity. Credential
Manager, file associations, Jump Lists, AppUserModelID and `AppInstance`
redirection all work unpackaged. Self-contained deployment makes the install
independent of what else is on the machine.

**Confirm (W0.9).** The vertical-slice app runs from a copied folder on a clean
Windows 11 VM with no Windows App Runtime or .NET installed.

## D5 — Per-user MSI built with WiX *(owner-decided: per-user)*

**Decision.** The standalone installer is an MSI built with WiX Toolset v5 or
later that installs **per user** into `%LOCALAPPDATA%\Programs\TidyVNC`, with no
administrator rights or UAC prompt. All registrations (Start menu shortcut, file
association, uninstall entry, optional `PATH` entry) go under the current user
(`HKCU`). It has a stable `UpgradeCode`, major upgrades, repair, and leaves user
data in place on uninstall. The owner chose per-user scope on 2026-09-23; W0.9
confirms that WiX builds it cleanly.

**Consequences of per-user scope.**
- Each Windows user who wants TidyVNC installs it. Managed deployment (Intune,
  Group Policy) has to run in the user's context rather than the machine's.
- The install directory is writable by the user, so any program running as that
  user could modify TidyVNC's files. That is the same trust boundary as the
  user's own data and credentials, and the same as other per-user apps (for
  example the per-user VS Code installer), but it is weaker than a Program Files
  install. The Help text does not need to mention it; the plan records it.
- Upgrades, repair and uninstall need no elevation, which also makes an updater
  simpler if one is added later (D22).

**Alternatives.**
- *Per-machine MSI* into `%ProgramFiles%\TidyVNC` (needs elevation). A possible
  later channel for managed environments; a separate MSI is simpler than a
  dual-purpose one.
- *Inno Setup* (used today for FLTK). Simple and familiar, but an EXE installer
  lacks MSI's transactional rollback and is less convenient for Intune
  deployment.
- *MSIX sideload with an `.appinstaller` feed.* Clean install/uninstall and
  automatic updates, but installation needs a signing certificate the machine
  trusts (which D23 postpones), writes under `%LOCALAPPDATA%` are virtualized,
  launching the SSH askpass helper from `WindowsApps` needs care, and the CLI
  works only through an execution alias. Kept as an optional later channel.

**Confirm (W0.9, W7).** A prototype per-user MSI installs, upgrades, repairs and
uninstalls the vertical slice on a clean Windows 11 VM, as a standard (non-admin)
user, without a UAC prompt.

## D6 — Windows 11 only; x64 and ARM64 *(owner-decided)*

**Decision.** The WinUI app supports Windows 11 only, on x64 and ARM64. The owner
chose this on 2026-09-23. The MSI refuses to install below Windows 11 (build
22000) with a message pointing Windows 10 users to the FLTK build. The test
matrix covers the Windows 11 releases Microsoft still services for all editions
when W7 runs (today 24H2 and 25H2); older Windows 11 builds may work but are not
claimed. 32-bit x86 is not built.

**Consequences.** Windows 11 features are used without fallbacks: Mica, Segoe
Fluent Icons, rounded corners and Snap Layouts. Windows 10 and older users keep
the FLTK viewer, which is why W7.12 keeps the FLTK Windows build available after
cutover. Adding Windows 10 later would need a solid-background replacement for
Mica, icons limited to glyphs Segoe MDL2 Assets also has, and a Windows 10 VM in
the test matrix. Consumer Extended Security Updates for Windows 10 22H2 end in
October 2026, so that is not expected.

## D7 — One UI thread for all windows

**Decision.** All windows run on the app's single UI thread and
`DispatcherQueue`, like SwiftUI's MainActor. Desktop rendering runs on per-view
render workers; store and file IO run on background tasks.

**Rationale.** One owner for UI state keeps the delivery model identical to
macOS and avoids cross-window marshalling. WinUI supports several windows on one
thread.

**Confirm (W3.2).** The macOS N2.8 responsiveness measurement, repeated on
Windows: the UI thread's worst tick gap during a pending connect, a large raw
decode flood and shutdown under load.

**Outcome (W3.2, 2026-09-23): accepted.** The worst UI tick gaps were 16 ms during a pending connect,
16 ms over 60 full-frame 1080p Raw updates and 18 ms during shutdown under load.

## D8 — One primary process for shell activations; CLI launches are separate

**Decision.** Launches from the Start menu, Explorer file opens and Jump List
tasks use `AppInstance.FindOrRegisterForKey` and redirect to the running primary
process, which opens a new window, like a macOS app receiving a Finder open.
Launches through the `vncviewer.exe` command line always get their own process,
which owns its invocation and any launch credentials and does not register as
primary.

**Rationale.** macOS has one process with many windows, and users expect New
Connection, Explorer opens and the clipboard coordinator to behave that way. The
command line must not send `VNC_PASSWORD` or `PasswordFile` inputs to another
process (the macOS rule: no secrets through relaunch or IPC), so command-line
processes stay separate. Because of this, all stores must be safe with several
processes writing (SERVICES.md §2).

**Confirm (W0.10).** Prototype redirection with a file activation and two
concurrent processes; show that a command-line process neither redirects nor
receives redirected activations.

## D9 — `TidyVNC.exe` plus a console `vncviewer.exe`

**Decision.** `TidyVNC.exe` is the GUI-subsystem app. `vncviewer.exe` is a small
console-subsystem launcher. It validates the command line with the core's
invocation parser, prints `--help`, `--version` and syntax errors to the
terminal with the retained exit codes, then starts `TidyVNC.exe` with the same
arguments and working directory, lets it inherit the environment, waits for it
to exit, and returns its exit code. Ctrl+C asks the GUI process to close its
windows through a private, per-process named event.

**Alternatives.** One GUI executable that calls `AttachConsole` (output appears
after the prompt returns, exit codes are lost, and scripts cannot wait), or
`AllocConsole` as FLTK does (opens a new console window).

**Confirm (W0.10).** The macOS executable terminal cases
(`tests/macos/invocation-terminal.py`) are ported and pass through
`vncviewer.exe` in cmd.exe and PowerShell, byte-identical where the macOS suite
requires it, apart from documented platform differences such as path syntax.

## D10 — Move shared policy into the core

**Decision.** See [PLAN.md §6](PLAN.md). Pure, OS-independent product rules
(layer resolution and migrations, credential/route/trust digests, import
projection, legacy trust parsing, legacy monitor numbering, error
classification, canonical export losses) move into the core with additive C
exports. Swift keeps its implementation; conformance tests compare the two.

**Confirm (W2).** Each extracted rule reproduces the Swift results on the
existing Swift test vectors, and the conformance tests run in the macOS native
suite.

## D11 — SwapChainPanel with CPU tiles from the core

**Decision.** Each desktop view is a `SwapChainPanel` with a flip-model DXGI swap
chain created for composition. The render worker asks the core's tile renderer
for changed tiles at device resolution, copies them into a persistent texture,
copies that into the back buffer, and calls `Present1` with dirty rectangles.
The helper DLL owns all Direct3D objects.

**Alternatives.** `WriteableBitmap` (a full-frame copy through XAML on the UI
thread each update; too slow for 4K). GPU scaling with shaders (would stop
matching the core's nearest/bilinear/area pixels, so it is deferred like Metal on
macOS).

**Confirm (W0.5).** Full-frame 1080p and 4K updates at 30/s through the spike
presenter, with p50/p95 present latency and CPU compared against the FLTK GDI
path on this machine, device-lost recovery, and resize across two DPI scales.

## D12 — Keyboard: UI-thread message hook with the retained translation

**Decision.** While a desktop view has focus, a `WH_GETMESSAGE` hook on the UI
thread takes keyboard messages (`WM_KEYDOWN`, `WM_KEYUP`, `WM_SYSKEYDOWN`,
`WM_SYSKEYUP`, `WM_CHAR`, dead-char messages) addressed to that window's input
site, translates them with logic extracted from `vncviewer/KeyboardWin32.cxx`,
and replaces them with `WM_NULL` so XAML never acts on them. When the desktop
does not have focus, the hook passes everything through and normal WinUI
keyboard handling applies. The FLTK viewer already uses a thread `WH_GETMESSAGE`
hook for a related purpose.

**Alternatives.** XAML `PreviewKeyDown`/`KeyDown` with `Handled = true`, using
`KeyStatus.ScanCode` and `IsExtendedKey`. Simpler, but Alt alone, F10, access
keys, Tab navigation, `Alt+Space` and accelerators may still be processed
before or outside the routed events, and character translation has to be redone.

**Confirm (W0.4).** A checklist run on both approaches: Alt alone, F10, Tab and
Shift+Tab, Alt+Space, Alt+F4 (matching the retained viewer's behaviour),
Ctrl+N and other app accelerators, AltGr on German and French layouts, dead
keys, Japanese and Korean IME keys, the emoji panel and touch keyboard
(`VK_PACKET`), NumLock/numpad, Pause, Print Screen, key repeat, releasing one
Shift while holding the other, and release-all on focus loss.

## D13 — Real Windows cursor, software fallback

**Decision.** Show the remote cursor as a real Windows cursor built with
`CreateIconIndirect` from the core's sampled cursor image, so it moves at
hardware-cursor latency, as macOS uses `NSCursor`. Larger cursors fall back to the
core's software cursor tiles drawn by the presenter, as on macOS.

**Open question.** WinUI 3 has no public API that turns an `HCURSOR` into an
`InputCursor`, and `InputDesktopResourceCursor` only loads cursors compiled into
resources, which does not fit a cursor the server changes at run time. The spike
tries, in order: handling `WM_SETCURSOR` for the desktop view's input-site
window from the helper; any newer Windows App SDK cursor API available in the
pinned version; then software-only drawing with the system cursor hidden over
the view.

**Confirm (W0.6).** Cursor shape, hotspot and visibility follow the remote cursor
across a 100% and a 150% display with no visible flicker when moving between the
toolbar and the desktop.

**Route chosen (W6.3, 2026-09-24).** The pinned Windows App SDK has
`IInputCursorStaticsInterop.CreateFromHCursor`, so the helper's `HCURSOR` becomes an `InputCursor` and
is set as the desktop view's `ProtectedCursor`. No `WM_SETCURSOR` subclassing is needed.
- Cursors larger than 1024 pixels are drawn by the view from the core's software cursor tiles
  (DESKTOP.md section 3).
- The on-screen checks above are still open. The owner's display was off during this work.

## D14 — One borderless window per monitor for fullscreen

**Decision.** Fullscreen on the current display uses `AppWindow` with
`FullScreenPresenter`. Fullscreen across all or selected displays creates one
borderless, owned window per display, each with its own `SwapChainPanel` on the
shared canvas, matching the macOS owned-window model and keeping each monitor at
its own DPI. A slide-down connection bar at the top of the primary surface gives
the fullscreen commands (see UX.md §7). Settings dialogs open on the primary
surface without leaving fullscreen, with keyboard capture released while they
are open; macOS defers them because of Spaces, which Windows does not have.

**Alternative.** A single window spanning the union of the monitors, as FLTK
does. It is simpler but has one DPI for all monitors and breaks with mixed
scales or non-rectangular arrangements.

**Confirm (W0.7).** Enter/exit, minimize/restore, focus moving between surfaces
and topology change on two monitors at different scales; this needs physical
hardware or an equivalent VM setup, and stays open until run.

## D15 — Credential Manager generic credentials

**Decision.** "Remember on this PC" stores the password in Windows Credential
Manager as a generic credential with `CRED_PERSIST_LOCAL_MACHINE` (local to this
user on this machine; it does not roam). The target name is
`TidyVNC/credentials.v1/<digest>`, where the digest is the core's credential
identity (D10). No host or user name appears in the entry. There is no
plaintext fallback and no Windows Hello prompt, matching the macOS decision to
require no biometric.

**Threat model, stated.** Credential Manager encrypts with DPAPI, but any process
running as the same user can read generic credentials. There is no per-app
access control like the macOS Keychain's. This is the same protection the
Windows Remote Desktop client uses for saved passwords. The Help text and
SERVICES.md say so.

**Confirm (W0.8).** Create, read, replace, delete and enumerate disposable entries
from the C# layer; confirm `ERROR_NOT_FOUND` and `ERROR_NO_SUCH_LOGON_SESSION`
map to NotFound and Unavailable; confirm entries survive an app upgrade because
Credential Manager does not depend on the app's identity.

## D16 — JSON stores in `%LOCALAPPDATA%\TidyVNC`, not the registry

**Decision.** Preferences, profiles/history and trust decisions are versioned JSON
records in `%LOCALAPPDATA%\TidyVNC`, with an owner-only access-control list,
atomic replacement and a `LockFileEx` writer lock. The registry is used only for
installer-owned keys (file association, uninstall entry).

**Rationale.** The handoff notes that the registry cannot provide a revisioned
record with atomic compare-and-replace. Local (not roaming) AppData matches the
macOS "this device only" behaviour; display IDs and paths are machine-specific.
The FLTK viewer's registry keys remain an import source only.

**Outcome (W4.1, 2026-09-23): accepted.** The stores and their contract tests are in place: schema and
revision, `LockFileEx`, atomic replace, the ACL check, sharing-violation retry, and recovery from
corrupt or newer-schema files.

## D17 — Windows OpenSSH for SSH gateways

**Decision.** Use the Windows OpenSSH client (`%SystemRoot%\System32\OpenSSH\ssh.exe`,
present by default on current Windows) with explicit arguments, inside a Job
Object that kills the process tree when the owner closes. Windows OpenSSH does
not support ControlMaster, which the macOS design relies on, so the forwarding
shape changes. Preferred: `ssh -W target:port` with the RFB stream carried over
the process's standard input and output (no listening port at all). Fallback:
`ssh -L 127.0.0.1:<port>:target:port -N` with `ExitOnForwardFailure=yes`, where
the app verifies the connecting peer is the owned `ssh.exe` process before
handing the socket to the core. Password and passphrase prompts use an askpass
helper that talks to the app over a per-attempt named pipe restricted to the
current user. Host-key review follows the macOS flow.

**Confirm (W0.11).** Windows OpenSSH 9.5 on this machine: `-W` behaviour,
`SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force`, host-key prompts through askpass,
`ssh -G` for configuration capture, the Windows `ssh-agent` service, and Job
Object cleanup. If `-W` is chosen, W1 adds a routed stream transport to the core
(CORE.md §4). If `ssh.exe` is missing, the gateway field is disabled with a
message that points to Settings > System > Optional features.

**Spike outcome (2026-09-24, W0.11).** Windows OpenSSH 9.5p2 on this machine,
against an in-process SSH-2 test server:
- `-W` carries RFB over standard input and output.
- `SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force` answers password prompts
  through the helper.
- `KnownHostsCommand` reports the offered key (reason, host, type, key), and
  the new-key question accepts the computed fingerprint as the answer.
  OpenSSH then saves the key itself.
- `ssh -G` evaluates configuration without a server.
- A Job Object assigned at creation ends ssh and its askpass children.
- ssh.exe needs `%ProgramData%` in its environment (exit 255 without it).

Chosen shape: `-W`, with the app relaying ssh's standard streams to a
private AF_UNIX socket in an owner-only per-attempt directory. The socket
accepts only a connection from the app's own process
(`SIO_AF_UNIX_GETPEERPID`), and the core's existing routed connect uses it.
This keeps "no listening TCP port" without a new core transport, so W1.14 is
not needed. `-L` was not exercised.

Still open, needing the owner or a VM:
- the `ssh-agent` service, which is disabled here, and enabling it is a
  system change;
- real servers and key types beyond the test server's ECDSA host key and
  password authentication.

## D18 — Unix-domain sockets where Windows supports them

**Decision.** Every supported Windows 11 release has `AF_UNIX` sockets (added in
Windows 10 1803). Enable Unix
socket endpoints on Windows if the W1 adapter passes the same connect,
cancellation and path-classification tests as macOS; otherwise report the
capability as unavailable with a clear message. The retained Windows viewer does
not support them, so enabling them is a gain, not a parity requirement.

**Outcome (W1.6, 2026-09-23): accepted; Unix socket endpoints are enabled on Windows,** with the shared
connect, cancellation and path-classification tests. Paths are ASCII. A path with backslashes
classifies as a Unix socket on Windows.

## D19 — H.264 off; no audio *(audio owner-decided)*

**Audio (owner-decided 2026-09-23).** The WinUI app has no audio, matching the
macOS app. The `Audio` parameter and any audio control are reported as
unavailable, never shown as working. The retained FLTK Windows viewer has
`waveOut` audio, so Windows users who need remote audio lose it with the WinUI
app; the owner accepted this, and it does not block cutover. A WASAPI backend
would be a separate, later plan.

**H.264 (proposed).** Build the first Windows release with H.264 off, matching
the macOS app. The core already has a Media Foundation H.264 decoder for
Windows, so enabling it later needs only decoder and presentation acceptance, not
new code.

## D20 — `.resw` resources with keys derived from the macOS catalog

**Decision.** English strings live in `apps/windows/TidyVNC/Strings/en-US/Resources.resw`,
loaded with MRT Core (`x:Uid` in XAML, `ResourceLoader` in code). Each resource
name is the macOS catalog key with dots replaced by underscores
(`connection.endpoint.label` → `connection_endpoint_label`), plus a property
suffix for `x:Uid` use. Windows wording differs where platform terms or sentence
case require it (UX.md §9). An audit script checks that every referenced key
exists and lists macOS keys that have no Windows entry, with an allow-list for
platform-only strings. Pseudo-locales (`qps-ploc`, `qps-plocm`) test expansion
and right-to-left layout. Gettext catalogs stay with FLTK.

## D21 — Remote clipboard text stays out of cloud sync *(owner-decided)*

**Decision (2026-09-23).** Whenever the viewer puts text from the remote computer
on the Windows clipboard, it also writes the `CanUploadToCloudClipboard`
clipboard format with the value 0, so Windows never syncs remote content to the
user's other devices. Local clipboard history is left to the user's Windows
setting. Text the user copies locally and sends to the remote computer is not
marked; the rule applies only to text the viewer writes. The macOS app has no
equivalent system feature, so this is a Windows-only row (PARITY.md W13).

**Confirm (W4.6).** With clipboard history and cloud sync turned on in a test
account, remote text appears in local history but never reaches a second
device, and the format is present on every remote-origin write.

## D22 — No automatic updater for now *(owner-decided)*

**Decision (2026-09-23).** Updates are new MSIs that perform a major upgrade. No
updater service or background check is built now; the owner may add one later.
To keep that option open: the `UpgradeCode` and version scheme are stable, the
per-user install (D5) lets an updater replace the app without elevation, and
nothing in the app assumes it is the only installed version. When an updater is
added it must verify downloads by signature, so it depends on D23. A winget
manifest is another later option.

## D23 — Unsigned for now; signing added later *(owner-decided)*

**Decision (2026-09-23).** Builds are not code-signed until the owner sets up a
signing identity. The packaging pipeline still has a signing step (PACKAGING.md
§7) that is skipped unless an identity is configured, and the report records
`signed: false`, so adding signing later changes configuration, not the pipeline.

**Consequences while unsigned.**
- A downloaded MSI or EXE shows the SmartScreen "Windows protected your PC"
  warning; users must choose *More info* > *Run anyway*.
- If Smart App Control is on (it can be on for clean Windows 11 installs), it
  blocks unsigned apps without a per-app override, so TidyVNC cannot run there
  until it is signed. Help and the README say so.
- File properties and the SmartScreen prompt show no verified publisher.
- Evidence about SmartScreen, Smart App Control and upgrade behaviour of a
  signed app stays open (W7.4); unsigned runs do not stand in for it.

When signing is added, the owner chooses the Authenticode identity (for example
an Azure Artifact Signing account or an OV certificate) and where its keys live.

## D24 — Windows App SDK 2.x *(owner-decided)*

**Decision (2026-09-24).** Move from Windows App SDK 1.8 (1.8.260804001) to the 2.x line, pinned at
2.5.1, the current stable release. Later 2.x patches are taken as they ship. 3.0, the next
side-by-side release, is a new decision.

**Why.**
- 1.8 reached the end of servicing on 2026-09-09 (Microsoft's lifecycle table). Microsoft supports only
  the latest patch of a serviced version, so staying on 1.8 means no fixes and no support.
- 2.0 is the Current release, serviced until at least 2027-04-29. It has WinUI reliability fixes around
  closing windows, popups and UI Automation teardown.
- No 2.x release note mentions the title-bar handle leak measured in W6.11 (about 50 handles per closed
  window that extends into the title bar). The W6.11 leak test measures it on each version.

**Costs.**
- 2.0 changed the package layout. The ML runtime moved into `Microsoft.Windows.AI.MachineLearning`, and
  a `Search` component was added. The components the viewer does not use (AI, ML and its runtime,
  Search, Widgets, and the Runtime package's framework MSIX) are re-pinned and excluded again, and the
  payload audit and third-party notices follow the new component set.
- 2.1 changed `DISABLE_XAML_GENERATED_MAIN`: the generated `Main` is renamed, not removed. The app's own
  `Program.Main` is unaffected.
- 2.0 changed `FileSavePicker` so it no longer creates the file. The viewer uses its own Win32 file
  dialogs, so this does not apply.
- Everything checked on 1.8 is checked again on 2.5.1: builds, the native and UI suites, the smokes, the
  package stage and audit, Native AOT (D1), and the W6.11 leak tests.

**Confirm (W7.13).** Debug and Release build with no new warnings. The native suite, the gated UI suite
(its display-dependent tests still need the display on), the scaling, security, tunnel, invocation and
console smokes, the package audit and MSI build, and the W6.11 leak tests pass. The title-bar leak is
measured and recorded.
