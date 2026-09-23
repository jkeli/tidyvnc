# Native capability and parameter inventory

Source checkpoint: `6d69ccb5`, inspected 2026-09-22. This records N0.2 for the
current development configuration; it does not establish protocol, UI or release
acceptance. [PARITY.md](PARITY.md) maps controls/actions and remaining acceptance.
Repeat the compiled queries whenever a feature flag or dependency changes.

## Actual build and executable evidence

`build/native-ui-frontend/core/config.h` and `CMakeCache.txt`: Debug, arm64,
macOS 27 SDK, deployment declaration 14.0; GnuTLS/nettle enabled, audio/H.264/NLS
disabled. Native localization uses the Swift catalogs independently of gettext.
Homebrew dependencies on this host require macOS 26/27; this is not minimum-OS
proof. The successful full verification report is
`build/native-ui-frontend/verification/run-yhdlyz2o/summary.json`.

A temporary C++ probe linked to the **existing built core libraries**, using the
`encodingoptions` target's link dependencies, queried `encodingChoices()`,
`securityChoices()`, `SecuritySelection().text()` and
`invocationOptions(InvocationCapabilities::compiled())`. It returned 6 encoding
choices, 15 available security methods and 47 canonical parameters. The actual
app's `--help` independently lists the same 47 parameters and three aliases, marks
four unavailable parameters and marks AlertOnFatalError as needing an adapter.
The retained FLTK executable's `--help` was also read: its 46 available spellings
match the 43 macOS-available canonical names plus three aliases. Help exits 1 by
retained convention; this is not a failed probe. Neither probe
starts a connection or accesses credentials. Temporary source/output:
`/tmp/tidyvnc-parity-capabilities.{cxx,log}`. The results are recorded below so the
inventory does not depend on temporary files surviving.

| Capability | Compiled result | Native behavior and remaining proof |
| --- | --- | --- |
| Tight, JPEG, ZRLE, Hextile, Raw | Available | Shared decoder catalog drives encoding choices; wire/render acceptance still needs the full native matrix |
| H.264 | Unavailable in this build | Choice exists but cannot be selected; an enabled build and native decoder/presentation proof remain required before claiming support |
| None, VncAuth, Plain | Available | Exact allow-list and session-scoped prompts; absence of transport encryption remains visible |
| TLSNone, TLSVnc, TLSPlain | Available via GnuTLS | Anonymous TLS is distinct from authenticated X.509 identity |
| X509None, X509Vnc, X509Plain | Available via GnuTLS | Configured CA/CRL, structured verification and scoped saved decisions; real installed identity/privacy checks remain open |
| RA2, RA2_256 | Available via nettle | RSA/AES with 128/256-bit confidentiality; server selects credential shape |
| RA2ne, RA2ne_256 | Available via nettle | Authentication-only RSA variants; do not label the session encrypted |
| DH, MSLogonII | Available via nettle | Legacy username/password authentication; separate trust policy, no TLS implication |
| Audio | Unavailable | No native audio backend; new backend is deferred by PLAN. A library feature flag alone must not create a working native control |
| X11 primary selections / display | Unavailable on macOS | Retained Linux-specific controls, not missing macOS controls |
| SSH `via` | Available | Native owned OpenSSH process, captured admitted configuration, agent/key/password/passphrase and host-key review; restrictions in TUNNELS/SSH-CONFIGURATION remain explicit |
| Reverse TCP listener | Available | Manual admission into independent sessions; Unix listener unsupported; installed LAN proof remains open |
| Remote resizing | Client implementation available | Actual support is negotiated per server; UI also checks input policy and in-flight operation state |
| Global keyboard capture | Adapter available | Actual permission/backend state checked on use; ordinary view input does not require global capture permission |

The actual default security allow-list, in order, is:

```text
None,VncAuth,Plain,TLSNone,TLSVnc,TLSPlain,X509None,X509Vnc,X509Plain,RA2,RA2ne,RA2_256,RA2ne_256,DH,MSLogonII
```

VeNCrypt is protocol negotiation, not an additional selectable leaf method. On a
build without GnuTLS/nettle the corresponding leaf methods are unavailable and
removed from the compiled default. An explicitly empty native allow-list denies
all methods. No security-method alias is invented; names use the shared parser.

Sources: [encoding schema](../../viewer/core/EncodingOptions.cxx),
[security catalog](../../viewer/core/SecurityOptions.cxx),
[security implementation/defaults](../../common/rfb/SecurityClient.cxx),
[invocation catalog](../../viewer/core/Invocation.cxx),
[native admission](../../platform/macos/Settings/NativeInvocationResolution.swift).

