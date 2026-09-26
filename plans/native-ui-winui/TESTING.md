# Windows verification

Recorded 2026-09-23. The evidence rules from the macOS plan apply unchanged:

- A test proves only its own assertions. A green model test is not window,
  keyboard, Narrator, installed-app or physical-hardware acceptance.
- A check that cannot run here (hardware, signing identity, another Windows
  version) stays open with a note. It is never counted as passed.
- Tests never read, change or clear the user's real settings, Credential Manager
  entries, registry keys, trust files or clipboard history.
- Hosted CI (D25) runs the core and .NET suites, the string audit, the unsigned
  package and the ARM64 cross-build. Everything else runs locally through scripts
  that write a `summary.json` into a new `build/winui/verification/run-<id>/`
  directory, and TODO.md records the run ID, commit and machine.

## 1. Test layers

| Layer | What | Tool | Phase |
| --- | --- | --- | --- |
| Core | `tests/unit` under MSVC x64, including the new Windows adapter tests | CTest | W1 |
| ABI | `viewer-c-abi-smoke` (static) and a DLL-loading C smoke; export list check | CTest | W1 |
| Build boundary | `tests/viewer/headless.py` in Windows mode | Python | W1 |
| Sanitizer | Core and unit suite with `/fsanitize=address`; Linux TSan for shared code | CTest | W1 |
| Conformance | Shared corpus through the core and through the Swift implementations | CTest + macOS native suite | W2 |
| Interop | C# declarations match `tidyvnc.h` struct sizes and offsets; every export callable | MSTest | W3 |
| Library | `TidyVNC.Native` sessions, listener, delivery, drain, prompts, frames, input, clipboard routing, stores, credentials, trust, imports, documents, tunnel owner; real loopback peers where the macOS tests use them | MSTest | W3–W4 |
| UI thread | View models and controls that need the dispatcher (drafts, dialog queue, focus routing) | MSTest WinUI test app | W4–W5 |
| UI automation | The actual app with an isolated state root, driven through UI Automation | FlaUI (UIA3) | W5–W7 |
| Accessibility | Automated scans of every reachable window and dialog | Axe.Windows | W5 |
| Protocol | 55-case baseline and security/tunnel/reconnect smokes through the real executables | Python harness | W6 |
| Performance | Matched FLTK and WinUI workloads | Python harness, PresentMon/ETW | W6 |
| Package | Dependency audit, relocation run; signature verification once signing exists (D23) | Python | W7 |
| Installed | Install/upgrade/repair/uninstall and OS integration | Manual + scripts | W7 |

## 2. Isolation

- **State root.** Debug and test builds honour `TIDYVNC_STATE_ROOT`, which moves
  the store directory (`%LOCALAPPDATA%\TidyVNC`), the Credential Manager target
  prefix (`TidyVNC-test-<run>/…`), the registry import root (a test key under
  `HKCU\Software\TidyVNC-Test\<run>`) and the log path. Release builds compile
  this out, and the package audit checks the Release binary ignores it. Windows
  resolves known folders from the registry, not environment variables, so
  changing `%LOCALAPPDATA%` for a child process would not isolate it.
- **Credential Manager tests** create entries with unique per-run targets and
  delete exactly those, including after failures.
- **Clipboard tests** save and restore the clipboard around each case and run
  one at a time. Tests that check D21 inspect the formats written, and never
  sign in to a Microsoft account or rely on a second device, except in the
  manual W4.6 check.
- **Displays.** Topology tests use the helper's injectable snapshot source;
  physical display checks are manual.

## 3. UI automation

- Tests find controls by `AutomationId`, which equals the macOS accessibility
  identifier, so a test case can name the same control on both platforms.
- The suite covers each PARITY row's automatable part: Enter and Escape on every
  dialog, tab order and focus visibility, menus and accelerators with focus
  outside the desktop, the desktop swallowing accelerators when focused, the
  dialog queue priority, window close and exit with pending work, and the
  File > Exit path while a file dialog is open.
