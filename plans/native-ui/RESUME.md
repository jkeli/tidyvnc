# Native UI work handoff

Updated 2026-09-23. Read this first when resuming, then use [TODO.md](TODO.md)
for the full checklist and historical evidence. The objective remains the entire
[PLAN.md](PLAN.md); this checkpoint does not establish parity or release readiness.

## Committed checkpoint and next execution order

Implementation checkpoint: the commit that adds this section (`feat(macos): sound
server bells, route app copies through the pasteboard worker and run Apple
sanitizers`), on top of `c2a6057e`. See the two 2026-09-23 TODO evidence sections.
N1.5, N1.6, N1.13, N1.14 and N1.15 are now checked; N1.2, N1.3, N1.4, N1.9 and
N1.16 remain open.

1. N1.9 service contracts, from the recorded audit: add an access/permission
   service (Local Network guidance, Accessibility, security-scoped file access)
   with typed states and a fake; an app-services contract (lifecycle/quit, logging,
   help/URL resources) replacing the static launch hand-off; route remaining
   `NSScreen`/`NSApp.isActive`/`NSWorkspace` reads through the display/window
   contracts; add a document writer fake and a picker service; unify trust errors
   and stop dropping them with `try?`; add a test that builds the production
   `AppCoordinator` wiring (or extract it into a testable factory).
2. Finish the N1.2/N1.3/N1.4 audits: confirm every CAPABILITIES.md parameter's
   schema lives in portable core (not only Swift), document transactions, then close.
3. Map existing encoding/security, authentication/trust, clipboard, reverse/listen,
   tunnel and reconnect fixtures to PLAN §12 (N6.6). Extend actual-frontend coverage
   for uncovered paths, keeping wire assertions distinct from visible acceptance.
4. Resume actual app window/menu/file-panel, keyboard and VoiceOver acceptance
   through CUA when native access works (UI-ACCEPTANCE.md, PARITY.md), including
   an audible/visible bell check; then matched performance and physical 1×/2×,
   mixed-display, hotplug/Spaces/IME checks.
5. Verify minimum-OS/Intel dependencies, hosted CI (including the Linux sanitizer
   jobs), installed Finder/network-consent behavior and intended signing/Keychain
   upgrade access. Complete the full parity and requirement audit before changing
   the shipping frontend or declaring N6 done.

These are ordered follow-ups within the original plan, not replacement completion
criteria. The full goal remains active and FLTK remains the default.

## Latest follow-up (2026-09-23) — Apple sanitizers, server bell, pasteboard routing

The crypto-enabled core suite passes **762/762** under macOS ASan+UBSan and TSan
(three runs each). The native Swift suite passes all **89** cases under ASan and
TSan; the long settings-render case needed its limit raised from 40 to 120 s.
Limitations (uninstrumented frameworks/dependencies, disabled container-overflow
checks on macOS, no Darwin LSan, no MSan) are listed in TODO.

The N1.9 audit found that the native app never sounded server bells. It now does,
through an injected `NativeBellSounding` (`NSSound.beep()`), once per delivery turn
for the current attempt. "Copy Diagnostics" now goes through the clipboard
coordinator's serialized worker instead of writing `NSPasteboard.general` on the
main thread. N1.5/N1.13/N1.15 are closed with explicit maps; N1.9 stays open with
its gap list.

Final macOS Debug: **3/3 viewer, 762/762 unit, 89/89 native**
(`build/native-ui-frontend/verification/run-s8ryht58`), 140 Swift sources / 1353
localization call sites. Branding and diff checks pass. FLTK remains the default.

## Latest follow-up (2026-09-23) — Release revalidation, Linux resolver, sanitizers

Release at `8b56c793` passes **3/756/89** and the new packaged DMG passes mounted
inspection. Its packaged executable passes the full **55/55** protocol baseline
(`build/native-protocol-release-8b56c793`). DMG SHA-256
`ac238bdcee5e11972bc7ae014e79ae7e7d9b246e6674347d15ba4f86ce9be54a`; the explicit
27.0 floor remains a host-dependency floor.

N1.6 is now complete: glibc Linux resolves hostnames through `getaddrinfo_a` with
prompt cancellation/deadline abandonment. Running the portable suite for the first
time as Linux Debug (`-Werror`) under ASan+UBSan+LSan and TSan found and fixed an
upstream per-handshake GnuTLS description leak, three null-`memcpy` UB sites,
GCC-only warnings and a test allocator mismatch. All Linux configurations pass
**759/759** (TSan skips only three glibc resolver tests, documented in code). CI
jobs are defined; hosted execution is unverified.

The N1.4 global-state table is reconciled in STATE-AUDIT.md. GnuTLS global
lifetime is resolved under a `static_assert`ed ≥ 3.3 floor with a churn test.
Client key exchange fails closed without a system random source (verified with
`/dev` hidden). N1.14 is complete at the production runtime: a parked VncAuth
session and a live session keep prompt, secret, held modifier, clipboard and
encoding settings separate.

After all changes, macOS Debug passes **3/3 viewer, 762/762 unit, 89/89 native**
(`build/native-ui-frontend/verification/run-y01wnifx`). Retained FLTK passes
782/782 unit and 3/3 viewer. Both 55-case baselines pass again with the shared-code fixes (native Debug `build/native-protocol-shared-fixes`, FLTK `build/fltk-protocol-shared-fixes`, hashes matched). Branding and diff checks
pass. FLTK remains the default; the full goal stays active.

## Latest follow-up (2026-09-23) — Actual native protocol baseline and startup fix

The full retained **55-case** baseline now runs through the actual native app with
isolated Foundation paths, unique app/preference domains and a signed temporary
copy. All wire assertions remain: fragmented updates, framebuffer/cursor changes,
scaling suppression, explicit 123×97 size, measured automatic logical/device size
and bounded denial retries. Native peer-close/socket drain is checked separately
from fixture SIGTERM cleanup. It does not establish pixels/input, window dismissal
or interactive app Quit. See [PROTOCOL.md](PROTOCOL.md).

This exposed an actual startup defect: AppKit treated the endpoint operand as a
file and suppressed the scene that consumes the parsed invocation. The entry
point now disables that duplicate interpretation in the volatile argument domain
before SwiftUI starts, without persistent preference or argv changes. The
first-window/file-review fixtures now supply real process operands and use the
same handoff. Their simplified app did not independently reproduce the failure;
the actual-app timeout traces and passing full matrix are the before/after proof.
All temporary startup traces were removed.

An additive numeric-only viewport diagnostic uses the existing redacted debug
route; the C header now has **113 status-returning exports**. Pure-C boundary and
redaction/route checks pass. The ordinary preferences domain is unchanged, while
alternate bundle identities get separate domains. A Foundation probe verifies
HOME/Application Support before each fixture launch; cleanup accepts only exact
UUID-suffixed fixture domains. HOME alone did not isolate CFPreferences.

Final all-target Debug verification:
`build/native-ui-frontend/verification/run-1hqziv5q/summary.json` —
**3/3 viewer, 756/756 unit (21.70 s), 89/89 native (129.15 s)**, graph **170/3**,
**10** configure checks, **1052 + 2** bundled localized values, strict signature
and **36** actual CLI cases. Compiler coverage remains **139 sources / 1353 call
sites**. Focused logging plus pure-C ABI checks pass **11/11 ASan+UBSan** and
**11/11 TSan**; those existing builds disable crypto and retain uninstrumented
system/dependency libraries. This is not a full sanitizer-matrix claim.

Final reports `build/native-protocol-final/summary.json` and
`build/fltk-protocol-final/summary.json` both pass **55/55**, with hashes checked
against the tested executables. Native SHA-256:
`244ea6912a4b5309699fa43b9ece7976f0d071a81e15c61d93db20c40e3b86bf`.
Native measured/wire sizes are 960×525 logical and 1920×1050 device; both explicit
cases send 123×97 and scaled automatic cases send nothing. These dimensions are
observations of this run, not hardcoded acceptance values. The CI definition now
runs/preserves this baseline; hosted execution is still unverified. Workflow
YAML/shell parsing, branding **1650** and diff checks pass. All process handles
completed. This change has not rebuilt the earlier Release DMG.

N6.5's baseline subitem is complete; its broader protocol/sanitizer gate remains
open. Next: remaining contract/global-state audits and broader protocol evidence,
actual interaction/accessibility, physical/performance, supported minimum-OS/Intel,
installed services/signing, hosted CI and final parity/cutover. The full original
goal stays active; FLTK remains the shipping default.

## Latest follow-up (2026-09-22) — Clean Release validation

Started from a nonexistent `build/native-release-validation` directory and built
all core, app and test targets with `--configuration Release --test --package`.
The generated handoff and Xcode configuration are Release-only, arm64, SDK 27,
build deployment declaration 14.0. C++ uses `-O3` with the root's existing
`-UNDEBUG` assertion policy; Swift uses `-O`. The package explicitly declares
27.0 for the current Homebrew dependency floors. No production code changed.

The first full report (`run-85kkqfoe`) caught a clipboard-limit wire-fixture race:
an initial-frame publication could satisfy a generic frame-sequence wait before
the clipboard message was sent, leaving the fixture queue occupied. It reproduced
immediately in isolation. The test now checks the exact pixel marker following
each clipboard message, including messages that must be discarded, rather than
any newer frame. Existing admission, boundary, retention, reconnect and isolation
assertions remain. The corrected test passes **30 Release + 30 Debug** repetitions.

The final complete pipeline passes in
`build/native-release-validation/verification/run-mu47vmxj/summary.json`:
**3/3 viewer, 756/756 unit (21.87 s), 89/89 native (124.63 s)**, graph **170/3**,
**10** configure rejection checks, **1052 UI + 2 metadata** localized values,
strict signature and **36** CLI cases. Compiler audit remains **139 sources /
1353 call sites**. No sanitizer rerun is claimed for this fixture-only change.

Release artifact:
`build/native-release-validation/package/Release/TidyVNC-1.16.80-arm64.dmg`, SHA-256
`31684912587385f21ce9eeb21a5c7a376aed0cba241f805926d656151e9fdf6b`.
The mounted read-only image passes all **36** CLI cases plus identity/resources/
notices, closed dependency graph, symbol and strict signature checks. It contains
**13 signed binaries / 11 bundled dylibs** and is detached after inspection.
The adjacent `package-report.json` preserves hashes and minimums. All process
handles completed; branding **1650** and diff checks pass.

