# Windows native UI (WinUI 3) plan

Planning checkpoint: `6972f720`, inspected 2026-09-23. **Nothing in this folder is
implemented yet.** The plan builds on the macOS native UI work in
[`plans/native-ui`](../native-ui/PLAN.md), whose portable core, C ABI and service
contracts were designed so that a second native frontend could use them. The
entry point that work left for this plan is
[`plans/native-ui/HANDOFF.md`](../native-ui/HANDOFF.md). The macOS plan remains the
authority for those shared contracts; this folder covers only what Windows adds or
changes.

Companion documents:

| Document | Contents |
| --- | --- |
| [DECISIONS.md](DECISIONS.md) | Decisions made in this plan, with alternatives, rationale and the spike that confirms each one |
| [UX.md](UX.md) | How the app looks and behaves on Windows 11 while staying familiar to macOS users |
| [PARITY.md](PARITY.md) | Row-by-row mapping of the macOS parity inventory to WinUI, plus Windows-only rows |
| [CORE.md](CORE.md) | Building the core with MSVC, Windows platform adapters, DLL export and moving shared logic out of Swift |
| [SERVICES.md](SERVICES.md) | Windows service adapters: stores, Credential Manager, trust, files, clipboard, displays, SSH, activation |
| [DESKTOP.md](DESKTOP.md) | Rendering, DPI, cursor, keyboard/pointer/touch input and fullscreen |
| [PACKAGING.md](PACKAGING.md) | Build pipeline, self-contained deployment, MSI installer, signing and standalone install |
| [TESTING.md](TESTING.md) | Test layers, automation, acceptance logs and local validation |
| [TODO.md](TODO.md) | Tracked tasks W0–W7 and the evidence log |

## 1. Outcome, scope and decisions

Deliver a native Windows TidyVNC viewer built with WinUI 3 (Windows App SDK) on
the same portable C++ core and versioned C ABI as the macOS SwiftUI app. It must:

- **Match the macOS app's features.** Every row in the macOS
  [parity inventory](../native-ui/PARITY.md) and all 47 parameters in
  [CAPABILITIES.md](../native-ui/CAPABILITIES.md) map to a Windows implementation,
  an explicit Windows-specific equivalent, or a documented reason it cannot apply.
- **Feel familiar to someone who has used the macOS app.** The windows, their
  order of controls, dialog content, section names, defaults, safe default
  buttons and help text are the same. Windows conventions change the chrome, not
  the product: see [UX.md](UX.md).
- **Use modern Windows UI.** Fluent controls, Mica, light/dark/contrast themes,
  Segoe Fluent icons, snap layouts, per-monitor DPI, Narrator and touch.
- **Install without the Microsoft Store.** A self-contained, per-user MSI that
  needs no administrator rights and no separately installed runtime. See
  [PACKAGING.md](PACKAGING.md).
- **Run on Windows 11.** x64 and ARM64. Windows 10 and older keep the FLTK
  viewer.

Scope rules carried over from the macOS plan:

- The C++ core keeps RFB, codecs, security, transport policy and geometry. No
  protocol logic moves into C#. No transport rewrite, new encodings or TLS
  library replacement.
- The frontend uses only the C ABI (`viewer/bridge/tidyvnc.h`). No C++ types,
  exceptions or STL cross into .NET.
- The retained FLTK viewer stays the Windows default, and its MinGW build keeps
  working, until the WinUI app passes the gates in §12. Removing FLTK from the
  Windows shipping path is the last step; the FLTK source stays for Linux.
- `.tidyvnc` and legacy `.tigervnc` files, option meanings, security checks,
  client scaling and capabilities are preserved. A new look cannot silently drop
  an advanced feature or change wire behaviour.
- Owner policy recorded in the macOS [RESUME](../native-ui/RESUME.md): hosted
  GitHub CI is not enabled and nothing is pushed. Windows validation runs locally,
  on this machine and on VMs, through scripts. A CI workflow can be written but
  stays disabled.

