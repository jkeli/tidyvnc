#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Baseline screenshots of the retained FLTK viewer (N0.4 evidence).

Runs the FLTK viewer with fresh HOME/XDG roots (tests/macos/isolated-app.py
environment) against native-security-peer fixtures and captures only the
viewer's own windows (found through CGWindowList by process id, captured with
`screencapture -l`; nothing else on screen is recorded):

  server-dialog        no arguments: the connection dialog
  desktop              security None: the connected desktop window (64x48 fixture)
  password-dialog      VncAuth: the password prompt
  certificate-dialog   X509None with an untrusted certificate: the trust dialog
  connection-refused   a refused port: the error dialog

No input is sent to the viewer; each process is terminated after capture.
Requires WindowServer and a process allowed to record the screen.
"""
import argparse
import importlib.util
import json
import signal
import socket
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

LISTER = r'''
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
// Normal windows and FLTK's modal dialogs (layer 25); tiny menu strips are
// filtered by size below and system overlays sit higher.
let windows = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 99) <= 25 }
  .map { window -> [String: Any] in
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return ["id": window[kCGWindowNumber as String] ?? 0, "name": window[kCGWindowName as String] ?? "",
            "width": bounds["Width"] ?? 0, "height": bounds["Height"] ?? 0]
  }
print(String(data: try! JSONSerialization.data(withJSONObject: windows), encoding: .utf8)!)
'''


def windows(lister, pid):
    output = subprocess.run([str(lister), str(pid)], capture_output=True, text=True, check=True).stdout
    return [window for window in json.loads(output) if window['width'] > 40 and window['height'] > 40]


def capture(lister, process, name, directory, minimum=1, timeout=20):
    deadline = time.monotonic() + timeout
    found = []
    while time.monotonic() < deadline:
        found = windows(lister, process.pid)
        if len(found) >= minimum: break
        time.sleep(0.3)
    if not found: raise AssertionError(f'{name}: no FLTK window appeared')
    time.sleep(1.0)                                      # let the window finish drawing
    found = windows(lister, process.pid)
    paths = []
    for index, window in enumerate(sorted(found, key=lambda w: w['id'])):
        path = directory / (f'fltk-{name}.png' if index == 0 else f'fltk-{name}-{index + 1}.png')
        subprocess.run(['/usr/sbin/screencapture', '-x', '-o', f'-l{window["id"]}', str(path)], check=True)
        paths.append({'file': path.name, 'title': window['name'], 'points': [window['width'], window['height']]})
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('fltk', type=Path, help='retained FLTK vncviewer executable')
    parser.add_argument('output', type=Path, help='directory for PNGs and baseline.json')
    parser.add_argument('--peer', type=Path, default=ROOT / 'build/native-ui-frontend/core/tests/macos/native-security-peer')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = {}
    with tempfile.TemporaryDirectory(prefix='tidyvnc-fltk-baseline-') as temporary:
        work = Path(temporary)
        lister = work / 'window-list'
        (work / 'window-list.swift').write_text(LISTER)
        subprocess.run(['xcrun', 'swiftc', '-O', str(work / 'window-list.swift'), '-o', str(lister)], check=True)
        key, cert, _ = security.materials(work)
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0)); refused = reserve.getsockname()[1]
        scenarios = [
            ('server-dialog', None, [], []),
            ('desktop', ('None', []), ['-SecurityTypes=None'], []),
            ('password-dialog', ('VncAuth', [f'VncPassword={security.PASSWORD}']), ['-SecurityTypes=VncAuth'], []),
            ('certificate-dialog', ('X509None', [f'X509Cert={cert}', f'X509Key={key}']), ['-SecurityTypes=X509None'], []),
            ('connection-refused', None, ['-SecurityTypes=None'], [f'127.0.0.1::{refused}']),
        ]
        for name, peer_spec, options, endpoint in scenarios:
            peer = security.Peer(args.peer.resolve(), *peer_spec) if peer_spec else None
            state = work / name
            state.mkdir()
            env = isolated.environment(state)
            target = [peer.endpoint] if peer else endpoint
            process = subprocess.Popen([str(args.fltk.resolve()), '-SendClipboard=0', '-AcceptClipboard=0', *options, *target],
                                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                if name == 'desktop':
                    peer.expect(lambda line: line == 'request', 20); time.sleep(0.5)
                results[name] = capture(lister, process, name, args.output)
                print(f'PASS {name}: ' + ', '.join(f"{shot['file']} ({shot['title'] or 'untitled'})" for shot in results[name]))
            finally:
                process.send_signal(signal.SIGTERM)
                try: process.wait(10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
                if peer: peer.stop()
    (args.output / 'baseline.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    sys.exit(main())