The CUA access check still could not inspect the actual app; see UI-ACCEPTANCE.md.
No interactive acceptance is inferred. The 55-case protocol harness still has
FLTK-specific log and process-lifetime assertions and needs a native adapter
before it can establish native baseline coverage. Next: that full native protocol
baseline, supported minimum-OS/Intel dependency packages and intended signing /
installed behavior, plus all remaining service/interaction/physical/performance
and parity gates. The complete original goal stays active; FLTK stays the default.

## Latest follow-up (2026-09-22) — Relocatable native app and DMG

The native build now has `native-package`/`dmg` targets and `build.py --package`.
One packager recursively copies non-system dylibs, rewrites their load paths,
removes runpaths, checks architecture/deployment floors and preserves dependency
notices. It signs nested binaries before the app seal, audits closure, executes
help from a moved path with spaces and atomically publishes a fresh output.
The reusable inspector checks the actual read-only mounted image and detaches it.
See [PACKAGING.md](PACKAGING.md) for commands, supported scope and limits.

The current Homebrew libraries correctly fail a 14.0 package declaration: nettle
requires macOS 27. Local inspection packages explicitly declare **27.0**, preserving
the original Xcode app's 14.0 declaration and leaving the supported-floor decision
open. This is a dependency portability improvement, not minimum-OS acceptance.
The package contains **13 signed binaries / 11 bundled dylibs**, upstream notices,
resources and an Applications link. No production identity or notarization is used.

Direct `dmg` target and the complete `build.py --test --package` pipeline pass.
Final verification `build/native-ui-frontend/verification/run-mi4r1bps/summary.json`
passes **3/3 viewer, 756/756 unit (21.93 s), 89/89 native (129.43 s)**, graph checks
**170/3**, **10** configure rejection cases, **1052 + 2** packaged localization
values, strict signature and **36** CLI cases. Compiler coverage stays
**139 sources / 1353 call sites**. The new native CTest contains **13** package
policy/failure regressions. Workflow YAML/shell parsing, branding **1650** and diff
checks pass. No sanitizer rerun is claimed for this packaging change.

Final artifact: `build/native-package-pipeline/TidyVNC-1.16.80-arm64.dmg`, SHA-256
`5ce0805d95e166cd644e9df280eca4fde584782fc253e5faa10e75fb9447fc4b`.
`package-report.json` in the same directory records hashes, dependency edges,
minimums and signing mode. The final mounted image passes binary/resource/notice/
identity/signature/symbol checks plus all **36** real CLI cases, then detaches.
No temporary packaging stage remains. All process handles completed.

Native CI now defines host-floor package assembly and mounted-image inspection;
its execution remains unverified. Next: clean Release and supported dependency/
minimum-OS/Intel packages, intended signing identity and installed privacy/Keychain,
plus every remaining interaction, protocol, physical/performance and parity gate.
N6.2's local assembly subitem is complete; parent/distribution acceptance stays
open. The complete original goal remains active. FLTK stays the shipping default.

## Latest follow-up (2026-09-22) — Scoped failure alert policy

`AlertOnFatalError` now has a native adapter, defaults on, and is captured in an
immutable launch/session value. Eligible outgoing errors still offer Retry when
ReconnectOnError is on. With alerts off, fatal/non-retry connection and listener
failures request joined owner cleanup, then the app coordinator closes that
window. Reverse failure preserves the accepting listener; unrelated sessions and
the macOS application remain open, including after the last window closes. This
native lifetime adaptation is documented in CLI help; actual window acceptance
remains open. Cancellation, editable validation and credential/trust decisions
retain their existing behavior. See [CONNECTION.md](CONNECTION.md).

Every CLI occurrence is validated; the last valid value wins. Compatibility-file
fields cannot override it and still require ignored-field review. Export review
now explicitly acknowledges that failure-alert policy is omitted. Two localized
messages bring coverage to **139 sources / 1353 call sites / 1052 UI keys**, plus
**2 InfoPlist** entries. The new export-review fixture images were inspected.

The all-target build and first full verification passed (`run-u2u4a5tm`). Review
then added a missing-preferences listener startup case and an explicit initializer
policy check; the final incremental build and full verification passed in
`build/native-ui-frontend/verification/run-bl32lpk7/summary.json`: **3/3 viewer,
756/756 unit (21.50 s), 88/88 native (117.29 s)**, graph checks **168/3**, **10**
configure rejection cases, **1052 + 2** packaged values, strict development
signature and **36** actual executable CLI cases. Real socket fixtures cover all
four alert/retry combinations, healthy-session isolation, cancelled authentication,
bind failure, pre-session failure and reverse-peer loss. The first focused run
caught a fixture missing the required ignored-file-field acknowledgment; correcting
that fixture preserved the production review gate. No sanitizer rerun is claimed.

N4.11 implementation evidence is updated; actual window/keyboard/VoiceOver,
physical/protocol/performance, installed services, minimum-OS/Intel, hosted CI and
distribution gates remain open. The complete original goal remains active and
FLTK remains the shipping default. All build/test handles completed.

## Latest follow-up (2026-09-22) — Parity and compiled capability inventory

[PARITY.md](PARITY.md) now maps **162** control/action/launch rows to retained
sources, native replacements, registered fixture evidence and concrete remaining
acceptance actions. It covers all 16 rows of PLAN §9, including eight scaling
modes, settings inheritance, prompts, menus/shortcuts, files/imports and native
additions. [CAPABILITIES.md](CAPABILITIES.md) records all **47** canonical parameters,
three aliases, built-in defaults, validation bounds and live/next-attempt policy.
N0.1/N0.2 inventory deliverables are complete; parity acceptance remains open.

A temporary probe linked to the current built libraries confirms 5 available
encodings (H.264 unavailable), 15 available security methods and their exact
default allow-list. Native help agrees with all 47 catalog names; retained FLTK
help accounts for 43 available canonical names plus three aliases. Actual native
launches with AlertOnFatalError=on and =off both reject the missing adapter before
UI startup. This is the next concrete implementation gap. Retained code proves
ReconnectOnError can still prompt with AlertOnFatalError off; preserve that
precedence while keeping native multi-window failures scoped.

Inventory review records native empty CA/CRL and stable-display selection defaults,
SSH customization restrictions and explicit own-store imports; documentation alone
does not accept these differences. It also corrects stale CLI prose claiming the
tunnel adapter was absent. All document links, test references, 162 unique IDs,
coverage ranges, 47 parameter rows and both help catalogs were checked; branding
baseline **1650** and diff checks pass. No production code changed or full suite
rerun. The prior **3/756/88** result remains the latest full build evidence.

Next: implement AlertOnFatalError with retry/fatal/reverse/startup distinctions and
multi-window tests, then continue remaining service/lifecycle, native interaction,
protocol/physical/performance, CI, distribution and installed acceptance gates.
The complete original goal remains active. FLTK remains the shipping default.
All probe processes ended; no actual user-app UI/credential/store action occurred.

## Latest follow-up (2026-09-22) — Automated native verification and SSH exit recovery

`apps/macos/build.py --test --parallel 2` now builds every target and requires
complete, fresh CTest inventories/JUnit for viewer, unit and native suites, then
checks frontend graphs/configuration failures, bundle localization/signature and
the real CLI. Reports preserve failures/skips and cannot reuse an older run's XML.
The five-job native CI definition retains existing FLTK/headless workflows, saves
host/toolchain/dependency details and development artifacts. Hosted execution is
not yet verified; N6.4 remains open. See [BUILD.md](BUILD.md).

The first complete runs exposed an intermittent real SSH exit race: Darwin may
post NOTE_EXIT before waitid can observe the child. The owned process now schedules
one bounded-delay retry at a time after that notification, preserving pinned
PID/group identity, joined cleanup and exactly-once completion. A deterministic
regression fails on the old implementation and passes with the fix. Lifecycle and
real ECDSA checks each pass 20 repetitions; targeted lifecycle checks also pass
under ASan and TSan. See [TUNNELS.md](TUNNELS.md).

A subsequent rebuild exposed the localization check's incorrect mtime assumption:
Swift keeps unchanged localization records. Successful target builds now record
source/record content hashes; the audit requires matching receipts plus complete
records/catalog coverage. All 16 checker regressions pass. See [LOCALIZATION.md](LOCALIZATION.md).

Final all-target build and verification pass in
`build/native-ui-frontend/verification/run-yhdlyz2o/summary.json`: **3/3 viewer,
756/756 unit (21.81 s), 88/88 native (129.47 s)**, graphs **168/3** with no FLTK,
**10** configure rejection cases, **1050 UI + 2 metadata** bundle entries, strict
signature and **32** CLI cases. Compiler audit covers **139 sources / 1351 sites**.
Verifier regressions pass **9/9**; workflow YAML/shell parsing, branding baseline
**1650** and diff checks pass. All process handles completed.

Earlier failed reports are retained: `run-g6r34__1` caught duplicate pretty-name
handling in the verifier; `run-f_dttci7` correctly caught the SSH failure. Neither
is the final green result. The later mtime-gate failure stopped before verification.
No hosted CI, Intel/minimum-OS, full sanitizer matrix, actual UI/VoiceOver, physical
input/display, installed privacy/Keychain or distribution acceptance is claimed.
Development dependencies still require macOS 26/27; the 14.0 floor is provisional.
Next: exhaustive parity/capability inventory, remaining service/lifecycle gaps,
distribution packaging and every unchecked acceptance gate. The complete original
plan stays active and FLTK remains the shipping default.

## Latest follow-up (2026-09-22) — Explicit frontend build selection

`TIDYVNC_UI=FLTK|SWIFTUI` now selects the application; FLTK remains the default.
SwiftUI requires Apple/full Xcode/Swift 6, Ninja, Debug or Release and one
architecture. `BUILD_VIEWER=OFF` and independent bridge-only builds remain valid.
The root viewer/macapp targets and convenience script share one core → Xcode
build, with generated dependency/configuration metadata and early rejection of
app/core SDK, architecture or deployment mismatch. FLTK-only tests/benchmark and
dependency discovery are excluded from native/core-only graphs. See [BUILD.md](BUILD.md).
N6.1 and N6.3 are complete; N6.2's full test/package workflow remains open.

