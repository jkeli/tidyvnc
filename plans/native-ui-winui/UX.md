# Windows user experience

Recorded 2026-09-23. This defines how the WinUI app looks and behaves. The goal
has two halves that pull in different directions, and the rules below settle
where each one wins:

- **Same product.** Someone who has used the macOS app finds the same windows,
  the same controls in the same order, the same dialog content, the same section
  names, the same defaults and the same safe default buttons.
- **Windows chrome.** Title bars, menus, dialogs, icons, fonts, capitalization,
  keyboard conventions, themes and system terms follow Windows 11, the only
  supported Windows version (DECISIONS.md D6). A Windows user should not feel
  they are running a Mac app.

When the two conflict: product behaviour (what a control does, what is saved,
what is safe by default) follows macOS; presentation (how it is drawn, what it is
called, which key reaches it) follows Windows. Every deliberate difference is
listed in §12 for owner review, as the macOS plan did for its differences from
FLTK.

Source inventory for the macOS side: [PARITY.md](../native-ui/PARITY.md) and the
files under [apps/macos/TidyVNC](../../apps/macos/TidyVNC).

## 1. Visual language

| Aspect | Windows 11 |
| --- | --- |
| Window backdrop | `MicaBackdrop` on the connection, settings, library, import, listener and help windows. When Windows turns transparency off (*Transparency effects* or battery saver), Mica shows its solid fallback colour automatically |
| Desktop area | Opaque black letterbox behind the remote image (never Mica) |
| Title bar | `ExtendsContentIntoTitleBar` with the app icon, title and menu bar in the caption area; system caption buttons kept so Snap Layouts works |
| Corners, shadows | System defaults (rounded) |
| Typography | WinUI type ramp, Segoe UI Variable |
| Icons | Segoe Fluent Icons through `SymbolThemeFontFamily` |
| Theme | Follows the system light/dark setting; contrast themes supported (§10) |
| Accent | System accent for primary buttons and selection |
| Motion | WinUI theme transitions only; none custom. Off when *Animation effects* is off |

Warning and error text uses app colours with measured contrast of at least 4.5:1
on every background in light and dark themes, the same rule as
`NativeStatusColors` on macOS. In contrast themes it uses the system
`SystemColorWindowTextColor`/`SystemColorHighlightColor` resources instead of app
colours.

## 2. Window map

Sizes are in effective pixels and start from the macOS point sizes; W5 checks
them with expanded pseudo-localized text and 225% text scaling.

| macOS window | WinUI window | Default / minimum size | Notes |
| --- | --- | --- | --- |
| Connection window (`WindowGroup "connection"`) | `ConnectionWindow` | 960×700 / 640×420 | Also used for profile, document and incoming connections, as on macOS |
| Profile connection window | `ConnectionWindow` opened with a profile ID | same | Re-reads the profile when it opens |
| Document connection window | `ConnectionWindow` with review page first | same | Title shows the file name |
| Incoming Connection window | `ConnectionWindow` in reverse mode | same | Read-only address, nothing saved |
| Listen for Connections | `ListenerWindow` (one at a time) | 700×560 | |
| Saved Profiles | `ProfilesWindow` | 940×680 | List and detail |
| Saved Server Keys / Saved Certificate Decisions | `TrustLibraryWindow` (two instances by kind) | 720×560 | |
| Settings (Connection Defaults) | `SettingsWindow` | 860×640 | `NavigationView`, §8 |
| TidyVNC Help | `HelpWindow` | 720×640 | `SelectorBar`: Getting started, Acknowledgements, Licence |
| About (standard panel) | `AboutWindow` (small, not resizable) | 480×560 | Icon, name, version, copyright, credits, links |
| Import Connection Defaults / Import Recent Connections | `ImportWindow` (two kinds) | 660×640 | Step pages in a `Frame` |
| Owned fullscreen windows | `FullscreenSurfaceWindow` per display | display bounds | Borderless, no Mica |

Windows closes an app when its last window closes, so TidyVNC does the same:
closing the last window runs the same coordinated shutdown as File > Exit. A
listener window counts as a window. This differs from macOS, where the app stays
open with no windows.

Each window has its own taskbar button, grouped under TidyVNC. Window titles
reuse the macOS title text; a connected window shows the server first (for
example `server.example:1 – TidyVNC`) so taskbar thumbnails can be told apart.

