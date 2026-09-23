#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in actual-app VNC authentication smoke test for the native macOS viewer.

Each case launches an isolated copy of the app (unique bundle identifier and
preference domains, fresh HOME/XDG, see tests/macos/isolated-app.py) against a
loopback-only RFB 3.8 peer that offers only VncAuth and verifies the DES response:

  correct   VNC_PASSWORD matches: the viewer finishes the handshake and requests
            a framebuffer update.
  rejected  VNC_PASSWORD is wrong: the peer rejects it once; the viewer must not
            retry automatically and must stay running.
  vanished  no credentials: the viewer parks at its password prompt while the peer
            closes the socket; it must stay running and not reconnect.
  untrusted VeNCrypt X509None with a fresh self-signed certificate: the TLS
            handshake completes but the viewer never continues the RFB handshake
            (whether it waits for a decision or aborts), survives the peer leaving
            and does not reconnect.

Requires WindowServer (the prompt and alerts appear on screen), codesign, a Swift
compiler and /usr/bin/openssl (DES and a throwaway certificate). Nothing is typed into the app; displayed
UI is not asserted.
"""
import argparse
import importlib.util
import os
import signal
import ssl
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('isolated_app', ROOT / 'tests/macos/isolated-app.py')
isolated = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolated)

PASSWORD = 'fixture-pw'


def vnc_response(challenge, password):
    """RFB VncAuth: DES-ECB of the challenge, key = password bytes bit-reversed."""
    key = bytes(int(f'{(password.encode() + bytes(8))[i]:08b}'[::-1], 2) for i in range(8))
    result = subprocess.run(['/usr/bin/openssl', 'enc', '-des-ecb', '-nopad', '-K', key.hex()],
                            input=challenge, capture_output=True, check=True)
    return result.stdout


def read_exact(connection, count, timeout=10):
    connection.settimeout(timeout)
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise AssertionError('viewer closed the connection early')
        data.extend(chunk)
    return bytes(data)


def handshake(connection):
    connection.sendall(b'RFB 003.008\n')
    assert read_exact(connection, 12) == b'RFB 003.008\n'
    connection.sendall(b'\1\2')                      # one security type: VncAuth
    assert read_exact(connection, 1) == b'\2'
    challenge = os.urandom(16)
    connection.sendall(challenge)
    return challenge


def self_signed(directory):
    key, cert = directory / 'key.pem', directory / 'cert.pem'
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)],
                   capture_output=True, check=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    return context


def untrusted_tls(connection, context):
    connection.sendall(b'RFB 003.008\n')
    assert read_exact(connection, 12) == b'RFB 003.008\n'
    connection.sendall(bytes([1, 19]))                # one security type: VeNCrypt
    assert read_exact(connection, 1) == bytes([19])
    connection.sendall(bytes([0, 2]))                 # VeNCrypt 0.2
    assert read_exact(connection, 2) == bytes([0, 2])
    connection.sendall(bytes([0]))                    # version accepted
    connection.sendall(bytes([1]) + struct.pack('>I', 260))   # only X509None
    assert struct.unpack('>I', read_exact(connection, 4))[0] == 260
    connection.sendall(bytes([1]))                    # ready for TLS
    connection.settimeout(10)
    tls = context.wrap_socket(connection, server_side=True)
    # The viewer must neither continue the RFB handshake nor send anything while
    # its decision about the untrusted certificate is pending.
    tls.settimeout(1.5)
    try:
        data = tls.recv(1)
    except (socket.timeout, TimeoutError):
        data = None
    except ssl.SSLError:
        data = None                                   # an alert on abort is acceptable
    assert not data, 'viewer continued past an untrusted certificate'
    try: tls.shutdown(socket.SHUT_RDWR)
    except OSError: pass
    tls.close()


def accept(listener, timeout):
    listener.settimeout(timeout)
    try:
        return listener.accept()[0]
    except (socket.timeout, TimeoutError):
        return None


def run_case(app, case, work):
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(4)
    port = listener.getsockname()[1]
    env = {} if case in ('vanished', 'untrusted') else {'VNC_PASSWORD': PASSWORD if case == 'correct' else 'wrong-pw'}
    state = work / case
    security = 'X509None' if case == 'untrusted' else 'VncAuth'
    context = self_signed(work) if case == 'untrusted' else None
    launched = isolated.launch(app, state, [f'-SecurityTypes={security}', '-SendClipboard=0', '-AcceptClipboard=0',
                                            f'127.0.0.1::{port}'], extra_env=env)
    process = launched['process']
    try:
        connection = accept(listener, 30)
        assert connection, 'viewer did not connect'
        if case == 'untrusted':
            untrusted_tls(connection, context)
        else:
          with connection:
            challenge = handshake(connection)
            if case == 'vanished':
                time.sleep(1.5)                          # viewer is parked at its prompt
                connection.shutdown(socket.SHUT_RDWR)
            else:
                response = read_exact(connection, 16)
                expected = vnc_response(challenge, PASSWORD)
                if case == 'correct':
                    assert response == expected, 'correct VNC_PASSWORD produced a wrong response'
                    connection.sendall(struct.pack('>I', 0))
                    read_exact(connection, 1)            # ClientInit
                    pixel_format = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
                    name = b'auth fixture'
                    connection.sendall(struct.pack('>HH', 64, 48) + pixel_format + struct.pack('>I', len(name)) + name)
                    deadline = time.monotonic() + 10
                    requested = False
                    while time.monotonic() < deadline and not requested:
                        kind = read_exact(connection, 1)[0]
                        if kind == 3: read_exact(connection, 9); requested = True
                        elif kind == 2: read_exact(connection, 1); read_exact(connection, 4 * struct.unpack('>H', read_exact(connection, 2))[0])
                        elif kind == 0: read_exact(connection, 19)
                        elif kind == 4: read_exact(connection, 7)
                        elif kind == 5: read_exact(connection, 5)
                        elif kind == 150: read_exact(connection, 9)
                        else: raise AssertionError(f'unexpected client message {kind}')
                    assert requested, 'authenticated viewer never requested a framebuffer update'
                else:
                    assert response != expected, 'fixture error: wrong password matched'
                    reason = b'Authentication failed'
                    connection.sendall(struct.pack('>II', 1, len(reason)) + reason)
        if case in ('rejected', 'vanished', 'untrusted'):
            again = accept(listener, 3)
            if again: again.close()
            assert again is None, 'viewer reconnected without an explicit Retry'
        time.sleep(0.5)
        assert process.poll() is None, f'viewer exited (code {process.returncode})'
        print(f'PASS {case}', flush=True)
    finally:
        listener.close()
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try: process.wait(10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        isolated.cleanup(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path, help='TidyVNC.app built from build/native-ui-frontend')
    parser.add_argument('--case', action='append', choices=['correct', 'rejected', 'vanished', 'untrusted'])
    args = parser.parse_args()
    cases = args.case or ['correct', 'rejected', 'vanished', 'untrusted']
    with tempfile.TemporaryDirectory(prefix='tidyvnc-auth-smoke-') as temporary:
        for case in cases:
            run_case(args.app.resolve(), case, Path(temporary))
    print(f'{len(cases)} actual-app authentication cases passed; displayed UI was not asserted.')


if __name__ == '__main__':
    sys.exit(main())
