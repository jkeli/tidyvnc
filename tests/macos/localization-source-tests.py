#!/usr/bin/env python3
"""Failure-path tests for the native compiler/catalog build gate."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("localization_source", Path(__file__).with_name("localization-source.py"))
audit_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_module)


class CatalogAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "Screen.swift"
        self.source.write_text("// Fixture source\n")
        self.manifest = self.root / "sources.txt"
        self.manifest.write_text(str(self.source) + "\n")
        self.catalog = self.root / "Localizable.xcstrings"
        self.entries = {"screen.count": "Count %u"}
        self.records = self.root / "records"
        self.records.mkdir()
        self.record = self.records / "Screen.stringsdata"
        self.write_record()

    def write_record(self, entries=None, **overrides):
        record = {"version": 1, "source": str(self.source), "tables": {"Localizable": entries or [
            {"key": "screen.count", "value": "Count %u",
             "location": {"startingLine": 1, "startingColumn": 1}}]}}
        record.update(overrides)
        self.record.write_text(json.dumps(record))
        audit_module.record_build(self.manifest, self.records)

    def run_audit(self):
        self.catalog.write_text(json.dumps({"sourceLanguage": "en", "strings": {
            key: {"localizations": {"en": {"stringUnit": {"value": value}}}}
            for key, value in self.entries.items()}}))
        return audit_module.audit(self.catalog, [(self.manifest, self.records)])

    def test_complete_coverage(self):
        self.assertEqual(self.run_audit(), ([], 1, 1, 1))

    def test_missing_key(self):
        self.entries = {}
        self.assertTrue(any("Missing catalog key" in issue for issue in self.run_audit()[0]))

    def test_wrong_interpolation_type(self):
        self.entries["screen.count"] = "Count %@"
        self.assertTrue(any("Default mismatch" in issue for issue in self.run_audit()[0]))

    def test_unused_entry(self):
        self.entries["obsolete"] = "Unused"
        self.assertTrue(any("no compiled call site" in issue for issue in self.run_audit()[0]))

    def test_missing_source_record(self):
        self.record.unlink()
        self.assertTrue(any("Missing current compiler record" in issue for issue in self.run_audit()[0]))

    def test_changed_source_requires_completed_build(self):
        self.source.write_text("// Changed after compilation\n")
        self.assertTrue(any("Stale completed build receipt" in issue for issue in self.run_audit()[0]))

    def test_byte_identical_record_can_predate_recompiled_source(self):
        self.source.write_text("// Code-only change with identical localization output\n")
        older = self.source.stat().st_mtime_ns - 1_000_000_000
        os.utime(self.record, ns=(older, older))
        audit_module.record_build(self.manifest, self.records)
        self.assertEqual(self.run_audit(), ([], 1, 1, 1))

    def test_record_changed_after_build_fails(self):
        self.record.write_text(self.record.read_text() + "\n")
        self.assertTrue(any("Stale completed build receipt" in issue for issue in self.run_audit()[0]))

    def test_missing_receipt_fails(self):
        self.manifest.with_suffix(".built.json").unlink()
        self.assertTrue(any("Missing completed build receipt" in issue for issue in self.run_audit()[0]))

    def test_same_basename_wrong_source_cannot_satisfy_manifest(self):
        self.write_record(source=str(self.root / "other/Screen.swift"))
        self.assertTrue(any("Missing current compiler record" in issue for issue in self.run_audit()[0]))

    def test_synthesized_locations_and_empty_titles(self):
        self.write_record([{"key": "screen.count", "value": "Count %u"}, {"key": ""}])
        self.assertEqual(self.run_audit(), ([], 1, 1, 1))

    def test_implicit_localized_literal(self):
        self.write_record([{"key": "Uncataloged title"}])
        self.assertTrue(any("Missing catalog key 'Uncataloged title'" in issue for issue in self.run_audit()[0]))

    def test_unsupported_record_format(self):
        self.write_record(version=999)
        with self.assertRaisesRegex(ValueError, "Unsupported Swift localization record"):
            self.run_audit()

    def test_unsupported_table(self):
        self.write_record(tables={"Other": [{"key": "screen.count"}]})
        self.assertTrue(any("Unexpected localization table" in issue for issue in self.run_audit()[0]))

    def test_generated_metadata_and_removed_sources_are_ignored(self):
        (self.records / "old.stringsdata").write_text(json.dumps({"version": 999, "source": "Removed.swift"}))
        (self.records / "metadata.stringsdata").write_text(json.dumps({"version": 2, "source": "ExtractedAppShortcutsMetadata"}))
        self.assertEqual(self.run_audit(), ([], 1, 1, 1))

    def test_empty_manifest_cannot_pass(self):
        self.manifest.write_text("")
        with self.assertRaisesRegex(ValueError, "Empty source manifest"):
            self.run_audit()


if __name__ == "__main__":
    unittest.main()
