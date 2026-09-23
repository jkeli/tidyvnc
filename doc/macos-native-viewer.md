# The native macOS viewer (preview)

TidyVNC has a native SwiftUI/AppKit viewer for macOS. It is built with
`TIDYVNC_UI=SWIFTUI` (see [BUILD-MACOS.md](../BUILD-MACOS.md)). **The retained FLTK
viewer is still the default macOS frontend.** The native viewer becomes the
default only after the acceptance review in
[plans/native-ui](../plans/native-ui/TODO.md) is complete.

The protocol, security and encoding code are the same shared core, so a server
that works with the FLTK viewer should behave the same with the native one.
This page covers what differs for you: where settings live, moving your data
across, and going back.

## Where the native viewer keeps things

| Data | Location |
| --- | --- |
| App-wide connection defaults (TidyVNC › Settings…) | macOS preferences for `io.github.jkeli.tidyvnc` |
| Recent servers and saved profiles | `~/Library/Application Support/io.github.jkeli.tidyvnc.native/` |
| Saved certificate exceptions and server keys | `$XDG_STATE_HOME/tidyvnc/native-trust/` (default `~/.local/state/tidyvnc/native-trust/`) |
| Remembered passwords ("Remember on this Mac" only) | Keychain, service `io.github.jkeli.tidyvnc.credentials.v1` |

The FLTK viewer's files are never written by the native viewer:
`~/.config/tidyvnc/default.tidyvnc`, `~/.local/state/tidyvnc/tidyvnc.history`,
the upstream `~/.config/tigervnc/` files, and the FLTK certificate exceptions in
`~/.local/state/tidyvnc/x509_known_hosts`.

## Bringing your FLTK or TigerVNC settings across

Nothing is migrated automatically. On first launch the connection window offers
two separate reviews, which you can also run later from the File menu:

- **File › Import Connection Defaults…** reads the current TidyVNC or legacy
  TigerVNC defaults file. The review lists what will change and what is
  excluded before you accept. Passwords, server addresses, security settings,
  certificate files, trust decisions, tunnel commands and recent servers are
  never imported as defaults.
- **File › Import Recent Connections…** imports the server history as a
  separate choice.

A matching certificate exception that the FLTK viewer saved in
`x509_known_hosts` is honoured when you connect; that file is only read. A new
decision is saved only in the native store, and only after you confirm it.

## Passwords

The password prompt offers three lifetimes:
- **Use once**: the default.
- **Retain for this session's reconnect**: like FLTK's "Keep password for
  reconnect".
- **Remember on this Mac**: stores the password in the Keychain, and only after
  authentication succeeds.

Use Saved Password and Forget Saved Password act only on the entry for that
server.

`VNC_PASSWORD` (with `VNC_USERNAME` when needed) supplies launch credentials to
the first connection window, including an explicit Retry in that window. They
are never saved.

## Server identity

An untrusted certificate or new RSA-AES server key opens **Verify server
identity**. Return and Escape cancel. **Connect Once** trusts the server for
this attempt only. **Save … and Connect** asks you to confirm the scope (this
address, port and route) before saving. Saved decisions can be reviewed and
forgotten in File › Saved Certificate Decisions… and File › Saved Server Keys….
Always compare the fingerprint with the server administrator.

## Connection files

The native viewer opens `.tidyvnc` and legacy `.tigervnc` connection files.
**File › Save Connection File As…** writes a compatibility file after showing
which settings the format cannot carry. It never writes passwords. The FLTK
viewer can open these files.

## Command line

The native executable accepts the same viewer options (for example
`-SecurityTypes`, `-X509CA`, `-via`, `-listen`, `-FullScreen`). Its `--help`
lists them together with the native-specific notes:
- `-via` accepts `[user@]host` or `ssh://[user@]host[:port]` and captures
  supported `~/.ssh/config` settings.
- Arbitrary SSH commands, proxy hops and `VNC_VIA_CMD` are not supported.
- SSH forwarding cannot be combined with `-listen`.

## Going back to the FLTK viewer

Quit the native viewer and start the FLTK viewer. It uses its own untouched
settings and history, and it does not change the native stores.

To take a connection across, save it with **File › Save Connection File As…**
and open that file in the FLTK viewer. Remembered passwords stay in the
Keychain and are not copied. The FLTK viewer asks for the password as it always
has.

## Accessibility

Every native control has a VoiceOver label. The remote desktop is announced as
an image with focus and pan actions. RFB carries only pixels, so the remote
computer's interface itself is not readable by VoiceOver. See
[plans/native-ui/ACCESSIBILITY.md](../plans/native-ui/ACCESSIBILITY.md), which
also notes that the default viewer shortcut modifiers (Control + Option) overlap
the VoiceOver modifier.
