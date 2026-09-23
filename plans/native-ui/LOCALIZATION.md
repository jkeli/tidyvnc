# Native localization

The native app's source language is English. `apps/macos/Localizable.xcstrings`
is compiled by the Xcode resource build into the app's localization resources;
`CFBundleDevelopmentRegion` is explicitly `en`.

Structured connection diagnostics use stable `connection.issue.<category>.<field>`
keys. Selection still depends only on structured status/reason codes. Every lookup
has an explicit, redacted English default, including when the native library is
used by a test executable without an app resource bundle. Unknown errors retain
the safe internal-failure category; remote strings are never localization keys or
message arguments. Shared titles intentionally share one key.

The English source entries cover these diagnostics, the Help window's guidance,
topic labels, links and loading/error text, its menu/window title, and the explicit
About action. No other language is claimed as translated. Existing gettext
catalogs and translator attribution are untouched. Other native UI controls,
prompts, settings and presentation strings still need stable catalog IDs. Do not
mark N4.16 complete until those are covered and long-string/fallback layout
acceptance is recorded. Bundled legal documents remain verbatim source resources.

Authentication and SSH sheet labels/actions, trust detail labels, credential
protection guidance, certificate verification reasons and fixed trust-presentation
errors now also use stable catalog IDs. Trust confirmation and fingerprint text
use whole sentences with interpolated arguments so translators can reorder them.
Endpoint/fingerprint arguments remain literal (including percent signs); RSA
key-size interpolation uses the unsigned 32-bit placeholder matching its type.
Server names, identities, SSH-provided questions and protocol responses are not
translated. Credential-store and saved-trust operation notices, password-file
errors and the saved-trust library now also have catalog coverage. Launch-failure
and unconfirmed-save messages interpolate a fixed diagnostic instead of joining
sentence fragments; the library's saved-fingerprint text has separate algorithm
and fingerprint arguments. No policy, trust override, credential retention or default-button action
is changed by this localization work.

Help expansion checks use a temporary fixture bundle whose English values are
doubled and bracketed, never a shipping translation. At 560×440 and 720×640 in
light/dark, the original segmented picker forced content outside the window.
Help now uses a menu when the segmented picker does not fit. Corrected renders
show wrapped text and links within the window. This offscreen evidence does not
establish keyboard, VoiceOver, RTL or interactive topic-switching acceptance.

Authentication/trust expansion is repeatable with the built native settings test:

```sh
python3 tests/macos/localization-expansion.py \
  build/native-ui-swift/tests/macos/native-settings-tests \
  apps/macos/Localizable.xcstrings /tmp/tidyvnc-settings-expanded-renders
```

The runner creates and removes an isolated test bundle. It originally expanded
authentication, credential, trust and shared-action entries; settings coverage is
now included as described below. It appends
padding instead of duplicating format placeholders. Inspect the resulting PNGs:
the initial run passed fitting-size assertions while the password-retention
selection and saved-password buttons were truncated. The retention label now
appears above its full-width picker, and saved-password actions are vertical.
This targeted fixture does not establish expansion support for the remaining UI.

The catalog now contains 645 English source entries. Settings section labels,
clipboard defaults, storage recovery messages, encoding controls/source labels and
the live encoding sheet have stable IDs. Encoding option/value and unavailable
choice messages use literal interpolated arguments; ranges, protocol names and
stored values still come from the shared schema. Input, scaling, connection options,
security/TLS priority and certificate-file controls and fixed model errors are now
also covered. Fullscreen and remote-resize defaults/session sheets, display
descriptions and fixed draft/server-result messages are now covered too. Profile/history views, endpoint validation and history-import presentation and
fixed errors are now covered. Menus, connection/status/listener UI, document/defaults
import flows and fixed controller/gateway errors remain to migrate.

The trust-library destination now has a wrapping visible label and an explicit
accessibility name. Native trust save/replace buttons still truncate long labels,
even with a multiline Text label, so an adaptive fallback displays the complete
action above a short Review Decision button. It opens the same confirmation and
retains the complete action as its accessibility name. Cancel remains the default.

