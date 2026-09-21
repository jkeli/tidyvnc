#!/usr/bin/env python3
"""Exercise native file logging through the public ABI in separate processes."""
import argparse
import os
from pathlib import Path
import select
import stat
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('executable', type=Path)
parser.add_argument('--macos-unbundled-nls', action='store_true')
args = parser.parse_args()
executable = str(args.executable.resolve())
# The retained translation helper writes this fixed pre-routing diagnostic when
# the standalone macOS test executable has no bundle locale resources. Require
# exactly that known message only in the translation-enabled configuration.
startup_errors = b'Failed to determine locale directory\n' if args.macos_unbundled_nls else b''
children = []


def start(path):
    child = subprocess.Popen([executable, 'file', str(path)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    children.append(child)
    assert select.select([child.stdout], [], [], 15)[0], 'file logger startup timed out'
    assert child.stdout.readline() == b'READY\n', 'file logger startup failed'
    return child


def finish(child):
    output, errors = child.communicate(b'\n', timeout=15)
    assert child.returncode == 0, (output, errors)
    assert b'PASS process logging ownership and ABI' in output
    return errors


def redacted(data):
    assert b'TLS handshake completed with [redacted]' in data
    assert b'Reading protocol version' in data
    assert b'Diagnostic details redacted.' in data
    for private in (b'private', b'forged', b'Key pressed'):
        assert private not in data


try:
    with tempfile.TemporaryDirectory(prefix='tidyvnc-log-process-') as temporary:
        root = Path(temporary)
        path = root / 'diagnostic-\u00e9.log'
        backup = Path(str(path) + '.bak')
        path.write_bytes(b'previous diagnostic bytes\n')
        backup.write_bytes(b'older diagnostic bytes\n')
        first = start(path)
        original_inode = path.stat().st_ino
        first_bytes = path.read_bytes()
        redacted(first_bytes)
        assert backup.read_bytes() == b'previous diagnostic bytes\n'
        second = start(path)
        errors = finish(second)
        redacted(errors)
        assert errors.count(b'File logging is unavailable; using standard error.') == 1
        assert os.fsencode(root) not in errors
        assert path.stat().st_ino == original_inode and path.read_bytes() == first_bytes
        assert backup.read_bytes() == b'previous diagnostic bytes\n'
        errors = finish(first)
        assert errors == startup_errors, errors
        completed_bytes = path.read_bytes()
        assert len(completed_bytes) > len(first_bytes)
        third = start(path)
        assert backup.stat().st_ino == original_inode
        assert backup.read_bytes() == completed_bytes
        errors = finish(third)
        assert errors == startup_errors, errors
        redacted(path.read_bytes())
        assert sorted(p.name for p in root.iterdir()) == [path.name, path.name+'.bak', path.name+'.lock']
        for entry in root.iterdir():
            info = entry.lstat()
            assert stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
            assert info.st_nlink == 1 and info.st_uid == os.geteuid()
        print('PASS private file ABI, process lock, redaction, drain lifetime and rotation')
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait()
