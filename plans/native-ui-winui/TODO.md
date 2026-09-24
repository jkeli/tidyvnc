# WinUI TODO

Tracks [PLAN.md](PLAN.md). Planning checkpoint `6972f720`, 2026-09-23. Implementation started the same
day; see the evidence log for what has landed and what stays open. Task IDs are W0.x–W7.x,
parallel to the macOS N0.x–N6.x IDs in
[plans/native-ui/TODO.md](../native-ui/TODO.md).

Rules (the macOS rules, unchanged):

- Check an item only after its code and stated validation are complete. Record
  the commit, commands and results, machine, OS, toolchain and build, and the
  remaining limitations in the evidence log below.
- A hardware, signing, VM or installed-OS check that cannot be run stays
  unchecked, not waived.
- Sub-items (`  - [ ]`) are independently verifiable parts; plain `  - ` bullets
  are notes.
- Keep the FLTK Windows viewer (MinGW) building and the macOS native suite
  passing throughout. Hosted CI stays off; nothing is pushed without the owner.

## W0 — Decisions, environment and spikes

- [ ] W0.1 Record the environment and the owner decisions. Toolchain seen on
  2026-09-23: VS 2022 Build Tools (MSVC 14.44.35207, clang-cl), Windows SDK
  10.0.26100, .NET SDK 10.0.112 (also 8 and 9), CMake 4.0.3, Python 3.13.5,
  Windows 11 25H2 x64, Windows OpenSSH 9.5p2. Not installed: vcpkg, WiX, MSYS2.
  - [x] Owner approves installing vcpkg, WiX and MSYS2 (for the FLTK comparison build) on this machine. Approved 2026-09-23
  - [x] Install vcpkg, WiX and MSYS2 and record their versions
  - [x] Owner decisions, 2026-09-23: D5 per-user install; D6 Windows 11 only; D19 no audio; D21 remote clipboard text excluded from cloud sync; D22 no updater for now; D23 unsigned for now, signing added later. See the evidence log
  - [ ] Availability of a second serviced Windows 11 release in a VM, an ARM64 device or VM, a second monitor at a different scale, and a touch screen
- [ ] W0.2 D1 spike: WinUI 3 on .NET 10 calls `tidyvnc_get_abi` and a parser export through `LibraryImport`, receives a `ready` callback and marshals it to the UI thread; trimmed and Native AOT builds with startup time, size and warnings recorded.
- [ ] W0.3 D2/D3 spike: MSVC x64 build of the core via `headless.py`-style configure with vcpkg dependencies; ARM64 cross-build; GnuTLS and nettle work (TLS and RSA-AES unit tests), or the MinGW-DLL fallback is chosen and recorded.
- [ ] W0.4 D12 spike: message-hook versus routed-event keyboard path, run against the full checklist in DECISIONS.md D12; record the retained FLTK behaviour for each case first.
- [ ] W0.5 D11 spike: `SwapChainPanel` presenter with core tiles; 1080p and 4K at 30/s; p50/p95 present latency and CPU versus FLTK GDI; device-lost recovery; resize across two scales.
- [ ] W0.6 D13 spike: real `HCURSOR` over a WinUI desktop view (WM_SETCURSOR route), else software cursor; no flicker between toolbar and desktop.
- [ ] W0.7 D14 spike: per-monitor borderless surfaces and `FullScreenPresenter`; enter/exit, minimize/restore, focus, topology change. Needs two monitors; stays open until run.
- [ ] W0.8 D15 spike: Credential Manager create/read/replace/delete/enumerate with disposable targets; error mapping; survival across an app reinstall.
- [ ] W0.9 D4/D5 prototype: self-contained app runs from a copied folder on a clean Windows 11 VM; a prototype per-user MSI installs, upgrades, repairs and uninstalls it as a standard user without a UAC prompt, and refuses to install below Windows 11.
- [ ] W0.10 D8/D9 spike: `AppInstance` redirection for file and plain activations; command-line processes neither redirect nor receive redirects; `vncviewer.exe` console launcher output, exit codes and Ctrl+C in cmd.exe and PowerShell.
- [ ] W0.11 D17 spike: Windows OpenSSH `-W` and `-L` forwarding, `SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force`, host-key prompts, `ssh -G`, the `ssh-agent` service, Job Object cleanup; choose the forwarding shape.
- [ ] W0.12 FLTK Windows baseline on this machine: MinGW build of the retained viewer; window-only screenshots of the five BASELINE states at 100% and 150%, light and dark; workload measurements; notes on keyboard behaviour (Alt+F4, Alt, F10, AltGr) for W0.4.
- [ ] W0.13 Owner review of [UX.md §12](UX.md) differences and the Windows-only rows in [PARITY.md](PARITY.md).

Exit: every decision in DECISIONS.md is accepted or revised with evidence, the
owner decisions are recorded, and the FLTK baseline exists. No screen work starts
before W0.2–W0.5 are accepted.

## W1 — Core on Windows

- [x] W1.1 CMake: MSVC allowed for `TIDYVNC_UI=WINUI` and headless builds, still refused for FLTK/server targets; `WINUI` added to `cmake/ViewerFrontend.cmake`; compiler-specific flag sets; `_WIN32_WINNT=0x0A00` for WinUI only.
- [x] W1.2 `vcpkg.json` with a pinned baseline for x64 and ARM64; versions recorded (or the D3 fallback documented and scripted).
- [x] W1.3 MSVC `/W4` clean with a reviewed suppression list; `/WX` in Debug; GCC/Clang C++11 builds still clean.
- [x] W1.4 `TIDYVNC_API` export macro and `tidyvnc_viewer.dll`; export list equals the header; `headless.py` header audit accepts exactly that macro.
- [x] W1.5 Windows wakeup and established-socket transport (`WSAEventSelect`, `FD_CLOSE` peer-closure observation) with tests.
- [x] W1.6 Windows connector: cancellable `GetAddrInfoExW`, nonblocking connect, family policy, scope IDs, typed failures, with tests.
  - [x] D18: `AF_UNIX` endpoints enabled with tests, or reported unavailable with a recorded reason
- [x] W1.7 Windows listener (`SO_EXCLUSIVEADDRUSE`, `IPV6_V6ONLY`), passing the existing listener contract tests.
- [x] W1.8 Windows private log file (owner-only DACL, `LockFileEx`, rotation, reparse refusal), stdio routes in a GUI process, retained default path.
- [ ] W1.9 Bridge: Windows feature bits, Windows path rules for CA/CRL and logs (UTF-8 active code page or in-memory CA/CRL loading, CORE.md §4), native error domain, Winsock/DNS error categories.
- [x] W1.10 Tests: MSVC unit suite with justified exclusions; `c-abi-smoke` gated on the listener bit; DLL-loading C smoke; `headless.py` Windows mode.
- [x] W1.11 AddressSanitizer build of the core and unit suite.
- [ ] W1.12 FLTK MinGW build and unit run still pass; ARM64 cross-build of the core succeeds.
- [x] W1.13 End-to-end C program through the DLL: loopback connect, VncAuth, TLS, frames, disconnect, drain.
- [x] W1.14 Only if D17 selects `ssh -W`: routed stream transport with the routed-connect contract, one feature bit and one export. *(Not needed: D17 chose `-W` with an app relay into the existing routed connect over a private AF_UNIX socket; see the W4.9 evidence.)*

Exit: CORE.md §8 criteria 1–6.

## W2 — Shared policy extraction

Requires the macOS host for the Swift half of each conformance check.

- [ ] W2.1 Conformance corpus under `tests/conformance/` with a core runner in `tests/unit` and a Swift runner in the macOS native suite.
- [ ] W2.2 `ConfigurationLayers`: five-layer resolution, provenance, both deprecated migrations, dormant values; exports and conformance.
- [ ] W2.3 `IdentityDigest` with internal SHA-256 and FIPS vectors; credential, route/intent and trust-scope digests equal the pinned macOS values.
- [ ] W2.4 `ImportProjection` for defaults and history from (name, value, origin) triples; macOS XDG vectors and new Windows registry vectors.
- [ ] W2.5 `LegacyKnownHosts` parse and match; macOS vectors plus Windows path cases.
- [ ] W2.6 `LegacyMonitorNumbering`; checked against the retained FLTK numbering on Windows in W6.
- [ ] W2.7 `ExportLoss` for canonical parameters.
- [x] W2.8 Update the handoff, bridge README and PARITY references for the new exports.

Exit: CORE.md §8, W2 paragraph.

## W3 — .NET bridge and vertical slice

- [x] W3.1 Solution layout (`platform/windows/TidyVNC.Native`, `platform/windows/Native`, `apps/windows/TidyVNC`, `apps/windows/TidyVNC.Cli`, `tests/windows`); central package versions; nullable and warnings-as-errors; CsWin32 configuration; licence list started.
- [ ] W3.2 Interop: `LibraryImport` declarations, struct size/offset tests against the C smoke's values, `SafeHandle`s with asynchronous close and drain, the callback dispatcher to `DispatcherQueue`.
  - [x] D7 responsiveness: worst UI-thread tick gap during a pending connect, a raw decode flood and shutdown under load
- [x] W3.3 `NativeRuntime`, `NativeSession`, `NativeListener` with prompts, frames, input, clipboard and information; MSTest model tests against real loopback peers.
- [x] W3.4 Helper DLL skeleton with its C API: presenter, keyboard translator extracted from `KeyboardWin32.cxx` with the equivalence test harness, display queries.
- [ ] W3.5 WinUI shell: `App`, a minimal `ConnectionWindow` (address, Connect, authentication dialog, desktop view, Disconnect); FLTK not linked.
- [ ] W3.6 Vertical slice against a loopback peer: connect, authenticate, render, type, click, disconnect; close and exit during authentication; two windows at once.
- [x] W3.7 `apps/windows/build.py` first version: core and app, Debug and Release, x64.

Exit: the macOS N2 exit, on Windows: lifecycle, cancellation and frame ownership
proven through the real app before substantial screen work.

## W4 — Windows services

- [x] W4.1 Stores: preferences, profiles/history, window state; schema, revision, `LockFileEx`, atomic replace, ACL check, sharing-violation retry, corruption and newer-schema recovery (D16).
- [x] W4.2 Credentials: Credential Manager store, retention controller (use once / session / remember), replace/forget, launch credentials with Windows path rules (D15).
- [x] W4.3 Trust: TidyVNC trust stores, legacy `x509_known_hosts` adapters for both `%APPDATA%` locations, CA/CRL path handling.
- [x] W4.4 Documents: common file dialogs, bounded reads, atomic writes, launch routing; file dialog open during exit.
- [x] W4.5 Registry import sources for defaults and history, read-only, feeding the core projection.
- [x] W4.6 Clipboard adapter and coordinator: listener window, contention retry, remote-origin format, focus routing, `CanUploadToCloudClipboard = 0` on every remote-origin write (D21).
  - [ ] Manual check with cloud clipboard on: remote text appears in local history and never on a second device
- [x] W4.7 Display service: `QueryDisplayConfig` topology, stable IDs, friendly names, change notifications.
- [x] W4.8 Keyboard capture service: `WH_KEYBOARD_LL` thread, pass-through rules, release triggers, typed failures.
- [x] W4.9 SSH tunnel owner with Job Object, askpass helper over a named pipe, configuration capture, host-key review (D17).
- [x] W4.10 Activation: primary instance, Jump List, file association handling, console launcher (D8/D9).
- [x] W4.11 Lifecycle: close and exit ordering, `WM_QUERYENDSESSION`, lock and suspend, bell, logging, links.
- [x] W4.12 Service contract tests and a Windows semantics section in the handoff.

Exit: every service in SERVICES.md implemented with contract tests using isolated
roots; none of them touches real user data in tests.

## W5 — WinUI screens

Each item covers its PARITY rows, including the global acceptance list at the top
of PARITY.md. Remaining keyboard/Narrator/installed checks stay as open sub-items.

- [ ] W5.1 Connection window: address row, toolbar, gateway field, notices, empty state, status bar, pre-session pages (C01–C10, V01).
- [ ] W5.2 Authentication dialog (A01–A09).
- [ ] W5.3 Trust dialogs and the two trust libraries (T01–T08).
- [ ] W5.4 Encoding fields and live dialog (O01–O08).
- [ ] W5.5 Security fields and disconnected dialog (S01–S07).
- [ ] W5.6 Input, clipboard and shortcut fields and dialog (I01–I13, K01–K06).
- [ ] W5.7 Scaling fields and dialog (Z01–Z12).
- [ ] W5.8 Fullscreen, remote resize and connection option fields and dialogs (D01–D12).
- [ ] W5.9 Settings window with defaults versus live overrides (P01–P06, P09).
- [ ] W5.10 Profiles window (P07, P08, C10).
- [ ] W5.11 Menu bar, toolbar, desktop context menu, fullscreen connection bar; accelerator scoping (M01–M14, K07–K09).
- [ ] W5.12 Listener window and incoming connection windows (L07, L08, W12).
- [ ] W5.13 Import windows (F09–F14).
- [ ] W5.14 Document review, monitor mapping and export review (F01–F08).
- [ ] W5.15 Connection information and statistics overlay (Q01–Q04).
- [ ] W5.16 Errors, retry and alerts (E01–E06).
- [ ] W5.17 Help and About (H01–H04).
- [ ] W5.18 Localization: `.resw` catalog, key audit against the macOS catalog, pseudo-locale checks (D20).
- [ ] W5.19 Accessibility: automation IDs equal to macOS, desktop automation peer with Scroll pattern, Axe.Windows scans, Narrator, keyboard-only, contrast themes, 225% text (W16, W18).
- [ ] W5.20 Screenshot comparison with the FLTK Windows baseline and the macOS native screenshots.
- [ ] W5.21 Visual design: Mica (including its solid fallback when transparency is off), title bar and Snap Layouts, icons, themes; start-up refusal on older Windows (W08, W15).

