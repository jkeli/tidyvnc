#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Matched FLTK/native viewer workload measurements (macOS, requires WindowServer).

Runs an actual viewer executable against a loopback RFB 3.8 peer that answers
every FramebufferUpdateRequest with a scripted update, so the request cadence is
paced by the viewer's own read/decode/request loop:

  idle      one full frame, then no updates for the measurement window
  full1080  1920x1080 full-frame Raw update per request
  full4k    3840x2160 full-frame Raw update per request
  scroll    1920x1080 CopyRect shift by 16 rows plus a 16-row Raw strip
  patch     1920x1080 with one moving 64x64 Raw patch per request (small damage)

Updates are offered at a fixed rate (--rate, default 30/s; 0 answers every
request immediately), so both frontends receive the same load. Reported per workload: updates consumed per second; the protocol round trip from
the end of each update the peer sent to the viewer's next request (p50/p95); the
viewer's CPU time (user+system) per second; and peak RSS. The round trip is only
a protocol-level signal: near zero means the viewer had already requested the
next update (pipelined), and it never includes the time until pixels reach the
display, so it is NOT presentation latency. For the native app, updates consumed
are decoded updates; presentation may coalesce them.

The native app runs as an isolated copy (tests/macos/isolated-app.py); FLTK runs
with fresh HOME/XDG roots. Both use -ScalingFactor=100 -RemoteResize=0 and no
clipboard. Results are a local baseline for matched comparison on one machine.

