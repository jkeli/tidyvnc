#!/usr/bin/env python3
"""Run the native settings renderer with synthetic expanded UI text.

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
parser.add_argument("--prefix", action="append", help="Catalog prefix to expand (repeatable). Defaults to authentication, credentials, trust, actions, settings, profiles, history, listener, documents, defaults import, app menus/connection, desktop commands, information, endpoint and controller/service recovery errors.")
parser.add_argument("--rtl", action="store_true", help="Mirror the fixture layout; this is not a translated-language acceptance test.")
parser.add_argument("--named-output", action="store_true", help="Run app-style fixture arguments: --verify --output DIRECTORY.")
parser.add_argument("--renderer-arg", action="append", default=[], help="Additional fixture argument (repeatable; use --renderer-arg=--flag).")
args = parser.parse_args()
prefixes = tuple(args.prefix or ["authentication.", "credentials.", "trust.", "action.", "settings.", "profiles.", "history.", "listener.", "document.", "import.defaults.", "app.", "desktop.", "information.", "endpoint.issue.", "import.source.", "connection.recovery.", "clipboard.recovery.", "tunnel.error.", "invocation."])
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
        if key.startswith(prefixes):
            # Append padding instead of repeating a format string: each argument
            # placeholder must still occur exactly once.
            value = "[ " + value + " " + "expanded " * max(1, len(value) // 9) + "]"
        lines.append(json.dumps(key, ensure_ascii=False) + " = " +
                     json.dumps(value, ensure_ascii=False) + ";")
    (resources / "Localizable.strings").write_text("\n".join(lines) + "\n")
    command = [str(executable)] + (["--verify", "--output"] if args.named_output else []) + [str(args.output.resolve())]
    if args.rtl:
        command.append("--rtl")
    command.extend(args.renderer_arg)
    subprocess.run(command, check=True)
