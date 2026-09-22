# Native UI acceptance observations

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