Settings now gives field content a bounded scroll area, preserving space for
errors/recovery and Apply/Cancel controls. Restore actions adapt to a separate row
when necessary; live encoding recovery has its own row. Input defaults place
labels above their inherited-value pickers. These changes address truncation
found in expanded screenshots, beyond fitting-size assertions.

The expansion runner now includes `settings.` by default. Use repeated `--prefix`
arguments to narrow the expanded entries, and `--rtl` to mirror the fixture's
SwiftUI layout. Mirrored English is a layout stress check, not translated-language
or VoiceOver acceptance. Inspect the images and keep remaining subfield coverage
open; a scroller screenshot shows only its currently visible content.

After building the app, run the packaging regression check:

```sh
xcrun swift tests/macos/localization-bundle.swift \
  build/native-app/app/Debug/TidyVNC.app apps/macos/Localizable.xcstrings
```

It checks compiled bundle values, English development-region fallback for an
untranslated language, and the explicit default for an absent key. The focused
`NativeConnection.ErrorsAndRetry` CTest separately exercises category selection,
redaction, cancellation and retry using an executable without the catalog.

Input/scaling reset labels use a typed inheritance source, never comparison with
translated English. Input accessibility IDs are stable across display languages.
Inherited choices use a short picker label and a wrapping effective-value caption;
modifier controls use two columns. Live input/scaling/security content scrolls
within bounded sheets, leaving recovery/actions available. Scaling uses a vertical
stack because Form columns overflowed even though fitting assertions passed.
Certificate-file paths are full-width with separate Choose/None actions and
explicit accessibility labels. CA/CRL actions use complete localized sentences,
without lowercasing or joining translated fragments. Synthetic expanded screenshots
and the packaged interpolation check cover literal percent signs and setting
values; no translation, physical-device or full accessibility acceptance is implied.

Fullscreen/remote-resize sheets use bounded scroll content and separate recovery
actions. Source pickers and blank-size guidance have visible wrapping labels.
Display rows scroll with the sheet instead of using fixed single-line height
estimates. Physical coordinate diagrams explicitly retain left-to-right order
under a mirrored interface: translating UI direction must not reverse the actual
monitor arrangement. The fullscreen presentation fixture now accepts `--rtl` and
can be passed to the expansion runner in place of `native-settings-tests`.
Packaged tests exercise literal display names containing percent/Unicode text,
locale-formatted dimensions and the full UInt32 server-result range.

Profile/history catalog coverage includes complete gateway tooltips and removal
accessibility labels; addresses with percent escapes and Unicode stay literal.
History import has source choice, omission review, success and fixed reader/storage
diagnostics. Count summaries use labels that also read correctly for one entry.
Profile fields have persistent visible/accessibility labels, and action rows remain
separate at the 900×640 minimum. The app scene retains its 940×680 default. History
import uses NSHostingController min-size propagation from 640×572 content, avoiding
AppKit resetting a manually assigned window minimum. Expanded source/review layouts
were checked at that content floor and the default size.

The expansion runner now includes profile/history/endpoint/source-error prefixes.
For `native-history-import-ui-tests.app/Contents/MacOS/native-history-import-ui-tests`,
add `--named-output` to select its `--verify --output DIRECTORY` interface. That
fixture checks real AppKit window bounds, omission acknowledgement, stale reviews,
source consent and IO drain with temporary source files and an in-memory store.
It does not establish user-app interaction, VoiceOver, or import RTL acceptance.


The listener checkpoint brought the source catalog to **683** entries. Listener UI, status and fixed model
errors are covered, including recovery after invalid ports/families, bind failure,
queue overflow, delivery failure and unavailable incoming peers. Protocol family
names and port syntax remain literal arguments in complete localized sentences.
The port input has an explicit localized accessibility name. Shared document
review/mapping content and file-related errors are covered by the follow-up below.

Listener controls remain outside a single details scroller; peer actions have a
separate row. The 660×472 content minimum is checked with ordinary and expanded
text, including recovery states. A dark minimum-size end capture and scroll
assertion cover the second peer's actions and complete policy notice. Run:

```sh
python3 tests/macos/localization-expansion.py \
  build/native-ui-swift/tests/macos/native-listener-ui-tests.app/Contents/MacOS/native-listener-ui-tests \
  apps/macos/Localizable.xcstrings /tmp/tidyvnc-listener-expanded --named-output
```

