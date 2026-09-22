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

The runner creates and removes an isolated test bundle, expanding only the
authentication, credential, trust and shared-action catalog entries. It appends
padding instead of duplicating format placeholders. Inspect the resulting PNGs:
the initial run passed fitting-size assertions while the password-retention
selection and saved-password buttons were truncated. The retention label now
appears above its full-width picker, and saved-password actions are vertical.
This targeted fixture does not establish expansion support for the remaining UI.

After building the app, run the packaging regression check:

```sh
xcrun swift tests/macos/localization-bundle.swift \
  build/native-app/app/Debug/TidyVNC.app apps/macos/Localizable.xcstrings
```

It checks compiled bundle values, English development-region fallback for an
untranslated language, and the explicit default for an absent key. The focused
`NativeConnection.ErrorsAndRetry` CTest separately exercises category selection,
redaction, cancellation and retry using an executable without the catalog.
