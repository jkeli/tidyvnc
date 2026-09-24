#!/usr/bin/env python3
"""Check that tidyvnc_viewer.dll exports exactly the functions tidyvnc.h declares.

plans/native-ui-winui/CORE.md section 4: the DLL exports only tidyvnc_*
functions, every declared function is exported, and every declaration carries
TIDYVNC_API. Usage: dll-exports.py <tidyvnc.h> <tidyvnc_viewer.dll> <dumpbin.exe>
"""
import re
import subprocess
import sys


def main():
    header, dll, dumpbin = sys.argv[1:4]
    text = open(header, encoding="utf-8").read()
    body = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    declared = set(re.findall(r"^TIDYVNC_API tidyvnc_status (tidyvnc_\w+)\(", body, re.M))
    unannotated = re.findall(r"^tidyvnc_status (tidyvnc_\w+)\(", body, re.M)
    output = subprocess.check_output([dumpbin, "/nologo", "/exports", dll], text=True)
    exported, started = set(), False
    for line in output.splitlines():
        if re.match(r"\s*ordinal\s+hint\s+RVA\s+name", line):
            started = True
            continue
        if started:
            match = re.match(r"\s*\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)", line)
            if match:
                exported.add(match.group(1))
            elif line.strip().startswith("Summary"):
                break
    problems = []
    if unannotated:
        problems.append(f"declarations without TIDYVNC_API: {sorted(unannotated)}")
    if not declared:
        problems.append("no declarations found")
    if declared - exported:
        problems.append(f"declared but not exported: {sorted(declared - exported)}")
    if exported - declared:
        problems.append(f"exported but not declared: {sorted(exported - declared)}")
    if problems:
        print("\n".join(problems))
        return 1
    print(f"{len(exported)} exports match tidyvnc.h")
    return 0


if __name__ == "__main__":
    sys.exit(main())
