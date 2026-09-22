# SSH configuration integration

This is the remaining configuration work under N3.18/N4.11, not a replacement for
PLAN.md. The app now prepares supported ~/.ssh/config settings through an owned
snapshot and bounded OpenSSH probe before credential/trust and RFB admission.
This is limited configuration support; the restrictions below remain enforced.

## Required semantics

Preserve gateway alias spelling as the user's saved destination, while separately
resolving the effective SSH hostname, username, port and host-key lookup identity.
A forwarding socket, alias string or configuration filename alone is insufficient
for VNC credential/trust routing. Resolve a single immutable attempt before RFB
admission and bind credentials/trust to its effective route. Keep the alias for
profile/history editing and export-loss review. A later configuration change must
not redirect an existing attempt or silently reuse credentials from another route.

NativeSSHGateway now retains explicit versus inherited port intent in its canonical
URI and a portIsExplicit flag. New Codable values use a closed version-2 object;
legacy string values decode to a concrete port, including omitted port 22. Profile/
history schema 12 writes those objects and reads schema 11 strings without an eager
rewrite. Do not infer that an old stored :22 meant "use configured port". Defaults
storage remains schema 11. Explicit and inherited port destinations remain distinct
in history even while they both currently launch on 22.

This is an intent/storage prerequisite: the existing launcher and legacy route
digest still use a concrete port. Configuration-aware preparation must apply explicit
user/port precedence and bind credentials/trust to the effective route before RFB
admission; it must not use the requested alias digest as the resolved identity.

