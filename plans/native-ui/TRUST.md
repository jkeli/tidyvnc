# Native trust policy and remaining integration

Recorded 2026-09-20 for N3.12/N4.3. This documents current implementation and the
remaining gates; it is not acceptance of the full trust-store requirement.

## Shared certificate exception policy

`viewer/core/CertificatePolicy` now owns the X509 exception mask previously embedded
in `vncviewer/CConn.cxx`. FLTK uses the same classifier. The overridable status bits
remain invalid, signer-not-found, signer-not-CA, not-yet-valid, expired, insecure
algorithm and unexpected owner. Revocation, bad signature, invalid revocation data,
signer constraints, mismatched required identity/purpose, missing/invalid OCSP,
unknown critical extensions and all unknown/new bits are fatal. A zero status does
not represent failed verification and cannot authorize an exception.

This preserves the existing exception boundary; it does not reinterpret an allowed
exception as a verified server. GnuTLS still performs certificate/hostname/chain
verification before invoking the trust callback. System trust remains enabled. Native configured-file failures now stop X509
setup, as described below; retained parameter consumers preserve their historical
load-warning behavior. No roots are installed in the system trust store.

PromptAuthentication rejects an affirmative reply for a non-overridable certificate
with PolicyRejected. The request stays pending so it can still be cancelled; a
frontend cannot bypass the rule by enabling a button or retrying the same reply.
The C bridge maps this result to Unsupported. Existing request/generation/timeout
checks run first. No locks are held while invoking UI, waiting for its response,
or executing external store IO.

The stateless `tidyvnc_certificate_policy_get` ABI returns stable presentation
reason flags, fatal raw bits and the override decision. It preserves output on
header/null failures and is available without a TLS build dependency. GnuTLS
headers are checked for matching status values when present; diagnostic assertions
for newer enum names are version-gated to avoid raising the existing header floor.
The native runtime requires CERTIFICATE_POLICY (2097152). Current C exports: 71, including the security catalog described in [SECURITY.md](SECURITY.md).

## Native presentation and one-time decisions

NativeTrustPresentation derives typed problems and fingerprints from owned bounded
prompt data. A certificate must decode before the UI enables Connect Once; zero,
unknown or fatal status and malformed identity disable it. Cancel is the default
trust action; Escape cancels as well. Certificate reasons, subject, SHA-256 over
the DER leaf certificate and the full attempted destination are shown. Connect Once
is explicitly limited to the current attempt and does not persist an exception.
Saving is a separate, explicitly confirmed scoped decision described below.

For RSA-AES server keys, SHA-256 is independently calculated over the raw encoded
key supplied by the core. The existing RealVNC-compatible fingerprint is the first
eight bytes of SHA-1 over that encoding and is labeled separately. It is no longer
incorrectly labeled SHA-256. There is no claim that either displayed fingerprint
establishes trust without an independent comparison. Presentation descriptions are
redacted; identity data is displayed only in the trust sheet.

## Existing store behavior to preserve

The retained FLTK certificate path uses `gettidyvncstatedir()/x509_known_hosts`
through GnuTLS stored-public-key lookup/save. It passes getServerName as the host
and no service, so this historical lookup is host-scoped rather than keyed by the
native credential identity's complete port/route tuple. It distinguishes missing,
matching and mismatched stored public keys before making explicit exception
choices. Fatal verification errors are rejected before consulting that store.
The retained RSA-AES host-key dialog has no persistent store (its source contains
a TOFU TODO). The native RSA-AES store below is separate; the retained FLTK
host-key dialog remains non-persistent.

## Read-only legacy certificate adapter

NativeLegacyTrustFile resolves the retained TidyVNC state path without calling
xdgdirs' shared static buffers: an absolute XDG_STATE_HOME, otherwise HOME plus
`.local/state`, followed by `tidyvnc/x509_known_hosts`. Unset HOME uses the OS home
location. It does not fall back to upstream paths, migrate preferences, create directories,
rewrite a file or install roots. The application owns one shared actor and each
window owns a NativeCertificateTrust controller.

The codec reads GnuTLS g0 SPKI records and c0 digest commitments. Host matching is
byte-exact, any leading `*` has the historical wildcard meaning, and a null service
matches all services. A matching active record wins over changed records; expiry
zero never expires, and the expiration second itself is still active. This is
historical host scope across ports/routes, explicitly labeled in the UI; it is not
the complete endpoint identity used for credentials. RSA-AES keys do not use this
X509 database.

CertificateKey extracts the exact DER SPKI through a private GnuTLS verification
backend. The callback performs no IO and captures exceptions before returning to
C. Re-exporting a platform SecKey or hashing the certificate would not reproduce
this identity. Owned C handles expose copied Swift SPKI and bounded digest output;
CERTIFICATE_KEY (4194304) is optional and advertised only with GnuTLS. The three
new exports do not alter existing layouts. Non-TLS builds report Unsupported.

