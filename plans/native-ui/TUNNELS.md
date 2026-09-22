# Native tunnel adapter

N3.18 and N4.11 remain open. The retained viewer implements `via` using SSH local
forwarding; it also evaluates VNC_VIA_CMD as a shell string after substituting
environment variables. Native code must invoke a process with explicit argv and
must not evaluate that shell customization. The file field catalog does not persist
`via`; unknown file fields retain their existing ignored-field review.

## Implemented transport prerequisite

prepareRoutedSocketConnection and tidyvnc_session_connect_routed separate a logical
TCP target (with a required opaque route identity) from its prepared local socket.
The local socket must be Unix or numeric 127.0.0.1/::1 with a nonzero TCP port and
no scope/route. There is no remote DNS resolution by this connector. The logical
hostname, not the forwarding address, reaches the existing protocol/TLS server-name
path. Direct connect still rejects an unhandled route; it cannot silently bypass
a tunnel. Cancellation, deadlines, single use and transport drain reuse the socket
connector's existing contracts. Endpoint values are copied before C admission
returns, so the caller may release the target handle afterward.

The additive ROUTED_CONNECT feature has one new C export (112 total), with no
change to existing structs. Route persistence evolves separately below. The Swift wrapper requires the
feature and exposes connect(endpoint:through:routeIdentity:). It does not authorize
credential reuse, launch a process, or infer the destination from a local port.
The caller owns the tunnel until the RFB transport is drained. The app controller and CLI `via` path now own this boundary as described below.

## Owned SSH process service

NativeSSHGateway validates `[user@]host` or `ssh://[user@]host[:port]` independently
of a target and without IO. Canonical URI length is bounded so every admitted value survives
encode/decode. NativeSSHTunnelRequest pairs it with the final TCP
target after file/default resolution. Bracketed IPv6 is supported. Gateway identity
is a versioned digest of canonical host, exact scope, port and explicit/implicit
user; it does not depend on the ephemeral forwarding socket. The target remains
separate. Command/forwarding grammar characters are rejected before process IO.

NativeSSHTunnel implements NativeTunnelOwning. Each attempt creates a short,
private 0700 directory with empty ACL, a private SSH master control socket and a
0600 forwarding socket. It starts `/usr/bin/ssh` with explicit argv, checks the
master and requests forwarding with `-O forward`; only successful acknowledgement
and the expected private socket permit RFB admission. Socket-file creation alone
is not readiness. Startup has a monotonic 20-second deadline without interaction, or five minutes
when native SSH prompts are enabled. No local TCP port
reservation/release race is needed. UseIPv4/UseIPv6 apply to reaching the gateway;
the gateway resolves the remote target itself.

The app uses an admitted private config snapshot and UpdateHostKeys=no. Explicit
unconfigured service callers retain `-F /dev/null`. Noninteractive owners use
StrictHostKeyChecking=yes; native interaction uses ask with the bound key review
described below.
It uses existing known-host keys and default-key or agent authentication. The app
now enables password/passphrase interaction through its bundled SSH_ASKPASS helper;
service callers without NativeSSHAuthentication retain BatchMode=yes. Supported
static ~/.ssh/config aliases and settings are captured before connecting. Proxy
hops, command execution and VNC_VIA_CMD remain unsupported.
New plain Ed25519/RSA/ECDSA keys have native review; unsupported key formats fail
closed when approval would be needed. Existing keys and trusted certificates remain
subject to OpenSSH verification. These limitations must be resolved or explicitly presented before
advertising app/CLI support; they do not close the complete tunnel parity item.
Environment inheritance is restricted to fixed PATH/locale/askpass policy and the
named SSH_AUTH_SOCK input. VNC credentials are never forwarded into SSH's argv or
environment. Standard input/output use `/dev/null`; master stderr is streamed into
a constant-space save-failure classifier and discarded. Errors are fixed text.