Clean `build/native-ui-frontend` Debug app succeeds, including the compiler
localization audit (**139 sources / 1351 sites / 1050 UI keys**). Direct root
`macapp` and smoke targets pass. Generated graphs contain **168 core / 3 app**
targets with no FLTK source/compile/link inputs. Five frontend policy groups,
ten actual configure rejection checks and three viewer CTests pass. The failure
fixtures caught SDK diagnostic ordering, fixed by checking the handoff before
compiler probes. Clean headless build/audit passes **3/3** viewer and **756/756**
unit tests (21.43 s). Retained FLTK viewer/benchmark/surface/state targets build;
the affected **19/19** tests pass (0.32 s). Bundle localization (**1050 + 2**),
strict signature and **32** CLI cases pass.

The native suite remains **87** registered tests; no full native/sanitizer run
or Windows/Linux build is claimed here. macOS 14 and Intel execution are unproven;
the development Homebrew dependencies still report macOS 26/27 floors. No CUA or
user-app action was attempted. Next: finish the exhaustive parity/capability
inventory and remaining service/lifecycle gaps, native CI/test/package automation,
and every unchecked interactive/physical/installed/performance/release gate.
The full original objective remains active, with FLTK still the shipping default.

Logs use `/tmp/tidyvnc-frontend-`: app, root-target, root-final, headless, fltk,
fltk-tests, graph, smoke, configurations-verified, terminal-final, bundle-final and
branding-final. The earlier
configuration logs record fixture/diagnostic failures superseded by the verified
run. The branding check found a pre-existing unlisted absolute checkout path in
UI-ACCEPTANCE.md; it is now expressed relative to the repository, preserving the
observation without adding a branding exception. All process handles completed.

## Latest follow-up (2026-09-22) — Encoding reset names

Dynamic label tracing found that encoding reset buttons exposed raw schema tokens
such as NoJPEG and LowColorLevel in their accessibility names. Reset help and
accessibility names now reuse the corresponding localized visible control label
(e.g. Allow JPEG and Reduced colors), with stable per-option accessibility IDs.
The reset callback still receives the same typed option; no schema/policy change.

App build and compiler audit pass **139 sources / 1351 call sites / 1050 UI keys**.
The separate **2 InfoPlist entries**, packaged fallback/interpolation checks, strict
signature, **32** terminal cases, branding baseline **1650** and diff checks pass.
Existing profile inheritance, encoding isolation and settings rendering regressions
pass **3/3 (35.78 s)**. Expanded settings/profile rendering passes. No full-suite
or sanitizer rerun; the native suite still contains **87** registered tests.

An experimental in-process SwiftUI accessibility fixture returned no children from
NSHostingView, with a hidden or presented off-desktop test window. Its first build
also needed NSAccessibilityProtocol (the Swift protocol name). The experiment did
not verify labels or press actions and was removed from the shipped test suite;
source/logs remain in /tmp for diagnosis. This is a fixture limitation, not evidence
that the actual app's accessibility tree is empty. No CUA/user-app action occurred.
Next: continue dynamic presentation provenance and actual keyboard/VoiceOver/menu/
panel acceptance, plus every unchecked parity/core/services/physical/installed/
deployment/CI/performance/release gate. N4.16/N4.17 stay open. All handles completed.

## Latest follow-up (2026-09-22) — Compiler-checked localization coverage

The standard native app build now emits Swift localization records for the core
module and app, then audits them against the catalog using CMake's actual source
lists. The final build passes **139 Swift sources, 1350 localization call sites,
1050 UI keys**, with matching English defaults and typed interpolation formats.
Every source must have a current compiler record. Missing keys, stale records,
unknown tables/formats and orphaned catalog entries fail the build. The separate
**2 InfoPlist entries** retain their existing runtime packaging checks.

The audit found one unused catalog entry and implicit translation keys for brand,
protocol labels, the listener port placeholder and numeric monitor labels. The
unused entry was removed; technical labels now use explicit verbatim text, and
monitor numbers are locale-formatted. Empty field titles have no translatable
content; the audited fields have separate accessibility labels. The gate does not
prove arbitrary dynamic text provenance, layout or interactive accessibility.

All **13** checker failure/coverage tests pass. Integrated audit plus affected
settings/listener/fullscreen CTests pass **4/4 (38.59 s)**. App build/signature,
**1050 + 2** packaged values/fallback/interpolation, **32** terminal cases, branding
baseline **1650** and diff checks pass. The registered native suite now contains
**87** tests; no fresh full suite or sanitizer run is claimed. The preceding full
86/86 result remains from the structured-recovery checkpoint.

No CUA request was repeated in this follow-up; the most recent actual-app selection
failed at the native pipe (UI-ACCEPTANCE.md). Next: finish dynamic presentation
provenance and keyboard/VoiceOver/window/menu/panel acceptance, plus every unchecked
parity/core/services/physical/installed/deployment/CI/performance/release gate.
N4.16/N4.17 remain open. All recorded process handles completed.

## Latest follow-up (2026-09-22) — Bundle and trust identity localization

The native app now compiles **2 InfoPlist entries** for Local Network purpose and
its document-type display name, separately from **1051 Localizable entries**.
The release template remains authoritative for bundle identity, registration and
English metadata. Packaging checks verify both tables, system privacy lookup,
English fallback, literal interpolation and unchanged identity/attribution/document
registration. Actual Finder and Local Network permission presentation remain open.

Legacy trust identities now retain typed SPKI/commitment values; matching and
deduplication are independent of translated text. Their expected-identity messages
and saved certificate/server-key messages use complete localized sentences. Three
entries replace two fragment templates; serialized trust bytes and scope do not
change. Expanded legacy-policy tests pass, including mixed/duplicate identities.
Five affected trust/store/rendering tests pass **5/5 (33.92 s)**. Expanded settings/
trust renders pass; SPKI/commitment and both library screenshots were inspected.
App build/signature, **1051 + 2** packaged values, **32** terminal cases, branding
baseline **1650** and diff checks pass. No fresh full suite or sanitizers were run;
the preceding full suite remains **86/86 (116.31 s)** at the prior checkpoint.

A fresh full-path CUA app selection again fails with “native pipe closed before
response.” No follow-up UI action was sent; no app/version/draft conclusion follows.
See UI-ACCEPTANCE.md. Next: finish the dynamic presentation/call-site coverage audit
and keyboard/VoiceOver/window/menu/panel acceptance when available, plus every
unchecked core/parity/physical/installed/deployment/CI/performance/release gate.
N4.16 is still open. See LOCALIZATION.md for the raw-literal classification and
remaining audit limits. All recorded process handles completed.

## Latest follow-up (2026-09-22) — Structured presentation recovery

Startup, renderer/cursor, canvas/layout, input/shortcuts and fullscreen failures now
select fixed localized recovery from typed errors and operation context. Arbitrary
error descriptions, NSError userInfo and remote/path/credential text are never
formatted by this mapping. Keyboard-capture denial is a typed Swift error that
retains Accessibility guidance. Existing cancellation/lifetime guards and the C ABI
are unchanged. The old fullscreen diagnostic-interpolation template was removed;
14 new recovery entries bring the source catalog to **1050**.

The new fixture injects private renderer/cursor errors and invalid canvas intent,
checks UI redaction, alert coalescing, later-frame recovery, pointer fallback,
geometry preservation and joined teardown. Existing fullscreen tests now inject a
foreign window error and prove redacted rollback while rethrowing the original
error. A manual capture-denial check verifies its typed failure and guidance.
Focused checks pass **9/9 (5.13 s)**; expanded recovery/fullscreen fixtures pass.
The full run found an SSH identity-sheet overflow; details now scroll inside a
460×570 sheet with fixed title/actions. Expanded/mirrored light/dark fixtures check
actual bounds and scroll reachability, with representative images inspected.
All native executables were rebuilt and the corrected full suite passes **86/86 (116.31 s)**.
App build/signature, **1050** packaged values/fallback/interpolation, **32** terminal
cases, branding **1650** and diff checks pass. Sanitizers were not rerun.

A fresh CUA selection of the repository app still reports “native pipe closed before
response”; no subsequent UI action was sent and no crash/version/draft conclusion
follows. See UI-ACCEPTANCE.md. Actual app/VoiceOver/installed/physical/deployment/CI/
performance/release gates remain open. Next: native bundle privacy/document-type
localization review, remaining user-presentation audit and the entire unchecked
plan. Internal errors and compatibility data are not blanket-translated.

## Latest follow-up (2026-09-22) — CLI and Keychain presentation localization

The catalog now has **1037** English source entries. Native command-line syntax
failures, initialization/launch-credential errors, version/help prose and option
annotations are localized. Command names, grammar examples, aliases, defaults,
paths and environment variable names remain literal arguments. Argument numbering
reuses the complete localized diagnostic template. Keychain access reasons and
new-item display labels are localized; account/service identity and existing-item
labels are not rewritten.

Five focused syntax/bootstrap/credential/Keychain tests pass **5/5 (1.60 s)**.
Expanded bootstrap and Keychain policy fixtures pass, including literal command
syntax, scoped queries, interaction policy and new-record label assertions. The
final app's English help (**3711 bytes**) and version (**108 bytes**) match the
pre-change app byte for byte with identical exit statuses and untouched isolated
HOME/XDG. Build/signature, **1037** packaged values/fallback/interpolation, **32**
terminal cases, branding baseline **1650** and diff checks pass.

The audit still finds raw error presentation in app startup, desktop rendering,
cursor/input/canvas and fullscreen failure detail paths. Map these to structured,
localized recovery without exposing arbitrary diagnostics. Native bundle privacy/
document-type descriptions from release/Info.plist.in also need localization review.
Protocol headers, stored trust commitments and caught internal errors need use-based
classification, not blanket translation. N4.16 and all actual-app/VoiceOver/physical/
installed/deployment/CI/performance/release gates remain open. No full-suite/sanitizer,
real Keychain prompt or CUA/user-app acceptance is claimed. All handles completed.

## Latest follow-up (2026-09-22) — Controller and service recovery localization

