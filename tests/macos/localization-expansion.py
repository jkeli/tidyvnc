#!/usr/bin/env python3
"""Run the native settings renderer with synthetic expanded authentication text.

This is a temporary test bundle, never a shipping translation. Inspect the PNGs:
the renderer's fitting-size assertions alone cannot detect truncated controls.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("renderer", type=Path)
parser.add_argument("catalog", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
catalog = json.loads(args.catalog.read_text())
assert catalog["sourceLanguage"] == "en"
with tempfile.TemporaryDirectory(prefix="tidyvnc-localization-") as directory:
    contents = Path(directory) / "Expansion.app/Contents"
    executable = contents / "MacOS/render"
    resources = contents / "Resources/en.lproj"
    executable.parent.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(args.renderer.resolve(strict=True), executable)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "test.tidyvnc.localization-expansion",
        "CFBundleExecutable": "render",
        "CFBundleDevelopmentRegion": "en",
    }))
    lines = []
    for key, entry in catalog["strings"].items():
        value = entry["localizations"]["en"]["stringUnit"]["value"]
        if key.startswith(("authentication.", "credentials.", "trust.", "action.")):
            # Append padding instead of repeating a format string: each argument
            # placeholder must still occur exactly once.
            value = "[ " + value + " " + "expanded " * max(1, len(value) // 9) + "]"
        lines.append(json.dumps(key, ensure_ascii=False) + " = " +
                     json.dumps(value, ensure_ascii=False) + ";")
    (resources / "Localizable.strings").write_text("\n".join(lines) + "\n")
    subprocess.run([str(executable), str(args.output.resolve())], check=True)
