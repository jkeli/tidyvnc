# Portable viewer interface handoff (for a future WinUI plan)

Updated 2026-09-23 (N6.14). This is the entry point for anyone building another
native frontend (for example WinUI) on the portable viewer core that the macOS
SwiftUI app uses. It summarizes the contracts and links to the authoritative
detail. **No Windows frontend, Windows service backend or Windows execution of the
native core is implemented or claimed.** The retained FLTK viewer remains the
Windows and Linux UI.

Authoritative references:

- C boundary: [`viewer/bridge/README.md`](../../viewer/bridge/README.md) and the
  header [`viewer/bridge/tidyvnc.h`](../../viewer/bridge/tidyvnc.h).
- Core services and ownership: [`viewer/README.md`](../../viewer/README.md) and
  [STATE-AUDIT.md](STATE-AUDIT.md).
- Parameters and precedence: [CAPABILITIES.md](CAPABILITIES.md), [CLI.md](CLI.md),
  [DOCUMENTS.md](DOCUMENTS.md).
- The macOS reference frontend: [`platform/macos/README.md`](../../platform/macos/README.md).

## Layers and dependency direction

```text
frontend (SwiftUI app / future WinUI app)
  └─ frontend platform layer (Swift TidyVNCNative / future C#/C++ layer)
       └─ tidyvnc_viewer_c        C ABI, handle registry, callback dispatcher
            └─ tidyvnc_viewer_core     sessions, listener, prompts, frames, input,
            │                          clipboard, settings grammars, documents
            └─ tidyvnc_viewer_platform socket connect/listen/transport, logging file
                 └─ rfbclient / network / rdr / core (shared with FLTK and servers)
```

The core and C targets never include FLTK, AppKit, SwiftUI, WinUI or X11.
`tests/viewer/headless.py` proves that from the generated CMake graph, and also
rejects any public-header include other than `stdint.h`/`stddef.h` or any
POSIX/Apple/Objective-C/Windows/widget or non-fixed-width type in `tidyvnc.h`.

Platform code in `viewer/platform` is POSIX (macOS and Linux). A Windows port
needs its own socket transport, connector (hostname lookup with cancellation),
listener source and private log file adapter behind the same internal interfaces
(`SessionTransport`, `ConnectionAttempt`, `ListenerSource`), plus Winsock start-up.

## C ABI conventions

- Version 1 (`TIDYVNC_ABI_VERSION`). Structs are zero-initialized with `size` and
  `version` set; unknown required feature bits are rejected. `tidyvnc_get_abi`
  advertises implemented features; check a bit before using its exports.
- Only fixed-width integers, `tidyvnc_bytes` / `tidyvnc_mutable_bytes` spans
  (pointer + 64-bit length) and opaque 64-bit handles. Text is UTF-8 without NUL,
  bounded (4096 bytes unless documented otherwise).
- Every export returns `tidyvnc_status` and never lets an exception escape. The
  optional `tidyvnc_error` carries domain, detail, native code and fixed,
  redacted text; server-provided or user-provided text is never copied into it.
- Failure, `NO_CHANGE` and `PENDING` leave outputs unchanged.
- Handles are registry IDs that are never reused. Stale, zero and wrong-kind handles
  return distinct statuses. Borrowed spans (image pixels, prompt fields, gateway
  fields) stay valid until the owning handle is released.

117 status-returning exports exist. The PLAN §4.2 command catalog maps to them as
recorded under N1.5 in [TODO.md](TODO.md).

## Session lifecycle

```mermaid
stateDiagram-v2
  [*] --> Idle: session_create
  Idle --> Resolving: connect (generation 1)
  Resolving --> Connecting
  Connecting --> Negotiating
  Negotiating --> Authenticating: prompt (credentials / certificate / host key)
  Authenticating --> Negotiating: reply
  Negotiating --> Connected
  Connected --> Disconnecting: disconnect / peer close / error
  Disconnecting --> Closed: attempt drained
  Resolving --> Failed
  Connecting --> Failed
  Negotiating --> Failed
  Authenticating --> Failed
  Closed --> Resolving: connect (next generation, reusable session)
  Failed --> Resolving: explicit Retry = connect (next generation)
  Closed --> [*]: close + poll_drained (permanent)
  Failed --> [*]: close + poll_drained (permanent)
```

- Each connect creates a new **attempt generation**. Events, frames, prompts and
  completions carry their generation; frontends must drop stale ones
  (`subscription_validate` plus their own recheck on the UI executor).
- Every admitted operation reserves its completion before admission and completes
  exactly once (succeeded, failed or cancelled). Invalid-state commands are
  rejected synchronously with a status; UI disabling is not the only defense.
- Subscriptions start with the current snapshot, so there is no subscribe/connect
  race.
- Close/shutdown never joins on the caller. `session_poll_drained` and
  `runtime_poll_drained` report joined drain; release handles only after drain.

The listener has its own lifecycle (Starting, Listening, Stopping, terminal),
bounded incoming peers with expiry, explicit accept/reject and handoff of the
accepted transport into a configured reusable session. See "Reverse listener
ownership" in the bridge README.

