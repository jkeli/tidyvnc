#!/usr/bin/env python3
"""Prevent incomplete CTest execution from being reported as native acceptance."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("verify_build", Path(__file__).with_name("verify-build.py"))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class CoverageTests(unittest.TestCase):
    def check(self, xml, names=("one",)):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "results.xml"
            path.write_text(xml)
            return verify.check_junit(path, list(names))

    def test_pass_requires_every_discovered_test(self):
        self.assertEqual(self.check('<testsuite tests="2"><testcase name="two" status="run"/>'
                                    '<testcase name="one" status="run"/></testsuite>', ("one", "two")), 2)

    def test_empty_inventory_is_invalid(self):
        with self.assertRaises(ValueError):
            self.check('<testsuite tests="0"/>', ())

    def test_repeated_parameter_names_preserve_multiplicity(self):
        self.assertEqual(self.check('<testsuite tests="2"><testcase name="one" status="run"/>'
                                    '<testcase name="one" status="run"/></testsuite>', ("one", "one")), 2)
        with self.assertRaises(ValueError):
            self.check('<testsuite tests="1"><testcase name="one" status="run"/></testsuite>', ("one", "one"))

    def test_missing_extra_duplicate_and_stale_tests_fail(self):
        for cases in ('', '<testcase name="old" status="run"/>',
                      '<testcase name="one" status="run"/><testcase name="extra" status="run"/>',
                      '<testcase name="one" status="run"/><testcase name="one" status="run"/>'):
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                self.check(f'<testsuite tests="1">{cases}</testsuite>')

    def test_failures_and_skips_fail_even_with_successful_summary(self):
        for tag in ("failure", "error", "skipped"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.check(f'<testsuite tests="1" failures="0" skipped="0">'
                           f'<testcase name="one" status="run"><{tag}/></testcase></testsuite>')

    def test_missing_or_not_run_status_fails(self):
        for status in ('', 'status="notrun"', 'status="disabled"'):
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.check(f'<testsuite tests="1"><testcase name="one" {status}/></testsuite>')

    def test_summary_failures_and_count_mismatch_fail(self):
        for attributes in ('tests="2"', 'tests="one"', 'tests="1" skipped="1"',
                           'tests="1" disabled="1"', 'tests="1" failures="1"', 'tests="1" errors="1"'):
            with self.subTest(attributes=attributes), self.assertRaises(ValueError):
                self.check(f'<testsuite {attributes}><testcase name="one" status="run"/></testsuite>')

    def test_wrong_root_fails(self):
        with self.assertRaises(ValueError):
            self.check('<testsuites><testsuite tests="1"><testcase name="one" status="run"/></testsuite></testsuites>')

    def test_nonzero_command_and_missing_executable_remain_failed(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verify.Verification(Path(temporary), dict(os.environ))
            run.command("failed", [sys.executable, "-c", "raise SystemExit(7)"])
            run.command("missing", [str(Path(temporary) / "missing")])
            run.command("passed", [sys.executable, "-c", "pass"])
            self.assertEqual(run.finish(), 1)
            saved = json.loads((Path(temporary) / "summary.json").read_text())
            self.assertEqual(saved["status"], "failed")
            self.assertEqual([stage["status"] for stage in saved["stages"]], ["failed", "failed", "passed"])


if __name__ == "__main__":
    unittest.main()
