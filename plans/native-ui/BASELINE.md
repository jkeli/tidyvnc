# Retained FLTK viewer baseline (N0.4)

Recorded 2026-09-23 at `dca759c1`, before any cutover. The retained FLTK
viewer is the reference that native parity (PARITY.md, N4.18) is judged
against.

## Environment

| Item | Value |
| --- | --- |
| Hardware | Mac15,10, Apple M3 Max, 14 cores, 36 GiB |
| OS | macOS 27.0 (26A428) |
| Toolchain | Xcode 27.0 (27A266a), macOS SDK 27.0, Apple clang 21.0.0, Swift 6.4, CMake 3.30.2 |
| FLTK | 1.4.5, static, pinned source tarball built into `build/hidpi-deps` |
| Other dependencies (Homebrew) | pixman 0.46.4, jpeg-turbo 3.2.0, GnuTLS 3.8.13, nettle 4.0, gettext 1.0, googletest 1.18.0 |
| Build | `build/hidpi-release`: Release (`-O3 -DNDEBUG`), arm64, Ninja, static FLTK, no explicit deployment target |

## Test and protocol results for this build

- **Unit tests:** 796/796 (`ctest --test-dir build/hidpi-release/tests/unit`).
- **Viewer tests:** 3/3 (`ctest --test-dir build/hidpi-release/tests/viewer`).
- **Protocol/lifecycle baseline:** 55/55 through the FLTK viewer
  (`tests/integration/macos-scaling-smoke.py … --frontend fltk`). The native app
  passes the same 55 cases.
- **Performance:** matched FLTK/native workloads and presentation latency are
  in [PERFORMANCE.md](PERFORMANCE.md).

## Screenshots

Captured by `tests/macos/fltk-baseline.py <vncviewer> <dir>`. It runs the viewer
with fresh HOME/XDG roots against `native-security-peer` fixtures and captures
only the viewer's own windows with `screencapture -l`. No input is sent.
Window metadata is in [baseline/baseline.json](baseline/baseline.json).

| State | Image | Title | Default action and focus |
| --- | --- | --- | --- |
| Connection dialog (no arguments) | [fltk-server-dialog.png](baseline/fltk-server-dialog.png) | TidyVNC | Connect is the Return default; focus is in "VNC server" |
| Connected desktop (64×48 fixture) | [fltk-desktop.png](baseline/fltk-desktop.png) | security fixture - TidyVNC | — |
| VncAuth password prompt | [fltk-password-dialog.png](baseline/fltk-password-dialog.png) | VNC authentication | OK is the default; focus is in Password; red "This connection is not secure" banner; "Keep password for reconnect" |
| Untrusted certificate (X509None) | [fltk-certificate-dialog.png](baseline/fltk-certificate-dialog.png) | Unknown certificate issuer | **Cancel** is the default; subject, issuer, serial, key, validity and pin-sha256 shown; "Add exception" |
| Connection refused | [fltk-connection-refused.png](baseline/fltk-connection-refused.png) | TidyVNC | **Yes** (reconnect) is the default of "Attempt to reconnect?" |

## Observed differences to review for parity

- **Refused connection.** FLTK defaults to reconnecting ("Yes"). The native
  alert makes Cancel the default, with a separate Retry.
- **Certificate prompt.** Both default to Cancel. FLTK offers "Add exception"
  (saved). The native sheet separates Connect Once from a confirmed Save
  Exception and Connect….
- **Password prompt.** FLTK offers a single "Keep password for reconnect"
  toggle. The native sheet has three retention choices (use once, this
  session's reconnect, remember on this Mac).

These are listed for the N4.18/N6.13 review; each needs to be recorded as an
intentional difference or resolved.

## Not captured

- **Options dialog and interactive behaviour.** The options dialog tabs, menus
  (F8), fullscreen, and keyboard/focus traversal beyond the defaults above
  require synthetic or physical input. Access for such a pass was declined in
  this session.
- **Other hardware.** No second machine, Intel or macOS 14 host.
