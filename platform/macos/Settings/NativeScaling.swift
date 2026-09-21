// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import TidyVNC

extension tidyvnc_scaling: ABIValue {}
public enum NativeScalingMode: UInt32, CaseIterable, Sendable {
  case unscaled = 0, automatic, fixedRatio, fitWidth, fitHeight, exact, percent, independent
  public var fits: Bool { [.automatic, .fixedRatio, .fitWidth, .fitHeight].contains(self) }
  public var custom: Bool { [.exact, .percent, .independent].contains(self) }
  public var initialText: String {
    switch self {
    case .unscaled: "100"
    case .automatic: "Auto"
    case .fixedRatio: "FixedRatio"
    case .fitWidth: "FitWidth"
    case .fitHeight: "FitHeight"
    case .exact: "1920x1080"
    case .percent: "137.5"
    case .independent: "125%x80%"
    }
  }
}

public struct NativeScaling: Equatable, Sendable {
  public let mode: NativeScalingMode
  public let canonical: String
  public let x: UInt32, y: UInt32
  public let devicePixels: Bool
  public let filter: NativeScalingFilter
  public init(_ text: String, devicePixels: Bool = false, filter: NativeScalingFilter = .bilinear) throws {
    var value = abi(tidyvnc_scaling.self)
    let input = Array(text.utf8.prefix(65))
    try input.withUnsafeBufferPointer { bytes in
      _ = try checked { tidyvnc_scaling_parse(tidyvnc_bytes(data: bytes.baseAddress, length: UInt64(bytes.count)), &value, $0) }
    }
    guard let mode = NativeScalingMode(rawValue: value.mode) else { throw NativeScalingIssue.invalid }
    self.mode = mode; canonical = withUnsafeBytes(of: value.canonical) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    x = value.x; y = value.y; self.devicePixels = devicePixels; self.filter = filter
  }
  private init() { mode = .fixedRatio; canonical = "FixedRatio"; x = 10000; y = 10000; devicePixels = false; filter = .bilinear }
  public static let builtIn = NativeScaling()
}

public enum NativeScalingIssue: Error, Equatable { case invalid, dimensions, changed, closed }

// Each connection owns one state. Surface references are weak, and validation
// and application run synchronously on MainActor with no intervening await.
@MainActor public final class NativeScalingState: ObservableObject {
  @Published public private(set) var value: NativeScaling = .builtIn
  @Published public private(set) var sources: [NativeScalingOption: NativeOptionSource] = [:]
  private weak var session: NativeSession?
  private(set) var revision = UUID()
  private(set) var stopped = false
  private final class Surface {
    weak var view: NativeDesktopView?
    init(_ view: NativeDesktopView) { self.view = view }
  }
  private var surfaces: [Surface] = []
  var desktop: NativeDesktopView? { surfaces.compactMap(\.view).first }
  func register(_ view: NativeDesktopView) {
    surfaces.removeAll { $0.view == nil }
    if !surfaces.contains(where:{ $0.view === view }) { surfaces.append(Surface(view)) }
  }
  func unregister(_ view: NativeDesktopView) { surfaces.removeAll { $0.view == nil || $0.view === view } }
  func isBound(to session: NativeSession) -> Bool { !stopped && self.session === session }
  public init() {}
  public func bind(_ session: NativeSession) {
    guard !stopped, self.session !== session else { return }
    for surface in surfaces { surface.view?.canvasCoordinator?.stop() }
    self.session = session; revision = UUID()
    sources = session.initialScalingSources; value = session.initialScaling ?? .builtIn
  }
  fileprivate func apply(_ value: NativeScaling, expected: UUID) throws {
    guard !stopped else { throw NativeScalingIssue.closed }
    guard revision == expected else { throw NativeScalingIssue.changed }
    do {
      var canvases = Set<ObjectIdentifier>()
      for surface in surfaces {
        if let canvas = surface.view?.canvasCoordinator {
          if canvases.insert(ObjectIdentifier(canvas)).inserted { try canvas.validateScaling(value) }
        } else { try surface.view?.validateScaling(value) }
      }
    } catch { throw NativeScalingIssue.dimensions }
    if self.value.canonical != value.canonical { sources[.scaling] = .session }
    if self.value.devicePixels != value.devicePixels { sources[.devicePixels] = .session }
    if self.value.filter != value.filter { sources[.filter] = .session }
    revision = UUID(); self.value = value
  }
  public func stop() {
    stopped = true; revision = UUID()
    for surface in surfaces { surface.view?.canvasCoordinator?.stop() }
    surfaces.removeAll(); session = nil
  }
}

@MainActor public final class NativeScalingDraft: ObservableObject, Identifiable {
  nonisolated public let id = UUID()
  private weak var state: NativeScalingState?
  private let revision: UUID
  public let sources: [NativeScalingOption: NativeOptionSource]
  private let baseline: NativeScaling
  @Published public var mode: NativeScalingMode { didSet { issue = nil } }
  @Published public var devicePixels: Bool { didSet { issue = nil } }
  @Published public var filter: NativeScalingFilter { didSet { issue = nil } }
  @Published private var values: [NativeScalingMode: String]
  @Published public private(set) var issue: NativeScalingIssue?
  @Published public private(set) var finished = false
  public init(state: NativeScalingState) {
    self.state = state; revision = state.revision; baseline = state.value; sources = state.sources
    mode = baseline.mode; devicePixels = baseline.devicePixels; filter = baseline.filter
    values = [baseline.mode: baseline.canonical]
  }
  public var text: String {
    get { values[mode] ?? mode.initialText }
    set { values[mode] = newValue; issue = nil }
  }
  public var candidate: NativeScaling? {
    guard let result = try? NativeScaling(mode.custom ? text : mode.initialText, devicePixels: devicePixels, filter: filter),
          result.mode == mode || (mode == .percent && result.mode == .unscaled) else { return nil }
    return result
  }
  public func source(for option: NativeScalingOption) -> NativeOptionSource {
    let changed: Bool
    switch option {
    case .scaling: changed = candidate?.canonical != baseline.canonical
    case .devicePixels: changed = devicePixels != baseline.devicePixels
    case .filter: changed = filter != baseline.filter
    }
    return changed ? .session : sources[option] ?? .compiled
  }
  public var canApply: Bool { !finished && state?.stopped == false && candidate != nil && candidate != baseline }
  @discardableResult public func apply() -> Bool {
    guard !finished else { return false }
    guard let state else { issue = .closed; return false }
    guard let candidate else { issue = .invalid; return false }
    do { try state.apply(candidate, expected: revision); finished = true; return true }
    catch { issue = error as? NativeScalingIssue ?? .invalid; return false }
  }
  public func cancel() { finished = true; state = nil }
}
