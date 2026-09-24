# Portable C boundary

`tidyvnc.h` is the version-1 internal C interface. The static
`tidyvnc_viewer_c` target owns all C++ implementation and links the portable viewer
core. `module.modulemap` makes the header importable as `TidyVNC`; the opt-in
[`TidyVNCNative` Swift layer](../../platform/macos/README.md) owns it on macOS.
The existing FLTK
executable keeps its current C++ path.

## Version, values and diagnostics

Zero-initialize each top-level struct, set `size = sizeof(value)` and
`version = TIDYVNC_ABI_VERSION`, then call its initializer where provided. Input
reserved fields must be zero. Smaller structs and unknown versions are rejected;
larger structs have only their known prefix read/written. Unknown tail bytes are
ignored, so new mandatory behavior must use version or required-feature checks.
`tidyvnc_get_abi` advertises only implemented capabilities and compiled RFB
security IDs. Runtime creation rejects any unknown required feature bit.

The interface uses fixed-width scalar fields and explicit constant values. Spans
use byte pointers and 64-bit lengths. Callers must supply accessible memory;
null/length/overflow validation does not make arbitrary invalid addresses safe.
Text is valid UTF-8 without embedded NUL, bounded to 4096 bytes unless a call
documents another limit (clipboard 256 KiB; scaling syntax 64 bytes). Endpoint text uses
the shared viewer parser, including display/port notation, IPv6 scope and Unix
paths. Input spans are copied before returning from asynchronous admission.

`endpoint_validate` (feature `ENDPOINT_VALIDATION`, 1024) performs synchronous
syntax validation without a runtime or handle. It borrows its UTF-8 span only for
the call, admits at most 4096 bytes and accepts an explicit 0/1 Unix-socket policy.
The same bounded helper is used by `session_connect`; both report identical
structured syntax errors before admitting any connection operation. Overlong
input returns ENDPOINT/TOO_LONG before allocation or pointer access. Malformed
spans, embedded NUL and invalid UTF-8 return BRIDGE/INVALID_ARGUMENT. No input text
is copied into diagnostics. Empty input retains the core's localhost display-0
meaning; native forms separately require a nonempty field. The parser performs
no DNS, socket or filesystem IO and does not establish reachability, authorization
or server identity. No endpoint is rewritten by preflight validation.

Every export translates exceptions, including allocation failure, into a status.
The optional size/version-tagged error supplies domain, detail, native error and
fixed diagnostic text. Exceptions' potentially sensitive `what()` text is never
copied. Endpoint validation has explicit detail values. Asynchronous setup/auth/
protocol failure is reported in events/snapshots with explicit end reasons and
native codes. Successful polling with no data returns NO_CHANGE; incomplete drain
returns PENDING. Other output storage remains unchanged on these results/failure.
Previously returned owned handles must be released before their output storage
is overwritten by a later successful call.

## Handles and lifetime

Handles are opaque 64-bit IDs, not pointers. A synchronized registry checks kind,
liveness and reference count before access. IDs never wrap or reuse, so stale
handles cannot alias a later object. Zero and arbitrary/released IDs are invalid;
wrong kinds are distinct errors. Explicit retain/release works on any thread.
Keep a reference during calls and for the full use of borrowed image/prompt spans.
An in-flight call retains its implementation object while it runs, but concurrent
final release can initiate shutdown: callers must not rely on further work being
admitted after they relinquish ownership.

The process registry holds at most 4096 records, including temporary reservations;
the service admits at most eight application runtimes. Runtime session capacity is
1–64, default 16. A runtime slot is occupied until joined shutdown, independently
of the registry handle's lifetime. Handle reservations and owned metadata are
allocated before admitting work or consuming view/prompt updates. A failed
allocation cannot consume an update and then fail to return its owning handle.

A final session-handle release requests close without joining. A final runtime
release requests shutdown of its sessions. An application service thread owns
runtime disposal, waits for core drain, and destroys the runtime only on that
service thread. `runtime_poll_drained` becomes OK after disposal has joined the
runtime's coordinator. The service sleeps when idle and checks closing runtimes'
futures at bounded 20ms intervals. It has eight fixed slots and one joined thread;
no detached task or per-frame cleanup worker is created. Process teardown also
shuts down and joins any unreleased runtimes. Applications should explicitly
close/shutdown and observe drain before releasing their last handles.

Session lifecycle, exactly-once reserved command completions and generations are
preserved from SessionWorker. Connect/disconnect/refresh return operation and
generation together. Permanent close is idempotent and needs no completion slot;
its drain is separately observable. Commands/queries do not wait for network,
authentication or decoding. Construction can allocate and start worker threads.
Listener and layout configuration exports
remain future parts of the ABI rather than advertised implemented capabilities.

## Callback ownership and delivery

`session_subscribe` registers one readiness subscription per session. A shared
dispatcher with 512 fixed slots serializes callbacks; protocol workers and the
join coordinator only signal it. Event, frame/cursor, authentication and joined
session drain changes wake it directly. It does not poll those mailboxes or
allocate a task for every update. Pending readiness coalesces to one bit per
subscription. Round-robin selection prevents a busy session starving another;
a slow host callback can delay other callbacks, so it must enqueue host work and
return promptly. Callbacks run outside registry, dispatcher and core locks.

All three function pointers are required, even with a null context. The caller
must keep the context accessible throughout `subscribe`; `retain_context` runs
once on that caller before publication. Successful registration owns that retain
until `release_context` runs on the dispatcher after the final callback. On a
failed registration after retention, release runs on the caller instead. These
functions must not throw. A violating C++ ready callback is contained, cancelled
and drained; exceptions from release are contained but cannot repair host cleanup.

