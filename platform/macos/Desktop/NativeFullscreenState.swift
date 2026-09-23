// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine

// One connection's presentation owner. The experimental application uses native
// Spaces; the comparison harness retains both strategies for physical acceptance.
@MainActor public final class NativeFullscreenState: ObservableObject {
  public let windowStartup = NativeWindowStartupState()
  @Published public private(set) var policy: NativeFullscreenPolicy = .builtIn
  public private(set) var initialPolicy: NativeFullscreenPolicy = .builtIn
  public private(set) var sources: [NativeFullscreenOption:NativeOptionSource] = [:]
  public var selection: NativeFullscreenSelection { policy.selection }
  @Published public private(set) var phase: NativeFullscreenPhase = .windowed
  @Published public private(set) var message: String?
  @Published public private(set) var waitingForWindow = false
  public var onActivate: (() -> Void)?
  public var showsStatistics = false { didSet { controller?.showsStatistics = showsStatistics } }
  private(set) var revision = UUID()
  private weak var session: NativeSession?
  private weak var displays: NativeDisplayService?
  private weak var scaling: NativeScalingState?
  private weak var input: NativeInputState?
  private weak var commands: NativeDesktopCommands?
  private weak var source: NativeDesktopView?
  private weak var managedWindow: NSWindow?
  private var originalBehavior: NSWindow.CollectionBehavior?
  private var controller: NativeFullscreenController?
  private var observations = Set<AnyCancellable>()
  private var controllerObservations = Set<AnyCancellable>()
  private var pending: (id: UUID, generation: UInt64, action: () -> Void)?
  private var wantsFullscreen = false
  private var nextAttemptOverride: Bool?
  private var attemptGeneration: UInt64?
  private var automaticGeneration: UInt64?
  private var automaticTask: Task<Void,Never>?
  private var automaticID = UUID()
  var automaticEntryEligibility: (() -> Bool)? // Hidden-window fixture seam.
  private var stopped = false
  private let entryID = UUID()
  private let windows: any NativeFullscreenWindows
  public convenience init() { self.init(windows:AppKitFullscreenWindows()) }
  init(windows: any NativeFullscreenWindows) {
    self.windows = windows
    windowStartup.onResolved = { [weak self] in self?.scheduleAutomaticEntry() }
  }
  deinit {
    automaticTask?.cancel()
    let window = managedWindow, behavior = originalBehavior, commands = commands, id = entryID, source = source
    Task { @MainActor [weak window, weak commands, weak source] in
      commands?.removeFullscreenEntry(id:id)
      if source?.fullscreenStateOwnerID == id {
        source?.fullscreenStateOwnerID = nil
        if let behavior { window?.collectionBehavior = behavior }
      }
    }
  }
  public var canPresentSettings: Bool {
    !stopped && !waitingForWindow && commands?.isMinimizing != true && (phase == .windowed || phase == .active)
  }
  public var displaySnapshot: NativeDisplaySnapshot? { displays?.snapshot }
  var generation: UInt64? { session?.generation }
  var connected: Bool { !stopped && session?.isClosing == false && session?.snapshot.state == .connected }
  var currentDisplay: NativeDisplayID? { managedWindow.flatMap { windows.currentDisplay($0) } }
  var devicePixels: Bool { scaling.map { !$0.value.mode.fits && $0.value.devicePixels } ?? false }
  public func bind(session: NativeSession, displays: NativeDisplayService, scaling: NativeScalingState,
                   input: NativeInputState, commands: NativeDesktopCommands) {
    guard !stopped, self.session !== session else { return }
    clearController(); self.commands?.removeFullscreenEntry(id:entryID); observations.removeAll()
    showsStatistics = false
    self.session = session; self.displays = displays; self.scaling = scaling; self.input = input; self.commands = commands
    windowStartup.configure(session.initialWindowStartupPolicy)
    revision = UUID(); initialPolicy = session.initialFullscreenPolicy; policy = initialPolicy
    sources = session.initialFullscreenSources; wantsFullscreen = initialPolicy.startsFullscreen
    nextAttemptOverride = nil; attemptGeneration = nil
    commands.installFullscreenEntry(id:entryID) { [weak self] in
      guard let self, let controller = self.controller, !self.waitingForWindow else { throw NativeDesktopCommandIssue.unavailable }
      self.cancelAutomaticEntry()
      try controller.enter(self.selection,strategy:.nativeSpace)
    }
    displays.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in:&observations)
    commands.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in:&observations)
    session.$snapshot.removeDuplicates { $0.generation == $1.generation && $0.state == $1.state }
      .sink { [weak self] value in self?.observeConnection(value) }.store(in:&observations)
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
                 NSWindow.didDeminiaturizeNotification, NSWindow.didEndSheetNotification] {
      NotificationCenter.default.publisher(for:name).sink { [weak self] notice in MainActor.assumeIsolated {
        guard let self else { return }
        if notice.name == NSApplication.didBecomeActiveNotification || (notice.object as? NSWindow) === self.managedWindow { self.scheduleAutomaticEntry() }
      } }.store(in:&observations)
    }
    session.$isClosing.sink { [weak self] value in if value { self?.stop() } }.store(in:&observations)
    NotificationCenter.default.publisher(for:NSWindow.willCloseNotification).sink { [weak self] notice in MainActor.assumeIsolated {
      guard let self, let window = notice.object as? NSWindow, window === self.managedWindow else { return }
      self.cancelPending(); self.cancelAutomaticEntry(); self.wantsFullscreen = false
    } }.store(in:&observations)
    if let source { attach(source) }
  }
  func attach(_ view: NativeDesktopView) {
    guard !stopped else { return }
    if source !== view || managedWindow !== view.window { clearController(cancelIntent:controller != nil || managedWindow != nil); source = view }
    guard controller == nil, let window = view.window, let session, view.isBound(to:session),
          let displays, let scaling, let input, let commands else { return }
    windowStartup.attach(window)
    managedWindow = window; originalBehavior = window.collectionBehavior; view.fullscreenStateOwnerID = entryID
    // The app's command/shortcut owns entry. Preserve unrelated window flags and
    // restore the original behavior when the SwiftUI source detaches.
    window.collectionBehavior.remove(.fullScreenPrimary); window.collectionBehavior.remove(.fullScreenAuxiliary)
    window.collectionBehavior.insert(.fullScreenNone)
    let owner = NativeFullscreenController(session:session,source:view,displays:displays,scaling:scaling,input:input,commands:commands,windows:windows)
    controller = owner; owner.showsStatistics = showsStatistics
    owner.onActivate = { [weak self] in self?.onActivate?() }
    owner.onEnd = { [weak self] reason in
      self?.cancelAutomaticEntry()
      if reason == .windowed { self?.wantsFullscreen = false }
    }
    owner.$message.sink { [weak self] in self?.message = $0 }.store(in:&controllerObservations)
    owner.$phase.sink { [weak self] value in
      guard let self else { return }; self.phase = value
      if value == .entering { self.wantsFullscreen = true }
      if value == .exiting { self.wantsFullscreen = false }
      if value == .windowed, let id = self.pending?.id {
        Task { @MainActor [weak self] in self?.completePending(id) }
      }
    }.store(in:&controllerObservations)
    scheduleAutomaticEntry()
  }
  func detach(_ view: NativeDesktopView) {
    guard source === view else { return }
    clearController(); source = nil
  }
  private func cancelPending() { pending = nil; if waitingForWindow { waitingForWindow = false } }
  private func clearController(cancelIntent: Bool = true) {
    if cancelIntent { cancelAutomaticEntry(); wantsFullscreen = false }
    cancelPending(); controllerObservations.removeAll(); controller?.stop(); controller = nil; phase = .windowed
    if source?.fullscreenStateOwnerID == entryID {
      source?.fullscreenStateOwnerID = nil
      if let originalBehavior { managedWindow?.collectionBehavior = originalBehavior }
    }
    originalBehavior = nil; managedWindow = nil
  }
  // Return true if the caller can present immediately; otherwise retry only
  // after the original window is restored and the same connection is current.
  public func prepareForSettings(_ retry: @escaping () -> Void) -> Bool {
    guard canPresentSettings else { return false }
    if phase == .windowed {
      if automaticGeneration != nil { cancelAutomaticEntry(); wantsFullscreen = false }
      return true
    }
    guard connected, let generation, let controller else { return false }
    pending = (UUID(),generation,retry); waitingForWindow = true
    controller.exit(); return false
  }
  private func completePending(_ id: UUID) {
    guard let request = pending, request.id == id else { return }
    let valid = connected && generation == request.generation && phase == .windowed &&
      source?.window === managedWindow && managedWindow?.isVisible == true && managedWindow?.attachedSheet == nil && commands?.isMinimizing != true
    cancelPending()
    if valid { request.action() }
  }
  func refreshDisplays() { displays?.refresh() }
  func apply(_ candidate: NativeFullscreenPolicy, expected: UUID, generation: UInt64) throws {
    guard connected, phase == .windowed, !waitingForWindow, commands?.isMinimizing != true,
          revision == expected, self.generation == generation else { throw NativeDesktopCommandIssue.unavailable }
    if candidate.startsFullscreen != policy.startsFullscreen {
      sources[.startsFullscreen] = .session; nextAttemptOverride = candidate.startsFullscreen
    }
    if candidate.mode != policy.mode { sources[.mode] = .session }
    if candidate.selectedDisplays != policy.selectedDisplays { sources[.selectedDisplays] = .session }
    revision = UUID(); policy = candidate; message = nil
  }
  private func observeConnection(_ value: NativeSnapshot) {
    if value.state != .connected { cancelPending(); cancelAutomaticEntry() }
    if ![.idle,.closed,.failed].contains(value.state), attemptGeneration != value.generation {
      attemptGeneration = value.generation
      if let nextAttemptOverride { wantsFullscreen = nextAttemptOverride; self.nextAttemptOverride = nil }
    }
    if value.state == .connected, wantsFullscreen {
      automaticGeneration = value.generation; scheduleAutomaticEntry()
    }
  }
  private func cancelAutomaticEntry() {
    automaticTask?.cancel(); automaticTask = nil; automaticGeneration = nil; automaticID = UUID()
  }
  private func scheduleAutomaticEntry() {
    guard !stopped, automaticGeneration != nil, automaticTask == nil else { return }
    let id = automaticID
    automaticTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let self, self.automaticID == id else { return }
      self.automaticTask = nil; self.tryAutomaticEntry()
    }
  }
  private func tryAutomaticEntry() {
    guard windowStartup.resolved, let generation = automaticGeneration, connected, self.generation == generation,
          phase == .windowed, !waitingForWindow, commands?.isMinimizing != true,
          let source, let window = managedWindow, source.window === window,
          window.isVisible, !window.isMiniaturized, !source.isHiddenOrHasHiddenAncestor,
          window.attachedSheet == nil, !window.styleMask.contains(.fullScreen), let controller,
          automaticEntryEligibility?() ?? (NSApp?.isActive == true && window.isKeyWindow) else { return }
    cancelAutomaticEntry() // One attempt; notifications cannot retry a failed Space.
    do { try controller.enter(selection,strategy:.nativeSpace) }
    catch { wantsFullscreen = false; message = NativePresentationIssue(error:error,context:.fullscreen).message }
  }
  public func stop() {
    guard !stopped else { return }; stopped = true; windowStartup.stop()
    clearController(); commands?.removeFullscreenEntry(id:entryID); observations.removeAll(); onActivate = nil; showsStatistics = false
  }
}
