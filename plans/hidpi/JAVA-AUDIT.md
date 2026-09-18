# Java HiDPI audit: remaining work

Inspected 2026-09-17. No Java implementation changes have been made in this
native implementation pass. H7 remains open; this file records concrete
integration points so native progress is not confused with Java parity.

The existing CI builds Temurin 8, 11, 17 and 21 on Ubuntu. This is a compiler
matrix, not a Windows/macOS/Linux HiDPI runtime matrix. Keep the Java 8 source
floor until an explicit runtime compatibility decision is made.

- `Viewport.paintComponent()` uses Graphics2D and a BufferedImage. The default
  GraphicsConfiguration transform must be included when computing a final
  backing raster; do not multiply an already scaled Graphics2D context twice.
- `Viewport.setScaledSize()` currently parses integer percentages or the two
  legacy fit strings, and RemoteResize takes precedence. Replace this with
  typed settings and the same Logical/Device contract as native.
- `Viewport` stores integer scaledWidth/scaledHeight and float scale ratios.
  Component enclosure must be separated from fractional logical image extent.
  Pointer inverse mapping and damage bounds must use the same snapshot.
- `OptionsDialog` strips all percent signs before serialization. That would
  corrupt independent-percentage syntax; replace it with canonical parsing.
  Its remote-resize callback currently disables scaling controls.
- `DesktopWindow` contains several integer-regex decisions for resize/zoom.
  Audit each when adding the other modes and density transitions.
- Cursor sizing uses Toolkit native cursor limits, integer dimensions and
  separately scaled hotspots. Test on each supported JDK/OS, and provide a
  software fallback when native cursor APIs cannot represent the transform.
- Robot warps, monitor bounds and fullscreen border assumptions require
  platform tests. GraphicsConfiguration coordinates are not automatically
  interchangeable with native screen pixels.

`tests/fixtures/desktop-scaling.tsv` contains language-neutral expected backing
sizes. Native tests consume it now. Add a Java 8-compatible headless harness
that consumes the same file, validates serialization/input geometry, and tests
premultiplied filtered images with documented tolerances. Wire it into CTest
and all supported-JDK CI jobs, separately from manual GUI/DPI testing.
