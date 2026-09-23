#!/usr/bin/env python3
"""Compare compiled Swift localization call sites with the English UI catalog.

Run after the native app build. Each --module pairs CMake's source manifest with
the directory containing that module's compiler-emitted .stringsdata records.
This checks annotated localization APIs, not arbitrary dynamic UI text or layout.
"""
import argparse
import json
from pathlib import Path


def audit(catalog_path, modules):
    catalog = json.loads(catalog_path.read_text())
    if catalog.get("sourceLanguage") != "en":
        raise ValueError("Expected the English source catalog")
    strings = catalog["strings"]
    errors, observed, sources, sites = [], set(), set(), set()
    for manifest, directory in modules:
        expected = {Path(line).resolve() for line in manifest.read_text().splitlines() if line}
        if not expected:
            raise ValueError(f"Empty source manifest: {manifest}")
        missing_files = [str(path) for path in expected if not path.is_file()]
        if missing_files:
            raise ValueError(f"Missing manifest sources: {missing_files}")
        found = set()
        for path in sorted(directory.rglob("*.stringsdata")):
            record = json.loads(path.read_text())
            source = Path(record.get("source", "")).resolve()
            # Ignore old files removed from the target and generated App Shortcuts
            # metadata. Only the current CMake source lists define this audit.
            if source not in expected:
                continue
            if record.get("version") != 1:
                raise ValueError(f"Unsupported Swift localization record: {path}")
            if path.stat().st_mtime_ns < source.stat().st_mtime_ns:
                errors.append(f"Stale compiler record: {source}; rebuild the app")
                continue
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
    parser.add_argument("catalog", type=Path)
    parser.add_argument("--module", nargs=2, action="append", required=True,
                        type=Path, metavar=("SOURCES", "RECORDS"))
    args = parser.parse_args()
    errors, sources, sites, keys = audit(args.catalog, args.module)
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"PASS {sources} Swift sources, {sites} localization call sites, {keys} catalog keys; "
          "complete compiler records and matching English defaults/interpolation formats")


if __name__ == "__main__":
    main()
