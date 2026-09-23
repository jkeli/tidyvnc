# Native UI acceptance observations

## 2026-09-22 — Release validation access check

While the clean Release build was compiling, CUA selection of the current
`build/native-ui-frontend/app/Debug/TidyVNC.app` returned “Running application not
found.” Inventory then showed multiple TidyVNC registrations; selecting by bundle
identifier was explicitly ambiguous. Selecting the older
`build/native-app/app/Debug/TidyVNC.app` by full path returned “Sky Computer Use
native pipe closed before response.” No subsequent window, keyboard, profile,
credential, trust or preference action was sent. These responses do not prove an
app crash or any interactive acceptance. Release automated fixtures and packaged
CLI evidence remain separate from the unresolved actual-window gates.

## 2026-09-22 — bundle/trust localization follow-up access check

After the final bundle build and reloading CUA documentation, selecting the app
by the full path to `build/native-app/app/Debug/TidyVNC.app` again
returned “Sky Computer Use native pipe closed before response.” No follow-up UI
action was sent. Selection may launch an app, but this response does not establish
which version is running, a crash, the old draft state or any interactive acceptance.
Metadata lookup and trust rendering/policy evidence are isolated tests only.

## 2026-09-22 — structured recovery follow-up access check

After reloading CUA documentation, selecting the repository app bundle by its full
path again returned “Sky Computer Use native pipe closed before response.” No
follow-up UI action was sent. Selection may launch an app in the background; the
response did not establish which version was running or expose its windows. No
new crash, profile-draft, keyboard or actual-app acceptance conclusion follows.
The structured recovery evidence remains isolated fixtures and build/package tests.

## 2026-09-22 — fullscreen/resize follow-up access check

A fresh CUA `getApp("TidyVNC")` again reports “native pipe closed before response.”
No UI action or relaunch was sent, and no new app-crash or interactive acceptance
conclusion follows. The new fullscreen/resize evidence is offscreen fixture
rendering only. Resume actual-app checks through CUA when it recovers.

## 2026-09-22 — rebuilt Help/About, profile connector failure reproduced

CUA native access recovered at the start of this follow-up. The older app was
quit through Command-Q and the rebuilt app was launched by its full repository
bundle path. Actual Help menu activation opens the native Help window. Getting
Started, Acknowledgements and Licence all load; accessibility exposes the bundled
README and GPL text. The 720×640 guide screenshot shows wrapping text, scrollable
topics and visible project/support links. Tab reaches the topic control and Right
moves focus to Acknowledgements; this alone does not establish keyboard activation.
Command-W closes Help. About displays TidyVNC 1.16.80, the app icon, upstream
copyright and contributor credits; its screenshot was inspected. Escape closes it.
These are actual app observations, separate from offscreen fixture evidence.

Command-Shift-P opens the empty Saved Profiles window. Clicking New Profile again
caused the CUA native pipe to close before returning state. A subsequent read also
failed. The app remained alive (PID 53970 at this observation, sleeping at 0% CPU);
no app crash was established. No Save or credential/trust action was invoked.
The resulting unsaved draft is unverified and the running process predates the
final localization/layout rebuild. Relaunch through CUA before further acceptance
when access recovers. Do not substitute other UI-automation technologies.

VoiceOver, complete keyboard activation, minimum-size interactive Help,
profile editing, trust/authentication interactions and installed-app acceptance
remain open. Screenshots were inspected inline; archival deliverables remain open.

## 2026-09-22 — built connection window

The native app was selected through cua_repl using
`/Users/kyle/Projects/tidyvnc/build/native-app/app/Debug/TidyVNC.app`.
The bundle identifier is shared by installed/release builds and is ambiguous.
Native UI inspection now works; earlier connector failures are not a current blocker.

Observed through native accessibility state and window screenshots in the task:

- At the supported 640-point minimum width, the original single-row toolbar
  compressed the address field to roughly eight characters.
- After splitting the address/action row from auxiliary controls, the rebuilt
  window gives the field approximately 490 points. The toolbar and desktop empty
  state fit without clipping in the observed 640 × 558 window.
