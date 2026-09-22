// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

public enum NativeFullscreenMode: String, CaseIterable, Sendable {
  case current, all, selected
  public var title: String { switch self { case .current: String(localized:"settings.fullscreen.current.display", defaultValue:"Current display"); case .all: String(localized:"settings.fullscreen.all.displays", defaultValue:"All displays"); case .selected: String(localized:"settings.fullscreen.selected.displays", defaultValue:"Selected displays") } }
}
@MainActor public final class NativeFullscreenDraft: ObservableObject, Identifiable {
  public nonisolated let id = UUID()
  @Published public var startsFullscreen: Bool
  @Published public var mode: NativeFullscreenMode
  @Published public var selectedDisplays = Set<NativeDisplayID>()
  @Published public private(set) var message: String?
  private weak var state: NativeFullscreenState?
  private let revision: UUID, generation: UInt64?
  private let baseline: NativeFullscreenPolicy
  private let sources: [NativeFullscreenOption:NativeOptionSource]
  private var reviewed: UInt64?
  private var stopped = false
  private var observation: AnyCancellable?
  public init(state: NativeFullscreenState) {
    self.state = state; baseline = state.policy; revision = state.revision; generation = state.generation
    sources = state.sources; startsFullscreen = baseline.startsFullscreen; mode = baseline.mode
    selectedDisplays = Set(baseline.selectedDisplays)
    state.refreshDisplays(); reviewed = state.displaySnapshot?.generation
    observation = state.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
  }
  public var snapshot: NativeDisplaySnapshot? { state?.displaySnapshot }
  public var selection: NativeFullscreenSelection {
    switch mode {
    case .current: .current
    case .all: .all
    case .selected: .selected(selectedDisplays.sorted { $0.rawValue < $1.rawValue })
    }
  }
  private var candidate: NativeFullscreenPolicy? {
    try? .init(startsFullscreen:startsFullscreen,mode:mode,selectedDisplays:Array(selectedDisplays))
  }
  public func source(_ option: NativeFullscreenOption) -> NativeOptionSource {
    switch option {
    case .startsFullscreen: if startsFullscreen != baseline.startsFullscreen { return .session }
    case .mode: if mode != baseline.mode { return .session }
    case .selectedDisplays: if selectedDisplays != Set(baseline.selectedDisplays) { return .session }
    }
    return sources[option] ?? .compiled
  }
  public func restoreInitial() {
    guard !stopped, let state else { return }
    startsFullscreen = state.initialPolicy.startsFullscreen; mode = state.initialPolicy.mode
    selectedDisplays = Set(state.initialPolicy.selectedDisplays)
  }
  public var missing: [NativeDisplayID] {
    selectedDisplays.filter { snapshot?.display($0) == nil }.sorted { $0.rawValue < $1.rawValue }
  }
  public var chosenDisplays: [NativeDisplay] {
    guard let snapshot else { return [] }
    switch mode {
    case .current: return snapshot.resolve([],current:state?.currentDisplay).displays
    case .all: return snapshot.displays
    case .selected: return selectedDisplays.isEmpty ? [] : snapshot.resolve(Array(selectedDisplays),current:state?.currentDisplay).displays
    }
  }
  public var needsReview: Bool { snapshot?.generation != reviewed }
  public var validationMessage: String? {
    if state?.connected != true || state?.revision != revision || state?.generation != generation { return String(localized:"settings.fullscreen.the.connection.changed.close.and.reopen.this.sheet", defaultValue:"The connection changed. Close and reopen this sheet.") }
    if needsReview { return String(localized:"settings.fullscreen.displays.changed.review.the.new.arrangement.before.applying", defaultValue:"Displays changed. Review the new arrangement before applying.") }
    if snapshot?.error != nil || snapshot?.displays.isEmpty != false { return String(localized:"settings.fullscreen.display.information.is.unavailable", defaultValue:"Display information is unavailable.") }
    if mode == .selected && selectedDisplays.isEmpty { return String(localized:"settings.fullscreen.select.at.least.one.display", defaultValue:"Select at least one display.") }
    if (try? NativeFullscreenPolicy.validateIDs(Array(selectedDisplays))) == nil {
      return String(localized:"settings.fullscreen.select.up.to.64.displays.with.valid.saved.identities.remove.unavailable.selections", defaultValue:"Select up to 64 displays with valid saved identities. Remove unavailable selections if necessary.")
    }
    if (try? NativeDisplayLayout(displays:chosenDisplays,devicePixels:state?.devicePixels ?? false)) == nil { return String(localized:"settings.fullscreen.this.display.arrangement.cannot.be.mapped.overlapping.or.mirrored.displays.are.not", defaultValue:"This display arrangement cannot be mapped. Overlapping or mirrored displays are not supported.") }
    return nil
  }
  public var canApply: Bool { !stopped && state?.phase == .windowed && validationMessage == nil && candidate != nil && candidate != baseline }
  public func reviewDisplays() { guard !stopped else { return }; state?.refreshDisplays(); reviewed = snapshot?.generation; objectWillChange.send() }
  public func apply() -> Bool {
    guard !stopped, let state else { return false }
    state.refreshDisplays()
    guard canApply, let generation, let candidate else { objectWillChange.send(); return false }
    do { try state.apply(candidate,expected:revision,generation:generation); cancel(); return true }
    catch { message = String(localized:"settings.fullscreen.the.connection.changed.close.and.reopen.this.sheet", defaultValue:"The connection changed. Close and reopen this sheet."); return false }
  }
  public func cancel() { stopped = true; observation = nil }
}
