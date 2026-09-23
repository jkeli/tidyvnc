// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine

public enum NativeFullscreenSelection: Equatable, Sendable {
  case current, all, selected([NativeDisplayID])
}
// Both strategies remain explicit until physical Spaces/mixed-display comparison
// establishes the app's policy. This owner never replaces a SwiftUI window delegate.
public enum NativeFullscreenStrategy: Sendable { case nativeSpace, borderless }
public enum NativeFullscreenPhase: Sendable { case windowed, entering, active, exiting }
enum NativeFullscreenEndReason { case windowed, disconnected }

@MainActor protocol NativeFullscreenWindows: AnyObject, Sendable {
  func currentDisplay(_ window: NSWindow) -> NativeDisplayID?
  func makeWindow(display: NativeDisplay, primary: Bool, strategy: NativeFullscreenStrategy) throws -> NSWindow
  func show(_ window: NSWindow, focus: Bool)
  func hide(_ window: NSWindow)
  func toggleNative(_ window: NSWindow)
  func dispose(_ window: NSWindow)
}
@MainActor private final class FullscreenWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
@MainActor final class AppKitFullscreenWindows: NativeFullscreenWindows {
  func currentDisplay(_ window: NSWindow) -> NativeDisplayID? { window.screen.flatMap { try? AppKitDisplaySource.identity($0) } }
  func makeWindow(display: NativeDisplay, primary: Bool, strategy: NativeFullscreenStrategy) throws -> NSWindow {
    guard let screen = NSScreen.screens.first(where:{ (try? AppKitDisplaySource.identity($0)) == display.id }) else { throw NativeDisplayError.unavailable }
    guard let primaryScreen = NSScreen.screens.first,
          AppKitDisplaySource.rectangle(screen.frame,primary:primaryScreen.frame) == display.bounds,
          Double(screen.backingScaleFactor) == display.backingScale else { throw NativeDisplayError.unavailable }
    let native = strategy == .nativeSpace && primary
    let window = FullscreenWindow(contentRect:screen.frame,styleMask:native ? [.titled,.resizable,.closable] : [.borderless],backing:.buffered,defer:false,screen:screen)
    window.isReleasedWhenClosed = false; window.backgroundColor = .black
    window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
    if native { window.collectionBehavior = [.fullScreenPrimary] }
    else if strategy == .nativeSpace { window.collectionBehavior = [.fullScreenAuxiliary,.canJoinAllSpaces] }
    else { window.collectionBehavior = [.moveToActiveSpace,.fullScreenNone] }
    window.setFrame(screen.frame,display:false)
    return window
  }
  func show(_ window: NSWindow, focus: Bool) {
    if focus && NSApp.isActive { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
  }
  func hide(_ window: NSWindow) { window.orderOut(nil) }
  func toggleNative(_ window: NSWindow) { window.toggleFullScreen(nil) }
  func dispose(_ window: NSWindow) { window.orderOut(nil); window.close() }
}

@MainActor public final class NativeFullscreenController: NSObject, ObservableObject, NSWindowDelegate {
  @MainActor private final class Surface {
    let display: NativeDisplay, window: NSWindow, view: NativeDesktopView
    let content: NativeFullscreenContentView
    init(_ display: NativeDisplay, _ window: NSWindow, _ view: NativeDesktopView) {
      self.display = display; self.window = window; self.view = view
      content = NativeFullscreenContentView(desktop:view)
    }
  }
  @Published public private(set) var phase: NativeFullscreenPhase = .windowed
  public var onActivate: (() -> Void)?
  public var showsStatistics = false { didSet { if showsStatistics != oldValue { updateStatistics() } } }
  private var statisticsInformation: NativeConnectionInformation?
  private func updateStatistics() {
    let value = !stopped && phase == .active && showsStatistics ? statisticsInformation : nil
    for surface in surfaces { surface.content.showStatistics(value) }
  }
  var onEnd: ((NativeFullscreenEndReason) -> Void)?
  @Published public private(set) var message: String?
  @Published public private(set) var missingDisplays: [NativeDisplayID] = []
  public private(set) var selection: NativeFullscreenSelection = .current
  public private(set) var strategy: NativeFullscreenStrategy = .nativeSpace
  public var canvasLayout: NativeDisplayLayout? { canvas?.layout }
  private weak var session: NativeSession?
  private weak var source: NativeDesktopView?
  private weak var original: NSWindow?
  private weak var displays: NativeDisplayService?
  private weak var scaling: NativeScalingState?
  private weak var input: NativeInputState?
  private weak var commands: NativeDesktopCommands?
  private let windows: any NativeFullscreenWindows
  private var surfaces: [Surface] = []
  private var primary: Surface?
  private var canvas: NativeDesktopCanvas?
  private var subscriptions = Set<AnyCancellable>()
  private var deadline: Task<Void,Never>?
  private var ticket = UUID(), owner = UUID()
  private var topology: [NativeDisplay] = []
  private var sourceWasHidden = false, originalWasVisible = false, sourceChanged = false
  private var stopped = false
  private var minimizeAfterExit = false
  private var minimizeGeneration: UInt64 = 0
  var transitionTimeout: Duration = .seconds(15)
  var ownedViews: [NativeDesktopView] { surfaces.map(\.view) }
  var ownedWindows: [NSWindow] { surfaces.map(\.window) }
  private var minimizeTargetAvailable: Bool {
    !stopped && session?.isClosing == false && session?.snapshot.state == .connected &&
      originalWasVisible && original != nil && source?.window === original &&
      original?.attachedSheet == nil && original?.isMiniaturized == false &&
      original?.styleMask.contains(.miniaturizable) == true &&
      original?.styleMask.contains(.fullScreen) == false &&
      surfaces.allSatisfy { $0.window.attachedSheet == nil } &&
      commands?.fullscreenOwner === self && surfaces.contains { commands?.isActiveHost($0.view) == true }
  }
  var canMinimize: Bool { phase == .active && minimizeTargetAvailable }
  func minimize() throws {
    guard canMinimize, let session else { throw NativeDesktopCommandIssue.unavailable }
    minimizeGeneration = session.generation; minimizeAfterExit = true
    exit()
  }

