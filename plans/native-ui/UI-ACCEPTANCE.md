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
