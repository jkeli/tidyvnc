# Rebrand inventory

> Historical inventory: the Java viewer and its bundled dependencies were
> removed on 2026-09-18 when TidyVNC became native only. Java entries below
> describe the original baseline, not current files or remaining rollout work.


Canonical identity: **TidyVNC**, `tidyvnc`, `TIDYVNC`. Generic binaries remain
`vncviewer`, `vncpasswd`, `Xvnc`, etc. Application ID: `io.github.jkeli.tidyvnc`.
Publisher description: `jkeli/tidyvnc project` (repository identity, not a legal
company or signing identity). GitHub API checked 2026-09-18: owner `jkeli`,
`has_issues=true`; support: https://github.com/jkeli/tidyvnc/issues.

Artwork direction: original paired remote displays with a connecting link,
navy/teal palette, no tiger shapes. Editable SVG, GPL-2.0-or-later; record actual
creation and export tooling in media/README.md. Outputs: 16–1024 PNG, full
1×/2× ICNS, multiresolution ICO and scalable Linux icon.

The exact occurrence ledger is `tests/fixtures/rebrand-exceptions.json`.
Each entry identifies a path and exact text (or path-only occurrence), a count,
disposition and reason. Replace/migrate entries are unresolved work, never
completion exceptions. Initial classification is conservative; mixed legal and
product lines require review when edited. `rebrand-attribution.json` snapshots
license hashes and copyright lines before implementation.

## Consumers, migration dependencies and validation

| Group | Consumers / dependency | Validation |
| --- | --- | --- |
| Native UI and private symbols | FLTK viewer, Cocoa bridge; R1 | Fresh Debug/Release, GUI review |
| Catalogs | All gettext callers, staging, installers; R1 | Extraction, merge, msgfmt and packaged MO |
| Settings | Viewer, shared core helpers, registry, Java; R2 | Isolated new/legacy tests, no fallback writes |
| Artwork | Native, Java, Windows, Linux; R3 | Dimensions, container slots, visual review |
| macOS | plist, DMG, build outputs; R4 | Staged app and mounted DMG |
| Windows/Linux/server/Java | Packaging, PAM/systemd/SELinux, IPC; R5 deferred | Platform builds and coexistence tests required |
| Docs/CI | Current instructions versus historical evidence; R6 | Artifact/link consistency |
| X extension / Java packages | External clients, class loaders | Keep established wire/package names; no branding-only rename |

Windows registry (`Software\\TigerVNC`), Java `Preferences` node, XDG roots and
`.vnc` fallback are separate migration interfaces. Existing shared server paths
must remain stable until their platform rollout. New viewer destinations must
not inherit the legacy write fallback.

Binary inventory includes all tracked ICO/BMP/ICNS/PNG/JPG/SVG resources. Visual
classification is recorded separately as it is performed; text classification
does not establish whether a bitmap contains branding.

## Initial per-file occurrence groups

Counts below include branded paths. Exact strings and reasons are in the ledger.

