#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Ctrl+C in real consoles (plans/native-ui-winui D9, TODO W0.10).

For cmd.exe, Windows PowerShell and PowerShell 7 (when installed), a helper
process with its own hidden console starts vncviewer.exe through that shell
against a loopback RFB server. When the viewer has connected and asked for a
frame, the helper sends Ctrl+C to its console. Checked:

- the viewer's connection closes (the GUI closed its window);
- no TidyVNC.exe from this publish remains;
- vncviewer.exe, and the shell around it, end with the GUI's exit status (0)
  rather than being killed by the signal.

Each case uses an isolated TIDYVNC_STATE_ROOT, so --viewer must be a Debug or
measurement publish. The viewer window appears on the desktop, so like the UI
suite this runs only with TIDYVNC_UI_TESTS=1 and a desktop idle for a minute.
"""
import argparse
import ctypes
import json
import os
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PWSH = Path(r'C:\Program Files\PowerShell\7\pwsh.exe')
WINDOWS_POWERSHELL = Path(os.environ.get('SystemRoot', r'C:\Windows')) / r'System32\WindowsPowerShell\v1.0\powershell.exe'
CREATE_NEW_CONSOLE, STARTF_USESHOWWINDOW, SW_HIDE, CTRL_C_EVENT = 0x10, 0x1, 0, 0


def idle_seconds():
    class LastInput(ctypes.Structure):
        _fields_ = [('size', ctypes.c_uint), ('time', ctypes.c_uint)]
    info = LastInput(ctypes.sizeof(LastInput), 0)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
        return 0
    return ((ctypes.windll.kernel32.GetTickCount() - info.time) & 0xFFFFFFFF) / 1000


def gui_processes(folder):
    script = (f"Get-CimInstance Win32_Process -Filter \"Name='TidyVNC.exe'\" | "
              f"Where-Object {{ $_.ExecutablePath -like '{folder}\\*' }} | ForEach-Object {{ $_.ProcessId }}")
    output = subprocess.run([str(WINDOWS_POWERSHELL), '-NoProfile', '-Command', script], capture_output=True, text=True).stdout
    return {int(p) for p in output.split()}


def close_gui(pid):
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.OpenEventW.restype = ctypes.c_void_p
    handle = kernel32.OpenEventW(0x0002, False, f'Local\\TidyVNC-close-{pid}')
    if handle:
        kernel32.SetEvent(ctypes.c_void_p(handle))
        kernel32.CloseHandle(ctypes.c_void_p(handle))


def shell_command(shell, viewer, port):
    arguments = [str(viewer), '-SecurityTypes=None', '-AlertOnFatalError=0', '-ReconnectOnError=0', f'127.0.0.1::{port}']
    if shell == 'cmd':
        return f'cmd.exe /d /s /c "{subprocess.list2cmdline(arguments)}"'
    quoted = ' '.join("'" + a.replace("'", "''") + "'" for a in arguments)
    # Ctrl+C stops a PowerShell script (its own status would be 1); finally still runs and reports the launcher's.
    return [str(shell), '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', f'try {{ & {quoted} }} finally {{ exit $LASTEXITCODE }}']


def child(shell, viewer, port, go, result):
    """In its own console: start the shell, wait for the go file, press Ctrl+C, report the shell's status."""
    kernel32 = ctypes.windll.kernel32
    # A process started with Ctrl+C disabled (as tool runners often start them) passes that on to its
    # children; the shell and the launcher must see Ctrl+C as they would in a terminal.
    kernel32.SetConsoleCtrlHandler(None, False)
    process = subprocess.Popen(shell_command(shell, viewer, port))
    # Ignore Ctrl+C here only after the shell has started, so the shell and the launcher do not inherit it.
    kernel32.SetConsoleCtrlHandler(None, True)
    deadline = time.monotonic() + 90
    while not Path(go).exists() and time.monotonic() < deadline and process.poll() is None:
        time.sleep(0.05)
    sent = time.monotonic()
    kernel32.GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)
    try:
        code = process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        code = None
    Path(result).write_text(json.dumps({'exit': code, 'seconds': round(time.monotonic() - sent, 2)}))