The catalog now has **1009** English source entries. Fixed connection-controller,
SSH tunnel, clipboard, fullscreen/automatic-resize and desktop keyboard/scaling
recovery text now uses stable IDs. Desktop accessibility label/help/focus actions
are localized too. The fullscreen failure sentence has a literal diagnostic
argument. Typed errors, OpenSSH parsing/argv, credentials, clipboard routing, focus,
selectors and persisted/protocol values are unchanged.

Focused normal checks pass **11/11 (60.41 s)**. Expanded native menu/accessibility
routing, clipboard recovery and fullscreen transition fixtures pass after replacing
English-only test lookups with localized expected labels. Existing wire, redaction,
input isolation, lifetime and cleanup assertions remain. App build/signature,
**1009** packaged values/fallback/interpolation, **32** terminal cases, branding
baseline **1650** and diff checks pass. No full-suite/sanitizer or actual-user-app/
VoiceOver/physical/installed-app/deployment/release acceptance is inferred.

The remaining source audit identifies native launch/CLI text and Keychain access
reason text. Classify other raw literals before migration: protocol file headers,
persisted trust commitments, identity labels and caught internal diagnostics are
not interchangeable with UI text. Also audit generic diagnostic presentation paths
and finish actual window/menu/file-panel accessibility. N4.16 remains open, as do
all unchecked parity, physical, CI, performance, deployment and release gates.
All process handles completed; no CUA/user-app action was attempted. See TODO logs.

## Latest follow-up (2026-09-22) — App and connection localization

The catalog now has **973** English source entries. App menus, native context menus,
window/panel titles, connection controls and state labels, information/statistics
and fixed app recovery text use stable IDs. Clipboard/profile provenance, dimensions
and speed use complete templates with literal arguments and formatted display
numbers. Protocol names/versions, remote values, diagnostics, shortcuts and action
identities retain their existing meaning. Remaining controller/gateway/status
errors still need coverage; this does not complete N4.16.

ConnectionContent is now a separate source shared by the app and rendering fixture.
The fixture uses private in-memory stores and a loopback peer, with first-use,
gateway, idle and connected captures at exactly 640×420. Information uses 560×650;
statistics use a constrained width and intrinsic height in a 320×300 host. Measuring
unconstrained ideal sizes previously let the host resize itself, so the new helper
checks proposed and actual bounds and rejects wholly blank captures. Idle guidance
has a compact fallback and white text against the black desktop. Expanded and
mirrored light/dark checks pass. An incomplete image preview was complete when the
same PNG was read again; no AppKit drawing workaround is retained.

Focused panning/settings/fullscreen checks pass **3/3 (30.16 s)** before the final
placeholder adjustment; the final settings rerun passes **1/1 (33.57 s)**. Expanded
fullscreen statistics also pass their input/geometry/lifetime assertions. Final
app build/signature, **973** packaged values/fallback/interpolation, **32** terminal
cases, branding baseline **1650** and diff checks pass. No full-suite/sanitizer,
actual-user-app, VoiceOver, installed-app or deployment-floor acceptance follows.
Newer dependency deployment warnings remain. No CUA/user-app action was attempted.

Continue controlled controller/gateway/status localization and actual window/menu/
file-panel accessibility acceptance, then the entire unchecked parity, physical,
installed-app, CI, performance, deployment and release plan. Evidence is in TODO.

## Latest follow-up (2026-09-22) — Defaults-import localization

The catalog now has **851** English source entries. Defaults-import source choice,
category/omission review, mapping, consent, progress, results, first-use offer and
fixed storage/source recovery messages use stable IDs. Omission rows take literal
field names and localized line/notice arguments; display rows reuse the shared
complete file-monitor sentence. Import filtering, precedence, source bytes, stored
identities and consent policies are unchanged.

Source explanations and mapping details scroll while recovery/actions remain
visible. Pickers have separate wrapping labels and explicit accessibility names;
Refresh Displays has its own row. The first-use offer puts actions below its text.
Fixtures retain the 640×572 content minimum and add success, missing-source,
existing-state, mapping-error and end-of-review captures, plus light/dark first-use
renders at 592 points wide. These do not prove combined connection-window layout,
RTL, VoiceOver or actual-user-app interaction.

Five focused import/projection/history/source/consent tests pass **5/5 (5.41 s)**.
Expanded import and mapping fixtures pass. A mapping control capture showed a
transition artifact; increasing fixture settling to 250 ms yielded a clear final
capture, with no production change for that artifact. Final app build/signature,
**851** packaged values/fallback/interpolation, **32** terminal cases, branding
baseline **1650** and diff checks pass. Full-suite/sanitizers were not rerun;
newer dependency deployment warnings remain. No CUA/user-app action was attempted.

Continue app menus/connection/status, file panels and remaining controlled
controller/gateway diagnostic localization and integrated window acceptance.
The full unchecked parity, accessibility, physical, installed-app, deployment,
CI, performance and release requirements remain in scope. Evidence is in TODO.

## Latest follow-up (2026-09-22) — Connection-file review/export localization

The catalog now has **796** English source entries. Connection-file review,
file/inherited/direct command-line display mapping, export mapping/loss review,
save status, reader/writer/codec diagnostics and shared invocation-resolution
errors use stable IDs. File and command-line monitor labels are separate complete
sentences; display names, field names, addresses and filenames remain literal
arguments. Display/line numbers use localized presentation while serialized
monitor numbers, protocol fields and entered port/monitor syntax remain unchanged.

Review and mapping views put their details in one scroller with actions outside.
Display pickers have persistent wrapping labels and matching accessibility names.
Listener preparation now hosts those bounded views directly, retaining 660×472
content minimums and visible review actions. Outbound mapping/review fixtures fit
640×420; export mapping/loss review retains the 560×600 sheet. Expanded light/dark
captures include review scrolling, errors, sparse monitor numbers and listener
file review. These fixtures do not implement RTL and do not prove VoiceOver or
actual-user-app acceptance.

Seven of eight initial document/listener tests passed; the new scroll assertion
incorrectly required ordinary English content to overflow. Inspection showed all
content visible. After making scrolling conditional on overflow, document mapping
passes **1/1 (2.10 s)**. Invocation precedence/recovery passes **2/2 (0.46 s)**.
All three expanded document/export/listener fixtures pass. Final capture review
found a mapping error below the fold; errors/unavailable-display guidance now stay
above the action buttons. Corrected expanded captures pass, including no connected
displays, and final document/listener tests pass **2/2 (4.09 s)**. Final app build/signature,
**796** packaged values/fallback/interpolation, **32** terminal cases, branding
baseline **1650** and diff checks pass. No full-suite/sanitizer rerun; newer
macOS dependency warnings remain. No CUA/user-app action was attempted.

Continue defaults-import, app menus/connection/status and file panels, and other
controlled controller/gateway error localization. All unchecked parity, actual
window/accessibility, physical, installed-app, deployment, CI, performance and
release requirements remain in scope. Exact evidence is in TODO.

## Latest follow-up (2026-09-22) — Listener localization and scrolling

The catalog now has **683** English source entries. Listener headings, actions,
status, preparation notices and fixed model recovery errors use stable IDs.
Protocol names, addresses and numeric port syntax stay literal; port/family
sentences use reorderable arguments. Shared document-review/mapping views and
errors originating in their controllers still need localization.

The listener keeps network/start/stop controls above one scrolling details area.
Peer actions have their own row, and controls can stack when a horizontal row
cannot fit. The TCP port field has an explicit localized accessibility name.
The content minimum remains 660×472. Ordinary and expanded fixtures cover idle,
incoming, stopped, invalid-port, missing-family, bind-error and file-review states.
A scrolling assertion and dark capture show both peers' actions and the complete
policy notice reachable at the minimum size. Synthetic expansion is not a shipping
translation or RTL/VoiceOver/actual-user-app acceptance.

Final listener UI/model CTest passes **1/1 (1.75 s)**, as does the expanded fixture.
The final app build, strict deep signature, **683** packaged values/fallback/
interpolation, **32** terminal cases, branding baseline **1650** and diff checks
pass. Loopback handoff/authentication, file consent, credential consumption and
shutdown assertions remain in the fixture. Protocol and persistence policy are
unchanged. Full-suite/sanitizers were not rerun; deployment warnings remain.
No CUA/user-app action was attempted. Exact evidence paths are in TODO.

Continue document/defaults-import, app menus/connection/status and controlled
controller/gateway error localization, plus actual window/accessibility acceptance.
The entire unchecked parity, physical, installed-app, deployment, CI, performance
and release plan remains in scope.

## Latest follow-up (2026-09-22) — Hosted window minimums

Fresh regressions reproduced the history-import sizing bug in defaults import and
listener windows: both reported a zero content minimum after their hosting views
finished layout. Defaults import now propagates a 640×572 content floor; listener
normal/preparation views propagate 660×472. `NSHostingController.sizingOptions`
uses `.minSize`, replacing the ineffective manual window minimum. The listener
also renders an explicit native window background. The accepted reverse-connection
host uses the same policy with ConnectionRoot’s existing 640×420 content floor.
The startup listener relies on its shared view floor instead of a second manual
minimum. Reverse/startup real-app interaction is not yet accepted.

Defaults import choices/review/errors/mapping and listener idle/incoming/stopped/
file-review fixtures now assert stable minima and render at those minima. All three
focused tests pass (4.26 s); the final listener/background rerun passes (1.30 s).
Minimum defaults-mapping and listener light/dark captures were inspected. These
are isolated fixtures, not physical-network, VoiceOver or installed-app evidence.

Final app build, strict deep signature, **645** packaged catalog values/fallback/
interpolation, **32** terminal cases, branding baseline **1650** and diff checks
pass. No strings, protocols, storage schemas or persistence policies changed.
Full-suite/sanitizers were not rerun. Exact logs and initial failing assertions are
in TODO. No CUA/user-app action was attempted.

Continue remaining app menu/connection/status/listener and document/defaults-import
localization, controlled controller/gateway errors, and actual window/accessibility
acceptance. All other unchecked parity, physical, installed-app, deployment, CI,
performance and release requirements remain in scope.

## Latest follow-up (2026-09-22) — Profiles, history and import localization

The catalog now has **645** English source entries. Profile/history presentation,
storage recovery, endpoint validation, history import source/review/result text,
fixed import diagnostics and relevant source-access errors use stable IDs. Gateway,
address and line-number messages take literal arguments; import count wording also
works for a single entry. Retained data and protocol values are unchanged.

