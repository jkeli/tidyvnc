# Native reverse listener

The portable listener has a C ABI, a Swift owner and a native listener window under
File > Listen for Connections. Native `-listen [port]` launches the same presentation
and starts listening once. `-listen ./connection.tidyvnc` prepares file settings
for review before binding. The current checkpoint and resumption work are recorded
in [RESUME.md](RESUME.md).

## Ownership and admission

A runtime lazily owns up to four listeners, separate from its session capacity.
Each listener binds numeric IPv4/IPv6 or wildcard addresses on its worker. Port
zero selects one ephemeral port shared across enabled families. Defaults remain
port 5500, backlog 16, eight pending peers, 32 queued events and a 30-second pending
expiry. The existing limits remain backlog/pending 1–64, events 4–4096 and expiry
1–60000 milliseconds. DNS, scoped bind addresses and Unix listeners are not admitted.

Incoming peers are numeric copied addresses and monotonic IDs scoped to one
listener handle. Pending sockets remain bounded and no RFB bytes are read before
explicit acceptance. A consumer may reject or accept once; expiry and duplicate
IDs cannot consume another peer. Acceptance transfers into an already configured
reusable session, preserving its explicit security, rendering, clipboard, sharing,
input, limits and authentication settings. There is no hidden session with defaults.
The normal session operation/completion and generation machinery handles the attempt.

Invalid handles and malformed output arguments leave a peer pending. After claim,
a busy/closing target or allocation failure closes the claimed socket; no requeue
or second owner exists. An Accepted event means ownership transfer, not completed
RFB authentication. Successful attempts use existing prompt, trust, input, frame
and command delivery. A later explicit reverse admission can reuse the same logical
session after its prior attempt drains.

Numeric peer host supplies the TLS hostname, excluding an IPv6 route scope. An
incoming source port is not a stable saved-server identity. The app treats each
accepted reverse connection as a one-attempt, connection-only identity: it does not
attach history, Keychain, legacy trust exceptions or saved certificate/server-key
stores. The source address is read-only and cannot become an outbound reconnect or
exported connection document. Password UI uses a single submission; trust prompts
retain explicit connection-only decisions. The low-level wrapper itself performs
no store access, persistence, environment capture or credential reuse.

## Events and close

Listener events have ordered sequence numbers, immutable snapshots, and copied
numeric addresses. The stream begins at Starting and progresses through Listening,
Stopping and Closed/Failed. Queue overflow closes unclaimed sockets and reserves
terminal delivery. Typed failure reason and OS code remain separate from addresses.

Readiness notifications run outside core listener locks. The C bridge routes them
through its existing bounded, coalesced callback dispatcher; callbacks can safely
reenter snapshot/event APIs. Subscription retain/unsubscribe/drain behavior matches
sessions. Listener handles never restart, so callback generation is always one;
a restart requires a new handle. Final release cancels subscription delivery;
explicit stop preserves terminal event delivery until unsubscribe/release.

NativeListener uses NativeDelivery to marshal updates to MainActor, retains copied
pending peers and checks each peer's originating listener before accepting/rejecting.
It does not poll listener state. Stop leaves accepted sessions alive. Close revokes
queued host delivery, unsubscribes, stops, and asynchronously drains the worker,
callback context and already queued MainActor delivery. Deinitialization only
requests cancellation and releases handles. Runtime shutdown begins closure of all
weakly registered listeners and sessions, then awaits both services; no UI thread
joins a worker. Closed listener handles can still expose their terminal snapshots.

## Native window and admission

The listener window exposes TCP port and IPv4/IPv6 selection, Start/Stop, bound
ports, pending numeric peers and explicit Accept/Reject. Port zero selects an
available port. Invalid ports or both families disabled fail before binding.
Bind errors and event overflow have fixed recovery notices. Starting a replacement
waits for the previous owner to close; stop/close invalidates a pending start.

