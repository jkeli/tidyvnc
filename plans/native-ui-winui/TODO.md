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
- [ ] W1.14 Only if D17 selects `ssh -W`: routed stream transport with the routed-connect contract, one feature bit and one export.

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
- [ ] W4.9 SSH tunnel owner with Job Object, askpass helper over a named pipe, configuration capture, host-key review (D17).
- [ ] W4.10 Activation: primary instance, Jump List, file association handling, console launcher (D8/D9).
- [ ] W4.11 Lifecycle: close and exit ordering, `WM_QUERYENDSESSION`, lock and suspend, bell, logging, links.
- [ ] W4.12 Service contract tests and a Windows semantics section in the handoff.

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
- [ ] W7.8 Final Native AOT decision (D1).
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