- Interactive checks that need a person or on-screen observation (Narrator
  speech, contrast appearance, physical input) are recorded in a Windows
  `UI-ACCEPTANCE.md` log, created with the first observation, in the same dated
  format as the macOS log. Automated computer-use sessions on this machine may
  help with observation when the owner grants access, and are recorded the same
  way.

## 4. Accessibility

- Axe.Windows scan of every window, dialog and page reachable in the automation
  suite; zero errors required. Record results in JSON beside the macOS audit.
- Keyboard-only pass of every PARITY row.
- Narrator pass: labels, roles, values, live status announcements, the desktop
  view's Scroll pattern, dialogs, and Narrator commands while the keyboard is
  captured.
- Each Windows contrast theme, light and dark, 225% text size, and pseudo-locales
  `qps-ploc` (expansion) and `qps-plocm` (mirrored) at every window's minimum size.

## 5. Protocol, security and tunnel harnesses

- **Baseline.** Port `tests/integration/macos-scaling-smoke.py` to
  `tests/integration/windows-scaling-smoke.py`: the same scripted RFB peer and 55
  cases (eight scaling modes × three filters × two unit choices, cursor and resize
  cases), with window capture through `PrintWindow` or Windows.Graphics.Capture
  and process launch through the CLI launcher. Run it against the FLTK MinGW
  build and the WinUI build.
- **Security.** Port the security smoke (VncAuth, TLS, CA-trusted X.509, all RSA-AES
  variants) and its test peer to Windows. Certificate trust cases (Connect once,
  saved decision reused, Forget re-prompts) run through UI automation.
- **Tunnel.** A loopback `sshd` is needed. Options: the Windows OpenSSH Server
  optional feature (needs administrator rights to install; the owner decides) or
  an `sshd` in a local container. Cover agent, key, password and passphrase
  prompts, new and changed host keys, cancellation and process-tree cleanup.
- **Reconnect and failures.** Refused port, DNS failure, timeout, peer
  disappearance, Retry scoping, AlertOnFatalError.

## 6. Baseline screenshots

Repeat the macOS BASELINE.md comparison on Windows: window-only captures of the
FLTK Windows viewer and the WinUI app in the same five states (connection window,
connected desktop, password prompt, untrusted certificate, connection refused),
at 100% and 150% scale, light and dark. Differences go into PARITY.md, either as
fixes or as intentional differences for owner review.

## 7. Physical and manual matrix

| Area | Cases |
| --- | --- |
| Displays | One monitor at 100%, 125%, 150%, 175%; two monitors at different scales; hot-plug during full screen; portrait monitor; negative-origin arrangement |
| Keyboard layouts | US, UK, German, French (AZERTY), Swiss German, Spanish, Japanese (with IME), Korean (with IME), Simplified Chinese IME, Dvorak |
| Keys | AltGr combinations, dead keys, NumLock/numpad, Pause, Print Screen, media keys, key repeat, Shift release, Windows key and Alt+Tab with and without capture |
| Pointer | Mouse with five buttons, high-resolution wheel, precision touchpad, pen, touch screen (all gestures in DESKTOP.md §6) |
| OS | Windows 11 x64 (this machine, 25H2) and a second serviced Windows 11 release (24H2) in a VM; Windows 11 ARM64; installer refusal on Windows 10 (once) |
| Install | Per-user install, upgrade, repair and uninstall as a standard user; a second Windows user on the same machine |
| Environment | Running inside a Remote Desktop session; switching users; sleep/wake; lock/unlock; network change |

## 8. Running everything

`tests/windows/verify.py` builds (or takes an existing build), runs every
automated layer in §1 that applies to the build, and writes the summary. Options
select Debug/Release, architecture, ASan, the protocol harness and the package
checks. The hosted workflow (D25) runs the layers that need no interactive
desktop.
