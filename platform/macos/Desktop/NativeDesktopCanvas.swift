// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine

// One connection's fullscreen canvas intent. Window creation/Spaces transitions
// belong to the fullscreen owner; this object coordinates its weak view members.
@MainActor public final class NativeDesktopCanvas {
  @MainActor private final class Member {
    let display: NativeDisplay
    weak var view: NativeDesktopView?
    init(_ display: NativeDisplay, _ view: NativeDesktopView) { self.display = display; self.view = view }
  }
  let id = UUID()
  private weak var session: NativeSession?
  private weak var scaling: NativeScalingState?
  private var members: [Member] = []
  private var subscriptions = Set<AnyCancellable>()
  private var stopped = false
  private weak var resizeCoordinator: NativeRemoteResizeCoordinator?
  private var ownsAutomaticResize = false
  private var automaticResizeAvailable = false
  private var current: NativeScaling
  public private(set) var layout: NativeDisplayLayout?
  public private(set) var pan = CGPoint.zero
  public var onError: ((String) -> Void)?
  func usesScaling(_ state: NativeScalingState?) -> Bool { scaling === state }

  public init(session: NativeSession, scaling: NativeScalingState) throws {
    guard scaling.isBound(to:session), !session.isClosing else { throw NativeError(.invalidArgument,"Canvas requires this connection's scaling state") }
    self.session = session; self.scaling = scaling; current = scaling.value
    scaling.$value.dropFirst().sink { [weak self] value in MainActor.assumeIsolated {
      guard let self, !self.stopped else { return }
      do {
        let reset = self.current.canonical != value.canonical || self.current.devicePixels != value.devicePixels
        try self.update(value,pan:reset ? .zero : self.pan)
      } catch { self.onError?(String(describing:error)) }
    } }.store(in:&subscriptions)
    // Images are delivered before individual views necessarily install them. The
    // authoritative dimensions here keep every member's pan bound identical.
    session.frameUpdates.sink { [weak self] image in MainActor.assumeIsolated {
      guard let self, !self.stopped else { return }
      do {
        let point = try self.clamped(image == nil ? .zero : self.pan,layout:self.layout,scaling:self.current,image:image)
        self.pan = point
        for member in self.members { member.view?.setSharedPan(point) }
      } catch { self.onError?(String(describing:error)) }
    } }.store(in:&subscriptions)
    session.$isClosing.sink { [weak self] closing in MainActor.assumeIsolated {
      if closing { self?.stop() }
    } }.store(in:&subscriptions)
  }
  deinit {
    let members = members, owner = id, coordinator = resizeCoordinator
    Task { @MainActor in
      for member in members { member.view?.leaveCanvas(owner:owner) }
      coordinator?.endCanvas(owner:owner)
    }
  }

  // The window owner reserves the whole layout before constructing surfaces.
  // It enables requests only after entry and suspends them before exit.
  func beginAutomaticResize() {
    guard !stopped, !ownsAutomaticResize else { return }
    ownsAutomaticResize = true; resizeCoordinator = session?.remoteResize; resizeCoordinator?.beginCanvas(owner:id)
    publishAutomaticResize()
  }
  func setAutomaticResizeAvailable(_ available: Bool) {
    automaticResizeAvailable = available; publishAutomaticResize()
  }
  private func publishAutomaticResize() {
    guard ownsAutomaticResize, let layout else { return }
    session?.remoteResize.updateCanvas(owner:id,layout:layout,unscaled:current.mode == .unscaled,
      available:automaticResizeAvailable && members.allSatisfy { $0.view != nil })
  }

