#!/usr/bin/env python3
# Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later.
"""Opt-in macOS viewer protocol/lifecycle smoke test (requires WindowServer).

Runs the supplied viewer against a temporary loopback-only RFB server. Tests
all scaling/filter/unit combinations, fragmented updates, cursor replacement,
server framebuffer replacement, resize suppression and explicit DesktopSize.
This does NOT inspect displayed pixels or synthesize user input. Physical
mixed-display/Spaces and interactive input checks remain separate.
"""
import argparse
import itertools
import math
import re
import select
import socket
import struct
import subprocess
import time
from pathlib import Path


def rectangle(x, y, w, h, encoding, payload=b''):
    return struct.pack('>HHHHi', x, y, w, h, encoding) + payload


def layout(w, h, reason=0, result=0):
    return rectangle(reason, result, w, h, -308,
                     b'\1\0\0\0' + struct.pack('>IHHHHI', 7, 0, 0, w, h, 0))


def run_case(viewer, mode, quality, units, remote_resize=False, explicit=False):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(10)
        args = [str(viewer), '-SendClipboard=0', '-AcceptClipboard=0',
                '-AlertOnFatalError=0', '-ReconnectOnError=0', '-FullScreen=0',
                '-AlwaysCursor=0', '-ViewOnly=0', '-Log=*:stderr:100',
                f'-RemoteResize={int(remote_resize)}', f'-ScalingFactor={mode}',
                f'-ScalingQuality={quality}', f'-DesktopPixelUnits={units}',
                '-DesktopSize=123x97' if explicit else '-DesktopSize=',
                f'127.0.0.1::{listener.getsockname()[1]}']
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            client, _ = listener.accept()
            with client:
                client.settimeout(10)

                def read(n):
                    data = bytearray()
                    while len(data) < n:
                        chunk = client.recv(n-len(data))
                        if not chunk:
                            raise AssertionError('Viewer disconnected before fixture completed')
                        data.extend(chunk)
                    return bytes(data)

                def update(rectangles, fragmented=False):
                    payload = b'\0\0' + struct.pack('>H', len(rectangles)) + b''.join(rectangles)
                    if fragmented:
                        for offset in range(0, len(payload), 16384):
                            client.sendall(payload[offset:offset+16384])
                            time.sleep(.002)
                    else:
                        client.sendall(payload)

                client.sendall(b'RFB 003.008\n')
                assert read(12) == b'RFB 003.008\n'
                client.sendall(b'\1\1')
                assert read(1) == b'\1'
                client.sendall(b'\0'*4)
                read(1)
                pf = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
                name = b'TigerVNC scaling lifecycle fixture'
                client.sendall(struct.pack('>HH', 320, 240)+pf+struct.pack('>I', len(name))+name)
                stage = 0
                resize_requests = []
                requests = []
                end = time.monotonic()+10
                final_at = None
                while time.monotonic() < end:
                    if final_at and time.monotonic()-final_at > .3:
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
                        read(count*4)
                    elif kind == 3:
                        request = struct.unpack('>BHHHH', read(9))
                        requests.append(request)
                        bits, _, big, _, rmax, gmax, bmax, rs, gs, bs = struct.unpack('>BBBBHHHBBBxxx', pf)
                        pixel = ((rmax << rs) | ((gmax//3) << gs) | ((bmax//2) << bs)).to_bytes(bits//8, 'big' if big else 'little')
                        if stage == 0:
                            cursor = rectangle(16, 16, 128, 128, -239, pixel*(128*128)+b'\xff'*(16*128))
                            update([layout(320, 240), rectangle(0, 0, 320, 240, 0, pixel*(320*240)), cursor], True)
                        elif stage == 1:
                            update([layout(321, 241), rectangle(0, 0, 321, 241, 0, pixel*(321*241))], True)
                        elif stage == 2:
                            update([rectangle(320, 240, 1, 1, 0, pixel), rectangle(0, 0, 0, 0, -239)])
                            final_at = time.monotonic()
                        stage += 1
                    elif kind == 251:
                        read(1)
                        w, h, count, _ = struct.unpack('>HHBB', read(6))
                        screens = read(count*16)
                        resize_requests.append((w, h, count, screens))
                        # Refuse the request. Repeated identical retries would
                        # reveal a denial/pending-state feedback loop.
                        update([layout(w, h, 1, 1)])
                    elif kind == 4:
                        read(7)
                    elif kind == 5:
                        read(5)
                    elif kind == 6:
                        read(3)
                        count = struct.unpack('>I', read(4))[0]
                        assert count <= 1024*1024
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
                # There can be one request before and one after the server's
                # unsolicited framebuffer change; neither may loop on denial.
                assert len(resize_requests) <= 2, resize_requests
            _, stderr = process.communicate(timeout=10)
            log = stderr.decode(errors='replace')
            assert process.returncode in (0, 1), (process.returncode, log)
            assert 'Display generation 1: FLTK 1.4.5' in log, log
            assert 'CConn:       Connected' in log, log
            assert 'Assertion failed' not in log and 'terminate called' not in log, log
            if remote_resize and mode == '100' and not explicit:
                metrics = re.search(r'backing ratio\s+([0-9.]+)x([0-9.]+), logical (\d+)x(\d+)', log)
                assert metrics, log
                qx, qy = float(metrics[1]), float(metrics[2])
                width, height = int(metrics[3]), int(metrics[4])
                expected = (math.floor(width*qx), math.floor(height*qy)) if units == 'Device' else (width, height)
                if expected != (320, 240):
                    assert resize_requests and resize_requests[0][:2] == expected, (expected, resize_requests)
            return len(resize_requests)
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('viewer', type=Path)
    parser.add_argument('--quick', action='store_true', help='run a representative subset')
    args = parser.parse_args()
    modes = ['100', 'Auto', 'FixedRatio', 'FitWidth', 'FitHeight', '641x359', '137.5', '125%x80%']
    cases = list(itertools.product(modes, ['Nearest', 'Bilinear', 'Area'], ['Logical', 'Device']))
    if args.quick:
        cases = [('100', 'Nearest', 'Device'), ('1600', 'Area', 'Logical')]
    if not args.quick:
        cases.append(('1600', 'Area', 'Logical'))
    count = 0
    for mode, quality, units in cases:
        run_case(args.viewer.resolve(), mode, quality, units)
        count += 1
        print(f'PASS {mode} {quality} {units}', flush=True)
    for mode, units, explicit in [('100', 'Logical', False), ('100', 'Device', False),
                                  ('200', 'Logical', False), ('200', 'Device', False),
                                  ('200', 'Logical', True), ('200', 'Device', True)]:
        requests = run_case(args.viewer.resolve(), mode, 'Bilinear', units, True, explicit)
        count += 1
        print(f'PASS resize policy {mode} {units} explicit={explicit}, requests={requests}', flush=True)
    print(f'{count} protocol/lifecycle cases passed; displayed pixels and user input were not asserted.')


if __name__ == '__main__':
    main()