Reads run off MainActor and are bounded to 1 MiB/4096 records/64 KiB keys and at
most 16 displayed expected identities. The final file must be regular, current-user
owned, singly linked, not group/world writable and have no extended ACL; historical
0644 is accepted. Final symlinks are not followed, FIFOs cannot block the open, and
size/mtime/ctime changes during the read reject the result. These checks describe
the opened file, not a lock against later external edits. A changed file can be
checked again on a new attempt.

Unlike GnuTLS's permissive file reader, malformed or unknown records fail the whole
read closed with a typed error; no records are discarded or rewritten. Unsupported
commitment digests for an applicable record also fail the lookup. Denied, unsafe,
corrupt, unsupported, oversized, changed, unavailable and cancelled states remain
distinct from a missing host. The sheet reports the issue and still permits an
explicit Connect Once when certificate policy permits it.

Fatal/unknown policy and malformed certificate checks precede store access. A
saved matching exception can approve only the identical pending prompt in the same
generation; cancelled, superseded and closed-window results are discarded. Each
window admits one lookup at a time and drains it before checking a newer prompt.
Closing a window waits for its lookup; application shutdown closes the shared store
after all windows drain. These decisions do not automatically submit credentials.
Changed keys show expected SPKI SHA-256 (or the labeled legacy digest commitment)
and received SPKI SHA-256, separately from the leaf-certificate fingerprint.
Descriptions redact identity values.

## Destination-scoped certificate decisions

NativeTrustStore adds explicit save/replace/forget in a separate version-1 record at
`<TidyVNC state directory>/native-trust/trust-exceptions.json`. It uses the same
absolute XDG_STATE_HOME or HOME/.local/state selection as the retained trust adapter.
Trust remains under the dedicated state path, independent of native preferences
and profile migration. The existing x509_known_hosts file stays untouched. No
record is copied automatically, and there is no bidirectional writer or implicit
handoff of new scoped exceptions to the retained FLTK viewer.

Scope is a domain-separated SHA-256 identity over length-framed canonical endpoint
transport, host, IPv6 scope, port, Unix path and non-secret route identity. The shared
core parser supplies these fields. Equivalent address spellings agree; ports,
byte-distinct paths/routes and IPv6 scopes stay separate. Username and credential
authentication method are intentionally absent from certificate identity. Stored
endpoint/route display labels are bounded and rederived on every load; they cannot
mislabel another stored scope. Descriptions redact scopes, keys and fingerprints.

Precedence is explicit and fail-closed:

1. Fatal/unknown verification status and malformed certificates are rejected first.
2. Read the scoped store. A matching accepted SPKI approves this current prompt;
   a different SPKI requires a new decision. An unreadable/unsupported store is an
   error, never permission to fall back to broader trust.
3. A forgotten destination asks again when an exception is needed and suppresses
   the old host-wide exception for this exact endpoint/route. Its key bytes have
   been removed; a bounded suppression record remains to avoid resurrecting trust.
4. Only a destination with no native record may consult the unchanged legacy
   host-scoped adapter. Ordinary successful CA verification still follows the core
   TLS path without an exception prompt; forgetting is not certificate revocation.

The trust sheet offers Save Exception and Connect or Replace Saved Key and Connect
only after scoped inspection. Both require explicit confirmation naming the full
attempted destination; Cancel is the default. The shared fatal-status rule is also
checked in the store before writing. A confirmed accepted key covers future
otherwise-overridable certificate failures at this scope, like the retained key
exception policy; it never overrides fatal status. A successful write can approve
only the same pending prompt and generation. No credential is automatically sent.

File > Saved Certificate Decisions lists the bounded saved destinations, fingerprints
and forgotten states. Forget removes a saved key. Ask Again can enter a legacy-only
destination to suppress its broad exception without first creating a native accepted
key. Both require confirmation and a current revision. Existing connections are
unaffected; changes govern later exception decisions. Suppression records count
against the capacity and are not silently evicted.

The file uses a closed schema, at most 256 records, 64 KiB keys and 2 MiB total.
Unknown/future fields, corrupt values and mismatched scope labels are preserved and
rejected. NativePrivateFile selects fixed profile, certificate and host-key record kinds
with independent lock/temporary names. The trust subdirectory is private
0700, records and lock files 0600, with ownership/type/link/ACL checks. Reads create
nothing. Writes use a nonblocking advisory lock, exact-byte compare-and-replace,
private temporary file, file fsync, atomic rename and directory fsync. Content-hash
revisions reject even whitespace-only external changes. Independent cooperating
writers return Busy or Conflict; there is no automatic overwrite/retry. Arbitrary
external writers ignoring the lock are outside this transaction contract.