Exit: every PARITY row has a WinUI implementation and automated evidence where
automation is possible; the remaining manual checks are listed per row.

## W6 — Desktop fidelity

- [ ] W6.1 Production presenter: damage, budgets, device loss, resize, render-worker teardown.
- [ ] W6.2 Scaling fidelity: all modes and filters at 100/125/150/175%; pixel equality with the shared renderer's golden outputs; inverse input mapping (W05).
- [ ] W6.3 Cursor: shapes, hotspots, visibility, large cursors, density changes (D13).
- [ ] W6.4 Keyboard: translator equivalence test; layout and IME matrix (W03, W04).
- [ ] W6.5 Release-all on focus loss, deactivation, capture loss, lock, suspend, disconnect, close (W06).
- [ ] W6.6 Pointer, wheel and pen (V07, W02).
- [ ] W6.7 Touch gestures (W01).
- [ ] W6.8 Fullscreen current/all/selected with the connection bar and dialogs in place (D14).
- [ ] W6.9 Physical checks: mixed-DPI monitors, hot-plug, portrait, negative origins, running inside RDP (W07). Stays open until run on hardware.
- [ ] W6.10 Performance against FLTK on the same machine (DESKTOP.md §9).
- [ ] W6.11 Stress: long reconnect, resize and attach cycles without leaks.
- [ ] W6.12 Protocol baseline port (55 cases) and security, tunnel and reconnect smokes, for FLTK and WinUI.

Exit: the macOS N5 exit on Windows, including the matched performance budget.

## W7 — Packaging, release gates and cutover

- [ ] W7.1 `build.py` complete: publish, assemble, report; x64 and ARM64; exclusive output publication.
- [ ] W7.2 Dependency audit and third-party notices (PACKAGING.md §5).
- [ ] W7.3 Per-user WiX MSI (PACKAGING.md §8), including the Windows 11 launch condition.
- [ ] W7.4 Signing (D23). Deferred by the owner: the pipeline step exists and is skipped; unsigned SmartScreen and Smart App Control behaviour is recorded. Signed-build verification stays open until an identity is set up.
- [ ] W7.5 Relocation and launch checks (PACKAGING.md §6).
- [ ] W7.6 Installed-app acceptance (PACKAGING.md §9).
- [ ] W7.7 OS and architecture matrix: serviced Windows 11 releases on x64 and ARM64; refusal on Windows 10 (D6).
- [x] W7.8 Final Native AOT decision (D1).
- [ ] W7.9 Documentation: `BUILDING.txt` Windows section, a Windows build guide beside `BUILD-MACOS.md`, Help content, handoff status.
- [ ] W7.10 Rollback: WinUI and FLTK installed side by side; uninstalling WinUI leaves FLTK and its data untouched.
- [ ] W7.11 Owner review of remaining differences (audio loss versus FLTK is already accepted, D19).
- [ ] W7.12 Cutover: the Windows 11 release ships the WinUI app; the FLTK Windows build remains available for Windows 10 and older, and buildable until the owner removes it.

Exit: PLAN.md §12 completion statement.

## Deferred beyond this plan

- MSIX channel, per-machine MSI, portable ZIP release artifact, winget manifest.
- Code signing (D23) and automatic updates (D22); both may be added later, and an
  updater needs signing first.
- Windows 10 support (D6).
- Audio backend (WASAPI) (D19).
- Enabling H.264 through Media Foundation (needs only acceptance, D19).
- GPU scaling and filtering.
- Switching the Swift app to the W2 core exports.
- Microsoft Store.

## Evidence log

Add dated entries, newest last, in the macOS format:

```text
### <IDs> — <topic> — <YYYY-MM-DD>

- IDs/commit:
- Behaviour delivered and affected interfaces:
- Tests, commands and results (run ID):
- Machine, OS, toolchain, build (Debug/Release, architecture):
- Screenshots, benchmarks, artifacts:
- Remaining limitations and unchecked dependencies:
```

### W0.1 — owner decisions — 2026-09-23

- IDs/commit: W0.1 (D5, D6, D19, D21, D22, D23); planning only, no code.
- Decisions: Windows 11 only (x64, ARM64), older Windows keeps the FLTK viewer;
  no audio; per-user MSI install; no code signing for now, to be added later; no
  automatic updater for now, may be added later; remote clipboard text stays out
  of Windows cloud clipboard sync. Installing vcpkg, WiX and MSYS2 on this machine
  is approved.
- Affected documents: DECISIONS.md, PLAN.md, UX.md, PACKAGING.md, SERVICES.md,
  PARITY.md, TESTING.md, TODO.md, README.md.
- Tests, commands and results: none (decision record).
- Remaining: tool installation and versions (W0.1), all spikes (W0.2–W0.11),
  and owner review of UX.md §12 (W0.13).

### W0.1 — tools installed — 2026-09-23

- IDs/commit: W0.1; `3231271d`.
- Installed (owner-approved): vcpkg at `C:\vcpkg`, tool 2026-07-27, baseline
  `48483a35f9e6f32572bc7c9382f14436cc7106a8` (pinned in `vcpkg.json`); MSYS2
  installer 2026-06-11 at `C:\msys64` (packages below); WiX Toolset 5.0.2 as a
  `dotnet` global tool. WiX 7.0.0 was installed first and removed: it requires
  accepting the WiX OSMF EULA (`wix eula accept`), which needs the owner. The
  plan allows "v5 or later".
- MSYS2 packages (x64 and ARM64 C dependencies, D3 revised): CLANG64 and
  CLANGARM64 gnutls 3.8.13-3, nettle 4.0-1, gmp 6.3.0-2, libtasn1 4.21.0-1,
  libidn2 2.3.8-4, libunistring 1.4.2-1, p11-kit 0.26.5-1, brotli 1.2.0-1,
  zstd 1.5.7-2, libiconv 1.19-1, gettext-runtime 1.0-1, pixman 0.46.4-3,
  libjpeg-turbo 3.2.0-1; MINGW64 gcc 16.2.0-4 and friends for the FLTK
  comparison build; CLANG64 clang/lld 22.1.8 (tried for ARM64, see W0.3).
- Toolchain: VS 2022 Build Tools MSVC 14.44.35207 (x64 host and target only:
  no ARM64 cross compiler and no ARM64 C runtime libraries are installed),
  Windows SDK 10.0.26100 (includes ARM64 libraries), .NET SDK 10.0.112,
  CMake 4.0.3, Ninja 1.13.1, Python 3.13.5.
- Remaining: second Windows 11 release VM, ARM64 hardware/VM, second monitor at
  another scale and touch screen availability (unknown; owner). WSL Ubuntu is
  present but has no compiler and needs a sudo password, so Linux runs of the
  shared code stay open.

### W0.3, W1.1–W1.13 — core on Windows with MSVC — 2026-09-23

- IDs/commits: `3231271d`, `93217115`, `1c3a4ba5`, `4c0b741b`, `29e09cdb`,
  `0e260c82`, `0a500cfa`, `de0d9cab`.
- Behaviour: MSVC (C++17, `/W4` with the reviewed list in
  `cmake/MSVCWarnings.cmake`, `/WX` in Debug, `/guard:cf`, `/CETCOMPAT`) builds
  the core, bridge, `tidyvnc_viewer.dll` (117 + 1 `TIDYVNC_API` exports) and
  tests; FLTK and the server still require MinGW. `common/compat/msvc` gives
  POSIX spellings to shared sources. New Windows adapters in
  `viewer/platform/windows`: WSAPoll + loopback-UDP wake transport with
  `FD_CLOSE` peer observation (event-based write waits were rejected:
  `FD_WRITE` is only re-posted after a failed send, which the select-guarded
  `FdOutStream` never makes), `GetAddrInfoExW` connector with abandon-on-cancel
  completion, AF_UNIX (ASCII paths; backslash paths classify as Unix sockets
  on Windows), `SO_EXCLUSIVEADDRUSE` listener, private log file (protected
  user+SYSTEM DACL, `LockFileEx` sidecar, `.bak` rotation, reparse/hard-link/
  foreign-owner refusal, sticky-directory rule), GUI-safe stdio routes. New
  export `tidyvnc_native_error_category` (feature bit 1<<47).
- D3 revised: vcpkg's gnutls port rejects MSVC and vcpkg's ARM64 triplet needs
  the missing MSVC ARM64 tools, so all C dependencies come from MSYS2
  CLANG64/CLANGARM64 as UCRT DLLs with MSVC import libraries
  (`apps/windows/deps.py`); vcpkg supplies only GoogleTest.