## Threading and callbacks

- All commands and queries are callable from any thread and never wait for
  network, authentication or decoding. Protocol work runs on per-session workers.
- One shared dispatcher delivers coalesced readiness callbacks outside all locks.
  Callbacks must enqueue UI work and return promptly; they may take events, views
  and prompts, reply, issue commands and unsubscribe.
- The frontend must serialize delivery on its UI executor, own its captures, and
  recheck subscription identity and payload generation there. The Swift reference
  is `NativeDelivery`/`NativeSession` (one coalesced MainActor task).
- Measured on macOS: MainActor stays responsive (worst 5 ms tick gap 8–11 ms)
  during a pending connect, a 768 MiB raw decode flood and shutdown under load
  (N2.8).

## Data, input and prompts

- **Frames/cursor:** immutable leases with explicit format, stride, origin, damage,
  size generation and sequence, charged to bounded budgets. Old leases survive
  reconnect and destruction. Render with the shared tile renderer, damage mapping
  and cursor sampler exports; do not copy full desktops per view.
- **Input:** bounded key/pointer mailbox with coalescing, release-all on focus loss,
  overflow and disconnect, view-only enforced in core. Keys use physical IDs plus
  RFB keysyms and optional QEMU codes; the frontend maps its keyboard.
- **Prompts:** take a prompt handle, show UI, reply with prompt ID and generation.
  Credential spans are mutable and wiped on every return. Trust replies are
  explicit decisions; the core performs verification, and the frontend owns
  exception storage.
- **Clipboard:** bounded channel with independent send/receive policy,
  focus/generation routing and remote-origin echo suppression. The frontend owns
  the OS clipboard adapter and must serialize access to it.
- **Bell:** a per-attempt counter in the snapshot. The frontend sounds it; macOS
  rings once per delivery turn.

## Settings and parameters

The core owns grammar, validation and canonical form for the command line and
connection documents: the invocation catalog, encoding/security/scaling/window
geometry/logging, DesktopSize, ports and the SSH `via` grammar
(`TIDYVNC_FEATURE_PARAMETER_GRAMMARS`). The frontend owns:

- its typed configuration model over the layer composition (compiled → app
  defaults → profile → CLI → explicit file) and the two deprecated migrations
  (DotWhenNoCursor, FullScreenAllMonitors); see `NativeOptionOverlay`. The
  precedence, migrations and provenance are also in the core
  (`tidyvnc_config_resolve`, W2 of the WinUI plan);
- platform path policy for PasswordFile and X509CA/CRL (Windows needs drive/UNC
  rules);
- stores. Their identities (credential accounts, trust scopes, SSH route and
  intent digests) are the core's `tidyvnc_identity_digest`, byte-identical to
  the macOS values, which stay pinned by regression tests.

The Windows plan moved further shared policy into the core with conformance
cases under `tests/conformance` that the macOS Swift implementations must also
pass: legacy `x509_known_hosts` lookup, legacy monitor numbering, export
losses, and the defaults/history import projection (see the bridge README,
"Shared policy for the Windows frontend"). The macOS app keeps its Swift
implementations; switching it to these exports is optional.

## Services a frontend must provide

| Service | macOS reference (injected through `AppServices`) |
| --- | --- |
| Preferences (schema, revision, serialized writes) | `NativePreferencesStore` over `NativePreferencesBacking` |
| Profiles/history (private atomic files) | `NativeProfileHistoryStore` over `NativeAtomicFileBacking` |
| Credentials (OS secret store, no plaintext fallback) | `NativeCredentialStore` over `NativeCredentialBacking` (Keychain) |
| Trust (saved decisions, read-only legacy exceptions) | `NativeTrustStore`, `NativeLegacyTrustStore` |
| Documents/files (explicit, bounded, no main-thread IO) | `NativeDocumentReading`, `NativeDocumentWriting`, `NativePasswordFileReading` |
| Clipboard | `NativePasteboardAccess` + `NativeClipboardCoordinator` |
| Displays/windows/fullscreen/input capture | `NativeDisplaySource`, `NativeFullscreenWindows`, `NativeKeyboardCapturing` |
| Tunnel (SSH gateway process) | `NativeTunnelOwning` |
| Bell, logging, help, lifecycle/quit | `NativeBellSounding`, `NativeProcessLogging`, `AppCoordinator` |
| Permission guidance | typed issues (Local Network, Accessibility via `NativeKeyboardCaptureStart`) |

Each has typed errors. The N1.9 audit in TODO.md records what is intentionally
process-wide.

### Windows semantics (decided; implemented in `platform/windows/TidyVNC.Native`)

The WinUI plan (`plans/native-ui-winui`, SERVICES.md, DECISIONS.md) settled
the open notes that used to be listed here. Contract tests are in
`tests/windows/TidyVNC.Native.Tests`; evidence is in that plan's TODO.md
(W4.1-W4.12).