OpenSSH should evaluate Host patterns, option precedence and supported settings;
do not replace its resolver with an approximate Host-matching implementation.
Its `-G` command evaluates configuration before producing a dump, including Match
conditions. It is not a safe validator for arbitrary unreviewed configuration.
See [ssh(1)](https://man.openbsd.org/ssh.1) and
[ssh_config(5)](https://man.openbsd.org/ssh_config.5).

## Configuration admission and ownership

Before evaluating files, define and implement bounded immutable snapshots with
explicit handling of Include, scope, path expansion, missing/unsafe files, cycles,
size/count/depth limits and revision changes. Preserve Include semantics rather
than flattening conditional files incorrectly. Prefer retaining OpenSSH parsing
against controlled snapshot paths. Do not pass a live file to a probe and reread
it later for connection with potentially different routing or command contents.

Keep native ownership controls authoritative: no detached master, existing shared
control socket, unsolicited forwards, local/remote session commands, inherited
VNC secrets or shell interpolation. Configuration directives that execute commands
(such as Match exec, ProxyCommand, LocalCommand and KnownHostsCommand) require an
explicit supported ownership policy; do not enable them incidentally by dropping
`-F /dev/null`. Unsupported settings must fail visibly, never silently fall back to
a direct route or a different gateway. The fixed bundled key observer is distinct
from user-provided KnownHostsCommand. ProxyJump needs owned hop lifecycle and
route/credential identity tests before admission.

Identity/certificate/known-host paths and agent selection must use the reviewed
snapshot. Do not persist configuration dumps or report raw command/path values in
errors. Validate only copied typed results. The probe now extracts hostname, user, port and an optional bounded literal host-key
alias. NativeSSHPreparedGateway owns the admitted snapshot and typed resolution;
its ssh-v2 digest separates effective account/host/port/key lookup from old requested
alias scopes. Explicit HostKeyAlias is used verbatim for key lookup, following
[OpenSSH get_hostfile_hostname_ipaddr](https://raw.githubusercontent.com/openssh/openssh-portable/master/sshconnect.c).
No alias and a literal alias of "none" remain distinct.

The internal prepared NativeSSHTunnel initializer now enforces effective hostname,
user/port and any explicit key alias, retains the requested alias as the destination
argument, and disables further canonicalization. Hostname percent bytes are escaped
for OpenSSH option expansion, preserving IPv6 scopes. Absent HostKeyAlias remains
absent; HostKeyAlias=none is never used as a clearing mechanism, so default certificate
principal semantics are preserved.

Before starting the master, an owned cancellable `-G` preflight uses those launch
arguments and the retained snapshot. Typed routing and a digest of all remaining
emitted settings must match preparation; native-owned controls are excluded because
they are intentionally authoritative. No raw dump is retained. Match rules that
select different effective settings with the forced route fail explicitly instead
of silently changing policy. Match localnetwork is now rejected during snapshot
admission because its result could change after verification. Command execution
settings remain rejected. Common static aliases/Include/Match settings are exercised
through isolated SSH-to-RFB tests; this is not a claim that all SSH config is supported.

Configured askpass observation uses the prepared key lookup name. Close and dropped
owners join preflight, master/control children and prompts before releasing snapshot
files. Internal service tests cover startup cancellation and dropped-owner cleanup.

Default preparation now captures an absent ~/.ssh/config as an owned empty file,
without creating user files. Missing explicit files and unsafe/inaccessible parents
or dangling symlinks fail. Absence is revalidated before publication, so a config
appearing during preparation rejects. Address-family policy is applied to the first
probe and retained by the preparation; tunnel construction rejects a different
policy instead of changing it after route binding.

Configured encrypted-key authentication, cancellation and routed RFB now pass with
the real helper. Configured HostKeyAlias cases also cover new-key cancel/save/repeat,
independent fingerprints and changed/revoked-key rejection for Ed25519/RSA/ECDSA.

ConnectionModel now uses NativeConfiguredSSHTunnel and owns a preparation phase.
It binds credentials/trust to the prepared effective route before SSH/RFB admission,
checks that forwarding returns the same route, and preserves the requested alias
for history/profile editing. Launch credentials bind separately to requested intent
(including omitted versus explicit :22) and the first effective route; a changed
resolution discards them. Cancellation/close joins preparation and tunnel teardown.
Controller fixtures cover configured aliases through RFB, launch authentication,
fresh reconnect, unsupported config on retry and cancellation before SSH startup.
Native UI, installed execution and broader trust/credential interaction acceptance
remain open; implementation alone does not establish those gates.

## Integration order and evidence

1. Bounded process output and configuration probe: implemented. Exercise exact
   bounds, fragmented writes, overflow, launch failure, cancellation/deadline,
   inherited writers, output single-use and malformed/duplicate routing fields.
2. Configuration snapshot/admission and OpenSSH evaluation with private fixtures:
   aliases, precedence, Include/Match scope, rejected command settings, substitutions,
   cycles/oversized files and changes during preparation. No network or command
   execution before explicit supported admission.
3. Explicit/inherited gateway intent and storage migration; resolved route values
   and identity. Test requested alias versus effective host/user/port, IPv6/scope,
   host-key alias, distinct configuration resolutions and stale prepared values.
4. ConnectionModel preparation and immutable attempt publication before credentials,
   RFB or history changes. Update launch-password ownership, saved/session credential
   keys, trust binding, retry comparison, recent/profile selection and export review.
   Cancellation/close must join configuration preparation as well as SSH/RFB.
5. Actual isolated SSH configuration-to-RFB acceptance is exercised through the
   controller. Native app interactions and installed acceptance remain required.
   UI/help now describe the admitted subset because blanket unsupported wording
   became inaccurate when the app factory changed; this is not a completed UI or
   release gate. Retain the restrictions and track sanitizer/package evidence.

OpenSSH-reported initial host-key save failures now produce a fixed error before
VNC admission, including when authentication ends before readiness. Native-owned
logging overrides config verbosity without retaining raw diagnostics. Further SSH
key/authentication formats and native UI/physical/installed/release gates remain.


Initial snapshot implementation now exists in NativeSSHConfigurationSnapshot.swift.
It preserves included files as separate private copies. Real OpenSSH fixtures
compare scope/immutability, glob ordering, hidden files and quoted paths. Missing
matches are ignored, but other directory/stat failures reject preparation. Every
visited source path is revalidated, including alternate paths to the same inode.
Cancellation and construction errors after preparation join removal of the private
copies. Copied file/directory modes are established independently of the caller's
umask, and cleanup verifies directory identity before removing its pathname.
Fixtures also cover ACL rejection, aggregate bytes and unique-file bounds. Literal
hash characters inside Include filenames follow OpenSSH tokenization; only a hash
at the start of a token introduces a comment. Non-ASCII whitespace is not silently
normalized into accepted directive syntax. Escaped Include
patterns are explicitly unsupported until their lexical/glob semantics are covered;
percent/environment/named-user expansion and final symlink files also remain
unsupported. The app path supports this admitted subset, not complete OpenSSH
Include expansion. See TODO/RESUME for current validation evidence and next work.