Cancellation before rename preserves the previous record. After rename it cannot
undo the user's committed decision. A post-rename failure rereads exact bytes: when
the new record is observed, return committed-with-uncertain-durability and require a
reload before relying on saved acceptance. If the result cannot be reconciled, keep
an explicit error and require reread. A failed or uncertain save never auto-approves
the current prompt. Window/library close drains its task, and application shutdown
closes the store after all clients drain. Stale replies cannot undo a committed
record or approve another generation.

Physical keyboard/VoiceOver/native TLS-sheet acceptance remains open. First-release interactive acceptance of persistence and confirmation
UI is not yet claimed. RSA-AES persistence is described below.

## Dedicated RSA-AES server-key decisions

NativeTrustKind separates certificate and RSA-AES identities. Existing certificate
scope hashes and version-1 file shape are unchanged. RSA-AES uses the independent
`io.github.jkeli.tidyvnc.trust.rsa-aes.v1` hash domain and a dedicated
`<TidyVNC state directory>/native-trust/server-keys.json` with its own lock and
temporaries. Its closed version-1 schema requires `kind: rsa-aes` and `hostKey`
identity fields; certificate SPKI fields/files cannot be loaded as server keys.
There is no automatic migration, X509 legacy fallback or cross-kind approval.
Each kind independently bounds its store to 256 records and 2 MiB.

Server-key identity is the exact protocol encoding: four big-endian header bytes,
followed by fixed-width modulus and exponent. The shared rfb/RSAAESKey validator
checks declared 1024–8192-bit bounds, total width, nonzero leading modulus byte,
odd modulus/exponent and 1 < exponent < modulus. It performs no allocation or
cryptographic trust check. The retained server rounds declared lengths to bytes;
validation preserves that representation and reports the actual modulus bit count
for display. It must not require that the declared count equal the true top-bit
position. Leading-zero/inconsistent-width encodings are rejected, avoiding a
truncated fingerprint when Nettle's prepared modulus width differs from the wire.

CSecurityRSAAES validates components before Nettle key preparation and before the
trust prompt. PromptAuthentication independently refuses affirmative replies for
malformed host encodings, leaving the request cancellable. The stateless
`tidyvnc_host_key_validate` ABI preserves output on failure, has no TLS/Nettle build
dependency, and advertises HOST_KEY_ENCODING (8388608), required by NativeRuntime.
Existing ABI layouts are unchanged. This syntax policy does not prove prime factors
or possession of the private key; the existing RSA-AES encrypted/hash exchange
still runs after the trust decision and before credential submission.

NativeHostKey validates owned bytes through this policy. The sheet shows actual
modulus bits, SHA-256 over the full protocol encoding, and an independently computed
RealVNC-compatible first-eight-byte SHA-1 fingerprint. The callback's display string
is not trusted as the fingerprint source. Fingerprints are never the stored key
identity. Malformed encodings disable both Connect Once and persistent approval.

The same per-window task/generation/revision and atomic-write contracts apply to
host-key save/replace/forget. A saved matching host key can approve only the current
host-key prompt at its canonical endpoint/route. A changed key requires explicit
replacement; forgotten or unreadable host state cannot inherit certificate trust.
File > Saved Server Keys is separate from Saved Certificate Decisions and provides
Forget/Ask Again. Defaults remain Connect Once and safe Cancel; durable actions
require confirmation. The retained FLTK RSA-AES dialog still makes a fresh decision
and is not silently given native records.

## Explicit CA/CRL files

Connection Defaults > Security > Certificate Files and each saved profile now offer separate certificate
CA and CRL paths, asynchronous native file selection, and explicit None. An absent
field inherits the preceding layer; an empty string deliberately adds no file.
The native defaults retain system trust with no additional files. No XDG file or
security setting is silently imported. These controls affect X509 TLS security
methods, not anonymous TLS or RSA-AES trust decisions.

NativeTrustFiles is a closed, typed value: paths must be empty or absolute, contain
no NUL, and fit 4096 UTF-8 bytes. Exact path bytes are preserved; no tilde expansion,
canonicalization, file opening or certificate parsing occurs while editing or
saving. CA/CRL fields were introduced in defaults schema 5 and profile schema 4; current
writers use defaults 9/profile 8, including resize policy and the security settings described in [SECURITY.md](SECURITY.md).
Older versions remain readable; only an explicit write upgrades a record. Invalid/unknown/future data stays intact.
App defaults precede profile overrides, field by field, before session construction.
Existing windows retain their configuration after defaults/profile saves; open a
new window to use those saved selections, or explicitly edit the disconnected
window’s Security settings for its next attempt. Cancel never saves edits. Late picker results
are ignored after dismissal, context changes or intervening draft edits.

