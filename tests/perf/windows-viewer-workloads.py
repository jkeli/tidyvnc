#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Viewer workload measurements on Windows (plans/native-ui-winui DESKTOP.md
section 9, TODO W6.10; the Windows port of viewer-workloads.py).

Runs a viewer against a loopback RFB 3.8 peer that answers every
FramebufferUpdateRequest with a scripted update at an offered rate (default
30/s), so both frontends receive the same load:

  idle      one full frame, then no updates for the measurement window
  full1080  1920x1080 full-frame Raw update per request
  full4k    3840x2160 full-frame Raw update per request
  scroll    1920x1080 CopyRect shift by 16 rows plus a 16-row Raw strip
  patch     1920x1080 with one moving 64x64 Raw patch per request

Reported per workload: updates consumed per second; the protocol round trip
from the end of each update to the viewer's next request (p50/p95; a protocol
signal, not presentation latency); the viewer process's CPU seconds per second;
its peak working set and private bytes.

--startup N instead launches each viewer N times against the same peer and
reports, from process creation: its first visible titled window, the accepted
connection, the first FramebufferUpdateRequest after the handshake and the
request that follows the first full frame (D1's startup time; the first launch
is reported apart from the median of the rest).

--winui takes vncviewer.exe of a Debug publish or of a measurement publish
(apps/windows/build.py --stages app --measurement [--runtime ...]); packaged Release
builds ignore the isolated TIDYVNC_STATE_ROOT. The measured process is the
TidyVNC.exe it starts.
--fltk takes the retained FLTK vncviewer.exe. It has no state isolation on
Windows (it writes its history to HKCU), so it runs only when
TIDYVNC_TEST_ACCOUNT=1 says this is a dedicated test account or VM.

