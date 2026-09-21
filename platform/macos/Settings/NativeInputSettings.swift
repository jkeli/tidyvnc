// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

public struct NativeInputSettings: Equatable, Sendable {
  public let shortcutModifiers: NativeShortcutModifiers
  public let fullscreenSystemKeys: Bool
  public let emulateMiddle: Bool
  public let viewOnly: Bool
  public let cursorFallback: NativeCursorFallback
  public init(viewOnly: Bool = false, emulateMiddle: Bool = false, shortcutModifiers: NativeShortcutModifiers = .builtIn, fullscreenSystemKeys: Bool = true, cursorFallback: NativeCursorFallback = .hidden) {
    self.shortcutModifiers = shortcutModifiers; self.fullscreenSystemKeys = fullscreenSystemKeys
    self.viewOnly = viewOnly; self.emulateMiddle = emulateMiddle; self.cursorFallback = cursorFallback
  }
}
public enum NativeInputIssue: Error, Equatable { case changed, closed, failed }

// Connection-local policy. The session remains authoritative for view-only;
// copied editors cannot overwrite a later change or a replacement connection.
@MainActor public final class NativeInputState: ObservableObject {
  @Published public private(set) var value = NativeInputSettings()
  // Preserve the selected shape while cursor fallback is hidden, including a
  // connection document's dormant CursorType value and subsequent user edits.
  @Published public private(set) var inactiveCursor: NativeCursorFallback = .dot
  @Published public private(set) var sources: [NativeInputOption: NativeOptionSource] = [:]
  private weak var session: NativeSession?
  private var subscriptions = Set<AnyCancellable>()
  fileprivate var revision = UUID()
  private var stopped = false
  private var applying = false
  func isBound(to session: NativeSession) -> Bool { !stopped && self.session === session }
  fileprivate var generation: UInt64? { session?.generation }
  fileprivate var available: Bool { !stopped && session?.isClosing == false && session?.snapshot.state == .connected }
  public init() {}
  public func bind(_ session: NativeSession, inactiveCursor: NativeCursorFallback = .dot) {
    guard !stopped, self.session !== session else { return }
    subscriptions.removeAll(); self.session = session; revision = UUID()
    sources = session.initialInputSources
    self.inactiveCursor = session.initialInput.cursorFallback == .hidden ?
      (inactiveCursor == .system ? .system : .dot) : session.initialInput.cursorFallback
    sources[.viewOnly] = session.viewOnlySource; sources[.emulateMiddle] = session.middleButtonSource
    value = NativeInputSettings(viewOnly: session.isViewOnly, emulateMiddle: session.emulatesMiddleButton,
      shortcutModifiers: session.initialInput.shortcutModifiers, fullscreenSystemKeys: session.initialInput.fullscreenSystemKeys,
      cursorFallback: session.initialInput.cursorFallback)
    session.$isViewOnly.removeDuplicates().sink { [weak self] enabled in MainActor.assumeIsolated {
      guard let self, !self.applying, self.value.viewOnly != enabled else { return }
      self.revision = UUID(); self.sources[.viewOnly] = .session
      self.value = NativeInputSettings(viewOnly: enabled, emulateMiddle: self.value.emulateMiddle, shortcutModifiers: self.value.shortcutModifiers, fullscreenSystemKeys: self.value.fullscreenSystemKeys, cursorFallback: self.value.cursorFallback)
    } }.store(in: &subscriptions)
    session.$emulatesMiddleButton.removeDuplicates().sink { [weak self] enabled in MainActor.assumeIsolated {
      guard let self, !self.applying, self.value.emulateMiddle != enabled else { return }
      self.revision = UUID(); self.sources[.emulateMiddle] = .session
      self.value = NativeInputSettings(viewOnly: self.value.viewOnly, emulateMiddle: enabled, shortcutModifiers: self.value.shortcutModifiers, fullscreenSystemKeys: self.value.fullscreenSystemKeys, cursorFallback: self.value.cursorFallback)
    } }.store(in: &subscriptions)
    session.$snapshot.removeDuplicates { $0.generation == $1.generation && $0.state == $1.state }
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.revision = UUID() } }.store(in: &subscriptions)
  }
  fileprivate func apply(_ candidate: NativeInputSettings, revision: UUID, generation: UInt64?) throws {
    guard available, let session else { throw NativeInputIssue.closed }
    guard self.revision == revision, session.generation == generation else { throw NativeInputIssue.changed }
    guard candidate.shortcutModifiers.rawValue & ~15 == 0 else { throw NativeInputIssue.failed }
    applying = true
    defer { applying = false }
    do {
      if session.isViewOnly != candidate.viewOnly || session.emulatesMiddleButton != candidate.emulateMiddle {
        try session.setInputPolicy(viewOnly: candidate.viewOnly, emulateMiddle: candidate.emulateMiddle)
      }
    }
    catch { throw NativeInputIssue.failed }
    if value.viewOnly != candidate.viewOnly { sources[.viewOnly] = .session }
    if value.emulateMiddle != candidate.emulateMiddle { sources[.emulateMiddle] = .session }
    if value.shortcutModifiers != candidate.shortcutModifiers { sources[.shortcutModifiers] = .session }
    if value.fullscreenSystemKeys != candidate.fullscreenSystemKeys { sources[.fullscreenSystemKeys] = .session }
    if value.cursorFallback != candidate.cursorFallback { sources[.cursorFallback] = .session }
    if candidate.cursorFallback != .hidden { inactiveCursor = candidate.cursorFallback }
    self.revision = UUID(); value = candidate
  }
  public func stop() { stopped = true; revision = UUID(); subscriptions.removeAll(); session = nil }
}

