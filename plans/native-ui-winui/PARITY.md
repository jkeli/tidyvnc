# WinUI parity inventory

Planning checkpoint `6972f720`, 2026-09-23. Every row of the macOS
[parity inventory](../native-ui/PARITY.md) appears here with its planned WinUI
replacement and the Windows-specific part of its acceptance. **No row is
implemented.** The macOS row's own acceptance criteria also apply to the Windows
row; this table adds only what differs. [CAPABILITIES.md](../native-ui/CAPABILITIES.md)
still defines all 47 parameters and aliases; the same parameter rows apply on
Windows, with the Windows platform exclusions noted below.

Test areas reuse the macOS evidence codes (EP, HI, PR, ST, AU, TR, SE, EN, IN, CB,
SC, FS, RR, CO, DT, CM, DO, EX, IM, IH, CL, CP, LC, LI, SH, LO). Windows tests will
be named `Windows.<Code>.<Case>` so the two suites line up.

Window, dialog and control names refer to [UX.md](UX.md). "Same" means the WinUI
replacement mirrors the macOS one with the Windows presentation rules in UX.md.

For **every** window, dialog and menu below, Windows acceptance also covers: Enter
and Escape, tab order and visible focus, Narrator name/role/value, access keys
where focus allows them, light/dark and each contrast theme, 225% text size,
pseudo-localized expansion and mirroring, minimum window size and scrolling.

## Connection form, recent hosts and profiles

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| C01 | Address `TextBox` in `ConnectionWindow`; `ConnectionModel` | IPv6 scope IDs by Windows interface index; Unix socket paths only if D18 is accepted; Enter connects once |
| C02 | Recent connections flyout | Same 20-entry rules; flyout keyboard navigation and remove buttons reachable without a mouse |
| C03 | *Connect* button | UI thread stays responsive (W3.2 measurement) |
| C04 | *Cancel* while resolving/connecting/authenticating | Escape in the address row cancels; no late dialog after cancel |
| C05 | Settings window and per-connection dialogs | Defaults versus this connection clearly separated |
| C06 | File > Open connection file… (`IFileOpenDialog`, *Review* button) | Both extensions via filters; review page before any session |
| C07 | File > Save connection file as… (`IFileSaveDialog`) | Overwrite prompt, `.tidyvnc` default extension |
| C08 | Help > About TidyVNC window | Selectable text, keyboard-closable |
| C09 | *SSH gateway (optional)* field | Disabled with guidance when Windows OpenSSH is missing |
| C10 | `ProfilesWindow`, *Open connection* | Opens a new window; never connects automatically |

## Authentication and trust

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| A01 | `AuthenticationDialog` server/security text | Warning colour meets contrast in all themes |
| A02 | User name `TextBox` | Focus order; Unicode input through IMEs |
| A03 | `PasswordBox` | Copy disabled; reveal button follows the Windows default; value cleared on close (SERVICES.md §3) |
| A04 | Lifetime `RadioButtons`: *Use once*, *Retain for this session's reconnect*, *Remember on this PC* | "Remember" absent for reverse connections and when Credential Manager is unavailable |
| A05 | *Authenticate* / *Cancel* | Enter submits once; Escape cancels; closing the window cancels |
| A06 | *Use session password* | Two windows keep separate session passwords |
| A07 | *Use saved password* / *Forget saved password* | Credential Manager NotFound/Unavailable handling; forget deletes only that target |
| A08 | *Replace an existing saved password* toggle | Save failure leaves authentication recoverable |
| A09 | `SSHAuthenticationDialog` | Askpass over the named pipe; multiwindow prompt routing |
| T01 | Trust dialog with `TrustDetailsView` | Details scroll inside the dialog; fingerprints selectable |
| T02 | Expected/received identities | Same |
| T03 | *Cancel* is the default button | Enter cancels; verified with a mutation check as on macOS |
| T04 | *Connect once* | Nothing written to `trust\*.json` |
| T05 | *Save exception and connect…* with a confirmation step inside the dialog | No second dialog; stale generation cannot auto-connect |
| T06 | *Reload saved decisions* | Read failure never implies trust |
| T07 | `TrustLibraryWindow` ×2 | Legacy `%APPDATA%\…\x509_known_hosts` suppressed after Forget |
| T08 | SSH host-key review | `%USERPROFILE%\.ssh\known_hosts`; changed keys rejected |

