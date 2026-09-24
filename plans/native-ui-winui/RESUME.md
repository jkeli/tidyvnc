# Resume point: Windows native UI (WinUI 3)

Checkpoint 2026-09-24. TODO.md holds the task list and the dated evidence log; this
file says where things stand and how to run everything.

## State

The WinUI 3 viewer (`apps/windows/TidyVNC`) runs on the MSVC-built core
(`tidyvnc_viewer.dll`) and the C++ helper (`platform/windows/Native`), through
`platform/windows/TidyVNC.Native`. Every W5 screen exists, and W6 fidelity work is under way:

- rendering, cursors, keyboard, pointer, pen and touch;
- release-all and device loss;
- the protocol and security smokes.

The W7 package stage produces an audited per-user MSI. Items stay unchecked in TODO.md until
their remaining checks run. These are mostly the following, and each item lists its own:

- display-dependent UI tests (the owner's single display was powered off during this work);
- hands-on keyboard, Narrator and contrast passes;
- hardware: mixed-DPI, touch, pen, ARM64;
- a clean VM or test account: installing, FLTK comparisons, relocated GUI start;
- owner reviews.

Checked or decided so far: W1–W4 (with named exceptions), W7.8 (Native AOT not adopted yet; see
DECISIONS.md D1).

## Owner-dependent items

- ARM64: install the Visual Studio component "MSVC v143 C++ ARM64/ARM64EC build tools".
  That needs an elevated installer change, which was not made.
- Signing identity (D23).
- VMs or a test account for installed-app acceptance (W7.3–W7.7, W7.10).
- W0.13 and W7.11 reviews.
- An SSH server for the tunnel smoke. None is installed, and installing one needs approval.

## Commands

```bat
rem Core (and tests), then the app, then the audited MSI
python apps\windows\build.py --configuration Debug --test
python apps\windows\build.py --configuration Debug --stages app
python apps\windows\build.py --configuration Release --stages package

rem .NET tests (four stuck test processes from an earlier session lock the default output; use -o)
dotnet build tests\windows\TidyVNC.Native.Tests -c Debug -p:Platform=x64 -o <dir>
dotnet exec <dir>\TidyVNC.Native.Tests.dll

rem UI automation and smokes: only with TIDYVNC_UI_TESTS=1 and an idle desktop (never TIDYVNC_UI_TESTS_FORCE)
dotnet test --project tests\windows\TidyVNC.UITests -c Debug -p:Platform=x64
python tests\integration\windows-scaling-smoke.py build\winui\app-x64-debug\vncviewer.exe
python tests\integration\windows-security-smoke.py build\winui\app-x64-debug\vncviewer.exe --accept-prompts
python tests\perf\windows-viewer-workloads.py --winui build\winui\app-x64-debug\vncviewer.exe

rem Strings and pseudo-locales
python apps\windows\strings.py audit
python apps\windows\strings.py pseudo
```

The retained FLTK viewer builds in `build/mingw/viewer` with MSYS2 MINGW64
(`make`, then `ctest --test-dir tests/unit`). Its known state is 655/659, with the same 4
failures since the planning checkpoint.

## Rules that stay in force

- Never push; hosted CI stays off.
- Commits end with the Co-Authored-By line.
- Tests never touch real user data. They use `TIDYVNC_STATE_ROOT` in Debug builds, disposable
  `HKCU\Software\TidyVNC-test-*` keys and test Credential Manager prefixes, and they restore the
  clipboard.
- Do not install into the owner's account.
- Do not accept EULAs.
- Do not change system settings.
