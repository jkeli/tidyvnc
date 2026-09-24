# Third-party components of the Windows app

Everything the WinUI app installs besides TidyVNC's own code
(plans/native-ui-winui PACKAGING.md sections 2 and 5). W7.2 copies each
component's licence and notice texts into `ThirdParty\<component>\` in the
payload, and the package audit fails if any shipped binary is not listed here
with a text. Started in W3.1; versions are those pinned by `vcpkg.json`,
`Directory.Packages.props` and `apps/windows/deps.py` (MSYS2 CLANG64 and
CLANGARM64) and recorded in `build/winui/deps/<arch>/deps.json`.

Licence text source: **MSYS2** means `apps/windows/deps.py` copies it from the
package's `share/licenses`. **Repository** means the MSYS2 package ships none, so
this directory keeps the texts the upstream distribution names
(`ThirdParty/<package>/`, with a README.txt saying where each came from);
`deps.py` copies them instead.

## Native libraries (MSYS2, dynamically linked by `tidyvnc_viewer.dll`)

| Component | Version (x64) | Binaries | Licence | Text |
| --- | --- | --- | --- | --- |
| GnuTLS | 3.8.13 | `libgnutls-30.dll` | LGPL-2.1-or-later | Repository |
| Nettle | 4.0 | `libnettle-9.dll`, `libhogweed-7.dll` | LGPL-3.0-or-later or GPL-2.0-or-later | Repository |
| GMP | 6.3.0 | `libgmp-10.dll` | LGPL-3.0-or-later or GPL-2.0-or-later | Repository |
| libtasn1 | 4.21.0 | `libtasn1-6.dll` | LGPL-2.1-or-later | MSYS2 |
| p11-kit | 0.26.5 | `libp11-kit-0.dll` | BSD-3-Clause | Repository |
| libffi | 3.8.0 | `libffi-8.dll` | MIT | MSYS2 |
| libidn2 | 2.3.8 | `libidn2-0.dll` | LGPL-3.0-or-later or GPL-2.0-or-later | Repository |
| libunistring | 1.4.2 | `libunistring-5.dll` | LGPL-3.0-or-later or GPL-2.0-or-later | MSYS2 |
| libiconv | 1.19 | `libiconv-2.dll` | LGPL-2.1-or-later | MSYS2 |
| gettext runtime | 1.0 | `libintl-8.dll` | LGPL-2.1-or-later | MSYS2 |
| Brotli | 1.2.0 | `libbrotlicommon.dll`, `libbrotlidec.dll`, `libbrotlienc.dll` | MIT | MSYS2 |
| Zstandard | 1.5.7 | `libzstd.dll` | BSD-3-Clause | MSYS2 |
| zlib | 1.3.2 | `zlib1.dll` | Zlib | MSYS2 |
| pixman | 0.46.4 | `libpixman-1-0.dll` | MIT | MSYS2 |
| libjpeg-turbo | 3.2.0 | `libjpeg-8.dll` | IJG, BSD-3-Clause, Zlib | MSYS2 |

Not shipped: `libpng16*.dll` and the vcpkg GoogleTest DLLs appear in the
development `bin` directory for tests only; the W7 payload script excludes them.

## .NET and Windows App SDK (NuGet, self-contained)

| Component | Version | Licence |
| --- | --- | --- |
| .NET runtime | 10.0 (SDK 10.0.112) | MIT |
| Windows App SDK (WinUI 3 and runtime) | 1.8.260804001 | MIT |
| CommunityToolkit.Mvvm | 8.4.2 | MIT |
| CommunityToolkit.WinUI.Controls.SettingsControls | 8.2.251219 | MIT (added when W5 uses it) |

Build-time only (not shipped): Microsoft.Windows.CsWin32 (MIT), MSTest (MIT),
FlaUI (MIT), Axe.Windows (MIT), WiX Toolset (MS-RL).
