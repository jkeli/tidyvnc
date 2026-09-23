# Core and C ABI on Windows

Recorded 2026-09-23. This covers phases W1 (core on Windows) and W2 (shared
policy extraction). The portable contracts are defined in
[viewer/bridge/README.md](../../viewer/bridge/README.md),
[viewer/README.md](../../viewer/README.md) and the
[handoff](../native-ui/HANDOFF.md); nothing here changes their meaning.

## 1. Current state on Windows

- `viewer/core` is C++11 using the standard library, `std::thread` and
  `steady_clock`. The existing Windows branches are small: Winsock includes in
  `core/Endpoint.cxx` and `x11 = false`, `tunnel = false` in
  `core/Invocation.cxx`.
- `viewer/platform` has no Windows code. On Windows the target contains only
  `DisplayMetrics.cxx` (`viewer/CMakeLists.txt`), and the bridge reports connect,
  routed connect, the listener and process/file logging as unsupported
  (`bridge/tidyvnc.cxx` guards on `__APPLE__ || __linux__`).
- All three viewer targets are static libraries with no export annotation.
- `CMakeLists.txt` refuses MSVC and sets GCC-only flags (`-std=gnu++11`,
  `-Wsuggest-override`, `-Werror` in Debug, `_FORTIFY_SOURCE`) and
  `_WIN32_WINNT=0x0601`.
- The MinGW Windows CI definition builds the FLTK viewer and runs most of
  `tests/unit`, including the session worker, protocol session and ABI parsing
  tests. `certificatekey` and `clienttls` are excluded on Windows. The
  `tests/viewer` tests are built but not run, and `c-abi-smoke.c` would fail
  because it requires `TIDYVNC_FEATURE_LISTENER` unconditionally.

## 2. Toolchain and CMake changes (W1.1–W1.3)

- Replace the unconditional MSVC rejection with targeted rules. MSVC is refused
  only when a target that needs MinGW is enabled: the FLTK viewer (for now) and
  the Windows server under `win/`. `TIDYVNC_UI=WINUI` and core-only headless
  builds require MSVC.
- Add `WINUI` to `cmake/ViewerFrontend.cmake`: valid only on Windows, sets
  `BUILD_WINUI_VIEWER`, never discovers or links FLTK, and fails clearly if the
  compiler is not MSVC. The .NET app itself is not built by CMake; CMake builds
  and installs the native DLLs, and `apps/windows/build.py` drives the rest
  (PACKAGING.md §2).
- Put GCC-style flags behind `if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang" AND NOT MSVC)`.
  For MSVC use `/std:c++17` (MSVC has no C++11 mode; the code must stay C++11-clean
  for GCC and Clang, which `headless.py` on Linux keeps checking), `/utf-8`,
  `/W4` with an agreed suppression list, `/WX` in Debug once clean,
  `/permissive-`, `/Zc:__cplusplus`, `/guard:cf`, `/Qspectre` where supported,
  `/CETCOMPAT` on x64, `NOMINMAX`, `WIN32_LEAN_AND_MEAN`, `UNICODE`, `_UNICODE`.
- Raise `_WIN32_WINNT` to `0x0A00` for the WinUI configuration only (the value
  covers Windows 10 and 11; the app supports Windows 11 only, D6, and the core
  needs nothing newer than Windows 10 APIs);
  the FLTK MinGW configuration keeps its current value.
- Keep asserts in Release as the existing build does (`-UNDEBUG` becomes `/UNDEBUG`
  in the MSVC flag set).
- ARM64: cross-compile from x64 with the MSVC ARM64 tools (`-A ARM64` or a Ninja
  toolchain file). Running ARM64 tests needs ARM64 hardware or a VM (W7).

## 3. Dependencies (W1.2)

`vcpkg.json` at the repository root, in manifest mode with a pinned
`builtin-baseline`, listing zlib, libjpeg-turbo, pixman, gmp, nettle and gnutls.
Triplets `x64-windows` and `arm64-windows` (dynamic). CMake finds them through the
vcpkg toolchain file; `build.py` checks the baseline and the resolved versions
and records them.

Fallback (DECISIONS.md D3): if GnuTLS or nettle fail under MSVC for either
architecture, build GnuTLS, nettle and GMP with MSYS2 UCRT64 clang as DLLs,
generate import libraries with `llvm-dlltool` or `lib /def`, and link them from
the MSVC core. Record the MSYS2 package versions and their licence files.

Either way, the dependency DLLs are shipped next to the app and audited
(PACKAGING.md §5). H.264 stays off in the first build (D19); the existing Media
Foundation decoder can be enabled later without new dependencies.