## 3. Connection window

The layout keeps the macOS order from top to bottom:

1. **Title bar row.** App icon, window title, and the menu bar (§6) in the caption
   area, like Windows 11 Notepad. Caption buttons on the right.
2. **Address row.** Monitor glyph, *Server address* `TextBox` (Enter connects),
   then *Connect* (accent), *Disconnect* or *Cancel*, and a `ProgressRing` while
   connecting. Address errors appear under the box through the text box's
   description area, with an error glyph, exactly where macOS shows them.
3. **Toolbar row.** A `CommandBar` holding the same controls, in the same order,
   as the macOS toolbar row:

   | macOS item | WinUI control | Icon |
   | --- | --- | --- |
   | Recent connections (popover) | `AppBarButton` with a `Flyout` | History |
   | Saved profiles | `AppBarButton` | Folder |
   | Clipboard menu (Send/Receive toggles with sources) | `AppBarButton` with a `MenuFlyout` of `ToggleMenuFlyoutItem`s | Paste |
   | Connection actions (ellipsis) | `AppBarButton` with the Connection `MenuFlyout` | More |
   | Input | `AppBarButton` | Keyboard |
   | Scaling | `AppBarButton` | Zoom |
   | Encoding | `AppBarButton` | Equalizer |

   Every icon button has a tooltip and an automation name with the same text as
   the macOS `.help` and accessibility label.
4. **Gateway row.** *SSH gateway (optional)* text box with its help text.
5. **Notices.** `InfoBar`s for what macOS shows as inline banners and notices:
   first-use import offers (*Review import…* / *Not now*), history errors
   (*Reload history*), *Settings from profile: X*, and the credential notice
   (*Dismiss*). They stack in the macOS order.
6. **Desktop area.** The remote desktop view. When idle it shows the macOS empty
   state: *Connect to a desktop* and *Enter a VNC server address to begin*, or the
   current status text. The statistics overlay sits top-right on an acrylic
   panel and ignores the pointer, as on macOS.
7. **Status bar.** A thin bar with the connection state and the same fullscreen,
   window-command, keyboard-capture, remote-resize and clipboard messages and
   desktop size. Messages are announced politely to Narrator (§10).

The pre-session pages (loading, command-line or file display mapping, *Review
connection file*, retry actions, *Unable to start a connection*) replace the
desktop area inside the same window, as `ConnectionRoot` does on macOS.

The recent-connections flyout matches the macOS popover: address rows with a
*Via gateway* note and a remove button, clicking a row fills the address and
gateway fields without connecting, and a footer with *Reload* and *Clear recent
connections*.

## 4. Other windows

- **Saved Profiles.** List on the left (name, address, gateway, New profile)
  and editor on the right with `SettingsExpander` groups in the macOS order:
  Connection, Fullscreen, Remote resize, Clipboard, Security methods, Certificate
  files, Scaling, Input, Encoding. Footer: *Reload*, *Delete…*, *Cancel edits*,
  *Save*, *Open connection*. A dirty draft blocks switching profiles, as on macOS.
- **Trust libraries.** Destination field with *Ask again…*, a list of entries
  (endpoint, route, fingerprint) with *Forget for this destination*, and *Reload*.
  Confirmations use a flyout on the button (§5).
- **Listen for Connections.** Port `NumberBox` (default 5500), IPv4 and IPv6
  check boxes, *Start listening* / *Stop listening*, status and bound ports, and
  *Incoming connections* as cards with *Accept* and *Reject* and the 30-second
  expiry. The first time the listener binds a non-loopback address, an `InfoBar`
  explains the Windows Firewall prompt (SERVICES.md §10).
- **Import windows.** The same steps as macOS (choose source, review with
  acknowledgement, display mapping when needed, done page with *Done* and *New
  connection*), with *Back* and a primary action at the bottom right. The sources
  are named for Windows: *Current TidyVNC settings* and *TigerVNC settings*
  (registry, SERVICES.md §9).
- **Help.** The seven *Getting started* sections from the macOS catalog, with
  Windows keys and terms, plus the bundled README and licence text, and links to
  the project and issue tracker. F1 opens it.
- **About.** App icon, *TidyVNC*, version and architecture, copyright, the credits
  text from `Credits.rtf` converted once to the Windows resource, and links.
  Text is selectable.

## 5. Dialogs (macOS sheets)