## Options: compression and security

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| O01 | *Choose encoding and quality automatically* toggle | Dependent controls disable; dormant values kept |
| O02 | Preferred encoding `ComboBox` from the shared catalog | H.264 shown unavailable while D19 keeps it off |
| O03 | Full color toggle | Same |
| O04 | Reduced colors `ComboBox` | Same |
| O05 | *Allow JPEG* (inverse of NoJPEG) | Narrator name matches the label |
| O06 | Custom compression toggle | Same |
| O07 | Compression `NumberBox` 0–9 with spin buttons | Invalid entry blocks Apply |
| O08 | JPEG quality `NumberBox` 0–9 | Same |
| S01 | Security method check boxes grouped by protection | All 15 methods from the Windows build's catalog; unavailable ones explained |
| S02 | Same catalog | Same |
| S03 | CA file field, *Choose…*, *None* | Drive, UNC and long paths; unreadable file recovery |
| S04 | CRL file field | Same |
| S05 | Advanced TLS priority | Shared GnuTLS preflight on the Windows build |
| S06 | Override/inherit allowed methods | Same |
| S07 | `SessionSecurityDialog` (disconnected only) | Same |

## Options: input and clipboard

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| I01 | View only | Blocks keys taken by the message hook and the low-level hook too |
| I02 | Emulate middle button | Physical two-button mouse and precision touchpad |
| I03 | Cursor fallback | Real `HCURSOR` and software fallback (D13) |
| I04 | Dot / System cursor | Same |
| I05 | *Capture system keys in full screen* | `WH_KEYBOARD_LL`; no permission; secure-desktop keys explained |
| I06 | Shortcut modifier Ctrl | Same |
| I07 | Shortcut modifier Shift | Same |
| I08 | Shortcut modifier Alt | Labelled Alt; AltGr never counts as Ctrl+Alt |
| I09 | Shortcut modifier Super | Labelled *Windows key* |
| I10 | Receive clipboard | Clipboard contention retry; remote-origin marker |
| I11 | Send clipboard | Focus-routed; sent on refocus if changed |
| I12 | SetPrimary/SendPrimary | Unavailable (X11 only), rejected on the command line as on macOS |
| I13 | PointerEventInterval, MaxCutText (CLI only) | Same |

## Options: scaling

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| Z01 | Unscaled | Identity at 100% (logical and device); logical at 125/150/175% resamples as expected |
| Z02 | Stretch | Same |
| Z03 | Aspect fit | Same |
| Z04 | Fit width | Same |
| Z05 | Fit height | Same |
| Z06 | Uniform percentage | Fractional display scales |
| Z07 | Exact WxH | Same |
| Z08 | Independent X%xY% | Same |
| Z09 | Mode-specific drafts | Same |
| Z10 | Nearest / Bilinear / Area | Pixels match macOS for the same frame and transform (shared renderer) |
| Z11 | Logical (effective pixels) / Device (physical pixels) | Window moved between monitors of different scale keeps intent |
| Z12 | Limits and fit recovery | Same |

## Display, remote resize and miscellaneous

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| D01 | Windowed start | Restores placement from `window-state.json` only onto existing displays |
| D02 | Current display | Uses the display the window is actually on |
| D03 | All displays | One surface per monitor, mixed scales |
| D04 | Selected displays | Stable IDs from monitor device paths |
| D05 | Display arrangement chooser | Monitor friendly names; physical order kept in mirrored layouts |
| D06 | Initial desktop size | Same |
| D07 | Automatic remote resize | Same |
| D08 | *Resize remote desktop…* | Same |
| D09 | Shared | Same |
| D10 | Offer Retry | Same |
| D11 | Audio | Unavailable, as on macOS (owner decision D19). The FLTK Windows viewer has audio; the owner accepted losing it, so it does not block cutover |
| D12 | `geometry` / `Maximize` | `AppWindow` placement once, before automatic fullscreen |

