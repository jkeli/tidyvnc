# Rebrand the TigerVNC fork as TidyVNC

Status: planned; implementation has not started. Baseline: `33556c96`, inspected
2026-09-18. Track implementation and validation in [TODO.md](TODO.md).
Paths below are repository-relative unless stated otherwise.

## 1. Outcome and scope

Identify this fork as **TidyVNC** wherever the software presents its own product
identity: application windows, menus, dialogs, command-line output, documentation,
translations, launchers, installers, package metadata, downloadable artifacts and
graphics. Use appropriate case in filenames, identifiers and build variables.
Replace the tiger-eye artwork and any other TigerVNC-specific visual identity
with original TidyVNC assets designed for high-density displays.

Preserve TigerVNC references that describe actual authorship, copyright, licenses,
upstream history, third-party resources, or deliberately supported compatibility
interfaces. A successful rebrand does **not** produce zero search matches for
TigerVNC. It produces no unexplained use of TigerVNC as this fork's branding.

The implementation sequence starts with the native macOS viewer, matching the
current development focus. This plan inventories repository-wide branding and
includes later Windows, Linux/server and Java branding work. The earlier decision
to defer cross-platform implementation and exclude Java HiDPI feature parity
remains in effect: branding Java does not require porting the native scaling
architecture. A macOS milestone must not be described as a completed repository-
wide rebrand while the later branding passes remain open.

This work does not rename the user's checkout, rewrite Git history, rename the
upstream Git remote, change VNC protocol behavior, redesign the client UI, or
publish releases. Distribution signing, notarization, dependency bundling and
broader HiDPI correctness gates remain separate work in [the HiDPI plan](../hidpi/PLAN.md).

## 2. Naming and identity contract

| Context | New spelling / policy |
| --- | --- |
| Product name and prose | `TidyVNC`; viewer/server qualifiers follow it where useful |
| Lowercase project, asset, package and directory names | `tidyvnc` |
| Uppercase prefixes and private include guards | `TIDYVNC` / `TIDYVNC_*` |
| PascalCase private symbols | `TidyVNC`, e.g. `TidyVNCDisplayObserver` |
| macOS application and disk image | `TidyVNC.app`, `TidyVNC-<version>.dmg` |
| Native icon stem and gettext domain | `tidyvnc` |
| New connection file / magic header | `.tidyvnc` / `TidyVNC Configuration file Version 1.0` |
| New user state | `tidyvnc` under the existing XDG roots; `TidyVNC` under Windows application data |
| Repository / project homepage | `https://github.com/jkeli/tidyvnc`, confirmed from `origin` |
| Support destination | The fork's issue tracker, after checking it is enabled; do not invent a support email or domain |
| Proposed macOS bundle and Linux application ID | `io.github.jkeli.tidyvnc`; finalize before shipping, consistently across metadata and packaging |
| Generic executable names | Keep `vncviewer`, `vncpasswd`, `Xvnc`, etc. unless a packaging collision requires a documented alternative |

Do not mechanically transform `tigervnc.org` into an unverified `tidyvnc.org`,
or rewrite `com.tigervnc.*` to imply ownership of a new DNS domain. Do not rename
RealVNC, TightVNC, FLTK, X.org, libjpeg-turbo, or other projects. Existing version
numbers describe the code baseline; rebranding alone is not a versioning reset.

Finalize the proposed bundle ID and artwork direction early in implementation.
For new artwork, use a simple remote-display/connection motif with a clear small
silhouette, distinct from the tiger eye, stripes and tiger-face composition. The
exact palette and mark are design choices to record alongside the assets; this
plan does not prescribe a finished logo or a new publisher's legal identity.

## 3. Classify every occurrence before changing it (R0)

Create a tracked inventory, proposed `plans/rebrand/INVENTORY.md`, and a narrow
machine-readable exception list, proposed `tests/fixtures/rebrand-exceptions.json`.
Each inventory entry records path, relevant symbol/string/asset, role, action,
reason, migration dependency, and validation. Use these dispositions:

1. **Replace product branding:** text, URLs and images that identify this fork.
2. **Preserve attribution/legal text:** copyright notices, license text, authors,
   translator credits, original artwork provenance and upstream acknowledgments.
3. **Preserve history or external references:** old release entries, upstream
   issues/commits, quoted original output, vendor code and historical build evidence.
4. **Migrate compatibility identifiers:** persistent files, registry keys, app IDs,
   gettext catalogs and public build inputs; never change their writers alone.
5. **Retain a compatibility identifier:** an explicit, justified interface such as
   a protocol extension name or Java package namespace. Record its consumers and
   why changing it is outside a branding-only change.

Search tracked contents case-insensitively for `tigervnc`, `tiger vnc`,
`tiger-vnc` and `tiger_vnc`; also inspect filenames, archives and graphics. For
example, `git grep -n -i -E 'tiger[-_ ]?vnc'` is a starting inventory, not a
replacement command. Inspect all tracked paths with `git ls-files`; include
hidden CI files, PO/POT catalogs, vendored X server integration and packaging
patches. Exclude `.git` objects and generated build trees from the source scan,
then separately audit fresh build outputs. Never exclude whole source directories
just because they contain copyright notices or Java package declarations.

An exception must identify a specific string or semantic block and its reason.
Do not permit an entire file such as `vncviewer.cxx`: its About text currently
combines product branding, copyright and an upstream URL in one message.
Distinguish the copyright line from the surrounding presentation. Review new
matches and stale exceptions in CI so future upstream merges cannot silently
restore branding.

### Audited starting points

| Area | Observed files / important details |
| --- | --- |
| Native UI | `vncviewer/vncviewer.cxx`, `DesktopWindow.cxx`, `Viewport.cxx`, `OptionsDialog.cxx`, `ServerDialog.cxx`; About, app menus, window titles, file pickers, messages and version output |
| Persistent identity | `vncviewer/parameters.cxx`, `ServerDialog.cxx`, `common/core/xdgdirs.{cxx,h}`; magic header, defaults, history, registry and XDG directories |
| Build identity | `CMakeLists.txt`, `cmake/FLTK/CMakeLists.txt`, `cmake/StaticBuild.cmake`, `vncviewer/CMakeLists.txt`, `tests/*/CMakeLists.txt`; project and `TIGERVNC_*` names |
| macOS | `release/Info.plist.in`, `release/makemacapp.in`, `release/CMakeLists.txt`; app name, bundle ID, ICNS reference, volume and DMG names |
| Windows | `vncviewer/vncviewer.rc.in`, `release/{tigervnc,winvnc}.iss.in`, `win/**/{*.rc,*.manifest*}`; product/publisher fields, captions, shortcuts, services and resources |
| Linux desktop | `vncviewer/vncviewer.desktop.in.in`, `org.tigervnc.vncviewer.metainfo.xml.in`, `vncviewer/metainfo/*.jpg`; launcher, application ID, screenshots, project links and historical releases |
| Linux/server packaging | `contrib/packages/**`, `.github/containers/**`, `unix/vncserver/**`, `unix/xserver/hw/vnc/**`; package names, script paths, PAM/SELinux, service names and X extension identifiers |
| Localization | `common/core/i18n.h`, `po/CMakeLists.txt`, `po/tigervnc.pot`, `po/*.po`; domain and compiled catalog names must move together |
| Graphics | `media/tigervnc*.svg`, `media/icons/tigervnc*`, `media/CMakeLists.txt`; visually inspected native PNG is the tiger eye |
| Other artwork | `java/com/tigervnc/vncviewer/tigervnc.{png,ico}`, `win/winvnc/*.{ico,bmp}`, `win/vncconfig/vncconfig.ico`; Java PNG also visibly uses the tiger eye; Windows resources need visual classification |
| Java | `java/CMakeLists.txt`, `java/com/tigervnc/vncviewer/**`; UI, manifest, image loading, preference node, file paths and stable `com.tigervnc` packages |
| Documentation/support | `README.rst`, `BUILDING.txt`, `BUILD-MACOS.md`, manuals, `.github/ISSUE_TEMPLATE/**`, plans and package metadata |