An initial readiness callback can start before `subscribe` returns. Its numeric
subscription ID is borrowed; retain it to use it beyond the callback. Do not read
the subscribing caller's output variable from that thread, or release the caller's
reference. A callback can safely take events/views/prompts, reply, issue commands,
retain/release owned handles and unsubscribe, without reentering protocol work.
Drain events to NO_CHANGE and take the latest view/prompt on each readiness signal;
also check session drain. Spurious readiness is allowed. Only one consumer owns
each mailbox; callbacks do not copy or reorder the reliable completion stream.

Unsubscribe cancels pending readiness immediately and never waits. Delivery that
has already started may finish; `subscription_poll_drained` is OK only after its
context release has returned. A replacement subscription is BUSY until that point.
Final subscription or session release also cancels; the service keeps in-flight
context alive even if the registry handle is gone. A subscription uses weak session
ownership and cannot keep protocol activity alive after session release. Explicit
session close and runtime shutdown preserve terminal/drain notifications. Protocol
drain and subscription drain are therefore separate obligations. Process teardown
cancels all remaining subscriptions and joins the dispatcher.

Readiness carries the current attempt generation, including a connect admitted
before worker state publication. Each consumed event/frame/prompt retains its own
generation. `subscription_validate` rejects inactive subscriptions and stale
generations, including immediately after a new connect. This is an advisory
check, not a lock across host UI work. A native wrapper must serialize UI delivery
and teardown on its executor, own captures for queued closures, and recheck both
subscription identity and payload generation there. Callback drain does **not**
join arbitrary work the host queued elsewhere or free its captured handles. That
The Swift wrapper now implements this gate with one coalesced MainActor task,
owned captures, a weak model target and explicit queued-delivery drain. Native
app/window lifecycle integration remains open.

## Data and authentication

One consumer reads each session's event, view and prompt mailbox. Event structs
are owned copies; desktop topology records are not exported in this first slice.
View updates distinguish unchanged, new image and clear image/cursor. Each nonzero
image handle owns a retained core lease, charged to the existing shared pixel
budget. Image metadata states format, alpha, top-left origin, stride, generation,
size generation, sequence and cursor hotspot. Its immutable pixel span remains
valid until the last image reference is released, including across reconnect and
after session/runtime destruction. Core dimension/stride/overflow checks precede
publication; the C boundary never invents an unchecked server buffer length.

The session initializer snapshots compiled security defaults, not legacy global
settings. Callers can supply an explicit allow-list, including an empty deny-all
list. TLS priority/CA/CRL spans are copied; system trust and existing protocol
verification are retained. Framebuffer and publication budgets default to 64 and
128 MiB and accept 1 byte–1 GiB, subject to core construction/use validation.
Event, command and prompt-timeout values retain their core validation and bounds.

Prompt handles own server name, fingerprint and certificate/key bytes independently
of the session. Replies require prompt ID plus attempt generation; cancellation
wakes a parked worker directly. Credential submission accepts mutable spans only,
copies into the rendezvous, and wipes both supplied spans on every return when
nonnull and at most 4096 bytes, including validation/reply rejection. Temporary
bridge strings are wiped too. The caller retains ownership of the input buffers.
This cannot erase foreign-runtime copies, arbitrary invalid pointers or unknown
oversized storage; it does not promise compiler/runtime-wide secret zeroization.
Trust replies remain explicit decisions. No credential caching or persistence is
added. Input calls preserve core view-only, focus, transition and overflow rules.

## Evidence and remaining work

`tests/viewer/c-abi-smoke.c` is compiled as C99, includes only the C header and C
standard headers, and checks versions, flags, spans, errors, types, stale handles,
ownership, shutdown and secret wiping. Its separate test-only C++ support injects
allocation failures on the calling thread at 48 allocation positions, without
adding a production fault-injection API or affecting background workers.
`tests/unit/viewerabi.cxx` drives the interface through real loopback RFB peers:
frames, input/release barriers, reconnect, VNC password authentication, retained
payloads, parked-prompt cancellation, independent sessions and runtime capacity.
The clean headless dependency audit traverses both C and C++ smoke targets.

Six additional ABI tests cover callback self-unsubscribe/reentrant queries,
running/queued cancellation, final session/subscription release, replacement
admission, stale generations, exception containment, callback-driven VNC prompts,
server frames, exactly-once completion and joined drain. The pure C consumer
also exercises callbacks and eight allocation-failure positions during subscribe.
Core mailbox tests cover weak wake ownership and event/frame/cursor/clear signals.

This proves a C consumer on the current host, not Linux/Windows execution or a
native UI. Swift owning wrappers and queued host delivery/drain are now exercised
by the separate native bridge suite. The opt-in macOS app now exercises AppKit/
SwiftUI presentation and native lifecycle cleanup. Reverse/listen exports and their
Swift owner are implemented below; app routing and remaining settings/service
interfaces stay open N2/N3 work. Polling remains a low-level
mailbox API; native presentation can now be driven by readiness callbacks.

## Shared desktop geometry