This fixture runs real loopback connections with isolated preferences; it does not
use the user's profiles or credentials. It does not implement `--rtl`, and neither
fixture rendering nor synthetic English expansion establishes VoiceOver, installed
app, physical-network or translated-language acceptance.


The document checkpoint brought the source catalog to **796** entries. Document review, mapping and export
flows include reader/writer/codec/resolution diagnostics and shared invocation
resolution failures. File and command-line monitor labels use separate complete
sentences so translations need not splice a source prefix into English grammar.
Line annotations also use complete format entries. Names, endpoint/filename text
and unknown-field names are literal arguments; unknown values are never displayed.
Number formatting is presentation-only: compatibility serialization, protocol
identifiers, stored display IDs and accepted numeric input syntax are untouched.

Document review and display mapping keep actions outside one details scroller;
mapping errors and unavailable-display guidance stay visible above the actions,
with a specific error taking precedence over generic unavailable-display guidance.
pickers have persistent labels with matching accessibility names. Outbound fixture
content is checked at 640×420, listener at 660×472, export at 560×600. The ordinary
review may fit completely; when expanded text overflows, the fixture checks and
captures scrolling to the remaining assignments and guidance. The export fixture
also scrolls through all loss notices without changing the sheet identity or
handing off to the writer early.

Use the expansion command above with either
`native-document-mapping-ui-tests.app/Contents/MacOS/native-document-mapping-ui-tests`
or `native-export-mapping-ui-tests.app/Contents/MacOS/native-export-mapping-ui-tests`
and `--named-output`. `document.` is included by default. These fixtures do not
implement `--rtl`. Remaining app menus/connection/status, file panels and other controlled errors
still require localization; N4.16 stays open. Defaults import is covered below.


The defaults-import checkpoint brought the source catalog to **851** entries. Defaults-import source/review/mapping,
category/omission explanations, consent, results, first-use offer and fixed state/
source recovery messages are localized. Omission rows have separate literal name,
localized line-number and notice arguments; shared file-monitor templates keep
full source-specific sentences. Source paths, stored IDs and protocol field names
are never translated, and source filtering/precedence/consent behavior is unchanged.

Source explanations and mapping details scroll. Error messages, omission consent
and import/review actions stay visible; picker labels have their own wrapping line
and accessibility name. The first-use offer has a separate action row. Expanded
fixtures check the 640×572 content minimum and a 592-point-wide offer, with end
captures for overflowing review details. They do not establish the integrated
connection-window layout, RTL, keyboard/VoiceOver or actual-user-app acceptance.

The expansion runner includes `import.defaults.` by default. Use it with
`native-import-ui-tests.app/Contents/MacOS/native-import-ui-tests` or
`native-defaults-mapping-ui-tests.app/Contents/MacOS/native-defaults-mapping-ui-tests`
and `--named-output`. The fixtures use private temporary sources and in-memory
native stores. Inspect their PNGs in addition to fitting assertions; allow native
control appearance/size transitions to settle before judging captures.


The app/connection checkpoint brought the source catalog to **973** entries. App/window/file-panel titles and actions,
connection controls/state/provenance, native and SwiftUI desktop menus, information
and statistics have stable IDs. Dimensions, speeds and counts use formatted display
numbers. Protocol versions/names, remote values, redacted diagnostics, stored IDs,
keyboard shortcuts and command routing remain unchanged. Fixed controller/gateway
and some status-service errors still need migration; N4.16 remains open.

ConnectionContent is compiled into both the app and settings fixture. Use the
expansion command with `--renderer-arg=--connection-only` to render only the
integrated connection, information and statistics surfaces; add `--rtl` to mirror.
The default prefixes now include `app.`, `desktop.` and `information.`. A fixed
hosting-controller viewport checks actual and proposed sizes rather than allowing
unconstrained ideal sizing to enlarge the fixture. Connection content uses 640×420,
information 560×650, statistics a constrained width with intrinsic height inside
320×300. A compact placeholder fallback and white foreground keep idle guidance
readable when first-use offers reduce the black desktop area. Inspect the PNGs:
geometry and nonblank-image checks alone cannot establish text visibility.