- Empty endpoint disables Connect. `127.0.0.1::9` with `gateway.invalid` enables
  Connect without initiating a connection.
- `bad target` and `ssh://gateway.invalid:0` show inline errors and disable Connect.
  The supported SSH configuration disclosure is present and readable.
- The clipboard menu exposes Send clipboard to server, Receive clipboard from
  server, and both Built-in default source labels. Menu screenshot capture was
  unavailable; these menu observations come from accessibility state.
- Escape dismisses the menu. Both form fields were restored empty. No connection,
  import, saved setting, clipboard toggle or credential operation was performed.

Final build succeeds; strict deep app signature and 32 terminal cases pass.
Logs: `/tmp/tidyvnc-connection-toolbar-final-build.log` and
`/tmp/tidyvnc-connection-toolbar-terminal.log`.

This does not establish connected clipboard traffic/activation, keyboard/VoiceOver
acceptance, actual SSH/certificate-sheet interaction, installed-app behavior,
physical display transitions, or complete PLAN parity. Screenshots were inspected
inline; archival screenshot deliverables remain separate work.


## 2026-09-22 — profiles inspection interrupted

The Saved Profiles window opened and exposed the empty library, New Profile,
Reload, disabled Save/Open/Delete/Cancel Edits, and its explanatory text. A click
on New Profile was sent, but the connector then reported “native pipe closed before
response.” Re-reading state and resetting/rebinding cua_repl did not recover it.
The native executable (vncviewer, PID 17988 at the time) remained alive, sleeping
at 0% CPU; no app crash was established. Do not mark draft-screen acceptance passed.
No Save action was invoked. Any resulting unsaved draft remains unverified.
The running native instance predates the host-key save-failure rebuild and should
be quit/relaunched through the UI connector before inspecting that new behavior.

## 2026-09-23 — stale instances, quit and current connection window

Computer-use access to `io.github.jkeli.tidyvnc` was granted. Two older dev
instances were still running (the earlier `build/native-app` process PID 53970 and
a pre-rebuild `build/native-ui-frontend` process); the shared bundle identifier
made the connector pick one without a choice.

- The earlier interrupted profile draft (see 2026-09-22) was on screen: New Profile
  had opened an empty draft editor with Save and Open Connection disabled, Cancel
  Edits and Discard Edits and Reload available, and Connection/Fullscreen sections
  showing App default values. Cancel Edits returned to the empty library ("No saved
  profiles", "Choose a profile or create a new one"); nothing was saved. This is
  an old build, so it closes the earlier "unverified draft" question only.
- TidyVNC › Quit TidyVNC terminated each stale instance with its Help, Saved
  Profiles and connection windows open; no process remained. This is an actual
  menu Quit of idle windows, not quit with pending IO/auth/store work (N6.10).
- The current Debug build (launched from `build/native-ui-frontend`) opened one
  960×700 connection window showing the defaults-import offer (Review Import… /
  Not Now), the server address and SSH gateway fields, a disabled Connect button,
  labelled toolbar controls (Recent connections, Saved profiles, Clipboard sharing,
  Connection actions, Input/Scaling/Encoding settings), the "Connect to a desktop"
  guidance and a "Ready" status. Not Now was deliberately not pressed: this build
  shares the user's real preference domain.

To avoid writing the user's real history/preferences during a connected check,
`tests/macos/isolated-app.py` now launches a copy with a UUID bundle identifier,
fresh HOME/XDG roots and a relocated Foundation home, reusing the protocol
baseline's `native-isolation.swift` verification and cleanup. The loopback peer
executable accepts `bell` and `keys <keysym>` commands for such checks. The copy
launched and passed isolation, but the computer-use access request for its
bundle identifier was **denied**, so no connected, keyboard, bell or menu
interaction was performed; the copy, peer and fixture domains were removed.
Connected-window, keyboard, VoiceOver and physical acceptance remain open.

## 2026-09-23 — isolated copy: first use, keyboard connect, display, disconnect, quit

With the user's approval, computer-use drove an isolated copy launched by
`tests/macos/isolated-app.py` (bundle `io.github.jkeli.tidyvnc.protocol-fixture.<uuid>`,
fresh HOME/XDG, `-SecurityTypes=None -SendClipboard=0 -AcceptClipboard=0`) against
the loopback peer (`native-loopback-peer`, 2×2 red/green/blue/white pattern). The
user's current Space was a full-screen app, so only background (accessibility and
raw window input) control was available; the full-screen approval was not answered.