The GEOMETRY capability adds synchronous `tidyvnc_desktop_geometry`, with no
handles or callbacks. The size/version-tagged input contains remote dimensions,
logical viewport size, backing scale, pan, explicit-size units and a borrowed
scaling string (at most 64 bytes). It delegates parsing, placement and clamped
inverse mapping to `DesktopTransform`. Output is a logical rectangle, backing
dimensions and one remote point. Native painting and input use the same result;
fractional backing scales retain the core's pixel-origin rounding. Calls are
independent and thread-safe. Invalid headers, units, nonfinite/range values,
spans and scaling syntax return structured errors without changing output;
scaled-dimension overflow returns RESOURCE_LIMIT. Pure C tests cover placement,
clamping, fractional-origin rounding and malformed input. No GUI/OS type enters
the public C surface.

## Clipboard boundary

The CLIPBOARD capability adds six exports: change independent send/receive policy,
offer local text, withdraw a local offer, consume the clipboard mailbox, inspect
retained text, and validate a route before native presentation. Offers use the
normal reserved operation/completion stream and cancellation; optional change IDs
appear as completion origins. Completion proves protocol send/announcement, not
a write to the remote OS clipboard. Empty text is valid; invalid UTF-8/NUL fails.
The current ABI uses the core defaults of 256 KiB per text and 1 MiB total retained
payload per session. Core normalization uses LF while existing RFB negotiation
retains extended UTF-8/legacy Latin-1 interoperability.

Mailbox output contains a sequence, kind, result, route and optional owned text
handle. Text-info spans are immutable and borrowed while that handle is retained;
it keeps the core byte budget alive after session/runtime disposal. Taking first
reserves handle capacity and allocates metadata, so allocation failure cannot
consume and lose an update. The shared readiness subscription signals clipboard
publication/policy invalidation through weak internal wake targets outside locks.

Route tokens include the originating opaque session ID (identity only, without a
session reference), attempt generation, focus revision and policy revision.
`tidyvnc_session_clipboard_check` rejects foreign sessions and stale routing even
if two sessions' revision counters coincide. Validation is advisory: the host must
serialize focus and native writes and recheck immediately before writing. Tokens
are not cryptographic authorization. Remote-origin text handles supplied to offer
suppress echoes across sessions and reconnects. DISABLED and ECHO are distinct
statuses; focus and view-only policy remain enforced by the core. Clear withdraws
protocol availability without clearing the user's native clipboard.

Swift `NativeClipboardText` copies bounded UTF-8 into an immutable String and also
retains the C lease/provenance. MainActor sessions publish typed updates, expose
async offer/clear, policy controls and route validation, and clear clipboard/focus
presentation on close/reconnect. The macOS adapter now observes NSPasteboard through
an injected MainActor contract. An app-wide coordinator routes to one eligible
focused session, preserves remote-write provenance across sessions, bounds pending
host transfers and joins cleanup. Per-connection controls expose independent send
and receive policy. Isolated named pasteboards and controlled peers exercise the
adapter and routing; tests do not access the user's general clipboard. Visible
control and app activation verification remain N3.15 work (Mac locked at the latest
attempt). No Windows backend or minimum-OS execution is established by these tests.

## Encoding schema and immutable options

The ENCODING feature (512) adds seven exports. With endpoint validation, scaling
parsing, tile rendering, damage geometry and cursor sampling, the boundary now has
54 C symbols.
`encoding_schema_at` and `encoding_choice_at` enumerate the core's schema and
compiled decoder choices, returning NO_CHANGE at the end. Names, aliases, defaults,
ranges, persistence/live flags and availability come from `EncodingOptions`, not a
second frontend table. All returned strings are copied into NUL-terminated 32-byte
fields. Schema IDs, value types and source IDs have explicit C constants.

`encoding_create` returns an immutable owning snapshot. A zero base starts with
compiled defaults; a nonzero base is copied before applying a patch. The assignment
element is a fixed pair of byte spans. At most 256 assignments of 128 UTF-8 bytes
per name/value are admitted and copied before return. The shared validator handles
aliases, canonical values, ranges, decoder availability and last-duplicate-wins
semantics. Failure preserves the base and output handle. Each assignment records
its explicit compiled/app/profile/session/CLI source. Source labels are provenance
metadata supplied by the caller, not authorization. `encoding_get` copies one
canonical value/source; handles share the existing 4096-entry registry bound and
remain valid after their originating session/runtime is disposed.

`session_create_with_encoding` copies a supplied snapshot before negotiation; zero
uses defaults and the original `session_create` delegates to this path. Existing
session-options layout is unchanged. `session_encoding` returns a newly retained
snapshot of requested options. `session_apply_encoding` checks generation and
copies options into the existing bounded command queue with a reserved completion.
The caller may immediately release its encoding handle. Completed application
updates only that session and persists across reconnect. Completion is local
application, not a server acknowledgement or proof that a new framebuffer used
those settings. Encoding hints are sent at the protocol's next safe update point;
automatic selection and pre-3.8 pixel-format policy remain in the shared core.

Encoding validation errors use domain 6. The low 16 detail bits identify unknown
option, invalid value, unavailable encoding or oversized patch; high 16 bits hold
option ID + 1, or zero for a patch-wide error. Status distinguishes unsupported
capabilities and resource limits from invalid values. Diagnostics never contain
caller text. Span/ABI/handle errors keep their existing boundary classifications.
All exceptions are caught before returning through C, including allocation failure.

