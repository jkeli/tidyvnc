// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import TidyVNC

extension tidyvnc_desktop_size: ABIValue {}
// The shared core DesktopSize grammars (legacy command line or strict native).
enum NativeDesktopSize {
  static func parse(_ text: String, legacy: Bool) throws -> (width: UInt32, height: UInt32)? {
    var value = abi(tidyvnc_desktop_size.self)
    try checked { error in withText(text) {
      tidyvnc_desktop_size_parse($0, UInt32(legacy ? TIDYVNC_DESKTOP_SIZE_LEGACY : TIDYVNC_DESKTOP_SIZE_STRICT), &value, error)
    } }
    return value.width == 0 ? nil : (value.width, value.height)
  }
}

public struct NativeRemoteResizePolicy: Equatable, Sendable {
  public let enabled: Bool
  public let initialSize: String
  let initialWidth: UInt32?, initialHeight: UInt32?
  private init() { enabled = true; initialSize = ""; initialWidth = nil; initialHeight = nil }
  public static let builtIn = NativeRemoteResizePolicy()
  public init(enabled: Bool = true, initialSize: String = "") throws {
    self.enabled = enabled
    if initialSize.isEmpty { self.initialSize = ""; initialWidth = nil; initialHeight = nil; return }
    guard let size = try? NativeDesktopSize.parse(initialSize, legacy: false) else {
      throw NativeError(.invalidArgument,"Use width x height in remote pixels")
    }
    let width = size.width, height = size.height
    initialWidth = width; initialHeight = height; self.initialSize = "\(width)x\(height)"
  }
}

@MainActor public final class NativeRemoteResizePolicyDraft: ObservableObject, Identifiable {
  public nonisolated let id = UUID()
  @Published public var enabled: Bool
  @Published public var initialSize: String
  @Published public private(set) var message: String?
  public let sources: [NativeResizeOption:NativeOptionSource]
  private let revision: UUID
  private let baseline: NativeRemoteResizePolicy
  private weak var session: NativeSession?
  private var stopped = false
  private var observations = Set<AnyCancellable>()
  public init(session: NativeSession) {
    sources = session.resizeSources
    self.session = session; baseline = session.resizePolicy; revision = session.resizePolicyRevision
    enabled = baseline.enabled; initialSize = baseline.initialSize
    session.$resizePolicy.sink { [weak self, weak session] _ in
      guard let self, let session, session.resizePolicyRevision != self.revision else { return }
      self.message = String(localized:"settings.resize.the.connection.s.resize.settings.changed.close.and.reopen.this.sheet", defaultValue:"The connection’s resize settings changed. Close and reopen this sheet.")
    }.store(in:&observations)
    session.$isClosing.sink { [weak self] value in if value { self?.cancel(); self?.objectWillChange.send() } }.store(in:&observations)
  }
  public func source(_ option: NativeResizeOption) -> NativeOptionSource {
    if option == .enabled && enabled != baseline.enabled { return .session }
    if option == .initialSize && (try? NativeRemoteResizePolicy(initialSize:initialSize).initialSize) != baseline.initialSize { return .session }
    return sources[option] ?? .compiled
  }
  public var validationMessage: String? {
    (try? NativeRemoteResizePolicy(enabled:enabled,initialSize:initialSize)) == nil ?
      String(localized:"settings.resize.use.widthxheight.with.each.dimension.from.1.to.65535.or.leave.the", defaultValue:"Use widthxheight with each dimension from 1 to 65535, or leave the initial size blank.") : nil
  }
  public var canApply: Bool {
    !stopped && session?.isClosing == false && session?.resizePolicyRevision == revision &&
      (try? NativeRemoteResizePolicy(enabled:enabled,initialSize:initialSize)).map { $0 != baseline } == true
  }
  public func restoreInitial() {
    guard !stopped, let session else { return }
    enabled = session.initialResizePolicy.enabled; initialSize = session.initialResizePolicy.initialSize
  }
  public func apply() -> Bool {
    guard canApply, let session else { return false }
    do {
      try session.setResizePolicy(NativeRemoteResizePolicy(enabled:enabled,initialSize:initialSize),expected:revision)
      stopped = true; return true
    } catch { message = String(localized:"settings.resize.the.connection.s.resize.settings.changed.close.and.reopen.this.sheet", defaultValue:"The connection’s resize settings changed. Close and reopen this sheet."); return false }
  }
  public func cancel() { stopped = true; observations.removeAll() }
}
