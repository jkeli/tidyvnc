#!/usr/bin/env python3
"""Verify a built native app and all registered automated suites; save evidence.

This is automated core/model/adapter/render-fixture coverage, not interactive
keyboard/VoiceOver, installed privacy/Keychain or distribution acceptance.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]


def check_junit(path, expected):
    """Require exactly the discovered tests, each actually run and passed."""
    if not expected:
        raise ValueError("CTest inventory is empty")
    suite = ET.parse(path).getroot()
    if suite.tag != "testsuite":
        raise ValueError("Expected CTest's single testsuite JUnit report")
    cases = suite.findall("testcase")
    # GoogleTest's pretty parameter names can repeat for distinct case indices.
    # Preserve their multiplicity instead of discarding or rejecting such cases.
    if Counter(case.get("name") for case in cases) != Counter(expected):
        raise ValueError("JUnit tests do not match the complete CTest inventory")
    if int(suite.get("tests", "-1")) != len(expected):
        raise ValueError("JUnit test count does not match the CTest inventory")
    for counter in ("failures", "errors", "disabled", "skipped"):
        if int(suite.get(counter, "0")) != 0:
            raise ValueError(f"JUnit reports {counter}; automated coverage is incomplete")
    incomplete = [case.get("name") for case in cases
                  if case.get("status") != "run" or
                  any(case.find(kind) is not None for kind in ("failure", "error", "skipped"))]
    if incomplete:
        raise ValueError("Tests failed or did not run: " + ", ".join(incomplete))
    return len(cases)


class Verification:
    def __init__(self, output, env):
        self.output = output
        self.env = env
        self.report = {
            "schemaVersion": 1,
            "status": "running",
            "startedAt": datetime.now(timezone.utc).isoformat(),
            "host": {"system": platform.system(), "macOS": platform.mac_ver()[0],
                     "architecture": platform.machine(), "developerDirectory": env.get("DEVELOPER_DIR")},
            "coverage": "Automated core/model/adapter/render fixtures and development bundle checks",
            "excludes": ["interactive keyboard/VoiceOver", "physical display/input",
                         "installed privacy/Keychain", "distribution portability/signing", "notarization"],
            "stages": [],
        }
        self.save()

    def save(self):
        (self.output / "summary.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def command(self, name, command):
        command = [str(value) for value in command]
        log = self.output / f"{name}.log"
        stage = {"name": name, "command": command, "log": log.name, "status": "running"}
        self.report["stages"].append(stage)
        self.save()
        print(f"Running {name}; log: {log}", flush=True)
        try:
            with log.open("w") as stream:
                result = subprocess.run(command, env=self.env, stdout=stream, stderr=subprocess.STDOUT)
            stage["exitCode"] = result.returncode
            stage["status"] = "passed" if result.returncode == 0 else "failed"
        except OSError as error:
            stage.update(status="failed", error=str(error))
        self.save()
        return stage

    def suite(self, name, directory):
        inventory = self.command(f"{name}-inventory", ["ctest", "--test-dir", directory, "--show-only=json-v1"])
        if inventory["status"] != "passed":
            return
        try:
            discovered = json.loads((self.output / inventory["log"]).read_text())
            expected = [test["name"] for test in discovered["tests"]]
            if not expected:
                raise ValueError("CTest inventory is empty")
            inventory["testCount"] = len(expected)
        except (KeyError, TypeError, ValueError) as error:
            inventory.update(status="failed", error=str(error))
            self.save()
            return
        junit = self.output / f"{name}.xml"
        stage = self.command(name, ["ctest", "--test-dir", directory, "--output-on-failure",
                                   "--no-tests=error", "--parallel", "1", "--timeout", "120", "--output-junit", junit])
        stage["junit"] = junit.name
        try:
            stage["passedTests"] = check_junit(junit, expected)
        except (OSError, ValueError, ET.ParseError) as error:
            stage.update(status="failed", error=str(error))
        self.save()

    def finish(self):
        failed = [stage["name"] for stage in self.report["stages"] if stage["status"] != "passed"]
        self.report.update(status="failed" if failed else "passed",
                           finishedAt=datetime.now(timezone.utc).isoformat())
        self.save()
        print(f"{'FAIL' if failed else 'PASS'} native automated verification: {self.output / 'summary.json'}")
        if failed:
            print("Failed/incomplete stages: " + ", ".join(failed))
        return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--reports", type=Path, required=True, help="Parent directory for a fresh report per run")
    args = parser.parse_args()
    core, app = args.core.resolve(), args.app.resolve()
    args.reports.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=args.reports.resolve()))
    # A fresh directory prevents old XML/logs from making an interrupted run green.
    verification = Verification(output, dict(os.environ))
    verification.command("toolchain", ["xcodebuild", "-version"])
    verification.command("swift-version", ["xcrun", "swift", "--version"])
    for suite in ("viewer", "unit", "macos"):
        verification.suite(suite, core / "tests" / suite)
    verification.command("frontend-graph", [sys.executable, ROOT / "tests/macos/frontend-graph.py",
                                             core, app.parent.parent])
    configuration = [sys.executable, ROOT / "tests/macos/frontend-configuration.py", core]
    if os.environ.get("DEVELOPER_DIR"):
        configuration += ["--developer-dir", os.environ["DEVELOPER_DIR"]]
    verification.command("configuration-failures", configuration)
    verification.command("bundle-localization", ["xcrun", "swift", "-module-cache-path", output / "module-cache",
        ROOT / "tests/macos/localization-bundle.swift", app, ROOT / "apps/macos/Localizable.xcstrings"])
    verification.command("bundle-signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    verification.command("terminal", [sys.executable, ROOT / "tests/macos/invocation-terminal.py", "--app", app])
    binary = app / "Contents/MacOS/vncviewer"
    if binary.is_file():
        verification.report["executableSHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    return verification.finish()


if __name__ == "__main__":
    sys.exit(main())