This table is a starting map, not a claim that every match has been classified.

## 4. Preserve authorship and provenance (part of R0 and every phase)

Leave `LICENCE.TXT`, bundled license files, source copyright notices, legal
copyright resource fields, named contributors and translator attribution intact.
This includes the recently added `Copyright 2026 TigerVNC contributors` headers;
do not silently reassign their authorship because the product name changes.
Add accurate attribution for new work separately when applicable.

Rewrite the README introduction to say that TidyVNC is a fork of TigerVNC.
Keep TigerVNC's origins in TightVNC/RealVNC/X.org attached to TigerVNC rather than
claiming that TidyVNC itself existed in 2009. Preserve upstream history and
acknowledgments in their appropriate sections.

About/version output should start with `TidyVNC`, give the fork's project link,
and retain existing copyright plus a clear upstream acknowledgment. TigerVNC
may still appear in this credits context. Product identity and source attribution
are different roles even when they share a dialog or translated message.

Inspect publisher metadata separately: `AppPublisher`, `CompanyName`, AppStream
developer identity and generated package maintainer fields must not falsely
identify the upstream team as the publisher of this fork. Use a factual fork
maintainer/project identity, confirmed before packaging, while retaining original
authors in credits. Do not fabricate a company, email address or signing identity.
Review `LegalTrademarks` as a legal/provenance field rather than doing a blind
rename or treating it as a place to assert a new trademark claim.

Preserve upstream URLs in historical release entries, cited bugs, license/source
references and attribution. Replace links that currently direct TidyVNC users to
TigerVNC for product help or bug reports. If a target such as fork Discussions
does not exist, use an available issue route or remove that invitation.

Keep old measured build outputs and commit hashes in `BUILD-MACOS.md` and earlier
plans historically accurate. Add current TidyVNC instructions and clearly label
historical sections instead of retroactively renaming artifacts that were
actually built as TigerVNC. Existing filesystem paths under this checkout remain
valid even though its directory is named `tigervnc`.

## 5. Product text, build names and translations (R1)

- Change native UI literals and translated message IDs to TidyVNC, including the
  macOS About/Hide/Quit menu, default message title, connection dialog, options,
  grabbed-keyboard title, context-menu mnemonic, error text and CLI banners.
  Preserve format arguments, newline behavior and keyboard accelerators.
- Change `project(tigervnc)` and the FLTK dependency project to their TidyVNC
  counterparts. Audit variables derived from `CMAKE_PROJECT_NAME`: install paths,
  archive names and package resources can change implicitly. Keep this fork's
  internal `TIGERVNC_FLTK_TARGET` and private include guards consistent with
  `TIDYVNC_*`; rename the private Cocoa observer class as well.
- For documented public build inputs, introduce `TIDYVNC_FLTK_SHARED` and other
  applicable `TIDYVNC_*` options with deprecated `TIGERVNC_*` aliases. New-only
  settings work; old-only settings work with a diagnostic; contradictory old/new
  values produce an actionable error. Do not overwrite an explicitly set new
  value with a stale cache entry. Apply the same policy to X server build inputs
  when that platform's pass is implemented.
- Change `DEFAULT_TEXT_DOMAIN`, POT filename, extraction domain, installed MO
  filename and every installer/app-staging copy rule together to `tidyvnc`.
  This private resource name does not need a runtime alias if every artifact
  ships the matching catalogs. Never load TigerVNC's installed translations as
  a fallback for TidyVNC.
- Regenerate the POT and merge every PO catalog. Review `msgstr` as well as
  `msgid`, including combined About/copyright strings. Preserve translator
  credits, legal lines, placeholders, markup and mnemonic syntax. Handle obsolete
  entries and fuzzy translations explicitly; a missing translation may fall back
  to new English text, but an active translation must not reintroduce branding.
  Update project/buginfo metadata without rewriting historical translator notes.