The fixtures use in-memory stores and loopback peers. They do not establish real
menu/panel interaction, VoiceOver, translated-language, installed-app or release
acceptance. Source English is still the only supplied translation. Existing gettext
catalogs and translator attribution remain intact.


The controller/service checkpoint brought the source catalog to **1009** entries. Fixed controller/tunnel/clipboard,
fullscreen/automatic-resize and desktop keyboard/scaling recovery messages are
localized, along with the desktop accessibility label, help and focus action.
OpenSSH grammar/diagnostic classification remains literal and error selection uses
typed cases. A complete fullscreen-failure template accepts a literal diagnostic;
the bundle test verifies percent/Unicode arguments without recursive formatting.

The expansion runner now includes `connection.recovery.`, `clipboard.recovery.`
and `tunnel.error.`. It can run the panning, clipboard and fullscreen executables
with its existing positional interface (those fixtures ignore the output argument).
Localized expected labels replace English-only lookups in these tests; native
selector dispatch, wire routing, focus/lifetime and recovery checks remain active.
These checks establish fixture behavior, not actual VoiceOver or OS prompt use.

Remaining audit includes native launch/CLI strings, the Keychain access reason and
generic diagnostic presentation. Do not translate a raw literal just because it
resembles prose: protocol headers, saved trust commitments and internal errors
caught before presentation have different compatibility obligations. N4.16 remains
open, and English remains the only supplied language.


The CLI/Keychain checkpoint brought the source catalog to **1037** entries. CLI syntax failures, initialization and
launch-credential errors, version/help prose and option annotations are localized.
Help templates receive command syntax, paths, environment names and shared-schema
aliases/defaults as literal arguments; translators can reorder prose without
rewriting those tokens. Argument diagnostics reuse the complete argument/message
template. English help/version bytes and exit statuses are unchanged.

Keychain LAContext reasons and newly created item labels use catalog values.
Service/account identity and OS interaction/access policy remain fixed; replacing
an existing item does not rewrite its label. Expanded fake-SecItem checks verify
presentation together with these identity/policy invariants. Actual OS prompt,
installed signing/upgrade and VoiceOver acceptance remain separate open gates.

`invocation.` is included in the expansion runner. The bootstrap fixture checks
literal syntax examples as well as localized annotation construction. Bundle checks
cover literal percent/Unicode usage, alias and default arguments.

Remaining presentation audit: raw errors in startup, desktop/cursor/rendering/input/
canvas callbacks and fullscreen failure details; native bundle privacy and document
type descriptions inherited from release/Info.plist.in. Translate user presentation
through structured mappings, while classifying protocol headers, trust commitments,
identities and caught internal exceptions according to their actual uses. N4.16
remains open; only English is supplied and no actual translated-language acceptance
is inferred from synthetic expansion.


The source catalog now has **1050** entries. NativePresentationIssue maps typed
startup/desktop failures and operation context to fixed localized recovery. Raw
error descriptions, NSError userInfo and remote/path/credential text are not
formatted. The previous fullscreen arbitrary-diagnostic template was removed;
14 recovery messages were added. Existing cancellation/lifetime guards remain at
the call sites, and fullscreen preserves the original thrown error for its caller.
Keyboard capture denial has a typed case, preserving Accessibility guidance through
shortcut and command catches without inspecting localized text.

The expansion runner includes `presentation.issue.`. Injected renderer, cursor,
canvas and foreign-window failures verify redaction, fallback/recovery, rollback
and teardown with ordinary and expanded text. A hostile error whose description
traps proves that mapping does not stringify unknown errors. This establishes
fixture behavior, not interactive OS/VoiceOver or installed-app acceptance.

The full regression exposed an SSH identity-sheet overflow. Details now scroll in
one bounded 460×570 sheet, retaining visible title and adaptive action rows. The
fixture checks proposed and actual bounds with host auto-sizing disabled, plus
scroll reachability for long untrusted requests. Expanded SSH text and mirrored
layouts pass; representative light/dark top/end images were inspected. Run the
expansion helper with the native-ssh-askpass-tests executable, `--prefix ssh.` and
`--prefix action.`, and `--renderer-arg=--render-only`; add `--rtl` for mirroring.
This does not establish interactive prompt focus, default-button or VoiceOver proof.