Profile fields have persistent labels; recovery/delete and editor actions use
separate rows. Recent history actions stack to avoid crowding. Minimum-size tests
exposed a profile view preferring 940×680 even in a 900×640 host, and an import
window whose manually assigned minimum was reset by AppKit to zero content size.
Profile content now fits 900×640 while the scene retains a 940×680 default. Import
uses hosted min-size propagation from a 640×572 content floor; source explanation
scrolls and review/confirmation remains visible. Expanded and ordinary minimum-size
checks now pass. Screenshots show visible viewport content only.

Four focused profile/history/import tests pass (2.50 s). Final ordinary settings
and import presentation pass (26.16 s); expanded settings, mirrored minimum-size
profiles/history, and expanded import source/review/conflict/result fixtures pass.
The final app build/signature, **645** catalog values/fallback/interpolation,
**32** terminal cases and branding baseline **1650** pass. Exact logs are in TODO.
No full-suite/sanitizer, actual-user-profile, VoiceOver, installed-app or release
acceptance is inferred. No new CUA action was attempted; its last pipe failure
remains documented in UI-ACCEPTANCE.md.

Next: remaining app menus/connection/status/listener UI, document/defaults-import
flows and fixed controller/gateway errors. Other hosting controllers using empty
sizing options need their explicit minimums checked too; do not assume they retain
them. Continue the entire unchecked plan, including parity, physical displays/input,
deployment, installed-app, CI, performance and release gates.

## Latest follow-up (2026-09-22) — Fullscreen and remote-resize localization

The catalog now has **534** English source entries. Fullscreen defaults/session
selection, remote-resize defaults/policy/request sheets, display descriptions,
fixed draft errors and server results use stable IDs with English defaults. Profile
inheritance labels for the migrated settings groups are covered too. Display names,
formatted dimensions and server result codes are literal interpolated arguments;
stored mode IDs, numeric input syntax, request and persistence behavior are unchanged.

Inherited selections use wrapping effective-value captions. Long blank-size guidance
is visible above the field. Fullscreen/resize sheets bound their scroll content,
keep recovery/actions visible and give the resize-source picker a full-width row.
Display lists use their enclosing sheet scroller so multiline rows are not cut by
single-line height estimates. Mirrored rendering exposed physical display maps
being reversed; their coordinate diagrams now remain left-to-right while controls
follow the interface direction. Synthetic screenshots are separate from actual
multi-monitor, VoiceOver and interactive scrolling acceptance.

The final app and focused targets build; four fullscreen/resize model tests pass
(9.09 s). Final ordinary/expanded/mirrored rendering, compiled catalog, signatures,
terminal and branding evidence is in the latest TODO entry. No full-suite or
sanitizer rerun for presentation-only changes. A fresh CUA getApp still reports a
closed native pipe; no app crash or new interactive acceptance is established.

Continue remaining menu/connection/profile/document/history/listener/status
localization and fixed controller errors, followed by the complete unchecked plan.
All parity, accessibility, physical, installed-app, deployment, CI and release gates
remain in scope. The prior 85-test suite remains historical evidence, not a claim
that all remaining acceptance is complete.

## Latest follow-up (2026-09-22) — Input, scaling and security localization

The catalog now has **460** English source entries. Input, scaling, connection
options, security methods/TLS priority and certificate-file fields, including
connection-local sheets and fixed model errors, use stable catalog IDs. Reset
labels now use typed source information rather than comparing translated English;
input accessibility identifiers are independent of display text. Stored values,
protocol behavior and persistence schemas are unchanged.

Expanded screenshots exposed scaling Form columns overflowing the sheet, inherited
picker labels truncating, compressed certificate paths and oversized sheet content.
Scaling uses vertically arranged full-width controls; inherited effective values
wrap below pickers. Certificate paths occupy their own row, modifier controls use
a two-column grid, and input/scaling/security sheets bound their scroll content
while preserving recovery/actions. Final expanded and ordinary rendering passes;
representative visible content was inspected. These are synthetic layout checks,
not complete interactive scrolling, VoiceOver or shipping-language acceptance.

The final app build, strict deep signature, **460** packaged values with fallback/
literal-interpolation checks, **32** terminal cases, branding baseline **1650** and
diff checks pass. Five focused input/scaling/profile/security/connection tests pass
(1.60 s), configured certificate-file inheritance passes (0.17 s), and the final
ordinary renderer passes (26.61 s). No full-suite or sanitizer rerun was needed for
these presentation changes. Exact logs and mirrored render evidence are in TODO.

Next localization: fullscreen/display selection, explicit/automatic remote resize,
then remaining menus, connection/profile/document/history/listener/status UI and
fixed errors. The earlier CUA New Profile pipe failure remains unresolved; no new
actual-app interaction is claimed. All unchecked parity, accessibility, physical,
installed-app, deployment, CI and release gates remain in scope.

## Latest follow-up (2026-09-22) — Settings localization and visible UI checks

Implementation commits: `86d36a54` (compatible Help state wrappers) and
`a72fd6ee` (Settings localization and expanded control layouts).

The catalog has **304** English source entries. Settings headings, clipboard
controls, defaults diagnostics, encoding controls/source labels and live encoding
recovery are localized. Literal option/value interpolation is checked in the
packaged bundle. Trust-library destination guidance now wraps above its field
with an explicit accessibility name. Expanded trust save/replace actions use a
complete wrapping label plus Review Decision when a native button would truncate;
the existing confirmation and safe default remain intact.

Settings field content scrolls within a bounded window; expanded recovery messages
and Apply/Cancel remain visible. Restore actions can move to a separate row, live
encoding reload has its own row, and input-default labels sit above full-width
pickers. The expansion runner supports prefix selection and mirrored `--rtl`
fixtures. Representative expanded light/dark and mirrored trust/library/encoding/
Settings conflict PNGs were inspected. This is synthetic layout evidence, not a
shipping translation or full VoiceOver/interactive Settings acceptance.

The app's Help state explicitly uses the macOS 14 property wrapper, matching
AuthenticationSheet, rather than resolving the newer SDK State macro. CUA access
recovered long enough to quit/relaunch the app, open Help and switch all three
topics, inspect About identity/credits, and dismiss with Command-W/Escape. The
profile shortcut opens its empty library; New Profile again closed the connector's
native pipe. The app remained alive (PID 53970 at that observation, 0% CPU).
No Save or credential/trust action was invoked. The running process predates the
final layout rebuild and may contain an unsaved draft. See UI-ACCEPTANCE.md.

Validation and exact logs are in the latest TODO evidence. The prior full 85-test
suite and sanitizers were not rerun for these presentation changes. No ABI,
storage schema, protocol, credential or trust-policy change. All remaining plan
items stay in scope, including physical/installed/deployment/CI/release gates.

## Committed checkpoint (2026-09-22)

The accumulated implementation is committed by purpose at the user's request:

- `8aed5265`: serialize pasteboard fixtures and render color checks in sRGB.
- `a1bd4414`: supported SSH configuration snapshots, native askpass/host-key
  review, joined process/diagnostic cleanup and effective-route credential/trust
  isolation, including storage migration and app integration.
- `0507ab9b`: Help/About resources, 228 English source localization entries,
  complete interpolated trust/status messages and expanded authentication controls.

Planning, CLI/SSH policy, UI acceptance and localization documentation are
committed separately. No publication or release is implied. The entire PLAN
remains active; no incomplete acceptance gate has been checked off for this commit.

Fresh checkpoint validation: the complete normal native build passes and the full
native CTest suite passes **85/85 (130.78 s)**, including isolated OpenSSH tests.
Strict deep app and helper signatures pass; 32 executable terminal cases, all 228
compiled catalog values plus fallback/interpolation, branding baseline 1650 and
diff checks pass. This full-suite result supersedes older partial/full-suite
observations below. Evidence: `/tmp/tidyvnc-commit-{native-build,native-tests,
terminal,localization,branding}.log`. The app was already rebuilt from the same
implementation in the preceding slice. All recorded build/test handles completed.
Sanitizers were not rerun for this commit checkpoint; previous SSH sanitizer
results and their TLS-disabled limitations remain historical evidence only.

## Implementation evidence (2026-09-22)

Credential/password-file notices, saved-trust errors and the trust library add
60 localization entries (228 total). Fixed diagnostics and saved fingerprints use
whole sentences with literal arguments. App build, packaged lookup/fallback/
interpolation, strict deep signature, 32 terminal cases, branding and diff pass.
Eight focused storage/credential/trust/rendering tests pass (40.42 s).

New tests/macos/localization-expansion.py creates a temporary test bundle with
padded authentication/credential/trust/action strings, preserving placeholder
count. The first expanded run passed geometry tests but screenshots showed
truncated password retention and saved-password controls. AuthenticationSheet now
puts the retention label above a full-width picker and stacks saved-password
actions. Final app build and ordinary renderer pass (36.92 s), final expanded
renderer exits 0, and light/dark remembered-password captures show full labels.
The expanded trust-library screenshot still shows a truncated destination
placeholder: next replace placeholder-only guidance with a visible wrapping label
and retain an explicit accessibility label. Other expanded trust screens also
need visual review; passing fitting-size checks alone is insufficient.

Evidence: `/tmp/tidyvnc-storage-localization-*`,
`/tmp/tidyvnc-settings-expanded-final.log`, `/tmp/tidyvnc-settings-expanded-renders/`.
All process handles are terminal. A fresh CUA getApp still reports native pipe
closed, so no actual app/VoiceOver acceptance is claimed. The overall plan and
remaining localization, physical, installed-app and release gates stay open.

Authentication/trust localization adds 96 entries (168 total). AuthenticationSheet,
SSHAuthenticationSheet, TrustDetailsView, credential-protection guidance and native
certificate/key presentation now use stable IDs with English defaults. Destination
confirmations and expected/received fingerprints use whole localized sentences
with literal interpolated arguments. No trust/credential/protocol behavior changed.
RSA key bits use a UInt32-compatible placeholder. The interpolation test initially
expected ungrouped digits; it now checks locale-aware formatting (2,048 here).

