#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in actual-app SSH tunnel: the native app reaches a VNC server through a
real loopback OpenSSH daemon.

Starts /usr/sbin/sshd on 127.0.0.1 with fresh host and client keys (public-key
only, local forwarding only, the current user only) and native-security-peer
(VncAuth) as the VNC server. An isolated copy of the app (tests/macos/
isolated-app.py, which also removes SSH_AUTH_SOCK) gets an isolated
~/.ssh/config naming the client key and a known_hosts file that already trusts
the fixture host key, and connects with -via ssh://user@127.0.0.1:<port>. The
case passes when sshd accepted the client key, the VNC server authenticated
the session and the app requested a framebuffer update.

Requires WindowServer, /usr/sbin/sshd, ssh-keygen, codesign and a Swift
compiler. Nothing outside the temporary directory is read or written.
"""
import argparse
import importlib.util
import os
import pwd
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


def start_sshd(root):
    for name in ('host', 'client'):
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / name)], check=True)
    authorized = root / 'authorized'
    authorized.write_bytes((root / 'client.pub').read_bytes()); authorized.chmod(0o600)
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
    kind, key, *_ = (root / 'host.pub').read_text().split()
    (root / 'known_hosts').write_text(f'[127.0.0.1]:{port} {kind} {key}\n')
    user = pwd.getpwuid(os.getuid()).pw_name
    config = root / 'sshd_config'
    config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root / 'host'}
PidFile {root / 'sshd.pid'}
AuthorizedKeysFile {authorized}
AllowUsers {user}
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowTcpForwarding local
AllowStreamLocalForwarding no
PermitTunnel no
X11Forwarding no
PrintMotd no
LogLevel VERBOSE
""")
    log = root / 'sshd.log'
    process = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stderr=open(log, 'wb'))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.5): break
        except OSError: time.sleep(0.1)
    else:
        process.terminate(); raise AssertionError('sshd did not start: ' + log.read_text()[-500:])
    return process, port, user, log


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path, help='TidyVNC.app built from build/native-ui-frontend')
    parser.add_argument('--peer', type=Path, default=ROOT / 'build/native-ui-frontend/core/tests/macos/native-security-peer')
    args = parser.parse_args()
    if not Path('/usr/sbin/sshd').is_file():
        print('SKIP: system sshd is unavailable'); return 77
    with tempfile.TemporaryDirectory(prefix='tidyvnc-tunnel-smoke-') as temporary:
        root = Path(temporary)
        sshd, port, user, log = start_sshd(root)
        peer = security.Peer(args.peer.resolve(), 'VncAuth', [f'VncPassword={security.PASSWORD}'])
        state = root / 'app'
        ssh_config = (f'Host 127.0.0.1\n  IdentityFile {root / "client"}\n  IdentitiesOnly yes\n'
                      f'  UserKnownHostsFile {root / "known_hosts"}\n')
        process = isolated.launch(args.app.resolve(), state,
                                  ['-SecurityTypes=VncAuth', '-SendClipboard=0', '-AcceptClipboard=0', '-ReconnectOnError=0',
                                   f'-via=ssh://{user}@127.0.0.1:{port}', peer.endpoint],
                                  extra_env={'VNC_PASSWORD': security.PASSWORD},
                                  home_files={'.ssh/config': ssh_config})['process']
        try:
            peer.expect(lambda line: line == 'accepted', 45)
            peer.expect(lambda line: line == 'authenticated VncAuth', 30)
            peer.expect(lambda line: line == 'request', 15)
            time.sleep(0.5)
            assert process.poll() is None, f'viewer exited (code {process.returncode})'
            sshd_log = log.read_text()
            assert 'Accepted publickey for' in sshd_log, 'sshd did not accept the fixture key'
            print(f'PASS tunnel: VncAuth through sshd on 127.0.0.1:{port} authenticated and the app requested '
                  'a framebuffer update', flush=True)
        except AssertionError:
            print('sshd log:', log.read_text()[-2000:]); print('app log:', (state / 'app.log').read_text()[-2000:])
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            isolated.cleanup(state)
            peer.stop(); sshd.terminate(); sshd.wait(10)


if __name__ == '__main__':
    sys.exit(main())
