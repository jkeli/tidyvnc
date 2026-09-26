# Windows native UI (WinUI 3)

Plan for a native Windows TidyVNC viewer built with WinUI 3 on the portable core
and C ABI that the macOS SwiftUI app already uses. Created 2026-09-23 at commit
`6972f720`. **Status (2026-09-24): implemented through W5 and much of W6 and W7;
[RESUME.md](RESUME.md) has the checkpoint, what remains open and the exact commands.**

## Read in this order

1. [PLAN.md](PLAN.md): outcome, scope, architecture, phases W0–W7, risks.
2. [DECISIONS.md](DECISIONS.md): the 23 decisions, what confirms each one, and
   the owner's choices.
3. [UX.md](UX.md): what the app looks like on Windows and how it stays familiar
   to macOS users.
4. [PARITY.md](PARITY.md): every macOS parity row mapped to WinUI, plus 20
   Windows-only rows.
5. Detail by area: [CORE.md](CORE.md) (MSVC build, Windows adapters, shared
   policy), [SERVICES.md](SERVICES.md) (stores, credentials, trust, clipboard,
   displays, SSH, activation), [DESKTOP.md](DESKTOP.md) (rendering, DPI, input,
   fullscreen), [PACKAGING.md](PACKAGING.md) (build, MSI, signing),
   [TESTING.md](TESTING.md) (verification).
6. [TODO.md](TODO.md): the task list and evidence log.

## Background

- The macOS work and its shared contracts: [plans/native-ui](../native-ui/PLAN.md),
  especially the [handoff for a WinUI plan](../native-ui/HANDOFF.md).
- The C ABI: [viewer/bridge/README.md](../../viewer/bridge/README.md) and
  [tidyvnc.h](../../viewer/bridge/tidyvnc.h).
- The macOS reference frontend: [platform/macos/README.md](../../platform/macos/README.md)
  and [apps/macos/TidyVNC](../../apps/macos/TidyVNC).

## Where to start work

Begin with W0 in TODO.md. The owner decisions are recorded (2026-09-23): Windows
11 only, no audio, per-user install, unsigned for now, no updater yet, and remote
clipboard text kept out of Windows cloud clipboard sync. Installing vcpkg, WiX
and MSYS2 is approved, so the first step is installing them and recording
versions. Then run spikes W0.2 (WinUI/.NET interop) and W0.3 (MSVC core build),
because every later phase depends on them.

Hosted CI runs the Windows workflows (D25); nothing is pushed without the owner.
Record every result in TODO.md's evidence log. When work starts, add a
`RESUME.md` here, as the macOS folder has, holding the current checkpoint and
exact commands.