@MainActor public final class NativeInputDraft: ObservableObject, Identifiable {
  nonisolated public let id = UUID()
  private weak var state: NativeInputState?
  private let revision: UUID
  private let generation: UInt64?
  public let sources: [NativeInputOption: NativeOptionSource]
  private let baseline: NativeInputSettings
  @Published public var shortcutModifiers: NativeShortcutModifiers { didSet { issue = nil } }
  @Published public var fullscreenSystemKeys: Bool { didSet { issue = nil } }
  @Published public var emulateMiddle: Bool { didSet { issue = nil } }
  @Published public var viewOnly: Bool { didSet { issue = nil } }
  @Published public var cursorFallback: NativeCursorFallback { didSet { issue = nil } }
  @Published public private(set) var issue: NativeInputIssue?
  @Published public private(set) var finished = false
  public init(state: NativeInputState) {
    sources = state.sources
    self.state = state; revision = state.revision; generation = state.generation; baseline = state.value
    shortcutModifiers = baseline.shortcutModifiers; fullscreenSystemKeys = baseline.fullscreenSystemKeys
    viewOnly = baseline.viewOnly; emulateMiddle = baseline.emulateMiddle; cursorFallback = baseline.cursorFallback
  }
  public func source(for option: NativeInputOption) -> NativeOptionSource {
    let changed: Bool
    switch option {
    case .viewOnly: changed = viewOnly != baseline.viewOnly
    case .emulateMiddle: changed = emulateMiddle != baseline.emulateMiddle
    case .shortcutModifiers: changed = shortcutModifiers != baseline.shortcutModifiers
    case .fullscreenSystemKeys: changed = fullscreenSystemKeys != baseline.fullscreenSystemKeys
    case .cursorFallback: changed = cursorFallback != baseline.cursorFallback
    }
    return changed ? .session : sources[option] ?? .compiled
  }
  private var candidate: NativeInputSettings { NativeInputSettings(viewOnly: viewOnly, emulateMiddle: emulateMiddle, shortcutModifiers: shortcutModifiers, fullscreenSystemKeys: fullscreenSystemKeys, cursorFallback: cursorFallback) }
  public var canApply: Bool { !finished && state?.available == true && candidate != baseline }
  @discardableResult public func apply() -> Bool {
    guard !finished else { return false }
    guard let state else { issue = .closed; return false }
    do { try state.apply(candidate, revision: revision, generation: generation); finished = true; return true }
    catch { issue = error as? NativeInputIssue ?? .failed; return false }
  }
  public func cancel() { finished = true; state = nil }
}
