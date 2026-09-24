#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in Windows viewer protocol/lifecycle smoke test (plans/native-ui-winui
TESTING.md section 5, TODO W6.12; the port of macos-scaling-smoke.py).

Runs the WinUI viewer through its `vncviewer.exe` launcher against a temporary
loopback-only RFB server, for every scaling mode, filter and unit (55 cases):
fragmented updates, cursor replacement, a server framebuffer change, resize
suppression, automatic resize from the measured viewport and an explicit
DesktopSize. Each case runs with an isolated TIDYVNC_STATE_ROOT, so no user
setting, profile, history or trust store is read or written. It does not
inspect displayed pixels or synthesise user input.

The viewer shows a window per case, so like the UI automation suite it runs
only with TIDYVNC_UI_TESTS=1 and when nobody has used the desktop for a minute.
"""
import argparse
import ctypes
import hashlib
import itertools
import json
import os
import platform
import re
import select
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path


def idle_seconds():
    class LastInput(ctypes.Structure):
        _fields_ = [("size", ctypes.c_uint), ("time", ctypes.c_uint)]
    info = LastInput(ctypes.sizeof(LastInput), 0)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
        return 0
    return ((ctypes.windll.kernel32.GetTickCount() - info.time) & 0xFFFFFFFF) / 1000


def rectangle(x, y, w, h, encoding, payload=b''):
    return struct.pack('>HHHHi', x, y, w, h, encoding) + payload


def layout(w, h, reason=0, result=0):
    return rectangle(reason, result, w, h, -308,
                     b'\1\0\0\0' + struct.pack('>IHHHHI', 7, 0, 0, w, h, 0))


def run_case(viewer, mode, quality, units, remote_resize=False, explicit=False, log_path=None):
    with socket.socket() as listener, tempfile.TemporaryDirectory(prefix='tidyvnc-smoke-') as state, tempfile.TemporaryFile() as output:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(20)
        args = [str(viewer), '-SendClipboard=0', '-AcceptClipboard=0',
                '-AlertOnFatalError=0', '-ReconnectOnError=0', '-FullScreen=0',
                '-AlwaysCursor=0', '-ViewOnly=0', '-Log=*:stderr:100', '-SecurityTypes=None',
                f'-RemoteResize={int(remote_resize)}', f'-ScalingFactor={mode}',
                f'-ScalingQuality={quality}', f'-DesktopPixelUnits={units}',
                '-DesktopSize=123x97' if explicit else '-DesktopSize=',
                f'127.0.0.1::{listener.getsockname()[1]}']
        env = {k: v for k, v in os.environ.items() if not k.upper().startswith(('VNC_', 'TIDYVNC_'))}
        env['TIDYVNC_STATE_ROOT'] = str(Path(state).resolve() / 'state')
        process = subprocess.Popen(args, env=env, stdout=output, stderr=subprocess.STDOUT)
        expected = None
        try:
            client, _ = listener.accept()
            with client:
                client.settimeout(20)

                def read(n):
                    data = bytearray()
                    while len(data) < n:
                        chunk = client.recv(n - len(data))
                        if not chunk:
                            raise AssertionError('Viewer disconnected before fixture completed')
                        data.extend(chunk)
                    return bytes(data)

                def update(rectangles, fragmented=False):
                    payload = b'\0\0' + struct.pack('>H', len(rectangles)) + b''.join(rectangles)
                    if fragmented:
                        for offset in range(0, len(payload), 16384):
                            client.sendall(payload[offset:offset + 16384])
                            time.sleep(.002)
                    else:
                        client.sendall(payload)

                client.sendall(b'RFB 003.008\n')
                assert read(12) == b'RFB 003.008\n'
                client.sendall(b'\1\1')
                assert read(1) == b'\1'
                client.sendall(b'\0' * 4)
                read(1)
                pf = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
                name = b'TidyVNC scaling lifecycle fixture'
                client.sendall(struct.pack('>HH', 320, 240) + pf + struct.pack('>I', len(name)) + name)
                stage = 0
                resize_requests = []
                requests = []
                end = time.monotonic() + 20
                final_at = None
                while time.monotonic() < end:
                    if final_at and time.monotonic() - final_at > .5:
                        break
                    if not select.select([client], [], [], .05)[0]:
                        continue
                    kind = read(1)[0]
                    if kind == 0:
                        read(3)
                        pf = read(16)
                    elif kind == 2:
                        read(1)
                        count = struct.unpack('>H', read(2))[0]
                        read(count * 4)
                    elif kind == 3:
                        request = struct.unpack('>BHHHH', read(9))
                        requests.append(request)
                        bits, _, big, _, rmax, gmax, bmax, rs, gs, bs = struct.unpack('>BBBBHHHBBBxxx', pf)
                        pixel = ((rmax << rs) | ((gmax // 3) << gs) | ((bmax // 2) << bs)).to_bytes(bits // 8, 'big' if big else 'little')
                        if stage == 0:
                            cursor = rectangle(16, 16, 128, 128, -239, pixel * (128 * 128) + b'\xff' * (16 * 128))
                            update([layout(320, 240), rectangle(0, 0, 320, 240, 0, pixel * (320 * 240)), cursor], True)
                        elif stage == 1:
                            update([layout(321, 241), rectangle(0, 0, 321, 241, 0, pixel * (321 * 241))], True)
                        elif stage == 2:
                            update([rectangle(320, 240, 1, 1, 0, pixel), rectangle(0, 0, 0, 0, -239)])
                            final_at = time.monotonic()
                        stage += 1
                    elif kind == 251:
                        read(1)
                        w, h, count, _ = struct.unpack('>HHBB', read(6))
                        screens = read(count * 16)
                        resize_requests.append((w, h, count, screens))
                        # Refuse: identical retries would reveal a denial feedback loop.
                        update([layout(w, h, 1, 1)])
                    elif kind == 4:
                        read(7)
                    elif kind == 5:
                        read(5)
                    elif kind == 6:
                        read(3)
                        count = struct.unpack('>I', read(4))[0]
                        assert count <= 1024 * 1024
                        read(count)
                    elif kind == 150:
                        read(9)
                    else:
                        raise AssertionError(f'Unexpected client message {kind}')
                assert stage >= 3, (stage, requests)
                assert any(r[3:] == (321, 241) for r in requests), requests
                if explicit:
                    assert resize_requests and resize_requests[0][:2] == (123, 97), resize_requests
                elif not remote_resize or mode != '100':
                    assert not resize_requests, resize_requests
                assert len(resize_requests) <= 2, resize_requests
                # The server closes; with AlertOnFatalError off the window closes and the
                # command-line launch ends. Output after our close must stay bounded.
                client.shutdown(socket.SHUT_WR)
                drained = 0
                while True:
                    try:
                        pending = client.recv(4096)
                    except (ConnectionResetError, ConnectionAbortedError):
                        break
                    if not pending:
                        break
                    drained += len(pending)
                    assert drained <= 1024 * 1024, 'unbounded output after peer close'
            process.wait(timeout=30)
            output.seek(0)
            log = output.read().decode(errors='replace')
            assert process.returncode in (0, 1), (process.returncode, log[-2000:])
            assert 'Initialisation done' in log, log[-2000:]
            assert 'Assertion failed' not in log and 'Unhandled' not in log, log[-2000:]
            if remote_resize and mode == '100' and not explicit:
                metrics = re.search(r'Viewport logical (\d+)x(\d+), backing (\d+)x(\d+)', log)
                assert metrics, log[-2000:]
                expected = tuple(map(int, metrics.group(3, 4) if units == 'Device' else metrics.group(1, 2)))
                if expected != (320, 240):
                    assert resize_requests and resize_requests[0][:2] == expected, (expected, resize_requests)
            return {'resizeRequests': len(resize_requests),
                    'requestedDesktopSizes': [list(request[:2]) for request in resize_requests],
                    'automaticViewportExpected': list(expected) if expected else None,
                    'processExitCode': process.returncode}
        finally:
            if process.poll() is None:
                # The launcher's GUI child keeps running if only the launcher is killed.
                subprocess.run(['taskkill', '/T', '/F', '/PID', str(process.pid)], capture_output=True)
                process.wait(timeout=10)
            output.seek(0)
            if log_path:
                log_path.write_bytes(output.read())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('viewer', type=Path, help='vncviewer.exe beside TidyVNC.exe (a published app directory)')
    parser.add_argument('--quick', action='store_true', help='run a representative subset')
    parser.add_argument('--report-dir', type=Path, help='New directory for summary and per-case logs')
    args = parser.parse_args()
    if os.environ.get('TIDYVNC_UI_TESTS') != '1':
        parser.exit(2, 'This test opens viewer windows; set TIDYVNC_UI_TESTS=1 to run it.\n')
    if idle_seconds() < 60:
        parser.exit(2, f'The desktop is in use (idle {idle_seconds():.0f} s); not opening windows on it.\n')
    modes = ['100', 'Auto', 'FixedRatio', 'FitWidth', 'FitHeight', '641x359', '137.5', '125%x80%']
    cases = list(itertools.product(modes, ['Nearest', 'Bilinear', 'Area'], ['Logical', 'Device']))
    if args.quick:
        cases = [('100', 'Nearest', 'Device'), ('1600', 'Area', 'Logical')]
    if not args.quick:
        cases.append(('1600', 'Area', 'Logical'))
    matrix = [(mode, quality, units, False, False) for mode, quality, units in cases]
    matrix += [(mode, 'Bilinear', units, True, explicit) for mode, units, explicit in
               [('100', 'Logical', False), ('100', 'Device', False), ('200', 'Logical', False),
                ('200', 'Device', False), ('200', 'Logical', True), ('200', 'Device', True)]]
    if args.report_dir:
        args.report_dir.mkdir(parents=True, exist_ok=False)
    report = {'frontend': 'winui', 'status': 'running', 'expectedCases': len(matrix), 'cases': [],
              'viewer': str(args.viewer.resolve()), 'executableSHA256': hashlib.sha256(args.viewer.read_bytes()).hexdigest(),
              'windows': platform.version(), 'architecture': platform.machine(),
              'excludes': ['displayed pixels', 'user input', 'interactive window acceptance']}
    try:
        for index, (mode, quality, units, resize, explicit) in enumerate(matrix, 1):
            case = dict(mode=mode, quality=quality, units=units, remoteResize=resize, explicit=explicit, status='running')
            report['cases'].append(case)
            log_path = args.report_dir / f'{index:02d}.log' if args.report_dir else None
            try:
                case.update(run_case(args.viewer.resolve(), mode, quality, units, resize, explicit, log_path))
                case['status'] = 'passed'
                print(f'PASS {index}/{len(matrix)} {mode} {quality} {units} resize={resize} explicit={explicit}', flush=True)
            except Exception as error:
                case.update(status='failed', error=f'{type(error).__name__}: {error}')
                raise
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        if report['status'] != 'passed':
            report['status'] = 'failed'
        if args.report_dir:
            (args.report_dir / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'{len(matrix)} protocol/lifecycle cases passed; displayed pixels and user input were not asserted.')


if __name__ == '__main__':
    main()
