# Native security settings

Current implementation for N1.2/N4.5, recorded 2026-09-20. Physical acceptance,
full native authentication coverage remain open. This does not complete those parent
requirements or the native frontend migration.

## Shared policy and catalog

`viewer/core/SecurityOptions` provides an owned `SecuritySelection` and a read-only
catalog. Canonical names and IDs come from `rfb::secTypeName`/`secTypeNum`; availability
comes from `SecurityClient::supportedTypes()`. Neither path reads or mutates the
legacy `SecurityTypes` parameter. Compiled defaults currently allow every compiled
method, matching the existing C session initializer. The native UI preserves these
defaults rather than silently adopting a different security policy.

| Methods | Protection category | User authentication | Build dependency |
| --- | --- | --- | --- |
| None | Unencrypted session | None | Always |
| VncAuth | Unencrypted session | VNC password | Always |
| Plain | Unencrypted session | Username/password | Always |
| TLSNone, TLSVnc, TLSPlain | TLS without server identity verification | None, VNC password, username/password respectively | GnuTLS |
| X509None, X509Vnc, X509Plain | TLS with X509 verification | None, VNC password, username/password respectively | GnuTLS |
| RA2, RA2_256 | RSA-AES session encryption, 128/256-bit AES | Server selects password or username/password | Nettle |
| RA2ne, RA2ne_256 | RSA-AES authentication only, 128/256-bit AES | Server selects password or username/password | Nettle |
| DH, MSLogonII | Legacy authentication only | Username/password | Nettle |

The last two categories leave subsequent desktop traffic unencrypted. These are
presentation categories, not new cryptographic assurance decisions. Existing
`isSecure()` values, credential warnings, host-key verification, certificate fatal
policy and protocol algorithms are unchanged. In particular, AES bits alone do
not imply verified server identity or make all RSA variants equally secure.

The parser accepts at most 1024 bytes of comma-separated method names, with the
existing case-insensitive canonical names and optional surrounding ASCII whitespace.
Duplicates collapse to the first occurrence. Empty text means deny all. Empty items,
embedded NUL, unknown names and known-but-uncompiled methods fail the entire selection.
VeNCrypt is inferred from permitted subtypes; it cannot be enabled as a free-standing
bypass. Unsupported protocols such as Tight/SSPI are not added merely because the
shared name table recognizes them. No invalid field is silently removed.

This is an allow-list, not a client preference ranking. RFB and VeNCrypt continue
to select the first enabled method in the server's offer order. A profile's explicit
list replaces the preceding list as a whole; it is never unioned with defaults.

## C and Swift boundary

SECURITY_SELECTION (33554432), required by NativeRuntime, advertises two new
stateless exports (79 C exports total with TLS preflight, reconfiguration, sharing and remote layout): `tidyvnc_security_choice_at` and
`tidyvnc_security_resolve`. Size/version-tagged outputs contain only fixed-size
copied fields, numeric classifications and names. No mutable handles, platform types
or borrowed strings escape. Existing layouts are unchanged. End-of-catalog returns
NoChange without altering output; errors also preserve output. Domain Security (7)
distinguishes unknown type, unavailable type, too long and invalid syntax. Malformed
spans/headers retain ordinary bridge validation errors.

`defaults=1` requires an empty input and returns the compiled list. `defaults=0`
parses the supplied text, including an explicitly empty deny-all selection. The
catalog includes known methods absent from this build with `available=0` so controls
can explain their unavailability. Both exports catch exceptions, including
allocation failures, and use the existing fixed diagnostic text policy.

NativeSecuritySelection copies the bounded results; NativeSecurityPreferences holds
an optional canonical token list. Initial sessions retain the exact IDs and source
(compiled, app defaults, profile or caller/session). The existing session constructor
copies those IDs into the explicit core SecurityClient policy before any connection.

## Persistence and controls

Defaults schema 9 reads versions 1–8; profile schema 8 reads versions 1–7. The
optional `security` object accepts optional strings `types` and `tlsPriority`. The
priority field requires defaults 7/profile 6 or newer; method lists were introduced in defaults
6/profiles 5. For `types`, absence
inherits the previous layer; an empty string deliberately denies all methods.
Reads do not rewrite even valid noncanonical records. Explicit saves canonicalize
names and duplicates, preserve other settings/history, and retain existing revision,
cancellation and uncertain-write recovery semantics. Unknown fields, malformed or
unsupported choices and future schemas remain intact and block silent fallback.

Connection Defaults > Security provides an exact checklist grouped by protection
and credential mode. Known uncompiled choices are visible and disabled. The same
fields appear in a saved profile's Security Methods disclosure. Switching off the
override restores inheritance. An empty explicit selection stays valid and is
clearly labeled as refusing new connections. Invalid selections disable Apply/Save;
Cancel discards edits. Certificate Files is accessible from Security and keeps its
separate CA/CRL semantics described in [TRUST.md](TRUST.md).

App defaults and a freshly read profile resolve before constructing a new window's
session. Saving settings never renegotiates an active session. Existing windows,
including reconnects in those windows, keep their policy after defaults/profile
saves; a new window uses updated selections. An explicit connection-local security
editor can now change that window’s next-attempt policy while disconnected, as
specified below.

## Evidence boundaries

Core tests compare the complete catalog against compiled SecurityClient methods,
check canonical/invalid/unsupported/empty selections and concurrent readers, and
prove independence from mutated legacy configuration. Independent in-memory RFB
3.3/3.8 and VeNCrypt offer fixtures verify exact admission and retained server-order
selection; these fixtures stop before credential exchange. Pure-C tests check
metadata, defaults, bounds, headers, feature negotiation and unchanged failure outputs.

