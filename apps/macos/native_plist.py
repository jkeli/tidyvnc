"""Derive native metadata from the release template, retaining one identity."""
import plistlib
import sys
from pathlib import Path

value = plistlib.loads(Path(sys.argv[1]).read_bytes())
value.pop("LSRequiresCarbon", None)
value["CFBundleDevelopmentRegion"] = "en"
value["CFBundleVersion"] = value["CFBundleShortVersionString"]
Path(sys.argv[2]).write_bytes(plistlib.dumps(value))
print(value["CFBundleIdentifier"])