Accept reserves one pending peer and opens an independent connection window. The
existing NativeSessionDefaults path resolves native preferences before creating
the target session; sharing, security, input, rendering, clipboard and other settings
therefore reach the reverse handshake. No protocol bytes are read while preferences
are loading or being recovered. If the peer expires during setup, admission fails
with a fixed explanation. Closing that window before admission rejects the peer.
The listener stays available for other incoming connections. Stop/close leaves
accepted windows connected; application quit closes the listener and all sessions.

Incoming windows are app-owned NSWindows without a restorable scene payload. They
use the ordinary desktop, authentication and trust presentation, but suppress
outbound Connect/Retry, address editing, export and password persistence. Reconnect
requires the server to create a new incoming connection. Listener focus clears the
active connection menu target. Manually showing the listener window does not bind a port or
access a user store; binding requires Start, and target session preferences are
read after Accept.

## CLI startup and file review

CLI bootstrap resolves the final `listen` boolean before classifying operands.
With listen enabled, no operand selects 5500, and an ASCII decimal 0–65535 selects
that port (0 requests an ephemeral port). Empty argv entries are ignored by the
shared parser. Native parsing deliberately rejects nonnumeric operands, numeric
suffixes and out-of-range values: the retained viewer instead ignores a nonnumeric
operand and uses unchecked `atoi` for a digit-prefixed one. No display-number offset
is applied. This checked native policy is not a claim of retained CLI parity.
UseIPv4/UseIPv6 use their last validated assignment, default true, and cannot both
be false for a listen launch. Disabled listen follows ordinary outbound handling.
Paths use the existing file/socket classification with the captured working
directory. Unix socket listeners fail explicitly. Configuration files use the
bounded regular-file reader and defaults → CLI → file precedence. Every recognized
ServerName occurrence must be empty or a checked decimal port; absent/empty chooses
5500. Port zero remains ephemeral. Unknown/platform-only fields retain explicit
ignored-field review; this does not extend the compatibility file's field catalog.

NativeSessionDefaults has a listener preparation purpose: file read, resolution,
display mapping, ignored-field review and topology revalidation occur without
allocating a session or binding a socket. The listener scene displays the port and
enabled families. Its Start Listening approval produces NativePreparedSessionDefaults,
an owned configuration plus inherited/document/invocation metadata. Incoming windows
consume this value without rereading the source file or preferences, preserving
reviewed precedence, provenance and inactive cursor shape. Manual/numeric listeners
continue their existing per-incoming defaults resolution.

Mapping reconstruction retains the file's listener-port interpretation. Stale
approval IDs and display topology changes cannot bind. Before accepting a peer,
selected display IDs from the approved configuration must still be connected;
reconnect them or close/reopen the file to choose others. They are never silently
renumbered. Ordinary session/fullscreen topology handling continues after admission.
Closing during file IO cancels publication and awaits reader completion. Cancelling
review clears unclaimed credentials; an explicit reload cannot recapture them.

The first ordinary SwiftUI scene consumes startup once and presents a listener
instead of constructing an outbound ConnectionModel. Finder/profile windows do not
consume that request. Subsequent ordinary windows are normal outbound forms. Scene
reappearance cannot restart a stopped listener. The CLI option request follows each
accepted peer through NativeSessionDefaults, including display recovery before
session admission for numeric launches or the approved file snapshot for file launches.
The process-captured credential owner transfers only to the first
successfully opened incoming window. It is not restored, cloned or recreated from
PasswordFile for later peers. Failed window opening keeps the unclaimed owner;
Stop/close clears it. An admitted window retains its own owner when listening stops.
Manual listeners do not capture or consume CLI credentials.

Listener/model fixtures cover multiple peers, stop/start and reverse authentication,
but full actual app menu/window interaction, reverse TLS trust UI and
installed LAN/firewall/privacy acceptance remain open. See TODO.md for the exact
test and visual-validation scope.

C capability LISTENER is 8796093022208, currently macOS/Linux only. It adds nine
exports (111 total), new additive options/address/snapshot/event structs, and reuses
the existing session operation and callback structs. See TODO.md for test evidence.
