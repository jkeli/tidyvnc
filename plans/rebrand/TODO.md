# TidyVNC rebrand checklist

Implementation tracker for [PLAN.md](PLAN.md), baseline `33556c96`, 2026-09-18.
Implementation is in progress; unresolved and deferred work stays unchecked. Check an item only after its stated work and validation
are complete, and record evidence in the log at the end.

The native macOS viewer is first. Windows/Linux execution remains deferred;
Java branding is included in the eventual rebrand, while Java HiDPI feature
parity remains excluded. Deferred items do not count as completed.

## R0 — Inventory, naming and attribution

- [x] Inventory tracked text, filenames, hidden CI files, catalogs, packaging patches and binary artwork; include `unix/xserver/hw/vnc` and Java.
- [ ] Create `INVENTORY.md` with replace/preserve/migrate decisions, reasons, consumers and validation for every occurrence group.
- [ ] Establish narrow `rebrand-exceptions.json` entries for attribution, history and deliberate compatibility identifiers.
- [x] Record canonical `TidyVNC`, `tidyvnc` and `TIDYVNC` spellings and retained generic executable names.
- [x] Finalize the proposed `io.github.jkeli.tidyvnc` application identity before packaging.
- [x] Confirm actual publisher/maintainer identity and available fork support URLs; avoid invented domains, companies or email addresses.
- [x] Record baseline license/copyright/author/translator notices and historical upstream references for later diff review.
- [ ] Visually classify Windows ICO/BMP resources and all screenshots, including graphics whose filenames do not mention TigerVNC.
- [x] Record the original artwork direction, asset provenance requirements and expected platform outputs.

## R1 — Product strings, build identity and localization

- [ ] Rebrand native connection, session, options, error and file-dialog titles.
- [x] Rebrand About, context menu, macOS About/Hide/Quit and default message titles; preserve mnemonics.
- [x] Rebrand version/help/diagnostic output while preserving original copyright and adding clear upstream attribution.
- [ ] Replace current product/support links with verified fork destinations; retain historical and attribution links.
- [x] Rename CMake project/dependency names and audit derived artifact/install paths.
- [x] Rename private symbols, include guards and FLTK target variables using the appropriate case.
- [x] Introduce public `TIDYVNC_*` build options with tested legacy aliases and conflict diagnostics.
- [x] Rename the gettext domain and POT file together with every runtime, installation and staging MO path.
- [x] Regenerate POT and merge every PO; review active `msgstr`, fuzzy/obsolete entries and project metadata.
- [ ] Preserve translated legal text, translator credits, placeholders and markup.
- [ ] Run catalog validation and test representative translated UI for stale branding and clipped text.

## R2 — Connection files, settings and compatibility

- [ ] Add `.tidyvnc` and the TidyVNC configuration header for new saves.
- [ ] Read both legacy and new headers without changing option semantics; reject unknown versions and malformed files.
- [ ] Update default file filters, Save As behavior, CLI documentation and applicable file-open dispatch.
- [ ] Preserve explicit legacy import and avoid unprompted overwrites of imported files.
- [ ] Record whether legacy export is included; if implemented, label it explicitly and validate the legacy header with the upstream parser.
- [ ] Separate writable TidyVNC destinations from legacy import candidates in shared directory helpers.
- [ ] Introduce `default.tidyvnc` and `tidyvnc.history` under TidyVNC-owned state directories.
- [ ] Implement selected preferences/history import with new-state precedence, atomic writes and permission preservation.
- [ ] Verify malformed new state does not silently revert to old settings.
- [ ] Verify repeat import does not duplicate data and upstream files remain untouched.
- [ ] Handle passwords, trust/CA/CRL files, credentials and tunnel/script settings separately with explicit import selection.
- [ ] Preserve explicit user-supplied legacy paths and certificate verification behavior.
- [ ] Inventory `.vnc`, XDG overrides, Windows registry and Java preferences; implement each platform's migration with its rollout.
- [ ] Classify X extension, selection, IPC and wire identifiers; retain externally consumed names only with documented exceptions.
- [ ] Test new/old file round trips, precedence, malformed input, permission failures and coexistence with isolated test state.

## R3 — Original HiDPI artwork and reproducible exports