NativeTunnelProcess uses posix_spawn with a fresh process group, closed inherited
descriptors and reset signal policy. Exit arrives through a dispatch process
source. Cancellation sends TERM, followed by KILL after 250 ms if needed. The
owner uses waitid(WNOWAIT) to keep the leader's PID reserved while terminating its
remaining process group, then reaps that exact child. Waits and cleanup are async;
no UI-thread join or detached SSH `-f` process remains. Close revokes startup,
cancels both the master and any control client, joins them and unlinks only its
known socket leaves. This includes bounded direct `control.*` socket leaves left
if a master is killed while staging its control socket, as shown in the
[OpenSSH mux listener implementation](https://github.com/openssh/openssh-portable/blob/master/mux.c#L1234).
Cleanup never recurses or removes regular files/symlinks under those names.
Dropping an owner also requests cancellation; private cleanup
remains retained until child exit. A fresh owner is required for reconnect.

System evidence: `/usr/bin/ssh -V` reports OpenSSH_10.3p1. The installed ssh(1)
documents local Unix socket `-L` forwarding and `-O check/forward`; ssh_config(5)
documents BatchMode, ExitOnForwardFailure and StreamLocalBindMask. This does not
establish the deployment-floor SSH version or actual SSH authentication acceptance.

## Route persistence and export

Profile/history schema 11 stores an optional `sshGateway` canonical URI on profiles
and complete recent destinations (`recentConnections`, each with endpoint and
optional gateway). Gateway decoding always validates through NativeSSHGateway;
derived route digests, forwarding sockets, secrets and SSH command customizations
are not persisted. History identity is exact UTF-8 target text plus canonical gateway,
so direct, different user/port/gateway routes coexist. The 20-entry bound applies
to complete destinations. Removal and queued recency updates use the same identity.

Schemas 1–10 load as direct routes without writing. An explicit mutation upgrades
the complete record atomically, preserving profile IDs, settings, credential
references, address order and history initialization/import markers. Unknown fields,
invalid gateways, unsupported routed targets and canonical duplicate routes fail
without rewriting. Older readers reject schema 11 rather than dropping routes.
Endpoint-only compatibility accessors expose only direct entries.

NativeDocumentExportCapture retains optional gateway metadata across monitor
remapping. Compatibility export adds a separate `sshGateway` loss requiring explicit
acknowledgement: the file will connect directly unless the gateway is configured
separately. Gateway labels and digests do not enter exported file bytes.

Initial app ownership is now wired through ConnectionTunnelAttempt in
ConnectionModel. It creates a fresh tunnel per attempt, binds logical target and
route to credentials/trust, and has a shared uncancelled cleanup task intended to
drain RFB before closing SSH. Exit observations are scoped to the attempt. Recent
selection carries the complete destination; profile/connection gateway fields show
current authentication/configuration limitations; live export includes gateway
omission review. The temporary routed-profile admission rejection is removed.

Dedicated controller tests now exercise startup and committed-connect cancellation,
remote disconnect, child exit, fresh-owner reconnect, repeated close and dropped
presentation. They observe the terminal RFB state before ordinary tunnel close,
hold cleanup to prove replacement admission stays disabled, and verify saved and
session credentials stay isolated between gateway users and direct connections.
A second controller fixture uses the isolated OpenSSH daemon with disposable keys.
It covers unknown-key rejection, actual forwarding, remote/child exit and reconnect.
These fixtures do not establish physical app interaction or installed acceptance.

CLI `via` now validates every occurrence before path inspection/file reads, retains
user/host/port identity, and resolves the forwarding target after explicit file
review. Empty `via` explicitly selects a direct route. Listener combinations and
Unix targets fail before session/tunnel allocation; files are necessarily read and
reviewed before checking their final target. The resolved gateway is published before
session publication and launch-credential binding. Compatibility files do not gain a
new route field. `VNC_VIA_CMD` presence with an active CLI gateway fails before
credential capture, logging or application startup; no command text is evaluated or
reflected. Help describes native password/passphrase interaction, the existing-host-key
policy and unsupported host-key/configuration features. The complete parity items remain open.

## Remaining implementation

1. Extend CLI/file and actual app acceptance across route-aware profile/recent
   selection, trust decisions and installed launch paths. The initial CLI adapter
   and explicit shell-customization rejection are implemented above.
2. Extend actual SSH acceptance to child/server death and verify deployment-floor
   availability. The isolated daemon test now covers unknown host-key rejection,
   disposable-key authentication, routed RFB and cleanup. Extend authentication/host-key interaction
   and supported configuration policy without introducing shell interpolation,
   secret-bearing argv or detached children.
3. Extend ConnectionModel acceptance through native app interactions and TLS
   certificate/host-key decisions. Test complete destination retention, credential/trust route
   binding, launch-input ownership and current-route export. Prove old transport
   drain precedes ordinary SSH teardown and close/quit joins pending startup. Test
   remote/child death, stale exit observation and fresh-owner reconnect. Exercise
   route-aware recent/profile UI with actual interactions.
4. Test actual process lifecycle and routed RFB/TLS identity, CLI/file precedence,
   cancellation at startup/admission/connected states, child failure, credential
   separation and app presentation. Bootstrap/help now advertise the limited
   adapter and state its limitations.
   End-to-end SSH and installed network/privacy acceptance are separate gates.

### Connection owner integration checklist

Capture one immutable NativeConnectionDestination before attempt admission. Use
its logical target and gateway digest for credential/trust binding, and retain it
for history, retry comparison and export. Create the tunnel owner before async
startup so close/cancel can always reach it. Recheck attempt identity after every
await before publishing readiness or errors. Keep Connect disabled while startup,
RFB work or cleanup is outstanding.

A cancelled NativeSession await consumes its admitted completion and may have
raced a successful connect. Cleanup therefore needs its own uncancelled async
drain: disconnect/close the RFB transport, then close/join the tunnel and its exit
observer. Join pending startup on window close/quit. On remote disconnect, reap the
otherwise still-running SSH master. Child exit must cancel/drain only its matching
attempt; a late observer from an old attempt must never fail a replacement.
Reconnect constructs a fresh owner. Test startup cancellation, committed-connect
cancellation, remote/child exit, disconnect, repeated close, dropped presentation
and route changes using the existing private child and isolated SSH fixtures.

## Reproducible checks

NativeTunnel.ProcessOwnershipAndForwarding drives real private child processes:
descriptor isolation, separate process groups, typed failures, no readiness,
forwarding failure/hang, ignored TERM, cancellation before readiness and during a
control request, concurrent close, drop cleanup, noisy stderr and real RFB over a
Unix-to-loopback relay. It also checks validated gateway/route identities and asks
the system SSH to parse the generated argv with `-G` without connecting.

NativeTunnel.IsolatedOpenSSH invokes `tests/macos/tunnel-ssh.py` when Python is
available. It starts a loopback-only sshd with disposable host/client keys and
isolated authorized/known-host files, then runs the production SSH argv with only
test identity/known-host file overrides. It verifies rejection of an unknown key,
public-key authentication, acknowledged Unix forwarding, RFB negotiation and
joined cleanup. It changes no system SSH settings, user keys or known-host files.
Unavailable sshd or an account that cannot start it is reported as a skip (77),
never as proof of real SSH acceptance. The fixture daemon group is killed before
its leader is reaped so cleanup cannot signal a recycled PID.

Use `ctest --test-dir build/native-ui-swift/tests/macos --output-on-failure
--no-tests=error -R '^NativeTunnel\\.'` after building native-tunnel-tests. The same
selection runs in the ASan/TSan build trees. Exact results and platform limits are
recorded in TODO.md and RESUME.md.

NativeTunnel.ConnectionControllerLifecycle compiles the production ConnectionModel
with an injected owner wrapping the real private child relay. It also exercises
CLI target/file routing, launch-password binding and final-file Unix-target rejection.
NativeTunnel.ConnectionControllerOpenSSH runs the same app owner against the isolated
daemon via tunnel-ssh.py. Both are included in the full native CTest suite; focused
selection is `-R '^NativeTunnel.ConnectionController'`. See TODO.md for final evidence.

## Native SSH prompt transport

NativeSSHAskpass owns a separate Unix socket inside each attempt's private directory.
The C helper validates the directory ACL/mode, socket owner/mode and peer UID. Frames
have explicit type/version/length bounds; prompts are bounded UTF-8 plain text and
responses reject NUL/CR/LF and values beyond SSH's 1023-byte bound. No response goes
into argv, environment, files, errors or diagnostic output. The helper emits only
the response line to SSH's pipe. Secret byte buffers are cleared after use; SwiftUI
field strings follow the existing authentication UI's limited lifetime.

The utility worker never blocks MainActor. NativeSSHInteraction scopes each prompt
by UUID and immutable gateway/target; cancellation rejects late responses. Peer
exit, startup cancellation, window close and timeout revoke the prompt. Joined
cleanup drains the interaction and socket before removing the tunnel directory.
Concurrent connection attempts have separate sockets and presentation owners.

The helper follows OpenSSH's [readpass protocol](https://github.com/openssh/openssh-portable/blob/master/readpass.c).
Permission and notification hints are handled separately from secret responses.
A permission hint is not a host-key decision; structured key observation is
required for the separate host-key review below. SSH responses are use-once and do not enter VNC Keychain retention.

NativeTunnel.AskpassTransportAndInteraction exercises the real helper subprocess,
private directory rejection, bounded responses, stale answers, session isolation,
peer disappearance and joined close. NativeTunnel.AskpassOpenSSH uses a disposable
encrypted client key with the isolated daemon to exercise the actual passphrase
prompt, startup cancellation and routed RFB. App packaging signs the helper before
the development bundle; distribution identity/hardening remains a separate gate.


## Bound SSH gateway key review

The app supplies a fixed KnownHostsCommand helper template. OpenSSH splits this
into argv and expands tokens in the arguments; no shell is invoked. The executable
path is quoted for that parser, including spaces/backslashes/quotes. The helper
emits no known_hosts entries and does not select trusted keys. Its HOSTNAME call
sends only the lookup hostname, key algorithm and public-key blob over the private
socket; ORDER/ADDRESS calls leave OpenSSH's ordinary lookup unchanged.

NativeSSHHostKey validates the destination and wire key structure, then computes
SHA-256 from the actual public-key bytes. Current new-key review supports plain
Ed25519, RSA and NIST ECDSA keys. SSH's confirmation must contain the matching
hostname, algorithm and computed fingerprint. Unsupported or mismatched host-key
confirmations are cancelled instead of falling back to a password field.

The native sheet displays the immutable gateway/desktop context and calculated
fingerprint, with Cancel as the default. Trust and Save returns that exact
fingerprint. OpenSSH independently compares it with its offered key and owns the
known-hosts write before authentication. The app does not parse prompt prose into
trusted key material, append key records, or allow a generic yes response through
its typed host-key model. Remote authentication text cannot itself write trust;
the underlying OpenSSH confirmation state still governs any save.

OpenSSH's existing changed/revoked-key checks remain authoritative. A changed
saved key is not offered as a new-key override. Cancellation before approval does
not create a known-hosts record; cancellation after an explicit approval may leave
the approved key saved, as the sheet explains. VNC server trust is independent.

An initial known-hosts write failure reported by OpenSSH now prevents forwarding
and VNC admission, with a fixed file-access error. The master runs with native-owned
LogLevel=INFO and LogVerbose=none so config verbosity cannot hide that failure.
The stderr reader retains only matcher state, drains noisy streams in constant
space, and joins descriptor cleanup on close/deallocation. Readiness drains bytes
already emitted before the master acknowledgement; error cleanup also checks the
flag if authentication ends earlier. Task cancellation keeps its normal semantics.
No diagnostic text can approve a key; a forged failure line can only deny admission.
This observes OpenSSH's reported write result, not a separate persistence/durability
or external known-hosts-file integrity guarantee. Installed native interaction and
older deployment-floor SSH versions still need acceptance.

Protocol references: [KnownHostsCommand documentation](https://man.openbsd.org/ssh_config#KnownHostsCommand)
and [OpenSSH host verification](https://github.com/openssh/openssh-portable/blob/master/sshconnect.c).
This is not complete SSH configuration, certificate enrollment, deployment-floor
or installed app interaction acceptance. Exact current test evidence is in TODO.md.

## Configuration resolution prerequisite

NativeTunnelOutput adds single-use bounded stdout capture to the existing owned
process service. A nonblocking dispatch reader drains the pipe, rejects overflow,
and cancels the same PID-pinned process group. Descriptor closure waits for the
read source's cancellation handler. Launch failure and parent/descendant exit
release pipe owners. Configuration probes retain bounded stdout only. Masters use
a separate stderr mode that retains no raw text and reduces the stream to a fixed
host-key write-failure flag; authentication responses remain on private askpass IPC.

NativeSSHConfigurationProbe resolves the admitted snapshot with a deadline and
joined cancellation, validates bounded UTF-8 output and returns a typed effective
gateway/key identity plus an opaque policy digest. NativeConfiguredSSHTunnel owns
preparation in the app; credentials/trust bind to its result before SSH/RFB starts.
See [SSH-CONFIGURATION.md](SSH-CONFIGURATION.md) for snapshot, inherited-port intent,
resolved identity, supported settings and remaining acceptance requirements.