Observed in the actual app:

- First launch with an empty home shows both first-use offers: "Review Import…"
  for defaults and a separate "Review History…" for recent servers, each with Not Now.
- Review Import… opens "Import Connection Defaults", which explains what is
  excluded (passwords, addresses, security settings, certificate files, trust
  decisions, tunnel commands, recent servers) and offers the current and legacy
  sources separately. Reviewing the current source with no file shows "No defaults
  file was found for that source…" and keeps the window open. Escape closes it.
- Typing `127.0.0.1::62075` into the address field enables Connect; **Return alone
  connects** (keyboard-first). The window then shows the desktop, "Connected",
  "2 × 2", Disconnect in place of Connect, a disabled address field and enabled
  input/scaling/encoding controls. The first-use offers are dismissed on connect.
- **Displayed pixels:** the 2×2 pattern appears with correct orientation and channel
  order (red top-left, green top-right, blue bottom-left, white bottom-right),
  bilinear-scaled to fit and letterboxed. First actual-app displayed-pixel evidence.
- The app log shows redacted security details (`Choosing security type [redacted]`).
- Disconnect returns to "Disconnected" with the address kept and editable.
- TidyVNC › Quit TidyVNC exits cleanly after the session; the successful
  connection was recorded only in the isolated Application Support store.

Not established (the app was never active or frontmost): remote keyboard/pointer
input (by design, input is sent only from the focused desktop of the active app;
the peer received no keys), connected Connection-menu commands (the menu showed
"No active connection" because routing follows the key window), transient
popovers such as Recent connections, VoiceOver and physical displays. Repeat with
full-screen control from a regular desktop Space.

## 2026-09-23 — isolated copy with full-screen control: input, commands, sheets, errors

With the user's approval ("Yes, now"), computer-use took full-screen control from a
regular desktop Space and drove an isolated copy (`tests/macos/isolated-app.py`,
UUID bundle identifier, fresh HOME/XDG, `-SecurityTypes=None -SendClipboard=0
-AcceptClipboard=0`) against `native-loopback-peer` over a FIFO (`status`, `resize`,
`bell`, `keys <keysym>`). Peer counts are the RFB KeyEvents it received. The copy,
peer and fixture domains were removed afterwards.

Observed in the actual, frontmost app:

- **Keyboard input** from real key events reaches the peer paired: `b`, Shift+`C`,
  Return each down=1 up=1. (Computer-use `type` posts text events with keycode 0 and
  no key-up; they left a keysym held until the next real press. That is a tooling
  artifact, not app behavior, so only `key` events were used as evidence.)
- **Connection menu** while connected lists Disconnect, Enter Full Screen, Minimize,
  Resize Window to Desktop, Resize Remote Desktop…, Pan Desktop, Hold Control,
  Hold Alt, Capture Keyboard, Send Ctrl-Alt-Delete, Refresh Desktop, Connection
  Settings, Connection Information…, Show Connection Statistics and About TidyVNC….
- **Send Ctrl-Alt-Delete** sent Control_L, Alt_L and Delete, each down=1 up=1.
- **Hold Control** latched Control_L (down with no up); a real `x` then arrived as
  its own down=1 up=1 while Control stayed down; toggling Hold Control off released
  it (Control_L up count caught up to its down count).
- **Connection Information…** sheet: server, desktop name, RFB 3.8, security None,
  depth 24 (32 bpp) little-endian rgb888, requested Tight / last used raw, 20,000
  kbit/s estimate, 2 × 2, 1 frame, remote resize unavailable, input "Keyboard and
  pointer", middle-button emulation and both clipboard directions Off, with Copy
  Diagnostics and Done. Copy Diagnostics was not pressed (the system pasteboard is
  not isolated).
