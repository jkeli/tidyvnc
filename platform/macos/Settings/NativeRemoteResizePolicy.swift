// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

public struct NativeRemoteResizePolicy: Equatable, Sendable {
  public let enabled: Bool
  public let initialSize: String
  let initialWidth: UInt32?, initialHeight: UInt32?
  private init() { enabled = true; initialSize = ""; initialWidth = nil; initialHeight = nil }
  public static let builtIn = NativeRemoteResizePolicy()
  public init(enabled: Bool = true, initialSize: String = "") throws {
    self.enabled = enabled
    if initialSize.isEmpty { self.initialSize = ""; initialWidth = nil; initialHeight = nil; return }
    guard initialSize.utf8.count <= 32 else { throw NativeError(.invalidArgument,"Invalid initial desktop size") }
    let parts = initialSize.split(separator:"x",omittingEmptySubsequences:false)
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
          let width = UInt32(parts[0]), let height = UInt32(parts[1]) else { throw NativeError(.invalidArgument,"Use width x height in remote pixels") }
    _ = try NativeRemoteLayout(width:width,height:height,screens:[.init(id:0,x:0,y:0,width:width,height:height)])
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
