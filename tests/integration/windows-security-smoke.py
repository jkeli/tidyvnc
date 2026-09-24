#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in actual-app security handshakes on Windows against the project's real
server side (plans/native-ui-winui TESTING.md section 5, TODO W6.12; the port
of macos-security-smoke.py).

Each case runs the WinUI viewer through `vncviewer.exe` with an isolated
TIDYVNC_STATE_ROOT (Debug publish: Release ignores it) against
native-security-peer, a loopback RFB server built with MinGW from the project's
server-side handlers. A case passes when the peer reports that authentication
succeeded and the viewer then requested a framebuffer update, and the viewer is
still running. Credentials come from VNC_PASSWORD (launch credentials, never
saved).

  vncauth              VncAuth
  tlsnone / tlsvnc     anonymous TLS, without and with VncAuth
  x509none / x509vnc   X509 with a fresh certificate trusted through -X509CA
  ra2, ra2ne, ra2_256, ra2ne_256
                       RSA-AES; the viewer asks to verify the new server key,
                       which --accept-prompts answers with "Connect once" through
                       UI Automation (windows-invoke.ps1, Invoke pattern only)
  reconnect            VncAuth; the peer drops the session after its first
                       update, the viewer's problem dialog offers Retry, which
                       --accept-prompts presses; a second session must
                       authenticate with the same launch credentials