| Path | Dispositions (occurrences) |
| --- | --- |
| `.github/ISSUE_TEMPLATE/bug_report.md` | replace: 2 |
| `.github/ISSUE_TEMPLATE/config.yml` | migrate: 2, replace: 2 |
| `.github/containers/jammy/build.sh` | migrate: 6, replace: 4 |
| `.github/containers/noble/build.sh` | migrate: 6, replace: 4 |
| `.github/containers/resolute/build.sh` | migrate: 6, replace: 4 |
| `.github/containers/rocky10/build.sh` | migrate: 5, replace: 1 |
| `.github/containers/rocky8/build.sh` | migrate: 5, replace: 1 |
| `.github/containers/rocky9/build.sh` | migrate: 5, replace: 1 |
| `.github/workflows/build.yml` | migrate: 3, replace: 2 |
| `BUILD-MACOS.md` | preserve-history: 19 |
| `BUILDING.txt` | replace: 31, migrate: 1 |
| `CMakeLists.txt` | replace: 10, migrate: 2 |
| `README.rst` | replace: 11, preserve-attribution: 1 |
| `cmake/FLTK/CMakeLists.txt` | replace: 1 |
| `cmake/Modules/CMakeMacroLibtoolFile.cmake` | replace: 1 |
| `common/core/Exception.cxx` | preserve-attribution: 1 |
| `common/core/Exception.h` | preserve-attribution: 1 |
| `common/core/Logger_syslog.cxx` | preserve-attribution: 1 |
| `common/core/Logger_syslog.h` | preserve-attribution: 1 |
| `common/core/i18n.h` | replace: 1 |
| `common/core/xdgdirs.cxx` | migrate: 2, replace: 2 |
| `common/core/xdgdirs.h` | migrate: 6, replace: 3 |
| `common/rdr/TLSException.cxx` | preserve-attribution: 1 |
| `common/rdr/TLSException.h` | preserve-attribution: 1 |
| `common/rdr/TLSInStream.cxx` | preserve-attribution: 1 |
| `common/rdr/TLSInStream.h` | preserve-attribution: 1 |
| `common/rdr/TLSOutStream.cxx` | preserve-attribution: 1 |
| `common/rdr/TLSOutStream.h` | preserve-attribution: 1 |
| `common/rdr/TLSSocket.cxx` | preserve-attribution: 1 |
| `common/rdr/TLSSocket.h` | preserve-attribution: 1 |
| `common/rfb/AccessRights.cxx` | preserve-attribution: 1 |
| `common/rfb/AccessRights.h` | preserve-attribution: 1 |
| `common/rfb/CSecurityPlain.cxx` | preserve-attribution: 1 |
| `common/rfb/CSecurityPlain.h` | preserve-attribution: 1 |
| `common/rfb/CSecurityStack.cxx` | preserve-attribution: 1 |
| `common/rfb/CSecurityStack.h` | preserve-attribution: 1 |
| `common/rfb/CSecurityTLS.cxx` | preserve-attribution: 1 |
| `common/rfb/CSecurityTLS.h` | preserve-attribution: 1 |
| `common/rfb/CSecurityVeNCrypt.cxx` | preserve-attribution: 1 |
| `common/rfb/CSecurityVeNCrypt.h` | preserve-attribution: 1 |
| `common/rfb/SSecurityPlain.h` | preserve-attribution: 1 |
| `common/rfb/SSecurityStack.h` | preserve-attribution: 1 |
| `common/rfb/SSecurityTLS.cxx` | preserve-attribution: 1 |
| `common/rfb/SSecurityTLS.h` | preserve-attribution: 1 |
| `common/rfb/SSecurityVeNCrypt.cxx` | preserve-attribution: 1 |
| `common/rfb/SSecurityVeNCrypt.h` | preserve-attribution: 1 |
| `common/rfb/Security.cxx` | preserve-attribution: 1 |
| `common/rfb/SecurityClient.cxx` | preserve-attribution: 1 |
| `common/rfb/SecurityServer.cxx` | preserve-attribution: 1 |
| `common/rfb/SecurityServer.h` | preserve-attribution: 1 |
| `common/rfb/TightDecoder.cxx` | replace: 1 |
| `common/rfb/UnixPasswordValidator.cxx` | preserve-attribution: 1 |
| `common/rfb/UnixPasswordValidator.h` | preserve-attribution: 1 |
| `common/rfb/WinPasswdValidator.cxx` | preserve-attribution: 1 |
| `common/rfb/WinPasswdValidator.h` | preserve-attribution: 1 |
| `contrib/packages/deb/ubuntu-jammy/debian/changelog` | preserve-history: 1 |
| `contrib/packages/deb/ubuntu-jammy/debian/control` | replace: 33 |
| `contrib/packages/deb/ubuntu-jammy/debian/copyright` | replace: 3, preserve-attribution: 1 |
| `contrib/packages/deb/ubuntu-jammy/debian/rules` | replace: 14, migrate: 52 |
| `contrib/packages/deb/ubuntu-jammy/debian/tigervncserver.postinst.in` | migrate: 8, replace: 9 |
| `contrib/packages/deb/ubuntu-jammy/debian/tigervncserver.prerm` | migrate: 3, replace: 4 |
| `contrib/packages/deb/ubuntu-jammy/debian/xorg-source-patches/516_tigervnc-xorg-manpages.patch` | replace: 1 |
| `contrib/packages/deb/ubuntu-jammy/debian/xtigervncviewer.menu` | replace: 4 |
| `contrib/packages/deb/ubuntu-jammy/debian/xtigervncviewer.postinst` | replace: 5 |
| `contrib/packages/deb/ubuntu-jammy/debian/xtigervncviewer.prerm` | replace: 2 |
| `contrib/packages/deb/ubuntu-noble/debian/changelog` | preserve-history: 1 |
| `contrib/packages/deb/ubuntu-noble/debian/control` | replace: 33 |
| `contrib/packages/deb/ubuntu-noble/debian/copyright` | replace: 3, preserve-attribution: 1 |
| `contrib/packages/deb/ubuntu-noble/debian/rules` | replace: 14, migrate: 52 |
| `contrib/packages/deb/ubuntu-noble/debian/tigervncserver.postinst.in` | migrate: 8, replace: 9 |
| `contrib/packages/deb/ubuntu-noble/debian/tigervncserver.prerm` | migrate: 3, replace: 4 |
| `contrib/packages/deb/ubuntu-noble/debian/xorg-source-patches/516_tigervnc-xorg-manpages.patch` | replace: 1 |
| `contrib/packages/deb/ubuntu-noble/debian/xtigervncviewer.menu` | replace: 4 |
| `contrib/packages/deb/ubuntu-noble/debian/xtigervncviewer.postinst` | replace: 5 |
| `contrib/packages/deb/ubuntu-noble/debian/xtigervncviewer.prerm` | replace: 2 |
| `contrib/packages/deb/ubuntu-resolute/debian/changelog` | preserve-history: 1 |
| `contrib/packages/deb/ubuntu-resolute/debian/control` | replace: 33 |
| `contrib/packages/deb/ubuntu-resolute/debian/copyright` | replace: 3, preserve-attribution: 1 |
| `contrib/packages/deb/ubuntu-resolute/debian/rules` | replace: 14, migrate: 52 |
| `contrib/packages/deb/ubuntu-resolute/debian/tigervncserver.postinst.in` | migrate: 8, replace: 9 |
| `contrib/packages/deb/ubuntu-resolute/debian/tigervncserver.prerm` | migrate: 3, replace: 4 |
| `contrib/packages/deb/ubuntu-resolute/debian/xorg-source-patches/516_tigervnc-xorg-manpages.patch` | replace: 1 |
| `contrib/packages/deb/ubuntu-resolute/debian/xtigervncviewer.menu` | replace: 4 |
| `contrib/packages/deb/ubuntu-resolute/debian/xtigervncviewer.postinst` | replace: 5 |
| `contrib/packages/deb/ubuntu-resolute/debian/xtigervncviewer.prerm` | replace: 2 |
| `contrib/packages/rpm/el10/SPECS/tigervnc.spec` | replace: 65, migrate: 4 |
| `contrib/packages/rpm/el8/SOURCES/10-libvnc.conf` | replace: 1, migrate: 1 |
| `contrib/packages/rpm/el8/SPECS/tigervnc.spec` | replace: 65, migrate: 4 |
| `contrib/packages/rpm/el9/SOURCES/10-libvnc.conf` | replace: 1, migrate: 1 |
| `contrib/packages/rpm/el9/SPECS/tigervnc.spec` | replace: 67, migrate: 4 |
| `doc/keyboard-test.txt` | replace: 1 |
| `java/CMakeLists.txt` | replace: 3, migrate: 11 |
| `java/cmake/SignJar.cmake` | replace: 9, migrate: 1 |
| `java/com/tigervnc/network/FileDescriptor.java` | retain-interface: 3 |
| `java/com/tigervnc/network/SSLEngineManager.java` | retain-interface: 5 |
| `java/com/tigervnc/network/Socket.java` | retain-interface: 3 |
| `java/com/tigervnc/network/SocketDescriptor.java` | retain-interface: 3 |
| `java/com/tigervnc/network/SocketException.java` | retain-interface: 3 |
| `java/com/tigervnc/network/SocketListener.java` | retain-interface: 2 |
| `java/com/tigervnc/network/TcpListener.java` | retain-interface: 2 |
| `java/com/tigervnc/network/TcpSocket.java` | retain-interface: 7 |
| `java/com/tigervnc/network/UnixSocket.java` | preserve-attribution: 1, retain-interface: 6 |
| `java/com/tigervnc/rdr/AESEAXCipher.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/AESInStream.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/AESOutStream.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/EndOfStream.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/Exception.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/FdInStream.java` | retain-interface: 3 |
| `java/com/tigervnc/rdr/FdInStreamBlockCallback.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/FdOutStream.java` | retain-interface: 3 |
| `java/com/tigervnc/rdr/InStream.java` | retain-interface: 3 |
| `java/com/tigervnc/rdr/MemInStream.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/MemOutStream.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/OutStream.java` | retain-interface: 3 |
| `java/com/tigervnc/rdr/SystemException.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/rdr/TLSException.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/rdr/TLSInStream.java` | preserve-attribution: 1, retain-interface: 3 |
| `java/com/tigervnc/rdr/TLSOutStream.java` | preserve-attribution: 1, retain-interface: 3 |
| `java/com/tigervnc/rdr/TimedOut.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/WarningException.java` | retain-interface: 2 |
| `java/com/tigervnc/rdr/ZlibInStream.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/AliasParameter.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/AuthFailureException.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/BoolParameter.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/CConnection.java` | retain-interface: 4 |
| `java/com/tigervnc/rfb/CMsgHandler.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/CMsgReader.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/CMsgWriter.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/CSecurity.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/CSecurityDH.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/CSecurityIdent.java` | retain-interface: 4 |
| `java/com/tigervnc/rfb/CSecurityMSLogonII.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/CSecurityNone.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/CSecurityPlain.java` | preserve-attribution: 1, retain-interface: 4 |
| `java/com/tigervnc/rfb/CSecurityRSAAES.java` | retain-interface: 4 |
| `java/com/tigervnc/rfb/CSecurityStack.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/rfb/CSecurityTLS.java` | preserve-attribution: 1, retain-interface: 5 |
| `java/com/tigervnc/rfb/CSecurityVeNCrypt.java` | preserve-attribution: 1, retain-interface: 3 |
| `java/com/tigervnc/rfb/CSecurityVncAuth.java` | retain-interface: 4 |
| `java/com/tigervnc/rfb/ClipboardTypes.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Configuration.java` | retain-interface: 3, migrate: 1 |
| `java/com/tigervnc/rfb/ConnFailedException.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/CopyRectDecoder.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/Cursor.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/DecodeManager.java` | retain-interface: 6 |
| `java/com/tigervnc/rfb/Decoder.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/DesCipher.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Encoder.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Encodings.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Exception.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/FullFramePixelBuffer.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Hextile.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/HextileDecoder.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/Hostname.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/IntParameter.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/JpegCompressor.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/JpegDecompressor.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Keysym2ucs.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Keysymdef.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/LedStates.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/LogWriter.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/ManagedPixelBuffer.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/ModifiablePixelBuffer.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/MsgTypes.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/PixelBuffer.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/PixelFormat.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/Point.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/RREDecoder.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/RawDecoder.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/Rect.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Region.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Screen.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/ScreenSet.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/Security.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/rfb/SecurityClient.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/rfb/ServerParams.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/StringParameter.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/TightDecoder.java` | retain-interface: 6 |
| `java/com/tigervnc/rfb/UserMsgBox.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/UserPasswdGetter.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/VncAuth.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/VoidParameter.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/ZRLEDecoder.java` | retain-interface: 3 |
| `java/com/tigervnc/rfb/fenceTypes.java` | retain-interface: 2 |
| `java/com/tigervnc/rfb/screenTypes.java` | retain-interface: 2 |
| `java/com/tigervnc/vncviewer/CConn.java` | retain-interface: 12 |
| `java/com/tigervnc/vncviewer/ClipboardDialog.java` | retain-interface: 4 |
| `java/com/tigervnc/vncviewer/DesktopWindow.java` | retain-interface: 5 |
| `java/com/tigervnc/vncviewer/Dialog.java` | retain-interface: 2 |
| `java/com/tigervnc/vncviewer/ExtProcess.java` | retain-interface: 7 |
| `java/com/tigervnc/vncviewer/FileUtils.java` | retain-interface: 3, replace: 3 |
| `java/com/tigervnc/vncviewer/Fl.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/vncviewer/JavaPixelBuffer.java` | retain-interface: 4 |
| `java/com/tigervnc/vncviewer/KeyMap.java` | retain-interface: 4 |
| `java/com/tigervnc/vncviewer/LICENCE.TXT` | retain-interface: 1 |
| `java/com/tigervnc/vncviewer/MANIFEST.MF` | retain-interface: 2, replace: 1 |
| `java/com/tigervnc/vncviewer/MenuKey.java` | retain-interface: 4 |
| `java/com/tigervnc/vncviewer/MonitorArrangement.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/vncviewer/OptionsDialog.java` | retain-interface: 4, replace: 1 |
| `java/com/tigervnc/vncviewer/Parameters.java` | retain-interface: 4, replace: 1 |
| `java/com/tigervnc/vncviewer/PasswdDialog.java` | retain-interface: 3 |
| `java/com/tigervnc/vncviewer/PlatformPixelBuffer.java` | retain-interface: 4 |
| `java/com/tigervnc/vncviewer/QemuKeyMap.java` | preserve-attribution: 1, retain-interface: 2 |
| `java/com/tigervnc/vncviewer/README` | replace: 6, preserve-attribution: 1, retain-interface: 1 |
| `java/com/tigervnc/vncviewer/ServerDialog.java` | retain-interface: 4, replace: 6, migrate: 2 |
| `java/com/tigervnc/vncviewer/Tunnel.java` | retain-interface: 7, replace: 1 |
| `java/com/tigervnc/vncviewer/UserDialog.java` | retain-interface: 6 |
| `java/com/tigervnc/vncviewer/UserPreferences.java` | retain-interface: 3, replace: 1 |
| `java/com/tigervnc/vncviewer/Viewport.java` | retain-interface: 8, replace: 1 |
| `java/com/tigervnc/vncviewer/VncViewer.java` | retain-interface: 10, replace: 8, preserve-attribution: 1 |
| `java/com/tigervnc/vncviewer/insecure.png` | retain-interface: 1 |
| `java/com/tigervnc/vncviewer/secure.png` | retain-interface: 1 |
| `java/com/tigervnc/vncviewer/tigervnc.ico` | retain-interface: 1 |
| `java/com/tigervnc/vncviewer/tigervnc.png` | retain-interface: 1 |
| `java/com/tigervnc/vncviewer/timestamp.in` | retain-interface: 2 |
| `media/CMakeLists.txt` | migrate: 20 |
| `media/icons/tigervnc.icns` | replace: 1 |
| `media/icons/tigervnc.ico` | replace: 1 |
| `media/icons/tigervnc.svg` | replace: 2 |
| `media/icons/tigervnc_128.png` | replace: 1 |
| `media/icons/tigervnc_16.png` | replace: 1 |
| `media/icons/tigervnc_22.png` | replace: 1 |
| `media/icons/tigervnc_24.png` | replace: 1 |
| `media/icons/tigervnc_32.png` | replace: 1 |
| `media/icons/tigervnc_48.png` | replace: 1 |
| `media/icons/tigervnc_64.png` | replace: 1 |
| `media/tigervnc.svg` | replace: 2 |
| `media/tigervnc_16.svg` | replace: 2 |
| `media/tigervnc_22.svg` | replace: 2 |
| `media/tigervnc_24.svg` | replace: 2 |
| `media/tigervnc_32.svg` | replace: 2 |
| `media/tigervnc_48.svg` | replace: 2 |
| `plans/client-scaling/PLAN.md` | preserve-history: 2 |
| `plans/client-scaling/TODO.md` | preserve-history: 1 |
| `plans/hidpi/TODO.md` | preserve-history: 2 |
| `plans/rebrand/PLAN.md` | preserve-history: 39, preserve-attribution: 3 |
| `plans/rebrand/TODO.md` | preserve-history: 3 |
| `po/CMakeLists.txt` | migrate: 1, replace: 4, preserve-attribution: 1 |
| `po/ar.po` | replace: 54, preserve-attribution: 2 |
| `po/bg.po` | replace: 53, preserve-attribution: 3 |
| `po/cs.po` | replace: 57, preserve-attribution: 3 |
| `po/da.po` | replace: 27, preserve-attribution: 2 |
| `po/de.po` | replace: 53, preserve-attribution: 3 |
| `po/el.po` | replace: 33, preserve-attribution: 3, migrate: 8 |
| `po/eo.po` | preserve-attribution: 2, replace: 28, migrate: 8 |
| `po/es.po` | replace: 55, preserve-attribution: 3 |
| `po/fi.po` | replace: 55, preserve-attribution: 3, migrate: 8 |
| `po/fr.po` | replace: 41, preserve-attribution: 3 |
| `po/fur.po` | replace: 43, preserve-attribution: 3 |
| `po/he.po` | replace: 58, preserve-attribution: 2 |
| `po/hu.po` | replace: 26, preserve-attribution: 3 |
| `po/id.po` | replace: 54, preserve-attribution: 2 |
| `po/it.po` | preserve-attribution: 2, replace: 8, migrate: 181 |
| `po/ka.po` | replace: 54, preserve-attribution: 3 |
| `po/ko.po` | replace: 41, preserve-attribution: 3 |
| `po/nl.po` | replace: 18, preserve-attribution: 3 |
| `po/pl.po` | preserve-attribution: 3, replace: 11, migrate: 181 |
| `po/pt_BR.po` | replace: 26, preserve-attribution: 3 |
| `po/ro.po` | replace: 58, preserve-attribution: 4 |
| `po/ru.po` | replace: 53, preserve-attribution: 3 |
| `po/sk.po` | replace: 55, preserve-attribution: 3 |
| `po/sr.po` | replace: 53, preserve-attribution: 3 |
| `po/sv.po` | replace: 55, preserve-attribution: 3 |
| `po/tigervnc.pot` | preserve-attribution: 2, replace: 33 |
| `po/tr.po` | replace: 40, preserve-attribution: 2 |
| `po/uk.po` | replace: 60, preserve-attribution: 2, migrate: 8 |
| `po/vi.po` | replace: 27, preserve-attribution: 2 |
| `po/zh_CN.po` | replace: 54, preserve-attribution: 2 |
| `po/zh_TW.po` | replace: 54, preserve-attribution: 2 |
| `release/CMakeLists.txt` | replace: 5 |
| `release/Info.plist.in` | replace: 5, preserve-attribution: 2 |
| `release/makemacapp.in` | replace: 2, migrate: 2 |
| `release/tigervnc.iss.in` | replace: 10, migrate: 1 |
| `release/winvnc.iss.in` | replace: 10, migrate: 1 |
| `tests/integration/macos-scaling-smoke.py` | preserve-attribution: 1, replace: 1 |
| `tests/integration/rfb-scaling-fixture.py` | preserve-attribution: 1 |
| `tests/perf/CMakeLists.txt` | replace: 1 |
| `tests/perf/encperf.cxx` | replace: 1 |
| `tests/perf/scalingperf.cxx` | preserve-attribution: 1 |
| `tests/unit/CMakeLists.txt` | replace: 1 |
| `tests/unit/cursorrenderer.cxx` | preserve-attribution: 1 |
| `tests/unit/desktoplayout.cxx` | preserve-attribution: 1 |
| `tests/unit/desktopresampler.cxx` | preserve-attribution: 1 |
| `tests/unit/desktoptilecache.cxx` | preserve-attribution: 1 |
| `tests/unit/desktoptransform.cxx` | preserve-attribution: 1 |
| `tests/unit/surface.cxx` | preserve-attribution: 1 |
| `unix/vncconfig/vncExt.h` | replace: 1 |
| `unix/vncconfig/vncconfig.cxx` | replace: 1 |
| `unix/vncconfig/vncconfig.man` | replace: 3 |
| `unix/vncpasswd/vncpasswd.cxx` | replace: 1 |
| `unix/vncpasswd/vncpasswd.man` | replace: 3, migrate: 3 |
| `unix/vncserver/CMakeLists.txt` | replace: 1, migrate: 2 |
| `unix/vncserver/HOWTO.md` | replace: 11, migrate: 2 |
| `unix/vncserver/selinux/Makefile` | replace: 1 |
| `unix/vncserver/selinux/vncsession.fc` | migrate: 6 |
| `unix/vncserver/selinux/vncsession.te` | replace: 6 |
| `unix/vncserver/tigervnc.pam` | replace: 1 |
| `unix/vncserver/vncserver-config-defaults` | migrate: 1 |
| `unix/vncserver/vncserver-config-mandatory` | migrate: 1 |
| `unix/vncserver/vncserver.in` | migrate: 3 |
| `unix/vncserver/vncserver.users` | replace: 1 |
| `unix/vncserver/vncserver@.service.in` | migrate: 1 |
| `unix/vncserver/vncsession-start.in` | migrate: 1 |
| `unix/vncserver/vncsession.c` | replace: 1, migrate: 2 |
| `unix/vncserver/vncsession.man.in` | replace: 3, migrate: 18 |
| `unix/w0vncserver/w0vncserver-forget.cxx` | replace: 1 |
| `unix/w0vncserver/w0vncserver-forget.man` | replace: 4, migrate: 1 |
| `unix/w0vncserver/w0vncserver.cxx` | replace: 1 |
| `unix/w0vncserver/w0vncserver.man` | replace: 7 |
| `unix/w0vncserver/wayland/objects/DataControl.cxx` | replace: 4 |
| `unix/x0vncserver/XSelection.cxx` | replace: 4 |
| `unix/x0vncserver/x0vncserver.cxx` | replace: 1 |
| `unix/x0vncserver/x0vncserver.man` | replace: 6 |
| `unix/xserver/hw/vnc/Makefile.am` | replace: 12 |
| `unix/xserver/hw/vnc/Xvnc.man` | replace: 3, migrate: 1 |
| `unix/xserver/hw/vnc/vncInput.c` | replace: 4 |
| `unix/xserver/hw/vnc/vncInput.h` | preserve-attribution: 1 |
| `unix/xserver/hw/vnc/vncModule.c` | replace: 1 |
| `unix/xserver/hw/vnc/xvnc.c` | replace: 3, preserve-attribution: 1 |
| `vncviewer/.gitignore` | replace: 1 |
| `vncviewer/AudioOutputPulse.cxx` | replace: 3 |
| `vncviewer/CMakeLists.txt` | replace: 14, migrate: 2 |
| `vncviewer/CursorRenderer.cxx` | preserve-attribution: 1 |
| `vncviewer/CursorRenderer.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/DesktopLayout.cxx` | preserve-attribution: 1 |
| `vncviewer/DesktopLayout.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/DesktopResampler.cxx` | preserve-attribution: 1 |
| `vncviewer/DesktopResampler.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/DesktopSession.cxx` | preserve-attribution: 1 |
| `vncviewer/DesktopSession.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/DesktopTileCache.cxx` | preserve-attribution: 1 |
| `vncviewer/DesktopTileCache.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/DesktopTransform.cxx` | preserve-attribution: 1 |
| `vncviewer/DesktopTransform.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/DesktopView.cxx` | preserve-attribution: 1 |
| `vncviewer/DesktopView.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/DesktopWindow.cxx` | replace: 2 |
| `vncviewer/DisplayMetrics.cxx` | preserve-attribution: 1 |
| `vncviewer/DisplayMetrics.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/OptionsDialog.cxx` | replace: 1 |
| `vncviewer/ScalingParameter.h` | preserve-attribution: 1, replace: 2 |
| `vncviewer/ServerDialog.cxx` | migrate: 1, replace: 5 |
| `vncviewer/Surface_X11.cxx` | replace: 1 |
| `vncviewer/Viewport.cxx` | replace: 1, preserve-history: 1 |
| `vncviewer/cocoa.mm` | replace: 4 |
| `vncviewer/metainfo/tigervnc-connection-linux.jpg` | replace: 1 |
| `vncviewer/metainfo/tigervnc-connection-macos.jpg` | replace: 1 |
| `vncviewer/metainfo/tigervnc-connection-windows.jpg` | replace: 1 |
| `vncviewer/org.tigervnc.vncviewer.metainfo.xml.in` | replace: 12, migrate: 13 |
| `vncviewer/parameters.cxx` | migrate: 7 |
| `vncviewer/vncviewer.cxx` | replace: 12, preserve-attribution: 1, migrate: 1 |
| `vncviewer/vncviewer.desktop.in.in` | replace: 2 |
| `vncviewer/vncviewer.man` | replace: 11, migrate: 15 |
| `vncviewer/vncviewer.rc.in` | replace: 4, preserve-attribution: 1, migrate: 1 |
| `win/rfb_win32/SecurityPage.cxx` | preserve-attribution: 1 |
| `win/rfb_win32/SecurityPage.h` | preserve-attribution: 1 |
| `win/rfb_win32/Service.cxx` | replace: 1 |
| `win/rfb_win32/resource.h` | preserve-attribution: 1 |
| `win/vncconfig/vncconfig.cxx` | replace: 1, migrate: 2 |
| `win/vncconfig/vncconfig.exe.manifest` | replace: 1 |
| `win/vncconfig/vncconfig.exe.manifest64` | replace: 1 |
| `win/vncconfig/vncconfig.rc` | replace: 8, preserve-attribution: 1 |
| `win/winvnc/VNCServerService.cxx` | replace: 3 |
| `win/winvnc/VNCServerWin32.cxx` | migrate: 1, replace: 1 |
| `win/winvnc/winvnc.cxx` | replace: 3 |
| `win/winvnc/winvnc.rc` | replace: 6, preserve-attribution: 1 |
| `win/winvnc/winvnc4.exe.manifest` | replace: 1 |
| `win/winvnc/winvnc4.exe.manifest64` | replace: 1 |
| `win/wm_hooks/wm_hooks.rc` | replace: 4, preserve-attribution: 1 |

## Visual classification (2026-09-18)

Inspected a contact sheet of all Windows ICO/BMP files, all three AppStream
screenshots, native/Java app icons and Java padlocks. Every Windows ICO and
`winvnc.bmp` depicts the tiger eye; tray variants distinguish states with colored
borders. All three screenshots show the legacy application, icon and dialogs;
they are unsuitable as TidyVNC product screenshots. Native and Java app icons
are tiger-eye duplicates. Java secure/insecure images are generic padlocks and
can be retained. Native padlock SVGs and vector-drawn authentication controls
are unbranded. Deferred Windows/Java outputs remain tracked until their rollout.

## Current ledger status

The initial per-file table above is baseline evidence, not a current completion
claim. The exact ledger has been reconciled after native migration and artwork
replacement. `python3 tests/rebrand/audit.py` checks every current tracked text
and path occurrence and reports deferred debt separately; CI also checks
original license bodies, source attribution and translated legal strings.

Deferred product/state occurrences belong to Windows resources/registry, Linux
AppStream/server/package integration, Java product text/preferences, and their
shared or fuzzy gettext messages. No directory-wide exemption is used. Platform
rollout must replace these entries with tested changes or individually justified
preservation; do not mark repository completion while this debt remains.