- Retain literal extractable gettext messages. Do not replace them with dynamic
  string concatenation that prevents extraction. Small CMake branding constants
  can drive generated metadata; avoid a new generic branding framework.

## 6. Saved files, state and interoperability (R2)

The current magic header is `TigerVNC Configuration file Version 1.0` and new
settings are normally written to `default.tigervnc`. The current common directory
helper falls back to `.vnc`/`%APPDATA%\\vnc` and is shared by several tools.
Changing that helper's suffix without separating read and write behavior would
risk writing into an upstream installation's state. Design migration explicitly.

### Connection files

1. New saves default to `.tidyvnc` with the TidyVNC header. Keep option syntax and
   parameter names unchanged; the header change is product identity, not a claim
   that the configuration grammar changed.
2. Read both exact, versioned headers; keep `.tigervnc` files working through
   command-line loading, file chooser and drag/open dispatch where supported.
   Reject unknown versions and malformed files with useful errors.
3. Use a TidyVNC-labelled default filter and a separate, accurately labelled
   legacy TigerVNC import filter. The legacy product name is appropriate here.
   A normal Save As creates a new TidyVNC file and does not overwrite an imported
   legacy file without an explicit overwrite action.
4. If legacy export is provided, make it an explicit file type, emit the old
   header, and test with the original parser. Do not claim upstream supports
   fork-only scaling options merely because it accepts the header. Legacy export
   is optional; legacy import is required.

### Defaults, history and security-related state

- New writes target TidyVNC-owned directories, `default.tidyvnc`,
  `tidyvnc.history`, and Windows `Software\\TidyVNC\\vncviewer` keys.
  Keep explicit user-specified file paths working regardless of their spelling.
- Define separate lookup functions for current destinations and legacy import
  candidates rather than making writable paths fall back to old directories.
  On first run, offer import of legacy preferences/history when TidyVNC has no
  state. An existing or malformed new configuration must not silently fall back
  to old values; report parse errors. New values always win in a deliberate import.
- Copy only selected supported preferences/history; do not recursively copy a
  configuration tree, delete old files or merge two live applications' state.
  Use atomic writes and preserve appropriate file permissions. Repeated import
  must not duplicate history or overwrite existing preferences.
- Treat password files, CA/CRL paths, known-host trust, credentials, scripts and
  SSH/tunnel commands separately from ordinary display settings. Explain and
  require explicit selection before importing them; keep existing explicit paths
  usable and do not reset trust or weaken certificate checks during migration.
- Include XDG overrides, older `.vnc` locations, Windows registry history, and
  Java's `Preferences.userRoot().node("TigerVNC")` in the inventory. Implement
  platform-specific migration in its own phase. The macOS build currently uses
  the common XDG-style paths: do not assume it already uses Cocoa preferences.
- A new macOS bundle ID is a new application identity. Test launch registration,
  file associations and accessibility/input permissions; existing permission
  grants may not transfer. Do not automatically modify privacy permissions.

Keep wire constants, RFB encodings/security identifiers and generic command-line
options stable. In particular, inspect the X server's `TIGERVNC` extension name
and X selection/IPC identifiers as interfaces, not UI labels. Retain established
externally consumed names with narrow exceptions unless a separate compatibility
migration is implemented. Private names with no such consumers should be renamed.

## 7. Original artwork and HiDPI asset pipeline (R3)

### Visual inventory and sources

Replace all sizes of the native tiger-eye logo and Java duplicates, including
SVG metadata and resource filenames. Visually inspect Windows tray connected,
disconnected and configuration icons plus `winvnc.bmp`: filename searches alone
cannot detect TigerVNC-specific imagery. Preserve state distinctions after any
replacement. Inspect screenshots for old title bars and icons; capture actual
TidyVNC UI rather than merely changing captions on TigerVNC screenshots.