Final app and focused builds pass. Settings rendering, credential retention,
certificate policy/presentation and SSH askpass interaction pass 4/4 (39.16 s).
All 168 packaged values, missing-key/untranslated-language defaults and typed
interpolation pass; strict deep signature, branding baseline 1650 and diff pass.
Representative authentication/SSH light/dark English screenshots were inspected.
Evidence: `/tmp/tidyvnc-auth-localization-*`; all process handles are terminal.
No sanitizer, real-SSH or full-suite rerun was required for this presentation-only
slice. Expanded authentication/trust layouts, RTL/VoiceOver/interactive acceptance,
credential-store and saved-trust notices and other UI localization remain open.
The current SDK/dependency build is not minimum-OS acceptance.

The catalog now contains 72 English source entries: 46 connection diagnostics,
25 Help strings and the explicit About action. Help menu/window titles, guide,
topics, links and loading/error text use stable IDs with defaults. A doubled-string
offscreen fixture exposed horizontal overflow from the segmented topic picker;
ViewThatFits now uses a menu when segments do not fit. Corrected minimum/default
light/dark captures and normal English minimum-size capture were inspected.
Final app build, 72 packaged lookups, missing-key/untranslated-language fallback,
strict deep signature, branding and diff checks pass. All build/render processes
completed. Logs: `/tmp/tidyvnc-help-localization-*`; expanded captures:
`/tmp/tidyvnc-help-expanded-renders/`. This is synthetic layout evidence, not
shipping translations or interactive/VoiceOver/RTL acceptance. Continue the
remaining native controls/prompts/settings localization and full checklist.

Native localization now has an English source catalog compiled by Xcode and an
explicit English development region. NativeConnectionIssue's 46 titles/messages
use stable IDs with redacted English default values. Actual bundled lookups,
untranslated French-locale fallback and missing-key defaults pass; strict deep
signature and the focused ErrorsAndRetry CTest pass. No gettext catalog or
translator attribution changed. See LOCALIZATION.md and the repeatable
tests/macos/localization-bundle.swift packaging check. Other native strings and
long-string layout coverage remain unfinished. Evidence prefix:
`/tmp/tidyvnc-localization-`. App and focused test builds are terminal success.

Native Help and About credits are now implemented (N4.15 remains open for actual
UI/accessibility acceptance). The Help menu opens a dedicated SwiftUI window with
connection guidance, project/support links, and asynchronously loaded bundled
README/licence text. Credits.rtf supplies the standard About panel's upstream
attribution. The app build, strict deep signature and 32 terminal cases pass;
all three packaged documents match their source bytes and the RTF parses.
Offscreen guide renders at 560×440 and 720×640 in light/dark wrap correctly. An
initial intrinsic-fitting-size assertion was unsuitable for scrollable text;
actual constrained screenshots were inspected instead. This is not interactive
Help or About acceptance. CUA getApp still fails with native pipe closed, so the
running older app has not been relaunched or its new Help controls exercised.
Evidence: `/tmp/tidyvnc-native-help-final-build.log`,
`/tmp/tidyvnc-native-help-terminal.log`, `/tmp/tidyvnc-help-renders/`.
All build/render processes are terminal. Continue localization and the complete
remaining checklist while interactive UI access is unavailable.

The latest slice reports OpenSSH's initial known-hosts write failures before VNC
admission. NativeTunnelOutput has a stderr mode that keeps only a fixed classifier
state, never raw diagnostic text; large streams drain in constant space. The master
pins LogLevel=INFO / LogVerbose=none. Readiness drains pending stderr before creating
the forward, and error cleanup preserves the specific save error when authentication
ends early. Close/deinit join the shared diagnostic drain; cancellation is preserved.

Fixtures cover stderr-only classification, every marker split, no raw retention,
large output, configured QUIET/LogVerbose overrides, and failed saves with both
successful and ended authentication for Ed25519/RSA/ECDSA. Normal 8/8 passes (26.03 s).
ASan initially passed 7/8, with the new controller trust fixture failing because that
build omits GnuTLS. Scope-only tests now explicitly use public fixture SPKI only on
unsupported extraction; normal builds still extract the real DER key. Corrected
normal controller 2/2 passes (4.26 s), ASan affected case 1/1 (2.93 s), and TSan full
SSH suite 8/8 (51.74 s). Do not claim TLS-codec sanitizer coverage from that fixture.

A noisy-process regression from initially capping diagnostic volume was corrected
by constant-space discard. The expanded intentional-auth-failure sequence also hit
sshd source penalties; only the private fixture disables them after probing -T for
support, preserving older sshd compatibility. System SSH configuration is untouched.
Final app build, strict app/helper signatures, 32 terminal cases, branding baseline
1650 and diff checks pass. All build/test handles completed. Exact logs are at the
end of TODO.md. Full 85-test suite was not repeated.

Native UI access failed again: Saved Profiles opened empty, but New Profile caused
cua_repl to report its native pipe closed. Re-read and reset/rebind failed. The app
remained alive (PID 17988, vncviewer, sleeping at 0% CPU); no app crash was established.
No Save action was invoked; the resulting unsaved draft is unverified. The CUA binding
is now undefined after reset. The running native process predates the latest build;
quit/relaunch through CUA when inspection recovers. See UI-ACCEPTANCE.md. Do not use
other UI-automation technologies to work around the connector restriction.

Next: configured preparation cancellation/deallocation coverage, native/installed
SSH save-failure interaction and remaining native screens/keyboard/VoiceOver work.
Further key formats, TLS-enabled sanitizer acceptance, deployment-floor behavior,
installed Keychain, physical displays and release gates remain open. The whole PLAN
remains active. No ABI/storage schema change. Save-failure detection observes SSH's
reported initial write result, not a separate durability or file-integrity guarantee.

Previous slice: real configured-route password/trust-scope controller tests passed,
and native screenshots exposed then verified the corrected two-row connection
header at 640 points. That layout remains built; the profile connector failure above
does not invalidate those earlier observations, but later screens remain unverified.

The preceding slice wires configured SSH into the app:

Configured SSH is integrated with ConnectionModel. NativeConfiguredSSHTunnel
owns default-config preparation, cancellation and cleanup. ConnectionTunnelAttempt
awaits the effective route before credential/trust binding and requires forwarding
to return that same route. Requested aliases remain editable/saved destinations.
Launch credentials now bind separately to requested intent (including inherited vs
explicit :22) and the first effective route; a changed resolution destroys them.
UI and terminal help describe the admitted config subset and its restrictions.

Controller fixtures cover configured aliases through real SSH/RFB with launch
credentials, fresh reconnect after explicit secret-clearing Disconnect, rejected
config on retry, and cancellation/close before SSH starts. Credential fixtures
cover unchanged requested intent with changed effective routes and port intent.
Normal full suite: 84/85 passed in 129.04 s; the sole failure was a new test's invalid
bare host:22 syntax. After fixing it to ssh://host:22, all four affected launch and
controller cases passed (3.69 s). No production failure remained; full 85 was not
repeated after the fixture correction. ASan 10/10 (24.63 s), TSan 10/10 (50.59 s).
Final app build, strict app/helper signatures, 32 terminal cases, branding and diff
checks pass. All build/test handles completed. Exact logs and the initial fixture
failures/cleanup are recorded at TODO.md's end.

At that checkpoint, the next work was resolved-route credential/trust acceptance
and preparation cancellation/deallocation, followed by host-key save-failure and
native/installed interactions. The route-scope and initial native UI progress above
supersede that next-step ordering. Do not infer that controller fixtures satisfy native UI,
physical display, installed Keychain, deployment or release gates. The entire
PLAN remains active. C ABI 112, defaults schema 11 and profile/history schema 12
are unchanged. SSH-CONFIGURATION.md describes current admission boundaries.

The previous slice added prepareDefault, captured address-family policy, absent
config handling and configured interactive/helper acceptance. Normal 8/8 (19.91 s),
ASan 8/8 (23.08 s), TSan 8/8 (44.56 s), app/signatures/32 terminal cases passed.

The preceding slice wires prepared gateways into an internal NativeSSHTunnel initializer.
Launch pins effective host/user/port/explicit key alias, preserves the requested
alias for config selection, escapes percent bytes in HostName, and disables further
canonicalization. An owned cancellable preflight compares typed route plus an
opaque digest of non-owned effective settings before launching the master. Changed
Match policy rejects; Match localnetwork is rejected during snapshot admission.
Askpass observes the prepared key lookup identity. Close/deinit join preflight,
master/control children and prompts before releasing snapshot files.

Tests now reach RFB through actual configured SSH aliases with default and explicit
HostKeyAlias, original-source mutation after preparation, startup close and dropped
owners. Normal 8/8 (15.17 s), ASan 8/8 (17.19 s), TSan 8/8 (37.12 s). App build,
strict app/helper signatures, 32 terminal cases, branding and diff checks pass.
All recorded processes completed. An initial extended fixture timeout was traced
to reusing a one-shot VNC peer; fixed with fresh peers. Its verified orphaned SSH
master and two private directories were explicitly cleaned; no configured acceptance
snapshot directories remain. Full 85-test suite was not repeated for this slice.

Next: absent-default-config preparation, explicit network policy in initial
resolution, configured interactive/helper acceptance, then ConnectionModel attempt
publication and credential/trust/launch-secret/retry binding before RFB. Public app
factory still uses -F /dev/null; configuration remains correctly disclosed as
unsupported until integration is complete. Read SSH-CONFIGURATION.md for the
master-policy boundary and unsupported dynamic matching. C ABI 112, defaults schema
11 and profile/history schema 12 remain unchanged. Exact evidence is at TODO's end.

The preceding slice adds typed resolved gateway/key identity and an owned preparation.
NativeSSHResolvedGateway validates hostname/user/port and optional hostkeyalias,
computes the exact key lookup name and an ssh-v2 digest over the effective route.
NativeSSHPreparedGateway retains the requested alias, immutable admitted snapshot
and typed result; resolution failure joins snapshot cleanup. Explicit user/port
invocation values override config while an inherited port is omitted from probe argv.
These APIs remain internal and are not wired into app admission or master launch.

Focused tunnel tests pass 8/8 (14.59 s), covering real OpenSSH alias/precedence,
scoped IPv6, key aliases, immutable re-probing, changed source resolutions,
credential/trust namespace separation and failed-resolution cleanup. App build,
strict bundle/helper signatures, 32 terminal cases, branding and diff checks pass.
All recorded processes completed. Full 85-test and sanitizer suites were not
repeated for this internal preparation slice; the preceding full run is below.
Exact evidence is at the end of TODO.md.