Swift `NativeEncodingOptions` owns these immutable snapshots, copies schema/value
strings and bounds its temporary contiguous UTF-8 patch buffer. It exposes shared
schema/choices and typed option/source/problem enums. Session configuration accepts
an initial snapshot, and `applyEncoding` uses reserved async completion/cancellation.
An already executed command cannot be undone by cancellation; callers can query
requested options to reconcile. The native app persists a typed encoding patch,
validates it through this schema, and creates each session only after defaults have
loaded. Its app Settings controls use shared ranges and decoder availability.
Its separate connection encoding draft applies via the async command boundary,
checks generation and observed baseline changes, and rereads after uncertain
outcomes. The app serializes encoding editors per connection; this adds no core
compare-and-swap guarantee. Interactive UI acceptance remains open.

## Stateless scaling parsing

`TIDYVNC_FEATURE_SCALING` (2048) exposes `tidyvnc_scaling_parse`. It calls the
existing `ScalingSettings::parse` and copies mode, x/y, fit status and canonical
text into a size-tagged result. Input is borrowed for the synchronous call and
limited to 64 UTF-8 bytes; null spans, embedded NUL, malformed text and unsupported
headers fail without changing output. Diagnostics never include input text.
The explicit eight mode IDs are checked against the shared core at compile time.
A percentage of 100 canonicalizes to Unscaled; x/y use hundredths of a percent
except Exact's dimensions. Canonical strings fit the 64-byte NUL-terminated field.

This call creates no runtime, handles, subscriptions or IO, and can run concurrently.
Syntax validation alone cannot prove a selected size fits a particular display.
Use `tidyvnc_desktop_geometry` for framebuffer/viewport/backing-scale validation.
The native draft performs that check against its attached view before Apply.
Pure-C boundary tests and concurrent C++ differential tests cover this export.

## Bounded shared desktop tile rendering

`TIDYVNC_FEATURE_TILE_RENDERER` (4096) adds `renderer_create`, `renderer_render`
and `renderer_clear`. A renderer owns a mutex and the shared `FrameTileRenderer` /
`DesktopTileCache`, with a caller-selected 0–32 MiB cache budget. It retains no frame
lease. Each render borrows an owning image handle for the call; a retained frame
continues to render after its session/runtime closes. Cursor images are currently
unsupported by this surface; use the separate cursor sampler below. Run render and clear off the UI thread; area filtering
may inspect the complete source footprint for a tile and is not interrupted within
one tile. Final release does not join protocol work or cancel a concurrent call.

Requests carry destination dimensions (1–65535), filter, a tile of at most 256 × 256,
previous consumed frame sequence, and source-coordinate damage. Output is tightly
packed opaque BGRA in the caller's bounded mutable span, with copied cache-hit/byte
statistics. Shared nearest, bilinear and area algorithms are used, including their
identity branch. Header, bounds, lengths, reserved fields, source and damage are
validated before output or cache changes. Cache allocation failure preserves the
rendered output and clears cached pixels; later calls can cache again.

The bridge identifies image streams by never-reused session handle IDs. Source,
attempt generation, size generation, dimensions or filter changes invalidate cached
samples. Partial damage is accepted only when the cache's previous frame matches
the supplied history; skipped native frames force a complete cache invalidation.
All tiles for a frame must use the same history/damage metadata. No caller-provided
history is interpreted as a protocol generation or permission. Clear drops cache
pixels and history; a zero budget provides uncached rendering.

Core tests cover partial damage, skipped frames, source/resize/filter isolation,
cache budgets, unchanged output on failure and both cache allocation-failure
positions. C ABI tests cover concurrent calls, retained frames through close,
fixed BGRA pixels, typed-handle errors and pure-C span/header/budget/allocation
failures. The native AppKit view now composes these tiles and reuses unchanged
CG images; cursor filtering and measured presentation budgets remain N5 work.

## Shared damage geometry

`TIDYVNC_FEATURE_DAMAGE_GEOMETRY` (8192) adds `tidyvnc_desktop_damage`. It accepts
the same geometry options as desktop placement plus source-coordinate damage and
an explicit nearest/bilinear/area filter. The shared transform supplies filter
halos, backing-pixel rounding, pan and logical placement; callers clip the returned
logical rectangle to their viewport. Empty source damage produces an empty result.

This synchronous, stateless call is thread-safe, performs no IO and retains no
input or output memory. Headers, reserved fields, source bounds, quality and
geometry are validated before writing the copied rectangle. Output is untouched
on failure. Pure-C failure tests and differential shared-transform tests cover it.

## Immutable shared cursor sampling

`TIDYVNC_FEATURE_CURSOR_RENDERER` (16384) adds `cursor_renderer_create` and
`cursor_renderer_render`. Create accepts a retained cursor image, positive finite
X/Y backing-pixel scales (each at most 65535) and a shared filter ID. It copies
at most 4 MiB of packed straight RGBA into the shared `CursorRenderer`'s original-
sized premultiplied storage, retaining no source image or session lease. Frame
images and other formats/alpha layouts are rejected. Copied output geometry
contains rounded dimensions, clamped hotspot, an all-transparent-source flag and
source-storage byte count.
Dimensions follow the shared sampler's `INT_MAX/4` limit, so extremely enlarged
cursors can be sampled without allocating their full raster.

Each render writes packed straight RGBA for a nonempty tile at most 256 × 256;
its output span must hold the tile and be at most 256 KiB. Filtering is performed
in premultiplied alpha, then converted by the existing shared algorithm. Transparent
source colors cannot bleed into visible edges. Tile bounds, spans, versions and
reserved fields are checked before output changes. Create leaves both outputs
unchanged on failure, including allocation failure. Final release frees the source
copy; the sampler is immutable and concurrent render calls with separate output
spans are supported. Create/render are synchronous CPU work for background callers;
a tile's area-filter work is not interrupted by release or cancellation.

