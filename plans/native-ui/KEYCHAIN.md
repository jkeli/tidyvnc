# Native Keychain policy

Decision recorded 2026-09-19 for N0.9. Implementation lives in
`platform/macos/Storage/NativeCredentialStore.swift` and `NativeKeychainBacking.swift`.
The adapter/store and authentication UI integration are implemented. Real
packaged-app and interactive acceptance remain N3.10–N3.14/N6.9.

## Backend and signing

Use SecItem with the Data Protection Keychain in the logged-in user's context.
Apple recommends this backend and describes its provisioned entitlement-based
access model in [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
Do not silently switch to the file-based keychain if access fails.

The app must be packaged with a legitimate provisioned application identity and
its own default access group. Do not add shared groups or fabricate a Team ID,
application-identifier or provisioning profile. The current Debug bundle is ad
hoc signed; inspection shows only `com.apple.security.get-task-allow`, with no
application identity/access-group entitlement. That build does not establish
production Keychain access or upgrade continuity. `errSecMissingEntitlement`
produces a distinct typed failure. Real signed-app tests must establish access
and upgrade behavior before the persistence feature is accepted for shipping.

## Item and query policy

| Property | Value |
| --- | --- |
| Class | Generic password |
| Backend | `kSecUseDataProtectionKeychain = true` on every query |
| Service | `io.github.jkeli.tidyvnc.credentials.v1` |
| Account | `NativeCredentialKey.account`, the versioned opaque identity digest |
| Synchronization | `kSecAttrSynchronizable = false` |
| Accessibility on create/replace | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Access group | App's default; no shared group supplied |
| Biometric/access-control requirement | None added |
| Label | Fixed `TidyVNC credential`; no endpoint or username |
| Secret size | At most 4096 bytes; empty password is representable |

The selected accessibility class is restricted to unlocked access and does not
migrate to a different device. See [Apple's accessibility constant documentation](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly).
Queries do not alter macOS privacy settings or Keychain access controls.

Each operation has a fresh LAContext, invalidated after the call. Background
operations default to `interactionNotAllowed = true`; `.allow` is an explicit
caller policy for user-initiated work. See [LAContext.interactionNotAllowed](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed).
No process-wide interaction switch, shared authentication context or automatic
retry loop is used. Permission to read a Keychain item does not establish trust
in a VNC server or authorize sending the credential.

## Operations and results

Lookup reads one exact account. Create reports Duplicate without replacing an
existing item; replace reports NotFound without adding an item. Neither performs
an upsert retry. Delete targets the exact class/service/account and reports its
actual result. Metadata reads request attributes only, never password data.
Listing requests at most the selected limit plus one (limit 1–256), returns a
bounded first page and signals `hasMore`; it does not promise a complete list
when truncated. Metadata exposes only the opaque key and creation/modification
dates. Unsupported/malformed accounts and unexpected secret-bearing metadata are
rejected, never repaired or deleted implicitly.

Results distinguish NotFound, Unavailable, Denied, InteractionRequired,
Cancelled, MissingEntitlement, Duplicate, Corrupt and numeric unknown failure.
Unavailable/InteractionRequired preserve the OS result without pretending that
it proves whether the device is locked, the store is absent or UI is required.
Backend exception text is replaced with a fixed failure category. No plaintext
file, defaults, profile or password-file fallback exists.

## Execution, cancellation and secrets

One store actor admits at most 16 operations to a serial utility queue. MainActor
never waits synchronously on SecItem. Cancellation before a queued backend
operation begins prevents that operation. Once backend execution starts, its
actual result is returned even if the caller cancels; a successful save is not
reported as rolled back. Do not assume an OS error proves that a mutation had no
effect: callers must reconcile metadata before retrying an uncertain outcome.

Close rejects admission, cancels queued work, shares one asynchronous drain task
and crosses the serial queue after results have drained. It waits for an already
running synchronous Keychain call. OS-prompt dismissal/quit behavior needs the
real packaged-app acceptance test; this implementation does not forcibly abort
Security framework calls or conceal their outcomes.

NativeCredentialSecret owns a locked mutable allocation, clears consumed input
arrays, and zeroes its own storage on clear/deinit using `memset_s`. Descriptions
are redacted; it is not Codable or observable. Explicit `copyBytes` returns a
caller-owned copy that the caller must clear after protocol submission. Clearing
cannot guarantee erasure of pre-existing Swift strings, COW, Foundation, framework
or OS copies. A successful save does not clear a caller's retained secret; that
lifetime belongs to the explicit use-once/session/remember policy.

## Authentication integration and remaining acceptance

AppCoordinator owns one store and closes it after window controllers drain.
NativeAuthenticationCredentials owns each window's private pending/retained secret.
The default is use once. Session retention survives unexpected connection loss for
an explicit Use Session Password action, scoped to the same canonical endpoint,
negotiated method and entered username. Manual cancel/disconnect, authentication
rejection and window close clear the owned value. A changed endpoint clears it
before a new attempt. No retained password is published or placed in profiles.

Remember/explicit replacement saves only after the matching generation reaches
Connected. A failure reports a separate notice without failing the live connection;
uncertain OS results are described as unconfirmed, not rolled back. Background
post-success save forbids interaction. Explicit Use Saved Password and Forget
allow OS interaction, one outstanding operation per window. A late lookup is
cleared without submission if its prompt/generation or controller epoch changed.
Once an OS mutation starts, close waits for its actual outcome. Full OS prompt
cancellation and uncertain-mutation reconciliation remain acceptance work.

Saved values are submitted only by an explicit action at the protocol's current
credential prompt, after preceding trust callbacks. Rejected values are not
retried or deleted automatically. Retaining an explicitly used saved value for
session reconnect is optional and does not rewrite it. Forget targets the exact
key; replacement is a separate checkbox and happens only after successful manual
authentication. Automatic trust-gated reuse and dedicated trust storage remain
separate unfinished work; this flow does not infer server trust from Keychain access.

Current tests inject a SecItem client and backing to verify exact query policy,
status mapping, malformed results, secret ownership, bounds, asynchronous execution
and cancellation/drain. Loopback authentication tests cover successful-only save,
reconnect retention, rejected saved values, nonfatal persistence failure, late
lookup and close during an active save. They do not access a real Keychain. N3.14/N6.9 must use
unique disposable entries in a properly packaged signed app to verify read,
create, replace, metadata, delete, unavailable/denied/interactive behavior and
upgrade access. Delete only those test entries and preserve the user's stores.
