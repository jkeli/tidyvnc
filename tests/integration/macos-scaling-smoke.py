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
import hashlib
import itertools
import json
import math
import os
import plistlib
import platform
import tempfile
import re
import select
import socket
import struct
import subprocess
import time
import uuid
from pathlib import Path


def rectangle(x, y, w, h, encoding, payload=b''):
    return struct.pack('>HHHHi', x, y, w, h, encoding) + payload


def layout(w, h, reason=0, result=0):
    return rectangle(reason, result, w, h, -308,
                     b'\1\0\0\0' + struct.pack('>IHHHHI', 7, 0, 0, w, h, 0))


def run_case(viewer, mode, quality, units, remote_resize=False, explicit=False,
             native=None, log_path=None):
    with socket.socket() as listener, tempfile.TemporaryDirectory(prefix='tidyvnc-smoke-') as state, tempfile.TemporaryFile() as output:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(10)
        args = [str(viewer), '-SendClipboard=0', '-AcceptClipboard=0',
                '-AlertOnFatalError=0', '-ReconnectOnError=0', '-FullScreen=0',
                '-AlwaysCursor=0', '-ViewOnly=0', '-Log=*:stderr:100', '-SecurityTypes=None',
                f'-RemoteResize={int(remote_resize)}', f'-ScalingFactor={mode}',
                f'-ScalingQuality={quality}', f'-DesktopPixelUnits={units}',
                '-DesktopSize=123x97' if explicit else '-DesktopSize=',
                f'127.0.0.1::{listener.getsockname()[1]}']
        env = os.environ.copy()
        for name in ['VNC_USERNAME','VNC_PASSWORD','VNC_VIA_CMD','CFFIXED_USER_HOME','__CFPREFERENCES_AVOID_DAEMON']:
            env.pop(name, None)
        for name in ['HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME']:
            directory = Path(state).resolve() / name
            directory.mkdir()
            env[name] = str(directory)
        if native:
            env['CFFIXED_USER_HOME'] = env['HOME']
            subprocess.run([str(native[0]),env['HOME'],native[1]],env=env,check=True,capture_output=True,timeout=10)
        process = subprocess.Popen(args, env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            try:
                client, _ = listener.accept()
            except TimeoutError:
                if log_path and process.poll() is None:
                    subprocess.run(['/usr/bin/sample',str(process.pid),'1','-file',str(log_path.with_suffix('.sample.txt'))],
                                   capture_output=True,timeout=10)
                raise
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
                if native:
                    # Native failure closes the connection/window, while the app
                    # stays alive. Prove socket drain before stopping our child;
                    # SIGTERM cleanup is not evidence of interactive app Quit.
                    client.shutdown(socket.SHUT_WR)
                    drained = 0
                    while True:
                        pending = client.recv(4096)
                        if not pending:
                            break
                        drained += len(pending)
                        assert drained <= 1024*1024, 'unbounded output after peer close'
                    assert process.poll() is None, 'native application exited unexpectedly'
                    process.terminate()
            process.communicate(timeout=10)
            output.seek(0)
            log = output.read().decode(errors='replace')
            if native:
                assert process.returncode == -15, (process.returncode,log)
                assert 'Initialisation done' in log, log
            else:
                assert process.returncode in (0, 1), (process.returncode, log)
                assert 'Display generation 1: FLTK 1.4.5' in log, log
                assert 'CConn:       Connected' in log, log
            assert 'Assertion failed' not in log and 'terminate called' not in log, log
            if remote_resize and mode == '100' and not explicit:
                if native:
                    metrics = re.search(r'Viewport logical (\d+)x(\d+), backing (\d+)x(\d+)', log)
                    assert metrics, log
                    expected = tuple(map(int,metrics.group(3,4) if units == 'Device' else metrics.group(1,2)))
                else:
                    metrics = re.search(r'backing ratio\s+([0-9.]+)x([0-9.]+), logical (\d+)x(\d+)', log)
                    assert metrics, log
                    qx, qy = float(metrics[1]), float(metrics[2])
                    width, height = int(metrics[3]), int(metrics[4])
                    expected = (math.floor(width*qx), math.floor(height*qy)) if units == 'Device' else (width, height)
                if expected != (320, 240):
                    assert resize_requests and resize_requests[0][:2] == expected, (expected, resize_requests)
            return {'resizeRequests':len(resize_requests),
                    'requestedDesktopSizes':[list(request[:2]) for request in resize_requests],
                    'automaticViewportExpected':list(expected) if remote_resize and mode == '100' and not explicit else None,
                    'processExitCode':process.returncode}
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=10)
            output.seek(0)
            if log_path:
                log_path.write_bytes(output.read())
            if native:
                subprocess.run([str(native[0]),'--cleanup',native[1]],env=env,check=True,capture_output=True,timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('viewer', type=Path)
    parser.add_argument('--quick', action='store_true', help='run a representative subset')
    parser.add_argument('--frontend', choices=('fltk','swiftui'), default='fltk')
    parser.add_argument('--report-dir', type=Path, help='New directory for summary and per-case logs')
    args = parser.parse_args()
    modes = ['100', 'Auto', 'FixedRatio', 'FitWidth', 'FitHeight', '641x359', '137.5', '125%x80%']
    cases = list(itertools.product(modes, ['Nearest', 'Bilinear', 'Area'], ['Logical', 'Device']))
    if args.quick:
        cases = [('100', 'Nearest', 'Device'), ('1600', 'Area', 'Logical')]
    if not args.quick:
        cases.append(('1600', 'Area', 'Logical'))
    matrix = [(mode,quality,units,False,False) for mode,quality,units in cases]
    matrix += [(mode,'Bilinear',units,True,explicit) for mode,units,explicit in
               [('100','Logical',False),('100','Device',False),('200','Logical',False),
                ('200','Device',False),('200','Logical',True),('200','Device',True)]]
    if args.report_dir:
        args.report_dir.mkdir(parents=True,exist_ok=False)
    report = {'frontend':args.frontend,'status':'running','expectedCases':len(matrix),'cases':[],
              'viewer':str(args.viewer.resolve()),'executableSHA256':hashlib.sha256(args.viewer.read_bytes()).hexdigest(),
              'macOS':platform.mac_ver()[0],'architecture':platform.machine(),
              'excludes':['displayed pixels','user input','interactive window/quit acceptance']}
    try:
        with tempfile.TemporaryDirectory(prefix='tidyvnc-native-protocol-') as temporary:
            temporary = Path(temporary).resolve()
            viewer, native = args.viewer.resolve(), None
            if args.frontend == 'swiftui':
                source = viewer.parent.parent.parent
                info = plistlib.loads((source/'Contents/Info.plist').read_bytes())
                assert info['CFBundleIdentifier'] == 'io.github.jkeli.tidyvnc' and info['CFBundleExecutable'] == viewer.name
                copied = temporary/'TidyVNC Protocol Fixture.app'
                subprocess.run(['/usr/bin/ditto',str(source),str(copied)],check=True)
                domain = 'io.github.jkeli.tidyvnc.protocol-fixture.'+str(uuid.uuid4())
                info['CFBundleIdentifier'] = domain
                (copied/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier',domain,'--timestamp=none',str(copied)],check=True)
                subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(copied)],check=True)
                helper = temporary/'isolation'
                subprocess.run(['xcrun','swiftc',str(Path(__file__).with_name('native-isolation.swift')),'-o',str(helper)],check=True)
                viewer = copied/'Contents/MacOS'/viewer.name
                native = (helper,domain)
                report['fixtureIdentity'] = domain
            for index, (mode,quality,units,resize,explicit) in enumerate(matrix,1):
                case = dict(mode=mode,quality=quality,units=units,remoteResize=resize,explicit=explicit,status='running')
                report['cases'].append(case)
                log_path = args.report_dir/f'{index:02d}.log' if args.report_dir else None
                try:
                    case.update(run_case(viewer,mode,quality,units,resize,explicit,native,log_path))
                    case['status'] = 'passed'
                    print(f'PASS {index}/{len(matrix)} {mode} {quality} {units} resize={resize} explicit={explicit}',flush=True)
                except Exception as error:
                    case.update(status='failed',error=f'{type(error).__name__}: {error}')
                    raise
            report['status'] = 'passed'
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        if report['status'] != 'passed':
            report['status'] = 'failed'
        if args.report_dir:
            (args.report_dir/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'{len(matrix)} protocol/lifecycle cases passed; displayed pixels and user input were not asserted.')


if __name__ == '__main__':
    main()