C++ loopback tests compare all filters, fractional/anisotropic scales, extreme
zoom tiles and hotspots with shared samples and independent alpha goldens. They
exercise concurrent calls after runtime/source disposal and injected construction
allocation failures. Pure-C consumers check invalid headers/scales/spans/handles
and unchanged outputs. The Swift `NativeCursorSampler` owns the handle, validates
tiles before allocation, checks cancellation around calls and wraps each tile in
an immutable straight-RGBA CG image without a Data copy. AppKit now uses these for
bounded native/software cursor presentation. Physical cursor acceptance, fallback
settings UI and end-to-end performance remain N5 work.


### Negotiated credential prompt method

The PROMPT_SECURITY capability (1048576) adds `tidyvnc_prompt_security_type`.
It reads the immutable negotiated method captured on the protocol worker when the
credential callback starts, including the selected VeNCrypt subtype. It does not
infer the method from configured preferences or a later connected snapshot. The
existing prompt-info layout is unchanged. Trust prompts and legacy direct callback
callers report zero, which is not a valid credential key method. Retained prompt
handles remain readable after the attempt ends; null outputs, released handles and
wrong handle types leave caller storage unchanged. The Swift runtime requires this
capability and copies the value into NativePrompt. There are now 64 C exports.

SessionAuthentication's new default-forwarding method preserves existing adapters
implementing the original credentials callback. PromptAuthentication records the
method for native callers. Real VNC and X509Vnc socket tests cover the negotiated
method and retained trust-before-credentials ordering; pure-C and typed ABI tests
cover the new query's failure behavior.


### Shared certificate exception policy

CERTIFICATE_POLICY (2097152) adds `tidyvnc_certificate_policy_get`, bringing the
C surface to 65 exports at that step (68 with certificate-key queries below). It classifies the raw certificate_status in a retained
prompt into stable presentation reason flags, fatal bits and may_override. All
status values are classified; unknown bits and zero cannot authorize an exception.
The call is stateless, performs no IO, works in non-TLS builds and leaves output
unchanged on invalid headers/null output. Swift requires the capability before
creating sessions. No existing prompt or snapshot layout changes.

The same portable classifier supplies CConn's original allowed-errors mask and
PromptAuthentication's trust-reply gate. A forbidden affirmative reply returns
Unsupported, keeps the request pending and cannot bypass the existing generation,
expiry or kind checks. The host can still cancel normally. Trust persistence and
expected-identity metadata are not supplied by this ABI addition.


### Exact certificate public-key identity

CERTIFICATE_KEY (4194304) is optional and present only with GnuTLS. The owned
`certificate_key_create/get/digest` surface brings the ABI to 68 exports. Create
accepts 1–65536 certificate bytes and extracts their exact SPKI through GnuTLS into a typed
handle; get borrows SPKI for the retained handle lifetime. Digest takes a supported
GnuTLS digest ID and returns at most 64 owned bytes in a versioned fixed-size value.
The private per-call backend performs no filesystem IO and catches callback
exceptions. Invalid sizes/DER/digests, headers, stale/wrong-kind handles and disabled
TLS preserve output and report typed statuses. Swift copies the SPKI before dropping
its owner. This helper does not verify trust or create an exception; the existing
policy gate and the frontend's separately scoped store decision still apply.


### RSA-AES host-key encoding policy

HOST_KEY_ENCODING (8388608) adds stateless `host_key_validate` (69 C exports total).
It accepts the exact protocol encoding, at most 2052 bytes, and returns actual
modulus bits. Invalid/null/oversized encodings and null output preserve output.
Declared lengths are bounded to 1024–8192; the retained server rounds them to whole
bytes, so actual bits need not equal the header. The helper checks widths and
public-number constraints without allocation, filesystem IO or a crypto-library
dependency. It does not establish trust or prove possession of a private key.

The protocol uses the same component validation before Nettle preparation, and
PromptAuthentication refuses malformed affirmative host-key replies with
PolicyRejected/Unsupported while keeping the prompt cancellable. NativeRuntime
requires the capability and NativeHostKey uses it before one-time or persistent
approval. Existing ABI layouts are unchanged.

### Required configured TLS files

`TIDYVNC_FEATURE_REQUIRED_TLS_FILES` (16777216) guarantees that nonempty `ca_file`
and `crl_file` selections must load at least one PEM CA/CRL during each X509 TLS
attempt, before trust or credential prompts. Creation copies and validates strings;
it performs no file IO. NUL values are invalid. Without GnuTLS, nonempty selections
return Unsupported at creation without writing the output handle. The native
runtime requires this capability. This feature adds no C layout or function-count
changes. Including the security catalog, priority preflight, disconnected security
reconfiguration, sharing and remote layout below, the current total is 79 exports.
The internal TLS option is enabled by the C bridge; retained parameter consumers
keep their existing load-warning behavior. Normal system trust, chain, hostname
and revocation checks continue. Files are read per attempt, not pinned at creation.

### Security method catalog and selection

`TIDYVNC_FEATURE_SECURITY_SELECTION` (33554432) adds two stateless checked exports,
`tidyvnc_security_choice_at` and `tidyvnc_security_resolve` (79 exports total with
priority preflight, disconnected security reconfiguration, sharing and remote layout below).
The catalog copies canonical names/IDs, compiled availability and explicit numeric
protection/credential classifications. Known uncompiled choices remain visible.
The resolver either snapshots compiled defaults or parses at most 1024 bytes of
canonical case-insensitive comma-separated names; empty input with defaults=0
means deny-all. It rejects unknown/uncompiled types and empty tokens, deduplicates
first occurrences and never changes server offer ordering. Domain Security (7)
provides stable semantic error reasons. Failed calls and end-of-catalog preserve
output. Existing layouts stay unchanged; no new handles or platform types appear.
See [SECURITY.md](../../plans/native-ui/SECURITY.md) for semantics and validation.