- **Stores** (D16):
  - versioned JSON records (`schema`, `revision`) in `%LOCALAPPDATA%\TidyVNC`;
  - a protected owner-only DACL, plus owner and reparse checks on every
    open;
  - a `LockFileEx` writer lock and flushed temp-file `ReplaceFileW`;
  - bounded retry on sharing violations;
  - typed Corrupt, UnsupportedFields, FutureSchema, Conflict and Denied
    results;
  - explicit corrupt-record recovery, and a newer schema is never
    overwritten.

  The registry is only a read-only import source (FLTK defaults and
  history).
- **Credentials** (D15):
  - Credential Manager generic credentials under
    `TidyVNC/credentials.v1/<core digest>`, local-machine persistence, no user
    name;
  - Win32 errors map to NotFound, Unavailable (no logon session), Invalid,
    Denied and IOFailure;
  - Credential Manager never shows UI, so "interaction not allowed" holds by
    construction;
  - no plaintext fallback.

  The macOS retention controller (use once, session, remember, replace) is
  ported unchanged.
- **Paths:**
  - PasswordFile, CA/CRL and document paths take drive, UNC or `\\?\`
    paths as given;
  - plain relative paths resolve against the launch working directory (or
    the document's folder);
  - drive-relative (`C:x`) and root-relative (`\x`) forms are refused;
  - no `~`, `%VAR%` or shell expansion.
- **Launch credentials:** VNC_USERNAME and VNC_PASSWORD are captured once
  and removed from the process environment block before anything can fail,
  so child processes (ssh, askpass) never inherit them.
- **Input capture:**
  - the helper's `WH_KEYBOARD_LL` thread needs no permission, so start is
    Active or Failed;
  - the macOS capture rules (automatic once per fullscreen entry, explicit
    command, suppression after release or failure) and typed release reasons
    are kept;
  - Ctrl+Alt+Del, Win+L and elevated windows cannot be captured.
- **Clipboard:**
  - a registered `TidyVNC.RemoteOrigin` format (process, session,
    generation) replaces the private pasteboard type for echo suppression;
  - every remote-origin write also sets `CanUploadToCloudClipboard` = 0 in the
    same transaction, or is not made at all (D21);
  - a clipboard listener replaces polling;
  - `OpenClipboard` contention is retried off the UI thread.
- **Displays:**
  - stable IDs are a SHA-256 of the monitor device path, never HMONITOR or
    an index;
  - generations change only on real topology changes;
  - a failed query (all displays powered off) is a typed, empty snapshot.
- **Tunnel** (D17):
  - Windows OpenSSH has no ControlMaster, so the owner runs `ssh -W` inside a
    kill-on-close Job Object;
  - it relays ssh's standard streams to a private AF_UNIX socket that only
    this process may use, and the core's routed connect uses that socket;
  - `tidyvnc-ssh-askpass.exe` serves both `SSH_ASKPASS` and
    `KnownHostsCommand` over a per-attempt user-only named pipe;
  - new host keys are reviewed from the structured observation, and approval
    answers with the computed fingerprint;
  - configuration is a private snapshot evaluated by `ssh -G`, with
    command-running and proxy settings refused;
  - ssh.exe needs `%ProgramData%` in its environment.
- **Activation** (D8/D9):
  - shell launches share one primary process (AppInstance redirection);
  - `vncviewer.exe` launches are marked, keep their own process and never
    redirect;
  - operands containing `\` or `/` are files;
  - the Jump List uses `ICustomDestinationList` (unpackaged).
- **Lifecycle:**
  - lock and suspend release capture and held input;
  - `WM_QUERYENDSESSION` never vetoes and runs the normal shutdown with a
    block reason, bounded at `WM_ENDSESSION`;
  - no restart registration.
- **Network privacy:** there is no Local Network consent. The Windows
  Firewall prompt for listening sockets is the counterpart, covered by the
  listener guidance (SERVICES.md section 10).

## Reusable tests

- `tests/unit` (768 on macOS, 765 on Linux): core, protocol, prompts, frames,
  input, clipboard, listener, grammars and ABI boundaries (including per-position
  allocation failure and stale/wrong-kind handles). Uses only fake transports,
  schedulers and sinks, and runs unchanged on Linux.
- `tests/viewer`: `viewer-c-abi-smoke` (a pure C99 consumer of the ABI) and
  `viewer-core-smoke`.
- `tests/viewer/headless.py`: clean configure, dependency-graph and public-header
  audit, build and tests without any GUI toolkit.
- Sanitizers: the full suite passes under ASan+UBSan+LSan and TSan (Linux) and
  ASan+UBSan and TSan (macOS). The glibc resolver tests skip under TSan.
- Protocol baseline: `tests/integration/macos-scaling-smoke.py` drives an actual
  executable against a scripted RFB peer. A Windows port would need its own
  launcher and isolation.

A WinUI plan should start by making `headless.py` pass on Windows with MSVC,
implement the Windows transport/connector/listener adapters, and run the unit
suite and C smoke there before any UI work.
