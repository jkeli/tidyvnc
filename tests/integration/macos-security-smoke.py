#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in actual-app security handshakes against the project's real server side.

Each case launches an isolated copy of the native app (tests/macos/isolated-app.py)
against native-security-peer, a loopback RFB server built from the project's own
server-side handlers (SConnection, SSecurityVncAuth, SSecurityVeNCrypt/TLS,
SSecurityRSAAES). A case passes when the peer reports that authentication
succeeded and the app then requested a framebuffer update; the app must still be
running. Credentials come from VNC_PASSWORD (launch credentials, never saved).

  vncauth              VncAuth
  tlsnone / tlsvnc     anonymous TLS, without and with VncAuth
  x509none / x509vnc   X509 with a fresh certificate trusted through -X509CA
  ra2, ra2ne, ra2_256, ra2ne_256
                       RSA-AES variants (password-only subtype); the app asks to
                       verify the new server key, which --accept-prompts answers
                       with "Connect Once" through the accessibility API
                       (tests/macos/AccessibilityAudit.swift; the caller must be an
                       accessibility client). Without it these cases are not run.

Requires WindowServer, codesign, a Swift compiler and /usr/bin/openssl. Displayed
UI is not asserted.
"""
import argparse
import importlib.util
import queue
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('isolated_app', ROOT / 'tests/macos/isolated-app.py')
isolated = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolated)

# Eight characters: the server stores VNC passwords in the classic obfuscated
# 8-byte form, so RSA-AES (which sends the full password) needs no truncation.
PASSWORD = 'fixtpass'
CASES = {
    'vncauth': ('VncAuth', False, False),
    'tlsnone': ('TLSNone', False, False),
    'tlsvnc': ('TLSVnc', False, False),
    'x509none': ('X509None', True, False),
    'x509vnc': ('X509Vnc', True, False),
    'ra2': ('RA2', False, True),
    'ra2ne': ('RA2ne', False, True),
    'ra2_256': ('RA2_256', False, True),
    'ra2ne_256': ('RA2ne_256', False, True),
}


def materials(work):
    key, cert, rsa = work / 'x509-key.pem', work / 'x509-cert.pem', work / 'rsa-key.pem'
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                    '-keyout', str(key), '-out', str(cert)], capture_output=True, check=True)
    subprocess.run(['/usr/bin/openssl', 'genrsa', '-out', str(rsa), '2048'], capture_output=True, check=True)
    return key, cert, rsa


class Peer:
    def __init__(self, executable, security, parameters):
        self.process = subprocess.Popen([str(executable), security, *parameters], stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True)
        self.lines = queue.Queue()
        threading.Thread(target=self.pump, daemon=True).start()
        self.endpoint = self.expect(lambda line: line.startswith('127.0.0.1::'), 10)

    def pump(self):
        for line in self.process.stdout:
            self.lines.put(line.strip())

    def expect(self, predicate, timeout):
        deadline, seen = time.monotonic() + timeout, []
        while time.monotonic() < deadline:
            try: line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty: break
            seen.append(line)
            if predicate(line): return line
            if line.startswith('closed ') and line != 'closed normally':
                raise AssertionError(f'peer: {line}')
        raise AssertionError(f'peer did not report the expected event; saw {seen}')

    def stop(self):
        self.process.terminate()
        try: self.process.wait(5)
        except subprocess.TimeoutExpired: self.process.kill()


def run_case(app, peer_executable, accessibility, name, work, key, cert, rsa):
    security, uses_ca, needs_prompt = CASES[name]
    parameters = [f'VncPassword={PASSWORD}']
    if security.startswith('X509'): parameters += [f'X509Cert={cert}', f'X509Key={key}']
    if security.startswith('RA2'): parameters += [f'RSAKey={rsa}']
    peer = Peer(peer_executable, security, parameters)
    arguments = [f'-SecurityTypes={security}', '-SendClipboard=0', '-AcceptClipboard=0', '-ReconnectOnError=0']
    if uses_ca: arguments.append(f'-X509CA={cert}')
    state = work / name
    process = isolated.launch(app, state, [*arguments, peer.endpoint], extra_env={'VNC_PASSWORD': PASSWORD})['process']
    try:
        peer.expect(lambda line: line == 'accepted', 30)
        if needs_prompt:
            result = subprocess.run([str(accessibility), str(process.pid), 'wait', 'authentication.trust',
                                     'press', 'authentication.trust'], capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise AssertionError(f'could not answer the server-key prompt: {result.stdout.strip()} {result.stderr.strip()}')
        peer.expect(lambda line: line == f'authenticated {security}', 30)
        peer.expect(lambda line: line == 'request', 15)
        time.sleep(0.5)
        assert process.poll() is None, f'viewer exited (code {process.returncode})'
        print(f'PASS {name}: {security} authenticated and the app requested a framebuffer update', flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        isolated.cleanup(state)
        peer.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path, help='TidyVNC.app built from build/native-ui-frontend')
    parser.add_argument('--peer', type=Path, default=ROOT / 'build/native-ui-frontend/core/tests/macos/native-security-peer')
    parser.add_argument('--case', action='append', choices=sorted(CASES))
    parser.add_argument('--accept-prompts', action='store_true', help='answer server-key prompts via the accessibility API')
    args = parser.parse_args()
    cases = args.case or [name for name, (_, _, prompt) in CASES.items() if args.accept_prompts or not prompt]
    skipped = [name for name in cases if CASES[name][2] and not args.accept_prompts]
    if skipped:
        parser.error(f'{", ".join(skipped)} need --accept-prompts')
    with tempfile.TemporaryDirectory(prefix='tidyvnc-security-smoke-') as temporary:
        work = Path(temporary)
        key, cert, rsa = materials(work)
        accessibility = None
        if args.accept_prompts:
            accessibility = work / 'accessibility-audit'
            subprocess.run(['xcrun', 'swiftc', '-O', str(ROOT / 'tests/macos/AccessibilityAudit.swift'), '-o', str(accessibility)],
                           check=True)
        for name in cases:
            run_case(args.app.resolve(), args.peer.resolve(), accessibility, name, work, key, cert, rsa)
    print(f'{len(cases)} actual-app security handshakes completed; displayed UI was not asserted.')


if __name__ == '__main__':
    sys.exit(main())
