# Native launch credential inputs

The native executable supports PasswordFile/passwd and VNC_USERNAME/VNC_PASSWORD.
Inputs belong to the first ordinary connection window. They are absent from native
preferences, profiles, history, connection documents and Keychain persistence.
This completes launch input wiring; it does not establish installed/physical or
release acceptance for authentication.

## Capture and handoff

Strict argv decoding, help/version and launch preflight finish before environment
credentials are captured. Capture reads only the two named variables, with a
4096-byte limit for each and no UTF-8 conversion. Missing differs from present but
empty. The original process environment is not modified or claimed to be erased.
Owned copies use clearable allocations; other caller/OS/runtime copies are outside
that guarantee. Input errors are fixed and never echo values.

NativeLaunchCredentialInputs permits one atomic claim. NativeInvocationStartup
passes the owner only to the initial ordinary window and clears an unclaimed owner
on stop. Reusing the handoff object cannot give credentials to another window.
The resolved CLI or reviewed document endpoint binds before editable connection
admission. With no initial address, the first explicit Connect binds the scope.
Changing that endpoint revokes the launch inputs rather than forwarding them to
another server. Comparison preserves exact endpoint bytes.

PasswordFile selection validates every occurrence without IO. The last value wins;
empty disables it. Relative paths use the captured launch working directory. No
shell, tilde or environment expansion is performed. A host that injects a native
invocation without a process capture gets its explicit file policy, without a late
environment lookup. New windows and reconnects do not reparse process argv.

## Prompt precedence and ownership

At a current credential prompt, after protocol trust decisions:

1. A present environment password answers password-only authentication. Both
   environment variables must be present for username/password authentication.
   Empty values are legitimate explicit values. Legacy bytes are preserved.
2. For a launch file policy, a matching nonempty password explicitly retained for
   this session precedes a file read. Ordinary windows without launch inputs keep
   their existing explicit Use Session Password action.
3. A password file is read only for a password-only prompt. It cannot fill in a
   missing username/password pair or answer a trust prompt.
4. Otherwise the existing interactive credential prompt remains available.

The source does not prefill observable text fields or populate a credential key.
Automatic submissions never look up, save, replace or delete Keychain entries.
Environment inputs remain owned for unexpected reconnects to the same endpoint;
file inputs are reread for such reconnects unless a matching retained password wins.

NativePasswordFileReader accepts a selected regular file, including a symlink to
one, and reads only its first eight bytes. A second/view-only block and trailing
bytes are ignored. Special/short files fail without a blocking FIFO/device read.
Before/after metadata and cancellation checks protect the bounded read. The block
is obfuscated, not encrypted. Only the shared C++ decoder produces plaintext;
Swift holds a clearable owner of obfuscated bytes and submits a mutable array.

File errors are shown as fixed notices on the still-current prompt. The user may
explicitly enter a password, choose their existing saved/session controls, or
cancel. There is no silent success or automatic fallback to a stored password.
This native recovery UI deliberately replaces the retained viewer's immediate
file-error exit. No path or content appears in the notice.

## Cancellation and drain

Every asynchronous read captures the prompt ID/generation and an owner epoch.
After it returns, submission requires the same live session, current prompt and
epoch and a noncancelled task. The C++ rendezvous rechecks admission under its lock.
Late results are cleared, including from a provider that ignores cancellation.

Explicit Cancel, Disconnect, security changes and window close revoke launch
inputs and cancel pending work. Endpoint changes also revoke them. Unexpected peer
loss cancels pending work without recapturing environment; a later user-requested
retry can reuse the same scoped source. Retry admission remains closed while a
prior read is outstanding, and window close awaits that work. POSIX cancellation
checks do not interrupt an already-running kernel read; drain waits for its return.
This is not a claim of a hard IO deadline for network-backed regular files.

## Bridge and storage boundaries

CREDENTIAL_BYTES (4398046511104) adds a consuming legacy-byte reply, bringing that milestone to 102
C exports (111 after the listener boundary). It accepts two bounded non-NUL byte strings and preserves the existing
UTF-8-only credential API. PASSWORD_FILE_REPLY remains a separate password-only
block decoder/reply. Both use existing request/generation/deadline/kind checks and
clear valid bounded mutable input on every return. No C struct or persisted schema
changed.

Production storage setup now snapshots only HOME and the three XDG path variables.
It does not copy the whole process environment into immutable Foundation strings,
which would also materialize VNC_PASSWORD. Store access, trust policy, ordinary
manual credential retention and explicit Keychain consent otherwise remain intact.

See TODO.md for fixture counts and host limits. Tests use private files, memory
stores and loopback peers, including VeNCrypt Plain with non-UTF-8/empty byte pairs.

With native `-listen [port]`, the listener owns the captured inputs until its first
successfully opened incoming window claims them. Later peers receive CLI settings
but no credential owner and do not recreate the PasswordFile policy. Explicit
Stop/close clears unclaimed inputs; it does not revoke an already admitted window's
owner. Manual listeners do not capture credentials. All reverse windows continue to
exclude Keychain, saved trust/history and outbound retry. Connection-file listener
startup is not yet supported. See LISTEN.md.