Needs MSYS2 (`usr/bin/openssl.exe`, and the MINGW64 runtime DLLs for the peer).
Viewer windows appear, so it runs only with TIDYVNC_UI_TESTS=1 and when nobody
has used the desktop for a minute. Displayed UI is not asserted.
"""
import argparse
import ctypes
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MSYS = Path(os.environ.get('MSYS2_ROOT', r'C:\msys64'))
# Eight characters: the server stores VNC passwords in the classic 8-byte form.
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
    'reconnect': ('VncAuth', False, True),
}


def idle_seconds():
    class LastInput(ctypes.Structure):
        _fields_ = [("size", ctypes.c_uint), ("time", ctypes.c_uint)]
    info = LastInput(ctypes.sizeof(LastInput), 0)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
        return 0
    return ((ctypes.windll.kernel32.GetTickCount() - info.time) & 0xFFFFFFFF) / 1000


def materials(work):
    openssl = MSYS / 'usr/bin/openssl.exe'
    key, cert, rsa = work / 'x509-key.pem', work / 'x509-cert.pem', work / 'rsa-key.pem'
    subprocess.run([str(openssl), 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                    '-keyout', str(key), '-out', str(cert)], capture_output=True, check=True)
    subprocess.run([str(openssl), 'genrsa', '-out', str(rsa), '2048'], capture_output=True, check=True)
    return key, cert, rsa


class Peer:
    def __init__(self, executable, security, parameters, close_after_update=False):
        options = ['--close-after-update'] if close_after_update else []
        env = dict(os.environ, PATH=str(MSYS / 'mingw64/bin') + os.pathsep + os.environ.get('PATH', ''))
        self.process = subprocess.Popen([str(executable), *options, security, *parameters], stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, env=env)
        self.lines = queue.Queue()
        threading.Thread(target=self.pump, daemon=True).start()
        self.endpoint = self.expect(lambda line: line.startswith('127.0.0.1::'), 10)

    def pump(self):
        for line in self.process.stdout:
            self.lines.put(line.strip())

    def expect(self, predicate, timeout):
        deadline, seen = time.monotonic() + timeout, []
        while time.monotonic() < deadline:
            try:
                line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            seen.append(line)
            if predicate(line):
                return line
            if line.startswith('closed ') and line != 'closed normally':
                raise AssertionError(f'peer: {line}')
        raise AssertionError(f'peer did not report the expected event; saw {seen}')

    def stop(self):
        self.process.kill()
        self.process.wait(10)


def press(launcher, dialog, button='PrimaryButton'):
    result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                             str(Path(__file__).with_name('windows-invoke.ps1')), '-LauncherId', str(launcher.pid),
                             '-DialogId', dialog, '-ButtonId', button], capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise AssertionError(f'could not press {button} in {dialog}: {result.stdout.strip()} {result.stderr.strip()}')


def run_case(viewer, peer_executable, accept_prompts, name, work, key, cert, rsa):
    security, uses_ca, needs_prompt = CASES[name]
    parameters = [f'VncPassword={PASSWORD}']
    if security.startswith('X509'):
        parameters += [f'X509Cert={cert}', f'X509Key={key}']
    if security.startswith('RA2'):
        parameters += [f'RSAKey={rsa}']
    reconnect = name == 'reconnect'
    peer = Peer(peer_executable, security, parameters, close_after_update=reconnect)
    arguments = [f'-SecurityTypes={security}', '-SendClipboard=0', '-AcceptClipboard=0',
                 '-ReconnectOnError=1' if reconnect else '-ReconnectOnError=0']
    if uses_ca:
        arguments.append(f'-X509CA={cert}')
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(('VNC_', 'TIDYVNC_'))}
    env['TIDYVNC_STATE_ROOT'] = str(work / name / 'state')
    env['VNC_PASSWORD'] = PASSWORD
    process = subprocess.Popen([str(viewer), *arguments, peer.endpoint], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        peer.expect(lambda line: line == 'accepted', 30)
        if needs_prompt and not reconnect:
            press(process, 'trust.dialog')
        peer.expect(lambda line: line == f'authenticated {security}', 30)
        peer.expect(lambda line: line == 'request', 15)
        if reconnect:
            peer.expect(lambda line: line == 'closing after update', 10)
            press(process, 'connection.problem')
            peer.expect(lambda line: line == 'accepted', 30)
            peer.expect(lambda line: line == f'authenticated {security}', 30)
            peer.expect(lambda line: line == 'request', 15)
        time.sleep(0.5)
        assert process.poll() is None, f'viewer exited (code {process.returncode})'
        detail = 'reconnected through Retry after the server dropped the session; ' if reconnect else ''
        print(f'PASS {name}: {detail}{security} authenticated and the viewer requested a framebuffer update', flush=True)
    finally:
        if process.poll() is None:
            subprocess.run(['taskkill', '/T', '/F', '/PID', str(process.pid)], capture_output=True)
            process.wait(10)
        peer.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('viewer', type=Path, help='vncviewer.exe of a Debug publish (build/winui/app-x64-debug)')
    parser.add_argument('--peer', type=Path, default=ROOT / 'build/mingw/viewer/tests/native-security-peer.exe')
    parser.add_argument('--case', action='append', choices=sorted(CASES))
    parser.add_argument('--accept-prompts', action='store_true', help='answer prompts through UI Automation')
    args = parser.parse_args()
    if os.environ.get('TIDYVNC_UI_TESTS') != '1':
        parser.exit(2, 'This test opens viewer windows; set TIDYVNC_UI_TESTS=1 to run it.\n')
    if idle_seconds() < 60:
        parser.exit(2, f'The desktop is in use (idle {idle_seconds():.0f} s); not opening windows on it.\n')
    cases = args.case or [name for name, (_, _, prompt) in CASES.items() if args.accept_prompts or not prompt]
    skipped = [name for name in cases if CASES[name][2] and not args.accept_prompts]
    if skipped:
        parser.error(f'{", ".join(skipped)} need --accept-prompts')
    with tempfile.TemporaryDirectory(prefix='tidyvnc-security-smoke-') as temporary:
        work = Path(temporary)
        key, cert, rsa = materials(work)
        for name in cases:
            run_case(args.viewer.resolve(), args.peer.resolve(), args.accept_prompts, name, work, key, cert, rsa)
    print(f'{len(cases)} actual-app security handshakes completed; displayed UI was not asserted.')


if __name__ == '__main__':
    sys.exit(main())