## Saved defaults, live drafts and profiles

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| P01 | Settings `NavigationView` sections | Keyboard section navigation |
| P02 | `SettingsCard` description with effective value and source | Same |
| P03 | *Apply* | Revision check across several TidyVNC processes (D8) |
| P04 | *Cancel edits*, reload on conflict | Same |
| P05 | Reset / inherit per field | Same |
| P06 | Per-connection dialogs Apply/Cancel | Dialog queue priority |
| P07 | Profile create/edit/delete | Delete confirmation as a flyout, not a second dialog |
| P08 | Profile connect/refresh | Same |
| P09 | Store unavailable | ACL `Denied`, sharing-violation retry, newer schema read-only |

## Desktop views, menu actions and shortcuts

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| V01 | Window title, status bar, close | Taskbar title shows the server; close drains |
| V02 | Desktop view, pan | UIA Scroll pattern; touch pan |
| V03 | Fullscreen surfaces over the shared canvas | Per-monitor windows (D14) |
| V04 | Focus and activation | Message hook only while the desktop has focus; release on deactivation |
| V05 | Cursor | D13 |
| V06 | Key translation | Retained translator equivalence test; layout matrix (TESTING.md §7) |
| V07 | Buttons, wheel, timing | X1/X2, horizontal and high-resolution wheel |
| V08 | Resize, damage, filter redraw | Swap chain resize; device loss |
| V09 | Hot-plug, sleep, wake | Also lock/unlock, UAC and running inside RDP |
| V10 | Performance | Matched FLTK GDI baseline on the same machine |
| M01 | Disconnect | Same |
| M02 | Full screen | F11 outside the desktop; chord + Enter inside |
| M03 | Minimize | Minimizes fullscreen surfaces directly |
| M04 | Resize window to desktop | Limited to the display's work area |
| M05 | Hold Ctrl | Same |
| M06 | Hold Alt | Same |
| M07 | Send Ctrl+Alt+Del | The only way to send it; cannot be captured |
| M08 | Refresh desktop | Same |
| M09 | Connection settings submenu | Same seven entries |
| M10 | Connection information | Same |
| M11 | About | In Help only |
| M12 | Pan desktop submenu | Same |
| M13 | Capture / Release keyboard | Low-level hook start/stop and failure text |
| M14 | Remote resize / statistics | Menu bar, toolbar, connection bar and context menu route identically |
| K01 | Chord alone releases capture | Same |
| K02 | Chord + G | Same |
| K03 | Chord + Enter | Same |
| K04 | Chord + M | Menu at the pointer; Escape dismisses |
| K05 | Chord + Space bypass | Same |
| K06 | Chord + other key | Same |
| K07 | Ctrl+N / Ctrl+O / Ctrl+Shift+S | Only outside the desktop view |
| K08 | Ctrl+Shift+L / Ctrl+Shift+P / F1 | Same |
| K09 | Exit / Ctrl+, / Ctrl+W | Exit drains prompts, IO and services |

## App launch, files, imports and recovery

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| L01 | Start with no arguments | One window; no registry or legacy writes |
| L02 | `vncviewer host` | Own process (D8); connects once after stores are ready |
| L03 | Unix socket operand | D18 |
| L04 | Connection file operand | Review page; file overrides CLI |
| L05 | `--help`, `--version`, invalid arguments | Through `vncviewer.exe` in cmd.exe and PowerShell; exit codes; no stores touched |
| L06 | PasswordFile, VNC_USERNAME/VNC_PASSWORD | Windows path rules; environment cleared after capture |
| L07 | `-listen [port]` | Firewall guidance |
| L08 | `-listen file` | Same |
| L09 | `-via` | Windows OpenSSH design (D17) |
| L10 | File Explorer open | Redirected to the primary process; several files at once |
| L11 | Start menu, taskbar, Jump List reopen | Jump List tasks |
| L12 | Exit and OS shutdown | `WM_QUERYENDSESSION` with a bounded drain |
| L13 | Restore after sign-in | Not restored; no `RegisterApplicationRestart` |
| F01 | Open native or legacy file | Filters; oversize/unreadable/wrong header recovery |
| F02 | Review known/unknown/secret fields | Same |
| F03 | Monitor mapping review | Stable Windows display IDs |
| F04 | Reload/retry read | Same |
| F05 | Save As current settings | Same |
| F06 | Export losses and monitor numbering | Core export-loss rules (W2) |
| F07 | Save dialog extension/overwrite | Same |
| F08 | Atomic write | `ReplaceFileW`; sharing-violation retry; read-only destination |
| F09 | First-use defaults import offer | Offered when a TidyVNC or TigerVNC registry key exists |
| F10 | Defaults source choice | *Current TidyVNC settings* / *TigerVNC settings* |
| F11 | Defaults review and mapping | Core import projection over registry values |
| F12 | Defaults commit and marker | Registry never written |
| F13 | History source and review | `…\vncviewer\history` values in order |
| F14 | History import/skip/cancel | Same |
| E01 | DNS/refusal/routing/timeout | Winsock and `GetAddrInfoExW` codes mapped by the core (CORE.md §4) |
| E02 | Authentication/protocol/peer disappearance | Same |
| E03 | Retry scoping | Same |
| E04 | Local Network suspicion | Not applicable on Windows; listener firewall guidance instead |
| E05 | Renderer/cursor/input/fullscreen failure | Direct3D device loss |
| E06 | AlertOnFatalError off | Same scoped window closure |