### TLS priority preflight

`TIDYVNC_FEATURE_TLS_PRIORITY_VALIDATION` (67108864) adds
`tidyvnc_tls_priority_validate`. Including security reconfiguration, sharing and remote layout
below, the current total is 79 exports. The stateless
call takes at most 4096 UTF-8 bytes. Empty means library defaults and always succeeds;
nonempty text requires GnuTLS. It validates usable X509 or anonymous TLS priority
syntax, including the retained anonymous KX suffix, without changing global policy.
It may read GnuTLS configuration and should run off UI threads. It cannot establish
server compatibility. Invalid syntax uses Security reason INVALID_TLS_PRIORITY (5),
Unsupported uses UNAVAILABLE (2), and excessive length uses TOO_LONG (3). Session
creation copies the priority without parsing and rejects nonempty text when GnuTLS
is absent. The protocol worker remains responsible for actual TLS configuration.

### Disconnected security reconfiguration

SECURITY_RECONFIGURATION (134217728) adds `tidyvnc_session_security` and
`tidyvnc_session_set_security`. The getter copies canonical types, priority and
CA/CRL paths plus generation, revision and editability. The type list is NUL-terminated;
priority/path arrays use explicit byte lengths up to 4096 (they need not end in NUL).
The setter takes bounded spans and expected generation/revision; its synchronous
commit increments revision with no asynchronous operation or completion event.

The core serializes this compare-and-replace against connect, disconnect and close.
Only a reusable session between fully drained attempts is editable. Active attempts
return Busy, mismatched generation/revision returns Stale, and permanent closure
returns Closing. Failure leaves policy and outputs unchanged. Policy copying does
not parse GnuTLS expressions or open files; run the TLS preflight off UI threads
before applying. Actual security installation occurs on the worker before the next
attempt. Old immutable snapshots and session mailboxes remain valid. The two new
functions bring the current export count to **79** with sharing and remote layout below. See SECURITY.md for native
editor, credential/trust invalidation and proof boundaries.

### Shared-session flag

SHARED_SESSION (268435456) adds the owned `tidyvnc_session_sharing` snapshot and
`tidyvnc_session_set_shared` disconnected-only CAS update (79 total exports including remote layout below).
Shared defaults to false. The setter validates 0/1 and expected generation
and revision, rejects active/draining/closing or stale sessions, and preserves outputs
on failure. Accepted updates increment revision synchronously without a completion
event. The worker sets ClientInit’s shared byte on the next attempt. The server’s
sharing policy determines its effect. Retry-after-error is a host UI policy and does
not create transport retries in the core. See CONNECTION.md for native integration.

### Remote desktop layout

DESKTOP_LAYOUT (536870912) adds shared stateless geometry validation, an owned
connected-layout snapshot and an asynchronous remote-layout request (79 exports
total). `tidyvnc_desktop_layout_request` borrows 1–255 screens only for the call;
`tidyvnc_desktop_layout` copies all screens with a coherent session snapshot.
Bounds are 1–65535 pixels, unique IDs and positive enclosed screens; flags and
legal gaps/overlaps survive. Outputs remain unchanged on failure.

`tidyvnc_session_request_desktop_layout` uses the existing worker queue and exactly
one completion. Acceptance is not server success: completion reports reply,
rejection, timeout or teardown. Queued cancellation may win; after sending, consume
the eventual completion. Timeout leaves the wire slot busy until the late response
or reconnect. See [REMOTE-RESIZE.md](../../plans/native-ui/REMOTE-RESIZE.md) for all
contracts, native integration and remaining automatic/display policy work.


## Session input timing

INPUT_TIMING (68719476736) adds `tidyvnc_input_timing_init` and
`tidyvnc_session_create_with_input_timing`. These are two of the current **113 exports**.
The size/version/reserved-checked timing value owns a pointer interval in milliseconds
(0 through INT_MAX); initialization returns the shared viewer default of 17 ms.
Creation also accepts the existing encoding handle and copies all configuration
before publishing the new session. Invalid headers, bounds, handles or allocation
failures leave outputs unchanged. No existing structure grows or export changes.
Original create functions retain unthrottled input; hosts opt into timing through
the new creation call. NativeRuntime requires this feature.

The protocol worker owns one pending pointer value and a monotonic scheduler token.
Timing follows middle-button emulation: movement keeps its first deadline, button
and wheel transitions bypass the delay, and a following key flushes pending motion.
Callbacks check generation and routing revision as well as connected/focused/
view-only state. Release barriers and terminal cleanup discard pending motion;
reconnect retains the configured interval but cannot replay an earlier attempt.
No UI callbacks, OS handles, global timer list or per-motion allocation queue is
exposed through the API.


## Incoming message limits

MESSAGE_LIMITS (137438953472) adds `tidyvnc_message_limits_init` and
`tidyvnc_session_create_with_message_limits`, bringing the ABI to **96 exports**.
The checked size/version/reserved value accepts `max_cut_text` from zero through
INT_MAX and initializes it from the shared 256 KiB reader default. Creation requires
both the timing and message-limit values and copies them before session publication;
encoding remains optional. Failed validation leaves output handles/values unchanged.
No old structure grows. Older creation functions delegate using default message limits.