## 4. ABI changes for Windows (W1.4)

All changes are additive. `TIDYVNC_ABI_VERSION` stays 1; new behaviour gets new
feature bits.

| Change | Detail |
| --- | --- |
| Export macro | `TIDYVNC_API` in `tidyvnc.h`: `__declspec(dllexport)` when building the DLL, `__declspec(dllimport)` for C consumers on Windows, default visibility elsewhere. `headless.py`'s header audit learns to accept exactly this macro |
| DLL target | New `tidyvnc_viewer_shared` target producing `tidyvnc_viewer.dll` from the three static libraries, exporting only `tidyvnc_*`. A post-build check (`dumpbin /exports`) compares the export list with the header |
| Feature bits on Windows | `TCP_UNIX_CONNECT` (TCP always; Unix only if D18 passes), `LISTENER`, `ROUTED_CONNECT`, `PROCESS_LOGGING`, `FILE_LOGGING` are advertised once the adapters in §5 pass their tests |
| Paths | UTF-8 path spans (CA/CRL files, log file) are converted to UTF-16 and accepted when absolute: drive-letter (`C:\…`) or UNC (`\\server\share\…`, `\\?\…`). The "must start with `/`" rule applies only on POSIX. GnuTLS opens CA/CRL files with narrow C paths (`common/rfb/CSecurityTLS.cxx`), so W1.9 chooses between the UTF-8 active code page in the app manifest (which makes those narrow paths UTF-8 process-wide) and reading the file in the platform layer and passing it to GnuTLS from memory. Either way, non-ASCII and long paths must pass tests |
| Default log path | Retained FLTK behaviour: `%TMP%`, `%TEMP%`, then `%USERPROFILE%`, file `vncviewer.log`. The host passes it explicitly through `logging_configure_with_file`, as macOS passes `/tmp/vncviewer.log` |
| Stdio log routes | A GUI-subsystem process may have no valid stdout/stderr. `stderr`/`stdout` routes write to the attached console handle when present and are discarded otherwise; the CLI launcher (D9) forwards the GUI process's console output |
| Native error codes | `native_error` carries WSA or Win32 codes with a domain value that says so, never mixed with errno values |
| Error categories | Winsock and `GetAddrInfoExW` failures map to the existing categories (DNS, refused, routing, timeout, policy suspicion, …) in the platform adapter, so the frontend sees the same structured failures as on macOS |
| Routed stream transport | Only if D17 selects `ssh -W`: a way to hand the core a connected byte stream backed by process pipes instead of a socket, with the same routed-target, cancellation and drain contract as `session_connect_routed`. One new feature bit, one export |

## 5. Windows platform adapters (W1.5–W1.9)

New files in `viewer/platform/windows/`, implementing the existing internal
interfaces (`SessionTransport`, `ConnectionAttempt`, `ListenerSource`,
`SessionWakeup`/`MailboxWakeup`) so nothing above them changes.

| Adapter | Windows implementation | Tests |
| --- | --- | --- |
| Winsock start-up | Existing `std::call_once` path in `network/Socket.cxx`; the DLL never calls `WSACleanup` while workers run | Load/unload with a live runtime |
| Wakeup | An auto-reset event per worker instead of the POSIX pipe | Wake coalescing, shutdown |
| Established transport | `WSAEventSelect` for `FD_READ`, `FD_WRITE`, `FD_CLOSE` plus the wake event, waited with `WSAWaitForMultipleEvents`. `FD_CLOSE` gives the peer-closure observation that macOS gets from kqueue and Linux from `POLLRDHUP`. Sockets are created with `WSA_FLAG_NO_HANDLE_INHERIT`. The POSIX `FD_SETSIZE` check does not apply | Peer FIN during authentication, write back-pressure, cancellation, drain |
| Connector | `GetAddrInfoExW` with overlapped completion and `GetAddrInfoExCancel` for cancellable lookups; IPv4/IPv6 policy through hints; nonblocking `connect` completed through `FD_CONNECT`; scope IDs via `if_nametoindex` (iphlpapi) | Ordered resolving/connecting states, cancel during each stage, family policy, numeric-only rejection, typed failures |
| Unix sockets | `AF_UNIX` via `afunix.h` (Windows 10 1803+), if D18 accepts it | Path classification, connect, cancel |
| Listener | `SO_EXCLUSIVEADDRUSE` (not `SO_REUSEADDR`), `IPV6_V6ONLY`, nonblocking accept, bounded pending peers, handoff into sessions | The existing listener contract tests, run on Windows |
| Private log file | `CreateFileW` with an owner-only DACL, `LockFileEx` on a sidecar lock file, rotation with one backup through `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`, reparse points refused. Unsafe or unwritable files fall back to redacted stderr, as on macOS | Lock ownership across processes, rotation after owner exit, ACL check |