def serve_until_request(connection):
    def read(count):
        data = bytearray()
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                raise ConnectionError('viewer closed during the handshake')
            data.extend(chunk)
        return bytes(data)
    connection.sendall(b'RFB 003.008\n'); read(12)
    connection.sendall(b'\1\1'); read(1)
    connection.sendall(b'\0\0\0\0'); read(1)
    name = b'console fixture'
    connection.sendall(struct.pack('>HH', 64, 48) + struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
                       + struct.pack('>I', len(name)) + name)
    while True:
        kind = read(1)[0]
        if kind == 0: read(19)
        elif kind == 2: read(4 * struct.unpack('>xH', read(3))[0])
        elif kind == 3:
            read(9)
            connection.sendall(b'\0\0\0\1' + struct.pack('>HHHHi', 0, 0, 64, 48, 0) + b'\x40\x80\xc0\x00' * (64 * 48))
            return
        elif kind == 4: read(7)
        elif kind == 5: read(5)
        elif kind == 150: read(9)
        else: raise AssertionError(f'unexpected client message {kind}')


def closed_within(connection, seconds):
    end = time.monotonic() + seconds
    connection.setblocking(False)
    while time.monotonic() < end:
        if select.select([connection], [], [], 0.25)[0]:
            try:
                if not connection.recv(65536):
                    return True
            except (ConnectionResetError, ConnectionAbortedError):
                return True
            except BlockingIOError:
                pass
    return False


def case(shell, viewer, work):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(60)
        go, result = work / f'{Path(str(shell)).stem}.go', work / f'{Path(str(shell)).stem}.json'
        env = {k: v for k, v in os.environ.items() if not k.upper().startswith(('VNC_', 'TIDYVNC_'))}
        env['TIDYVNC_STATE_ROOT'] = str(work / f'state-{Path(str(shell)).stem}')
        startup = subprocess.STARTUPINFO(dwFlags=STARTF_USESHOWWINDOW, wShowWindow=SW_HIDE)
        helper = subprocess.Popen([sys.executable, __file__, '--child', str(shell), str(viewer), str(listener.getsockname()[1]),
                                   str(go), str(result)], env=env, creationflags=CREATE_NEW_CONSOLE, startupinfo=startup)
        connection, _ = listener.accept()
        with connection:
            serve_until_request(connection)
            time.sleep(1.0)  # The window is up and presenting.
            go.write_text('go')
            closed = closed_within(connection, 30)
        helper.wait(timeout=90)
        outcome = json.loads(result.read_text())
        return closed, outcome


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--child', nargs=5, metavar=('SHELL', 'VIEWER', 'PORT', 'GO', 'RESULT'), help=argparse.SUPPRESS)
    parser.add_argument('viewer', type=Path, nargs='?', help='vncviewer.exe of a Debug or measurement publish')
    args = parser.parse_args()
    if args.child:
        child(*args.child)
        return
    if not args.viewer:
        parser.error('give vncviewer.exe')
    if os.environ.get('TIDYVNC_UI_TESTS') != '1':
        parser.exit(2, 'This opens viewer windows; set TIDYVNC_UI_TESTS=1 to run it.\n')
    if idle_seconds() < 60:
        parser.exit(2, f'The desktop is in use (idle {idle_seconds():.0f} s); not opening windows on it.\n')
    viewer = args.viewer.resolve()
    shells = [('cmd', 'cmd')] + ([('powershell', WINDOWS_POWERSHELL)] if WINDOWS_POWERSHELL.exists() else []) \
        + ([('pwsh', PWSH)] if PWSH.exists() else [])
    before = gui_processes(viewer.parent)
    failures = []
    with tempfile.TemporaryDirectory(prefix='tidyvnc-console-', ignore_cleanup_errors=True) as temporary:
        for name, shell in shells:
            try:
                closed, outcome = case(shell, viewer, Path(temporary))
            except Exception as error:  # noqa: BLE001 - report every shell
                failures.append(f'{name}: {error}')
                continue
            left = gui_processes(viewer.parent) - before
            for pid in left:
                close_gui(pid)
            ok = closed and outcome['exit'] == 0 and not left
            print(f'{"PASS" if ok else "FAIL"} {name}: Ctrl+C closed the viewer={closed}, shell exit {outcome["exit"]} '
                  f'after {outcome["seconds"]} s, GUI processes left {sorted(left)}', flush=True)
            if not ok:
                failures.append(name)
    if failures:
        raise SystemExit(f'FAILED: {", ".join(failures)}')
    print(f'{len(shells)} consoles: Ctrl+C closes the viewer window and the launcher returns its exit status')


if __name__ == '__main__':
    main()
