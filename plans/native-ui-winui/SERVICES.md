# Windows platform services

Recorded 2026-09-23. Phase W4. Each service is the Windows implementation of a
macOS service listed in the [handoff](../native-ui/HANDOFF.md) ("Services a
frontend must provide"). The C# types keep the macOS names so the two can be
compared file by file.

## 1. Rules shared by every service

- Every asynchronous operation takes a cancellation token and completes exactly
  once with a typed result: `Succeeded`, `Unsupported`, `Unavailable`,
  `NotFound`, `Denied`, `Cancelled`, `Invalid`, `Conflict` or `IOFailure`.
  Cancellation is never an empty success. Win32/HRESULT codes go into diagnostic
  metadata, never into user-visible text.
- No file, registry, Credential Manager or process IO on the UI thread.
- Results that arrive after their window closed, their generation changed or the
  app began shutting down are discarded, not applied.
- Diagnostics are redacted: no passwords, no server-provided text, no file
  contents, no full paths in logs.
- Tests use isolated roots (temporary directories, a test registry hive path, a
  unique Credential Manager target prefix) and never touch the user's data.

## 2. Stores (preferences, profiles/history, trust)

**Location.** `%LOCALAPPDATA%\TidyVNC\` (local, not roaming; DECISIONS.md D16):

```text
%LOCALAPPDATA%\TidyVNC\
  preferences.json          app defaults (macOS: UserDefaults record)
  profiles-history.json     saved profiles and recent connections
  trust\certificates.json   X.509 decisions   (macOS: native-trust x509-spki)
  trust\server-keys.json    RSA-AES server keys (macOS: native-trust rsa-aes)
  window-state.json         window placement only, separate from settings
  *.lock                    writer lock files
```

**Format.** UTF-8 JSON with a `schema` number and a `revision` UUID, using
`System.Text.Json` source generation. The Windows schemas start at 1 and are
documented beside the code. They carry the same fields as the macOS records
(`NativePreferencesModels`, `NativeProfileHistoryStore`, `NativeTrustStore`) but
are not required to be byte-compatible, since the stores are never shared
between platforms.

**Writes.**
1. Take the writer lock with `LockFileEx` on the store's `.lock` file (shared by
   every TidyVNC process; D8 allows several).
2. Re-read the current record and compare its revision with the caller's; a
   mismatch returns `Conflict` and the UI offers reload, as on macOS.
3. Write the new record to a temporary file in the same directory, call
   `FlushFileBuffers`, then replace the target with `ReplaceFileW` (or
   `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH` when the
   target does not exist yet).
4. Release the lock.

Antivirus scanners, backup tools and the search indexer briefly hold files open
on Windows, so a sharing violation during replace is retried a bounded number of
times with a short backoff before returning `IOFailure`. Temporary files left by
a crash are removed on the next write.

**Access control.** The `TidyVNC` directory and its files get a protected DACL
granting full control to the current user and SYSTEM only, the Windows
counterpart of macOS 0700/0600. The store checks the DACL and owner when opening
and reports `Denied` if another user could write the file, rather than trusting
it. Reparse points (symbolic links, junctions) inside the store are refused.

**Recovery.** A corrupt record is not treated as absent: the UI shows the
recovery choices the macOS app shows (retry, use built-in defaults for this
connection). A record with a newer schema opens read-only with an error and is
never overwritten. Transient errors and permission guesses are never persisted.

## 3. Credentials

**Store.** Windows Credential Manager, generic credentials (`CredWriteW`,
`CredReadW`, `CredDeleteW`, `CredEnumerateW` through CsWin32), as decided in
DECISIONS.md D15:

| Field | Value |
| --- | --- |
| `Type` | `CRED_TYPE_GENERIC` |
| `TargetName` | `TidyVNC/credentials.v1/<digest>`; the digest comes from the core's credential identity (CORE.md §6) |
| `Persist` | `CRED_PERSIST_LOCAL_MACHINE` (this user, this machine; never roams) |
| `UserName` | Empty (the VNC user name is part of the digest, not stored in clear) |
| `CredentialBlob` | The UTF-8 password bytes, at most `CRED_MAX_CREDENTIAL_BLOB_SIZE` (2560 bytes) |
| `Comment` | Fixed text: `TidyVNC saved password` |

**Result mapping.**

| Windows result | Service result |
| --- | --- |
| Success | `Succeeded` |
| `ERROR_NOT_FOUND` | `NotFound` |
| `ERROR_NO_SUCH_LOGON_SESSION` (no loaded profile, for example `runas /netonly`) | `Unavailable` |
| `ERROR_INVALID_PARAMETER`, oversize blob | `Invalid` |
| `ERROR_ACCESS_DENIED` | `Denied` |
| Anything else | `IOFailure` with the code in diagnostics |

Credential Manager never shows UI, so the macOS "interaction not allowed"
policy is met by construction and "interaction required" never occurs. There is
no locked state while the user is signed in.

**Behaviour matching macOS.** The authentication dialog offers *Use once*,
*Retain for this session's reconnect* and *Remember on this PC*. Nothing is saved
until authentication succeeds with the "remember" choice. Replacing needs the
explicit *Replace an existing saved password* toggle. A rejected saved password
is never retried or deleted automatically. A save failure is a notice, not a
connection failure, and never falls back to a file. Reverse connections never
offer "remember". The macOS app has no credential-management window; neither does
this one. Users can see the entries in Control Panel > Credential Manager under
the fixed comment, and the store tolerates entries deleted there.

**Threat model (shown in Help).** DPAPI encrypts the entries for the user, but any
program running as that user can read them. This is the same protection the
Remote Desktop client uses. It is weaker than a macOS Keychain item with per-app
access, and the Help text says so plainly.

**Secret handling in C#.** The password travels from `PasswordBox.Password` (a
`string`, which WinUI provides and which cannot be wiped) into a pinned UTF-8
buffer that is passed to the core or Credential Manager and cleared immediately.
The `PasswordBox` is cleared when the dialog closes. The remaining managed string
lives until garbage collection; this limit is documented, not hidden.

**Launch credentials.** `VNC_PASSWORD` and optional `VNC_USERNAME` are captured at
process entry and cleared from the environment block; `PasswordFile` (alias
`passwd`) is read once by a bounded reader (one regular file, the first 8 bytes,
no reparse points). Windows path rules apply: absolute drive or UNC paths as
given; relative paths resolve against the working directory captured at launch;
no `~`, `%VAR%` or shell expansion. Ownership, precedence and first-window rules
are the macOS ones in [CREDENTIAL-INPUTS.md](../native-ui/CREDENTIAL-INPUTS.md).

## 4. Documents and file dialogs

- **Dialogs.** The Common Item Dialog (`IFileOpenDialog`, `IFileSaveDialog`)
  through CsWin32, owned by the requesting window's HWND. This gives what the
  WinUI picker wrappers do not: an OK button label (*Review* for Open connection
  file, as on macOS), `FOS_OVERWRITEPROMPT`, default extension `.tidyvnc`,
  file-type filters (TidyVNC connection `*.tidyvnc`; TigerVNC connection
  `*.tigervnc`; all files) and plain paths instead of `StorageFile` objects.
- **Nested loop.** `Show` runs a modal loop on the UI thread. Core delivery
  continues inside it, so delivery code must be reentrancy-safe (it already
  coalesces and rechecks generations). File > Exit and session end while a dialog
  is open close the dialog as cancelled before shutdown continues. This is the
  Windows form of the macOS "Command-Q while the Save panel is open" gap, and W5
  tests it explicitly.
- **Reads.** Background, bounded (the shared document size limit), regular files
  only, reparse points refused, then parsed by the shared codec. The window
  shows the review page before any session is created.
- **Writes.** The same atomic replace as the stores (§2), with the overwrite
  decision taken in the dialog and a conflict check if the file changed after
  review.
- **Relative paths** inside connection files (CA/CRL) resolve against the file's
  directory, as on macOS, using Windows path rules.

## 5. Trust

- **Stores.** `trust\certificates.json` and `trust\server-keys.json` (§2), holding
  destination-scoped decisions with the same kinds, capacity (256) and matching
  rules as the macOS `NativeTrustStore`.
- **Legacy input (read-only).** `%APPDATA%\TidyVNC\x509_known_hosts` (current FLTK)
  and `%APPDATA%\TigerVNC\x509_known_hosts` (upstream), parsed by the core module
  from CORE.md §6. A forgotten destination suppresses the legacy fallback. The
  app never writes these files.
- **Policy.** Verification stays in the core. The dialog content, *Connect once*,
  confirmed *Save exception and connect…*, *Cancel* as the default button, and
  the two library windows match [TRUST.md](../native-ui/TRUST.md). No certificate
  is ever added to the Windows certificate stores.
- **CA/CRL files.** Explicit files chosen in Settings, profiles or connection
  files, with Windows path rules. Native defaults are empty, as on macOS; the FLTK
  default `%APPDATA%\TidyVNC\x509_ca.pem` is not used implicitly.

## 6. Clipboard

- **Change detection.** A message-only window on the UI thread registers
  `AddClipboardFormatListener`; `WM_CLIPBOARDUPDATE` plus
  `GetClipboardSequenceNumber` replace the macOS 250 ms pasteboard polling.
- **Access.** `OpenClipboard` can fail while another program holds the clipboard;
  reads and writes retry briefly and then report `Unavailable`, never block.
- **Routing.** The same app-wide coordinator as macOS: text goes only to the
  session whose desktop is focused in the foreground window, respecting each
  direction's policy and the size limits, and is sent when focus returns if it
  changed while unfocused (the retained viewer's rule).
- **Echo suppression.** Text written from the remote side also gets a registered
  private format, `TidyVNC.RemoteOrigin`, holding the process, session and
  generation. A clipboard change carrying the current process's marker is not
  sent back. This replaces the macOS private pasteboard type.
- **Formats.** `CF_UNICODETEXT` only, with the core's newline and UTF-8 rules. No
  files or images, as on macOS.
- **Cloud clipboard** (owner decision D21). Every write of remote-origin text
  also sets the `CanUploadToCloudClipboard` format to 0 in the same
  `OpenClipboard`/`CloseClipboard` transaction, so Windows never syncs it to the
  user's other devices. Local clipboard history is left to the user's setting.
  Text the user copies locally is not marked. A write that cannot include the
  marker is not made: the viewer reports the clipboard as unavailable rather than
  writing remote text without it.

## 7. Displays

- **Topology.** `QueryDisplayConfig` for active paths and
  `DISPLAYCONFIG_TARGET_DEVICE_NAME` (monitor device path and friendly name),
  joined with `EnumDisplayMonitors`/`GetMonitorInfoW` for bounds and work areas and
  `GetDpiForMonitor` for scale. The helper DLL performs the queries; C# builds
  immutable snapshots.
- **Stable IDs.** An opaque SHA-256 of the monitor device path (which identifies
  the monitor and connector and survives reboots), never the `HMONITOR` value or
  the enumeration index. Duplicate (mirrored) outputs are reported as one display
  with a mirrored flag, as the macOS service reports mirrored screens.
- **Names.** The monitor's friendly name ("DELL U2720Q") for display choosers, with
  a numbered fallback.
- **Units.** Bounds in effective pixels (logical) and physical pixels (device),
  with the scale factor, matching the macOS snapshot fields.
- **Changes.** `WM_DISPLAYCHANGE`, `WM_DPICHANGED` and `WM_SETTINGCHANGE` (work
  area) trigger a fresh snapshot with a new generation. Missing selected displays
  resolve as on macOS: survivors kept, fallback to current, stored preference
  unchanged.
- **Legacy numbering.** For `.tidyvnc` files and imports, the core's legacy
  monitor numbering (CORE.md §6) converts between file numbers and stable IDs;
  W6 checks it against what the FLTK Windows viewer actually does.

## 8. Keyboard capture

Service contract as on macOS (`NativeKeyboardCapturing`): start, stop, typed
failure, release on focus loss, sleep, lock, policy change, disconnect and
close. Implementation in the helper DLL: a `WH_KEYBOARD_LL` hook on its own
thread, installed only while an eligible desktop has focus (fullscreen when
*Capture system keys in full screen* is on, or after *Capture keyboard*), with the
retained pass-through rules from `vncviewer/win32.c` (Caps Lock, Num Lock and
Scroll Lock pass; keys already down when capture started pass their release).
Windows needs no permission for this, but it cannot capture Ctrl+Alt+Del or
Win+L (secure desktop) or keys for elevated windows, and the guidance says so.
Details of the key path are in DESKTOP.md §5.

## 9. Import from the FLTK viewer (registry)

The WinUI app offers the same two explicit imports as macOS (defaults, recent
connections), reviewed and acknowledged, with the same exclusions.

| Source | Location | Notes |
| --- | --- | --- |
| Current TidyVNC settings | `HKCU\Software\TidyVNC\vncviewer` and `…\history` | Exists only after the rebrand R5 moves the FLTK viewer there |
| TigerVNC settings | `HKCU\Software\TigerVNC\vncviewer` and `…\history` | Used by upstream TigerVNC and by the current, not yet rebranded, FLTK TidyVNC |

The reader opens keys read-only and converts values the way
`vncviewer/parameters.cxx` writes them: `ServerName` as `REG_SZ`, integers and
booleans as `REG_DWORD`, other values as `REG_SZ` escaped with
`ConnectionDocument::encodeValue` (at most 256 characters); history values named
`"0"`, `"1"`, … in order. The results go into the core's import projection
(CORE.md §6) as (name, raw value, origin) triples; the projection decides what
imports. Passwords, CA/CRL paths, security types, trust records and tunnel
settings are never imported. The registry is never written. Both sources can
exist at once; the review names which one is used, and the user picks.

## 10. Listener and Windows Firewall

The listener is the core's (CORE.md §5). The first time the app listens on a
non-loopback address, Windows Defender Firewall may ask whether to allow
TidyVNC on private or public networks. The app cannot know the answer and does
not create firewall rules silently. The listener window shows an `InfoBar` that
explains the prompt and how to change the choice later, and connection guidance
mentions the firewall when no peers arrive. The installer offers no firewall
rule by default; an opt-in rule is a possible later addition.

Outgoing connections have no Windows consent step. The macOS Local Network
guidance has no Windows counterpart and is not shown.

## 11. SSH gateway tunnels

The macOS design (owned OpenSSH master, Unix-socket forwarding, askpass helper,
host-key review, captured `~/.ssh/config` subset) is in
[TUNNELS.md](../native-ui/TUNNELS.md) and
[SSH-CONFIGURATION.md](../native-ui/SSH-CONFIGURATION.md). Windows keeps the
behaviour and changes the mechanism (DECISIONS.md D17):

| macOS | Windows |
| --- | --- |
| `/usr/bin/ssh` | `%SystemRoot%\System32\OpenSSH\ssh.exe`; its absence disables the gateway field with guidance |
| ControlMaster + `-O forward` | Not supported by Windows OpenSSH. Chosen (D17 spike): `ssh -W host:port`; the app relays its stdin/stdout to a private AF_UNIX socket that the core's routed connect uses. First bytes from the RFB server mark readiness |
| Private Unix forwarding socket (0600) | Private AF_UNIX relay socket in an owner-only per-attempt directory, accepting only the app's own process (`SIO_AF_UNIX_GETPEERPID`); no TCP port |
| `posix_spawn` with a process group | `CreateProcessW` with an explicit argument vector, a restricted environment block, `bInheritHandles` limited to the pipes, all inside a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` |
| Askpass over a private Unix socket | `tidyvnc-ssh-askpass.exe` talking to the app over a per-attempt named pipe whose DACL allows only the current user, with a random per-attempt token |
| `SSH_AUTH_SOCK` | The Windows `ssh-agent` service pipe (`\\.\pipe\openssh-ssh-agent`), used by ssh.exe directly |
| `~/.ssh/config` capture via a bounded probe | A private snapshot of `%USERPROFILE%\.ssh\config` evaluated by `ssh -G`. `Include`, `Match exec` and `Match localnetwork` are refused before evaluation, and effective proxy, command or forwarding settings after it. The connection uses the same snapshot |
| Known hosts | `%USERPROFILE%\.ssh\known_hosts`. The helper doubles as `KnownHostsCommand` to observe the offered key, and the new-key question is reviewed only when it names that host, algorithm and fingerprint. Approval answers with the computed fingerprint, as on macOS |

Unchanged rules: argument vectors only, no shell strings; `VNC_VIA_CMD` and
proxy/command directives rejected visibly; VNC credentials never in ssh's
arguments or environment; fixed error text; startup deadlines of 20 seconds
without interaction and five minutes with native prompts; close waits for the
process tree to exit.

## 12. Activation, instances and the command line

- **Primary instance** (D8). `AppInstance.FindOrRegisterForKey("primary")` at
  start-up for shell launches. A secondary shell launch redirects its activation
  (plain launch, file open, Jump List task) to the primary and exits. The primary
  opens a window for it: a new connection window, a document review window, or
  the listener window.
- **Command line** (D9). `vncviewer.exe` validates arguments with the core's
  invocation parser, handles help, version and syntax errors in the terminal,
  then starts `TidyVNC.exe` with the same arguments, an internal flag marking a
  command-line launch, the captured working directory and the inherited
  environment. Command-line processes never redirect and never register as
  primary. Argument text is converted from UTF-16 (`CommandLineToArgvW` semantics)
  to UTF-8 once, before the shared parser sees it.
- **Operand rules** match the retained viewer and macOS: a bare name ending in
  `.tidyvnc` is still a host name; use `.\file.tidyvnc` for a relative file.
  Operands containing `\` or `/` are inspected as paths.
- **File association.** The per-user installer registers `.tidyvnc` for the
  current user (`HKCU\Software\Classes`) with ProgID `TidyVNC.ConnectionFile.1`
  and a default-program choice the user confirms in Windows settings;
  `.tigervnc` is not claimed.
- **AppUserModelID** `io.github.jkeli.tidyvnc` on the process and Start menu
  shortcut, so taskbar grouping and the Jump List belong to TidyVNC.

## 13. Lifecycle, power and session events

- **Window close.** `AppWindow.Closing` is cancelled, the window's session drains
  asynchronously, then the window closes. The last window runs full shutdown.
- **Exit and shutdown order** follow the macOS `AppCoordinator`: stop imports,
  document routing, listeners, dialogs, clipboard and display observers; close
  every window's session; await the runtime, sessions, listener, import work,
  library windows, stores, credentials, trust stores and clipboard.
- **Sign-out and restart.** `WM_QUERYENDSESSION` starts the same shutdown with a
  short deadline and `ShutdownBlockReasonCreate` while draining; nothing is saved
  that would not be saved on a normal exit. `RegisterApplicationRestart` is not
  used, so live connections are never restored automatically.
- **Session lock and suspend.** `WTSRegisterSessionNotification` (lock/unlock) and
  `PowerRegisterSuspendResumeNotification` release captured keys and held
  modifiers and buttons, as macOS does on sleep. Network loss surfaces as the
  core's ordinary connection failure; the app does not reconnect on its own.

## 14. Bell, logging, links

- **Bell:** `MessageBeep(MB_OK)`, coalesced per delivery turn.
- **Logging:** the core's process logging with the Windows default file path
  (CORE.md §4); the Help window names the file location for support.
- **Links:** Help links open with `Launcher.LaunchUriAsync` in the default
  browser; only the fixed project URLs are used.

## 15. Guidance mapping

| macOS guidance | Windows guidance |
| --- | --- |
| Local Network privacy may block the connection | Not applicable to outgoing connections; firewall guidance for the listener |
| Accessibility permission required for keyboard capture | Not applicable; explain keys that cannot be captured |
| Keychain locked or access denied | Credential Manager unavailable (no loaded user profile) |
| Finder could not open the file | File Explorer association missing or file unreadable |
| OpenSSH not found (never on macOS) | OpenSSH Client is not installed; Settings > System > Optional features |