Native tests exercise earlier schema versions, explicit upgrades, unknown/unavailable
state preservation, canonical writes, whole-list source precedence and editor gating.
Two actual native sessions connect to independent None-only loopback servers: the
VncAuth-only default rejects the offer while a None-only profile connects. Saving
an empty list affects only a subsequently created window. These tests do not claim
full native TLS/RSA-AES/DH/MSLogonII authentication acceptance.

Ten new light/dark render fixtures cover inherited, explicit, empty and invalid
selections plus all method groups. Physical scrolling, focus, keyboard/VoiceOver
and file-picker acceptance remain separate gates. No user settings, trust records
or credentials are changed by these isolated fixtures.

## Advanced TLS priority

Connection Defaults > Security and profile Security Methods now include Advanced
TLS Priority. `security.tlsPriority` is independent of the method list: nil inherits,
empty explicitly resets to the GnuTLS library default, and a nonempty value selects
a custom expression. Text is preserved exactly, bounded to 4096 UTF-8 bytes with no
NUL. A profile can override one security field and inherit the other. The value and
source are captured in a new window; later defaults/profile saves do not change existing windows.

TLS_PRIORITY_VALIDATION (67108864), required by NativeRuntime, adds the stateless
`tidyvnc_tls_priority_validate` export. Shared `validateTLSPriority` uses a private
GnuTLS priority cache. It accepts a usable expression for X509 TLS or the existing
anonymous-TLS form, which appends `:+ANON-ECDH:+ANON-DH`. The suffix is shared with
the retained TLS loader. This preserves anonymous-only configurations that have no
usable certificate suites before the suffix is added. It does not establish peer
compatibility or promise that every selected method can negotiate the expression.

Empty expressions succeed without GnuTLS; nonempty expressions return Unsupported
in builds without it. C session creation also rejects a nonempty priority in those
builds rather than ignoring it. Invalid expressions return InvalidArgument with
Security reason INVALID_TLS_PRIORITY (5); oversized text returns ResourceLimit with
TOO_LONG (3). Malformed spans retain ordinary bridge validation errors. No expression
is included in diagnostics or stored in process-global settings.

GnuTLS initialization/named-priority resolution may consult library configuration.
Preferences/profile actors preflight on reads and before writes; view bodies only
check bounds/NUL and method selection. Apply/Save reports a correctable expression
error without writing or changing the revision. Unsupported/corrupt stored values
remain intact. The C constructor copies bounded text without parsing or file IO;
the protocol worker configures the actual TLS session on each attempt. Configuration
changes between preflight and handshake can still cause connection failure.

Tests cover exact persistence, legacy schema preservation, strict nested fields,
prewrite rejection, independent inheritance, Apply/Cancel and immutable per-window
captures. Core tests cover concurrent preflights, anonymous-only policy, invalid and
bounded expressions and unavailable builds. A real loopback peer restricted to TLS
1.2 rejects a TLS 1.3-only client before credentials. Eight light/dark render fixtures
cover inherited, custom, explicit default and unavailable controls; these are not
physical keyboard/VoiceOver acceptance or full native TLS authentication proof.

## Connection-local security and reconnect

Connection > Connection Settings > Security (also available in the connection
actions menu) opens a draft while idle, disconnected or failed. Disconnect first
when connected. Apply commits the next-attempt policy synchronously after off-UI
TLS preflight; Done closes the editor, and Connect starts a new attempt. It does not
automatically disconnect or reconnect, update defaults/profiles, or mutate another
window. Methods, priority and CA/CRL fields can restore this window’s initial values;
those initial values are stable snapshots, not a reread of current saved defaults.
The sheet identifies the initial method/priority sources or a connection override.

SECURITY_RECONFIGURATION (134217728), required by NativeRuntime, adds
`tidyvnc_session_security` and `tidyvnc_session_set_security` (79 exports total).
The getter returns an owned bounded snapshot, revision, generation and editability.
The setter compares both identities under the worker’s command-admission mutex and
requires a reusable session with no active attempt or pending terminal drain. It
rejects connecting, authenticating, connected, disconnecting, stale and closing
states without mutation. Concurrent edits against one revision admit exactly one.
Revision increments are synchronous and produce no operation/completion event.

The setter copies bounded policy without GnuTLS parsing or file IO. A private
immutable policy snapshot is installed by the serialized worker before the next
attempt is prepared. The existing session, frame/input/clipboard/authentication
mailboxes and command identities remain intact. Retained policy snapshots stay
immutable; old generations cannot reconfigure a later attempt. CA/CRL selections
still require successful loading during the next X509 handshake.

The native editor preflights on its actor, then checks cancellation and performs
core compare-and-replace. A competing edit or connection forces reload. Closing or
dismissing cancels preflight, and reopening/Connect are gated until cleanup joins.
Authentication retains presentation priority. The connection controller clears
its retained reconnect credentials and trust-attempt state only after a successful
policy commit; stored Keychain items and saved trust decisions are unaffected.
Apply/Cancel uses private drafts and never touches durable settings.

Tests race eight writers, keep old snapshots, reject setup/authentication/active and
held-observer drain states, and reconnect the same worker with a changed allow-list.
Native tests use four real None-only peers: one window connects, disconnects, rejects
a peer under its new VncAuth-only policy, restores its initial selection and reconnects;
another stays connected throughout. Draft cancellation, revision conflicts, source
restoration, full 4096-byte text copies, controller lifecycle and sheet renders are
covered. Physical menus, scrolling, picker focus and VoiceOver remain acceptance gates.