  public convenience init(session: NativeSession, source: NativeDesktopView, displays: NativeDisplayService,
                          scaling: NativeScalingState, input: NativeInputState, commands: NativeDesktopCommands) {
    self.init(session:session,source:source,displays:displays,scaling:scaling,input:input,commands:commands,windows:AppKitFullscreenWindows())
  }
  init(session: NativeSession, source: NativeDesktopView, displays: NativeDisplayService,
       scaling: NativeScalingState, input: NativeInputState, commands: NativeDesktopCommands, windows: any NativeFullscreenWindows) {
    self.session = session; self.source = source; self.displays = displays
    self.scaling = scaling; self.input = input; self.commands = commands; self.windows = windows
    super.init()
    displays.$snapshot.sink { [weak self] snapshot in MainActor.assumeIsolated {
      guard let self, self.phase != .windowed else { return }
      // Entering/leaving a Space changes visibleFrame as the Dock/menu bar move.
      // Fullscreen uses full display bounds, not that windowed work area.
      guard snapshot.error != nil || !Self.sameTopology(snapshot.displays,self.topology) else { return }
      self.finish(message:String(localized:"desktop.fullscreen.displays.changed.full.screen.was.closed.choose.displays.again", defaultValue:"Displays changed. Full screen was closed; choose displays again."))
    } }.store(in:&subscriptions)
    session.$isClosing.sink { [weak self] closing in MainActor.assumeIsolated {
      if closing { self?.stop() }
    } }.store(in:&subscriptions)
    session.$snapshot.sink { [weak self] snapshot in MainActor.assumeIsolated {
      guard let self else { return }
      self.statisticsInformation = snapshot.generation == self.session?.generation ? snapshot.information : nil
      if snapshot.state != .connected { self.showsStatistics = false; self.finish(disconnected:true) }
      else { self.updateStatistics() }
    } }.store(in:&subscriptions)
    NotificationCenter.default.publisher(for:NSWindow.willCloseNotification).sink { [weak self] notice in MainActor.assumeIsolated {
      guard let self, let window = notice.object as? NSWindow, window === self.original else { return }
      self.finish(restore:false)
    } }.store(in:&subscriptions)
  }
  private static func sameTopology(_ lhs: [NativeDisplay], _ rhs: [NativeDisplay]) -> Bool {
    lhs.count == rhs.count && zip(lhs,rhs).allSatisfy {
      $0.id == $1.id && $0.bounds == $1.bounds && $0.backingScale == $1.backingScale && $0.isPrimary == $1.isPrimary
    }
  }
  deinit {
    deadline?.cancel()
    let surfaces = surfaces, canvas = canvas, windows = windows, owner = owner
    let source = source, original = original, commands = commands, hidden = sourceWasHidden, visible = originalWasVisible, changed = sourceChanged
    Task { @MainActor [weak source, weak original, weak commands] in
      commands?.endFullscreen(id:owner)
      canvas?.stop()
      for surface in surfaces { surface.content.showStatistics(nil); surface.window.delegate = nil; surface.view.detach(); surface.window.contentView = nil; windows.dispose(surface.window) }
      if source?.fullscreenOwnerID == owner {
        source?.fullscreenOwnerID = nil
        if changed { source?.isHidden = hidden; if visible, let original { windows.show(original,focus:false) } }
        source?.restoreAutomaticResize()
      }
    }
  }
  public func enter(_ selection: NativeFullscreenSelection, strategy: NativeFullscreenStrategy) throws {
    guard !stopped, phase == .windowed, let session, session.snapshot.state == .connected, !session.isClosing,
          let source, source.isBound(to:session), source.fullscreenOwnerID == nil,
          let original = source.window, !original.isMiniaturized, !original.styleMask.contains(.fullScreen), original.attachedSheet == nil,
          let displays, let scaling, scaling.isBound(to:session), let input, input.isBound(to:session),
          let commands, commands.isBound(to:session), !commands.isMinimizing, commands.fullscreenOwner == nil else { throw NativeDesktopCommandIssue.unavailable }
    displays.refresh()
    let snapshot = displays.snapshot, current = windows.currentDisplay(original)
    guard snapshot.error == nil, !snapshot.displays.isEmpty else { throw NativeDisplayError.unavailable }
    let chosen: [NativeDisplay], missing: [NativeDisplayID]
    switch selection {
    case .current:
      let resolved = snapshot.resolve([],current:current); chosen = resolved.displays; missing = []
    case .all: chosen = snapshot.displays; missing = []
    case .selected(let ids):
      guard !ids.isEmpty else { throw NativeError(.invalidArgument,String(localized:"desktop.fullscreen.select.at.least.one.display", defaultValue:"Select at least one display")) }
      let resolved = snapshot.resolve(ids,current:current); chosen = resolved.displays; missing = resolved.missing
    }
    let layout = try NativeDisplayLayout(displays:chosen,devicePixels:!scaling.value.mode.fits && scaling.value.devicePixels)
    let mainID = chosen.first(where:{ $0.id == current })?.id ?? chosen.first(where:\.isPrimary)?.id ?? chosen[0].id
    self.original = original; sourceWasHidden = source.isHidden; originalWasVisible = original.isVisible; sourceChanged = false
    self.selection = selection; self.strategy = strategy; missingDisplays = missing
    message = missing.isEmpty ? nil : String(localized:"desktop.fullscreen.some.selected.displays.are.unavailable.full.screen.uses.the.available.displays", defaultValue:"Some selected displays are unavailable. Full screen uses the available displays.")
    topology = snapshot.displays; owner = UUID(); source.fullscreenOwnerID = owner
    phase = .entering
    commands.beginFullscreen(self,id:owner)
    do {
      try session.setFocused(false); source.clearCommandInput()
      let canvas = try NativeDesktopCanvas(session:session,scaling:scaling); self.canvas = canvas
      canvas.beginAutomaticResize()
      canvas.onError = { [weak self] text in self?.message = text }
      for display in chosen {
        let view = NativeDesktopView(frame:.init(x:0,y:0,width:display.bounds.width,height:display.bounds.height))
        view.isHidden = true; view.bind(session); view.observeScaling(scaling); view.observeInput(input); view.observeCommands(commands)
        view.onError = source.onError; view.onContextMenu = source.onContextMenu; view.fullscreenOverride = { true }
        try view.setCanvasViewport(layout.viewport(for:display.id)) // Never claim window resize ownership while attaching.
        let window = try windows.makeWindow(display:display,primary:display.id == mainID,strategy:strategy)
        let surface = Surface(display,window,view); surfaces.append(surface)
        window.contentView = surface.content; window.delegate = self; window.title = original.title
        view.onFullscreenPointerEntered = { [weak self, weak view] in
          guard let self, self.phase == .active, NSApp.isActive, let view,
                let surface = self.surfaces.first(where:{ $0.view === view }) else { return }
          self.windows.show(surface.window,focus:true); _ = view.focusDesktop()
        }
        if display.id == mainID { primary = surface }
      }
      try canvas.configure(surfaces.map { ($0.display,$0.view) })
      guard let primary else { throw NativeDisplayError.unavailable }
      if strategy == .nativeSpace {
        armDeadline(); windows.show(primary.window,focus:true); windows.toggleNative(primary.window)
      } else { activate() }
    } catch { finish(message:NativePresentationIssue(error:error,context:.fullscreen).message); throw error }
  }
  public func exit() {
    guard phase != .windowed else { return }
    if strategy == .nativeSpace, phase == .active, let primary {
      beginExit(); windows.toggleNative(primary.window)
    } else if phase == .entering || strategy == .borderless { finish(completedExit:phase == .active) }
  }
  private func activate() {
    guard phase == .entering, let primary else { return }
    deadline?.cancel(); deadline = nil; phase = .active
    sourceChanged = true; source?.isHidden = true
    if let original { windows.hide(original) }
    for surface in surfaces {
      surface.view.isHidden = false; _ = surface.window.makeFirstResponder(surface.view)
      windows.show(surface.window,focus:surface === primary)
    }
    commands?.attach(primary.view); _ = primary.view.focusDesktop()
    canvas?.setAutomaticResizeAvailable(true)
    updateStatistics()
  }
  private func beginExit() {
    guard phase != .windowed else { return }
    canvas?.setAutomaticResizeAvailable(false)
    phase = .exiting; updateStatistics(); try? session?.setFocused(false)
    for surface in surfaces { surface.view.isHidden = true; surface.view.clearCommandInput() }
    armDeadline()
  }
  private func armDeadline() {
    deadline?.cancel(); let id = UUID(); ticket = id; let timeout = transitionTimeout
    deadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for:timeout) } catch { return }
      guard let self, self.ticket == id else { return }
      self.finish(message:String(localized:"desktop.fullscreen.the.full.screen.transition.did.not.finish.try.again", defaultValue:"The full-screen transition did not finish. Try again."))
    }
  }
  private func finish(message: String? = nil, restore: Bool = true, completedExit: Bool = false, disconnected: Bool = false) {
    guard phase != .windowed || !surfaces.isEmpty else { return }
    let restoresSource = restore && source?.fullscreenOwnerID == owner
    let minimize = minimizeAfterExit && completedExit && restore && minimizeTargetAvailable && session?.generation == minimizeGeneration
    minimizeAfterExit = false
    deadline?.cancel(); deadline = nil; ticket = UUID()
    try? session?.setFocused(false)
    commands?.endFullscreen(id:owner)
    let old = surfaces; surfaces = []; primary = nil
    canvas?.stop(); canvas = nil
    for surface in old { surface.content.showStatistics(nil); surface.window.delegate = nil; surface.view.onFullscreenPointerEntered = nil; surface.view.detach(); surface.window.contentView = nil; windows.dispose(surface.window) }
    if source?.fullscreenOwnerID == owner {
      source?.fullscreenOwnerID = nil
      if sourceChanged {
        source?.isHidden = sourceWasHidden
        if restore, originalWasVisible, let original { windows.show(original,focus:!minimize) }
      }
      if restore, let source { commands?.attach(source); if !minimize { _ = source.focusDesktop() } }
    }
    sourceChanged = false; phase = .windowed
    if let message { self.message = message }
    onEnd?(disconnected ? .disconnected : .windowed)
    // Only a successful owned exit can carry the intent to the original host.
    // Its existing minimize operation handles completion, timeout and input gates.
    if minimize {
      do { try commands?.perform(.minimize) }
      catch { self.message = String(localized:"desktop.the.window.could.not.be.minimized.try.minimize.again", defaultValue:"The window could not be minimized. Try Minimize again.") }
    }
    if restoresSource { source?.restoreAutomaticResize() }
  }
  public func stop() { guard !stopped else { return }; stopped = true; statisticsInformation = nil; showsStatistics = false; finish(); subscriptions.removeAll() }
  public func windowDidEnterFullScreen(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === primary?.window else { return }
    activate()
  }
  public func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, surfaces.contains(where:{ $0.window === window }) else { return }
    onActivate?()
  }
  public func windowWillExitFullScreen(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === primary?.window, phase == .active else { return }
    beginExit()
  }
  public func windowDidExitFullScreen(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === primary?.window else { return }
    finish(completedExit:true)
  }
  public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
    if window === primary?.window { finish(message:String(localized:"desktop.fullscreen.full.screen.could.not.be.opened.try.again", defaultValue:"Full screen could not be opened. Try again.")) }
  }
  public func windowDidFailToExitFullScreen(_ window: NSWindow) {
    if window === primary?.window { finish(message:String(localized:"desktop.fullscreen.full.screen.could.not.exit.normally.the.windowed.desktop.was.restored", defaultValue:"Full screen could not exit normally. The windowed desktop was restored.")) }
  }
  public func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow, surfaces.contains(where:{ $0.window === window }) { finish() }
  }
}