Generic security padlocks are not TigerVNC branding by themselves. Audit
`media/{secure,insecure}.{svg,xpm}` and Java equivalents and retain unbranded
assets when appropriate. The native authentication dialog already draws its
padlocks with vector primitives; preserve that HiDPI path. Any newly created or
replaced graphic, including incidental UI artwork, must meet the density rules.

Create an editable vector master, proposed `media/tidyvnc.svg`, with optional
optically adjusted small-size variants. The result must be an original mark,
not a recolored tiger eye. Record source/provenance, actual creator information,
license, colors and export commands in a proposed `media/README.md`. If bitmap
concept artwork is generated, retain a sufficiently large original and derive
production assets from reviewed high-resolution or vector sources; do not
upscale a small raster and call it HiDPI. Preserve accurate attribution for any
retained or derived upstream material.

### Required asset outputs

| Consumer | Planned outputs and checks |
| --- | --- |
| macOS | `tidyvnc.icns` built from an iconset containing 16, 32, 128, 256 and 512 logical-pixel slots at both 1× and 2×; largest bitmap 1024×1024. Use the platform iconset tool and inspect the resulting representations. |
| Windows | A multi-resolution `tidyvnc.ico`, at least 16, 24, 32, 48 and 256 pixels; add appropriate intermediate sizes such as 20, 40, 64 and 96 to reduce fractional-DPI resampling. Inspect alpha and small-size legibility, including tray/status variants. |
| Linux | Scalable SVG and PNGs at existing 16/22/24/32/48/64/128 sizes plus 256 and 512; consistent hicolor install names and scale-aware lookup. |
| In-app/Java images | Vector rendering where supported; otherwise correctly selected multiple raster sizes at fixed logical dimensions, covering 1×/2× and relevant fractional density. Do not raise Java's runtime floor just to load a new icon. |
| Screenshots/docs | Fresh high-resolution captures of the branded build with recorded logical size and density. Provide suitable display-sized derivatives; no enlarged legacy captures. |

