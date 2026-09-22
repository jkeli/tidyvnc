#!/usr/bin/env python3
"""Exercise the native tunnel against an isolated loopback OpenSSH daemon."""
import os
from pathlib import Path
import pwd
import signal
import socket
import subprocess
import sys
import tempfile
import time


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: tunnel-ssh.py native-tunnel-tests")
    sshd = Path("/usr/sbin/sshd")
    if not sshd.is_file():
        print("SKIP: system sshd is unavailable; real SSH acceptance remains open")
        return 77
    with tempfile.TemporaryDirectory(prefix="tidyvnc-ssh-acceptance-") as temporary:
        root = Path(temporary)
        for name in ("host", "client"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        authorized = root / "authorized"
        authorized.write_bytes((root / "client.pub").read_bytes())
        authorized.chmod(0o600)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        known = root / "known_hosts"
        kind, key, *_ = (root / "host.pub").read_text().split()
        known.write_text(f"[127.0.0.1]:{port} {kind} {key}\n")
        user = pwd.getpwuid(os.getuid()).pw_name
        config = root / "sshd_config"
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
StrictModes yes
AllowTcpForwarding local
AllowStreamLocalForwarding local
PermitTunnel no
X11Forwarding no
PrintMotd no
LogLevel ERROR
""")
        with (root / "server.log").open("wb") as log:
            server = subprocess.Popen([str(sshd), "-D", "-e", "-f", str(config)],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while True:
                    if hasattr(os, "waitid") and os.waitid(os.P_PID, server.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
                        print("SKIP: isolated sshd cannot start under this host account; real SSH acceptance remains open")
                        return 77
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            print("SKIP: isolated SSH listener did not start; real SSH acceptance remains open")
                            return 77
                        time.sleep(0.02)
                result = subprocess.run([sys.argv[1], "--ssh", f"ssh://{user}@127.0.0.1:{port}",
                                         str(root / "client"), str(known)], timeout=35, check=False)
                return result.returncode
            finally:
                # The leader remains unreaped, pinning this exact fixture group
                # until all daemon/session processes receive the cleanup signal.
                try:
                    os.killpg(server.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                server.wait()


if __name__ == "__main__":
    raise SystemExit(main())