--probe runs build/.../tests/macos/native-presentation-probe instead: the
production NativeSession and NativeDesktopView in an on-screen 1280x720 window
(fit scaling, bilinear); --probe-views N binds N such views to one session. The peer records when it finished writing each update
(CLOCK_UPTIME_RAW) and the probe records when the frame reached the main actor,
when AppKit finished drawing it and the display-link refresh targets. Each
arrival is paired with the latest update sent before it, so reported latencies
are: decode (update sent -> frame on the main actor), draw (-> AppKit draw
finished) and display (-> next refresh target after the draw; an estimate of the
earliest time the frame can be on screen, not a photon measurement). Updates
never drawn, because presentation coalesced them, are counted separately. With
several views, a frame's draw time is when its last view finished. Per drawn
frame the probe also reports resampled output bytes written (copies), resident
output bytes and invalidated device pixels (damage).
"""
import argparse
import bisect
import importlib.util
import json
import os
import platform
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('isolated_app', ROOT / 'tests/macos/isolated-app.py')
isolated = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolated)

WORKLOADS = {'idle': (1920, 1080), 'full1080': (1920, 1080), 'full4k': (3840, 2160), 'scroll': (1920, 1080),
             'patch': (1920, 1080)}


def cpu_seconds(pid):
    out = subprocess.run(['/bin/ps', '-o', 'time=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = out.replace('-', ':').split(':')
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + float(part)
    return seconds


def rss_kib(pid):
    out = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) if out else None


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


class Peer:
    def __init__(self, connection):
        self.connection = connection
        self.pixel_format = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)

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
        """Returns ('request', incremental) for FramebufferUpdateRequest, other kinds consumed."""
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
        # Cached per geometry, colour and pixel format so the peer is not the bottleneck.
        key = (x, y, w, h, colour, self.pixel_format)
        cache = self.__dict__.setdefault('cache', {})
        if key not in cache:
            cache[key] = struct.pack('>HHHHi', x, y, w, h, 0) + self.pixel(colour) * (w * h)
        return cache[key]

    def copyrect(self, x, y, w, h, sx, sy):
        return struct.pack('>HHHHiHH', x, y, w, h, 1, sx, sy)

    def update(self, rects):
        self.connection.sendall(b'\0\0' + struct.pack('>H', len(rects)))
        for rect in rects:
            self.connection.sendall(rect)


def serve(peer, workload, width, height, seconds, pid, rate):
    colour = [(40, 120, 200), (200, 80, 40)]
    frames, round_trips, rss_peak = 0, [], 0
    sends = []                                         # CLOCK_UPTIME_RAW ns after each update was written
    # First request always gets a full frame; the window starts afterwards.
    while True:
        message = peer.next_message(30)
        assert message, 'viewer never requested the first frame'
        if message[0] == 'request':
            peer.update([peer.raw(0, 0, width, height, colour[0])]); sends.append(uptime_ns()); break
    start, cpu_start = time.monotonic(), cpu_seconds(pid)
    sent_at = time.monotonic()
    # Sample RSS off the serving loop: spawning ps per message would throttle the peer.
    stop, peaks = threading.Event(), [0]
    def sample():
        while not stop.wait(0.25):
            value = rss_kib(pid)
            if value: peaks[0] = max(peaks[0], value)
    sampler = threading.Thread(target=sample, daemon=True); sampler.start()
    while time.monotonic() - start < seconds:
        message = peer.next_message(0.25)
        if not message or message[0] != 'request':
            continue
        now = time.monotonic()
        if workload == 'idle':
            continue                                   # answer nothing: measure idle cost
        round_trips.append(now - sent_at)
        if rate:                                       # hold the offered rate (absolute schedule)
            wait = start + frames / rate - time.monotonic()
            if wait > 0: time.sleep(wait)
        if workload in ('full1080', 'full4k'):
            peer.update([peer.raw(0, 0, width, height, colour[frames % 2])])
        elif workload == 'patch':                      # 64x64 patch walking a 16x8 grid
            cell = frames % 128
            peer.update([peer.raw(64 + (cell % 16) * 100, 64 + (cell // 16) * 100, 64, 64, colour[frames % 2])])
        else:                                          # scroll: shift up 16 rows, new strip
            peer.update([peer.copyrect(0, 0, width, height - 16, 0, 16),
                         peer.raw(0, height - 16, width, 16, colour[frames % 2])])
        sent_at = time.monotonic(); frames += 1; sends.append(uptime_ns())
    elapsed = time.monotonic() - start
    cpu = (cpu_seconds(pid) or 0) - (cpu_start or 0)
    stop.set(); sampler.join(); rss_peak = max(peaks[0], rss_kib(pid) or 0)
    return {'workload': workload, 'width': width, 'height': height, 'seconds': round(elapsed, 3), 'offeredRate': rate,
            'updatesPerSecond': round(frames / elapsed, 2), 'updates': frames,
            'roundTripP50ms': None if not round_trips else round(percentile(round_trips, .5) * 1000, 2),
            'roundTripP95ms': None if not round_trips else round(percentile(round_trips, .95) * 1000, 2),
            'cpuSecondsPerSecond': round(cpu / elapsed, 3), 'peakRSSMiB': round(rss_peak / 1024, 1), '_sends': sends}


def uptime_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def milliseconds(values, fraction):
    value = percentile(values, fraction)
    return None if value is None else round(value / 1e6, 2)


def analyse_probe(sends, probe, rate):
    """Pairs probe arrivals with the latest update sent before each one."""
    vsync = sorted(probe['vsync'])
    arrivals, decode, late = {}, [], 0
    for sequence, at in probe['arrived']:
        index = bisect.bisect_right(sends, at) - 1
        if index < 0:
            continue                                   # initial framebuffer before any update
        arrivals[sequence] = sends[index]
        decode.append(at - sends[index])
        if rate and at - sends[index] > 1e9 / rate:
            late += 1                                  # pairing is ambiguous beyond one interval
    views = probe.get('views', 1)
    finished, rendered, resident, damage = {}, [], [], []
    for _, sequence, at, written, output, invalidated, _ in probe['drawn']:
        if sequence not in arrivals:
            continue
        finished.setdefault(sequence, []).append(at)
        rendered.append(written); resident.append(output); damage.append(invalidated)
    draw, display = [], []
    for sequence, times in finished.items():
        if len(times) < views:
            continue                                   # not drawn by every view
        at = max(times)
        draw.append(at - arrivals[sequence])
        index = bisect.bisect_left(vsync, at)
        if index < len(vsync):
            display.append(vsync[index] - arrivals[sequence])
    view_pixels = probe['view'][0] * probe['view'][1] * probe['backingScale'] ** 2
    mib = lambda value: None if value is None else round(value / 2**20, 2)
    return {'updatesSent': len(sends), 'framesArrived': len(decode), 'framesDrawn': len(draw), 'views': views,
            'renderedMiBPerViewFrameP50': mib(percentile(rendered, .5)),
            'renderedMiBPerViewFrameP95': mib(percentile(rendered, .95)),
            'residentOutputMiBP50': mib(percentile(resident, .5)),
            'damageFractionP50': None if not damage else round(percentile(damage, .5) / view_pixels, 4),
            'damageFractionP95': None if not damage else round(percentile(damage, .95) / view_pixels, 4),
            'arrivalsLaterThanOneInterval': late,
            'decodeP50ms': milliseconds(decode, .5), 'decodeP95ms': milliseconds(decode, .95),
            'drawP50ms': milliseconds(draw, .5), 'drawP95ms': milliseconds(draw, .95),
            'displayEstimateP50ms': milliseconds(display, .5), 'displayEstimateP95ms': milliseconds(display, .95),
            'refreshIntervalMs': None if len(vsync) < 2 else round((vsync[-1] - vsync[0]) / (len(vsync) - 1) / 1e6, 2),
            'probeView': probe.get('view'), 'probeBackingScale': probe.get('backingScale'),
            'probeScaling': probe.get('scaling')}


def run(frontend, target, workload, seconds, work, rate, probe_views=1):
    width, height = WORKLOADS[workload]
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1)
    port = listener.getsockname()[1]
    args = ['-SecurityTypes=None', '-SendClipboard=0', '-AcceptClipboard=0', '-ScalingFactor=100',
            '-RemoteResize=0', '-ReconnectOnError=0', f'127.0.0.1::{port}']
    state = work / f'{frontend}-{workload}'
    probe_report = work / f'probe-{workload}.json'
    if frontend == 'native':
        process = isolated.launch(target, state, args)['process']
    elif frontend == 'probe':
        state.mkdir(parents=True)
        process = subprocess.Popen([str(target), f'127.0.0.1::{port}', str(probe_report), '--views', str(probe_views)],
                                   env=isolated.environment(state), stdout=subprocess.DEVNULL)
    else:
        state.mkdir(parents=True)
        env = isolated.environment(state)
        process = subprocess.Popen([str(target), *args], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        listener.settimeout(30)
        connection, _ = listener.accept()
        with connection:
            peer = Peer(connection); peer.handshake(width, height)
            result = serve(peer, workload, width, height, seconds, process.pid, rate)
            if frontend == 'probe':
                process.send_signal(signal.SIGTERM); process.wait(10)
                result.update(analyse_probe(result['_sends'], json.loads(probe_report.read_text()), rate))
            return result
    finally:
        listener.close()
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try: process.wait(10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        if frontend == 'native':
            isolated.cleanup(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--native', type=Path, help='TidyVNC.app from build/native-ui-frontend')
    parser.add_argument('--fltk', type=Path, help='retained FLTK vncviewer executable')
    parser.add_argument('--probe', type=Path, help='native-presentation-probe from the core build (tests/macos)')
    parser.add_argument('--probe-views', type=int, default=1, choices=range(1, 5), help='views bound to the probe session')
    parser.add_argument('--workload', action='append', choices=sorted(WORKLOADS))
    parser.add_argument('--seconds', type=float, default=8)
    parser.add_argument('--rate', type=float, default=30, help='offered updates per second (0: unpaced)')
    parser.add_argument('--report', type=Path, help='write JSON results here')
    args = parser.parse_args()
    targets = [(name, path.resolve()) for name, path in
               (('fltk', args.fltk), ('native', args.native), ('probe', args.probe)) if path]
    if not targets:
        parser.error('give --native, --fltk and/or --probe')
    workloads = args.workload or ['idle', 'full1080', 'full4k', 'scroll', 'patch']
    report = {'macOS': platform.mac_ver()[0], 'architecture': platform.machine(), 'results': [],
              'note': 'roundTrip is update-sent to next-request, a protocol proxy that excludes display time'}
    with tempfile.TemporaryDirectory(prefix='tidyvnc-workloads-') as temporary:
        for workload in workloads:
            for frontend, target in targets:
                result = run(frontend, target, workload, args.seconds, Path(temporary), args.rate, args.probe_views)
                result['frontend'] = frontend
                result.pop('_sends', None)
                report['results'].append(result)
                print(json.dumps(result), flush=True)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    sys.exit(main())
