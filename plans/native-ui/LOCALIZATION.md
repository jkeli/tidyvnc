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


The source catalog now has **973** entries. App/window/file-panel titles and actions,
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