Out of scope: Microsoft Store submission, cloud settings sync, audio (the macOS
app has none; owner decision D19), Windows 10 support (D6), code signing and an
automatic updater for now (D23, D22; both may be added later), new VNC features,
and any change to the Windows VNC server under `win/`.

Owner decisions recorded on 2026-09-23: Windows 11 only, no audio, per-user
install, unsigned builds until a signing identity is set up, no updater yet,
remote clipboard text kept out of Windows cloud clipboard sync, and approval to
install vcpkg, WiX and MSYS2 on this machine.

The headline decisions (full records, alternatives and confirming spikes are in
[DECISIONS.md](DECISIONS.md)):

| ID | Decision |
| --- | --- |
| D1 | C# on .NET 10 (LTS) with WinUI 3. A small C++ helper DLL covers the Direct3D presenter and low-level keyboard code |
| D2 | The core and C ABI are built with MSVC as `tidyvnc_viewer.dll`. The retained FLTK viewer stays on MinGW |
| D3 | Dependencies (zlib, libjpeg-turbo, pixman, nettle/GMP, GnuTLS) come from a pinned vcpkg manifest. Fallback: MinGW-built GnuTLS/nettle DLLs linked through import libraries |
| D4 | Unpackaged, self-contained Windows App SDK and .NET deployment (no runtime installers) |
| D5 | Per-user MSI built with WiX, installed to `%LOCALAPPDATA%\Programs\TidyVNC` without elevation (owner). Per-machine MSI and MSIX sideload are optional later channels |
| D6 | Windows 11 only, x64 and ARM64 (owner); the MSI refuses older Windows and points to the FLTK build |
| D7 | One UI thread owns all windows, like the macOS MainActor. Rendering runs on per-view workers |
| D8 | Shell activations (Start, Explorer file open, Jump List) go to one primary process. Command-line launches get their own process |
| D9 | `TidyVNC.exe` is the GUI. A console-subsystem `vncviewer.exe` gives terminal-correct `--help`, `--version`, errors and exit codes |
| D10 | Moving frontend-neutral policy out of Swift into the core, with conformance tests against the Swift results (§6) |
| D11–D18 | Renderer, input path, cursor, fullscreen, credentials, stores, SSH and Unix sockets: see DECISIONS.md |
| D19 | No audio (owner); H.264 off in the first release |
| D20 | Localization format |
| D21 | Remote clipboard text is excluded from Windows cloud clipboard sync (owner) |
| D22 | No automatic updater for now (owner) |
| D23 | Unsigned builds for now; the pipeline keeps a signing step for later (owner) |
| D24 | Windows App SDK 2.x, pinned at 2.5.1: 1.8 left servicing on 2026-09-09 (owner) |

## 2. Starting point

What exists (details in [CORE.md](CORE.md) and the handoff):

- **Portable core.** `viewer/core` is standard C++11 with `std::thread` and
  `steady_clock`. It already compiles under MinGW, and most unit tests run in the
  Windows CI definition. It owns sessions, the listener, prompts, frames, input,
  clipboard, shortcut classification, settings grammars, documents, rendering
  tiles, the cursor sampler and display-layout math.
- **C ABI.** 117 status-returning `tidyvnc_` exports, ABI version 1, size-tagged
  structs, fixed-width types only, never-reused handles, coalesced readiness
  callbacks on one dispatcher thread. There is no DLL export annotation; all three
  targets are static libraries.
- **Windows gaps in the core.** `viewer/platform` (socket transport, connector,
  listener, private log file) is POSIX-only. On Windows the bridge reports
  connect, routed connect, the listener and logging as unsupported.
  `c-abi-smoke.c` assumes the listener feature and would fail there.
- **Build.** `CMakeLists.txt` stops with a fatal error under MSVC and uses
  GCC-only flags. `TIDYVNC_UI` accepts `FLTK` or `SWIFTUI`.
