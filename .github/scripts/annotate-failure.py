#!/usr/bin/env python3
"""Run a command and, if it fails, summarise its output as a GitHub Actions error annotation.

Usage: annotate-failure.py <command> [arguments...]

The output streams through unchanged. On failure the annotation shows the
lines that look like failures, followed by the end of the output, on the run's
summary page. Unlike job logs, annotations can be read through the REST API
without signing in. The exit status is the command's.
"""
import re
import subprocess
import sys

FAILURE = re.compile(r"FAILED|\*\*\*Failed|\(Failed\)|^\s*failed |Failed!|error [A-Z]+\d+|: error|"
                     r"Traceback|Error:|SystemExit|Assertion failed|Assert\.", re.I)


def main():
    lines = []
    process = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding="utf-8", errors="replace", bufsize=1)
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        lines.append(line.rstrip())
    status = process.wait()
    if status != 0:
        matches = [line for line in lines if FAILURE.search(line) and "Passed" not in line][-40:]
        body = "\n".join([f"Exit status {status}. Failure lines:", *matches, "", "End of the output:", *lines[-25:]])
        body = body.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
        print(f"::error title=Build or test failure::{body}", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