## Parameter rules and precedence

All names/aliases are case-insensitive. Boolean values accept on/off, yes/no,
true/false and 1/0. Bare canonical booleans enable the option; separate boolean
lookahead and the FullColour alias exception are documented in [CLI.md](CLI.md).
Unknown/unavailable options fail explicitly. Every occurrence is validated, so an
invalid earlier assignment cannot hide behind a valid duplicate or `--help`.
The three aliases are **FullColour → FullColor**, **LowColourLevel → LowColorLevel**
and **passwd → PasswordFile**. DotWhenNoCursor and FullScreenAllMonitors are
migrations, not aliases.

Native resolution is compiled defaults → app defaults → selected profile → CLI →
explicit connection file. A later live edit changes only its session. Fields not
supported in a compatibility file stay opaque and are disclosed during review;
the file is not a second unrestricted CLI. Explicit defaults/history import is a
separate transaction. Saving defaults/profiles affects future sessions, not open
ones. See [DOCUMENTS.md](DOCUMENTS.md), [IMPORTS.md](IMPORTS.md) and [CLI.md](CLI.md).

In the tables, **live** means an implemented connection-local apply, not mutation
of global defaults. **next attempt** means a disconnected edit/reconnect or
initial startup snapshot. **launch** is first-window/process policy. “Same” means
native built-in matches the retained compiled default, before user stores apply.
Boolean range is the shared boolean syntax above. Table rows exhaust the 47
canonical invocation parameters; credential environment inputs follow separately.

### Encoding and color (8)

All eight fields share [EncodingOptions](../../viewer/core/EncodingOptions.cxx),
[EncodingSettingsFields](../../apps/macos/TidyVNC/EncodingSettingsFields.swift),
[SessionEncodingSheet](../../apps/macos/TidyVNC/SessionEncodingSheet.swift) and
[NativeEncodingPreferences](../../platform/macos/Storage/NativeEncodingPreferences.swift).
The live API applies a coherent snapshot and re-negotiates on the session worker.

| Parameter | Retained / native built-in | Validation and effective meaning | Change |
| --- | --- | --- | --- |
| `AutoSelect` | on / same | Boolean; automatic policy chooses encoding/color/quality from measured bandwidth | live |
| `FullColor` | on / same | Boolean; alias FullColour; manual color preference retained while auto is on | live |
| `LowColorLevel` | 2 / same | Integer 0 very low, 1 low, 2 medium; alias LowColourLevel; used when reduced color is effective | live |
| `PreferredEncoding` | Tight / same | Tight, JPEG, ZRLE, Hextile, H.264, Raw; rejects unavailable decoder; dormant under auto | live |
| `CustomCompressLevel` | off / same | Boolean; off selects automatic/default compression rather than deleting the saved level | live |
| `CompressLevel` | 2 / same | Integer 0–9; used when custom compression is on | live |
| `NoJPEG` | off / same | Boolean; UI “Allow JPEG” is the inverse | live |
| `QualityLevel` | 8 / same | Integer 0–9; dependent on JPEG and automatic policy | live |

Integer input preserves checked legacy base-0 decimal/octal/hex and leading
whitespace/sign; it rejects out-of-range/empty/trailing-invalid input. Saving an
inactive preference preserves it; UI gating is not loss of the underlying field.

### Input and clipboard (13)

Sources: [retained parameters](../../vncviewer/parameters.cxx),
[InputSettings](../../platform/macos/Settings/NativeInputSettings.swift),
[InputPreferences](../../platform/macos/Storage/NativeInputPreferences.swift),
[InputDefaultsFields](../../apps/macos/TidyVNC/InputDefaultsFields.swift),
[ConnectionContent](../../apps/macos/TidyVNC/ConnectionContent.swift),
[session configuration](../../platform/macos/Bridge/NativeValues.swift).