- [ ] Create the original editable TidyVNC vector master and optically adjusted small variants as needed.
- [ ] Record creator/provenance, license, palette and export commands in `media/README.md`.
- [ ] Replace native tiger-eye SVG/PNG/ICO/ICNS files and matching Java image resources.
- [ ] Replace any branded Windows tray/configuration/bitmap graphics while preserving connected/disconnected state distinctions.
- [ ] Audit generic padlocks; retain unbranded assets and the existing native vector-rendering path where appropriate.
- [ ] Generate complete macOS iconset slots at 1×/2× through 512 logical pixels / 1024 physical pixels, then build `tidyvnc.icns`.
- [ ] Generate the Windows multi-resolution ICO and needed fractional-DPI/tray representations.
- [ ] Generate scalable Linux SVG and raster sizes through 512 pixels with consistent install names.
- [ ] Provide density-aware in-app/Java image selection without changing logical dimensions or requiring a new Java baseline.
- [ ] Refactor media export rules: deduplicate sizes, declare dependencies and generate into the build tree.
- [ ] Provide explicit regeneration/verification tooling and keep ordinary offline builds independent of optional graphics tools.
- [ ] Update all icon/resource consumers atomically with filenames; remove stale active asset references.
- [ ] Inspect final ICNS/ICO/JAR representations, dimensions, alpha and reproducibility.
- [ ] Review light/dark backgrounds, small/large sizes, 1×/2× and fractional density for blur, halos, clipping and state contrast.
- [ ] Replace branded screenshots with actual high-resolution TidyVNC captures; verify captions and image URLs.

## R4 — Native macOS app and packaging

- [ ] Update plist display/name/version branding, icon reference and bundle identity; preserve copyright and Retina capability.
- [ ] Update app directory, DMG/volume names and all packaging inputs to TidyVNC.
- [ ] Make packaging depend on required compiled translations and icon assets.
- [ ] Build from a fresh `build/tidyvnc-release` directory without borrowing stale generated resources.
- [ ] Stage `TidyVNC.app` and produce `TidyVNC-<version>.dmg` from the same binary.
- [ ] Validate plist, embedded ICNS, locale resources and executable identity/version output.
- [ ] Test new bundle identity, applicable file-open associations and input/accessibility permission behavior.
- [ ] Review Finder, Dock, app switcher, app menus, About and all dialogs for TidyVNC text/artwork.
- [ ] Review normal/error paths, grabbed-keyboard titles, file import/save and translated UI in the packaged app.
- [ ] Inspect actual 1×/2× icon selection and carry forward fractional/mixed-display checks; record unavailable tests explicitly.
- [ ] Verify side-by-side behavior with upstream without changing its settings or deleting its application.
- [ ] Inspect the DMG contents and verify its checksum; document local dependency/deployment/signing limitations.

## R5 — Other platform branding (later rollout)

- [ ] Windows: update resource product fields/captions, manifests, installer text, shortcuts, icons and artifact names.
- [ ] Windows: distinguish truthful publisher identity from preserved copyright/legal attribution.
- [ ] Windows: establish a distinct installer identity and validate install/uninstall coexistence and file associations.
- [ ] Windows: migrate registry/app-data settings and coordinate service/event/IPC names without breaking server control.
- [ ] Windows: inspect packaged application/tray icons at 100/125/150/200% scale.
- [ ] Linux: update desktop file, icon stem, AppStream ID/launchable reference, descriptions and current URLs.
- [ ] Linux: replace active screenshots and separate upstream release history from TidyVNC release claims.
- [ ] Packaging: update Debian/RPM names, spec/script filenames, source archives, container tags and CI globs together.
- [ ] Packaging: validate alternatives, installed-path collisions and Provides/Replaces/Conflicts without rewriting historical maintainers/changelogs.
- [ ] Servers: coordinate system configuration, PAM, systemd, SELinux and logs while retaining appropriate external protocol interfaces.
- [ ] Servers: rebrand visible banners/manuals and verify renamed packaging patches still apply.
- [ ] Java: update UI, manifest Application-Name, banners, docs, asset names and resource loaders.
- [ ] Java: retain and document `com.tigervnc` namespaces/Main-Class as compatibility exceptions; preserve bundled third-party notices.
- [ ] Java: implement new state/import behavior and verify high-density icon loading on the supported runtime before shipping that flavor.
- [ ] Run each platform's build/package/branding checks when it becomes available; retain explicit deferred status until then.