- **Retained Windows viewer.** FLTK with scan-code keyboard handling, AltGr
  merging and a low-level keyboard hook (`vncviewer/KeyboardWin32.cxx`,
  `vncviewer/win32.c`), touch gestures (`Win32TouchHandler.cxx`), GDI drawing,
  settings and history in `HKCU\Software\TigerVNC\vncviewer` (not yet rebranded),
  TLS files in `%APPDATA%\TidyVNC`, and a TigerVNC-branded Inno Setup installer
  with no file associations or signing.
- **Swift-only logic.** Option layering and deprecated-option migrations,
  credential and route identity digests, import projections, legacy trust-file
  matching, legacy monitor numbering, store schemas and every OS adapter live in
  `platform/macos`. §6 decides which of these move to the core.
- **Local toolchain on this machine.** Visual Studio 2022 Build Tools (MSVC 14.44,
  clang-cl), Windows SDK 10.0.26100, .NET SDKs 8/9/10, CMake 4.0, Python 3.13, and
  Windows OpenSSH 9.5. No MSYS2, vcpkg, WiX or Inno Setup is installed yet; the
  owner approved installing vcpkg, WiX and MSYS2 (W0.1).

## 3. Architecture and source layout

```text
common/{rfb,network,rdr,core}/        Existing protocol foundation (shared)
viewer/core/                          Portable session engine (shared)
viewer/bridge/                        C ABI; now also builds tidyvnc_viewer.dll
viewer/platform/                      POSIX adapters (existing)
viewer/platform/windows/              NEW: Winsock transport, connector, listener, wakeup, logger
platform/windows/Native/              NEW: C++ helper DLL: D3D11 presenter, keyboard translation/hook, cursor, display topology
platform/windows/Askpass/             NEW: tidyvnc-ssh-askpass.exe (C), named-pipe SSH prompt helper
platform/windows/TidyVNC.Native/      NEW: C# library: interop, handles, delivery, models, stores, services
apps/windows/TidyVNC/                 NEW: WinUI 3 app: windows, dialogs, XAML, resources, manifest
apps/windows/TidyVNC.Cli/             NEW: console-subsystem vncviewer.exe launcher (C#, shares TidyVNC.Native)
apps/windows/Installer/               NEW: WiX MSI project
apps/windows/build.py                 NEW: CMake core -> dotnet publish -> package, like apps/macos/build.py
tests/windows/                        NEW: C# unit/model tests, UI automation, acceptance scripts
```

