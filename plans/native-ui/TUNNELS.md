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
change to existing structs or persisted schemas. The Swift wrapper requires the
feature and exposes connect(endpoint:through:routeIdentity:). It does not authorize
credential reuse, launch a process, or infer the destination from a local port.
The caller owns the tunnel until the RFB transport is drained. This is currently
a service boundary, not a completed `via` launch path.

## Owned SSH process service

NativeSSHTunnelRequest validates a TCP target and `[user@]host` or
`ssh://[user@]host[:port]` gateway. Bracketed IPv6 is supported. Gateway identity
is a versioned digest of canonical host, exact scope, port and explicit/implicit
user; it does not depend on the ephemeral forwarding socket. The target remains
separate. Command/forwarding grammar characters are rejected before process IO.

NativeSSHTunnel implements NativeTunnelOwning. Each attempt creates a short,
private 0700 directory with empty ACL, a private SSH master control socket and a
0600 forwarding socket. It starts `/usr/bin/ssh` with explicit argv, checks the
master and requests forwarding with `-O forward`; only successful acknowledgement
and the expected private socket permit RFB admission. Socket-file creation alone
is not readiness. Startup has a monotonic 20-second deadline. No local TCP port
reservation/release race is needed. UseIPv4/UseIPv6 apply to reaching the gateway;
the gateway resolves the remote target itself.

The initial service uses `-F /dev/null`, BatchMode, StrictHostKeyChecking and
UpdateHostKeys=no. It uses existing known-host keys and noninteractive default-key
or agent authentication. It cannot presently prompt for SSH passwords/passphrases,
approve new host keys, apply user SSH configuration/aliases/proxies, or evaluate
VNC_VIA_CMD. These limitations must be resolved or explicitly presented before
advertising app/CLI support; they do not close the complete tunnel parity item.
Environment inheritance is restricted to fixed PATH/locale/askpass policy and the
named SSH_AUTH_SOCK input. VNC credentials are never forwarded into SSH's argv or
environment. Standard input/output/error use `/dev/null`; errors are fixed text.

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

## Remaining implementation

1. Wire the validated gateway request and deterministic route identity into the
   invocation path, preserving SSH user/host/port distinctions. Resolve the final target after
   defaults/CLI/file review. Reject incompatible listen/Unix-target cases before
   side effects. Do not silently reinterpret custom VNC_VIA_CMD shell programs.
2. Extend actual SSH acceptance to child/server death and verify deployment-floor
   availability. The isolated daemon test now covers unknown host-key rejection,
   disposable-key authentication, routed RFB and cleanup. Extend authentication/host-key interaction
   and supported configuration policy without introducing shell interpolation,
   secret-bearing argv or detached children.
3. Wire the listener-independent outbound ConnectionModel path through tunnel
   preparation and routed connect. Keep address/history/export logical, scope both
   NativeAuthenticationCredentials and NativeCertificateTrust to target + route,
   and preserve launch credential ownership. Stop the old transport before tearing
   down its tunnel; cancel startup and drain on window close/quit. Reconnect must
   create a fresh owned route without leaking children or reusing local identities.
   The credential controller now supports route-scoped keys and launch binding;
   ConnectionModel still passes the direct default. History/profile route storage
   and explicit export-omission review need a defined policy before enabling CLI
   support; storing only a target must not silently change its connection route.
4. Test actual process lifecycle and routed RFB/TLS identity, CLI/file precedence,
   cancellation at startup/admission/connected states, child failure, credential
   separation and app presentation. Then advertise `via` support in bootstrap/help.
   End-to-end SSH and installed network/privacy acceptance are separate gates.

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
