// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// Manual presentation-latency probe; not a CTest case (it needs WindowServer and
// an external peer, see tests/perf/viewer-workloads.py --probe). It hosts the
// production NativeSession and NativeDesktopView in an on-screen window and, on
// SIGTERM, writes JSON with CLOCK_UPTIME_RAW nanoseconds:
//   arrived  [sequence, t]  core frame update observed on the main actor
//   drawn    [view, sequence, t, renderedBytes, presentationBytes, damagePixels, reusedTiles]
//            first AppKit draw of that sequence in that view finished; bytes are
//            resampled output written for the frame and resident output tiles,
//            damage is the invalidated area in device pixels
//   vsync    [t]            display-link target timestamps (next refresh)
// NSView display links need macOS 14; the app itself supports macOS 13.
import AppKit
import Combine
@testable import TidyVNCNative

func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@available(macOS 14, *) @MainActor final class Probe: NSObject {
  private let endpoint: String, output: URL
  private let runtime: NativeRuntime, session: NativeSession
  private let windows: [NSWindow], views: [NativeDesktopView]
  private var arrived: [[UInt64]] = [], drawn: [[UInt64]] = [], vsync: [UInt64] = []
  private var lastArrived: UInt64 = 0, lastDrawn: [UInt64]
  private var subscriptions = Set<AnyCancellable>()
  private var link: CADisplayLink?, signalSource: (any DispatchSourceSignal)?
  init(endpoint: String, output: URL, size: CGSize, scaling: String, views count: Int) throws {
    self.endpoint = endpoint; self.output = output
    runtime = try NativeRuntime()
    var config = NativeSessionConfiguration(); config.securityTypes = [1]; config.reconnectOnError = false
    config.alertOnFatalError = false
    session = try runtime.makeSession(configuration: config)
    // Several views of one session share its frame stream, like fullscreen canvases.
    views = (0..<count).map { _ in NativeDesktopView(frame: NSRect(origin: .zero, size: size)) }
    windows = views.indices.map { index in
      let window = NSWindow(contentRect: NSRect(x: 40 + 60 * index, y: 80 + 60 * index, width: Int(size.width), height: Int(size.height)),
                            styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.title = "TidyVNC presentation probe \(index + 1)"
      return window
    }
    lastDrawn = Array(repeating: 0, count: count)
    super.init()
    for (index, view) in views.enumerated() {
      view.scaling = scaling
      windows[index].contentView = view; windows[index].orderFrontRegardless()
      view.onDrawn = { [weak self, weak view] sequence in
        guard let self, let view, sequence != self.lastDrawn[index] else { return }
        self.lastDrawn[index] = sequence
        let scale = view.window?.backingScaleFactor ?? 1, damage = view.lastInvalidatedRectangle
        self.drawn.append([UInt64(index), sequence, uptime(), UInt64(view.renderedBytes), UInt64(view.presentationBytes),
                           UInt64((damage.width * scale * damage.height * scale).rounded()), UInt64(view.reusedTiles)])
      }
    }
    let view = views[0]
    session.frameUpdates.sink { [weak self] image in MainActor.assumeIsolated {
      guard let self, let image, image.sequence != self.lastArrived else { return }
      self.lastArrived = image.sequence; self.arrived.append([image.sequence, uptime()])
    } }.store(in: &subscriptions)
    for view in views { view.bind(session) }
    let link = view.displayLink(target: self, selector: #selector(refresh(_:)))
    link.add(to: .main, forMode: .common); self.link = link
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.finish() } }
    source.resume(); signalSource = source
  }
  @objc private func refresh(_ link: CADisplayLink) { vsync.append(UInt64(link.targetTimestamp * 1e9)) }
  func start() {
    Task { @MainActor in
      do { _ = try await session.connect(endpoint: endpoint) }
      catch { FileHandle.standardError.write(Data("probe connect failed: \(error)\n".utf8)); exit(1) }
    }
  }
  private func finish() {
    link?.invalidate(); link = nil
    let report: [String: Any] = ["arrived": arrived, "drawn": drawn, "vsync": vsync,
      "view": [views[0].bounds.width, views[0].bounds.height], "views": views.count,
      "backingScale": windows[0].backingScaleFactor,
      "desktopRectangle": [views[0].desktopRectangle.width, views[0].desktopRectangle.height], "scaling": views[0].scaling]
    do {
      try JSONSerialization.data(withJSONObject: report).write(to: output)
      exit(0)
    } catch { FileHandle.standardError.write(Data("probe write failed: \(error)\n".utf8)); exit(1) }
  }
}

@main struct Main {
  static func main() {
    let arguments = CommandLine.arguments
    func option(_ name: String) -> String? {
      arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    let count = Int(option("--views") ?? "1") ?? 0, width = Double(option("--width") ?? "1280") ?? 0
    let height = Double(option("--height") ?? "720") ?? 0, scaling = option("--scaling") ?? "FixedRatio"
    guard arguments.count >= 3, (1...4).contains(count), width >= 64, height >= 64 else {
      FileHandle.standardError.write(Data(("usage: native-presentation-probe <host::port> <report.json> " +
        "[--views 1-4] [--width W] [--height H] [--scaling S]\n").utf8)); exit(2)
    }
    guard #available(macOS 14, *) else {
      FileHandle.standardError.write(Data("native-presentation-probe needs macOS 14 or later\n".utf8)); exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
      do {
        let probe = try Probe(endpoint: arguments[1], output: URL(fileURLWithPath: arguments[2]),
                              size: CGSize(width: width, height: height), scaling: scaling, views: count)
        probe.start()
        withExtendedLifetime(probe) { app.run() }
      } catch { FileHandle.standardError.write(Data("probe setup failed: \(error)\n".utf8)); exit(1) }
    }
  }
}
