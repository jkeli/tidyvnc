#!/usr/bin/env python3
"""Audit SwiftUI core/app graphs for FLTK dependencies and Windows-only targets.

Before configuring each directory, create .cmake/api/v1/query/codemodel-v2.
This checks generated targets/compile/link inputs, not CMake source spelling.
"""
import argparse
import json
from pathlib import Path
import re


def inspect(build, required, forbidden):
    reply = build / ".cmake/api/v1/reply"
    indices = list(reply.glob("index-*.json"))
    if not indices:
        raise RuntimeError(f"No CMake File API reply in {build}; request codemodel-v2 and reconfigure")
    index = json.loads(max(indices, key=lambda path: path.stat().st_mtime_ns).read_text())
    model = json.loads((reply / index["reply"]["codemodel-v2"]["jsonFile"]).read_text())
    fltk = re.compile(r"fltk::|(?:^|[/\\])(?:lib)?fltk(?:[-./\\]|$)|[\"<]FL[/\\]", re.I)
    counts = []
    for configuration in model["configurations"]:
        refs = configuration["targets"]
        names = {ref["name"] for ref in refs}
        if required - names:
            raise RuntimeError(f"Missing targets in {build}: {sorted(required - names)}")
        if forbidden & names:
            raise RuntimeError(f"Incompatible targets in {build}: {sorted(forbidden & names)}")
        for ref in refs:
            target = json.loads((reply / ref["jsonFile"]).read_text())
            for field in ("compileGroups", "link", "sources"):
                if fltk.search(json.dumps(target.get(field, {}))):
                    raise RuntimeError(f"FLTK input in {build}/{ref['name']}: {field}")
            if ref["name"] == "vncviewer" and target["type"] != "UTILITY":
                raise RuntimeError("Native vncviewer must delegate app construction to Xcode")
        counts.append(f"{configuration['name']}: {len(refs)} targets")
    print(f"No incompatible targets or FLTK compile/link inputs: {build} ({', '.join(counts)})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("core", type=Path)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    inspect(args.core, {"vncviewer", "macapp", "native-package", "dmg", "tidyvnc_macos_bridge", "tidyvnc_viewer_c",
                        "viewer-core-smoke", "viewer-c-abi-smoke"},
            {"surface", "viewerstate", "fbperf", "utf8paths", "tidyvnc_viewer_shared", "tidyvnc_windows"})
    inspect(args.app, {"TidyVNC"}, {"vncviewer", "surface", "viewerstate", "fbperf"})


if __name__ == "__main__":
    main()
