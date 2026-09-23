#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Actual-app persistence of Settings defaults and recent history (N3.1/N3.2).

Launch 1: an isolated copy (tests/macos/isolated-app.py) connects to
native-security-peer (security None), so the connection enters history. It then
opens TidyVNC › Settings…, clears "Receive clipboard from server" and presses
Apply, and creates a profile in File › Saved Profiles… (name and address typed
through the accessibility text system) and saves it, then quits. Launch 2: the
same isolated copy and state start with no arguments. The Recent connections
popover must list the endpoint, Settings must show the cleared default with an
app-default source, and the saved profile must be listed and open a connection
window that connects to the peer.

The app is driven only through the accessibility API
(tests/macos/AccessibilityAudit.swift); the caller must be an accessibility
client. Nothing outside the temporary state is read or written.
"""
import argparse
import importlib.util
import json
import queue
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILE = 'Fixture desktop'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


isolated = load('isolated_app', 'tests/macos/isolated-app.py')
security = load('security_smoke', 'tests/integration/macos-security-smoke.py')


def drive(tool, pid, *steps):
    result = subprocess.run([str(tool), str(pid), *steps], capture_output=True, text=True, timeout=180)
    lines = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    errors = [line['error'] for line in lines if 'error' in line]
    if result.returncode or errors:
        raise AssertionError(f'accessibility steps failed: {errors or result.stderr.strip()}')
    return [line['dump'] for line in lines if 'dump' in line]


def quit_app(tool, process):
    drive(tool, process.pid, 'menu', 'TidyVNC', 'Quit TidyVNC')
    try: process.wait(15)
    except subprocess.TimeoutExpired: raise AssertionError('app did not quit')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path, help='TidyVNC.app built from build/native-ui-frontend')
    parser.add_argument('--peer', type=Path, default=ROOT / 'build/native-ui-frontend/core/tests/macos/native-security-peer')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tidyvnc-persistence-') as temporary:
        work = Path(temporary)
        tool = work / 'accessibility-audit'
        subprocess.run(['xcrun', 'swiftc', '-O', str(ROOT / 'tests/macos/AccessibilityAudit.swift'), '-o', str(tool)], check=True)
        peer = security.Peer(args.peer.resolve(), 'None', [])
        state = work / 'state'
        try:
            launched = isolated.launch(args.app.resolve(), state, ['-SecurityTypes=None', '-SendClipboard=0',
                                                                  '-AcceptClipboard=0', peer.endpoint])
            first = launched['process']
            peer.expect(lambda line: line == 'request', 45)
            drive(tool, first.pid, 'wait', 'connection.disconnect', 'press', 'connection.disconnect', 'wait', 'connection.connect',
                  'menu', 'TidyVNC', 'Settings…', 'wait', 'preferences.clipboard.receive',
                  'press', 'preferences.clipboard.receive', 'press', 'preferences.apply', 'sleep', '800',
                  'close', 'TidyVNC Settings',
                  'menu', 'File', 'Saved Profiles…', 'wait', 'profiles.new', 'press', 'profiles.new', 'sleep', '500',
                  'type', 'profiles.name', PROFILE, 'type', 'profiles.endpoint', peer.endpoint, 'sleep', '300',
                  'press', 'profiles.save', 'sleep', '800', 'close', 'Saved Profiles')
            quit_app(tool, first)
            # Consume the peer's report that launch 1's session ended.
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    if peer.lines.get(timeout=0.5).startswith('closed'): break
                except queue.Empty: pass
            print(f'PASS launch 1: connected to {peer.endpoint}, cleared the receive-clipboard default, '
                  f'saved profile "{PROFILE}" and quit')

            executable = Path(launched['app']) / 'Contents/MacOS/vncviewer'
            second = subprocess.Popen([str(executable)], env=isolated.environment(state.resolve()),
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                recent = drive(tool, second.pid, 'wait', 'connection.connect', 'press', 'Recent connections', 'sleep', '600', 'dump',
                               'press', 'Recent connections')
                texts = [item['value'] or item['label'] for item in recent]
                assert any(peer.endpoint in text for text in texts), f'history lacks {peer.endpoint}: {texts[:20]}'
                settings = drive(tool, second.pid, 'menu', 'TidyVNC', 'Settings…', 'wait', 'preferences.clipboard.receive', 'dump',
                                 'close', 'TidyVNC Settings')
                receive = [item for item in settings if item['identifier'] == 'preferences.clipboard.receive']
                assert receive and receive[0]['value'] == '0', f'receive default not persisted: {receive}'
                sources = [item['value'] or item['label'] for item in settings if item['role'] == 'AXStaticText']
                assert any('override' in text.lower() for text in sources), f'no app-default source label: {sources}'
                print('PASS launch 2: history lists the endpoint and Settings shows the persisted default as an app-default override')
                profiles = drive(tool, second.pid, 'menu', 'File', 'Saved Profiles…', 'wait', 'profiles.new', 'sleep', '500', 'dump')
                labels = [item['label'] or item['value'] for item in profiles]
                assert any(PROFILE in label for label in labels), f'profile not listed: {labels[:30]}'
                # Each saved profile is a row button labelled "<name>, <address>".
                # Open fills a new connection window; Connect is then an explicit step.
                drive(tool, second.pid, 'press', f'{PROFILE}, {peer.endpoint}', 'sleep', '400', 'press', 'profiles.open',
                      'sleep', '800', 'press-enabled', 'connection.connect')
                peer.expect(lambda line: line == 'accepted', 30)
                peer.expect(lambda line: line == 'request', 20)
                print(f'PASS launch 2: saved profile "{PROFILE}" is listed and opens a connection to the peer')
                quit_app(tool, second)
            finally:
                if second.poll() is None: second.terminate(); second.wait(10)
        finally:
            peer.stop()
            if (state / 'fixture.json').exists(): isolated.cleanup(state)


if __name__ == '__main__':
    sys.exit(main())
