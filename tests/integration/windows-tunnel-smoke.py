#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in actual-app SSH tunnel on Windows: the WinUI viewer reaches a VNC
server through a real loopback OpenSSH daemon (plans/native-ui-winui TODO
W6.12; the port of macos-tunnel-smoke.py).

Starts MSYS2's sshd as the current user on 127.0.0.1 with fresh host and client
keys (public-key only, local forwarding only, this user only) and
native-security-peer (VncAuth) as the VNC server. The viewer runs through
`vncviewer.exe` with an isolated TIDYVNC_STATE_ROOT (Debug publish: Release
ignores it). An isolated root makes the SSH gateway read `ssh\\config` and
`ssh\\known_hosts` inside it instead of %USERPROFILE%\\.ssh: the config names
the client key, and known_hosts already trusts the fixture host key. The viewer
connects with -via ssh://user@127.0.0.1:<port> through Windows' own ssh.exe.
The case passes when sshd accepted the client key, the VNC server
authenticated the session and the viewer requested a framebuffer update.

Needs MSYS2 with openssh (`usr/bin/sshd.exe`, `usr/bin/ssh-keygen.exe`), the
Windows OpenSSH Client, and the MinGW-built native-security-peer. Nothing
outside the temporary directory is read or written, and sshd stops with the
test. A viewer window appears, so it runs only with TIDYVNC_UI_TESTS=1 and when
nobody has used the desktop for a minute.
"""
import argparse
import getpass
import importlib.util
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('security_smoke', ROOT / 'tests/integration/windows-security-smoke.py')
security = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security)
MSYS = security.MSYS
SSH_CLIENT = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/OpenSSH/ssh.exe'


def posix(path):
    """An MSYS2 path for a Windows one (sshd reads its configuration through the MSYS2 runtime)."""
    text = str(Path(path).resolve())
    return '/' + text[0].lower() + text[2:].replace('\\', '/')


def private_directory(path):
    """A directory only this user and SYSTEM can use, owned by this user, as the app's state root must be."""
    path.mkdir(parents=True)
    user = f'{os.environ["USERDOMAIN"]}\\{os.environ["USERNAME"]}'
    # Removing inheritance can leave the parent's Administrators entry behind as an explicit one; drop it too.
    for arguments in (['/setowner', user], ['/inheritance:r'], ['/grant:r', f'{user}:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'],
                      ['/remove:g', '*S-1-5-32-544']):
        subprocess.run(['icacls', str(path), *arguments], capture_output=True, check=True)
    listing = subprocess.run(['icacls', str(path)], capture_output=True, text=True, check=True).stdout
    assert 'Administrators' not in listing, f'state root is not private: {listing}'


def start_sshd(work, user):
    keys = work / 'sshd'
    keys.mkdir()
    keygen = MSYS / 'usr/bin/ssh-keygen.exe'
    for name in ('host', 'client'):
        subprocess.run([str(keygen), '-q', '-t', 'ed25519', '-N', '', '-f', posix(keys / name)], check=True)
    (keys / 'authorized').write_bytes((keys / 'client.pub').read_bytes())
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    config = keys / 'sshd_config'
    config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {posix(keys / 'host')}
