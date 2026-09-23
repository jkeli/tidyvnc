#!/usr/bin/env python3
"""Compare compiled Swift localization call sites with the English UI catalog.

Run after the native app build. Each --module pairs CMake's source manifest with
the directory containing that module's compiler-emitted .stringsdata records.
This checks annotated localization APIs, not arbitrary dynamic UI text or layout.
"""
import argparse
import hashlib
import json
from pathlib import Path


def source_paths(manifest):
    expected = {Path(line).resolve() for line in manifest.read_text().splitlines() if line}
    if not expected:
        raise ValueError(f"Empty source manifest: {manifest}")
    missing = [str(path) for path in expected if not path.is_file()]
    if missing:
        raise ValueError(f"Missing manifest sources: {missing}")
    return expected


def records_for(directory, expected):
    for path in sorted(directory.rglob("*.stringsdata")):
        record = json.loads(path.read_text())
        source = Path(record.get("source", "")).resolve()
        if source in expected:
            yield path, record, source


def build_contents(manifest, directory):
    expected = source_paths(manifest)
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    return {"version": 1, "sources": {str(path): digest(path) for path in sorted(expected)},
            "records": {str(path.resolve()): digest(path) for path, _, _ in records_for(directory, expected)}}


def record_build(manifest, directory):
    # Called by the successful target's POST_BUILD command. Swift intentionally
    # retains byte-identical .stringsdata files; their mtime is not compile proof.
    receipt = manifest.with_suffix(".built.json")
    receipt.write_text(json.dumps(build_contents(manifest, directory), indent=2) + "\n")


def audit(catalog_path, modules):
    catalog = json.loads(catalog_path.read_text())
    if catalog.get("sourceLanguage") != "en":
        raise ValueError("Expected the English source catalog")
    strings = catalog["strings"]
    errors, observed, sources, sites = [], set(), set(), set()
    for manifest, directory in modules:
        expected = source_paths(manifest)
        receipt = manifest.with_suffix(".built.json")
        if not receipt.is_file():
            errors.append(f"Missing completed build receipt: {manifest}; rebuild the app")
        elif json.loads(receipt.read_text()) != build_contents(manifest, directory):
            errors.append(f"Stale completed build receipt: {manifest}; sources or records changed; rebuild the app")
        found = set()
        for path, record, source in records_for(directory, expected):
            # Ignore old files removed from the target and generated App Shortcuts
            # metadata. Only the current CMake source lists define this audit.
            if record.get("version") != 1:
                raise ValueError(f"Unsupported Swift localization record: {path}")
            found.add(source)
            for table, entries in record["tables"].items():
                if table != "Localizable":
                    errors.append(f"Unexpected localization table {table}: {source}")
                    continue
                for entry in entries:
                    key = entry["key"]
                    value = entry.get("value", key)
                    # Empty placeholder titles have no translatable content.
                    # Their separate accessibility labels require UI review.
                    if not key and not value:
                        continue
                    # Swift omits locations for some synthesized/default-value
                    # expressions, while still recording their key and value.
                    location = entry.get("location", {})
                    position = f"{source}:{location.get('startingLine', '?')}:{location.get('startingColumn', '?')}"
                    sites.add((position, key, value))
                    observed.add(key)
                    if key not in strings:
                        errors.append(f"Missing catalog key {key!r} at {position}")
                        continue
                    unit = strings[key]["localizations"]["en"]["stringUnit"]
                    if unit["value"] != value:
                        errors.append(f"Default mismatch {key!r} at {position}:\n"
                                      f"  Swift: {value!r}\n  Catalog: {unit['value']!r}")
        for source in sorted(expected - found):
            errors.append(f"Missing current compiler record: {source}")
        sources.update(expected)
    for key in sorted(strings.keys() - observed):
        errors.append(f"Catalog key has no compiled call site: {key!r}")
    return sorted(set(errors)), len(sources), len(sites), len(observed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path, nargs="?")
    parser.add_argument("--record-build", nargs=2, type=Path, metavar=("SOURCES", "RECORDS"),
                        help="Record source/record hashes after successful target compilation")
    parser.add_argument("--module", nargs=2, action="append",
                        type=Path, metavar=("SOURCES", "RECORDS"))
    args = parser.parse_args()
    if args.record_build:
        if args.catalog or args.module:
            parser.error("--record-build cannot be combined with an audit")
        record_build(*args.record_build)
        return
    if not args.catalog or not args.module:
        parser.error("an audit requires a catalog and at least one --module")
    errors, sources, sites, keys = audit(args.catalog, args.module)
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"PASS {sources} Swift sources, {sites} localization call sites, {keys} catalog keys; "
          "complete compiler records and matching English defaults/interpolation formats")


if __name__ == "__main__":
    main()
