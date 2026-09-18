# TidyVNC artwork

The paired remote displays and connection line are original SVG artwork created
with OpenAI Codex for the `jkeli/tidyvnc` project on 2026-09-18. The mark was drawn
as vector geometry; it is not derived from the upstream tiger eye. Source and
exports are licensed GPL-2.0-or-later, like this repository. No trademark or legal
publisher identity is asserted. The original upstream artwork remains available
in Git history; its authorship is not reassigned to this project.

Palette: navy `#142f43`, teal `#51d9ca`, white `#f4fafb`. The navy rounded square
provides contrast on light/dark desktops; two overlapping screens communicate a
remote display. Native padlocks remain unchanged; they are generic security
symbols and retain their existing provenance. Windows state badges use green
for connected and red/slash for disconnected, in addition to shape differences.

`tidyvnc.svg` is the editable master; `tidyvnc-small.svg` provides pixel-aligned
strokes for exports through 24 pixels. Reviewed distribution resources are in
`icons/`; builds do not need graphics tools. All PNG sizes are rendered directly
from vector, including the 1024-pixel ICNS source. Java uses multiple native
window sizes and draws a 256-pixel source into its original 48-pixel logo layout
using Java 8 APIs; runtime validation of the Java flavor remains deferred.

## Reproduce and verify

The reference toolchain is Qt SVG/Gui 6.11.0, Pillow 12.3.0, and macOS `iconutil`.
The renderer needs no display server. All regeneration goes into a build folder:

```sh
cmake -S media/tools -B build/icon-tools -G Ninja -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build build/icon-tools
python3 media/tools/export-icons.py --renderer build/icon-tools/render-svg \
  --output build/icon-export --verify
```

Use a Python environment with Pillow. On this Mac, commands also require
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`. `iconutil` may require access
to macOS image services outside a command sandbox. Missing tools are an error;
there is no low-resolution fallback. `--verify` compares decoded PNG pixels and
ICO/ICNS/SVG bytes. Qt or OS encoder changes may require reviewed regeneration.

Alternatively configure the main build with `TIDYVNC_REGENERATE_ICONS=ON` and the
appropriate `Python3_EXECUTABLE`, then use `icons_regenerate` / `icons_verify`.
Each target declares its sources and writes only to the build tree.

ICNS inputs cover 16, 32, 128, 256, 512 logical pixels at both 1× and 2×. ICO
covers 16, 20, 24, 32, 40, 48, 64, 96, 128, 256 pixels. Linux PNGs cover
16/22/24/32/48/64/128/256/512, with an SVG for scalable lookup. Source pixel
checks do not establish physical multi-display or Windows tray behavior.