PidFile {posix(keys / 'sshd.pid')}
AuthorizedKeysFile {posix(keys / 'authorized')}
AllowUsers {user}
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowTcpForwarding local
AllowStreamLocalForwarding no
AllowAgentForwarding no
PermitTunnel no
X11Forwarding no
PrintMotd no
LogLevel VERBOSE
""", newline='\n')
    log = keys / 'sshd.log'
    env = dict(os.environ, PATH=str(MSYS / 'usr/bin') + os.pathsep + os.environ.get('PATH', ''))
    process = subprocess.Popen([str(MSYS / 'usr/bin/sshd.exe'), '-D', '-e', '-f', posix(config)], env=env,
                               stdout=subprocess.DEVNULL, stderr=open(log, 'wb'))
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.5):
                break
        except OSError:
            if process.poll() is not None:
                break
            time.sleep(0.1)
    else:
        process.kill()
        raise AssertionError('sshd did not start: ' + log.read_text(errors='replace')[-800:])
    if process.poll() is not None:
        raise AssertionError('sshd exited: ' + log.read_text(errors='replace')[-800:])
    return process, port, keys, log


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('viewer', type=Path, help='vncviewer.exe of a Debug publish (build/winui/app-x64-debug)')
    parser.add_argument('--peer', type=Path, default=ROOT / 'build/mingw/viewer/tests/native-security-peer.exe')
    args = parser.parse_args()
    if os.environ.get('TIDYVNC_UI_TESTS') != '1':
        parser.exit(2, 'This test opens a viewer window; set TIDYVNC_UI_TESTS=1 to run it.\n')
    if security.idle_seconds() < 60:
        parser.exit(2, f'The desktop is in use (idle {security.idle_seconds():.0f} s); not opening windows on it.\n')
    for required in (MSYS / 'usr/bin/sshd.exe', MSYS / 'usr/bin/ssh-keygen.exe', SSH_CLIENT):
        if not required.is_file():
            print(f'SKIP: {required} is missing')
            return 77
    user = getpass.getuser()
    with tempfile.TemporaryDirectory(prefix='tidyvnc-tunnel-smoke-') as temporary:
        work = Path(temporary)
        sshd, port, keys, log = start_sshd(work, user)
        state = work / 'state'
        private_directory(state)
        ssh = state / 'ssh'
        ssh.mkdir()
        (ssh / 'client').write_bytes((keys / 'client').read_bytes())
        kind, key, *_ = (keys / 'host.pub').read_text().split()
        (ssh / 'known_hosts').write_text(f'[127.0.0.1]:{port} {kind} {key}\n')
        (ssh / 'config').write_text(f'Host 127.0.0.1\n  IdentityFile "{ssh / "client"}"\n  IdentitiesOnly yes\n')
        peer = security.Peer(args.peer.resolve(), 'VncAuth', [f'VncPassword={security.PASSWORD}'])
        env = {k: v for k, v in os.environ.items() if not k.upper().startswith(('VNC_', 'TIDYVNC_', 'SSH_'))}
        env['TIDYVNC_STATE_ROOT'] = str(state)
        env['VNC_PASSWORD'] = security.PASSWORD
        process = subprocess.Popen([str(args.viewer.resolve()), '-SecurityTypes=VncAuth', '-SendClipboard=0', '-AcceptClipboard=0',
                                    '-ReconnectOnError=0', f'-via=ssh://{user}@127.0.0.1:{port}', peer.endpoint],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            peer.expect(lambda line: line == 'accepted', 45)
            peer.expect(lambda line: line == 'authenticated VncAuth', 30)
            peer.expect(lambda line: line == 'request', 15)
            time.sleep(0.5)
            assert process.poll() is None, f'viewer exited (code {process.returncode})'
            sshd_log = log.read_text(errors='replace')
            assert 'Accepted publickey for' in sshd_log, 'sshd did not accept the fixture key'
            assert 'direct-tcpip' in sshd_log or 'Connection from 127.0.0.1' in sshd_log, 'sshd saw no forward'
            print(f'PASS tunnel: VncAuth through sshd on 127.0.0.1:{port} (Windows ssh.exe -W) authenticated and the viewer '
                  'requested a framebuffer update', flush=True)
        except AssertionError:
            print('sshd log:', log.read_text(errors='replace')[-2000:])
            viewer_log = state / 'vncviewer.log'
            if viewer_log.is_file():
                print('viewer log:', viewer_log.read_text(errors='replace')[-2000:])
            raise
        finally:
            if process.poll() is None:
                subprocess.run(['taskkill', '/T', '/F', '/PID', str(process.pid)], capture_output=True)
                process.wait(10)
            peer.stop()
            sshd.kill()
            sshd.wait(10)
    print('1 actual-app SSH tunnel completed; displayed UI was not asserted.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
