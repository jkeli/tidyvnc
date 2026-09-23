#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in rollback check (N6.11): after the native app has been used, the
retained FLTK viewer still runs with its own untouched data, and it leaves the
native stores alone.

1. An isolated state directory is seeded with legacy data: the FLTK viewer's
   XDG_CONFIG_HOME/tidyvnc/default.tidyvnc (AutoSelect=0, PreferredEncoding=ZRLE),
   its server history, and an upstream TigerVNC default.tigervnc.
2. An isolated copy of the native app (tests/macos/isolated-app.py) connects to
   native-security-peer and quits. The legacy files must be byte-identical,
   and the native app must have written its own history store.
3. The FLTK viewer runs with the same HOME/XDG roots. It must connect with
   ZRLE as its first requested real encoding (so it read its untouched defaults),
   and the native stores and legacy files must again be byte-identical.
4. Explicit profile export: native-export-fixture writes a reviewed
   compatibility file through the production NativeDocumentExport codec
   (PreferredEncoding=Hextile, clipboard off). The FLTK viewer opens that file
   and must connect with Hextile first; stores and legacy files stay unchanged.

No credentials are involved (security None); nothing is imported or migrated
automatically. Requires WindowServer, codesign and a Swift compiler.
"""
import argparse
import hashlib
import importlib.util
import queue
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


isolated = load('isolated_app', 'tests/macos/isolated-app.py')
security = load('security_smoke', 'tests/integration/macos-security-smoke.py')

LEGACY = {
    'XDG_CONFIG_HOME/tidyvnc/default.tidyvnc':
        'TidyVNC Configuration file Version 1.0\n\nAutoSelect=0\nPreferredEncoding=ZRLE\n',
    'XDG_STATE_HOME/tidyvnc/tidyvnc.history': 'legacy-history.invalid::5901\n',
    'XDG_CONFIG_HOME/tigervnc/default.tigervnc':
        'TigerVNC Configuration file Version 1.0\n\nAutoSelect=0\nPreferredEncoding=Hextile\n',
}
ZRLE, HEXTILE = 16, 5


def digests(root, relatives):
    return {relative: hashlib.sha256((root / relative).read_bytes()).hexdigest() for relative in relatives}


def native_store_files(state):
    support = state / 'HOME/Library/Application Support'
    if not support.exists(): return []
    return sorted(str(path.relative_to(state)) for path in support.rglob('*') if path.is_file() and not path.name.startswith('.'))


def drain(peer):
    """Consumes the peer's report that the previous session ended."""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            if peer.lines.get(timeout=0.5).startswith('closed'): return
        except queue.Empty: pass


def connect(peer, process, name, settle=lambda: True):
    try:
        peer.expect(lambda line: line == 'accepted', 45)
        peer.expect(lambda line: line == 'authenticated None', 30)
        encodings = peer.expect(lambda line: line.startswith('encodings '), 15)
        peer.expect(lambda line: line == 'request', 15)
        assert process.poll() is None, f'{name} exited (code {process.returncode})'
        deadline = time.monotonic() + 10
        while not settle() and time.monotonic() < deadline: time.sleep(0.2)
        return [int(value) for value in encodings.split(' ', 1)[1].split(',')]
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try: process.wait(10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path, help='TidyVNC.app built from build/native-ui-frontend')
    parser.add_argument('fltk', type=Path, help='retained FLTK vncviewer executable')
    parser.add_argument('--peer', type=Path, default=ROOT / 'build/native-ui-frontend/core/tests/macos/native-security-peer')
    parser.add_argument('--export-fixture', type=Path,
                        default=ROOT / 'build/native-ui-frontend/core/tests/macos/native-export-fixture')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tidyvnc-rollback-smoke-') as temporary:
        state = Path(temporary) / 'state'
        peer = security.Peer(args.peer.resolve(), 'None', [])
        try:
            arguments = ['-SecurityTypes=None', '-SendClipboard=0', '-AcceptClipboard=0', '-ReconnectOnError=0']
            native = isolated.launch(args.app.resolve(), state, [*arguments, peer.endpoint], state_files=LEGACY)['process']
            before = {relative: hashlib.sha256(text.encode()).hexdigest() for relative, text in LEGACY.items()}
            # The native app records a successful connection in its own history store.
            connect(peer, native, 'native app',
                    settle=lambda: any('profiles-history.json' in path for path in native_store_files(state)))
            time.sleep(0.5)
            assert digests(state, LEGACY) == before, 'the native app changed legacy FLTK/TigerVNC files'
            stores = native_store_files(state)
            assert any('profiles-history.json' in path for path in stores), f'native history store missing: {stores}'
            native_digests = digests(state, stores)
            print(f'PASS native session left {len(LEGACY)} legacy files unchanged and wrote {len(stores)} native store files')

            drain(peer)
            fltk = subprocess.Popen([str(args.fltk.resolve()), *arguments, peer.endpoint], env=isolated.environment(state),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            encodings = connect(peer, fltk, 'FLTK viewer')
            # Pseudo-encodings (negative or large) come first; the preferred real encoding leads the rest.
            real = [value for value in encodings if 0 <= value < 256]
            assert real and real[0] == ZRLE, f'FLTK did not use its legacy defaults: encodings {encodings}'
            time.sleep(0.5)
            assert digests(state, stores) == native_digests, 'the FLTK viewer changed native stores'
            assert digests(state, LEGACY) == before, 'the FLTK viewer rewrote legacy files'
            print('PASS FLTK viewer connected with its untouched defaults (ZRLE first) and left native stores unchanged')

            drain(peer)
            exported = Path(temporary) / 'Exported.tidyvnc'
            subprocess.run([str(args.export_fixture.resolve()), peer.endpoint, 'None', str(exported)], check=True,
                           stdout=subprocess.DEVNULL)
            fltk = subprocess.Popen([str(args.fltk.resolve()), str(exported)], env=isolated.environment(state),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            encodings = connect(peer, fltk, 'FLTK viewer with the native export')
            real = [value for value in encodings if 0 <= value < 256]
            assert real and real[0] == HEXTILE, f'FLTK did not apply the native export: encodings {encodings}'
            time.sleep(0.5)
            assert digests(state, stores) == native_digests and digests(state, LEGACY) == before, \
                'opening the export changed native stores or legacy files'
            print('PASS FLTK viewer opened the native compatibility export and connected with its settings (Hextile first)')
        finally:
            peer.stop()
            if (state / 'fixture.json').exists():
                isolated.cleanup(state)
    print('Rollback check passed: legacy and native data stay separate; nothing was migrated automatically.')


if __name__ == '__main__':
    sys.exit(main())
