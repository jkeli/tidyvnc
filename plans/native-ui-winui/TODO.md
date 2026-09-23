# WinUI TODO

Tracks [PLAN.md](PLAN.md). Planning checkpoint `6972f720`, 2026-09-23: **no code
is started;** the owner decisions in W0.1 are recorded. Task IDs are W0.x–W7.x,
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
  - [ ] Install vcpkg, WiX and MSYS2 and record their versions
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

- [ ] W1.1 CMake: MSVC allowed for `TIDYVNC_UI=WINUI` and headless builds, still refused for FLTK/server targets; `WINUI` added to `cmake/ViewerFrontend.cmake`; compiler-specific flag sets; `_WIN32_WINNT=0x0A00` for WinUI only.
- [ ] W1.2 `vcpkg.json` with a pinned baseline for x64 and ARM64; versions recorded (or the D3 fallback documented and scripted).
- [ ] W1.3 MSVC `/W4` clean with a reviewed suppression list; `/WX` in Debug; GCC/Clang C++11 builds still clean.
- [ ] W1.4 `TIDYVNC_API` export macro and `tidyvnc_viewer.dll`; export list equals the header; `headless.py` header audit accepts exactly that macro.
- [ ] W1.5 Windows wakeup and established-socket transport (`WSAEventSelect`, `FD_CLOSE` peer-closure observation) with tests.
- [ ] W1.6 Windows connector: cancellable `GetAddrInfoExW`, nonblocking connect, family policy, scope IDs, typed failures, with tests.
  - [ ] D18: `AF_UNIX` endpoints enabled with tests, or reported unavailable with a recorded reason
- [ ] W1.7 Windows listener (`SO_EXCLUSIVEADDRUSE`, `IPV6_V6ONLY`), passing the existing listener contract tests.
- [ ] W1.8 Windows private log file (owner-only DACL, `LockFileEx`, rotation, reparse refusal), stdio routes in a GUI process, retained default path.
- [ ] W1.9 Bridge: Windows feature bits, Windows path rules for CA/CRL and logs (UTF-8 active code page or in-memory CA/CRL loading, CORE.md §4), native error domain, Winsock/DNS error categories.
- [ ] W1.10 Tests: MSVC unit suite with justified exclusions; `c-abi-smoke` gated on the listener bit; DLL-loading C smoke; `headless.py` Windows mode.
- [ ] W1.11 AddressSanitizer build of the core and unit suite.
- [ ] W1.12 FLTK MinGW build and unit run still pass; ARM64 cross-build of the core succeeds.
- [ ] W1.13 End-to-end C program through the DLL: loopback connect, VncAuth, TLS, frames, disconnect, drain.
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
- [ ] W2.8 Update the handoff, bridge README and PARITY references for the new exports.

Exit: CORE.md §8, W2 paragraph.

## W3 — .NET bridge and vertical slice

- [ ] W3.1 Solution layout (`platform/windows/TidyVNC.Native`, `platform/windows/Native`, `apps/windows/TidyVNC`, `apps/windows/TidyVNC.Cli`, `tests/windows`); central package versions; nullable and warnings-as-errors; CsWin32 configuration; licence list started.
- [ ] W3.2 Interop: `LibraryImport` declarations, struct size/offset tests against the C smoke's values, `SafeHandle`s with asynchronous close and drain, the callback dispatcher to `DispatcherQueue`.
  - [ ] D7 responsiveness: worst UI-thread tick gap during a pending connect, a raw decode flood and shutdown under load
- [ ] W3.3 `NativeRuntime`, `NativeSession`, `NativeListener` with prompts, frames, input, clipboard and information; MSTest model tests against real loopback peers.
- [ ] W3.4 Helper DLL skeleton with its C API: presenter, keyboard translator extracted from `KeyboardWin32.cxx` with the equivalence test harness, display queries.
- [ ] W3.5 WinUI shell: `App`, a minimal `ConnectionWindow` (address, Connect, authentication dialog, desktop view, Disconnect); FLTK not linked.
- [ ] W3.6 Vertical slice against a loopback peer: connect, authenticate, render, type, click, disconnect; close and exit during authentication; two windows at once.
- [ ] W3.7 `apps/windows/build.py` first version: core and app, Debug and Release, x64.

Exit: the macOS N2 exit, on Windows: lifecycle, cancellation and frame ownership
proven through the real app before substantial screen work.

## W4 — Windows services

- [ ] W4.1 Stores: preferences, profiles/history, window state; schema, revision, `LockFileEx`, atomic replace, ACL check, sharing-violation retry, corruption and newer-schema recovery (D16).
- [ ] W4.2 Credentials: Credential Manager store, retention controller (use once / session / remember), replace/forget, launch credentials with Windows path rules (D15).
- [ ] W4.3 Trust: TidyVNC trust stores, legacy `x509_known_hosts` adapters for both `%APPDATA%` locations, CA/CRL path handling.
- [ ] W4.4 Documents: common file dialogs, bounded reads, atomic writes, launch routing; file dialog open during exit.
- [ ] W4.5 Registry import sources for defaults and history, read-only, feeding the core projection.
- [ ] W4.6 Clipboard adapter and coordinator: listener window, contention retry, remote-origin format, focus routing, `CanUploadToCloudClipboard = 0` on every remote-origin write (D21).
  - [ ] Manual check with cloud clipboard on: remote text appears in local history and never on a second device
- [ ] W4.7 Display service: `QueryDisplayConfig` topology, stable IDs, friendly names, change notifications.
- [ ] W4.8 Keyboard capture service: `WH_KEYBOARD_LL` thread, pass-through rules, release triggers, typed failures.
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