Next: enforce prepared host/user/port/key lookup and effective policy in the owned
master (including canonicalization/Match re-evaluation and default alias/certificate
semantics), handle absent default config, and connect askpass observation to the
prepared key identity. Then publish the immutable attempt and bind credentials/
trust atomically before RFB, including launch-secret/retry rules. Read
SSH-CONFIGURATION.md; do not just swap route digests while retaining a re-evaluated
master route. Config support is still honestly disclosed as unsupported in the app.

The preceding slice adds explicit/inherited SSH port intent and profile/history
schema 12. NativeSSHGateway canonical URIs omit an inherited port; portIsExplicit
retains the distinction. New Codable values are closed version-2 {version,uri}
objects. Historical strings (including hand-authored omitted ports) decode to a
concrete 22, preserving old behavior. Schema 11 remains read-only until an explicit
mutation upgrades the full record. Defaults schema stays 11; C ABI stays 112.
History preserves explicit/inherited destinations separately, and recent/profile
editing carries that distinction through the canonical URI.

Full normal native suite passes 85/85 (120.76 s), including old profile/history
migration, strict new gateway validation and all model/import/invocation/tunnel
consumers. App build, strict bundle/helper signature verification and 32 terminal cases
pass; branding and diff checks pass. All recorded build/test handles completed.
Sanitizers were not repeated for this immutable value/storage follow-up; the
preceding snapshot's sanitizer evidence remains scoped to that checkpoint.
Exact logs are at the end of TODO.md.

Next: typed effective host-key lookup/route identity, owned snapshot/probe
preparation, then atomic ConnectionModel credential/trust binding before RFB.
The current launcher and legacy route digest still use concrete port 22;
persisted intent does not enable configuration support by itself. Do not replace
-F /dev/null or use requested alias identity for a resolved connection.

The preceding slice finished the next snapshot ownership/admission checks. Private
files receive exact 0600 permissions; directory setup works with umask 0777 and
cleanup preserves a replacement directory while unlinking owned files through its
original descriptor. Include tokenization preserves literal hashes inside a word
and does not normalize non-ASCII whitespace into directive syntax. Actual OpenSSH
comparisons cover unquoted/single/double-quoted hash paths and trailing comments.
Additional fixtures cover ACL rejection, exact/aggregate byte and file-count
limits, prepared-construction failure and restrictive umask in a separate process.

Final normal/ASan/TSan tunnel runs pass 8/8 (14.01/15.53/36.71 s). The initial new
umask test failed and drove the directory-setup fix; its corrected focused run
passed 1/1. The earlier transient concurrent ASan probe failure remains documented
at the end of TODO.md; these final runs did not reproduce it. All normal/sanitizer and app build/test handles completed. App build, strict
bundle/helper signatures, 32 terminal cases and branding checks pass. Full 85-test
suite was not repeated for this internal snapshot follow-up; exact evidence is
at the end of TODO.md.

Remaining integration: resolved host-key/route identity and ConnectionModel
preparation before credential/trust binding and RFB admission. Existing stored gateway strings must
retain their explicit :22 meaning; do not reinterpret them as configuration port
inheritance. Snapshot/probe internals remain unwired to the app. Current Include
limits reject escapes, percent/environment/named-user tilde expansion and final
symlink files. Keep those limitations explicit. The entire plan remains open;
consult SSH-CONFIGURATION.md before enabling app admission.

The preceding follow-up adds the owned configuration-probe prerequisite:
NativeTunnelOutput provides bounded single-use stdout with cancellation/drain;
NativeSSHConfigurationProbe returns a validated effective hostname/user/port from
`ssh -G -F /dev/null`. It does not admit user configuration or change app routing.
Read [SSH-CONFIGURATION.md](SSH-CONFIGURATION.md) before enabling configuration:
immutable snapshots, explicit/inherited port intent, resolved route/host-key
identities and credential/trust admission still need integration.

Final focused tests: 8/8 normal, ASan and TSan; app build, strict bundle/helper
signatures and 32/32 terminal cases pass. All recorded processes completed. The
85/85 full-suite result below predates only this internal probe follow-up; the
full suite was not repeated. Exact evidence is at the end of TODO.md.

The preceding follow-up adds bound SSH gateway-key review on top of the native
askpass transport. A fixed KnownHostsCommand helper observes the actual offered
key without supplying trusted entries. NativeSSHHostKey validates gateway/type/blob
and computes SHA-256. Matching new-key confirmation presents a separate native
review; Trust and Save returns the exact fingerprint for OpenSSH to verify and
save. Cancel is the default. Changed and revoked keys remain rejected by SSH.
New-key review currently supports plain Ed25519/RSA/NIST ECDSA. Unsupported new-key
formats fail closed; existing trusted keys/certificates still use SSH verification.
`-F /dev/null` remains: supported user SSH configuration is the next major gap.

The helper/interaction/sheet implementation from the preceding checkpoint remains:
private bounded Unix-socket IPC, per-connection cancellation and joined cleanup,
use-once SSH responses separate from VNC credentials, and signed bundle packaging.
The isolated daemon now verifies independent fingerprints, cancelled approval,
exact saved key, reconnect, changed/revoked rejection and a helper path containing
spaces, quotes, percent and dollar characters. RSA and ECDSA variants bring the
native suite to 85 tests. Light/dark host-key sheets fit and were inspected.
Final checks: 85/85 normal native tests, 8/8 tunnel tests under ASan and TSan,
strict signed app/helper verification and 32/32 terminal cases. The bundled helper
also passed the real SSH fixture. All recorded processes completed. Exact evidence
for this follow-up is at the end of TODO.md. The prior
83/81-test checkpoints below predate gateway-key review.

Next: supported SSH configuration policy, further password/MFA and actual app
prompt/close/quit acceptance, known-host save-failure reporting, remaining key-format
and IPv6/scoped-host acceptance, then the full-plan inventory/hardware/installed/
deployment/release gates. Do not reimplement basic askpass or common new-key review.
A permission hint alone is still not a host-key decision; structured key observation
and fingerprint binding are required. No C ABI/store schema change (112/11).

This checkpoint supersedes the older next-step text below. Changes are currently
uncommitted; inspect status/diff before continuing. Dedicated ConnectionModel
lifecycle coverage and the initial CLI `via` adapter are now implemented. The new
NativeTunnelControllerTests fixture exercises actual child forwarding, startup and
committed-connect cancellation, remote/child exit, cleanup admission gating, fresh
reconnect, repeated close, dropped presentation, routed credential isolation,
CLI/file launch-password scope, export omission and final-file Unix-target rejection.
A separate CTest exercises the app controller against an isolated OpenSSH daemon.

`NativeInvocationRequest.gateway` validates gateway occurrences, explicit empty
routing and final targets. `NativeSessionDefaults.sshGateway` publishes the selected
route before its session so ConnectionModel binds launch credentials correctly.
The executable rejects an active gateway with VNC_VIA_CMD before further startup;
listen/gateway and Unix/gateway combinations cannot allocate sessions or tunnels.
Help describes missing interactive authentication, new-host-key and SSH configuration
support. No C ABI or persisted schema changed (112 exports; schemas remain 11).

A clean build exposed missing top-level visibility of Threads::Threads without
GoogleTest. CMake now discovers the production dependency in the top-level scope.
The full native run also found monitor-profile-dependent color fixture failures
and a half-point overflow in the settings conflict form. Color fixtures now choose
sRGB before drawing and preserve logical bitmap size; recovery UI groups Reload
with its error. Both color checks and the full settings-render test pass focused
checks. Light/dark conflict captures were inspected.

Next: finish SSH configuration support and authentication/trust acceptance, actual
route-aware app/trust interactions and the remaining complete-plan inventory,
physical-device, installed, performance and release gates. Do not repeat the old
instruction to add basic controller tests or reject CLI `via` as unsupported.
The final regression also exposed a clipboard fixture sharing one NSPasteboard
between MainActor and its worker. Simulated local writes and reads now use the
same worker through an internal injection initializer; production async clipboard
behavior stays intact. Final checks: 81/81 normal native tests (109.31 s), 7/7 ASan (7.38 s),
7/7 TSan (23.29 s), ten consecutive normal clipboard runs, successful app build,
strict deep signature and 32/32 terminal cases. All recorded builds/tests completed.
Validation details are at the end of TODO.md.

## Current state

- `1ba1fe0e`: accumulated native app, portable session services, C/Swift bridge,
  settings, credentials/trust, documents/imports and numeric CLI listening.
- `26fd7022`: previous planning handoff.
- `0d80192e`: a subsequent clipboard/UI-thread fix found on resume; preserved.
- `00f39b26`: reviewed file-listener planning checkpoint committed at user request.
- `20698e2c`: SSH service/credential planning checkpoint committed at user request.
- `7d80856b`: reviewed connection-file listening, immutable prepared settings,
  listener UI and regression coverage.
- `0913db13`: routed local sockets preserve logical server identity through the
  C ABI and Swift session bridge.
- `9cabf307`: owned SSH master/control processes, validated gateway values,
  route-scoped credentials and isolated child/OpenSSH fixtures.
- `9fcaa879`: profile/history schema 11, export omission review and initial app
  gateway integration.
  Inspect Git history/status before editing; preserve other contributors' changes.

The interrupted app integration now has ConnectionTunnelAttempt ownership,
route-scoped trust/credential admission, gateway fields in connection/profile UI,
complete recent-connection selection, and current-route export capture. The
previous temporary routed-profile rejection has been removed. Dedicated controller tests now cover startup/admission cancellation,
remote/child death, cleanup ordering, reconnect and close. CLI `via` now has a
noninteractive adapter; see the latest working-tree checkpoint above. SSH authentication acceptance, new host-key review,
SSH configuration support and installed/deployment acceptance remain open.

Native `-listen [port]` and File > Listen for Connections already worked. The new
path is `vncviewer -listen ./connection.tidyvnc`. It classifies files versus sockets,
reads files through the bounded reader, applies defaults → CLI → file precedence,
and shows review/display mapping before any bind or session allocation. File
ServerName is a checked decimal 0–65535 port; empty/absent means 5500 and zero is
ephemeral. Invalid duplicate occurrences fail. Unix socket listeners remain
unsupported. This checked policy differs from retained digit-prefix `atoi` and
nonnumeric-default handling; full CLI parity is not claimed.

