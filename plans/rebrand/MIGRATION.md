# Native viewer migration

TidyVNC reads both exact version-1 headers. New saves use `.tidyvnc` and the
TidyVNC header; there is no legacy export. Save As appends the new extension and
asks before replacing an existing destination. Explicit paths remain usable.

On macOS/POSIX, writable paths are:

| State | XDG override | Default |
| --- | --- | --- |
| Preferences | `$XDG_CONFIG_HOME/tidyvnc/default.tidyvnc` | `~/.config/tidyvnc/default.tidyvnc` |
| History | `$XDG_STATE_HOME/tidyvnc/tidyvnc.history` | `~/.local/state/tidyvnc/tidyvnc.history` |
| Known hosts | `$XDG_STATE_HOME/tidyvnc/x509_known_hosts` | `~/.local/state/tidyvnc/x509_known_hosts` |
| CA/CRL | `$XDG_CONFIG_HOME/tidyvnc/x509_{ca,crl}.pem` | `~/.config/tidyvnc/x509_{ca,crl}.pem` |

Relative XDG overrides are ignored, as before. The shared legacy server path
helpers have not been redirected. Registry and Java preferences migration remain
part of their deferred platform rollout.

The connection dialog offers preferences and history separately when the
corresponding new file is absent. Legacy candidates are the corresponding
`tigervnc` XDG directory and then `~/.vnc`. Preferences import selects the
supported non-security viewer preferences, omitting the last server address;
history import is the separate explicit choice for server addresses. New values
always win: imports never overwrite an existing file, including a malformed one.
Repeated import does not merge live applications or duplicate history. Unknown
parameters retain the parser's existing diagnostic/ignore behavior; malformed
syntax and invalid recognized values fail and restore previous in-memory values.

Passwords, security types, trust databases, CA/CRL files, credentials and tunnel
commands are not copied. To keep an existing certificate path, select it
explicitly in Options or pass `-X509CA`/`-X509CRL`. Certificate verification has
not been weakened. Old trust and settings files are untouched; the fork has its
own trust store. Automated sensitive-state migration is intentionally unavailable.

New preference/history files are created privately (0600). Imported files retain
the source owner permissions, restricted to 0600, so a read-only source stays
read-only. Atomic replacement
preserves existing destination permissions; imports use no-overwrite commits.
No old files or application bundles are deleted. TidyVNC's macOS bundle identity
is distinct, so macOS may require fresh input/accessibility permissions. The app
does not modify privacy permissions itself. Interactive coexistence, permission
and file-association checks remain open in TODO.md.