Next: native bundle privacy and document-type descriptions from release/Info.plist.in,
then finish the use-based presentation audit and actual window/sheet/menu/focus
acceptance. Protocol headers, stored commitments and caught internal diagnostics
retain their separate compatibility obligations. N4.16 remains open.


Current coverage is **1051 Localizable entries plus 2 InfoPlist entries**. The native
app compiles InfoPlist.xcstrings to its own table for NSLocalNetworkUsageDescription
and the exact document type value `TidyVNC connection`. Apple documents the
[InfoPlist.strings lookup and base-value fallback](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AboutInformationPropertyListFiles.html)
and the [document-type display-name lookup](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/displayname%28fortype%3A%29).
The existing release Info.plist template retains the shared English fallback,
identity, copyright and document extension/role/rank. Brand names and version
identifiers remain literal. No other language is claimed as translated.

`localization-bundle.swift` now also loads the sibling InfoPlist catalog and checks
both compiled tables, localized info dictionary, system privacy lookup, fallback
and equality with release metadata. Finder rendering/registration and the actual
OS privacy prompt still require installed-app acceptance; no permissions changed.

The trust audit found two English-fragment paths. Legacy expectations now use
NativeLegacyTrustIdentity (SPKI or commitment with typed algorithm/digest), so
matching and duplicate suppression cannot depend on translated text. UI messages
are complete sentences. Saved certificate/server-key labels likewise select a
complete sentence by kind. Three new entries replace two old templates; serialized
records, raw algorithms/fingerprints and trust policy remain unchanged. Expanded
policy fixtures verify mixed duplicates and identity decisions, and expanded
screenshots of both identity forms and libraries were inspected.

Raw-literal classification from the source audit:

| Source/use | Treatment and evidence |
| --- | --- |
| NativeDefaultsImport, NativeDocumentExport/Resolution, NativeOptionOverlay and invocation adapters | Option names, aliases, canonical values and file headers are compatibility syntax. Keep literal; translate the surrounding complete UI messages. |
| NativeLegacyTrustCodec and NativeTrustStore | Record delimiters, digests, scope keys and algorithms are data. Typed identities now defer user-facing prose to complete localized messages. |
| NativeRemoteResizePolicy, NativeConnectionDraft, NativeSessionSecurityDraft | Internal validation throws are caught or suppressed; published issue/validation messages select fixed localized recovery. Do not expose raw descriptions. |
| NativeSSHConfiguration/Snapshot | Internal redacted descriptions and literal OpenSSH parsing/arguments remain stable. Production catches convert failures to typed NativeTunnelError messages. |
| NativeValues.redactedDiagnostics | The explicit Copy Diagnostics action exports the existing redacted English support report. It is separate from localized information labels; remote names/endpoints/credentials remain excluded. |
| Bridge/rendering/input guard errors | Raw diagnostics remain internal. NativeConnectionIssue/NativePresentationIssue and operation-specific catches provide fixed UI recovery. The new presentation fixture verifies no arbitrary error description is evaluated. |
| IPv4/IPv6, RFB versions, digest/security/encoding identifiers, product names, resources, accessibility IDs and domains | Literal technical or identity values, distinct from translatable surrounding prose. |

This use-based review is not an exhaustive automated proof. The candidate scan
looked for uppercase/space-bearing literals outside explicit localized defaults;
it cannot prove dynamic string provenance or every Swift interpolation/multiline
case. Finish dynamic presentation/call-site coverage and interactive window/menu/
file-panel/focus acceptance. N4.16 remains open, with N4.17 and all other unchecked
gates. No current real OS, VoiceOver or installed-app acceptance is inferred.


The standard `python3 apps/macos/build.py` path now performs a compiler-derived
source audit after the app build. TidyVNCNative emits `.stringsdata` through Swift's
localization flags; the app uses `SWIFT_EMIT_LOC_STRINGS`. Both CMake targets write
`LocalizationSources.txt` with their actual Swift source list. The audit requires
current records for every source, then compares every extracted localization key
and English default (including typed interpolation placeholders) to the catalog.
It rejects missing/unused keys, stale/missing compiler output and unexpected tables
or record formats. No source mutation or catalog generation occurs in this check.