- Tests (this machine): `python apps/windows/build.py --test` → viewer 7/7 and
  unit 705/705 (MSVC x64 Debug, run 3 times; RelWithDebInfo 657/657 before the
  last additions); `ENABLE_ASAN` RelWithDebInfo 657/657 + 6/6;
  `python tests/viewer/headless.py --build-dir build/winui/headless-x64`
  passes the Windows audit and suites; `ViewerABI.EndToEndThroughDLL`
  (VncAuth and VeNCrypt X509Vnc/TLS 1.2 through the DLL only); the Windows
  adapter suites repeat 15× clean; `utf8paths` proves non-ASCII and `\\?\` CA
  paths through GnuTLS under the app's UTF-8 manifest (the W1.9 choice).
- Retained FLTK (W1.12, MinGW64 GCC 16.2, Debug, FLTK 1.4.5): builds
  `vncviewer.exe`; unit 643/647 (655/659 after W2). The 4 failures (DocumentABI allocation
  injection and three GDI `Surface` timeouts) also fail at the planning
  checkpoint `6972f720` built the same way, which additionally needed two
  fixes now committed (missing `<windows.h>` in `Fl_Suggestion_Input.cxx`,
  unused parameter in the bridge).
- Machine: Windows 11 Pro 25H2 (10.0.26200) x64, this workstation.
- Remaining: ARM64 cross-build (W0.3, W1.12) needs the Visual Studio component
  "MSVC v143 C++ ARM64/ARM64EC build tools" (elevated installer change, owner);
  long-path CA/CRL tests need `LongPathsEnabled=1` (0 here; system setting,
  owner) so W1.9 stays open; Linux/macOS reruns of the shared-code changes
  (Endpoint path separators, header macro, test fixtures) have not been run;
  W1.14 waits for D17. MSVC Debug skips allocation-injection cases (debug
  iterators allocate inside noexcept moves); Release runs them.

### W3.2/W3.3 (partial) — TidyVNC.Native bridge — 2026-09-23

- IDs/commit: `5b0132c6`.
- Behaviour: `platform/windows/TidyVNC.Native` (C#, .NET 10, AOT/trim
  compatible): generated `LibraryImport` interop for all 118 exports and 63
  structs (`Bridge/generate-interop.py`), SafeHandle ownership, coalesced
  `UnmanagedCallersOnly` readiness delivery onto one UI dispatcher,
  NativeRuntime/Session/Listener and the other Swift Bridge types.
- Tests: `dotnet test --project tests/windows/TidyVNC.Native.Tests` 13/13 —
  layouts equal the C compiler's for all 63 structs, every export resolves,
  loopback VncAuth session/frame/disconnect/drain, wrong password, cancel,
  close during authentication, two sessions, bell, remote clipboard, reverse
  connection through the listener. D7: worst UI tick gap 16 ms (pending
  connect), 16 ms (60 full-frame 1080p Raw updates), 18 ms (shutdown under
  load).
- Remaining: the WinUI DispatcherQueue adapter (W3.5), input commands and
  Native AOT/trim measurements (W0.2) with the app.

### W3.1, W3.3, W3.4, W3.7 and parts of W3.2/W3.5/W3.6 — helper DLL, renderer, app shell — 2026-09-23

- IDs/commits: `135fdaf4`, `d81528e7`, `3ad8db6b`, `ccbd6077`.
- Behaviour: `platform/windows/Native` builds `tidyvnc_windows.dll`
  (`tidyvnc_windows.h`): Direct3D 11 composition swap chain presenter for
  `SwapChainPanel` (persistent BGRA frame texture, dirty-rect presents,
  readback), the keyboard translator extracted from `KeyboardWin32.cxx` with
  an explicit AltGr timer, the UI-thread `WH_GETMESSAGE` hook, the
  `win32.c` low-level capture, HCURSOR creation and `QueryDisplayConfig`
  topology with SHA-256 display IDs. `TidyVNC.Native` gains the helper interop,
  `NativeGeometry`, `DesktopRenderer` (per-view render thread, core tiles,
  damage-limited uploads, merged skipped-frame damage, device-loss recovery),
  `NativeInvocation`/`NativeInvocationTerminal` and CsWin32. The WinUI app
  (`apps/windows/TidyVNC`) has `App`, `ConnectionWindow`, `DesktopView`,
  `KeyboardRouter` and the `DispatcherQueue` adapter; `vncviewer.exe`
  (`apps/windows/TidyVNC.Cli`) implements D9's terminal and launch paths;
  `apps/windows/TidyVNC.slnx`; `apps/windows/ThirdParty/README.md` starts the
  licence list; `build.py --stages core,app` publishes both executables.
- Fixes found on the way: sessions and listeners were reachable from their
  core deliveries only weakly, so a session awaited only by its own pending
  connect could be garbage-collected mid-connect (now rooted while active;
  `PendingConnectKeepsItsSessionAliveThroughCollection`); the Windows default
  log path escaped the ABI guard and swallowed allocation failures.
- Tests (this machine): `build.py --stages core,app --test` Debug and Release:
  viewer 7/7, unit 722/722 (includes `keyboardtranslator` 10 — the retained
  translator and the extracted one over scripted and 16,000 random messages on
  US/German/Japanese/Korean layouts, mutation-checked — and `windowshelper` 7),
  `TidyVNC.Native.Tests` 20/20 (presenter readback, renderer letterbox, scale
  change and update flood, key/pointer bytes at a peer, GC regression).
  Renderer on the Debug core: 30 full 1080p updates in 196 ms at 1x (worst
  frame 17 ms); 91 ms worst frame at 1.5x bilinear. `vncviewer.exe`: version
  exit 0, help exit 1, syntax errors `vncviewer: Argument N: ...` exit 1.
- W0.2 (partial): `dotnet publish` Release x64 self-contained — untrimmed
  231 MB; trimmed 137 MB with 2 IL2104 warnings (Microsoft.Windows.SDK.NET,
  WinRT.Runtime); Native AOT 147 MB, 6.0 MB native `TidyVNC.exe`, 0 warnings
  (the ILCompiler needs the VS Installer directory on PATH for `vswhere`).
  40 MB of the payload is `onnxruntime.dll`/`DirectML.dll` from the Windows
  App SDK metapackage's AI components, to be excluded in W7.1.
- Not yet run: the WinUI app on screen. The FlaUI vertical-slice suite
  (`tests/windows/TidyVNC.UITests`: connect/authenticate/render/type/click/
  disconnect, close during authentication, two windows) takes the foreground
  and injects input, so it runs only with `TIDYVNC_UI_TESTS=1` on an idle
  desktop; the owner was using this machine, so W3.2 (DispatcherQueue path),
  W3.5, W3.6 and W0.2 startup timing stay open until it runs.

### W2.1-W2.8 (core half) — shared policy in the core — 2026-09-23

- IDs/commits: `0d7f4bac`, `cc455246`, `f1aac6f9`, `028ad657`, `1fa4ba64`.
- Behaviour: new core modules with additive exports and feature bits 1<<48..1<<53:
  `IdentityDigest` (credential, trust-scope, SSH route/resolved/intent digests
  over an internal FIPS 180-4 SHA-256), `LegacyKnownHosts` (read-only g0/c0
  lookup), `LegacyMonitorNumbering` (x-then-y, ambiguous origins refused),
  `ExportLoss` (losses and parameter catalog), `ImportProjection` (defaults and
  history from files or registry values) and `ConfigurationLayers`
  (five-layer precedence, migrations, provenance, dormant values), each with
  a C# wrapper in `TidyVNC.Native`. `canonicalParameter` is now shared by the
  command line and the resolver.
- Conformance: `tests/conformance/{identity-digest,legacy-known-hosts,
  legacy-monitor-numbering,export-loss,import-projection,configuration-layers}.json`
  (about 160 cases) carry the macOS test cases and pinned goldens; expected
  digests were computed independently in Python from the documented
  encoding, which also reproduces all six pinned macOS values. They run in
  `tests/unit` through the C ABI and in `TidyVNC.Native.Tests` through .NET.
  The known-hosts lookup is also checked against files GnuTLS itself writes.
- Tests (this machine): `build.py --test` Debug and Release: viewer 7/7, unit
  735/735; `headless.py --build-dir build/winui/headless-x64-w2` clean
  (718/718, header and dependency audits); `TidyVNC.Native.Tests` 26/26.
- Open: the Swift half of each conformance check (W2.1-W2.7 stay open until the
  macOS native suite runs the same corpus on a macOS host); the Linux/macOS
  builds of the new shared sources have not been run here. The seven reserved
  feature bits (47-53) are now used, so W1.14, if D17 selects `ssh -W`, takes
  bit 54.

### W4.1 — stores — 2026-09-23

- Behaviour: `platform/windows/TidyVNC.Native/Storage`.
  - `NativeRecordStore<T>` provides schema and revision records, strict decoding
    (`Corrupt` / `UnsupportedFields` / `FutureSchema` / `TooLarge`), and
    `Conflict` on a stale revision. Explicit `ReplaceCorruptAsync` never
    replaces a valid record or a newer schema.
  - Work is serialized off the UI thread, with typed `Cancelled` and `Closed`
    results.
  - `NativePrivateFiles` handles the on-disk rules:
    - a protected user+SYSTEM DACL on create;
    - owner, allow-ACE and reparse checks on every open;
    - a `LockFileEx` writer lock on `<record>.lock`;
    - write-through temp file + `Flush(true)` + `ReplaceFileW`/move;
    - bounded retry on sharing, lock and replace errors, then `IOFailure`;
    - removal of crash leftovers.
  - The three records are `preferences.json`, `profiles-history.json` and
    `window-state.json`, with schemas in `Storage/README.md`.
  - Settings are canonical parameter maps validated by the core resolver
    (W2.2) against an allow-list, plus stable display IDs for fullscreen.
    Profiles carry the canonical SSH gateway (`NativeSshGateway`) and a
    credential reference only.
  - `NativeStateRoot` resolves `%LOCALAPPDATA%\TidyVNC`, with
    `TIDYVNC_STATE_ROOT` honoured in Debug only.
  - Records use `JsonDocument` / `Utf8JsonWriter` rather than source-generated
    serializers. This is equally AOT-safe and keeps the strict unknown-field
    rules.
- Tests: `TidyVNC.Native.Tests` `StorageTests`, 16 cases, each in a private
  temp root:
  - round trip, revisions and conflicts;
  - canonical and allow-listed settings;
  - ten strict-decoding cases, where a failed commit leaves the file untouched;
  - recovery and the future-schema guard; too large;
  - a foreign allow ACE and a shared parent directory are `Denied`, while deny
    ACEs are accepted;
  - a junction with a private DACL is refused;
  - 4 writers × 15 increments across separate lock handles lose no updates;
  - a held lock times out as `Unavailable`;
  - an exclusive "scanner" handle held for 150 ms is ridden out by both read
    and replace, and a permanent one gives `IOFailure`;
  - crash leftovers removed, and only this record's;
  - closed and cancelled stores; profiles/history capacity and invariants;
    window state; the Debug state-root override.

  Result: 3 consecutive clean runs; full suite 42/42. Mutation-checked: removing
  the reparse check, the allow-ACE check, leftover cleanup, the lock, the
  revision compare, the future-schema guard or the canonical-value check each
  fails the suite.
- Retained FLTK rerun after W2 (MinGW Debug): builds; unit 655/659, with the same
  4 known failures as the planning checkpoint (see W1.12 above).

### W4.2 — credentials — 2026-09-23

- Behaviour: `platform/windows/TidyVNC.Native/Credentials`.
  - `NativeCredentialManagerBacking`: Credential Manager generic credentials
    through CsWin32 (`CredReadW/WriteW/DeleteW/EnumerateW`).
    - Entry shape: target `TidyVNC/credentials.v1/<core credential digest>`,
      `CRED_PERSIST_LOCAL_MACHINE`, empty user name, UTF-8 blob of at most
      2560 bytes, fixed comment.
    - Result mapping as in SERVICES.md section 3. Create refuses an existing
      entry (`Duplicate`); replace needs the explicit mode.
  - `NativeCredentialStore`: one worker at a time, at most 16 pending
    callers, cancellation before admission only, and a close that drains.
  - `NativeCredentialSecret`: pinned and clearable. `NativeCredentialKey`
    wraps the W2.3 identity digest.
  - `NativeAuthenticationCredentials` ports the macOS retention controller:
    - use once / session / remember / replace;
    - saves only after `Connected` for the submitting generation;
    - a rejected saved password gives a notice and is never deleted;
    - explicit use-saved and forget-saved;
    - reverse windows have no store;
    - launch environment first, then a retained session password ahead of a
      password file, then the password file for password-only prompts;
    - endpoint and route changes revoke launch inputs.
  - `NativeLaunchCredentialInputs` / `NativePasswordFileReader`:
    - VNC_USERNAME / VNC_PASSWORD are captured once and removed from the
      process environment block before anything can fail, so child processes
      never inherit them. The app captures them in `OnLaunched`.
    - PasswordFile follows Windows path rules: drive and UNC paths as given;
      relative paths join the launch directory; `C:x` and `\x` are refused;
      no expansion.
    - The file reader opens without following reparse points, accepts disk
      files only, reads 8 bytes, and checks before/after identity.
- Tests: `TidyVNC.Native.Tests` `CredentialTests`, 15 cases.
  - Real Credential Manager entries under a disposable
    `TidyVNC-test-<guid>` prefix: create, read, duplicate, replace, list and
    paging, oversize, delete, NotFound, and the raw `CREDENTIALW` fields
    (type, persistence, comment, user name). All entries are removed
    afterwards.
  - Result mapping, keys, secrets, store admission (Busy, Cancelled,
    Closed, drain), PasswordFile selection and environment capture.
  - Password files: regular file, short file, missing, relative path,
    directory, junction, named pipe, `\\.\NUL`, cancelled.
  - Seven controller scenarios end to end against a VncAuth
    `RfbTestServer`.

  Result: 3 consecutive clean runs. Mutation-checked, 14 mutations, all fail
  the suite: save gating, rejection notice, replace mode, launch revocation,
  input wiping, use-once clearing, session drop on a new destination, the
  Busy limit, the close/cancel admission, the duplicate check, environment
  clearing, root-relative paths, and the disk-file check.
- Open: ERROR_NO_SUCH_LOGON_SESSION → Unavailable is covered only by the
  mapping test; running a real `runas /netonly` session is left for the VM
  pass (W7). Entries surviving an app upgrade follows from Credential Manager
  not depending on app identity; the check is part of the W7 installer
  upgrade test.
- Not in W4.2: the authentication dialog wiring (W5) consumes this
  controller; the app currently holds the captured launch inputs for it.
- Environment note: `DesktopTests.KeyboardDisplaysAndCursorsThroughTheBridge`
  fails while the monitors are in power save (QueryDisplayConfig returns
  E_INVALIDARG). W4.7 turns that into a typed Unavailable result.

### W4.3 — trust — 2026-09-23

- Behaviour: `platform/windows/TidyVNC.Native/Trust`.
  - `NativeTrustStore`: `trust\certificates.json` (SPKI) and
    `trust\server-keys.json` (RSA-AES keys) on the W4.1 record store, with the
    macOS rules:
    - destination scopes come from the core trust identity and are rederived
      on load;
    - accept/forget decisions, capacity 256;
    - a save needs a core-overridable status and an explicit replace flag
      that agrees with the record;
    - revision conflicts;
    - server keys are validated by the core.
  - `NativeLegacyTrustFiles`: read-only lookup in
    `%APPDATA%\TidyVNC\x509_known_hosts` and
    `%APPDATA%\TigerVNC\x509_known_hosts` through the core parser.
    - A match in either file is a match.
    - Files are opened without following reparse points and must be regular
      single-link disk files that no principal other than the user, SYSTEM
      and Administrators can modify.
    - Reads are bounded (1 MiB), with a before/after identity check.
  - `NativeCertificateTrust` ports the macOS controller. A saved match
    answers the prompt; a forgotten or changed entry stops there (no legacy
    revival); with no entry, a legacy match answers. It also covers Connect
    once, the confirmed save/replace and connect, forget, reload, and a
    Cancel that suspends checking.
  - `NativeTrustLibrary` is the library window model (reload, forget,
    forget destination; a stale view is a conflict).
  - `NativeTrustFiles` holds the CA/CRL paths:
    - fully qualified Windows paths only; empty selects no file; null
      inherits;
    - paths in connection files resolve against the file's folder, and `C:x`
      or `\x` are refused;
    - no implicit `%APPDATA%\TidyVNC\x509_ca.pem`.
- Tests: `TidyVNC.Native.Tests` `TrustTests`, 10 cases.
  - Store scope, revision and override rules, server keys, and revalidation
    of edited records and capacity.
  - Legacy files: combining, read-only use, format and corrupt errors, a
    shared ACL, hard links and directories.
  - CA/CRL path rules.
  - Five controller scenarios end to end against `TlsPeer`, a new .NET
    VeNCrypt X509None peer with a self-signed certificate, so the core's
    GnuTLS verification really fails and prompts. The scenarios cover:
    - save, then reconnect answered by the saved decision;
    - Connect once with nothing written, and Cancel;
    - a legacy match, and a forget that suppresses it;
    - a changed key replaced only on request;
    - the library.

  Result: 3 consecutive clean runs. Mutations:
  11 mutations. 10 fail the suite:
  - saved decisions suppress legacy lookups;
  - a saved match answers the prompt;
  - a legacy match answers the prompt;
  - the override policy gate;
  - the replace flag;
  - scope rederivation;
  - match in any legacy file;
  - the ACL check;
  - the single-link check;
  - relative CA/CRL refusal.
  
  One equivalent survivor: removing Mutate's early revision check changes
  nothing, because CommitAsync checks the same revision under the writer lock.
- Not in W4.3: the trust dialog and the two library windows (W5) bind these
  models.

### W4.4, W4.5 — documents and registry import — 2026-09-23

- Behaviour:
  - `Bridge/NativeConnectionDocument.cs`: the shared connection-file codec
    through the C ABI. Parse, decoded values, validated options, and
    canonical serialization; invalid UTF-8 is rejected, never replaced.
  - `Documents/NativeDocumentFiles.cs`:
    - Bounded reads: a regular disk file only, opened without following
      reparse points, 1 MiB maximum, with a before/after identity check.
    - Atomic saves:
      - `.tidyvnc` in an existing, non-redirected folder;
      - an existing destination must be a writable single-link regular file;
      - a per-folder named-mutex writer lock (`Busy`);
      - the file and folder identity are rechecked before and immediately
        after writing a write-through, flushed temporary file;
      - `ReplaceFileW`, or a no-replace `MoveFileExW` for a new file;
      - a failure after the replace is `CommittedUncertain`, never reported
        as the old file surviving.
    - `NativeDocumentLaunchRouter`: bounded, validated batches, queued
      until the window action is installed, with a new ID for every open.
  - `Documents/NativeFileDialogs.cs`: the Common Item Dialog through
    CsWin32 COM. It uses the owner HWND and gives plain file-system paths,
    an OK label (Review), overwrite prompt, the `.tidyvnc` default
    extension and filters. `CancelActive` closes an open dialog as
    cancelled, for exit and session end during a dialog.
  - `Storage/NativeRegistryImport.cs` (W4.5): read-only sources under
    `HKCU\Software\{TidyVNC,TigerVNC}\vncviewer`.
    - Values are read as parameters.cxx writes them: DWORDs as signed
      integers; strings decoded with the exact `decodeValue` escape rules,
      up to 255 bytes. The core document line limit (254) is too small for
      registry values, so the decoder is mirrored rather than routed through
      a synthetic document.
    - History is read as `"0".."n"` until the first gap.
    - Everything goes through the core import projection, which excludes
      passwords, CA/CRL, security types and tunnels.
    - Unrepresentable values are listed, never imported; nothing is written.
- Tests:
  - `DocumentTests`, 7 cases: codec, reads, saves, invalid destinations
    (extension, relative path, missing folder, folder named `.tidyvnc`, hard
    link, junction, read-only), races injected between write and replace,
    failures before and after commit, folder lock contention, launch
    routing.
  - `RegistryImportTests`, 5 cases, on disposable
    `HKCU\Software\TidyVNC-test-*` keys: decoding, discovery of both
    sources, projection with exclusions and skipped values, history order
    and gap, and no writes.
  - `FileDialogTests` shows real dialogs, so it is gated like the UI suite:
    a timer inside the dialog's modal loop checks that a second dialog is
    refused and then closes the open one as cancelled.

  Mutations:
  11 mutations, all fail the suite:
  - the pre-replace recheck;
  - the single-link check;
  - overwrite confirmation;
  - the folder lock;
  - destination ownership;
  - the committed-uncertain report;
  - the read size bound;
  - the special-file check;
  - the router batch bound;
  - the history gap;
  - the escape decoder.
  
  The gated dialog test passed on this machine while the desktop was idle.
  The first attempt showed that IFileDialog::Close is ignored outside dialog
  event callbacks, so CancelActive also posts IDCANCEL to the dialog window.
  Full native suite: 78 passed, 1 skipped (gated), 1 environmental failure
  (displays in power save, see W4.2).
- Open (W5): the document review, export review and monitor mapping screens
  (W5.14) use these services; the gated dialog test runs with the UI suite.

### W4.6 — clipboard — 2026-09-23

- Behaviour: `platform/windows/TidyVNC.Native/Clipboard`.
  - `NativeWindowsClipboard` owns the clipboard on one worker thread with a
    message-only window.
    - `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE` replace polling;
      `GetClipboardSequenceNumber` gives the change numbers.
    - `OpenClipboard` is retried briefly, then reported as `Unavailable`.
    - Only `CF_UNICODETEXT`, bounded and without NUL.
    - Remote writes add `TidyVNC.RemoteOrigin` (process, session,
      generation) and `CanUploadToCloudClipboard` = 0 in the same
      transaction. If either marker cannot be set, the clipboard is emptied
      and the write reported, never left unmarked.
    - Text carrying this process's marker reads as remote and is never
      offered back.
    - Deviation from SERVICES.md, which puts the listener window on the UI
      thread: it lives on the clipboard thread, like the macOS serial
      worker, so contention retries never block the UI thread.
  - `NativeClipboardCoordinator` ports the macOS coordinator, driven by
    change events:
    - text goes only to the single focused, connected, non-view-only desktop
      in the active app; ambiguous focus routes nothing;
    - send and receive policy;
    - a change made while unfocused is sent when focus returns;
    - one operation owns all clipboard access; routing changes invalidate
      pending work;
    - typed notices per connection.
  - Two races found by the tests and fixed:
    - Frame and counter updates of `Snapshot` were treated as routing
      changes. Only state transitions route now.
    - A cancelled operation that had not started yet could run newly queued
      remote text with its cancelled token.
    - Also, remote text arriving just before a queued focus reconciliation
      now settles routing first rather than being dropped.
  - The app creates one clipboard and coordinator, registers each window's
    session, and reports app activation from window activation.
- Tests: `TidyVNC.Native.Tests` `ClipboardTests`.
  - Four coordinator scenarios with real sessions against `LoopbackPeer`
    and a scripted clipboard:
    - focus routing: unfocused, refocus, ambiguous, inactive app;
    - view-only and send policy, which never read the clipboard;
    - remote text written with provenance, including during a 300-frame
      flood, never echoed, and never written while unfocused;
    - read failure notices, with a single read per change.
  - The gated real-clipboard test ran on this machine while the desktop was
    idle, restoring the previous text. It checks that remote writes carry
    `CanUploadToCloudClipboard` = 0 and the origin (pid, session,
    generation); that the process's own origin reads as remote; that local
    writes carry neither marker; and the size, change and NUL errors.

  Result: 6 consecutive clean runs. Mutation-checked, 8 mutations, all fail
  the suite: cloud marker, own-origin check, view-only gate, send-policy
  gate, ambiguous focus, snapshot-state filter, change dedupe, failure
  notice.
- Open: D21's confirmation that remote text never reaches a second device
  needs a test account with cloud clipboard sync on two devices (owner).

### W4.7 — display service — 2026-09-23

- Behaviour: `platform/windows/TidyVNC.Native/Platform/NativeDisplayService.cs`.
  - The source is the helper DLL's QueryDisplayConfig topology.
    - Each display has a stable ID: 16 lowercase hex digits of the SHA-256
      of the monitor device path, which is the format the preferences
      record stores.
    - Friendly names, with a numbered fallback.
    - Physical rectangles plus logical (effective-pixel) rectangles and
      the scale.
    - Mirrored outputs are reported as one display.
  - `NativeDisplayService` publishes immutable snapshots.
    - The generation advances only on a real change. Ordering and monitor
      handle changes alone keep it.
    - Whole-snapshot validation: unique IDs, exactly one primary, the work
      area inside the bounds, and at most 64 displays.
    - A failed read publishes an empty snapshot with a typed error (for
      example `Unavailable` while every display is powered off, when
      QueryDisplayConfig returns E_INVALIDARG), never stale geometry.
  - `Resolve` keeps surviving saved choices in their order and reports the
    missing ones without rewriting the preference. Only when none survive
    does it fall back to the current display, then the primary.
  - `NativeDisplayChangeListener` runs a hidden top-level window on its own
    per-monitor-v2-aware thread. It receives `WM_DISPLAYCHANGE`,
    `WM_SETTINGCHANGE`, `WM_DPICHANGED` and console display on/off power
    notifications (message-only windows get no broadcasts), and coalesces
    refreshes onto the UI thread.
  - The app owns one service.
- Tests: `DisplayTests`, 5 cases:
  - resolution, including a single survivor;
  - generation rules;
  - invalid topologies refused whole;
  - each notification message refreshing on the UI thread, while unrelated
    power messages do not;
  - the real topology, either valid or typed `Unavailable`.

  `DesktopTests` now tolerates the powered-off case. Result: 3 consecutive
  clean runs; full native suite 88 passed, 2 gated skipped. Mutation-checked,
  6 mutations, all fail the suite: survivor resolution, current-display
  fallback, generation dedupe, the primary rule, the power message filter,
  and stable ordering.
- Open: W6 checks the legacy monitor numbering against the FLTK viewer on
  multi-monitor hardware, and real DPI and topology changes (hot-plug,
  scale change) on that hardware.

### W4.8 — keyboard capture service — 2026-09-24

- Behaviour: `platform/windows/TidyVNC.Native/Platform/NativeKeyboardCaptureController.cs`.
  - `INativeKeyboardCapturing` is the Windows form of macOS
    `NativeKeyboardCapturing`. Windows needs no permission, so start is
    Active or Failed.
  - `NativeWindowsKeyboardCapture` wraps the helper's `WH_KEYBOARD_LL`
    thread (W3.4), which carries the retained win32.c pass-through rules
    (lock keys pass; keys down at capture start pass their release).
  - `NativeKeyboardCaptureController` holds the macOS desktop-view rules:
    - capture only while eligible;
    - automatic capture once per fullscreen entry or focus interval when
      Capture system keys in full screen is on;
    - the explicit Capture keyboard command, with typed `Unavailable` or
      `Failed`;
    - typed release reasons: focus lost, command, sleep, lock, policy
      change, disconnect, close, and ended (the hook went away);
    - the remote's pressed keys are released whenever capture ends;
    - an explicit release, a failure or an ended capture suppresses
      automatic recapture until the next fullscreen entry or focus change.
  - `DesktopView` owns one controller: focus changes drive it and dispose
    closes it. The menu command and fullscreen come with the W5/W6 screens;
    sleep and lock come with W4.11.
- Tests: `KeyboardCaptureTests`, 4 cases:
  - fullscreen policy and suppression, including no recapture after a
    dialog without a focus change;
  - eligibility and every lifecycle release;
  - failures and ended captures;
  - the real low-level hook starting and stopping for a window, which
    needs the UI-thread message hook first.

  Result: 3 consecutive clean runs. Mutation-checked, 6 mutations, all fail
  the suite: suppression, focus reset, input release, policy release, the
  once-per-entry rule, and the eligibility gate.
- Open: which keys the hook actually captures in fullscreen (Alt+Tab, Win
  and the rest of DESKTOP.md section 5) is W6 physical verification.

### W0.11 (partial), W1.14, W4.9 — SSH gateway tunnels — 2026-09-24

- Spike (D17, now recorded in DECISIONS.md): Windows OpenSSH 9.5p2 against
  `tests/windows/Shared/SshTestServer.cs`.
  - The test server is a minimal SSH-2 server written for this purpose:
    ecdh-sha2-nistp256, an ECDSA host key, aes128-ctr, hmac-sha2-256,
    "none" or password authentication, and direct-tcpip channels.
  - It shows that `-W` carries RFB, that `SSH_ASKPASS_REQUIRE=force`
    askpass answers passwords, and that `KnownHostsCommand` (`%I %H %t %K`)
    reports the offered key while the new-key question accepts the computed
    fingerprint.
  - It also shows `ssh -G` evaluation, and that a Job Object assigned at
    creation ends ssh and its helpers.
  - ssh.exe needs `%ProgramData%` in its environment.
  - Shape chosen: `-W` with an app relay, so W1.14 is not needed.
  - W0.11 stays open for the `ssh-agent` service (disabled on this machine;
    enabling it is a system change) and real servers and key types (VM or
    owner).
- Behaviour: `platform/windows/TidyVNC.Native/Tunnel`.
  - `NativeOwnedProcess`:
    - `CreateProcessW` with CRT-quoted argv and an explicit environment
      block;
    - `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` limited to the three pipes;
    - `PROC_THREAD_ATTRIBUTE_JOB_LIST` with kill-on-close;
    - `Contains(pid)` for job membership.
  - `NativeSshConfiguration` handles the configuration:
    - a private snapshot of `%USERPROFILE%\.ssh\config`, never created
      when absent;
    - `Include`, `Match exec` and `Match localnetwork` refused before
      evaluation;
    - `ssh -G` for the effective host, user, port and alias, with effective
      proxy, command, forward, PKCS#11 and tunnel settings refused;
    - explicit user and port win over the configuration;
    - the ssh-v2 route identity from the resolved values.
  - `NativeSshAskpassServer` and `tidyvnc-ssh-askpass.exe`
    (`apps/windows/TidyVNC.SshAskpass`, published with the app):
    - a per-attempt named pipe with an owner-only DACL, created as the first
      instance;
    - a 32-byte token and client admission by job membership;
    - the helper refuses a pipe served by any process but the app;
    - bounded frames; answers never contain NUL, CR or LF and are at most
      1023 bytes;
    - `KnownHostsCommand` HOSTNAME observations are recorded, and a new-key
      question is reviewed only when it names that host, key family and
      fingerprint;
    - approval answers with exactly the computed fingerprint, and anything
      else is refused without asking.
  - `NativeSshTunnel` runs a connection:
    - explicit `-o` controls: BatchMode or askpass, StrictHostKeyChecking
      yes or ask, no forwards, no control master, no local commands,
      UpdateHostKeys=no, LogLevel=ERROR;
    - the effective HostName, HostKeyAlias, user and port are enforced,
      with the alias kept as the destination;
    - readiness is the first RFB bytes, within 20 s, or 5 min once a prompt
      is shown;
    - a private AF_UNIX relay accepts only this process
      (`SIO_AF_UNIX_GETPEERPID`) and serves the core's routed connect;
    - stderr is reduced to typed errors in constant space without keeping
      text;
    - close ends the relay, lets ssh exit, ends the job and removes the
      attempt directory.
- Tests:
  - `TunnelTests`, 6 cases with the real ssh.exe and helper:
    - a routed `NativeSession` to RFB over the tunnel, with close ending
      ssh and removing the directory;
    - native host-key review and password;
    - declined key (typed, never written) and wrong password;
    - batch-mode unknown key, password and closed forward;
    - configuration aliases, explicit user, six refused configurations and
      an absent config;
    - startup deadline, cancellation and bad targets;
    - cancelling during a prompt ends the helper process.
  - `AskpassServerTests`, 4 cases: the fingerprint-only answer,
    mismatched questions never asked, wrong tokens and foreign clients
    ignored, structural key parsing.
  - `SshSpikeTests`, 3 cases recording the D17 spike.

  Result: 3 consecutive clean runs. Mutations:
  13 mutations, all fail the suite:
  - the fingerprint and host matches;
  - answering with the fingerprint;
  - the token check and job admission;
  - HOSTNAME-only observations;
  - the relay peer check;
  - StrictHostKeyChecking;
  - effective proxy refusal, Include refusal and Match exec refusal;
  - the explicit user;
  - the interactive deadline.
  The typed stderr errors are exercised by the failure cases above.

  Full native suite: 105 passed, 2 gated skips.
- Open: the gateway field, the prompt and host-key dialogs, and the
  connection controller wiring are W5. The installed app's askpass path is
  covered by the W7 package audit.

### W4.10 — activation, instances, Jump List, console launcher — 2026-09-24

- Behaviour:
  - `apps/windows/TidyVNC/Program.cs` replaces the XAML-generated `Main`
    (`DISABLE_XAML_GENERATED_MAIN`).
    - It reads and clears the command-line marker and sets the
      AppUserModelID `io.github.jkeli.tidyvnc`.
    - Shell launches use `AppInstance.FindOrRegisterForKey("primary")`. A
      second shell launch redirects its activation, with a COM-pumping wait
      and `AllowSetForegroundWindow`, and exits.
    - The primary queues redirected activations until its UI thread exists.
  - `vncviewer.exe` sets `TIDYVNC_COMMAND_LINE=1` for the TidyVNC.exe it
    starts. Such processes never redirect or register (D8), since they may
    own launch credentials.
  - `NativeActivation` (TidyVNC.Native/Activation):
    - operand rules: `\` or `/` means a file, anything else is an address,
      including `desk.tidyvnc`;
    - relative paths are accepted only with the launcher's working
      directory, and redirected activations accept only full paths;
    - `-listen`, and invalid launches that just open a window;
    - `CommandLineToArgvW` splitting, checked against the `CreateProcess`
      quoting.
  - The app routes its own launch and redirected launch or file activations
    through the W4.4 `NativeDocumentLaunchRouter`. A connection file opens
    in a new window for review without connecting; the full review page is
    W5.14.
  - `NativeJumpList` publishes the "New connection" task through
    `ICustomDestinationList`, because the WinRT JumpList needs package
    identity. The task is a shell launch, so it reaches the primary.
  - `.tidyvnc` registration under HKCU is the installer's job (W7);
    handling is here.
- Tests:
  - `ActivationTests`, 4 cases: operand rules, splitting and its round trip
    with `NativeOwnedProcess.Quote`, the marker, and publishing and deleting
    a Jump List under a disposable AppUserModelID.
  - Gated UI test `ShellLaunchesRedirectToThePrimaryAndCommandLineLaunchesDoNot`
    ran on this machine with the desktop idle for about an hour and passed:
    - a second shell launch exits 0 and the primary opens a second window;
    - a full-path `.tidyvnc` launch exits and the primary shows its server
      for review;
    - a marked command-line launch keeps its own process and window, and
      the primary still has 3.
- Same run, the rest of the gated UI suite:
  - `ClosingDuringAuthenticationExitsCleanly` and `TwoWindowsConnectAtOnce`
    passed (W3.5/W3.6 evidence).
  - `ConnectAuthenticateRenderTypeClickAndDisconnect` timed out waiting for
    the remote desktop on screen. The monitors were in power save, so its
    screen-capture check needs the displays on. W3.6 stays open until it
    passes.
- Open: D8's two-process confirmation for Explorer file opens through the
  real association waits for the W7 installer, which registers it.

### W4.11 — lifecycle, power, session events, bell, logging, links — 2026-09-24

- Behaviour:
  - `NativeSessionEvents` (Platform) runs a hidden top-level window on its
    own thread.
    - It registers `WTSRegisterSessionNotification` and
      `PowerRegisterSuspendResumeNotification` (Modern Standby) and reports
      lock, unlock, suspend and resume.
    - `WM_QUERYENDSESSION` never vetoes. It starts the app's shutdown once,
      with `ShutdownBlockReasonCreate`.
    - `WM_ENDSESSION(TRUE)` waits for the drain, at most 5 s;
      `WM_ENDSESSION(FALSE)` returns at once.
    - `RegisterApplicationRestart` is not used.
  - `NativeBell`: `MessageBeep(MB_OK)`, coalesced per delivery turn.
  - `NativeProcessLogging`:
    - validates every `Log` value, and the last one wins, committed before
      the first runtime;
    - maps unsupported targets to Unavailable;
    - reports the Windows default file path for Help (%TMP%, %TEMP%,
      %USERPROFILE%).
  - `NativeHelpLinks`: only the fixed project and issue URLs, opened with
    `Launcher.LaunchUriAsync`.
  - App:
    - configures logging before the runtime and routes session bells to
      the coalesced bell;
    - lock and suspend release every desktop's capture (typed Lock/Sleep)
      and held keys and buttons;
    - exit order: document router, then any open file dialog, then every
      window's session; the last window drains the clipboard, displays and
      runtime, then signals a waiting `WM_ENDSESSION`, then stops the
      session thread.
- Tests: `LifecycleTests`, 4 cases:
  - lock, unlock, suspend and resume reported, and unrelated messages not;
  - sign-out never vetoed, one shutdown per sign-out, the drain awaited and
    bounded, and a vetoed sign-out returning at once;
  - bell coalescing;
  - logging selection and errors, the default path and the fixed links.

  Result: 3 consecutive clean runs. Mutations:
  7 mutations, all fail the suite:
  - vetoing sign-out;
  - not waiting for the drain;
  - waiting without the deadline (the test hung; killed by timeout);
  - starting a second shutdown;
  - bell coalescing;
  - lock detection;
  - last-Log-wins.
- Open: a real sign-out, restart and Modern Standby cycle with live
  connections is part of the W7 VM matrix.

### W4.12 — service contracts, test isolation, handoff — 2026-09-24

- Contract tests: every W4 service has its own MSTest class in
  `tests/windows/TidyVNC.Native.Tests`, each mutation-checked as recorded in
  its own evidence section:
  - Storage, Credential, Trust, Document, RegistryImport, FileDialog;
  - Clipboard, Display, KeyboardCapture;
  - Tunnel, AskpassServer, SshSpike;
  - Activation, Lifecycle.
  Real peers are used wherever the macOS tests use them: `LoopbackPeer`,
  `RfbTestServer`, the new `TlsPeer` and `SshTestServer`, real Credential
  Manager entries under test prefixes, real registry test keys, and the real
  ssh.exe and askpass helper.
- Isolation (TESTING.md section 2), in Debug builds only: `TIDYVNC_STATE_ROOT`
  now moves, together:
  - the stores;
  - the Credential Manager prefix (`TidyVNC-test-<run>/credentials.v1/`);
  - the registry import root (`HKCU\Software\TidyVNC-Test\<run>`; no test
    key means no sources);
  - the log file (`<root>\vncviewer.log`, through
    `tidyvnc_logging_configure_with_file`).

  The run ID is a SHA-256 of the root path, case-insensitive. The app
  configures logging from it. `IsolationTests`, 2 cases, cover the default
  and isolated values, run separation, a real credential written only under
  the isolated prefix, and imports read only from the isolated key.
  Release builds compile the override out; W7's package audit checks the
  Release binary.
- Handoff: plans/native-ui/HANDOFF.md replaces "Semantics a Windows backend
  must decide (not implemented)" with the decided Windows semantics, per
  service, pointing at SERVICES.md, DECISIONS.md and these tests.
- Full native suite on this machine: 115 passed, 2 gated skips.

### W5.1–W5.8 (progress), W5.16 (progress), W5.18 (catalog) — connection window and per-connection dialogs — 2026-09-24

- IDs/commits: 00b3076a, 99bb06e4, 332642e3, d71777bc, 338835dd, c55aed71,
  c9dc653f, ab0f2a19, efc2a504, c07c92f3. No item is checked: each still
  has keyboard-only, Narrator or physical checks open (listed below).
- Behaviour delivered and affected interfaces:
  - Strings (D20): `apps/windows/strings.py` generates
    `Strings/en-US/Resources.resw` from the macOS catalog plus
    `Strings/windows.json`. It applies sentence case, .NET placeholders and
    Windows terminology ("full screen" as a noun, "full-screen" as an
    adjective, "scale" instead of "backing scale"). The audit flags macOS
    terms. Typed `NativeText` keeps library text localizable.
  - Session setup: `NativeSessionSetup.Resolve` layers app defaults,
    profile, command line and document into the configuration and the
    frontend policies, with typed setup failures and monitor mapping.
  - Controller: `NativeConnectionController`, the ConnectionModel port. It
    owns session defaults, recent history, SSH prompts, a single editor
    slot with Connected/Disconnected/Any scopes, and close ordering.
  - Connection window (W5.1): menu bar, address row, toolbar, gateway,
    notices, pre-session pages (loading, problem, review, mapping) and the
    status bar.
    - `DialogPresenter` shows one ContentDialog at a time in the macOS
      priority order: SSH, authentication/trust, editor, problem, message.
    - Command-line launches connect on ready; shell address launches fill
      the address; files open for review.
  - Dialogs:
    - authentication (W5.2) and trust (W5.3);
    - encoding (W5.4), which waits for the core on cancel;
    - security with TLS priority and certificate files (W5.5);
    - input (W5.6) and scaling (W5.7); the desktop view refuses sizes it
      cannot render (16384 backing limit).
  - W5.8:
    - connection options: shared access and Retry, inherit/on/off, while
      disconnected;
    - resize policy and Resize remote desktop: custom size, or one remote
      screen per chosen display from `tidyvnc_display_layout_compute`,
      reusing RFB screen IDs; close waits for the server's reply;
    - full-screen displays: start in full screen, current/all/selected,
      review of changed topology;
    - `FullscreenHost`: the current display uses FullScreenPresenter with
      the chrome collapsed; all or selected displays get owned full-screen
      windows, each with its own swap chain drawing its region of a shared
      canvas (`tidyvnc_desktop_canvas_geometry`/`_damage`); topology changes
      and disconnects close full screen; automatic entry once per connection
      while wanted; a user's exit sticks;
    - mixed-DPI displays get a gap-free effective-pixel arrangement derived
      from the physical desktop, because the core refuses overlapping
      logical rectangles;
    - automatic remote resize: `NativeRemoteResizeCoordinator`, the macOS
      coordinator port with canvas ownership and manual holds;
    - window placement: `window-state.json` restores only onto displays that
      still exist; `-geometry` and `Maximize` apply once, never after the
      user moves the window;
    - viewer shortcuts: Ctrl+Alt+Enter toggles full screen; G and M reach
      the desktop view through `NativeShortcutRouter`.
  - Core: `-via` capability on WIN32 (`Invocation.cxx`). The last address
    of a connect waits for the whole connect deadline, so a refused port is
    reported as refused (`SocketConnector.cxx`, `tests/unit/windows`).
- Tests, commands and results:
  - `dotnet test` on `tests/windows/TidyVNC.Native.Tests`: 153 total, 151
    passed, 2 gated skips. New classes: Setup, StringCatalog, Connection,
    EncodingDraft, SecurityDraft, InputScaling, ResizeConnection, Placement,
    Fullscreen, AutomaticResize. The resize/fullscreen classes were repeated
    5× clean.
  - `LoopbackPeer` speaks ExtendedDesktopSize: announcements, replies with
    status, SetDesktopSize on the wire.
  - `python apps/windows/strings.py audit`: 1066 strings, 270 referenced, no
    problems.
  - Core ctest (MSVC): 735/735 after the core edits.
  - Retained FLTK (MinGW64 Debug) after the core edits: builds; unit
    655/659, the same 4 known failures as the planning checkpoint
    (DocumentABI allocation injection, three GDI `Surface` timeouts).
  - UI tests (TIDYVNC_UI_TESTS=1, idle-gated):
    - redirect/review, close during authentication and two windows pass;
    - the render test fails;
    - the new full-screen test (`-FullScreen`, Ctrl+Alt+Enter) fails with
      "Displays unavailable". The only display was powered off, so
      QueryDisplayConfig reports no active paths. Both tests are to be
      rerun with the display awake.
- Machine: Windows 11 Pro 25H2 (10.0.26200) x64, .NET 10.0.112, Debug x64,
  one 3840×2160 display.
- Remaining limitations and unchecked dependencies:
  - W5.1–W5.8: keyboard-only and Narrator passes; W5.19 covers
    Axe.Windows.
  - W5.8: physical full screen on an awake display; all/selected displays
    need a second monitor (hardware) and mixed-DPI hardware.
  - W5.16: the retry and alert flows are wired; E-row checks remain.
  - W5.18: the pseudo-locale checks.
  - Context menu (M) and the full-screen connection bar are W5.11.

### W5.9–W5.12 (progress) — settings, profiles, Connection menu, full-screen bar, listener — 2026-09-24

- IDs/commit: the commit carrying this entry. No item is checked yet: keyboard-only and Narrator passes, and the
  tests that need the display awake, remain.
- Behaviour delivered and affected interfaces:
  - W5.9 Settings: `NativePreferencesDraft` edits canonical parameters checked by the core as they are set (an
    invalid GnuTLS priority is refused by the core's preflight at once), commits against the revision it read,
    reports conflicts and unreadable records without overwriting, and knows each parameter's built-in value.
    `SettingsWindow` has a NavigationView with the macOS sections (Security with Certificate files), settings
    cards with the effective value and its source, tri-state fields, and a footer (Restore built-in defaults,
    Cancel edits, Apply, Reload). File > Settings, Ctrl+,. `CommunityToolkit.WinUI.Controls.SettingsControls`
    (pinned in the plan) is now referenced.
  - W5.10 Saved profiles: `NativeProfileLibrary` (macOS NativeProfileLibrary) implements the same
    `INativeSettingsEditor` as the defaults draft, so `SettingsSections` serves both windows; profile values
    inherit the app defaults. `ProfilesWindow` covers the list, name/address/gateway checks, Delete with a
    confirmation flyout (P07) and Open connection, which opens a window without connecting. File > Saved
    profiles, Ctrl+Shift+P.
  - W5.11 Connection menu:
    - the full UX.md section 6 order: Disconnect, Full screen (F11), Minimize, Resize window to desktop, Resize
      remote desktop, Pan desktop, Hold Ctrl/Alt, Capture/Release keyboard, Send Ctrl+Alt+Del, Refresh, the
      seven connection settings, statistics;
    - `NativeDesktopCommands` for the held modifiers and the chord;
    - pan limits in `NativeGeometry`, with pan in the renderer's viewport;
    - the viewer chord + M opens the menu over the desktop;
    - `FullscreenConnectionBar` in full screen;
    - Minimize minimizes all full-screen surfaces;
    - the menu bar's Connection menu is rebuilt only when its state changes. Rebuilding it on every snapshot
      closed open menus and kept the UI thread busy.
  - W5.12 Listen for connections: `NativeListenerModel` (macOS ListenerModel) and `ListenerWindow`:
    - port and families are checked before binding; a stopped or failed listener finishes closing before
      binding again;
    - peers are reserved while their window opens;
    - AlertOnFatalError=off closes silently;
    - `vncviewer -listen [port]` starts one, as do the File menu (Ctrl+Shift+L), the Listen activation and a
      new "Listen for connections" Jump List task;
    - the app stays running while a listener is open.
  - Strings: sentence case now lowers hyphenated words with a lowercase tail ("Built-in"); new Windows-only
    strings; "Send Ctrl+Alt+Del".
- Tests, commands and results:
  - Native suite: 161 total, 159 passed, 2 gated skips. New classes: PreferencesDraft, ProfileLibrary,
    DesktopCommand (key events on the wire), Pan, ListenerModel (real TCP peers, busy port).
  - Gated UI tests (TIDYVNC_UI_TESTS=1, idle-gated), passing:
    - Settings apply/cancel (preferences.json in the isolated root);
    - Saved profiles create/open/delete;
    - listener accepts a reverse connection (`RfbTestServer.ConnectReverseAsync`);
    - two windows;
    - close during authentication;
    - shell launches.
  - UI tests failing only because the display was powered off: the render test, the full-screen test, and
    the new Connection-menu test (it cannot take the foreground). Rerun them with the display awake.
  - Strings audit: 1068 strings, 340 referenced, no problems.
- Remaining limitations and unchecked dependencies:
  - A listener started from a listener file (-listen file.tidyvnc) does not yet review the file first.
  - Connection information (W5.15) is not yet in the Connection menu.
  - The connection bar and multi-surface Minimize need physical checks (display awake; a second monitor for
    all/selected displays).

### W5.15, W5.17, W5.19 (progress) — information, statistics, help, about, Axe.Windows — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Behaviour delivered:
  - W5.15:
    - Connection information (Q01) is a read-only dialog in the editor slot, with live values;
    - Copy diagnostics (Q02) copies `RedactedDiagnostics` through `NativeClipboardCoordinator.CopyLocalAsync`,
      so the entry is local and not marked as remote content;
    - the statistics overlay (Q03/Q04) is part of `DesktopView`, so it shows on the window and on every
      full-screen surface;
    - the menu entry is Connection > Connection information.
  - W5.17 Help and About:
    - Help > TidyVNC help (F1) opens the guide and the bundled README (acknowledgements), LICENCE.TXT and the
      Windows third-party notices (`apps/windows/ThirdParty/README.md`), copied as `Documents\*` beside the
      app;
    - project and issue links;
    - Help > About TidyVNC shows the version and the processor architecture, with a link to the licence topic.
  - W5.19: `AccessibilityTests` runs Axe.Windows (the package pinned in the plan, build-time only) over every
    window of the running app: the connection window, Settings, Saved profiles, the listener and Help.
- Tests (gated UI tests, idle desktop):
  - ConnectionInformationAndStatistics, HelpAndAbout and EveryWindowPassesAxeWindows pass. The Axe scan
    reports no errors.
  - Strings audit clean.
- Remaining: Narrator, keyboard-only and contrast-theme passes (W5.19); the desktop view's automation peer
  with the Scroll pattern; the 225% text-size check.

### W5.13 (progress) — registry import windows — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Behaviour delivered:
  - Defaults (F09-F12): `NativeDefaultsImport` reads the chosen registry source (*Current TidyVNC settings* or
    *TigerVNC settings*) through the core import projection.
    - Monitor numbers become stable display IDs by the retained numbering; numbers without a connected display
      are omitted and listed.
    - Excluded, unknown, unreadable and Windows-unavailable values need an acknowledgement.
    - The review is written exactly, marked `importedFrom: registry`, against the revision read. A later
      native save refuses the stale review.
  - History (F13-F14): `NativeHistoryImport` offers the registry history only while native history was never
    started. Import or Skip starts native history (`ImportHistoryAsync`); omitted duplicates need
    acknowledging.
  - `ImportWindow` for both, the File menu items, and the connection window's first-use offer (defaults first,
    then recent connections; *Not now* for the run). The registry is never written.
- Tests:
  - ImportTests (disposable HKCU test keys): review, acknowledgement, mapping, marker, stale review, the
    registry left unchanged, history import once and skip.
  - Gated UI test FirstUseOfferImportsTigerVncDefaults, against the isolated registry root, passes.
- Remaining: a manual display-assignment step for imported monitor numbers (macOS lets the user choose; here
  missing numbers are omitted with acknowledgement).

### W5.14 (progress), W5.18 (pseudo-locales), W5.19 (desktop peer), W5.21 (progress) — 2026-09-24

- IDs/commit: the commit carrying this entry.
- W5.14, Save connection file as (F05-F08):
  - `NativeDocumentExport` snapshots the connection (endpoint, shared, reconnect, clipboard, encoding, input,
    inactive cursor, scaling, full-screen policy, security types, CA/CRL files, ignored-input and SSH gateway
    flags). The core's export-loss rules decide what the review lists; a custom TLS priority refuses the export.
  - Every emitted field is read back through the shared decoder before the export is offered. Passwords and
    trust decisions are never written. `Data()` refuses until every loss is acknowledged.
  - Selected displays become monitor numbers of the current arrangement. When a selected display has no
    number (disconnected), `NativeExportMapping` lets the user assign distinct positive numbers; "Change
    exported monitor numbers…" reopens it from the review. Only the file changes.
  - File > Save connection file as… (Ctrl+Shift+S) opens the review in the editor slot (mapping, then the
    review of losses and monitor numbers, "Continue to save…"). The Windows save dialog follows (`.tidyvnc`,
    overwrite prompt), then `NativeDocumentFileWriter` writes atomically. Progress, success and each
    `NativeDocumentSaveError` show in an InfoBar in the window.
  - Tests: ExportTests (losses acknowledged, no secrets, TLS priority refused, SSH gateway loss, monitor
    numbering, mapping validation and explicit numbers). Gated UI test
    SaveConnectionFileAsReviewsLossesAndWrites passes: review, save dialog, file on disk, status.
- W5.18, pseudo-locales (D20):
  - `strings.py pseudo` writes qps-ploc (about 40% longer, accented) and qps-plocm (mirrored) catalogs.
    They are generated, git-ignored and left out of non-Debug builds.
  - The catalog carries `app.flow.direction`; every window applies it, and the remote desktop is never
    mirrored. `TIDYVNC_UI_LANGUAGE` sets `ApplicationLanguages.PrimaryLanguageOverride` for layout checks.
  - Gated UI test PseudoLocaleWindowsFitTheirMinimumSize: in each pseudo-locale, the connection, settings,
    saved profiles, listener, import and help windows shrink to their minimum size, no text, button, box
    or menu item extends beyond its window, and qps-plocm mirrors the menu bar. Both pass. The test's menu
    helper now waits for a menu's items before toggling it again.
  - Screenshots are saved for review, but with the owner's display powered off they capture black. The
    visual review is still open.
- W5.19, desktop automation peer (UX.md section 10, V02, W18):
  - `DesktopAutomationPeer`: control type Image, name "Remote desktop", the macOS help text, and the Scroll
    pattern (percentages, view size, scroll by page, set percent with -1 kept) over the pan. Invoke focuses
    the view. Property-change events follow the pan.
  - `NativeGeometry.ScrollPercent`, `ViewPercent` and `PannedTo` carry the arithmetic.
  - Tests: PanTests.ScrollPercentagesFollowThePan; the gated UI test DesktopViewScrollsForAssistiveTechnology
    (2000×1500 desktop at 100%: set percent, page left and down, Invoke focuses) passes.
- Gated UI runs on this machine (display powered off, desktop idle): SaveConnectionFileAs, both pseudo-locales,
  DesktopViewScrolls, OlderWindowsIsRefused, HelpAndAbout, SavedProfiles, SettingsApply, ConnectionInformation
  and FirstUseOffer pass.
- W5.21, progress:
  - Mica on the connection window too; the desktop area stays opaque black.
  - Below Windows 11 (build 22000), the app shows why and exits with code 1 before any window opens (W15).
    Gated UI test OlderWindowsIsRefused simulates build 19045 and passes.
- Remaining:
  - W5.18: visual review of the pseudo-locale screenshots with the display on.
  - W5.19: Narrator, keyboard-only, contrast-theme and 225% text passes.
  - W5.21: title bar and Snap Layouts checks, icons, themes, and Mica's solid fallback with transparency off.

### W5.19 (progress), W7.1/W7.2 (progress) — theme-following colours, F6, payload trimming, licence texts — 2026-09-24

- IDs/commit: the commit carrying this entry.
- W5.19, contrast themes: code-built text and surfaces no longer copy a theme brush once. `Ui.SetTone` and
  `Ui.Surface` apply App.xaml styles whose `ThemeResource` setters follow light, dark and each contrast theme
  while windows are open. Covers error, warning, secondary and primary text; the full-screen bar; the
  statistics overlay; dividers; and display-chooser tiles. The only fixed colour left is the black desktop
  letterbox, by design.
- W5.19, keyboard: F6 and Shift+F6 cycle the address row, toolbar, open notices and the desktop (or the
  pre-session page). The desktop keeps F6 for the remote computer. Gated UI test F6MovesBetweenTheWindowAreas
  is written; it injects keys, so it waits for the display to be on.
- W7.1, payload: the unused Windows App SDK components are excluded by direct `ExcludeAssets="all"`
  references at the metapackage's pinned versions: AI, ML (ONNX Runtime, DirectML), Widgets, and the
  Runtime package's full framework MSIX. Self-contained builds then assemble the payload and WinRT
  registrations from the components actually used. The Release payload drops from 233 MB/454 files to
  186 MB/407 files.
  - `build.py` reuses a core directory configured with tests for a plain build.
- W7.2, licence texts: `apps/windows/ThirdParty/{gnutls,nettle,gmp,libidn2,p11-kit}` hold the upstream
  licence texts the MSYS2 packages lack. They are verbatim FSF texts from other local packages, and
  p11-kit's own COPYING from the MSYS2 usr package. Each has a README.txt giving its source.
- Tests:
  - Full gated VerticalSlice UI suite on the rebuilt app: 14 of 18 pass.
  - The 4 failures need the display on: on-screen render, full screen, foreground key injection, and F6.
  - Axe.Windows scan passes. `vncviewer.exe --version` from the Release payload exits 0.

### W7.1–W7.3, W7.5 (progress) — package stage: payload, audit, report, MSI — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Behaviour: `python apps/windows/build.py --configuration Release --stages package` builds the core and
  publishes the app, then `apps/windows/package.py`:
  - Assembles the payload: published files minus PDBs and test DLLs; the app-local Visual C++ runtime
    DLLs the payload imports (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`, from the VS
    redistributable folder); README and LICENCE at the root; and `ThirdParty\<component>\` for all 30
    components.
    - Components cover the MSYS2 packages, NuGet packages, the .NET runtime pack, the Windows SDK projection
      (Windows SDK licence), the Windows App SDK components, WebView2 and the VC++ runtime.
  - Audits the payload with `apps/windows/pe.py`, a standard-library PE reader:
    - every image's architecture;
    - every import and delay import resolved in the payload, to an API set, or to System32 (never the VC++
      runtime, which must be app-local);
    - no debug CRT, MinGW runtime or FLTK imports or exports;
    - no native DLL that nothing imports, P/Invokes, registers in the app manifest or lists as a runtime
      native asset;
    - `tidyvnc_viewer.dll` exports exactly the 133 functions declared in `tidyvnc.h`;
    - every shipped binary belongs to a component with a licence text.
  - Writes `package-report.json`: files with hashes, architectures, signatures, owners and import
    resolution; components; toolchain; MSI hash; the relocation results.
  - Signs only with `--sign <thumbprint>` (D23). Without it the report records `signed: false`.
  - Relocation check: the payload copied to a path with spaces and non-ASCII characters runs
    `vncviewer --version` (0) and `--help` (1) with only System32 on PATH, and refuses a simulated
    Windows 10 build (1).
  - Generates the WiX source and builds a per-user MSI (WiX 5.0.2).
    - Install location `%LOCALAPPDATA%\Programs\TidyVNC`.
    - One component per folder with an HKCU key path, and `RemoveFolder` entries (ICE38/ICE64).
    - Windows 11 launch condition, from the build number in the registry because VersionNT is capped.
    - Start menu shortcut with the AppUserModelID.
    - `.tidyvnc` ProgID and OpenWithProgids under HKCU; the default app is not forced.
    - Optional feature, off by default, that adds the install folder to the user PATH.
    - Major upgrades, with downgrades blocked; Add/Remove Programs icon and links.
    - Validation with `wix msi validate` passes. ICE03 is suppressed for Microsoft's WinUI resource
      language IDs, and ICE91 because a per-user package installs everything to the user profile.
  - Publishes the MSI, the symbols zip (PDBs and wixpdb) and the report by renaming the private staging
    directory. An existing output is refused, which was checked.
- `vncviewer.exe` now refuses older Windows too, through the shared `NativeWindowsVersion`, as TidyVNC.exe
  does. Test: WindowsVersionTests.
- Result, x64 Release, published to `build/winui/release/TidyVNC-1.16.80-x64`:
  - payload 554 files and 194 MB, with 280 PE images;
  - MSI 58.5 MB;
  - symbols 0.8 MB.
- UpgradeCodes are recorded in PACKAGING.md section 4.
- Remaining:
  - ARM64 packaging needs the MSVC ARM64 build tools. The ARM64 VC++ redistributable is missing, and the
    package stage says so.
  - W7.3/W7.6: installing, upgrading, repairing and uninstalling, and the launch-condition refusal on
    Windows 10. These need a VM or a dedicated test account; installing into the owner's account is not
    allowed.
  - W7.5: starting TidyVNC.exe from the relocated copy, in a test account, because Release ignores the
    test state root.
  - W7.4: signing, deferred.

### W7.9 (progress) — Windows build guide, README and Help — 2026-09-24

- IDs/commit: the commit carrying this entry.
- `BUILD-WINDOWS.md` sits beside `BUILD-MACOS.md`. It covers:
  - requirements;
  - `build.py` stages and options;
  - the core, .NET, UI-automation and strings checks, and the test environment variables;
  - the package stage and its outputs;
  - per-user MSI installation, with the optional PATH feature;
  - upgrades and uninstall, and what is kept;
  - unsigned-build behaviour.
- `BUILDING.txt` points Windows 11 builds there and keeps the MinGW FLTK sections for Windows 10.
- `README.rst`, which ships in the payload, explains the SmartScreen and Smart App Control behaviour and how
  to remove kept data.
- Help has a new guide topic, "Installing and removing", with the same content (PACKAGING.md sections 7
  and 8).
  - `strings.py` accepts `reviewed` entries for Windows-only keys: "Smart App Control" matches the macOS
    term "Control".
- The rebrand audit (`tests/rebrand/audit.py`, run with `PYTHONUTF8=1`) already fails on this Windows
  checkout before these changes:
  - old-brand mentions in macOS and Windows test files that are not in its baseline;
  - the LICENCE.TXT hash, after CRLF conversion; the file itself is unchanged.
  - This is left for the rebrand plan (R5).
- Remaining: the handoff status for W7.9, once W7 is further along.

### W6.12 (progress), W7.1 fix — protocol baseline on Windows; published payload missing its PRI — 2026-09-24

- IDs/commit: the commit carrying this entry.
- `tests/integration/windows-scaling-smoke.py` ports the macOS 55-case protocol/lifecycle baseline:
  - every scaling mode × filter × unit;
  - fragmented updates, cursor replacement, a server framebuffer change and resize suppression;
  - automatic resize from the measured viewport, and explicit DesktopSize.
  - It runs through `vncviewer.exe` with an isolated `TIDYVNC_STATE_ROOT`, so it needs a Debug publish,
    because Release ignores the override.
  - Like the UI suite, it is gated on `TIDYVNC_UI_TESTS=1` and an idle desktop. On failure it kills the
    launcher's process tree.
- The Windows app now logs "Viewport logical WxH, backing WxH" through `tidyvnc_logging_viewport` when an
  automatic resize request is made (`NativeProcessLogging.Viewport`, from `NativeRemoteResizeCoordinator`),
  as macOS does.
- Result on this machine (display powered off, desktop idle), Debug publish: 55/55 cases pass. For example,
  automatic resize requested 945×440 logical and 1417×660 device pixels, matching the logged viewport, and
  every case exited 0.
- Found while writing the smoke test: `dotnet publish` of the unpackaged app left out `TidyVNC.pri`
  (strings and compiled XAML). A published app therefore failed at its first window with a
  XamlParseException. That affected the Release payload and the MSI from the previous package entry. The
  development output, which the UI suite uses, was complete.
  - Fix: `EnableMsixTooling=true` in the app project.
  - The package audit now requires `TidyVNC.pri` with the compiled XAML and strings.
  - The rebuilt package has 555 files and a 58.9 MB MSI.
- Remaining:
  - FLTK side of the comparison: the retained viewer has no state isolation on Windows. It stores history
    and settings in HKCU, so it runs in a test account or VM.
  - Security, tunnel and reconnect smokes (next).

### W6.12 (progress) — security and reconnect smokes on Windows — 2026-09-24

- IDs/commit: the commit carrying this entry.
- `tests/macos/support/security-peer.cxx` builds on Windows too (Winsock ifdefs). `tests/CMakeLists.txt`
  adds `native-security-peer` to MinGW builds, which build the server-side libraries (`rfbserver`); MSVC
  builds only the viewer core. It is built in the existing MinGW tree (`build/mingw/viewer`).
- `tests/integration/windows-security-smoke.py` ports the macOS security smoke:
  - VncAuth, TLSNone, TLSVnc, X509None and X509Vnc (with `-X509CA`);
  - the four RSA-AES variants;
  - reconnect through Retry.
  - The viewer runs through `vncviewer.exe` with `VNC_PASSWORD` launch credentials and an isolated state
    root (Debug publish).
  - `tests/integration/windows-invoke.ps1` answers the server-key prompt (`trust.dialog`, "Connect once")
    and presses Retry (`connection.problem`) with the UI Automation Invoke pattern, not synthesized input.
  - Certificates come from MSYS2's openssl in the temporary directory.
  - The test is gated like the UI suite.
- Result on this machine: 10/10 cases pass (run with `--accept-prompts`). No test processes were left
  running.
- Remaining:
  - SSH tunnel smoke. There is no SSH server on this machine: Windows OpenSSH Server and MSYS2 openssh
    are not installed, and installing either needs approval. An isolated run also needs a Debug-only
    override for the SSH configuration, because the app reads `%USERPROFILE%\.ssh\config` through the
    known-folder API.
  - The FLTK side of the comparison needs a test account or VM (no state isolation).

### W6.4, W6.6, W6.7 (progress) — keyboard equivalence, pointer/wheel/pen, touch gestures — 2026-09-24

- IDs/commit: the commit carrying this entry.
- W6.7, touch: the WinUI desktop view had no gesture model; a touch was a raw left-button drag.
  - `platform/windows/Native/TouchGestures.{h,cxx}` extracts the retained `vncviewer/GestureHandler` and
    `BaseTouchHandler` into the helper DLL. The logic, constants and arithmetic types are unchanged; only
    timers and `gettimeofday()` became an injected millisecond clock with explicit deadlines.
  - The C API is `tvw_touch_*`, and `NativeTouch` is the C# binding.
  - `DesktopView` routes touch pointers through it, with a dispatcher timer for the long-press and
    pinch/scroll decisions. Coordinates are converted to remote coordinates once, when sent.
    - The retained meanings: tap = left click, two-finger tap = right, three-finger tap = middle,
      drag = left drag (50-pixel threshold), long press = right drag, two-finger drag = buttons 4–7, and
      pinch = Ctrl with buttons 4/5.
  - Test `touchgestures` (tests/unit/windows) compiles the retained sources with their clock redirected
    and a stub `core::Timer`. It replays scripted and 3,000 random touch streams through both
    implementations and requires identical events. 6/6 pass.
  - `PointerInputTests` covers the managed binding through the DLL.
- W6.6, pointer:
  - Back and forward (X1/X2) map to the retained bits 1<<7 and 1<<8, and start pointer capture.
  - A pen acts as a mouse: tip is left, barrel is right, and the eraser is ignored.
  - Wheel deltas accumulate to whole 120-unit notches per axis. Before, every partial delta from a
    high-resolution wheel or precision touchpad sent a full notch.
  - Release-all clears the wheel remainders and touch-held buttons.
  - `NativePointerButtons` and `NativeWheelAccumulator` are covered by `PointerInputTests`.
- W6.4: the table-driven translator equivalence test (`keyboardtranslator`, W3.4) passes 10/10 against
  the retained KeyboardWin32. The layout and IME matrix stays open (manual).
- Regression:
  - helper `windowshelper` 6 pass and 1 skipped (displays off);
  - .NET pointer, desktop and pan tests 9/9;
  - gated UI tests DesktopViewScrolls, ConnectionInformation and ClosingDuringAuthentication pass.
- Remaining: touch, pen and precision-touchpad hands-on checks need that hardware, and the touch keyboard
  from the full-screen connection bar is not done yet.

### W6.5 (progress) — release-all — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Wiring (from W3–W5, reviewed here): every trigger ends in `DesktopView.ReleaseKeys()`, which calls
  `NativeSession.ReleaseInput()` (the core input queue's release barrier). The triggers are:
  - keyboard focus loss (`SetKeyboardFocus(false)`);
  - connection-window deactivation;
  - deactivation of a full-screen surface, and full-screen entry and exit;
  - keyboard-capture revocation (`NativeKeyboardCaptureController`);
  - session lock and suspend (`NativeSessionEvents` → `App.SessionChanged`, which also releases capture).
  - Disconnect and close end the generation, and the core drops queued input.
  - The touch-held buttons and wheel remainders now reset too (W6.6/W6.7).
- New test `SessionTests.ReleaseAllLiftsHeldKeysAndButtons`: with Control_L and two buttons held at a
  loopback server, `ReleaseInput` sends the key-up and a pointer event with no buttons. Passes.
- Also rechecked after the MinGW test-peer change: the FLTK MinGW build builds, and its unit tests are
  655/659 with the same 4 known failures (DocumentABI allocation injection and three GDI Surface
  timeouts).
- Remaining: hands-on lock, sleep and Alt+Tab checks with a held key on a real server.

### W6.11 (progress) — reconnect, resize and attach stress — 2026-09-24

- IDs/commit: the commit carrying this entry.
- `StressTests.ReconnectResizeAndAttachCyclesDoNotLeak` exercises TidyVNC.Native and the core DLL. Each
  cycle:
  - connects to a fresh loopback server and receives frames;
  - takes a server-side ExtendedDesktopSize resize and 5 updates, then sends input;
  - disconnects, then reconnects the same session.
  - Every fifth cycle closes the session and attaches a new one.
  - After 15 warm-up cycles, handles, threads, managed memory and private bytes must stay within a fixed
    allowance or a small per-cycle rate. The default is 60 cycles (about 1 s); `TIDYVNC_STRESS_CYCLES` sets
    a soak.
- Soak on this machine, 4,000 cycles in 75 s: no per-cycle growth.
  - Private bytes rose from 21 to about 50 MiB over the first 250 cycles (the native heap settling), then
    stayed at 50–54 MiB.
  - Managed memory stayed about 1.0–1.2 MiB.
  - Handles and threads made one step (+132 handles, +8 threads near cycle 1,700, the thread pool adding
    workers), then stayed flat.
  - With criteria that allow one-off steps like that, the default and soak runs both pass.
- Remaining: attach cycles of the app's Direct3D presenter and swap chains, meaning desktop views
  detaching and reattaching and full-screen surfaces. These need the display on, through the UI suite.

### W5.12 (progress) — vncviewer -listen <file> — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Before: a listener file on the command line was ignored, and the window listened with defaults.
- Now `NativeListenerModel` takes a `NativeSessionDefaults` of purpose Listener, following macOS
  `ListenerModel`:
  - Nothing binds until the file is reviewed. The window shows the review, the monitor mapping, a file
    problem with *Reload connection file*, a defaults failure with *Retry* and *Use built-in defaults*,
    or *Loading listener settings…*.
  - Accepting listens on the file's ServerName port.
  - Cancelling marks the launch cancelled, and that window never listens.
  - Every accepted connection gets the reviewed settings (`NativeReverseRequest.Prepared`).
  - An accepted connection is refused with the macOS text when a reviewed selected display has
    disconnected.
  - Launch credentials go to the first accepted connection only, and are cleared on close or cancel.
- Tests:
  - `ListenerModelTests.AListenerFileIsReviewedAndItsSettingsReachAcceptedConnections`:
    - no bind before the review;
    - the unknown field is listed;
    - the port comes from ServerName;
    - the accepted request carries `Shared=off`;
    - cancel blocks Start.
  - Gated UI test `ListenWithAFileReviewsItFirst`: review, accept, listening, and a reverse connection
    accepted. Passes, and `ListenAcceptsAReverseConnection` still passes.

### W5.13 (progress) — display assignments for imported monitor numbers — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Before: imported monitor numbers without a display in the current arrangement were omitted with an
  acknowledgement. Now, as macOS `DefaultsImportMappingView` does:
  - `NativeDefaultsImport` offers a `Mapping` (a `NativeMonitorMappingRequest`) before the review whenever
    a number has no connected display, suggesting the numbers that do map.
  - `ResolveMapping` requires a connected display for every number; otherwise it reports
    `DisplaysChanged` and asks again. It then builds the review from the assignments.
  - The review has *Change display assignments* (`EditMapping`), which reopens the choice with the
    previous assignments. `CancelMapping` ends the import without writing.
  - The review says whether the numbering follows the current arrangement or the user's assignments.
- `SetupPages.Mapping` takes optional texts, so the import window reuses it with the import titles and
  automation prefix.
- Test: `ImportTests.DefaultsAreReviewedAcknowledgedAndMarked` now covers:
  - the suggestion;
  - the refused incomplete choice;
  - the resolved review's monitors and full-screen displays;
  - edit with the previous assignments;
  - cancel without writing;
  - the existing acknowledgement, marker and stale-review checks.
  - 7/7 import tests pass.

### W7.8 — Native AOT decision; W6.10 (progress) — 2026-09-24

- IDs/commit: the commit carrying this entry.
- W7.8: the D1 final is recorded in DECISIONS.md: ship the self-contained JIT build; Native AOT is not
  adopted yet.
  - Evidence: the full-app AOT publish has 0 warnings (12.9 MB TidyVNC.exe, 140 MB/175 files).
  - The Debug AOT build passes the quick protocol smoke (8/8) and the security smokes (10/10).
  - Its UI suite is 12/19. The failures are the 4 display-dependent tests; saved profiles (flaky, passed on
    rerun); and the two pseudo-locale runs, where an AOT-only hang left the app unable to exit after the
    multi-window sequence.
  - The item is checked because the decision is made with evidence. Revisiting AOT means fixing that hang.
- W6.10: `tests/perf/windows-viewer-workloads.py` ports the workload harness. It uses the same scripted
  peer and the idle, full1080, full4k, scroll and patch workloads at an offered 30/s. Metrics come from
  Win32 through ctypes: TidyVNC.exe CPU seconds per second, peak working set and private bytes, updates
  per second, and round-trip p50/p95.
  - The FLTK side needs a test account or VM (`TIDYVNC_TEST_ACCOUNT=1`), because the FLTK viewer writes
    HKCU.
  - The script is gated like the UI suite. Presentation timing (PresentMon/ETW) and the 10% gate stay
    open.
- W6.10 first run (this machine, Debug publish, display powered off, 6 s per workload, offered 30/s):

  | Workload | Updates/s | CPU s/s | Peak working set | Peak private |
  | --- | --- | --- | --- | --- |
  | idle | 0 | 0.031 | 270 MiB | 195 MiB |
  | full1080 | 30.16 | 0.424 | 362 MiB | 278 MiB |
  | full4k | 30.15 | 0.802 | 697 MiB | 621 MiB |
  | scroll | 30.16 | 0.359 | 306 MiB | 230 MiB |
  | patch | 30.17 | 0.172 | 295 MiB | 217 MiB |

  - Round trips were p50 0.02–0.05 ms and p95 at most 0.22 ms.
  - This is a harness check, not the W6.10 comparison. That needs a Release build, the display on, the
    FLTK side in a test account, and present timing.

### W6.2 (progress) — scaling fidelity at fractional scales — 2026-09-24

- IDs/commit: the commit carrying this entry.
- `ScalingFidelityTests.PresentedPixelsEqualTheSharedRendererAtFractionalScales` covers 192 transforms:
  - scales 100, 125, 150 and 175%;
  - all eight scaling modes (`100`, `Auto`, `FixedRatio`, `FitWidth`, `FitHeight`, a fixed size, a
    percentage, and per-axis percentages);
  - the nearest, bilinear and area filters;
  - logical and device units.
  - A 64×48 patterned desktop, in which every pixel differs from its neighbours, goes through
    `DesktopRenderer` into the Direct3D presenter and is read back.
  - The whole surface must equal the shared renderer's output for the same geometry at its placement, with
    opaque black elsewhere. So there is no Direct3D resampling, and the letterboxing and offsets are
    correct. All 192 match exactly.
- `RemotePixelCentresMapBackToThemselves`: for the same scales, modes and units, the centre of each
  sampled remote pixel, placed through the transform, maps back to that pixel through the inverse input
  mapping (`RemotePoint`). Exact.
- `LoopbackPeer` gained a patterned first frame for these checks.
- Remaining (hardware): a window dragged between monitors of different scale, and each scale on a real
  display.

### W6.3 (progress), W0.6 — remote cursors — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Before: the desktop view never showed the server's cursor. The helper could build an HCURSOR, but
  nothing used it.
- W0.6 route, taken: a real HCURSOR becomes a WinUI `InputCursor` through the Windows App SDK's
  `IInputCursorStaticsInterop.CreateFromHCursor` (`InputCursors.FromHandle`). It is set as the desktop
  view's `ProtectedCursor`, so WinUI keeps it over the view without WM_SETCURSOR subclassing and hands
  back the normal cursors elsewhere.
- `NativeCursorSampler` wraps the shared cursor sampler (`tidyvnc_cursor_renderer_*`). It scales the
  server's cursor by device pixels per remote pixel with the connection's filter, giving straight RGBA,
  the hotspot and blank detection.
- `NativeCursorPolicy` has the retained rules (vncviewer/Viewport.cxx):
  - view-only shows the system arrow;
  - a blank cursor becomes nothing, the 5×5 dot (hotspot 2,2, enlarged by whole pixels at high DPI) or
    the arrow, following the connection's cursor fallback;
  - otherwise the remote cursor is shown.
  - A cursor larger than Windows accepts (`tvw_cursor_limits`) is shown at the largest size that fits.
    The software-cursor overlay of DESKTOP.md section 3 remains a later step.
- `DesktopView` updates the cursor when:
  - the session's cursor changes;
  - view-only or the connection state changes;
  - the geometry changes (scale or mode);
  - the fallback setting changes.
  - A cursor handle lives exactly as long as its InputCursor is in use.
  - A failed conversion falls back to the arrow with a trace warning, and fails fast in Debug builds.
- Tests:
  - `CursorTests.ServerCursorsAreSampledAtTheViewScale`: a Cursor pseudo-encoding from a loopback server
    becomes 6×6 at 1.5×, with the hotspot scaled and red first in straight RGBA; an all-clear mask is
    blank.
  - `RetainedRulesChooseTheShownCursor` covers the rules, the dot and the size fitting.
  - The quick protocol smoke, which sends a 128×128 cursor and then an empty one, passes on the Debug
    publish, where a failed conversion would fail fast.
  - Connected UI tests pass: DesktopViewScrolls, TwoWindowsConnectAtOnce, ConnectionInformation and
    ListenAccepts.
- Remaining:
  - Seeing the cursor on screen and checking for flicker between the toolbar and the desktop, with the
    display on.
  - Large cursors as a software overlay.
  - Density changes checked on mixed-DPI hardware.

### W6.1 (progress), W5.16 (progress) — device loss and error rows — 2026-09-24

- IDs/commit: the commit carrying this entry.
- W6.1 / E05: `DesktopRenderer.SimulateDeviceLoss` (internal, for tests) makes the next render report
  `DXGI_ERROR_DEVICE_REMOVED`. That drives the real recovery path; Direct3D 11 cannot remove a device on
  request.
- `DesktopTests.DeviceLossRecreatesThePresenterAndRedrawsTheFrame` checks that recovery:
  - creates a new device and swap chain, and attaches the new presenter to the panel;
  - redraws the frame in full, with the letterbox black;
  - carries on with later updates on the new device;
  - stays silent (no Failed event) and counts one device reset.
  - An unrecoverable presenter error maps to the desktop presentation text.
  - Desktop tests 6/6.
- W5.16 / E01, E02: `ConnectionTests.NameFailuresAndVanishingServersAreTypedProblems`:
  - `no-such-host.invalid` ends with the resolution problem and its message.
  - A connected server that drops the socket ends with a peer-closed or transport problem that offers
    Retry.
  - Together with `ProblemsOfferRetryOnlyWhenAllowed` (refused, retry scoping, ReconnectOnError off,
    silent close with AlertOnFatalError off, which covers E01, E03 and E06), E02's rejected password
    (`SessionTests.WrongPasswordEndsTheAttemptWithAuthenticationRejected`) and the security smokes, each
    automatable E row now has a test. E04 does not apply on Windows.
- Remaining: seeing each alert on screen (display on), and a real driver reset.

### W7.9 (progress) — status and resume point — 2026-09-24

- `plans/native-ui-winui/RESUME.md` is the checkpoint the README asked for. It holds:
  - the state;
  - the owner-dependent items;
  - exact build, test, smoke, package and strings commands;
  - the standing rules.
- The plan README status and the macOS handoff (`plans/native-ui/HANDOFF.md`) no longer say that nothing
  is implemented on Windows. They point to the WinUI plan and the Windows smokes.
- W7.9 now has all four parts: the build guide, the BUILDING.txt section, Help content and the status.
  The item stays open until W7 finishes, because the handoff status must describe the released state.

### W6.7 (progress) — touch keyboard from the full-screen bar — 2026-09-24

- IDs/commit: the commit carrying this entry.
- DESKTOP.md §6 requires the touch keyboard to be reachable from the full-screen connection bar.
  `FullscreenConnectionBar` now has a "Show touch keyboard" button (automation ID
  `fullscreen.bar.keyboard`, glyph E765, string `desktop.bar.touch.keyboard` in `windows.json`).
  - `ConnectionWindow.ShowTouchKeyboard` first focuses the active desktop view, so the keyboard's
    `VK_PACKET` and key input reaches the remote computer through the W6.4 translator.
  - It then calls `InputPaneInterop.GetForWindow(hwnd).TryShow()` for the view's window. A missing
    input pane (no touch keyboard service) is logged and ignored.
- Build: the app builds with analyzers as errors. `strings.py generate`, `pseudo` and `audit` pass
  (1092 strings).
- Remaining for W6.7:
  - pressing the button with the display on (the full-screen UI tests fail while the display is off);
  - hands-on touch, pen and touch-keyboard checks on touch hardware.

### W3.2, W6.2 (test fixes) — no Debug CRT dialogs in unattended runs — 2026-09-24

- IDs/commit: the commit carrying this entry.
- Reported by the owner: a Debug CRT "abort() has been called" Abort/Retry/Ignore dialog opened on the
  desktop from `TidyVNC.Native.Tests.exe`. The C++ test executables already routed CRT reports to stderr
  (`common/compat/msvc/crt_reports.cxx`), but the .NET test host and test-launched Debug apps load the
  Debug `tidyvnc_viewer.dll` and `tidyvnc_windows.dll` without that. A modal dialog blocks the run until
  someone clicks it. The four long-stuck test processes from earlier sessions were most likely waiting
  on such dialogs; they are gone now.
- Fix:
  - `common/compat/msvc/crt_reports.h` holds the settings: SetErrorMode without fault boxes, no abort
    message or fault report, and CRT warnings, errors and asserts on stderr.
  - The helper exports it as `tvw_quiet_crt_reports`, and `NativeUnattended` wraps it.
  - `TidyVNC.Native.Tests` calls it from `[AssemblyInitialize]`.
  - `TidyVNC.exe` and `vncviewer.exe` call it when they run against an isolated `TIDYVNC_STATE_ROOT`, as
    every UI test, smoke and measurement launch does. Interactive Debug runs keep the dialog, which
    offers the debugger.
  - Check: a process that loads the Debug helper, calls it and then calls the Debug CRT's `abort()` exits
    at once with code 3 and no dialog. The case without the call was not run, to keep dialogs off the
    owner's screen.
- `ScalingFidelityTests` passed alone but timed out (10 min) in the full suite:
  - The viewer publishes its blank framebuffer before the first update fills it. The test cloned that
    blank frame as its reference whenever the pattern had not arrived yet, which depended on test
    order, so all 192 cases waited out their 5 s.
  - It now waits for the patterned frame, and stops after five mismatches or a renderer failure, naming
    the first differing pixel.
  - `LoopbackPeer`'s pattern mode now answers the viewer's first update request in the viewer's pixel
    format, as a real server does.
- `LifecycleTests.SignOutNeverVetoesAndWaitsBoundedlyForTheDrain` asserted the thread-pool shutdown start
  without waiting for it. It now waits, bounded.
- Result: the full .NET suite has 181 tests: 179 pass, 0 fail, and 2 skip (they need
  `TIDYVNC_UI_TESTS=1`). The helper's `windowshelper` passes 7/7.
  - `DesktopCommandTests.HeldModifiersAndTheSecureAttentionChordReachTheServer` failed once, after
    30 ms, in an earlier full run. It passed alone and in the next full run, and its message was not
    captured, so it is left unchanged and watched.