The limit applies separately to plain clipboard wire bytes, the extended wire payload
and each decompressed format, matching retained MaxCutText semantics. It is not an
aggregate allocation budget and does not restrict outgoing text. Independent UTF-8
clipboard retention budgets remain active. Choosing a large cap allocates no payload;
readers apply it to received data. It is immutable for the lifetime of the session and
survives reconnect without consulting a process-global registry. NativeRuntime requires
the feature; there is no live policy setter.

## Window geometry parsing

WINDOW_GEOMETRY (274877906944) adds `tidyvnc_window_geometry_parse`, bringing the
ABI to **97 exports**. This checked, stateless UTF-8 parser shares retained window
geometry syntax and returns supplied-size/position flags and copied signed values.
It accepts no OS handles and performs no display lookup or window mutation. Empty
text means no override; malformed, nonpositive dimensions, overflow, NUL or over
65536 bytes fail with outputs unchanged. Geometry's position is absolute signed
top-left coordinates, not right/bottom offsets. NativeRuntime requires the feature.

## Process startup logging

PROCESS_LOGGING (549755813888) adds `tidyvnc_logging_validate` and
`tidyvnc_logging_configure`. FILE_LOGGING (1099511627776) adds
`tidyvnc_logging_configure_with_file`, bringing the ABI to **100 exports**. These
features are currently available on macOS/Linux. Validation uses an owned startup
snapshot of registered writers and opens no destinations. Supported targets are
stderr/stdout/file and empty (disabled); unknown destinations report UNSUPPORTED.
The ordinary configure call uses `/tmp/vncviewer.log`; the additional call copies
an absolute UTF-8 path for embedding hosts, validating it even if file is unused.
Neither call accesses the log file at configuration time.

Configure prepares every needed redacted sink before publishing any writer change.
Failures release staged resources, preserve routes and permit retry. Successful
configuration is process-wide and closes admission. The first runtime creation gate
also closes admission, including when logging was never configured; shutdown does
not reopen it. Later configure calls return BUSY/LOGGING_FROZEN. Validation remains
available. Callers must finish static writer registration before use and must not
mutate the legacy registry/configuration or locale concurrently.

Stdout/stderr descriptors are duplicated at fd >= 3 with close-on-exec; originals
stay open and their status flags are unchanged. Known templates are redacted before
string/pointer expansion, key events are suppressed and audited numeric metadata
is retained. Output is synchronized. A process owner outlives RuntimeService's joined
shutdown, then detaches every writer before destroying destinations. Consumers that
never configure preserve their existing logging. No new C struct or persisted state
is introduced. The LOGGING domain encodes entry/reason and never reflects input.

File output opens on its first emitted record, uses 0600 owned single-link regular
files and one `.bak`, and holds a nonblocking private `.lock` until sink closure.
No-follow leaf operations and no-overwrite publication reject unsafe entries.
The parent must be owned by this user/root and not writable by others, except a
root-owned sticky directory; macOS extended parent ACLs are refused before creation.
File ACLs are cleared before use. A second cooperating process falls back to stderr
without rotating the owner's file. The persistent sidecar is intentionally retained
after close. Other writers must cooperate with this advisory lock.

File failures produce a fixed warning and redacted stderr output; failed writes
retry the current record there. No path/errno string is reflected. Configuration
remains successful when later file IO fails, so session workers can proceed.
Rotation preserves old log bytes in the backup before publishing a new log but is
not atomic across all entries; failure can leave the old log only in `.bak` and may
already have removed an earlier backup. There is no size cap or periodic rotation.

## Legacy password-file replies

PASSWORD_FILE_REPLY (2199023255552) adds `tidyvnc_session_reply_password_file`,
bringing the ABI to **101 exports**. This consumes one mutable eight-byte obfuscated
legacy password block; it performs no file IO. The shared decoder preserves raw
password bytes, stops at the first decoded NUL and never converts through UTF-8.
The existing username/password reply remains UTF-8. Legacy password files use
obfuscation, not encryption.

Only a current password-only credential request may consume the result. Prompt ID,
generation, deadline, cancellation and kind are checked under the same rendezvous
lock, so username-required requests are not answered with an empty username. Mutable
input is wiped on every return when nonnull and at most 4096 bytes, even for invalid
size, stale request, invalid error headers and allocation failure. The decoded
stack buffer and bridge-owned plaintext are also cleared; this is not a guarantee
about arbitrary caller/runtime copies or crypto implementation scratch. No opaque
secret handle, persistent state or automatic credential reuse is introduced.

The host must authorize/gate file reads on a current prompt, preserve environment
precedence, discard late results and join pending IO on close. Native actor-based
file reading, the Swift consuming reply, executable launch credential ownership
and native PasswordFile CLI admission are implemented; see the native credential
input contract for precedence, endpoint scope, revocation and drained cancellation.


## Captured legacy credential bytes

CREDENTIAL_BYTES (4398046511104) adds `tidyvnc_session_reply_credential_bytes`,
bringing the ABI at that milestone to **102 exports**. It uses the same current prompt rendezvous and
consuming input contract as the existing text reply, but accepts non-NUL legacy
byte strings without UTF-8 conversion. Each input is bounded to 4096 bytes; valid
bounded mutable spans are wiped on all returns, including invalid input, stale
requests and failure. Bridge-owned strings are cleared. The ordinary credential
text API retains its UTF-8 validation. This new call adds no environment/file IO,
retention or persistence; the host controls capture, scope and cancellation.