## R6 — Documentation, support and delivery

- [ ] Rewrite current README introduction as TidyVNC, explicitly a fork of TigerVNC; preserve upstream history and acknowledgments.
- [ ] Update current build/install instructions, manuals, CLI examples and downloadable artifact references.
- [ ] Add current TidyVNC instructions to `BUILD-MACOS.md` without changing historical measured outputs or checkout paths.
- [ ] Cross-link scaling/HiDPI plans and record rebrand status without rewriting their historical evidence.
- [ ] Update issue templates, translation bug-report routing and active support links to actual fork facilities.
- [ ] Update CI artifact globs, container names and generated package identities without fabricating maintainer credentials.
- [ ] Audit external hosting description, social artwork and support settings as separately tracked delivery tasks; do not assume Git edits update them.
- [ ] Document legacy import, remaining name exceptions, per-platform completion and migration limitations.

## R7 — Acceptance and regression gates

- [ ] Add the source/path audit and reviewed exception list; fail on unexplained old-brand additions and stale asset references.
- [ ] Review the combined diff for unchanged licenses, copyright, authors, translator credits and upstream history.
- [ ] Validate active compiled translations and resource domains in packaged products, not only source catalogs.
- [ ] Run settings migration, configuration format and build-option compatibility tests.
- [ ] Build fresh native Debug and Release configurations and verify viewer-off still configures/builds.
- [ ] Run the existing unit suite plus new rebrand tests without relying on a fixed historical count.
- [ ] Run the existing loopback RFB smoke suite against the packaged rebranded binary.
- [ ] Scan fresh artifacts and review remaining binary-text matches as legal/history/compatibility cases rather than requiring zero matches.
- [ ] Complete asset-container checks and human visual review; verify no active shipped tiger-eye graphics remain.
- [ ] Record artifact, platform, locale, density, outcome and evidence for all validation claims.
- [ ] Mark the macOS milestone complete only after its actual text/artwork/migration/package gates pass.
- [ ] Mark repository-wide rebranding complete only after all shipped flavors and inventory entries are resolved; deferred work stays open.

## Evidence log

### 2026-09-18 — Planning only

- Inspected native UI, configuration/state, common directory helpers, gettext,
  macOS/Windows/Linux packaging, CI, Java branding and source asset rules.
- Visually confirmed tiger-eye artwork in native and Java PNG resources.
- Confirmed `origin` points to `https://github.com/jkeli/tidyvnc.git`.
- Recorded current macOS-first scope and later platform branding passes.
- No branding code, icons, persistent settings or packaging behavior changed.

### Implementation evidence template

- Phase / checklist item:
- Commit or diff:
- Artifact / build configuration:
- Platform, locale and display density:
- Commands / checks and outcome:
- Visual evidence and attribution/compatibility review:
- Remaining limitations or deferred follow-up:

### 2026-09-18 — R0 baseline

- Inventoried 1,212 tracked paths and 3,369 old-brand text matches; exact occurrence
  ledger distinguishes unresolved replacements/migrations from preservation.
- Recorded license hashes and copyright lines before editing. Mixed legal/product
  lines and final exception review remain open.
- Verified GitHub API: jkeli/tidyvnc, issues enabled; adopted
  io.github.jkeli.tidyvnc and the factual jkeli/tidyvnc project identity.
- Windows artwork and screenshot visual classification remains open.

### 2026-09-18 — R1 native identity and catalogs

- Native menus, session/options titles, diagnostics and About identify TidyVNC;
  About preserves the original copyright and explicitly credits upstream.
- Renamed private guards/Cocoa observer/FLTK target and project names; public
  TIDYVNC_FLTK_SHARED has a deprecated alias with conflict detection. Seven
  standalone option tests passed. X server public options remain deferred.
- Renamed gettext domain/POT and every MO staging/install reference together.
  Regenerated POT, merged all 40 PO catalogs, checked msgfmt/accelerators.
  Simple native labels retain translations; changed combined About text stays
  fuzzy (English fallback) until translator review, preserving legal translations.
  Existing Italian header warnings remain; translated GUI review remains open.
- Fresh arm64 Release build (static FLTK 1.4.5, gettext, TLS, RSA-AES) passed;
  all 293 unit tests passed in 14.37 seconds. Viewer-off configuration passed.
- File labels/state migration and artwork are subsequent commits.
