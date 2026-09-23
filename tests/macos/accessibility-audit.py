#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Accessibility-label audit of the actual native app (N4.17 evidence).

Launches an isolated copy (tests/macos/isolated-app.py) against three loopback
peers started here (no security, VncAuth and VeNCrypt X509None with a throwaway
certificate) and drives it only through the accessibility API
(tests/macos/AccessibilityAudit.swift: AXPress/AXValue, never synthetic mouse or
keyboard input, never activating the app). Every reached window, sheet and
Settings section is audited: each interactive element must expose a label that
VoiceOver can speak (title, description, title element, placeholder or help).

The calling process must be an accessibility client (System Settings › Privacy &
Security › Accessibility). This is an automated label audit, not a VoiceOver
listening pass; no password is entered and no trust decision is saved.
"""
import argparse
import importlib.util
import json
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


isolated = load('isolated_app', 'tests/macos/isolated-app.py')
smoke = load('auth_smoke', 'tests/integration/macos-auth-smoke.py')


def read(connection, count):
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk: raise ConnectionError('closed')
        data.extend(chunk)
    return bytes(data)


def serve_desktop(connection):
    pixel_format = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    read(connection, 1)
    name = b'accessibility fixture'
    connection.sendall(struct.pack('>HH', 64, 48) + pixel_format + struct.pack('>I', len(name)) + name)
    sent = False
    while True:
        kind = read(connection, 1)[0]
        if kind == 0: read(connection, 19)
        elif kind == 2: read(connection, 1); read(connection, 4 * struct.unpack('>H', read(connection, 2))[0])
        elif kind == 3:
            read(connection, 9)
            if not sent:
                connection.sendall(b'\0\0\0\1' + struct.pack('>HHHHi', 0, 0, 64, 48, 0) + b'\x80\x40\x20\x00' * (64 * 48))
                sent = True
        elif kind == 4: read(connection, 7)
        elif kind == 5: read(connection, 5)
        elif kind == 6: read(connection, 3); read(connection, struct.unpack('>I', read(connection, 4))[0])
        elif kind == 150: read(connection, 9)
        elif kind == 251: read(connection, 1); _, _, count, _ = struct.unpack('>HHBB', read(connection, 6)); read(connection, 16 * count)
        else: return


def session(mode, connection, context):
    try:
        if mode == 'none':
            connection.sendall(b'RFB 003.008\n'); read(connection, 12)
            connection.sendall(b'\1\1'); read(connection, 1); connection.sendall(b'\0\0\0\0')
            serve_desktop(connection)
        elif mode == 'auth':
            smoke.handshake(connection); connection.settimeout(None)
            read(connection, 16)                        # parked at the prompt until cancelled
        else:
            connection.sendall(b'RFB 003.008\n'); read(connection, 12)
            connection.sendall(bytes([1, 19])); read(connection, 1)
            connection.sendall(bytes([0, 2])); read(connection, 2); connection.sendall(bytes([0]))
            connection.sendall(bytes([1]) + struct.pack('>I', 260)); read(connection, 4); connection.sendall(bytes([1]))
            connection.settimeout(None)
            tls = context.wrap_socket(connection, server_side=True)
            tls.recv(1)                                 # parked at the trust sheet until cancelled
    except (OSError, ConnectionError, ssl.SSLError):
        pass
    finally:
        connection.close()


ACCEPTED = {'none': 0, 'auth': 0, 'tls': 0}


def peer(mode, context=None):
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(4)
    def accept():
        while True:
            try: connection, _ = listener.accept()
            except OSError: return
            ACCEPTED[mode] += 1
            threading.Thread(target=session, args=(mode, connection, context), daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    return listener, f'127.0.0.1::{listener.getsockname()[1]}'


def main_steps():
    sheet = lambda open_id, marker, close, name: ['press', open_id, 'wait', marker, 'audit', name, 'press', close]
    return [
        'wait', 'connection.disconnect', 'audit', 'connected-window',
        *sheet('connection.input', 'Apply', 'Cancel', 'input-sheet'),
        *sheet('connection.scaling', 'Apply', 'Cancel', 'scaling-sheet'),
        *sheet('connection.encoding', 'Done', 'Done', 'encoding-sheet'),
        'menuitem', 'connection.actions', 'Connection Information…', 'wait', 'Copy Diagnostics',
        'audit', 'information-sheet', 'press', 'Done',
        'press', 'Recent connections', 'sleep', '500', 'audit', 'recent-connections-popover', 'press', 'Recent connections',
        'press', 'connection.disconnect', 'wait', 'connection.connect', 'audit', 'disconnected-window',
        'menu', 'TidyVNC', 'Settings…', 'wait', 'Restore Built-in Defaults', 'choose', 'preferences.section', 'settings',
        'close', 'TidyVNC Settings',
        'menu', 'File', 'Saved Certificate Decisions…', 'wait', 'Reload', 'audit', 'saved-certificate-decisions',
        'close', 'Saved Certificate Decisions',
        'menu', 'File', 'Saved Server Keys…', 'wait', 'Saved Server Keys', 'sleep', '500', 'audit', 'saved-server-keys',
        'close', 'Saved Server Keys',
        'menu', 'File', 'Saved Profiles…', 'wait', 'Saved Profiles', 'sleep', '500', 'audit', 'saved-profiles',
        'close', 'Saved Profiles',
        'menu', 'File', 'Import Connection Defaults…', 'sleep', '800', 'audit', 'import-defaults', 'close-others', 'TidyVNC',
        'menu', 'File', 'Import Recent Connections…', 'sleep', '800', 'audit', 'import-history', 'close-others', 'TidyVNC',
        'menu', 'TidyVNC', 'About TidyVNC', 'sleep', '800', 'audit', 'about', 'close-others', 'TidyVNC',
        'menu', 'Help', 'TidyVNC Help', 'wait', 'help.topic', 'choose', 'help.topic', 'help', 'close', 'TidyVNC Help',
        'menu', 'TidyVNC', 'Quit TidyVNC',
    ]


# SwiftUI text bindings ignore accessibility value writes, so each prompt gets its
# own launch with the peer endpoint as the viewer argument.
def prompt_steps(marker, name):
    return ['wait', marker, 'audit', name, 'press', 'authentication.cancel', 'wait', 'connection.connect',
            'menu', 'TidyVNC', 'Quit TidyVNC']


def drive(tool, app, work, name, endpoint, steps):
    state = work / name
    process = isolated.launch(app, state, ['-SendClipboard=0', '-AcceptClipboard=0', endpoint])['process']
    try:
        result = subprocess.run([str(tool), str(process.pid), *steps], capture_output=True, text=True, timeout=300)
        lines = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        if result.returncode and not any('error' in line for line in lines):
            lines.append({'error': f'{name}: exit {result.returncode} {result.stderr.strip()}'})
        try: process.wait(15)
        except subprocess.TimeoutExpired: lines.append({'error': f'{name}: app did not quit'})
        return lines
    finally:
        if process.poll() is None: process.terminate(); process.wait(10)
        isolated.cleanup(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path, help='TidyVNC.app built from build/native-ui-frontend')
    parser.add_argument('--report', type=Path, help='write the audit lines as JSON here')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tidyvnc-accessibility-') as temporary:
        work = Path(temporary)
        tool = work / 'accessibility-audit'
        subprocess.run(['xcrun', 'swiftc', '-O', str(ROOT / 'tests/macos/AccessibilityAudit.swift'), '-o', str(tool)], check=True)
        listeners = []
        plain, endpoint = peer('none'); listeners.append(plain)
        auth_listener, auth = peer('auth'); listeners.append(auth_listener)
        tls_listener, tls = peer('tls', smoke.self_signed(work)); listeners.append(tls_listener)
        app = args.app.resolve()
        lines = drive(tool, app, work, 'main', endpoint, main_steps())
        lines += drive(tool, app, work, 'auth', auth, prompt_steps('authentication.submit', 'authentication-sheet'))
        lines += drive(tool, app, work, 'tls', tls, prompt_steps('authentication.trust', 'trust-sheet'))
        for listener in listeners: listener.close()
    audits = [line for line in lines if 'audit' in line]
    errors = [line['error'] for line in lines if 'error' in line]
    unlabeled = sum(len(line['unlabeled']) for line in audits)
    for line in audits:
        status = 'PASS' if not line['unlabeled'] else 'FAIL'
        print(f"{status} {line['audit']}: {line['interactive']} interactive, {len(line['unlabeled'])} unlabeled")
        for element in line['unlabeled']:
            print('    unlabeled', json.dumps(element))
        for element in line.get('system', []):
            print('    system-provided, speaks its content:', element['role'], element['identifier'])
    for error in errors:
        print('ERROR', error)
    if args.report:
        args.report.write_text(json.dumps({'audits': audits, 'errors': errors}, indent=2) + '\n')
    print('peer connections', ACCEPTED)
    print(f'{len(audits)} screens audited, {unlabeled} unlabeled interactive elements, {len(errors)} errors; '
          'automated label audit only, not a VoiceOver listening pass.')
    return 1 if unlabeled or errors else 0


if __name__ == '__main__':
    sys.exit(main())
