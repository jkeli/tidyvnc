#!/usr/bin/env python3
"""Windows: native file logging through the public ABI in separate processes.

The Windows counterpart of tests/unit/processlogging-file.py: the first
process owns the log (LockFileEx), a second concurrent process falls back to
standard error once without rotating it, and a later process rotates the
completed log to .bak. File identity uses NTFS file IDs (st_ino on Windows).
"""
import argparse
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('executable', type=Path)
args = parser.parse_args()
executable = str(args.executable.resolve())
children = []


def start(path):
    child = subprocess.Popen([executable, 'file', str(path)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    children.append(child)
    lines = queue.Queue()
    threading.Thread(target=lambda: lines.put(child.stdout.readline()), daemon=True).start()
    try:
        line = lines.get(timeout=15)
    except queue.Empty:
        raise AssertionError('file logger startup timed out')
    assert line.strip() == b'READY', ('file logger startup failed', line, child.stderr.read() if child.poll() else b'')
    return child


def finish(child):
    output, errors = child.communicate(b'\n', timeout=15)
    assert child.returncode == 0, (output, errors)
    assert b'PASS process logging ownership and ABI' in output
    return errors.replace(b'\r\n', b'\n')


def redacted(data):
    assert b'TLS handshake completed with [redacted]' in data
    assert b'Reading protocol version' in data
    assert b'Diagnostic details redacted.' in data
    for private in (b'private', b'forged', b'Key pressed'):
        assert private not in data


try:
    with tempfile.TemporaryDirectory(prefix='tidyvnc-log-process-') as temporary:
        root = Path(temporary)
        path = root / 'diagnostic-é.log'
        backup = Path(str(path) + '.bak')
        path.write_bytes(b'previous diagnostic bytes\n')
        backup.write_bytes(b'older diagnostic bytes\n')
        first = start(path)
        original_id = path.stat().st_ino
        first_bytes = path.read_bytes()
        redacted(first_bytes)
        assert backup.read_bytes() == b'previous diagnostic bytes\n'
        second = start(path)
        errors = finish(second)
        redacted(errors)
        assert errors.count(b'File logging is unavailable; using standard error.') == 1
        assert str(root).encode() not in errors
        assert path.stat().st_ino == original_id and path.read_bytes() == first_bytes
        assert backup.read_bytes() == b'previous diagnostic bytes\n'
        errors = finish(first)
        assert errors == b'', errors
        completed_bytes = path.read_bytes()
        assert len(completed_bytes) > len(first_bytes)
        third = start(path)
        assert backup.stat().st_ino == original_id
        assert backup.read_bytes() == completed_bytes
        errors = finish(third)
        assert errors == b'', errors
        redacted(path.read_bytes())
        assert sorted(p.name for p in root.iterdir()) == [path.name, path.name + '.bak', path.name + '.lock']
        for entry in root.iterdir():
            assert entry.is_file() and not entry.is_symlink()
        print('PASS private file ABI, process lock, redaction, drain lifetime and rotation')
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait()
