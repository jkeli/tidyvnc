// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

public enum NativeRemoteResizeSource: String, CaseIterable, Sendable {
  case custom, allDisplays, selectedDisplays
  public var title: String {
    switch self {
    case .custom: return String(localized:"settings.resize.custom.size", defaultValue:"Custom size")
    case .allDisplays: return String(localized:"settings.resize.all.local.displays", defaultValue:"All local displays")
    case .selectedDisplays: return String(localized:"settings.resize.selected.local.displays", defaultValue:"Selected local displays")
    }
  }
}

@MainActor public final class NativeRemoteResizeDraft: ObservableObject, Identifiable {
  public nonisolated let id = UUID()
  @Published public var source: NativeRemoteResizeSource = .custom
  @Published public var selectedDisplays = Set<NativeDisplayID>()
  @Published public var devicePixels = false
  @Published public private(set) var displaySnapshot: NativeDisplaySnapshot?
  private weak var displays: NativeDisplayService?
  private var reviewedDisplayGeneration: UInt64?
  @Published public var width = ""
  @Published public var height = ""
  @Published public private(set) var baseline: NativeRemoteDesktop?
  @Published public private(set) var isBusy = false
  @Published public private(set) var needsReload = false
  @Published public private(set) var message: String?
  @Published public private(set) var didApply = false
  private weak var session: NativeSession?
  private var operation: Task<Void,Never>?
  private var observations = Set<AnyCancellable>()
  private var stopped = false
  public init(session: NativeSession, displays: NativeDisplayService? = nil) {
    self.session = session; self.displays = displays
    if let displays {
      displaySnapshot = displays.snapshot
      selectedDisplays = Set(displays.snapshot.displays.map(\.id))
      displays.$snapshot.sink { [weak self] value in self?.displaySnapshot = value }.store(in:&observations)
    }
    session.$snapshot.sink { [weak self] value in MainActor.assumeIsolated {
      guard let self else { return }
      if let baseline = self.baseline, value.state != .connected || value.generation != baseline.snapshot.generation {
        self.needsReload = true; self.didApply = false
      }
      self.objectWillChange.send()
    }}.store(in:&observations)
    session.$isViewOnly.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&observations)
    session.$isClosing.sink { [weak self] value in if value { self?.stop() } }.store(in:&observations)
  }
  deinit { operation?.cancel() }
  public var canReload: Bool { !stopped && !isBusy && session?.snapshot.state == .connected && session?.isClosing == false }
  private var dimensions: (UInt32,UInt32)? {
    guard !width.isEmpty, !height.isEmpty, width.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          height.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let w = UInt32(width), let h = UInt32(height),
          (1...65535).contains(w), (1...65535).contains(h) else { return nil }
    return (w,h)
  }
  public var needsDisplayReload: Bool {
    source != .custom && displaySnapshot?.generation != reviewedDisplayGeneration
  }
  public var chosenDisplays: [NativeDisplay] {
    guard let snapshot = displaySnapshot else { return [] }
    return source == .allDisplays ? snapshot.displays : snapshot.displays.filter { selectedDisplays.contains($0.id) }
  }
  public var missingDisplays: [NativeDisplayID] {
    guard let snapshot = displaySnapshot, source == .selectedDisplays else { return [] }
    return selectedDisplays.filter { snapshot.display($0) == nil }.sorted { $0.rawValue < $1.rawValue }
  }
  public var displayLayout: NativeDisplayLayout? {
    guard source != .custom, displays != nil, displaySnapshot?.error == nil, missingDisplays.isEmpty else { return nil }
    return try? NativeDisplayLayout(displays:chosenDisplays,devicePixels:devicePixels)
  }
  public var displayMessage: String? {
    guard source != .custom else { return nil }
    if needsDisplayReload { return String(localized:"settings.resize.local.displays.changed.reload.to.review.the.new.arrangement.before.resizing", defaultValue:"Local displays changed. Reload to review the new arrangement before resizing.") }
    if displays == nil || displaySnapshot?.error != nil { return String(localized:"settings.resize.local.display.information.is.unavailable", defaultValue:"Local display information is unavailable.") }
    if !missingDisplays.isEmpty { return String(localized:"settings.resize.a.selected.display.is.disconnected.reconnect.it.or.remove.it.from.the", defaultValue:"A selected display is disconnected. Reconnect it or remove it from the selection.") }
    if chosenDisplays.isEmpty { return String(localized:"settings.fullscreen.select.at.least.one.display", defaultValue:"Select at least one display.") }
    if displayLayout == nil { return String(localized:"settings.resize.this.arrangement.cannot.be.mapped.displays.must.not.overlap.or.mirror.and", defaultValue:"This arrangement cannot be mapped. Displays must not overlap or mirror, and the layout must fit within 65535 × 65535 pixels.") }
    return nil
  }
  private var proposedLayout: NativeRemoteLayout? {
    guard let baseline else { return nil }
    if source != .custom { return try? displayLayout?.remoteLayout(matching:baseline.layout) }
    guard let dimensions, let first = baseline.layout.screens.first else { return nil }
    return try? NativeRemoteLayout(width:dimensions.0,height:dimensions.1,
      screens:[.init(id:first.id,x:0,y:0,width:dimensions.0,height:dimensions.1,flags:first.flags)])
  }
  public var canApply: Bool {
    guard canReload, !needsReload, !needsDisplayReload, let session, let baseline, let proposedLayout,
          session.generation == baseline.snapshot.generation, session.snapshot.supportsResize,
          !session.snapshot.resizePending, !session.isViewOnly else { return false }
    return proposedLayout.width != baseline.layout.width || proposedLayout.height != baseline.layout.height ||
      proposedLayout.screens.sorted { $0.id < $1.id } != baseline.layout.screens.sorted { $0.id < $1.id }
  }
  public func reload() {
    guard canReload, let session else { return }
    do {
      displays?.refresh()
      reviewedDisplayGeneration = displaySnapshot?.generation
      let current = try session.desktopLayout(); baseline = current
      width = String(current.layout.width); height = String(current.layout.height)
      needsReload = false; didApply = false; message = nil
    } catch { needsReload = true; message = String(localized:"settings.resize.the.current.remote.desktop.size.is.unavailable", defaultValue:"The current remote desktop size is unavailable.") }
  }
  public func apply() {
    // Re-read the OS immediately before admission; notifications can be delayed.
    if source != .custom { displays?.refresh() }
    guard canApply, let session, let baseline, let layout = proposedLayout else { return }
    do {
      guard try session.desktopLayout().layout == baseline.layout else {
        needsReload = true; message = String(localized:"settings.resize.the.server.s.desktop.layout.changed.reload.before.resizing", defaultValue:"The server’s desktop layout changed. Reload before resizing."); return
      }
    } catch { message = String(localized:"settings.resize.the.requested.desktop.size.is.unavailable", defaultValue:"The requested desktop size is unavailable."); return }
    isBusy = true; message = nil; didApply = false
    operation = Task { @MainActor [weak self] in
      do {
        _ = try await session.requestDesktopLayout(layout,expectedGeneration:baseline.snapshot.generation)
        guard let self, !self.stopped else { self?.finish(); return }
        guard session.generation == baseline.snapshot.generation else { throw NativeError(.stale,"Connection changed") }
        let current = try session.desktopLayout(); self.baseline = current
        self.width = String(current.layout.width); self.height = String(current.layout.height)
        self.didApply = true; self.needsReload = false
        self.message = String(localized:"settings.resize.server.size", defaultValue:"The server’s desktop is now \((current.layout.width).formatted()) × \((current.layout.height).formatted()) pixels.")
      } catch {
        if let self, !self.stopped {
          if let failure = error as? NativeCommandFailure, failure.reason == .serverRejected {
            self.message = String(localized:"settings.resize.server.rejection", defaultValue:"The server rejected the requested size (result \((failure.nativeResult).formatted())).")
          } else if let failure = error as? NativeCommandFailure, failure.reason == .timedOut {
            self.message = String(localized:"settings.resize.the.server.has.not.replied.wait.for.its.reply.or.reconnect.before", defaultValue:"The server has not replied. Wait for its reply or reconnect before resizing again.")
          } else if let issue = error as? NativeError, issue.status == .resourceLimit {
            self.message = String(localized:"settings.resize.this.size.exceeds.the.connection.s.framebuffer.limit.choose.a.smaller.size", defaultValue:"This size exceeds the connection’s framebuffer limit. Choose a smaller size.")
          } else { self.message = String(localized:"settings.resize.the.resize.did.not.complete.reload.the.current.desktop.size.before.trying", defaultValue:"The resize did not complete. Reload the current desktop size before trying again."); self.needsReload = true }
        }
      }
      self?.finish()
    }
  }
  private func finish() { isBusy = false; operation = nil }
  public func stop() { stopped = true; observations.removeAll(); operation?.cancel() }
  public func close() async { stop(); await operation?.value }
}