The macOS iconset slots follow Apple's [Icon Set Type reference](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/IconSetType.html).
For Windows sizes, follow the native icon consumer described in Microsoft's
[app icon construction guidance](https://learn.microsoft.com/en-us/windows/apps/design/style/iconography/app-icon-construction).
Linux size/scale metadata follows the [Icon Theme Specification](https://specifications.freedesktop.org/icon-theme/).
These references guide asset packaging; they do not establish runtime HiDPI
correctness for every deferred platform.

### Build integration

Refactor `media/CMakeLists.txt` so one documented export path produces all
consumers from the master. Its current size lists stop at 512 for macOS and 128
for Linux; the fallback source is `tigervnc_48.svg`, and it writes generated
assets into the source tree. Deduplicate size lists before declaring outputs,
list every dependency, and generate into the build tree. Keep reviewed
distribution-ready assets in source if that allows normal/offline builds without
graphics tooling; provide an explicit regeneration/verification target that
compares exports rather than silently overwriting source files.

Record required tool versions and provide clear errors for missing export tools.
Use `iconutil` for the macOS iconset packaging path; do not rely on the current
`png2icns` path to imply complete 2× coverage. Update native runtime icon loading,
resource scripts, installer inputs, Linux installs and Java JAR resources
together. Make removed asset references a build failure. Inspect the final
embedded ICNS/ICO/JAR resources, not only loose PNGs.

Review icons on light/dark backgrounds and at small, large, 1×, 2× and fractional
display scales. Check clipping, alpha halos, aspect ratio and state contrast.
An image's pixel dimensions must not change the control's logical dimensions.
Do not infer density support from a renamed filename or `@2x` suffix alone.

## 8. macOS product and packaging integration (R4)

- Update `CFBundleName`, `CFBundleDisplayName`, long version name, bundle ID and
  `CFBundleIconFile` in `release/Info.plist.in`. Preserve both copyright fields,
  `NSHighResolutionCapable=true`, executable name and existing version semantics.
- Update `release/makemacapp.in` and `release/CMakeLists.txt` consistently: app
  directory, volume name, temporary naming, output DMG, icon and MO resources.
  Ensure translations are actual dependencies of packaging, avoiding the current
  requirement to remember a separate full build before the DMG target.
- Use a fresh `build/tidyvnc-release` directory so stale TigerVNC resources cannot
  mask missing inputs. Stage `TidyVNC.app` and build `TidyVNC-<version>.dmg` from
  the same executable. Preserve historical TigerVNC build directories.
- Update current app-staging instructions and CI artifact globs. Validate the
  plist, embedded icon representations, translations and startup output.
- Launch the packaged build and inspect Finder, Dock, app switcher, menu bar,
  About, connection/options/file dialogs, errors and remote-session titles.
  Use a fresh bundle path to distinguish stale icon caches from asset defects;
  do not clear system caches indiscriminately.
- Mount/inspect the DMG, verify the app name and resources, and verify its checksum.
  Check side-by-side launch with upstream where possible. Retain the documented
  local-build limitations until dependency portability/signing work is completed.

## 9. Remaining platform branding and interfaces (R5)

### Windows

Update native resource captions/product fields, application manifests, installer
templates, file/resource names, shortcuts, uninstaller text and output globs.
Set a distinct stable installer identity so installing/uninstalling TidyVNC does
not remove TigerVNC. Plan service and event/IPC names as a coordinated namespace
change; update server registration and clients together. Preserve configuration
and permit coexistence. Explicitly review file associations instead of taking
over upstream extensions without consent. Validate at 100/125/150/200% display
scale when Windows work resumes.

### Linux and Unix servers

Change launcher Name/Icon and create a fork-specific desktop file and matching
AppStream ID/launchable reference. Update product descriptions, icon install paths,
current project links and screenshots; retain historical upstream release links
only in a clearly attributed upstream-history context, not as TidyVNC releases.

Update Debian/RPM names, descriptions, source archives, `.install`/maintainer
scripts, spec paths, container image tags and CI copy/upload globs atomically.
Do not rewrite maintainer identity or signed historical changelogs. Review
`Provides/Replaces/Conflicts`, alternatives and generic executable collisions;
choose separate prefixes or explicit package conflicts where files cannot
coexist. Do not promise side-by-side distro installs without proving ownership
of installed paths.

Treat PAM service names, systemd units, system configuration paths, SELinux
contexts and logs as a coordinated deployment migration. Keep established X/RFB
interfaces where appropriate, while rebranding human-visible banners and manual
titles. Inspect `unix/xserver/hw/vnc` even if broader vendored X server sources
are left unchanged; embedded patch hunks must still apply after renames.

### Java branding only

Update Java titles, dialogs, banners, manifest `Application-Name`, documentation,
resource filenames/loaders and packaged assets. Add the matching settings/import
policy when shipping this flavor. Keep `com.tigervnc` package paths and manifest
Main-Class as documented binary/source compatibility exceptions for this pass;
they are not the UI brand. Inspect resource lookups after asset renames and test
multiple-size icon loading on the supported Java runtime. Do not alter bundled
JSch or Java license/author text. Java scaling feature parity remains excluded.

## 10. Documentation, support and repository integration (R6)

Update current README, build/install instructions, manuals, CLI examples, support
templates and CI artifact names to describe TidyVNC. Use actual produced names,
paths and URLs; update generated documentation inputs as well as visible outputs.
Explain legacy configuration import and the reason TigerVNC remains in credits
or compatibility examples. Add current rebrand status to the scaling/HiDPI plans
without rewriting their historical evidence.

Audit current package URL/maintainer fields, AppStream screenshots, generated
translation bug-report metadata and CI bot attribution. Keep historical release
and third-party source links intact. Do not publish or fabricate replacement
screenshots/URLs before the corresponding artifacts exist. Hosting settings,
social preview artwork, repository description and issue routing outside Git are
a separate delivery checklist; this plan does not change hosting configuration.

## 11. Validation and acceptance (R7)

### Automated checks

- A source/path branding audit with the reviewed exception list: fail on new
  unexplained old-brand matches and new references to removed assets. Classify
  multiline PO messages and copyright blocks; do not allow matches solely based
  on a whole-directory exemption.
- An attribution diff review against the baseline: no altered license bodies,
  reassigned copyright, removed authors or rewritten third-party history. Check
  combined version/About messages and translated equivalents specifically.
- Settings/file tests for both magic headers; old import, new round trip, unknown
  version rejection, malformed new-state errors, precedence, permission errors,
  repeat import, and preservation of upstream files. Use isolated temporary test
  state; do not read or change the developer's real credentials/preferences.
- Build-option alias tests for old-only, new-only and conflicting values. A fresh
  viewer-on build and viewer-off configuration must not depend on legacy names
  or files accidentally present in an existing build directory.
- `msgfmt --check` for every catalog; check active translated product labels and
  installed domain consistency. Verify representative non-English UI, placeholder
  formatting and copyright preservation.
- Asset validation for dimensions, density slots, alpha, expected container
  representations, reproducible exports and reference completeness. Use visual
  inspection in addition to tests; source scans cannot detect a tiger-eye raster.
- Fresh native Debug and Release builds, existing unit suite (currently 293
  cases, plus new tests) and existing loopback RFB smoke suite. Do not encode 293
  as a permanent expected count or drop tests to maintain it.
- Inspect staged app/installer/archive metadata and extracted catalogs/resources.
  `strings` can help triage binary matches but is not an unconditional zero-match
  gate because legal text and compatibility identifiers are intentionally present.

### User-visible review

Exercise all native app surfaces listed in R4, normal and error paths, file
loading/saving, translated dialogs, minimized/restored windows and keyboard-grab
titles. Inspect the packaged app's identity and icons at 1× and 2×; carry forward
fractional/mixed-display checks from the HiDPI plan. Use synthetic remote desktops
for screenshots: text supplied by a remote server is not this app's branding and
must not be rewritten by the viewer.

Record platform, build type, locale, display scale, tested artifact and evidence
for each result. Mark unavailable physical/platform tests as open. A build passing
does not prove visual replacement, correct asset density selection, or migration.

### Completion gates

**macOS milestone:** TidyVNC app/DMG, all native product text and active catalogs,
original HiDPI artwork, new identity/state with legacy import, preserved notices,
fresh builds/tests and packaged visual review completed. Document any physical
test gaps rather than claiming complete validation.

**Repository-wide completion:** every inventory item has a resolved disposition;
all shipped flavors pass their branding/packaging checks; remaining TigerVNC
matches are narrow documented attribution/history/compatibility exceptions;
there are no active tiger-eye assets in shipped products or misleading upstream
support/publisher links. Deferred platform work remains explicitly incomplete
until that platform's gate is met.

## 12. Implementation order and reviewable commits

| Phase | Deliverable | Depends on |
| --- | --- | --- |
| R0 | Inventory, naming decisions, attribution baseline and exception policy | None |
| R1 | Product text, build identity and complete gettext-domain/catalog changes | R0 |
| R2 | Connection format readers/writers and isolated settings/import behavior | R0; coordinate file labels with R1 |
| R3 | Original artwork, HiDPI exports and all resource references | R0 |
| R4 | Fully branded macOS app/DMG and native integration | R1–R3 |
| R5 | Deferred Windows/Linux/server and Java branding passes | Shared R1–R3; platform availability |
| R6 | Current docs/support/CI aligned with actual artifacts | Corresponding implementation phases |
| R7 | Automated audit, packaged visual checks and release evidence | Per-platform implemented phases |

Keep commits buildable. Pair an asset rename with its consumers; pair a gettext
domain rename with runtime/installer catalog paths; pair new settings writers
with compatible readers and migration tests. Keep private identifier cleanup
separate from behavioral migration where possible. Update TODO.md with actual
evidence as work proceeds. The final rebrand review must cover the combined diff,
not just each individually passing commit.