| Parameter | Retained / native built-in | Validation and effective meaning | Change |
| --- | --- | --- | --- |
| `PointerEventInterval` | 17 ms / same | Integer 0–2147483647; 0 disables motion delay; state transitions/releases remain ordered | next attempt; CLI |
| `EmulateMiddleButton` | off / same | Boolean; left+right chord policy and pending-state release | live |
| `DotWhenNoCursor` | off / same | Deprecated boolean; true migrates to AlwaysCursor on + Dot after overlays | migration at admission |
| `AlwaysCursor` | off / same | Boolean; fallback when server supplies no visible cursor | live |
| `CursorType` | Dot / same | Dot or System; dormant shape retained when fallback is off | live |
| `ViewOnly` | off / same | Boolean; enforced in core, including synthetic menu input | live |
| `AcceptClipboard` | on / same | Boolean; independent receive direction; active/focused session routing | live |
| `SendClipboard` | on / same | Boolean; independent send direction; remote-origin echo suppression | live |
| `SetPrimary` | on on X11 / unavailable | X11-only boolean; unavailable invocation rejects on macOS | platform exclusion |
| `SendPrimary` | on on X11 / unavailable | X11-only boolean; unavailable invocation rejects on macOS | platform exclusion |
| `display` | empty on X11 / unavailable | X11 display string | platform exclusion |
| `ShortcutModifiers` | Ctrl,Alt / same | Any subset of Ctrl, Shift, Alt, Super; Option=Alt, Win/Cmd=Super; empty disables; canonical deduplication | live |
| `FullscreenSystemKeys` | on / same | Boolean; capture attempted only in eligible focused fullscreen view | live; OS access required |

### Display and resize (11)

Sources: [scaling parser](../../viewer/core/DesktopTransform.cxx),
[fullscreen policy](../../platform/macos/Settings/NativeFullscreenPolicy.swift),
[resize policy](../../platform/macos/Settings/NativeRemoteResizePolicy.swift),
[window geometry](../../viewer/core/WindowGeometry.cxx),
[CLI resolution](../../platform/macos/Settings/NativeInvocationResolution.swift).

| Parameter | Retained / native built-in | Validation and effective meaning | Change |
| --- | --- | --- | --- |
| `Maximize` | off / same | Boolean; native initial zoom policy, separate from fullscreen | launch |
| `FullScreen` | off / same | Boolean; starts in selected fullscreen policy | live toggle; saved value on launch |
| `FullScreenMode` | Current / same | Current, Selected, All | live with coordinated transition |
| `FullScreenAllMonitors` | off / same | Deprecated boolean; true overrides mode to All after compatibility overlays | migration at admission |
| `FullScreenSelectedMonitors` | legacy {1} / native stable-ID list initially empty | Compatibility numeric list uses positive indices ≤2147483647; explicit review maps to stable displays. Native max 64 unique IDs, each ≤256 UTF-8 bytes; Selected requires a nonempty valid selection | live; mapping review may be required |
| `DesktopSize` | empty / same | Empty or width×height, each 1–65535; native UI strict decimal `WxH`; CLI retains checked legacy `%dx%d` useful whitespace/sign/trailing-text behavior | next attempt's initial remote size |
| `geometry` | empty / same | Retained `WxH[+X+Y]` / `+X+Y` grammar (not general X geometry); dimensions 1–2147483647, signed 32-bit coordinates; ≤65536 bytes; checked legacy suffix behavior | launch only |
| `ScalingFactor` | 100 / same | Eight modes below, 0.01–10000% with ≤2 decimals; dimensions 1–65535; computed backing dimensions also bounded | live |
| `ScalingQuality` | Bilinear / same | Nearest, Bilinear, Area | live |
| `DesktopPixelUnits` | Logical / same | Logical or Device; independent of remote resize policy | live |
| `RemoteResize` | on / same | Boolean; coalesced automatic server layout requests require capability/input permission | live |

The eight scaling modes are unscaled (`100`, `100%`, `None`), stretch-to-fit
(`Auto`), aspect fit (`FixedRatio`), `FitWidth`, `FitHeight`, uniform percentage,
exact `WxH`, and independent `X%xY%`. Mode-specific drafts preserve dormant values.
Fit modes follow the viewport; pixel units govern fixed sizing. Overflow/failure
recovery and mixed-display suitability are separate from syntax acceptance.

### Connection, security and process (15)

Sources: [retained parameters](../../vncviewer/parameters.cxx),
[security policy](../../viewer/core/SecurityOptions.cxx),
[TLS file defaults](../../common/rfb/CSecurityTLS.cxx),
[native configuration](../../platform/macos/Bridge/NativeValues.swift),
[CLI admission](../../platform/macos/Settings/NativeInvocationResolution.swift),
[logging grammar](../../viewer/core/LoggingPolicy.cxx).