Viewer windows appear, so the script runs only with TIDYVNC_UI_TESTS=1 and a
desktop nobody has used for a minute. Presentation timing (PresentMon/ETW) and
the 10% regression gate against FLTK are separate steps (DESKTOP.md section 9).
"""
import argparse
import ctypes
import ctypes.wintypes as wintypes
import json
import os
import platform
import select
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

WORKLOADS = {'idle': (1920, 1080), 'full1080': (1920, 1080), 'full4k': (3840, 2160), 'scroll': (1920, 1080), 'patch': (1920, 1080)}

kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
user32 = ctypes.WinDLL('user32', use_last_error=True)
psapi = ctypes.WinDLL('psapi', use_last_error=True)
PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_VM_READ = 0x1000, 0x0010
TH32CS_SNAPPROCESS = 0x2


class ProcessEntry(ctypes.Structure):
    _fields_ = [('dwSize', wintypes.DWORD), ('cntUsage', wintypes.DWORD), ('th32ProcessID', wintypes.DWORD),
                ('th32DefaultHeapID', ctypes.c_size_t), ('th32ModuleID', wintypes.DWORD), ('cntThreads', wintypes.DWORD),
                ('th32ParentProcessID', wintypes.DWORD), ('pcPriClassBase', ctypes.c_long), ('dwFlags', wintypes.DWORD),
                ('szExeFile', ctypes.c_wchar * 260)]


class MemoryCounters(ctypes.Structure):
    _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD), ('PeakWorkingSetSize', ctypes.c_size_t),
                ('WorkingSetSize', ctypes.c_size_t), ('QuotaPeakPagedPoolUsage', ctypes.c_size_t),
                ('QuotaPagedPoolUsage', ctypes.c_size_t), ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t),
                ('QuotaNonPagedPoolUsage', ctypes.c_size_t), ('PagefileUsage', ctypes.c_size_t),
                ('PeakPagefileUsage', ctypes.c_size_t), ('PrivateUsage', ctypes.c_size_t)]


kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.OpenProcess.restype = wintypes.HANDLE


def children(parent):
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    entry, found = ProcessEntry(), []
    entry.dwSize = ctypes.sizeof(ProcessEntry)
    try:
        ok = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            if entry.th32ParentProcessID == parent:
                found.append((entry.th32ProcessID, entry.szExeFile))
            ok = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return found


class Measured:
    """CPU and memory of one process through a handle held for the whole run."""
    def __init__(self, pid):
        self.handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, False, pid)
        if not self.handle:
            raise OSError(ctypes.get_last_error(), f'OpenProcess {pid}')

    def cpu_seconds(self):
        times = [wintypes.FILETIME() for _ in range(4)]
        if not kernel32.GetProcessTimes(self.handle, *[ctypes.byref(t) for t in times]):
            return None
        kernel, user = [(t.dwHighDateTime << 32 | t.dwLowDateTime) / 1e7 for t in times[2:]]
        return kernel + user

    def memory(self):
        counters = MemoryCounters()
        counters.cb = ctypes.sizeof(MemoryCounters)
        if not psapi.GetProcessMemoryInfo(self.handle, ctypes.byref(counters), counters.cb):
            return None
        return counters.PeakWorkingSetSize, counters.PrivateUsage

    def close(self):
        kernel32.CloseHandle(self.handle)


WindowCallback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def has_visible_window(pid):
    """True once the process owns a visible top-level window with a title."""
    found = []

    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0:
            found.append(hwnd)
            return False
        return True
    user32.EnumWindows(WindowCallback(visit), 0)
    return bool(found)


def idle_seconds():
    class LastInput(ctypes.Structure):
        _fields_ = [('size', ctypes.c_uint), ('time', ctypes.c_uint)]
    info = LastInput(ctypes.sizeof(LastInput), 0)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
        return 0
    return ((kernel32.GetTickCount() - info.time) & 0xFFFFFFFF) / 1000


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


class Peer:
    def __init__(self, connection):
        self.connection = connection
        self.pixel_format = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        self.cache = {}

    def read(self, count):
        data = bytearray()
        while len(data) < count:
            chunk = self.connection.recv(count - len(data))
            if not chunk:
                raise ConnectionError('viewer closed the connection')
            data.extend(chunk)
        return bytes(data)

    def handshake(self, width, height):
        c = self.connection
        c.sendall(b'RFB 003.008\n'); assert self.read(12) == b'RFB 003.008\n'
        c.sendall(b'\1\1'); assert self.read(1) == b'\1'
        c.sendall(b'\0\0\0\0'); self.read(1)
        name = b'workload fixture'
        c.sendall(struct.pack('>HH', width, height) + self.pixel_format + struct.pack('>I', len(name)) + name)

    def next_message(self, timeout):
        if not select.select([self.connection], [], [], timeout)[0]:
            return None
        kind = self.read(1)[0]
        if kind == 0: self.read(3); self.pixel_format = self.read(16); return ('other', None)
        if kind == 2: self.read(1); self.read(4 * struct.unpack('>H', self.read(2))[0]); return ('other', None)
        if kind == 3: return ('request', self.read(9)[0])
        if kind == 4: self.read(7); return ('other', None)
        if kind == 5: self.read(5); return ('other', None)
        if kind == 6: self.read(3); self.read(struct.unpack('>I', self.read(4))[0]); return ('other', None)
        if kind == 150: self.read(9); return ('other', None)
        if kind == 251:
            self.read(1); _, _, count, _ = struct.unpack('>HHBB', self.read(6)); self.read(16 * count); return ('other', None)
        raise AssertionError(f'unexpected client message {kind}')

    def pixel(self, value):
        bits, _, big, _, rmax, gmax, bmax, rs, gs, bs = struct.unpack('>BBBBHHHBBBxxx', self.pixel_format)
        r, g, b = value
        word = ((r * rmax // 255) << rs) | ((g * gmax // 255) << gs) | ((b * bmax // 255) << bs)
        return word.to_bytes(bits // 8, 'big' if big else 'little')

    def raw(self, x, y, w, h, colour):
        key = (x, y, w, h, colour, self.pixel_format)
        if key not in self.cache:
            self.cache[key] = struct.pack('>HHHHi', x, y, w, h, 0) + self.pixel(colour) * (w * h)
        return self.cache[key]

    def copyrect(self, x, y, w, h, sx, sy):
        return struct.pack('>HHHHiHH', x, y, w, h, 1, sx, sy)

    def update(self, rects):
        self.connection.sendall(b'\0\0' + struct.pack('>H', len(rects)))
        for rect in rects:
            self.connection.sendall(rect)


def serve(peer, workload, width, height, seconds, process, rate):
    colour = [(40, 120, 200), (200, 80, 40)]
    frames, round_trips = 0, []
    while True:
        message = peer.next_message(30)
        assert message, 'viewer never requested the first frame'
        if message[0] == 'request':
            peer.update([peer.raw(0, 0, width, height, colour[0])])
            break
    start, cpu_start = time.monotonic(), process.cpu_seconds()
    sent_at = time.monotonic()
    stop, peaks = threading.Event(), [0, 0]

    def sample():
        while not stop.wait(0.25):
            value = process.memory()
            if value:
                peaks[0], peaks[1] = max(peaks[0], value[0]), max(peaks[1], value[1])
    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    while time.monotonic() - start < seconds:
        message = peer.next_message(0.25)
        if not message or message[0] != 'request':
            continue
        now = time.monotonic()
        if workload == 'idle':
            continue
        round_trips.append(now - sent_at)
        if rate:
            wait = start + frames / rate - time.monotonic()
            if wait > 0:
                time.sleep(wait)
        if workload in ('full1080', 'full4k'):
            peer.update([peer.raw(0, 0, width, height, colour[frames % 2])])
        elif workload == 'patch':
            cell = frames % 128
            peer.update([peer.raw(64 + (cell % 16) * 100, 64 + (cell // 16) * 100, 64, 64, colour[frames % 2])])
        else:
            peer.update([peer.copyrect(0, 0, width, height - 16, 0, 16), peer.raw(0, height - 16, width, 16, colour[frames % 2])])
        sent_at = time.monotonic()
        frames += 1
    elapsed = time.monotonic() - start
    cpu = (process.cpu_seconds() or 0) - (cpu_start or 0)
    stop.set()
    sampler.join()
    final = process.memory() or (0, 0)
    return {'workload': workload, 'width': width, 'height': height, 'seconds': round(elapsed, 3), 'offeredRate': rate,
            'updatesPerSecond': round(frames / elapsed, 2), 'updates': frames,
            'roundTripP50ms': None if not round_trips else round(percentile(round_trips, .5) * 1000, 2),
            'roundTripP95ms': None if not round_trips else round(percentile(round_trips, .95) * 1000, 2),
            'cpuSecondsPerSecond': round(cpu / elapsed, 3),
            'peakWorkingSetMiB': round(max(peaks[0], final[0]) / 1048576, 1),
            'peakPrivateMiB': round(max(peaks[1], final[1]) / 1048576, 1)}


# --direct: start TidyVNC.exe beside the given vncviewer.exe the way the launcher does
# (its command-line marker set), so the app is measured without the launcher.
DIRECT = False


def launch(executable, port, state):
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(('VNC_', 'TIDYVNC_'))}
    if DIRECT:
        executable = Path(executable).parent / 'TidyVNC.exe'
        env['TIDYVNC_COMMAND_LINE'] = '1'
    args = [str(executable), '-SendClipboard=0', '-AcceptClipboard=0', '-AlertOnFatalError=0', '-ReconnectOnError=0',
            '-SecurityTypes=None', '-ScalingFactor=100', '-RemoteResize=0', f'127.0.0.1::{port}']
    env['TIDYVNC_STATE_ROOT'] = str(state)
    return subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop(launcher):
    if launcher.poll() is None:
        subprocess.run(['taskkill', '/T', '/F', '/PID', str(launcher.pid)], capture_output=True)
        launcher.wait(10)


def next_request(peer):
    while True:
        message = peer.next_message(60)
        assert message, 'viewer sent nothing for 60 s'
        if message[0] == 'request':
            return


def startup(frontend, executable, index, work):
    """Milliseconds from process creation to window, connection, first request and first frame."""
    width, height = WORKLOADS['full1080']
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(60)
        started = time.perf_counter()
        launcher = launch(executable, listener.getsockname()[1], work / f'{frontend}-startup-{index}')
        marks, done = {}, threading.Event()

        def watch_window():
            gui = None
            while not done.is_set() and time.perf_counter() - started < 60:
                if gui is None:
                    gui = launcher.pid if frontend == 'fltk' or DIRECT else next(
                        (p for p, name in children(launcher.pid) if name.lower() == 'tidyvnc.exe'), None)
                if gui is not None and has_visible_window(gui):
                    marks['window'] = time.perf_counter()
                    return
                time.sleep(0.002)
        watcher = threading.Thread(target=watch_window, daemon=True)
        watcher.start()
        try:
            client, _ = listener.accept()
            with client:
                marks['connected'] = time.perf_counter()
                peer = Peer(client)
                peer.handshake(width, height)
                next_request(peer)
                marks['firstRequest'] = time.perf_counter()
                peer.update([peer.raw(0, 0, width, height, (40, 120, 200))])
                next_request(peer)
                marks['firstFrame'] = time.perf_counter()
                watcher.join(30)
        finally:
            done.set()
            stop(launcher)
    return {name: round((marks[name] - started) * 1000, 1) if name in marks else None
            for name in ('window', 'connected', 'firstRequest', 'firstFrame')}


def measure_startup(frontend, executable, launches, work):
    runs = [startup(frontend, executable, index, work) for index in range(launches)]
    warm = runs[1:] or runs
    median = {name: percentile([r[name] for r in warm if r[name] is not None], .5) for name in runs[0]}
    return {'frontend': frontend, 'executable': str(executable), 'launches': launches, 'first': runs[0],
            'warmMedianMs': median, 'runs': runs}


def run(frontend, executable, workload, seconds, rate, work):
    width, height = WORKLOADS[workload]
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(30)
        launcher = launch(executable, listener.getsockname()[1], work / f'{frontend}-{workload}')
        measured = None
        try:
            client, _ = listener.accept()
            with client:
                pid = launcher.pid
                if frontend == 'winui' and not DIRECT:
                    gui = [p for p, name in children(launcher.pid) if name.lower() == 'tidyvnc.exe']
                    assert gui, 'vncviewer.exe did not start TidyVNC.exe'
                    pid = gui[0]
                measured = Measured(pid)
                peer = Peer(client)
                peer.handshake(width, height)
                result = serve(peer, workload, width, height, seconds, measured, rate)
            return dict(result, frontend=frontend)
        finally:
            if measured:
                measured.close()
            stop(launcher)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--winui', type=Path, help='vncviewer.exe of a Debug WinUI publish')
    parser.add_argument('--fltk', type=Path, help='retained FLTK vncviewer.exe (test account or VM only)')
    parser.add_argument('--workload', action='append', choices=sorted(WORKLOADS))
    parser.add_argument('--seconds', type=float, default=10)
    parser.add_argument('--rate', type=float, default=30)
    parser.add_argument('--startup', type=int, metavar='N', help='measure startup over N launches instead of the workloads')
    parser.add_argument('--direct', action='store_true', help='start TidyVNC.exe itself rather than through vncviewer.exe')
    parser.add_argument('--label', help='a name for this build in the report (for example jit or aot)')
    parser.add_argument('--report', type=Path, help='JSON report path')
    args = parser.parse_args()
    if not (args.winui or args.fltk):
        parser.error('give --winui and/or --fltk')
    if args.fltk and os.environ.get('TIDYVNC_TEST_ACCOUNT') != '1':
        parser.error('the FLTK viewer writes HKCU; run it only in a test account or VM (TIDYVNC_TEST_ACCOUNT=1)')
    if os.environ.get('TIDYVNC_UI_TESTS') != '1':
        parser.exit(2, 'This measurement opens viewer windows; set TIDYVNC_UI_TESTS=1 to run it.\n')
    if idle_seconds() < 60:
        parser.exit(2, f'The desktop is in use (idle {idle_seconds():.0f} s); not opening windows on it.\n')
    workloads = args.workload or ['idle', 'full1080', 'full4k', 'scroll', 'patch']
    report = {'windows': platform.version(), 'machine': platform.machine(), 'processor': platform.processor(),
              'rate': args.rate, 'seconds': args.seconds, 'label': args.label, 'results': []}
    global DIRECT
    DIRECT = args.direct
    report['direct'] = args.direct
    # A just-killed viewer can still hold a file in its state folder for a moment.
    with tempfile.TemporaryDirectory(prefix='tidyvnc-workloads-', ignore_cleanup_errors=True) as temporary:
        for frontend, executable in (('fltk', args.fltk), ('winui', args.winui)):
            if not executable:
                continue
            if args.startup:
                result = measure_startup(frontend, executable.resolve(), args.startup, Path(temporary))
                report['results'].append(result)
                print(json.dumps({k: v for k, v in result.items() if k != 'runs'}), flush=True)
                continue
            for workload in workloads:
                result = run(frontend, executable.resolve(), workload, args.seconds, args.rate, Path(temporary))
                report['results'].append(result)
                print(json.dumps(result), flush=True)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