Dependency direction mirrors macOS: WinUI app → `TidyVNC.Native` (C#) → C ABI
(`tidyvnc_viewer.dll`) → C++ core → RFB libraries. The helper DLL
(`tidyvnc_windows.dll`) is called only by `TidyVNC.Native` and never by the core.
Only the app, the C# library and the helper contain Windows types. The core and
C ABI must still configure, build and test without WinUI, .NET or any GUI
toolkit, and `tests/viewer/headless.py` must prove that on Windows too.

`TidyVNC.Native` plays the role of the Swift `TidyVNCNative` module. It is split
by the same concerns: `Bridge/`, `Storage/`, `Settings/`, `Clipboard/`,
`Desktop/`, `Display/`, `Presentation/`, `Tunnel/`. Keeping the same folder names
and type names (`NativeSession`, `NativePreferencesStore`, …) lets someone who
knows the macOS code find the Windows equivalent quickly and lets the parity
table point at matching files.

## 4. Technology stack

| Layer | Choice | Notes |
| --- | --- | --- |
| UI framework | WinUI 3 from the Windows App SDK (the 2.x line, pinned at 2.5.1; D24) | XAML, Fluent controls, `AppWindow`, `SwapChainPanel` |
| Language/runtime | C# on .NET 10 LTS, trimmed, self-contained; Native AOT if the W0 spike passes | `LibraryImport` source-generated interop, `System.Text.Json` source generation |
| MVVM | CommunityToolkit.Mvvm | Source generators; AOT-safe |
| Settings controls | CommunityToolkit.WinUI.Controls.SettingsControls | `SettingsCard`/`SettingsExpander` for Windows 11-style settings pages |
| Win32 interop | Microsoft.Windows.CsWin32 (build-time generator) | Credential Manager, clipboard, file dialogs, monitors, power, jobs |
| Native helper | C++20, MSVC, Direct3D 11/DXGI | Presenter, keyboard translation and hook, HCURSOR creation, `QueryDisplayConfig` |
| Core | Existing C++ built with MSVC (`/std:c++17`, since MSVC has no C++11 mode) | Must stay C++11-compatible for the other toolchains |
| Tests | MSTest (including the WinUI test app for UI-thread tests), FlaUI (UIA3), Axe.Windows, CTest, Python harnesses | See TESTING.md |
| Installer | WiX Toolset (v5 or later), per-user MSI; `signtool` step ready but unused until signing is set up | See PACKAGING.md |

Third-party packages are limited to the list above, pinned, and their licence
texts are shipped (PACKAGING.md §6).

## 5. Consuming the core and C ABI from .NET

The contracts in the handoff are unchanged. On Windows they become:

- **Loading.** `tidyvnc_viewer.dll` sits next to the app. `TidyVNC.Native` calls
  `tidyvnc_get_abi` first, requires ABI version 1 and the features it needs
  (`required_features` in the runtime options), and disables a UI capability when
  its feature bit is missing instead of failing later.
- **Declarations.** One `[LibraryImport]` per export, with blittable structs that
  mirror `tidyvnc.h` exactly (`size`/`version` fields, fixed-width integers,
  `tidyvnc_bytes` spans as pointer plus `ulong`). A generator or a checked
  test keeps the C# declarations in step with the header: struct sizes and
  field offsets are compared against values the C smoke test prints.
- **Handles.** Each handle kind gets a `SafeHandle` subclass. Close is explicit and
  asynchronous: `CloseAsync` requests close, polls `*_poll_drained` without
  blocking the UI thread, then releases. A finalizer only starts nonblocking
  cleanup through a cleanup service, never a join. This is the C# form of the
  Swift `deinit` rule.
- **Callbacks.** `ready` is an `[UnmanagedCallersOnly]` cdecl function. Its context
  is a `GCHandle` to the subscription owner, pinned from `retain_context` until
  `release_context`. The callback sets a coalescing flag and calls
  `DispatcherQueue.TryEnqueue`; it never touches UI state and returns at once.
  On the UI thread the owner drains events, views, prompts and clipboard until
  `NO_CHANGE`, and rechecks subscription identity and generation
  (`NativeDelivery` equivalent).
- **Secrets.** Credential replies use unmanaged buffers that the wrapper wipes
  after the call. WinUI's `PasswordBox` only exposes a `string`, so a managed copy
  exists until garbage collection. That limit is stated, not hidden, just as the
  macOS plan does not promise zeroization of every Swift copy. See SERVICES.md §3.
- **Threads.** Commands and queries may be called from any thread. The UI thread
  issues control commands. Render workers call the tile renderer and cursor
  sampler. No call blocks on network, authentication or decoding.

ABI additions needed for Windows are small and additive (CORE.md §4): an export
macro, Windows feature availability for connect/listen/logging, Windows path rules
for CA/CRL and log files, and, if D17 picks stdio forwarding for SSH, one routed
stream transport. The ABI stays at version 1 with new feature bits.

## 6. Frontend-owned logic: extract or reimplement

The macOS app keeps several product rules in Swift. If the Windows app
reimplements them in C#, the two frontends can drift apart in ways users would
notice: a file imported differently, a setting resolved from a different layer,
a deprecated option migrated differently. The rule for this plan:

- **Move to the core** anything that is pure policy, has no OS dependency, and
  must behave identically on both platforms. Expose it through additive C
  exports and test it with vectors taken from the existing Swift tests.
- **Reimplement in C#** anything that is UI state, a draft or sheet state machine,
  or an OS adapter.
- **Do not force the Swift app to switch.** Swift keeps its implementation. A
  conformance test runs the same corpus through Swift and the core and fails on
  any difference. Moving Swift onto the core exports is a separate, optional
  macOS task.

| Logic (Swift file) | Plan |
| --- | --- |
| Layer composition, provenance and the DotWhenNoCursor / FullScreenAllMonitors migrations (`NativeOptionOverlay`, parts of `NativeDocumentResolution`, `NativeInvocationResolution`) | **Core.** A resolver over canonical parameter assignments: each layer (compiled, app defaults, profile, CLI, explicit file) is a list of (parameter, canonical value) with a source tag; the core returns effective values, sources and migration notes |
| Credential identity, route/intent and trust-scope digests (`NativeCredentialKey`, gateway digests) | **Core.** Pure functions over canonical endpoint/gateway fields; macOS values stay pinned by the existing regression vectors |
| Import projection: which parameters import, omissions, conversions, 20-entry history dedupe (`NativeDefaultsImport`, `NativeHistoryImport`) | **Core** for the projection. Source readers stay per-OS: XDG files on macOS, the registry on Windows |
| Legacy `x509_known_hosts` parsing and host matching (`NativeLegacyTrustStore`) | **Core**, read-only; Windows also needs to read the legacy files in `%APPDATA%` |
| Legacy monitor numbering (sorted by x, then y) | **Core**, over display rectangles, next to `display_layout_compute` |
| Connection-error classification from native error codes | **Core platform adapter.** Winsock and DNS errors map to the same categories macOS derives from errno |
| Export loss review for canonical parameters | **Core** for canonical fields; native-only fields (stable display IDs, profiles, gateways) stay in each frontend |
| Preferences, profile/history and trust store schemas | **C#.** Stores are per platform; the Windows schemas are documented and versioned separately (SERVICES.md §2) |
| Drafts, sheet state, clipboard coordinator, fullscreen and remote-resize coordinators, delivery, session wrappers, tunnel owner | **C#**, following the Swift structure |

This is phase W2. It runs in parallel with the Windows adapters in W1 and must
land before the settings, import and document screens in W5.

## 7. Platform services

Each service keeps the macOS contract: operation token, single completion, typed
results (`Unsupported`, `Unavailable`, `NotFound`, `Denied`, `Cancelled`,
`Invalid`, `Conflict`, `IOFailure`), no UI-thread IO. The Windows designs are in
[SERVICES.md](SERVICES.md). In summary:

| Service | Windows implementation |
| --- | --- |
| Preferences | Versioned JSON record in `%LOCALAPPDATA%\TidyVNC`, revision checks, serialized writer |
| Profiles/history | Versioned JSON with atomic replace, owner-only ACL, `LockFileEx` writer lock |
| Credentials | Windows Credential Manager generic credentials, local persistence only, opaque digest target names |
| Trust | TidyVNC trust files in `%LOCALAPPDATA%\TidyVNC\trust`; legacy `x509_known_hosts` read-only |
| Documents/files | Common Item Dialog (`IFileOpenDialog`/`IFileSaveDialog`), bounded background reads, atomic writes |
| Clipboard | `AddClipboardFormatListener`, registered remote-origin format for echo suppression |
| Displays | `QueryDisplayConfig` + `EnumDisplayMonitors`, stable opaque IDs from monitor device paths |
| Keyboard capture | `WH_KEYBOARD_LL` hook on a dedicated thread, scoped to the focused desktop |
| SSH tunnel | Windows OpenSSH `ssh.exe` in a Job Object, named-pipe askpass helper |
| Listener | Winsock listener in the core; Windows Firewall guidance, no silent rule creation |
| Activation | `AppInstance` redirection, Jump List tasks, `.tidyvnc` association, CLI launcher |
| Lifecycle | Cancellable `AppWindow.Closing`, `WM_QUERYENDSESSION`, session lock, suspend/resume |

## 8. Desktop presentation, input and displays

Summary of [DESKTOP.md](DESKTOP.md):

- **Rendering.** A `SwapChainPanel` per desktop view with a flip-model DXGI swap
  chain. The core's `FrameTileRenderer` produces scaled CPU tiles exactly as on
  macOS, so all eight scaling modes and three filters produce the same pixels.
  The helper uploads changed tiles to a persistent texture and presents with
  dirty rectangles. No GPU scaling in the first version.
- **DPI.** WinUI runs per-monitor v2. Logical units are effective pixels;
  device units are physical pixels. Windows adds fractional scales (125%, 150%,
  175%) that macOS never has, which the plan tests explicitly.
- **Keyboard.** Scan codes become QEMU key codes and keysyms come from
  `ToUnicodeEx`, reusing the retained `KeyboardWin32` logic (AltGr merging, dead
  keys, IME keys, `VK_PACKET`, the Shift-release workaround). A UI-thread message
  hook takes keys before XAML sees them while the desktop has focus, so Alt, F10,
  Tab and accelerators reach the remote computer. W0 confirms this against the
  XAML routed-event alternative.
- **Pointer and touch.** WinUI pointer events with capture, wheel and horizontal
  wheel; touch gestures mapped as the retained Windows viewer does.
- **Cursor.** The remote cursor becomes a real Windows cursor (`HCURSOR`) up to
  the size Windows supports, with the core's software cursor tiles above that.
- **Fullscreen.** One borderless window per selected monitor over a shared canvas,
  matching the macOS owned-window model, with a Windows connection bar for
  commands.

## 9. UX: modern Windows, familiar to macOS users

Summary of [UX.md](UX.md):

- The same windows: connection window (address row, toolbar, desktop, status
  bar), Settings, Saved Profiles, the two trust libraries, Listen for
  Connections, the two import windows, Help and About.
- A compact menu bar in the title bar area (File, Connection, Help), as in
  Windows 11 Notepad, holding the same commands as the macOS menus. Command
  shortcuts map ⌘ to Ctrl; ⌃⌘F becomes F11; ⌘? becomes F1. They work only when
  the desktop view does not have keyboard focus; inside it, every key goes to the
  remote computer except the viewer shortcut chord.
- macOS sheets become `ContentDialog`s. A window shows one at a time, in the same
  priority order the macOS window uses. Confirmations inside a dialog become a
  confirmation step in that dialog, because WinUI cannot stack dialogs.
- Settings uses a `NavigationView` with the macOS section names and the same
  explicit Apply / Cancel Edits / Restore Built-in Defaults footer.
- Windows sentence-case labels and Windows terms ("Remember on this PC",
  "Credential Manager", "File Explorer", "Exit") replace Mac terms, from one
  terminology table.
- Viewer shortcut modifiers default to Ctrl+Alt as in the retained viewer, with
  AltGr never treated as that chord.

## 10. Storage, credentials, trust and migration

- **No shared writers with FLTK.** The WinUI app never writes the registry keys or
  `%APPDATA%` files that the FLTK viewer uses.
- **Explicit import.** A first-use offer imports defaults and history, reviewed
  and acknowledged, from `HKCU\Software\TidyVNC\vncviewer` (after the rebrand
  moves FLTK there) or `HKCU\Software\TigerVNC\vncviewer` (the current FLTK and
  upstream TigerVNC key). Passwords, CA/CRL paths, security types, trust records
  and tunnel settings are never imported, matching the macOS policy.
- **Trust.** The legacy `x509_known_hosts` files in `%APPDATA%\TidyVNC` and
  `%APPDATA%\TigerVNC` are read-only inputs; new decisions go to the TidyVNC trust
  store. A forgotten scope suppresses the legacy fallback, as on macOS.
- **Credentials.** Credential Manager is local to the user and machine. Nothing is
  saved until authentication succeeds and the user chose "Remember on this PC".
  Same-user processes can read Credential Manager entries; SERVICES.md §3 states
  that threat model instead of implying Keychain-style per-app isolation.
- **Rollback.** Uninstalling the WinUI app leaves the FLTK viewer's data untouched;
  a user can return to FLTK at any time. The uninstaller does not delete user data
  unless the user asks.

## 11. Packaging and standalone install

Summary of [PACKAGING.md](PACKAGING.md):

- `apps/windows/build.py` runs CMake (core DLL), then `dotnet publish` for x64 and
  ARM64, then assembles and audits the payload, then builds the MSI. A signing
  step sits between audit and MSI but is skipped until a signing identity is
  configured (D23).
- The payload is self-contained: .NET runtime, Windows App SDK runtime, core DLL,
  helper DLL, dependency DLLs, the askpass helper, the CLI launcher, resources and
  licence notices. Nothing else needs installing.
- The MSI installs per user to `%LOCALAPPDATA%\Programs\TidyVNC` without
  administrator rights, refuses Windows versions older than Windows 11, adds a
  Start menu entry with the app's AppUserModelID, registers `.tidyvnc` for the
  user with consent, offers `vncviewer.exe` on the user's `PATH` as an option,
  supports upgrade and repair, and leaves user data on uninstall.
- Builds are unsigned for now, so downloads show a SmartScreen warning and Smart
  App Control, where enabled, blocks the app (DECISIONS.md D23). A dependency
  audit (the Windows counterpart of the macOS Mach-O closure check) proves a
  closed DLL graph with no FLTK, correct architecture and notices for every
  third-party binary.

## 12. Delivery phases and gates

| Phase | Work and exit evidence | Depends on |
| --- | --- | --- |
| **W0** Decisions, environment and spikes | Install the approved tools; confirm or revise the technical decisions with spikes: MSVC dependencies, input path, renderer, cursor, fullscreen, OpenSSH, Credential Manager, single instance, CLI console. FLTK Windows baseline screenshots and performance on this machine | This plan |
| **W1** Core on Windows | MSVC build of core and bridge as a DLL; Windows transport, connector, listener, wakeup and logger adapters; `headless.py`, the unit suite and C smoke pass on Windows with ASan; FLTK MinGW build still works | W0 |
| **W2** Shared policy extraction | Resolver, digests, import projection, legacy trust parsing, monitor numbering and error classification in the core, with Swift conformance tests | W0; parallel with W1 |
| **W3** .NET bridge and vertical slice | `TidyVNC.Native` handles, delivery and session/runtime/listener wrappers; a WinUI window that connects, authenticates, renders, takes input and disconnects against a loopback peer, without FLTK; measured UI responsiveness | W1 |
| **W4** Windows services | Stores, Credential Manager, trust, documents, clipboard, displays, keyboard capture, SSH, registry import, activation, lifecycle, each with contract tests | W1, W2; integrates through W3 |
| **W5** WinUI screens | Every UX.md window, dialog, menu and setting; localization catalog; accessibility | W3, W4 |
| **W6** Desktop fidelity | Scaling and DPI (including fractional), cursor, keyboard layouts/IME/AltGr, touch, multi-monitor fullscreen, performance against the FLTK Windows baseline | W3; W5 controls |
| **W7** Packaging, release gates and cutover | Reproducible build, per-user MSI install/upgrade/uninstall as a standard user, dependency audit, Windows 11 x64 and ARM64 matrix, installed Explorer/Credential Manager/firewall checks, docs, rollback, then switching the Windows 11 default from FLTK (FLTK stays available for older Windows). Signing checks stay open until D23 is revisited | W4–W6 |

The rules from the macOS plan apply. Do not build all screens against a guessed
interface before W3 proves lifecycle, cancellation and frame ownership. Record
evidence as work lands. A hardware, signing or installed-OS check that cannot be
run stays open; it is never waived. W7 completes only when every PARITY row and
contract test passes, the shipped app contains no FLTK, native stores and
credentials are verified in the installed app, and remaining differences from
macOS are stated.

## 13. Verification summary

[TESTING.md](TESTING.md) has the detail. The layers are:

- **Core and ABI on Windows:** the unit suite, `viewer-c-abi-smoke`,
  `headless.py`, MSVC AddressSanitizer, and the existing Linux TSan runs for data
  races (MSVC has no thread sanitizer).
- **C# library:** MSTest model and contract tests against real loopback peers,
  fake services for stores, and disposable Credential Manager entries.
- **UI:** FlaUI automation using the same automation IDs as macOS
  (`connection.endpoint`, `authentication.password`, …), Axe.Windows scans,
  and manual Narrator, keyboard-only, contrast-theme and 225% text-size passes.
- **Protocol:** a Windows port of the 55-case baseline driving both the FLTK and
  WinUI executables.
- **Performance:** a Windows port of the workload harness with matched FLTK and
  WinUI runs; PresentMon and ETW for present latency.
- **Installed app:** install, upgrade, repair and uninstall; Explorer open;
  Credential Manager across upgrades; firewall prompt; sleep/lock/wake; sign-out
  with pending work; Windows 11 on x64 and ARM64; refusal on older Windows.

## 14. Risks

| Risk | Mitigation |
| --- | --- |
| GnuTLS/nettle under MSVC | W0 spike with vcpkg; fallback to MinGW-built DLLs via import libraries (D3). The C ABI makes the core's compiler invisible to .NET |
| XAML keyboard handling (Alt, F10, Tab, access keys, accelerators) | W0 input spike; message-hook design keeps keys away from XAML while the desktop has focus (D12) |
| Custom cursor support in WinUI 3 | W0 cursor spike; software cursor fallback exists in the core (D13) |
| `ContentDialog` limits (one at a time, no nesting, size) | Per-window dialog queue with the macOS priority order; confirmation steps inside the dialog (UX.md §5) |
| Fractional DPI blurring the default logical scaling | Explicit 125/150/175% tests; Help explains Device units; defaults unchanged for parity |
| Windows OpenSSH lacks ControlMaster | W0 spike; stdio forwarding (`-W`) or TCP forwarding with a verified loopback owner (D17) |
| Credential Manager isolation is weaker than Keychain | Documented threat model; opaque target names; no plaintext fallback (D15) |
| Nested modal loops (file dialogs) reentering delivery | Delivery code is reentrancy-safe; quit waits for dialogs to close (SERVICES.md §4) |
| Two frontends drifting apart | Core extraction (W2), conformance tests, shared automation IDs and parity rows |
| No hosted CI | Scripted local runs with recorded evidence; ARM64 and a second Windows 11 release on VMs or separate hardware |
| Unsigned builds blocked or warned about by Windows | Documented in Help and the README; the pipeline is ready for signing; signing-dependent checks stay open (D23) |
| No audio compared with the FLTK Windows viewer | Accepted by the owner (D19); the `Audio` parameter is reported unavailable, never shown as working |

## 15. References

- [macOS plan](../native-ui/PLAN.md), [handoff](../native-ui/HANDOFF.md),
  [parity](../native-ui/PARITY.md), [capabilities](../native-ui/CAPABILITIES.md),
  [bridge README](../../viewer/bridge/README.md),
  [macOS platform README](../../platform/macos/README.md)
- [Rebrand plan](../rebrand/PLAN.md) (R5 Windows identity, registry and installer),
  [migration policy](../rebrand/MIGRATION.md), [HiDPI plan](../hidpi/PLAN.md),
  [scaling plan](../client-scaling/PLAN.md)
- Microsoft Learn: Windows App SDK deployment for unpackaged and self-contained
  apps; `SwapChainPanel` and `ISwapChainPanelNative`; `AppWindow` and presenters;
  `AppInstance` activation redirection; `CredWriteW`/`CredReadW`; `QueryDisplayConfig`;
  `AddClipboardFormatListener`; `GetAddrInfoExW`/`GetAddrInfoExCancel`; WiX Toolset
  documentation. Recheck each against the Windows App SDK and SDK versions pinned
  in W0.