Approval retains NativePreparedSessionDefaults: configuration plus inherited,
document and invocation metadata. Incoming windows consume the exact reviewed
value without rereading preferences or files. Mapping retains the listener-port
interpretation; stale reviews and changed display topology cannot bind. Selected
reviewed display IDs must still be connected at explicit peer acceptance. Reconnect
those displays, or close/reopen the file to review a different selection; ordinary
session/fullscreen topology handling applies after admission.

The listener's captured credential owner still transfers to only its first
successfully opened incoming window. Cancel review, Stop or close clears unclaimed
inputs; reload and later incoming peers never recapture them. Reverse windows keep
history, Keychain, durable trust, document export and outbound retry disabled.
See [LISTEN.md](LISTEN.md), [CLI.md](CLI.md), and
[CREDENTIAL-INPUTS.md](CREDENTIAL-INPUTS.md).

The earlier four-file prototype was removed before `1ba1fe0e`; it is historical.
The new implementation now does contain NativeListenPort, NativeDocumentEndpointUse,
monitor-mapping endpointUse, and listenSocketUnsupported. Do not follow the older
handoff's statement that these APIs are absent or restore listenFileUnsupported.

## Files and ownership to preserve

- `platform/macos/Storage/NativePreferencesModels.swift`: NativeSessionDefaultsPurpose
  distinguishes ordinary session creation from listener preparation. Its approved
  snapshot bypasses store/file reads on incoming-session creation. Metadata is
  published before the session. Existing ordinary document behavior stays intact.
- `platform/macos/Settings/NativeDocumentResolution.swift`: listener-specific
  per-occurrence ServerName validation and typed listenPort; ordinary endpoints
  keep their existing meaning. The persisted file catalog is unchanged.
- `NativeDocumentMonitorMapping.swift` in that directory: endpointUse survives
  mapping, re-edit and topology recovery.
- `NativeInvocationBootstrap.swift` / `NativeInvocationResolution.swift`: typed
  listen launch, file/socket classification, checked numeric ports and help/errors.
- `apps/macos/TidyVNC/ListenerModel.swift`: prepare once, approve before bind, retain
  snapshot, check displays before Accept, transfer credentials once, drain on close.
  Only a display service created by this model is stopped by it.
- `ListenerView.swift` / `DocumentReviewView.swift`: file review, recovery and
  listening presentation. The listener UI test target now includes both document
  review and monitor-mapping view sources.
- `ConnectionModel.swift`: ReverseConnectionRequest carries the approved snapshot;
  NativeSessionDefaults installs it before reverse handoff.
- `TidyVNCApp.swift`: the startup listener receives preferences and the shared
  display service. Startup/quit/window ownership otherwise uses the existing path.
- `tests/macos/NativeListenerUITests.swift`: file precedence, no pre-review bind or
  session, sparse mapping/re-edit, topology changes, stale approval, two peers with
  closed preferences/changed source, cancellation during IO/review, and port errors.

## Validation for this follow-up

Normal native/app builds passed. Full normal native suite: **77/77 (87.91 s)**.
Six affected document/invocation/listener tests: **6/6 ASan (3.80 s)** and
**6/6 TSan (17.20 s)**. Strict deep app signature verification and **29/29** actual
executable terminal cases passed. Branding/attribution checks passed with 1650
unchanged deferred occurrences. See the latest TODO evidence for visual scope.
No C ABI or persisted schema changed; the existing 111 C exports remain.

That count describes the file-listener follow-up. The subsequent tunnel transport
boundary adds ROUTED_CONNECT and one C export (112 total), preserving existing ABI
structs and persisted schemas. Normal/ASan/TSan each passed the 15 socket connector
tests, pure-C ABI consumer and Swift bridge loopback test. Native/app builds,
signature verification and 29 terminal cases passed. The full native regression
rerun passed **77/77 (88.49 s)**, logged in
`/tmp/tidyvnc-routed-connect-native-tests.log`. All build/test/preview processes
from this follow-up completed; none was left running.

The later SSH service adds two native tests (79 total). The full normal run had
**78/79 pass (90.99 s)**; only the isolated SSH harness failed because CMake's
Python lacked os.waitid. The harness was corrected without changing production
code, and that test passed on rerun. After the final temporary-control-socket
cleanup fix, both tunnel tests passed **2/2 normal (2.21 s), 2/2 ASan (2.21 s),
2/2 TSan (6.41 s)**, including actual OpenSSH authentication/RFB forwarding (no
skips). The full 79-test run was not repeated after that focused cleanup change.
Logs: `/tmp/tidyvnc-ssh-service-*`.

Route-aware credential follow-up: retention and both launch-credential tests passed
**3/3 normal (1.37 s), 3/3 ASan (1.55 s), 3/3 TSan (7.68 s)**. The app rebuilt,
passed strict deep signature verification and **29/29** executable terminal cases.
No further ABI or schema change (112 C exports). All recorded builds, tests,
private children and isolated daemon fixtures completed. Latest credential evidence:
`/tmp/tidyvnc-tunnel-credentials-*`. At that checkpoint the complete native suite
had not been rerun after the credential API change; the final run below now covers
that outstanding regression check as well.

Latest route-storage follow-up: final normal native suite **79/79 (87.73 s)**,
focused **7/7 ASan (5.86 s)** and **7/7 TSan (21.52 s)**, including actual isolated
OpenSSH/RFB with no skips. The first full run had two stale schema-10 assertions;
both were corrected to schema 11 and passed, then the final full suite passed after
UTF-8 identity and canonical-URI-bound fixes. The app rebuilt, strict deep signature
verification and **29/29** isolated executable terminal checks passed. Branding
(1650 unchanged deferred occurrences) and whitespace checks passed. Evidence:
`/tmp/tidyvnc-route-storage-final-*`. All recorded build/test/fixture processes
completed. Defaults schema stays 11 and C ABI stays 112 exports; profile/history
schema is now 11. These results precede the interrupted app integration; see the
2026-09-22 checkpoint below for current validation.

### 2026-09-22 commit checkpoint

The implementation changes above are committed by purpose at the user's request.
The initial app integration now compiles after capturing the submitted profile
value explicitly in the sendable save closure. Both normal native and app builds
passed. The full native suite passed **79/79 (96.50 s)**, including the process and
isolated OpenSSH fixtures. Strict deep app signature verification, **29/29**
isolated executable terminal cases, branding and whitespace checks passed.
Evidence: `/tmp/tidyvnc-commit-check-{build,app,tests,terminal,branding}.log`.
All recorded build/test processes completed; no fixture was left running.

ASan/TSan were not rerun for this checkpoint. Earlier sanitizer results cover the
service/storage work before the interrupted controller changes; they do not verify
the new app lifecycle. The next work is the dedicated ConnectionModel tunnel
lifecycle coverage described below, followed by CLI/file routing. N3.18/N4.11 and
the full plan remain open. Planning and resume changes are committed separately.

Evidence prefix: `/tmp/tidyvnc-file-listen-`. Temporary logs/images can disappear;
rerun checks when needed. The test fixture uses memory preferences and private peers.
Its `--file-preview` mode displays review and can transition to a live listener:
create `/tmp/tidyvnc-file-listen-preview-accept` to approve, and
`/tmp/tidyvnc-file-listen-preview-stop` to close. It also exits after 120 seconds.
Remove those two fixture control files before another preview. The normal tests do
not use them. Do not confuse a fixture screenshot with full installed-app acceptance.

## Next steps

1. Continue stable-ID localization for remaining settings fields (input, scaling,
   security, fullscreen and resize), then connection/menu, document/profile/history,
   listener and status UI. Remove presentation-string comparisons in
   InputDefaultsFields/ScalingDefaultsFields before localizing the app-default
   inheritance labels; use typed intent for reset actions. Preserve shared option
   values, gettext attribution and English defaults. See LOCALIZATION.md.
2. Inspect expanded/RTL layouts for each newly migrated surface. The runner accepts
   `--prefix` and `--rtl`; geometry assertions miss native-control truncation.
   Synthetic mirrored English does not establish translated-language acceptance.
3. When CUA native access recovers, relaunch the final built app and resume
   profiles, interactive Settings/scrolling, SSH authentication/save-failure/trust,
   keyboard/VoiceOver and close/quit checks. Help topic loads/About presentation now
   have actual app evidence. New Profile reproduced the native pipe closure; no
   app crash or lock was established. Do not bypass CUA with other UI automation.
4. Continue the entire unchecked parity inventory and option coverage, physical
   keyboard/fullscreen/Spaces/multidisplay, installed Finder/LAN/privacy/Keychain,
   performance, minimum-OS/architecture, CI, signing and release gates. The current
   dependencies are newer than the declared deployment floor. These priorities
   do not narrow the numbered checklist; N4.15/N4.16 and release remain open.

## Commands and environment

From the repository root:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools cmake --build build/native-ui-swift -j 4
ctest --test-dir build/native-ui-swift/tests/macos --output-on-failure --no-tests=error
python3 apps/macos/build.py
codesign --verify --deep --strict build/native-app/app/Debug/TidyVNC.app
python3 tests/macos/invocation-terminal.py --app build/native-app/app/Debug/TidyVNC.app
python3 tests/rebrand/audit.py
git diff --check
```

Focused native test names are in `tests/macos/CMakeLists.txt`; the document prefix
is **NativeDocuments**, plural. For shared preparation changes, rebuild affected
executables in `build/native-ui-swift-asan` and `build/native-ui-swift-tsan` before
running their matching CTests. Unit and pure-C tests live under each build's
`tests/unit` and `tests/viewer`. App builds use the Xcode developer directory chosen
by `apps/macos/build.py`; normal CMake Swift builds above use Command Line Tools.

Evidence is arm64 macOS 27, provisional deployment target 14, dependencies built
for newer OS versions, and crypto-disabled sanitizer builds. It does not establish
older-OS, Intel or Linux runtime support. Revalidate recorded process handles before
starting duplicates; observation delay alone does not mean a process stopped.
Never build concurrently in one directory or edit compiled Swift sources while its
build runs. AppKit/socket/build checks have needed sandbox escalation; no approval
rejection blocked this work. The user said the Mac was unlocked. Slow tools or
AXError.cannotComplete are not evidence of a lock.