The C bridge requires `ClientTLSOptions.requireConfiguredFiles` for its sessions.
For each X509 attempt, GnuTLS reads the selected PEM files on the protocol worker.
Every nonempty selection must load at least one CA certificate or CRL respectively;
missing, inaccessible, malformed, empty and wrong-kind files fail the attempt before
trust/credential prompts. Successful loading still requires normal chain, name and
revocation verification. Fatal revocation status cannot be approved or saved as an
exception. This does not install global roots, download CRLs or promise revocation
freshness beyond GnuTLS's existing verification rules. File contents are intentionally
read afresh per attempt; storing a path is not a content pin or availability check.
The retained FLTK/parameter policy keeps warning-only load errors for compatibility.

REQUIRED_TLS_FILES (16777216) negotiates this bridge contract without changing C
layouts or adding exports. NativeRuntime requires it. A build without GnuTLS rejects
nonempty CA/CRL selections at session construction with Unsupported. Empty selections
remain supported. File-load failures currently use the general protocol-failure
snapshot; finer native setup-error presentation remains part of the error catalog.
Native paths are local filesystem paths in the current unsandboxed app; no security-
scoped bookmark persistence or App Sandbox support is claimed.

## Verification boundary

Core tests cover every status bit and mixed allowed/fatal masks, affirmative reply
rejection without consuming the prompt, duplicate/stale replies and attempt-only
acceptance. Pure-C tests cover ABI classification, capabilities and preserved
outputs. Existing real VNC/X509Vnc socket suites continue to exercise trust before
credentials. Native tests cover every reason, DER decoding, malformed/oversized
identity, independently pinned fingerprints, redaction and concurrent classification.
Fourteen light/dark render fixtures cover issuer, expiry/name, revoked, unknown,
malformed, overflowing problem lists and host-key states. These do not prove physical keyboard or OS trust
store behavior. Tests create no user trust entries and install no system roots.

The read-only adapter adds pure-C output/lifetime/type/unsupported-build checks,
independent OpenSSL SPKI and CryptoKit digest fixtures, real GnuTLS-generated g0/c0
compatibility tests, and native codec/file/controller tests. Those cover host/service
scope, wildcards, expiry, malformed/unknown/oversized records, changed identities,
unsafe file types/permissions, missing paths, cancellation, stale requests, shared
windows and joined close. Four additional light/dark details renders cover changed
keys and denied-store errors. Sanitizer configurations disable GnuTLS: they exercise
the unavailable-key branch plus injected-key codec/controller tests; the real
cryptographic extraction/compatibility tests run in normal headless/FLTK builds.
No user trust database is read or modified by these fixtures.

Scoped trust tests cover independent scope goldens, persisted add/replace/forget,
port/route/Unicode/IPv6 isolation, strict schema and capacity, separate profile
records, content revisions, independent-writer contention, injected pre/post-rename
failure, cancelled pending writes, committed writes during window close, manager
forget, legacy-only suppression, stale-save rejection and corrupt-native-store
precedence. Eight additional light/dark renders cover add/replace/forgotten sheets
and the management window. These fixture tests do not mutate user state or prove
physical confirmation-sheet keyboard behavior.

Host-key tests add independent OpenSSL public RSA encoding and Python SHA-256/SHA-1
and scope goldens, separate-file/kind rejection, valid/invalid encoding boundaries,
malformed affirmative reply rejection, native add/replace/forget/reuse and stale/error
handling. Four real loopback RSA-AES variants reach the owned host-key prompt from
valid public keys; malformed wire keys fail before any prompt. These tests stop at
trust rejection and joined teardown: they do not claim a completed encrypted RSA-AES
authentication/session. Eight more light/dark renders cover host add/replace/forgotten
states and the dedicated management window. Physical UI/VoiceOver and complete native
RSA-AES authentication acceptance remain open.

CA/CRL verification adds real independent loopback TLS peers: a CA-signed leaf with
a valid CRL reaches credentials and a connected session without an exception; a
revoked leaf produces a fatal, non-approvable prompt; missing/empty/malformed/wrong-
kind selections fail before prompts. Retained warning-only loading is also covered.
Pure C checks feature negotiation, copied paths, NUL rejection and TLS-disabled
rejection. Native tests cover schema compatibility, strict types, path bounds,
Apply/Cancel, profile inheritance and immutable existing windows. Six light/dark
settings renders cover inherited, selected and invalid paths. Physical file-picker,
keyboard/VoiceOver and full native TLS connection acceptance remain open.