## Information, help and about

| ID | WinUI replacement | Windows-specific acceptance |
| --- | --- | --- |
| Q01 | Connection information dialog | Same |
| Q02 | *Copy diagnostics* | Redacted; clipboard write marked local, not remote-origin |
| Q03 | Statistics overlay | Also on every fullscreen surface |
| Q04 | Counters | Same |
| H01 | About window | Version and architecture shown |
| H02 | Credits and licences | Includes Windows third-party notices (PACKAGING.md §5) |
| H03 | Help window | Windows keys and terms; Credential Manager threat model |
| H04 | Project and issue links | Open in the default browser |

## Windows-only rows

| ID | Behaviour | Acceptance |
| --- | --- | --- |
| W01 | Touch gestures (DESKTOP.md §6) | Every retained gesture on a touch screen; equivalence test with `BaseTouchHandler` |
| W02 | Pen as mouse | Tip, barrel button |
| W03 | AltGr merging and per-layout probe | German, French, Swiss German, Spanish layouts |
| W04 | IME keys, `VK_PACKET`, emoji panel, touch keyboard | Japanese, Korean, Chinese IMEs; emoji panel text reaches the remote side |
| W05 | Fractional and changing DPI | 125/150/175%; drag between monitors; scale change while connected |
| W06 | Session lock, secure desktop, UAC | Held keys released; presentation recovers |
| W07 | Running inside a Remote Desktop session | Reconnect at a new size and DPI |
| W08 | Custom title bar | Dragging, double-click maximize, Snap Layouts, system menu (Alt+Space) outside the desktop |
| W09 | Jump List | Two tasks, no history |
| W10 | Single primary process | Explorer open and Start launch while running |
| W11 | Console launcher | Output, exit codes, Ctrl+C closes the GUI process's windows |
| W12 | Firewall guidance | First bind, allowed, denied |
| W13 | Clipboard specifics | Contention, remote-origin marker, remote text never synced by Windows cloud clipboard (D21) but present in local history when enabled |
| W14 | Credential Manager specifics | Entries deleted outside the app; unavailable profile |
| W15 | Windows 11 only (D6) | MSI and app refuse older Windows with a message pointing to the FLTK build; Mica falls back to its solid colour when transparency is off |
| W16 | Contrast themes and text scaling | Every window, 225% text |
| W17 | Per-user installer | Standard user, no UAC; association consent, user PATH option, upgrade, repair, uninstall keeping data; unsigned SmartScreen path (D5, D23) |
| W18 | Narrator on the desktop view | Scroll pattern, Invoke to focus, status announcements |
| W19 | Sign-out with pending work | Shutdown block reason shown; bounded drain |
| W20 | Paths | UNC, long (>260 characters) and non-ASCII paths for files, CA/CRL and PasswordFile |

## Parameter exclusions on Windows

Same as macOS except where noted: `SetPrimary`, `SendPrimary` and `display` are
unavailable (X11 only). `via` is available when Windows OpenSSH is present. `Audio`
is unavailable (D19). Unix-socket operands and `-listen` depend on D18 and the W1
listener adapter respectively. The retained FLTK Windows viewer lacks `via` and
Unix sockets, so the WinUI app adds them.