## Reverse listener ownership

LISTENER (8796093022208, macOS/Linux) adds nine exports, bringing the ABI
export count at that milestone to **111**. Listener creation uses the app runtime's separate lazy
four-listener service. Copied snapshot/event structs expose numeric bound/peer
addresses, pending counts, monotonic peer/event IDs and typed failure/native codes.
Ordered queues preserve terminal delivery on overflow; no protocol bytes are read
before explicit accept. Accept transfers a peer once into a configured reusable
session and returns its ordinary generation-tagged operation. Invalid handles or
output headers leave it pending; failure after claim closes it, never requeues it.

The readiness subscription uses the same bounded callback dispatcher, retained
context and unsubscribe/drain APIs as sessions. Its generation is always one; a
restart creates a distinct listener handle. Core notifications run outside listener
locks. Stop preserves terminal callbacks and accepted sessions. Final handle release
stops and cancels callbacks. Runtime shutdown/drain covers listeners as well as
sessions, with service destruction on the existing reaper rather than the caller.

NativeListener copies these values onto MainActor through NativeDelivery and checks
peer ownership before dispatch. Its close drains workers and queued callbacks; it
performs no recurring state polling. CLI activation, incoming-peer presentation,
reverse identity/store policy and installed acceptance remain open. See
[LISTEN.md](../../plans/native-ui/LISTEN.md) for the integration contract and bounds.


### Numeric viewport diagnostics

`TIDYVNC_FEATURE_VIEWPORT_DIAGNOSTICS` (35184372088832) adds
`tidyvnc_logging_viewport`, bringing the C header to 113 status-returning exports
(including routed connect). It accepts logical and backing width/height in
1..INT32_MAX; zero and overflow are rejected. The `NativeDesktop` writer emits
only those four measurements at debug level 100 through the existing logging
route. A disabled route is a successful no-op, including after runtime creation.
No logging policy or session state changes. RedactedLogger admits only the exact
numeric template. Native automatic-resize protocol tests use it to compare wire
requests with measured viewport dimensions. See
[PROTOCOL.md](../../plans/native-ui/PROTOCOL.md).

### Portable parameter grammars

`TIDYVNC_FEATURE_PARAMETER_GRAMMARS` (70368744177664) adds three stateless exports,
bringing the C header to 117 status-returning exports. `tidyvnc_desktop_size_parse`
implements both DesktopSize grammars: the retained command-line `%dx%d` form
(`LEGACY`) and the strict native `WxH` form (`STRICT`), each 1..65535.
`tidyvnc_port_parse` is the strict decimal 0..65535 port used for listen ports and
SSH gateway ports. `tidyvnc_ssh_gateway_create/get` validates the `via` grammar and
returns the endpoint host, zone, optional user, port intent and canonical
`ssh://` URI. Frontends derive their own store-scoping digests from those fields;
the macOS route/intent identities are pinned by a regression test and unchanged.
PasswordFile and X509CA/CRL path resolution stays with each platform's file
services, since absolute-path and base-directory rules are platform-specific.

## Shared policy for the Windows frontend

The WinUI plan (plans/native-ui-winui CORE.md sections 4 and 6) adds feature bits
1<<47..1<<53 with additive exports, bringing the C header to 133 status-returning
exports. Each policy module has a JSON corpus under `tests/conformance`, run by
`tests/unit` through these exports and by `TidyVNC.Native.Tests`; the Swift
implementations they mirror must pass the same cases (the Swift runner needs a
macOS host). All are stateless, perform no IO, report typed reasons in their own
error domain, and leave outputs untouched on failure.

| Bit | Feature | Exports | Mirrors (macOS) |
| --- | --- | --- | --- |
| 47 | `NATIVE_ERROR_CATEGORY` | `tidyvnc_native_error_category` | errno/Winsock/Win32 codes as shared categories |
| 48 | `IDENTITY_DIGEST` | `tidyvnc_identity_digest` | `NativeCredentialKey`, `NativeTrustScope`, SSH route/intent/resolved identities |
| 49 | `KNOWN_HOSTS` | `tidyvnc_known_hosts_lookup` | `NativeLegacyTrustCodec` |
| 50 | `MONITOR_NUMBERING` | `tidyvnc_legacy_monitor_order` | `documentMonitorOrder` |
| 51 | `EXPORT_LOSS` | `tidyvnc_export_losses`, `tidyvnc_export_loss_at` | `NativeDocumentExportLoss` |
| 52 | `IMPORT_PROJECTION` | `tidyvnc_import_defaults`, `_defaults_get`, `_assignment_at`, `_notice_at`, `tidyvnc_import_history`, `_history_get` | `NativeDefaultsImportProjection`, `NativeHistoryImport` |
| 53 | `CONFIGURATION_LAYERS` | `tidyvnc_config_resolve`, `_get`, `_value_at`, `_note_at` | `NativeOptionOverlay`, `NativeInvocationResolution` |

Identity digests use a small internal FIPS 180-4 SHA-256 (tested with the NIST
vectors), so they exist in builds without nettle. The known-hosts lookup takes a
certificate-key handle for `c0` commitments and is cross-checked against files
GnuTLS itself writes. Import projection accepts either file bytes (the XDG files)
or decoded values (the Windows registry); configuration layers canonicalize every
parameter through the same validator as the command line
(`canonicalParameter`), so both agree for every available parameter.