  // Replaces a complete selected-display arrangement. Invalid membership, mapped
  // geometry or any surface's tile budget leaves the previous group untouched.
  public func configure(_ surfaces: [(display: NativeDisplay, view: NativeDesktopView)]) throws {
    guard !stopped, let session, !session.isClosing, let scaling, scaling.isBound(to:session) else { throw NativeError(.closing,"Canvas is closed") }
    guard !surfaces.isEmpty, Set(surfaces.map { ObjectIdentifier($0.view) }).count == surfaces.count,
          surfaces.allSatisfy({ $0.view.isBound(to:session) && ($0.view.canvasCoordinator == nil || $0.view.canvasCoordinator === self) }) else {
      throw NativeError(.invalidArgument,"Canvas surfaces must be distinct views of this session")
    }
    let next = surfaces.map { Member($0.display,$0.view) }
    let mapped = try mapping(next,scaling:current)
    let point = try clamped(pan,layout:mapped,scaling:current,image:session.frame)
    try validate(next,layout:mapped,pan:point,scaling:current)
    for member in members where !surfaces.contains(where:{ $0.view === member.view }) { member.view?.leaveCanvas(owner:id) }
    members = next; layout = mapped; pan = point
    for member in members {
      guard let view = member.view else { continue }
      view.canvasCoordinator = self; view.canvasOwnerID = id; view.observeScaling(scaling)
      view.installCanvas(try mapped.viewport(for:member.display.id),pan:point,scaling:current)
    }
    publishAutomaticResize()
  }
  private func mapping(_ members: [Member], scaling value: NativeScaling) throws -> NativeDisplayLayout {
    // Retained fullscreen policy: fitting modes use logical display geometry;
    // unscaled/custom modes may use normalized device-pixel monitor geometry.
    try NativeDisplayLayout(displays:members.map(\.display),devicePixels:!value.mode.fits && value.devicePixels)
  }
  private func clamped(_ point: CGPoint, layout: NativeDisplayLayout?, scaling value: NativeScaling, image: NativeImage?) throws -> CGPoint {
    guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0, point.x <= 65535, point.y <= 65535 else {
      throw NativeError(.invalidArgument,"Invalid canvas pan")
    }
    guard let layout, let image else { return .zero }
    return try NativeGeometry(width:image.width,height:image.height,
      viewport:.init(width:Int(layout.width),height:Int(layout.height)),backingScale:1,
      scaling:value.canonical,devicePixels:layout.devicePixels,pan:point).panPosition
  }
  private func validate(_ members: [Member], layout: NativeDisplayLayout, pan: CGPoint, scaling: NativeScaling) throws {
    for member in members {
      try member.view?.validateCanvas(layout.viewport(for:member.display.id),pan:pan,scaling:scaling)
    }
  }
  func validateScaling(_ value: NativeScaling) throws {
    guard !stopped else { throw NativeError(.closing,"Canvas is closed") }
    guard !members.isEmpty else { return }
    let mapped = try mapping(members,scaling:value)
    let reset = current.canonical != value.canonical || current.devicePixels != value.devicePixels
    let point = try clamped(reset ? .zero : pan,layout:mapped,scaling:value,image:session?.frame)
    try validate(members,layout:mapped,pan:point,scaling:value)
  }
  private func update(_ value: NativeScaling, pan point: CGPoint) throws {
    guard !members.isEmpty else { current = value; return }
    let mapped = try mapping(members,scaling:value)
    let point = try clamped(point,layout:mapped,scaling:value,image:session?.frame)
    try validate(members,layout:mapped,pan:point,scaling:value)
    current = value; layout = mapped; pan = point
    for member in members { member.view?.installCanvas(try mapped.viewport(for:member.display.id),pan:point,scaling:value) }
    publishAutomaticResize()
  }
  public func setPan(_ point: CGPoint) throws {
    guard !stopped, session?.isClosing == false else { throw NativeError(.closing,"Canvas is closed") }
    let point = try clamped(point,layout:layout,scaling:current,image:session?.frame)
    guard point != pan else { return }
    if let layout { try validate(members,layout:layout,pan:point,scaling:current) }
    pan = point
    for member in members { member.view?.setSharedPan(point) }
  }
  func remove(_ view: NativeDesktopView) {
    // Detach does not silently reflow the surviving monitors. The fullscreen
    // owner explicitly configures the next complete topology when it is ready.
    for member in members where member.view === view { member.view = nil }
    view.leaveCanvas(owner:id)
    publishAutomaticResize()
    if members.allSatisfy({ $0.view == nil }) { members.removeAll(); layout = nil; pan = .zero }
  }
  public func stop() {
    guard !stopped else { return }
    stopped = true; subscriptions.removeAll()
    for member in members { member.view?.leaveCanvas(owner:id) }
    members.removeAll(); layout = nil; pan = .zero
    session?.remoteResize.endCanvas(owner:id); ownsAutomaticResize = false
  }
}