- **Show Connection Statistics** overlay; a server-initiated **resize** to 3 × 1
  updated the overlay (3 × 1, 2 frames), the status bar and the displayed desktop
  live. A server **bell** was sent; audible output was not observable by the harness.
- **Input Settings** sheet: toggling View only changes the source label to "This
  connection override" and enables Apply. After Apply a real `z` never reached the
  peer (down=0 up=0); reopening shows the applied override; clearing it and applying
  restores input (`z` down=1 up=1).
- **Scaling Settings** sheet: the Scaling quality pop-up (Nearest neighbor /
  Bilinear / Area averaging) switched to Nearest neighbor; after Apply the 3 × 1
  desktop was shown as three sharp blocks instead of a bilinear gradient.
- **Connection Encoding** sheet: clearing "Choose encoding and quality
  automatically" enables Preferred encoding and Full color and turns Done into
  Cancel; Cancel discards the draft (reopening shows the built-in automatic state).
- **Disconnect** returns to "Disconnected" with Connect and the address editable
  and input/scaling/encoding toolbar actions disabled.
- **Recent connections** popover lists the isolated history entry with a clear
  button, Reload and Clear Recent Connections; choosing the entry fills the address.
- **Cancel during a stalled handshake** (the single-connection peer accepts TCP but
  never answers a second session) returns to Disconnected promptly.
- **Refused connection** (`127.0.0.1::1`, typed then Return) shows a "Connection
  Refused" alert with port/service guidance and Cancel (default) and Retry; Cancel
  leaves "Connection failed" in the window and status bar.
- **App Settings** (TidyVNC › Settings…) opens "Connection Defaults" separately from
  the live sheets; editing a clipboard default shows "App default override" and
  enables Cancel Edits / Apply; Cancel Edits reverts to "Uses the built-in default".
- TidyVNC › Quit TidyVNC exits cleanly with an open Settings window.

Still not established: VoiceOver and high-contrast/reduced-motion passes, full
keyboard-only traversal of every sheet, fullscreen and multi-display behavior,
clipboard exchange (kept off because the pasteboard is not isolated), audible bell,
authentication/trust sheets interactively, and physical 1×/2× displays.

## 2026-09-23 — isolated copy: authentication and certificate-trust sheets

Background control (no full-screen takeover) of a new isolated copy against a
scratch loopback peer offering either VncAuth or VeNCrypt X509None with a fresh
self-signed certificate. No password was typed: the sheet's structure and
cancellation were exercised, and successful password authentication remains
covered by `tests/integration/macos-auth-smoke.py` (VNC_PASSWORD).

- **Authentication sheet** (VncAuth): shows "Authentication required", the host,
  the orange credential-protection warning with the separate note that it
  describes credential protection rather than traffic encryption, a secure
  Password field, Password lifetime (Use once / session reconnect / Remember on
  this Mac), Use Saved Password and Forget Saved Password, and Cancel /
  Authenticate. Cancel returns to "Disconnected" with no alert and no retry; the
  peer saw the connection close. Escape could not be sent in background mode, so
  it was not exercised.
- **Defect found and fixed:** the credential-protection warning was **truncated**
  to "…may not adequately pro…". The presented sheet was one point shorter than
  the text's wrapped height. Offscreen renders in a larger window had hidden this.
  The warning, its caption and the error text now keep their full wrapped height
  (`fixedSize(horizontal: false, vertical: true)`). A new
  `NativeSettings.DraftRendering` check presents the real sheet on a window and
  counts the rendered warning lines. It fails at 1 line without the fix and passes
  at 2 with it.
- **Trust sheet** (untrusted certificate): shows "Verify server identity", the
  destination, "No active saved certificate exception matches this server",
  "Certificate verification failed", issuer-not-trusted and name-mismatch reasons,
  subject `localhost`, and a SHA-256 fingerprint that **matches** `openssl x509
  -fingerprint -sha256` of the peer certificate. Also shown: scope notes, Save
  Exception and Connect…, Cancel and Connect Once.