macOS sheets become `ContentDialog`s attached to their window. WinUI shows only
one `ContentDialog` per window at a time and cannot open one from another. That
matches the macOS window, which also shows one sheet at a time, so the rule is:

- Each window has a **dialog presenter** that queues requests and shows the
  highest-priority one, in the macOS order: SSH, authentication/trust,
  information, input, fullscreen, resize policy, remote resize, scaling,
  connection options, security, encoding, export review. A prompt that arrives
  while a settings dialog is open waits, or, for authentication and trust,
  closes the settings dialog as Cancel first, exactly as macOS priority does.
- **Confirmations inside a dialog** ("Save this server key?", "Delete this
  profile?") become either a second step inside the same dialog (with *Back*) or
  a `Flyout` anchored to the button that asked. They never open a second dialog.
- **Buttons.** Primary action on the left of the pair, *Cancel* on the right, as
  Windows orders them. Enter triggers the dialog's `DefaultButton`; Escape always
  cancels. The default button matches macOS: *Cancel* on trust dialogs, the
  apply action on settings dialogs only when the draft is valid.
- **Size.** The default 548 epx width limit is raised per dialog to the macOS sheet
  width (520–590). Tall content scrolls inside the dialog. Very large content
  that macOS shows as a sheet (trust details, export review) keeps a fixed
  maximum height and scrolls.
- **Alerts** (connection problem, import unavailable) are `ContentDialog`s with the
  same titles, text and buttons as macOS: *Retry* only when recoverable and
  allowed, *Cancel* as default.
- **File dialogs** are the Windows common dialogs (SERVICES.md §4) with the macOS
  button labels where Windows allows them (*Review* for Open connection file).

## 6. Menus and keyboard shortcuts

Windows apps do not have a global menu bar. Each connection window has a compact
`MenuBar` in its title-bar area with the menus below. Other windows show only
the commands relevant to them. Menu items use Windows sentence case and an
ellipsis when they open a window or dialog.

| Menu | Item | macOS shortcut | Windows shortcut |
| --- | --- | --- | --- |
| File | New connection | ⌘N | Ctrl+N |
| | Listen for connections… | ⇧⌘L | Ctrl+Shift+L |
| | Open connection file… | ⌘O | Ctrl+O |
| | Save connection file as… | ⇧⌘S | Ctrl+Shift+S |
| | Import connection defaults… | – | – |
| | Import recent connections… | – | – |
| | Saved server keys… | – | – |
| | Saved certificate decisions… | – | – |
| | Saved profiles… | ⇧⌘P | Ctrl+Shift+P |
| | Settings | ⌘, (app menu) | Ctrl+, |
| | Close window | ⌘W | Ctrl+W |
| | Exit | ⌘Q (Quit, app menu) | – (Alt+F4 closes the window) |
| Connection | Disconnect | – | – |
| | Full screen | ⌃⌘F | F11 |
| | Minimize | ⌘M | – |
| | Resize window to desktop | – | – |
| | Resize remote desktop… | – | – |
| | Pan desktop ▸ left, right, up, down, return to top left | – | – |
| | Hold Ctrl / Hold Alt (toggles) | – | – |
| | Capture keyboard / Release keyboard | – | – |
| | Send Ctrl+Alt+Del | – | – |
| | Refresh desktop | – | – |
| | Connection settings ▸ Fullscreen displays…, Input…, Remote resize…, Scaling…, Connection…, Security…, Encoding… | – | – |
| | Connection information… | – | – |
| | Show connection statistics (toggle) | – | – |
| Help | TidyVNC help | ⌘? | F1 |
| | Project and source code | – | – |
| | Report an issue | – | – |
| | About TidyVNC | App menu | – |

The Connection menu is the same `MenuFlyout` content everywhere it appears: the
menu bar, the toolbar's More button, the fullscreen connection bar and the
desktop context menu. On macOS the About item also appears in the Connection
menu; on Windows it stays in Help only.

**Keyboard rule.** App shortcuts and menu access keys (Alt+F, …) work only when
keyboard focus is outside the desktop view. When the desktop view has focus,
every key goes to the remote computer, including Ctrl+N, F11, F1, Alt, F10 and
Tab. The viewer shortcut chord (§7) reaches the viewer from inside the desktop.
This is the same model as macOS, where the desktop consumes keys except the
chord; the difference is that ⌘ shortcuts on macOS rarely clash with remote
input, while Ctrl shortcuts on Windows always would.

## 7. Desktop focus, viewer shortcuts and fullscreen

- **Viewer shortcut modifiers** default to Ctrl+Alt, the retained default; the
  macOS labels *Control + Option* become *Ctrl + Alt*, and *Command* becomes
  *Windows key*. The chord actions are the same as macOS: modifiers alone release
  keyboard capture; with G capture the keyboard; with M open the Connection menu
  at the pointer; with Enter toggle full screen; with Space pass the next key
  combination to the remote computer.
- **AltGr is never the chord.** On layouts with AltGr, Windows reports it as
  Ctrl+Alt. The retained AltGr merging (DESKTOP.md §5) turns it into the remote
  AltGr key before the shortcut classifier sees it, so typing `@` on a German
  layout never opens the menu. Pressing the left Ctrl and left Alt keys still
  forms the chord.
- **Right-click** goes to the remote computer, as on macOS. The desktop context
  menu opens with the chord + M, not by right-clicking.
- **Clicking** the desktop gives it focus; the view shows a thin accent focus
  outline when it has keyboard focus, so it is clear where keys are going.
- **Fullscreen connection bar.** In full screen, a small bar slides down from the
  top centre of the primary surface when the pointer rests at the top edge for
  half a second, and hides again when the pointer leaves it unless pinned. It
  shows the server name and buttons for the Connection menu, statistics,
  *Minimize*, *Exit full screen* and a pin. This is the Windows counterpart of the
  macOS menu bar appearing at the top edge in full screen, and resembles the
  Remote Desktop connection bar Windows users know. The chord + M menu works
  without it, for keyboard users.
- **Minimize in full screen** minimizes all of the connection's surfaces; restoring
  returns to full screen. macOS has to leave full screen first; Windows does not.
- **Settings dialogs in full screen** open on the primary surface without leaving
  full screen, and release keyboard capture while open (DECISIONS.md D14).

## 8. Settings window

- A `NavigationView` with the pane on the left lists the macOS sections in the
  macOS order: Clipboard, Encoding, Input, Scaling, Security (with *Certificate
  files* as a child item), Connection, Remote resize, Fullscreen. macOS uses a
  drop-down section picker because of its window style; a navigation pane is the
  Windows equivalent and keeps the same names.
- Each field is a `SettingsCard` with the macOS label, a description line with
  the *Effective value* and its source (built-in, app, profile, connection, file,
  command line), and the control. Tri-state fields use a `ComboBox`
  (*Use default (On)*, *On*, *Off*) where macOS uses a pop-up button.
- A fixed footer holds *Restore built-in defaults*, *Cancel edits* and *Apply*.
  Nothing is saved until Apply, unlike the Windows Settings app, because the
  macOS draft/revision rules apply: a stale revision shows *Reload saved
  defaults* and *Discard edits and reload*.
- The per-connection settings dialogs (Input, Scaling, Encoding, Security,
  Connection, Fullscreen displays, Remote resize) reuse the same field controls,
  as the macOS sheets reuse the `*Fields` views.

## 9. Terminology and string style

Windows strings come from their own catalog (DECISIONS.md D20). They say the same
thing as the macOS strings, with these substitutions and Windows sentence case
for labels, buttons and menu items ("Save connection file as…", not "Save
Connection File As…"). Window titles and dialog titles also use sentence case.

| macOS text | Windows text |
| --- | --- |
| Remember on this Mac | Remember on this PC |
| Keychain | Windows Credential Manager (Credential Manager after first use) |
| Finder | File Explorer |
| Quit TidyVNC | Exit |
| Settings… (app menu) | Settings (File menu) |
| Command (⌘) | Ctrl, or Windows key when it means the remote Super key |
| Option (⌥) | Alt |
| Control + Option (viewer shortcuts) | Ctrl + Alt |
| Return | Enter |
| Enter Full Screen / Exit Full Screen | Full screen / Exit full screen |
| Local Network privacy guidance | Windows Firewall guidance (listener only) |
| Accessibility permission for keyboard capture | No permission needed; capture limits explained (secure desktop, elevated windows) |
| Dock | Taskbar |
| logical points | effective pixels |
| Application Support | AppData |

Messages from the core stay structured and are localized in the frontend, as on
macOS. Remote text is never a resource key or a format argument.

## 10. Accessibility

- **UI Automation.** Every control gets an `AutomationProperties.Name` with the
  macOS accessibility label and an `AutomationProperties.AutomationId` equal to the
  macOS accessibility identifier (`connection.endpoint`, `authentication.password`,
  `desktop.fullscreen`, `preferences.apply`, …). Shared identifiers let the parity
  tables and test scripts use the same names on both platforms.
- **Desktop view.** A custom automation peer with control type *Image*, name
  *Remote desktop* and the macOS help text. Panning is exposed through the UIA
  *Scroll* pattern (horizontal and vertical percentages, scroll by page), which is
  how Windows assistive technology expects scrollable content, instead of the
  macOS custom actions. *Invoke* focuses the view. The same RFB limit applies:
  Narrator cannot read the remote computer's interface
  ([ACCESSIBILITY.md](../native-ui/ACCESSIBILITY.md)).
- **Live regions.** The status bar and connection notices use
  `AutomationProperties.LiveSetting = Polite`; connection failures use the dialog.
- **Keyboard.** All controls reachable with Tab and arrow keys, visible focus,
  access keys on menus, F6 moves between the toolbar, notices and desktop areas.
- **Narrator and keyboard capture.** Narrator uses Caps Lock or Insert as its
  key. Caps Lock already passes through the retained hook; W6 checks Narrator
  commands while the keyboard is captured, and the Help text explains how to
  release capture.
- **Contrast themes.** All custom colours have `HighContrast` theme dictionary
  entries using system colours. Checked with each Windows contrast theme.
- **Text scaling.** Every window checked at 225% *Text size*; content scrolls
  rather than clipping.
- **Checks.** Axe.Windows automated scans on every reachable window and dialog,
  plus manual Narrator, keyboard-only and contrast passes (TESTING.md).

## 11. Sound, notifications and shell integration

- The remote bell plays the Windows default beep (`MessageBeep`), once per
  delivery turn as on macOS. Remote audio is not played; like the macOS app, the
  Windows app has no audio (DECISIONS.md D19).
- No toast notifications, tray icon or background process; macOS has none.
- Text copied from the remote computer is kept out of Windows cloud clipboard
  sync; it still appears in the local clipboard history if the user has that on
  (D21).
- Until builds are signed (D23), downloading the installer shows a SmartScreen
  warning, and Smart App Control blocks the app where it is turned on. The README
  and Help say so; the app itself shows nothing about it.
- **Jump List** tasks: *New connection* and *Listen for connections*. No recent
  server list, because that would expose server names in the shell, and macOS
  has no Dock menu.
- `.tidyvnc` files open in TidyVNC from File Explorer after the installer's
  association (with consent). `.tigervnc` files are opened explicitly with
  File > Open connection file, as on macOS.

## 12. Intentional differences from macOS (owner review)

| macOS | Windows | Reason |
| --- | --- | --- |
| Global menu bar with App, File, Edit, View, Connection, Window, Help | Per-window menu bar with File, Connection, Help | Windows has no global menu. The SwiftUI default Edit, View and Window menus hold no TidyVNC commands; text boxes keep their own cut/copy/paste menus |
| App stays open with no windows | Closing the last window exits | Windows convention |
| Nested confirmation dialogs | Confirmation step or flyout inside the dialog | WinUI allows one dialog at a time |
| Settings sheets wait until full screen ends | Dialogs open on the fullscreen surface | No Spaces on Windows |
| Menu bar appears at the top edge in full screen | Connection bar slides down | Windows has no menu bar to reveal |
| Minimize leaves full screen first | Minimize directly | Windows allows it |
| Title Case strings | Sentence case | Windows style |
| Keychain with per-app access | Credential Manager, readable by the user's processes | Platform capability; stated in Help |
| Keyboard capture needs Accessibility permission | No permission; cannot capture Ctrl+Alt+Del, Win+L or keys for elevated windows | Platform capability |
| Local Network consent guidance | Firewall guidance for the listener | Platform capability |
| No touch input | Touch gestures (DESKTOP.md §6) | Windows devices have touch screens |
| No Dock menu | Jump List with two tasks | Windows shell convention, without history |
| No system clipboard sync to consider | Remote text marked to stay out of cloud clipboard | Owner decision D21; keeps remote content on this PC |
