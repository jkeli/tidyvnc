# Native connection options

Implementation for the shared/reconnect portion of N4.8. Display-selection and
remote-resize policy controls, physical keyboard/VoiceOver acceptance and the full
native migration remain open.

## Shared access

`Shared` controls the single RFB ClientInit shared byte. The compiled default is
false, matching `vncviewer/parameters.cxx`. True requests shared access; false may
cause the server to disconnect other viewers. The server controls the actual result;
this is not a promise that it will accept either request or preserve other sessions.
It does not alter authentication, encryption or trust policy.

The protocol session owns the Boolean and sets it on each new CConnection before
handshake processing. SessionWorker keeps it behind the command-admission mutex
with a monotonic revision. Reads return value, generation, revision and editability.
Updates compare generation/revision and require a reusable session between fully
drained attempts. Setup, authentication, connected and disconnecting/draining states
reject edits. The worker copies the accepted value before the next attempt begins.
No legacy global parameter is read or changed.

SHARED_SESSION (268435456), required by NativeRuntime, adds
`tidyvnc_session_sharing` and `tidyvnc_session_set_shared` (79 total C exports including remote layout).
The getter uses a size/version-tagged owned value; the setter accepts only 0/1,
compares both identities and returns the new revision synchronously. No asynchronous
completion event is produced. Errors preserve outputs and policy. The existing
session-options layout is unchanged; a host can set the flag before its first
connection. Native construction installs explicit shared=true before Connect is
available. Existing source/default values remain false.

## Retry after errors

`ReconnectOnError` defaults to true, matching the retained viewer’s setting to
show a reconnect choice. It does not mean automatic reconnect. The native flag is
owned by the connection window and controls whether an otherwise recoverable error
shows Retry. With it off, the error still appears and manual Connect remains
available after dismissal. Retry commands recheck both the policy and existing
endpoint/generation/problem identity guards. Fatal/non-retryable errors do not gain
a Retry action when the flag is enabled. No transport retry loop, timer, implicit
credential submission or automatic preference migration is added.

## Defaults, profiles and per-window edits

Defaults schema 8 and profiles schema 7 introduced optional top-level Boolean fields
`shared` and `reconnectOnError`; current writers use defaults 9/profile 8. Absence inherits independently per field. Numeric,
string and null lookalikes fail validation; old schemas reject these new fields.
All older schemas remain readable without rewriting, and explicit saves upgrade
records. Existing revision/conflict/recovery rules continue to apply.

Connection Defaults > Connection and saved profiles offer inherit/on/off choices.
A newly created window resolves app defaults then profile overrides and captures
initial values/sources. Subsequent defaults/profile saves do not change that window.
Connection > Connection Settings > Connection opens a local draft while disconnected.
Apply stages shared access for the next handshake and updates the Retry policy;
Done then Connect starts the next attempt. Each field can restore the window’s
initial value. Current sources are shown; untouched fields keep their source.
This does not save defaults or modify profiles.

The local editor commits with core generation/revision CAS. The host Retry flag is
changed only after that synchronous commit succeeds on MainActor, so stale/active
rejection leaves both values unchanged. Connect and other sheets are excluded while
the draft is open. New attempts and window close invalidate/dismiss the draft. Cancel
leaves both values untouched. No asynchronous cleanup task is needed for this Boolean
editor; it performs no file IO, crypto parsing or protocol processing on MainActor.

## Evidence boundaries

Core tests inspect ClientInit on repeated handshakes, race eight revisions, reject
active/stale/closed updates and check setup/prompt/drain exclusions. The pure C
consumer checks feature negotiation, headers, booleans, stale revisions and output
preservation. Native tests read every older schema, validate strict Boolean types,
exercise field precedence and use real loopback peers to observe simultaneous shared
and exclusive requests and a changed request on reconnect. A peer closure verifies
that disabling Retry leaves manual Connect available. Controller/editor isolation
and light/dark default/custom/session renders are tested separately from physical
menu, keyboard, VoiceOver and server-specific shared-session acceptance.
