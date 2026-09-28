#!/usr/bin/env python3
"""Inspect a packaged or mounted-DMG native app, without launching its UI."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("native_package", root / "apps/macos/package.py")
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)


def check(app, source, report):
    app, source = app.resolve(), source.resolve()
    saved = json.loads(report.read_text())
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    original = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    expected = dict(original, LSMinimumSystemVersion=saved["packageMinimumOS"])
    if info != expected:
        raise pkg.PackageError("Package metadata differs beyond the explicitly selected deployment floor")
    if info.get("CFBundleIdentifier") != "io.github.jkeli.tidyvnc" or info.get("CFBundleExecutable") != "vncviewer":
        raise pkg.PackageError("Incorrect native bundle identity")
    if not info.get("NSLocalNetworkUsageDescription") or info["CFBundleDocumentTypes"][0]["CFBundleTypeExtensions"] != ["tidyvnc"]:
        raise pkg.PackageError("Missing privacy/document metadata")
    actual = pkg.audit(app, saved["packageMinimumOS"], saved["architecture"])
    if actual != saved["binaries"]:
        raise pkg.PackageError("Package binaries differ from the verified assembly report")
    for path in (source / "Contents/Resources").rglob("*"):
        if path.is_file():
            packaged = app / path.relative_to(source)
            if not packaged.is_file() or pkg.digest(path) != pkg.digest(packaged):
                raise pkg.PackageError(f"Application resource changed: {path.relative_to(source)}")
    manifest = json.loads((app / "Contents/Resources/NativePackage.json").read_text())
    for key, value in manifest.items():
        if saved.get(key) != value:
            raise pkg.PackageError(f"Sealed package manifest mismatch: {key}")
    third_party = app / "Contents/Resources/ThirdParty"
    if saved["dependencies"] and not (third_party / "README.txt").is_file():
        raise pkg.PackageError("Missing third-party README")
    for dependency in saved["dependencies"]:
        directory = third_party / dependency["name"]
        if dependency["linkage"] != "static" or not dependency["notices"]:
            raise pkg.PackageError(f"Dependency {dependency['name']} is not static or has no licence text")
        for name, expected_hash in dependency["notices"].items():
            if pkg.digest(directory / name) != expected_hash:
                raise pkg.PackageError(f"Dependency notice changed: {name}")
    pkg.run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    signature = pkg.run("/usr/bin/codesign", "-dvv", app).stderr
    if "Identifier=io.github.jkeli.tidyvnc" not in signature or "Sealed Resources=none" in signature:
        raise pkg.PackageError("Missing bundle signing identity or resource seal")
    flags = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", signature)
    if not flags or "runtime" not in flags.group(1).split(","):
        raise pkg.PackageError("The app is not signed with the hardened runtime")
    signed = pkg.run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app).stdout
    if (plistlib.loads(signed.encode()) if signed.strip() else {}) != saved["entitlements"]:
        raise pkg.PackageError("Signed entitlements differ from the verified assembly report")
    if saved["notarized"]:
        pkg.run("/usr/bin/xcrun", "stapler", "validate", app)
        pkg.gatekeeper("--type", "execute", app)
    # Symbol check supplements the build graph and dependency-name checks.
    for record in actual:
        symbols = pkg.run("/usr/bin/nm", "-u", app / record["path"]).stdout
        if any(marker in symbols for marker in ("_fltk", "_ZN2Fl", "_ZN9Fl_Window", "_fl_open_display")):
            raise pkg.PackageError(f"FLTK symbol in {record['path']}")
    subprocess.run([sys.executable, str(root / "tests/macos/invocation-terminal.py"), "--app", str(app)], check=True)
    print(f"PASS native package: {len(actual)} binaries, {len(saved['dependencies'])} static libraries with notices; "
          "closed dependencies, resources/notices, identity, signature, symbols and CLI")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    artifact = parser.add_mutually_exclusive_group(required=True)
    artifact.add_argument("--app", type=Path)
    artifact.add_argument("--dmg", type=Path, help="Mount read-only, inspect the contained app, then detach")
    parser.add_argument("--source-app", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.app:
        check(args.app, args.source_app, args.report)
    else:
        saved = json.loads(args.report.read_text())
        if pkg.digest(args.dmg) != saved["diskImage"]["sha256"]:
            raise pkg.PackageError("Disk image differs from the verified assembly report")
        pkg.run("/usr/bin/hdiutil", "verify", args.dmg)
        if saved["notarized"]:
            pkg.run("/usr/bin/xcrun", "stapler", "validate", args.dmg)
            pkg.gatekeeper("--type", "open", "--context", "context:primary-signature", args.dmg)
        with tempfile.TemporaryDirectory(prefix="tidyvnc-dmg-inspect-") as temporary:
            mount = Path(temporary) / "mounted"
            mount.mkdir()
            pkg.run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                    "-mountpoint", mount, args.dmg)
            try:
                check(mount / "TidyVNC.app", args.source_app, args.report)
                for name in ("README.rst", "LICENCE.TXT"):
                    if pkg.digest(mount / name) != pkg.digest(args.source_app / "Contents/Resources" / name):
                        raise pkg.PackageError(f"Disk image resource mismatch: {name}")
                if not (mount / "Applications").is_symlink() or (mount / "Applications").readlink() != Path("/Applications"):
                    raise pkg.PackageError("Missing Applications install link")
            finally:
                pkg.run("/usr/bin/hdiutil", "detach", mount)
        print("PASS read-only mounted disk image; detached after inspection")