- **Connect Once** completes the TLS session; the 64×48 desktop shows orange left
  and blue right (correct channel order). After Disconnect and Connect, the trust
  sheet appears again, so nothing was saved.
- **Save Exception and Connect…** asks for confirmation. The prompt says the
  decision applies to `127.0.0.1::52681`, can be forgotten in Saved Certificate
  Decisions, and that the certificate problems are still present. Save and Connect
  connects; the next reconnect goes straight to the desktop. The exception was
  written only to the isolated `XDG_STATE_HOME/tidyvnc/native-trust`.
- **File › Saved Certificate Decisions…** lists the destination with a saved SPKI
  SHA-256 that **matches** the peer key (`openssl pkey … | dgst -sha256`).
  Forget for This Destination asks for confirmation (destructive Forget Saved Key
  / Cancel). The window then reports that existing connections are unchanged, and
  the live session did stay connected. The next connect shows the trust sheet
  again, now noting that the saved key was forgotten.
- **Cancel** on the trust sheet leaves "Disconnected"; the viewer never continued
  past TLS.
- File › Save Connection File As… and the Connection menu require the key window,
  so they were unavailable in background mode (Save-panel Command-Q remains open).

## 2026-09-23 — keyboard pass access declined

A further isolated copy was launched for a keyboard-only pass: Escape on the
password prompt, Tab traversal, and Command-Q with the Save panel open (N3.3).
The access request, which included system key combinations, was **denied**. No
interaction took place; the copy, the peer and the fixture domains were removed.
These keyboard checks remain open.

## 2026-09-23 — automated accessibility-label audit of the actual app

`tests/macos/accessibility-audit.py <TidyVNC.app>` launches isolated copies
against loopback peers it starts (no security, VncAuth, VeNCrypt X509None with a
throwaway certificate). It drives them only through the macOS accessibility API
(`tests/macos/AccessibilityAudit.swift`: AXPress, AXConfirm and AXValue; no
synthetic mouse or keyboard input, and the app is never activated). The caller
must be an accessibility client.

Every interactive element reached must expose a label VoiceOver can speak: a
title, description, title element, placeholder or help. System parts named by
their subrole count as labeled: window buttons, stepper arrows and scroll-bar
pages.

The audit covers **26 screens**:
- the connected and disconnected connection window;
- the Input, Scaling, Encoding and Connection Information sheets;
- the Recent connections popover;
- all eight Settings sections;
- Saved Certificate Decisions, Saved Server Keys and Saved Profiles;
- Import Connection Defaults and Import Recent Connections;
- the three Help topics and About;
- the VncAuth authentication sheet and the certificate trust sheet.

Raw results: [accessibility-audit-2026-09-23.json](accessibility-audit-2026-09-23.json).

**Defects found and fixed.** Six controls had no spoken label:
- in the Encoding sheet and Settings: the Preferred encoding and Reduced colors
  pop-ups and the Compression and JPEG quality steppers;
- the Settings Section pop-up;
- the Help topic picker.

SwiftUI showed their label text visually but exposed no accessibility title for
them (for steppers the text is a sibling of the incrementor). Each now has an
explicit `accessibilityLabel`, and the steppers also have an `accessibilityValue`.

**Result.** 26/26 screens pass with 0 unlabeled controls and 0 errors. One
system-provided element is reported separately: the standard AppKit About
panel's credits text, which speaks its content and cannot be labeled by the app.

**Observed limitations:**
- SwiftUI text bindings ignore accessibility value writes: setting the address
  field's AXValue does not change the endpoint used by Connect or Return.
  VoiceOver typing uses normal text input and is unaffected. The audit therefore
  launches a separate copy per prompt.
- File › Listen for Connections was not audited, because it opens a network
  listener.

This is an automated label audit. It is not a VoiceOver listening pass (reading
order and announcements), and it does not cover keyboard traversal.