Audit item: the shared `network` library stores sockets as `int`. Windows
`SOCKET` is pointer-sized. Values fit in practice, but the new adapters keep
`SOCKET` in their own types and convert once, with a checked conversion, where
they meet the shared code. The public ABI already exposes no socket handles.

## 6. Shared policy extraction (W2)

[PLAN.md §6](PLAN.md) gives the rule. The work items, each a new core module
with additive exports and tests built from the Swift test vectors:

| Module | Content | Exports (sketch) |
| --- | --- | --- |
| `ConfigurationLayers` | Resolve the five layers (compiled, app defaults, profile, CLI, explicit file) from canonical parameter assignments, each tagged with its source; apply DotWhenNoCursor and FullScreenAllMonitors migrations after the overlays; record per-field source and migration notes; keep dormant values | `config_resolve` returning a result handle; `config_value_at`, `config_note_at` |
| `IdentityDigest` | Versioned, length-prefixed SHA-256 digests for credential identity, gateway route/intent and trust scope, over canonical endpoint and gateway fields. Uses a small internal SHA-256 with FIPS 180-4 test vectors so it works in builds without nettle | `identity_digest(kind, fields)` |
| `ImportProjection` | The allow-list of importable parameters, conversions, omissions with reasons, deprecated migrations, legacy monitor-number handling, and the 20-entry history dedupe. Inputs are (name, raw value, origin) triples from any source: XDG lines on macOS, registry values on Windows | `import_project_defaults`, `import_project_history` |
| `LegacyKnownHosts` | Parse `x509_known_hosts` and match hosts, read-only | `known_hosts_parse`, `known_hosts_match` |
| `LegacyMonitorNumbering` | Number displays the way the retained viewer does (by x, then y) for file import/export mapping | `legacy_monitor_order` |
| `ExportLoss` | For canonical parameters, which values a compatibility file cannot represent and why | `export_losses` |

Conformance: a shared corpus of JSON cases under `tests/conformance/` runs through
the core in `tests/unit` and through the Swift implementations in the macOS
native suite. Any difference fails both. The Swift app is not changed to call the
new exports in this plan; that is an optional macOS follow-up.

## 7. Tests on Windows (W1.10–W1.12)

- **Unit suite.** Build and run `tests/unit` under MSVC for x64. Enable the
  POSIX-only groups as their Windows adapters land (socket, listener, logger,
  `viewerabi`, `listenerabi`, process logging). Re-enable `certificatekey` and
  `clienttls` once GnuTLS works under MSVC, or record why not.
- **Viewer tests.** Make `c-abi-smoke.c` check the listener only when the feature
  bit is advertised, then run `ViewerCore.HeadlessConsumer` and
  `ViewerABI.PureCConsumer` on Windows. Add a C smoke that loads
  `tidyvnc_viewer.dll` dynamically, so the DLL export list is exercised the way
  .NET will use it.
- **`headless.py`.** A Windows mode: configure with MSVC and `BUILD_VIEWER=OFF`,
  audit the CMake graph for FLTK/WinUI/.NET, audit the public header (now allowing
  `TIDYVNC_API`), build and run ctest.
- **Sanitizers.** An MSVC AddressSanitizer build (`/fsanitize=address`) of the
  core and tests. MSVC has no thread sanitizer; the Linux TSan run stays the race
  check for shared code, and new Windows adapter code gets targeted stress tests.
- **FLTK MinGW.** The MinGW build and its unit run still pass after every W1/W2
  change. This machine has no MSYS2; install it for this check (W0.1) or run it
  in a separate environment, and record which.

## 8. Exit criteria

W1 is complete when, on this machine with MSVC for x64 (and a successful ARM64
cross-build):

1. `headless.py` passes in Windows mode.
2. The unit suite passes, including the Windows adapter tests, with any remaining
   exclusions listed and justified.
3. The C smoke passes both statically linked and against the loaded DLL.
4. A loopback connect, VNC authentication, TLS handshake, frame receipt,
   disconnect and drain succeed through the DLL from a C test program.
5. The ASan build passes the unit suite.
6. The FLTK MinGW build and unit run still pass.

W2 is complete when every module in §6 passes its core tests and the Swift
conformance run on macOS, and PARITY rows that depend on them reference the new
exports.
