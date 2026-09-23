// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

// One coordinator per session. Geometry input has a view identity; removing an
// older view must not invalidate its replacement. Only one source is authoritative.
struct NativeResizeViewport: Equatable {
  let width: Double, height: Double, scale: Double
  let unscaled: Bool, devicePixels: Bool, available: Bool
}
@MainActor public final class NativeRemoteResizeCoordinator: ObservableObject {
  @Published public private(set) var message: String?
  private weak var session: NativeSession?
  private var observations = Set<AnyCancellable>()
  private var owner: UUID?
  private var viewport: NativeResizeViewport?
  // A fullscreen canvas reserves geometry ownership even while unavailable.
  // Ordinary source-window updates are remembered, never used during the lease.
  private var canvasOwner: UUID?
  private var canvasGeometry: Geometry?
  private enum Geometry: Equatable {
    case window(NativeResizeViewport)
    case canvas(NativeDisplayLayout, unscaled: Bool, available: Bool)
    var available: Bool {
      switch self { case .window(let value): value.available; case .canvas(_,_,let value): value }
    }
  }
  private var geometry: Geometry? { canvasOwner == nil ? viewport.map(Geometry.window) : canvasGeometry }
  private var geometryOwner: UUID? { canvasOwner ?? owner }
  private var delay: Task<Void,Never>?, operation: Task<Void,Never>?, wake: Task<Void,Never>?
  private var generation: UInt64 = 0
  private var initialPolicy: NativeRemoteResizePolicy = .builtIn
  private var initialAttempted = false
  private var initialViewport: Geometry?
  private var manualViewport: Geometry?
  private var lastAttempt: Target?
  private var stopped = false
  private struct Target: Equatable {
    let width: UInt32, height: UInt32, generation: UInt64
    let revision: UUID
    let initial: Bool
    let owner: UUID
    let canvas: NativeDisplayLayout?
  }
  init(session: NativeSession) {
    self.session = session
    session.$snapshot.removeDuplicates { a,b in
      a.generation == b.generation && a.state == b.state && a.supportsResize == b.supportsResize && a.resizePending == b.resizePending
    }.sink { [weak self] _ in self?.schedule() }.store(in:&observations)
    session.$isViewOnly.removeDuplicates().sink { [weak self] _ in self?.schedule() }.store(in:&observations)
    session.$resizePolicy.removeDuplicates().sink { [weak self] value in
      if !value.enabled { self?.operation?.cancel() }; self?.schedule()
    }.store(in:&observations)
    session.$isClosing.sink { [weak self] value in if value { self?.stop() } }.store(in:&observations)
  }
  deinit { delay?.cancel(); operation?.cancel(); wake?.cancel() }
  func beginAttempt(generation: UInt64, policy: NativeRemoteResizePolicy) {
    self.generation = generation; initialPolicy = policy
    initialAttempted = false; initialViewport = nil; manualViewport = nil; lastAttempt = nil; message = nil
    schedule()
  }
  func attach(owner: UUID) {
    guard !stopped, canvasOwner == nil, self.owner != owner else { return }
    self.owner = owner; viewport = nil; lastAttempt = nil; schedule()
  }
  func manualRequest() {
    manualViewport = geometry; lastAttempt = nil; delay?.cancel(); delay = nil
  }
  func update(owner: UUID, viewport: NativeResizeViewport) {
    guard !stopped else { return }
    guard self.owner == owner || (self.owner == nil && canvasOwner == nil && viewport.available) else { return }
    // Attachment explicitly chooses the authoritative geometry source.
    guard self.owner != owner || self.viewport != viewport else { return }
    self.owner = owner; self.viewport = viewport; schedule()
  }
  func detach(owner: UUID) {
    guard self.owner == owner else { return }
    self.owner = nil; viewport = nil; delay?.cancel(); delay = nil; operation?.cancel(); lastAttempt = nil
    // Sent requests still drain; no later viewport work is scheduled while detached.
  }
  func beginCanvas(owner: UUID) {
    guard !stopped, canvasOwner != owner else { return }
    canvasOwner = owner; canvasGeometry = nil; lastAttempt = nil
    delay?.cancel(); delay = nil; operation?.cancel(); schedule()
  }
  func updateCanvas(owner: UUID, layout: NativeDisplayLayout, unscaled: Bool, available: Bool) {
    guard !stopped, canvasOwner == owner else { return }
    let value = Geometry.canvas(layout,unscaled:unscaled,available:available)
    guard canvasGeometry != value else { return }
    canvasGeometry = value
    if !available { delay?.cancel(); delay = nil; operation?.cancel() }
    schedule()
  }
  func endCanvas(owner: UUID) {
    guard canvasOwner == owner else { return }
    canvasOwner = nil; canvasGeometry = nil; lastAttempt = nil
    delay?.cancel(); delay = nil; operation?.cancel(); schedule()
  }
  private func schedule() {
    guard !stopped, wake == nil else { return }
    wake = Task { @MainActor [weak self] in
      guard let self else { return }; self.wake = nil; self.reconcile()
    }
  }
  private func target() -> Target? {
    guard let session else { return nil }
    if generation != session.generation {
      generation = session.generation; initialPolicy = session.resizePolicy
      initialAttempted = false; initialViewport = nil; manualViewport = nil; lastAttempt = nil; message = nil
    }
    guard !stopped, !session.isClosing, session.snapshot.state == .connected,
          session.snapshot.supportsResize, !session.snapshot.resizePending, !session.isViewOnly,
          session.resizePolicy.enabled, let geometry, geometry.available, let owner = geometryOwner else { return nil }
    if let manualViewport {
      guard geometry != manualViewport else { return nil }
      self.manualViewport = nil // A later return to this geometry is a new resize.
    }
    if let initialViewport, geometry != initialViewport { self.initialViewport = nil }
    if !initialAttempted, let w = initialPolicy.initialWidth, let h = initialPolicy.initialHeight {
      return Target(width:w,height:h,generation:generation,revision:session.resizePolicyRevision,initial:true,owner:owner,canvas:nil)
    }
    guard geometry != initialViewport else { return nil }
    if case .canvas(let layout,let unscaled,_) = geometry {
      guard unscaled else { return nil }
      return Target(width:layout.width,height:layout.height,generation:generation,revision:session.resizePolicyRevision,
        initial:false,owner:owner,canvas:layout)
    }
    guard case .window(let viewport) = geometry, viewport.unscaled, viewport.width.isFinite, viewport.height.isFinite,
          viewport.scale.isFinite, viewport.scale > 0 else { return nil }
    let scale = viewport.devicePixels ? viewport.scale : 1
    let width = floor(viewport.width * scale), height = floor(viewport.height * scale)
    guard width >= 1, height >= 1, width <= 65535, height <= 65535 else { return nil }
    return Target(width:UInt32(width),height:UInt32(height),generation:generation,revision:session.resizePolicyRevision,initial:false,owner:owner,canvas:nil)
  }
  private func reconcile() {
    delay?.cancel(); delay = nil
    guard operation == nil, let target = target(), target != lastAttempt else { return }
    delay = Task { @MainActor [weak self] in
      do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
      guard let self, !Task.isCancelled, self.target() == target else { return }
      self.delay = nil; self.send(target)
    }
  }
  private func send(_ target: Target) {
    guard let session, operation == nil, self.target() == target else { return }
    do {
      let current = try session.desktopLayout()
      guard let first = current.layout.screens.first else { return }
      let requested: NativeRemoteLayout
      if let canvas = target.canvas { requested = try canvas.remoteLayout(matching:current.layout) }
      else { requested = try NativeRemoteLayout(width:target.width,height:target.height,
        screens:[.init(id:first.id,x:0,y:0,width:target.width,height:target.height,flags:first.flags)]) }
      lastAttempt = target; if target.initial { initialAttempted = true; initialViewport = geometry }
      if requested == current.layout { schedule(); return }
      message = nil
      operation = Task { @MainActor [weak self] in
        do { _ = try await session.requestAutomaticDesktopLayout(requested,expectedGeneration:target.generation) }
        catch {
          guard let self else { return }
          if !self.stopped && session.generation == target.generation && self.geometryOwner == target.owner {
            if let error = error as? NativeError, error.status == .busy {
              self.lastAttempt = nil; if target.initial { self.initialAttempted = false; self.initialViewport = nil }
            } else if !(error is CancellationError) {
              self.message = String(localized:"desktop.resize.the.automatic.desktop.resize.did.not.complete.you.can.request.a.size", defaultValue:"The automatic desktop resize did not complete. You can request a size with Resize Remote Desktop.")
            }
          }
        }
        guard let self else { return }; self.operation = nil; self.schedule()
      }
    } catch { message = String(localized:"desktop.resize.the.remote.desktop.layout.is.unavailable.for.automatic.resizing", defaultValue:"The remote desktop layout is unavailable for automatic resizing.") }
  }
  public func stop() {
    stopped = true; observations.removeAll(); delay?.cancel(); delay = nil; wake?.cancel(); wake = nil
    operation?.cancel(); viewport = nil; owner = nil; canvasGeometry = nil; canvasOwner = nil
  }
  func close() async { stop(); await operation?.value }
}
