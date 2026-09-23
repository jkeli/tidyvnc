// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// Manual presentation-latency probe; not a CTest case (it needs WindowServer and
// an external peer, see tests/perf/viewer-workloads.py --probe). It hosts the
// production NativeSession and NativeDesktopView in an on-screen window and, on
// SIGTERM, writes JSON with CLOCK_UPTIME_RAW nanoseconds:
//   arrived  [sequence, t]  core frame update observed on the main actor
//   drawn    [sequence, t]  first AppKit draw of that sequence finished
//   vsync    [t]            display-link target timestamps (next refresh)
import AppKit
import Combine
@testable import TidyVNCNative

func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@MainActor final class Probe: NSObject {
  private let endpoint: String, output: URL
  private let runtime: NativeRuntime, session: NativeSession
  private let window: NSWindow, view: NativeDesktopView
  private var arrived: [[UInt64]] = [], drawn: [[UInt64]] = [], vsync: [UInt64] = []
  private var lastArrived: UInt64 = 0, lastDrawn: UInt64 = 0
  private var subscriptions = Set<AnyCancellable>()
  private var link: CADisplayLink?, signalSource: (any DispatchSourceSignal)?
  init(endpoint: String, output: URL, size: CGSize, scaling: String) throws {
    self.endpoint = endpoint; self.output = output
    runtime = try NativeRuntime()
    var config = NativeSessionConfiguration(); config.securityTypes = [1]; config.reconnectOnError = false
    config.alertOnFatalError = false
    session = try runtime.makeSession(configuration: config)
    window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "TidyVNC presentation probe"
    view = NativeDesktopView(frame: NSRect(origin: .zero, size: size))
    view.scaling = scaling
    super.init()
    window.contentView = view; window.center(); window.orderFrontRegardless()
    view.onDrawn = { [weak self] sequence in
      guard let self, sequence != self.lastDrawn else { return }
      self.lastDrawn = sequence; self.drawn.append([sequence, uptime()])
    }
    session.frameUpdates.sink { [weak self] image in MainActor.assumeIsolated {
      guard let self, let image, image.sequence != self.lastArrived else { return }
      self.lastArrived = image.sequence; self.arrived.append([image.sequence, uptime()])
    } }.store(in: &subscriptions)
    view.bind(session)
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
      "view": [view.bounds.width, view.bounds.height], "backingScale": window.backingScaleFactor,
      "desktopRectangle": [view.desktopRectangle.width, view.desktopRectangle.height], "scaling": view.scaling]
    do {
      try JSONSerialization.data(withJSONObject: report).write(to: output)
      exit(0)
    } catch { FileHandle.standardError.write(Data("probe write failed: \(error)\n".utf8)); exit(1) }
  }
}

@main struct Main {
  static func main() {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else {
      FileHandle.standardError.write(Data("usage: native-presentation-probe <host::port> <report.json> [width height [scaling]]\n".utf8)); exit(2)
    }
    let width = arguments.count > 4 ? Double(arguments[3]) ?? 1280 : 1280
    let height = arguments.count > 4 ? Double(arguments[4]) ?? 720 : 720
    let scaling = arguments.count > 5 ? arguments[5] : "FixedRatio"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
      do {
        let probe = try Probe(endpoint: arguments[1], output: URL(fileURLWithPath: arguments[2]),
                              size: CGSize(width: width, height: height), scaling: scaling)
        probe.start()
        withExtendedLifetime(probe) { app.run() }
      } catch { FileHandle.standardError.write(Data("probe setup failed: \(error)\n".utf8)); exit(1) }
    }
  }
}