| Parameter | Retained / native built-in | Validation and effective meaning | Change |
| --- | --- | --- | --- |
| `AlertOnFatalError` | on / **missing adapter** | Recognized boolean, but native launch rejects either explicit value; do not count as parity | open implementation gap |
| `ReconnectOnError` | on / same | Boolean; permits explicit Retry after an eligible error; never automatic reconnection | disconnected edit, next failure policy |
| `PasswordFile` | empty / same | Path, alias passwd; regular file with at least 8 bytes, reads only first 8; password-only authentication; captured cwd; never exported/saved | launch credential owner |
| `listen` | off / same | Boolean; positional decimal port 0–65535, default 5500, 0 ephemeral; explicit connection file is reviewed before binding | launch; manual listener also available |
| `Shared` | off / same | Boolean; sent in ClientInit; no retroactive wire change | next attempt |
| `Audio` | on when compiled / unavailable | Boolean only on supported compiled platform; no native backend | deferred backend; explicit unavailable |
| `via` | empty / same | `[user@]host` or `ssh://[user@]host[:port]`; ≤4096 UTF-8 bytes, user ≤255 bytes, port 1–65535 (22 default); empty clears gateway; no listen/Unix target | next attempt |
| `SecurityTypes` | compiled allow-list above / same | ≤1024 bytes; known available comma-separated names, trim/deduplicate, empty denies all | next attempt; disconnected edit |
| `X509CA` | compatibility config-directory `x509_ca.pem` / empty | Empty or absolute native path ≤4096 UTF-8 bytes, no NUL; CLI/file relative path resolves from its captured base; no implicit legacy trust input | next attempt; disconnected edit |
| `X509CRL` | compatibility config-directory `x509_crl.pem` / empty | Same bounded native path policy as CA; malformed/inaccessible files fail, not silently ignored | next attempt; disconnected edit |
| `GnuTLSPriority` | empty / same | ≤4096 bytes, no NUL, shared GnuTLS preflight; empty uses library defaults | next attempt; disconnected edit |
| `MaxCutText` | 262144 bytes / same | Integer 0–2147483647 incoming wire/decompressed clipboard limit; independent of native retained UTF-8 budgets | next attempt; CLI |
| `UseIPv4` | on / same | Boolean; snapshotted transport family policy, both off gives explicit failure | next attempt; CLI/listen |
| `UseIPv6` | on / same | Boolean; same isolation/cancellation requirements | next attempt; CLI/listen |
| `Log` | `*:stderr:30` / same | ≤65536 bytes; registered writer/target/level triples; signed 32-bit level with checked retained decimal-prefix semantics; stderr/stdout/file/empty targets | process startup only |

The CA/CRL and display-selection default differences are deliberate native
ownership/migration choices and require review in the parity acceptance record.
They must not disappear inside a “same defaults” claim.

For AlertOnFatalError, the retained `mainloop` shows an important precedence:
an ordinary outgoing connection error still offers reconnect when ReconnectOnError
is on, even if AlertOnFatalError is off. Fatal app errors and non-retry/reverse
connection errors consult AlertOnFatalError. The native adapter must model these
cases explicitly; simply suppressing all errors when the flag is off is incorrect.

## Other launch inputs and compatibility boundaries

- `VNC_PASSWORD`, optionally `VNC_USERNAME`, take precedence over PasswordFile.
  Capture/clear at process entry; first connection owns the copy (first accepted
  peer for listen). Closing/stopping clears unclaimed inputs. Username/password
  are not invented CLI parameters and never relay through relaunch argv.
- `VNC_VIA_CMD` and arbitrary SSH commands/proxy hops are explicitly rejected by
  the native tunnel policy. Config capture admits a bounded subset; see
  [SSH-CONFIGURATION.md](SSH-CONFIGURATION.md). This is a visible compatibility
  restriction that still needs final acceptance, not a silent success.
- HOME/XDG determine explicit compatibility import sources and launch path context;
  native defaults/history/profile writers use their own stores. No implicit
  credential or certificate-exception migration.
- Help/version/error-only startup precedes native stores/windows. No operand opens
  the form; host connects when ready; explicit file is reviewed; Unix socket and
  host classification retain literal path rules. Detailed grammar is in CLI.md.
- Native additions (credential retention, profiles, trust libraries, statistics,
  remote-layout editors) do not create new legacy command-line parameters.

## Evidence limits and next work

Existing shared/catalog/value/ownership/native-wire tests cover many individual
contracts; the preceding full report passes 756 core and 88 native tests. A green
catalog query proves availability/defaults, not negotiation with every server or
physical input/display behavior. The 55-case protocol baseline, H.264-enabled
configuration, minimum/current/Intel/Release CI, live UI and installed integration
remain separate open gates. Implement AlertOnFatalError next, including its
interaction with ReconnectOnError and isolated multi-window lifetime. Do not
emulate the retained process exit by terminating unrelated native sessions.