Current result: **139 sources, 1350 call sites, 1050 Localizable keys**. The separate
**2 InfoPlist keys** remain checked by `localization-bundle.swift`. One unused UI
entry was removed. TidyVNC/IPv4/IPv6 and the numeric port placeholder now use
explicit verbatim text, and monitor numbers use `.formatted()` rather than an
implicit translation key. Empty field-title records have no translatable content;
those call sites were reviewed for separate localized accessibility labels.

To rerun the source check against an existing Debug app build:

```sh
python3 tests/macos/localization-source.py apps/macos/Localizable.xcstrings \
  --module build/native-app/core/platform/macos/LocalizationSources.txt \
    build/native-app/core/platform/macos/localization \
  --module build/native-app/app/LocalizationSources.txt \
    build/native-app/app/build/TidyVNC.build/Debug
```

The checker initially had 13 failure/coverage tests (`localization-source-tests.py`), registered
as `NativeLocalization.CompilerCatalogAudit`. These cover incomplete/stale/wrong-source
records, missing/orphaned keys, format mismatch and supported compiler edge cases.
Compiler output sometimes omits locations on synthesized expressions; their
key/default is still validated. Generated App Shortcuts metadata and removed-source
records are outside the source manifests and cannot satisfy current-source coverage.

This closes the static call-site/default-format evidence gap from the earlier
literal scan. It does not identify arbitrary dynamic Strings passed to Text,
prove visible layout or OS localization, or replace keyboard/VoiceOver acceptance.
Continue the dynamic provenance review and interactive requirements before marking
N4.16 or N4.17 complete. No new shipping translations or gettext edits were made.


A subsequent dynamic-label audit found reset actions inserting raw encoding schema
names into otherwise localized messages. EncodingSettingsFields now passes the
localized visible label to its reset helper; help and accessibility names agree
with controls such as Allow JPEG and Reduced colors. Reset IDs use typed option
values, while callbacks continue to pass those typed options. The compiler audit
now reports **1351 call sites**, with **139 sources / 1050 UI keys** unchanged.
Profile inheritance/isolation and expanded rendering pass. An isolated SwiftUI
accessibility-tree experiment returned no children and could not verify activation;
that unsupported fixture is not part of the shipped suite. Actual VoiceOver and
keyboard acceptance remain open and are not inferred from source labels or renders.

The full build/test workflow subsequently exposed an invalid freshness assumption:
Swift preserves a byte-identical `.stringsdata` file when recompiling a source whose
localized content did not change. Comparing record/source mtimes therefore rejected
a successfully rebuilt SSH process implementation. The check now uses
`LocalizationSources.built.json`, emitted by each target's successful POST_BUILD
step. It contains SHA-256 hashes of all current manifest sources and their compiler
records. The audit requires a matching receipt, complete source records, supported
record/table formats, and unchanged key/default/interpolation agreement with the
catalog. Missing receipts and source/record changes after a completed build fail.
Record timestamps are not used as proof of compilation.

The native bridge now requires Python for its POST_BUILD receipt, including in
bridge-only mode. The standalone audit command above is unchanged; build the
targets to create receipts, rather than manually creating them during acceptance.
The checker now has **16** regressions, including a recompiled source with an older
unchanged record, changed source/record contents and missing receipt. This fixes
incremental-build validation; it does not expand localization or interactive
acceptance claims. Source/catalog counts remain **139 / 1351 / 1050**, plus the
separate **2** system-metadata keys.

## Scoped failure-alert policy (2026-09-22)

Added `invocation.help.failure.alerts` and `document.failure.alerts.omitted`.
Help explains Retry precedence and affected-window/application lifetime; export
review explicitly acknowledges omission of the launch-only policy. Compiler
coverage is now **139 sources / 1353 call sites / 1052 UI keys**. Final verification
`run-bl32lpk7` passes all **1052 + 2** packaged lookups and native render/catalog
fixtures. The export review's added paragraph and scroll-end images were visually
inspected. These fixtures do not establish interactive keyboard or VoiceOver
acceptance; those gates remain open.
