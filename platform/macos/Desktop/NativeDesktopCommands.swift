// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine

@MainActor protocol NativeDesktopCommandHost: AnyObject {
  var commandWindow: NSWindow? { get }
  var commandViewport: CGSize { get }
  var commandDesktopSize: CGSize { get }
  func focusForCommand() -> Bool
  func captureKeyboardForCommand() throws
  func releaseKeyboardForCommand()
  func clearCommandInput()
  func canPan(_ direction: NativeDesktopPan) -> Bool
  func panDesktop(_ direction: NativeDesktopPan) -> Bool
  func refreshCommandFocus()
}
public enum NativeDesktopPan: CaseIterable, Sendable {
  case left, right, up, down, origin
  public var title: String {
    switch self {
    case .left: return String(localized:"desktop.pan.left", defaultValue:"Pan Left")
    case .right: return String(localized:"desktop.pan.right", defaultValue:"Pan Right")
    case .up: return String(localized:"desktop.pan.up", defaultValue:"Pan Up")
    case .down: return String(localized:"desktop.pan.down", defaultValue:"Pan Down")
    case .origin: return String(localized:"desktop.return.to.top.left", defaultValue:"Return to Top Left")
    }
  }
}
public enum NativeDesktopCommand: Sendable { case fullscreen, minimize, fitWindow, control, alt, controlAltDelete, captureKeyboard, releaseKeyboard, pan(NativeDesktopPan) }
public enum NativeDesktopCommandIssue: Error, Sendable, Equatable { case unavailable, keyboardCaptureUnavailable, keyboardCaptureFailed }

@MainActor public final class NativeDesktopCommands: ObservableObject {
  // A frontend may choose a display policy for entry. Active owned fullscreen
  // always routes Exit to its controller before consulting this hook.
  public var onEnterFullscreen: (() throws -> Void)? { didSet { fullscreenEntryID = nil } }
  private var fullscreenEntryID: UUID?
  func installFullscreenEntry(id: UUID, action: @escaping () throws -> Void) { onEnterFullscreen = action; fullscreenEntryID = id }
  func removeFullscreenEntry(id: UUID) { if fullscreenEntryID == id { onEnterFullscreen = nil } }
  @Published public private(set) var keyboardCaptured = false
  @Published public private(set) var captureMessage: String?
  @Published public private(set) var controlSelected = false
  @Published public private(set) var altSelected = false
  @Published public private(set) var isMinimizing = false
  @Published public private(set) var windowMessage: String?
  private enum MinimizePhase { case exitingFullscreen, minimizing }
  private var minimizePhase: MinimizePhase?
  private weak var minimizeWindow: NSWindow?
  private var minimizeGeneration: UInt64 = 0
  private var minimizeDeadline: Task<Void, Never>?
  private var minimizeID = UUID()
  var minimizeTimeout: Duration = .seconds(15) // Injectable; no polling or delegate replacement.
  private weak var session: NativeSession?
  private weak var host: (any NativeDesktopCommandHost)?
  private final class WeakHost {
    weak var value: (any NativeDesktopCommandHost)?
    init(_ value: any NativeDesktopCommandHost) { self.value = value }
  }
  private var hosts: [WeakHost] = []
  private(set) weak var fullscreenOwner: NativeFullscreenController?
  private var fullscreenID: UUID?
  private var fullscreenObservation: AnyCancellable?
  func beginFullscreen(_ owner: NativeFullscreenController, id: UUID) {
    fullscreenOwner = owner; fullscreenID = id
    fullscreenObservation = owner.$phase.sink { [weak self] _ in self?.objectWillChange.send() }
  }
  func endFullscreen(id: UUID) {
    guard fullscreenID == id else { return }
    fullscreenOwner = nil; fullscreenID = nil; fullscreenObservation = nil
    objectWillChange.send()
  }
  private var subscriptions = Set<AnyCancellable>()
  private var recovery: Task<Void, Never>?
  private var recoveryID = UUID()
  private var stopped = false
  private var sentControl = false, sentAlt = false
  public init() {}
  func isBound(to session: NativeSession) -> Bool { !stopped && self.session === session }
  deinit { minimizeDeadline?.cancel(); recovery?.cancel() }
  public func bind(_ session: NativeSession) {
    guard !stopped, self.session !== session else { return }
    fullscreenOwner?.stop()
    cancelMinimize(); windowMessage = nil
    host?.releaseKeyboardForCommand()
    if sentControl || sentAlt { try? self.session?.setFocused(false); host?.clearCommandInput() }
    subscriptions.removeAll(); recovery?.cancel(); recovery = nil; self.session = session
    controlSelected = false; altSelected = false; sentControl = false; sentAlt = false
    session.$snapshot.removeDuplicates { $0.generation == $1.generation && $0.state == $1.state }
      .sink { [weak self] value in MainActor.assumeIsolated {
        guard let self else { return }
        if value.state != .connected {
          self.cancelMinimize()
          self.recovery?.cancel(); self.recovery = nil
          self.controlSelected = false; self.altSelected = false; self.sentControl = false; self.sentAlt = false
        }
        self.objectWillChange.send()
      } }.store(in: &subscriptions)
    session.$isClosing.removeDuplicates().sink { [weak self] value in MainActor.assumeIsolated {
      if value { self?.cancelMinimize() }
      self?.scheduleRecovery()
    } }.store(in: &subscriptions)
    session.$isFocused.removeDuplicates().sink { [weak self] value in MainActor.assumeIsolated {
      guard let self else { return }
      if !value { self.sentControl = false; self.sentAlt = false }
      self.scheduleRecovery()
    } }.store(in: &subscriptions)
    session.$isViewOnly.removeDuplicates().sink { [weak self] _ in MainActor.assumeIsolated {
      self?.sentControl = false; self?.sentAlt = false; self?.scheduleRecovery()
    } }.store(in: &subscriptions)
    session.$emulatesMiddleButton.removeDuplicates().sink { [weak self] _ in MainActor.assumeIsolated {
      self?.sentControl = false; self?.sentAlt = false; self?.scheduleRecovery()
    } }.store(in: &subscriptions)
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                 NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                 NSWindow.willEnterFullScreenNotification, NSWindow.didMiniaturizeNotification,
                 NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
      NotificationCenter.default.publisher(for: name).sink { [weak self] notice in MainActor.assumeIsolated {
        guard let self, let window = notice.object as? NSWindow, window === self.host?.commandWindow else { return }
        self.windowChanged(notice.name, window: window)
        self.objectWillChange.send()
      } }.store(in: &subscriptions)
    }
  }
  private func remember(_ host: any NativeDesktopCommandHost) {
    hosts.removeAll { $0.value == nil }
    if !hosts.contains(where:{ $0.value === host }) { hosts.append(WeakHost(host)) }
  }
  func register(_ host: any NativeDesktopCommandHost) {
    guard !stopped else { return }
    remember(host)
    if self.host == nil { attach(host) }
  }
  // Explicit activation, normally after this surface acquires scoped focus.
  func attach(_ host: any NativeDesktopCommandHost) {
    guard !stopped else { return }
    remember(host)
    guard self.host !== host else { return }
    cancelMinimize(); self.host?.releaseKeyboardForCommand()
    self.host = host; scheduleRecovery()
  }
  func detach(_ host: any NativeDesktopCommandHost) {
    hosts.removeAll { $0.value == nil || $0.value === host }
    guard self.host === host else { return }
    cancelMinimize()
    self.host = nil; recovery?.cancel(); recovery = nil; sentControl = false; sentAlt = false
    let remaining = hosts.compactMap(\.value)
    if let next = remaining.first(where:{ $0.commandWindow?.isKeyWindow == true }) ?? remaining.first {
      self.host = next
    }
    if keyboardCaptured { keyboardCaptured = false }
    if captureMessage != nil { captureMessage = nil }
    scheduleRecovery()
  }
  func isActiveHost(_ host: any NativeDesktopCommandHost) -> Bool { self.host === host }
  private var connected: Bool { !stopped && session?.isClosing == false && session?.snapshot.state == .connected }
  public var isFullscreen: Bool {
    if let owner = fullscreenOwner, owner.phase != .windowed { return true }
    return host?.commandWindow?.styleMask.contains(.fullScreen) == true
  }
  public func canPerform(_ command: NativeDesktopCommand) -> Bool {
    guard !stopped, session?.isClosing == false, let host, let window = host.commandWindow, window.attachedSheet == nil else { return false }
    if let owner = fullscreenOwner, owner.phase != .windowed {
      switch command {
      case .fullscreen: return owner.phase == .entering || owner.phase == .active
      case .releaseKeyboard: return keyboardCaptured
      case .minimize: return owner.canMinimize
      case .fitWindow: return false
      default: if owner.phase != .active { return false }
      }
    }
    if isMinimizing {
      if case .releaseKeyboard = command { return keyboardCaptured }
      return false
    }
    switch command {
    case .pan(let direction): return connected && host.canPan(direction)
    case .releaseKeyboard: return keyboardCaptured
    case .fullscreen: return window.styleMask.contains(.resizable) && (isFullscreen || onEnterFullscreen == nil || connected)
    case .minimize: return window.styleMask.contains(.miniaturizable) && !window.isMiniaturized
    case .fitWindow: return connected && !isFullscreen && host.commandDesktopSize.width > 0 && host.commandDesktopSize.height > 0
    default: return connected && session?.isViewOnly == false
    }
  }
  public func perform(_ command: NativeDesktopCommand) throws {
    guard canPerform(command), let host, let window = host.commandWindow else { throw NativeDesktopCommandIssue.unavailable }
    switch command {
    case .pan(let direction):
      guard host.panDesktop(direction) else { throw NativeDesktopCommandIssue.unavailable }
    case .releaseKeyboard: host.releaseKeyboardForCommand()
    case .captureKeyboard:
      guard let session, host.focusForCommand(), self.session === session, self.host === host,
            connected, !session.isViewOnly, session.isFocused else { throw NativeDesktopCommandIssue.unavailable }
      try host.captureKeyboardForCommand()
    case .fullscreen:
      if let owner = fullscreenOwner, owner.phase != .windowed { owner.exit() }
      else if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
      else if let onEnterFullscreen { try onEnterFullscreen() }
      else { window.toggleFullScreen(nil) }
    case .minimize:
      if let owner = fullscreenOwner, owner.phase != .windowed { try owner.minimize() }
      else { try minimize(window, host: host) }
    case .fitWindow:
      guard let screen = window.screen ?? NSScreen.main,
            let frame = Self.fitFrame(window: window.frame, viewport: host.commandViewport,
              desktop: host.commandDesktopSize, minimum: window.minSize, screen: screen.visibleFrame) else { throw NativeDesktopCommandIssue.unavailable }
      window.setFrame(frame, display: true)
    default:
      guard let session, host.focusForCommand(), self.session === session, self.host === host,
            connected, !session.isViewOnly, session.isFocused else { throw NativeDesktopCommandIssue.unavailable }
      let previousControl = controlSelected, previousAlt = altSelected
      do {
        try session.releaseInput(); host.clearCommandInput()
        sentControl = false; sentAlt = false
        switch command {
        case .control: controlSelected.toggle(); try restoreModifiers()
        case .alt: altSelected.toggle(); try restoreModifiers()
        case .controlAltDelete:
          // Menu chords start with a clean wire/local input state. Keep selected
          // menu modifiers after the chord, with IDs outside physical/IME ranges.
          try key(0xffe3, 0x1d, true); try key(0xffe9, 0x38, true)
          try key(0xffff, 0xd3, true); try key(0xffff, 0xd3, false)
          if !altSelected { try key(0xffe9, 0x38, false) }
          if !controlSelected { try key(0xffe3, 0x1d, false) }
          sentControl = controlSelected; sentAlt = altSelected
        default: break
        }
      } catch {
        controlSelected = previousControl; altSelected = previousAlt
        try? session.setFocused(false); host.clearCommandInput()
        sentControl = false; sentAlt = false
        throw error
      }
    }
  }
  private func key(_ symbol: UInt32, _ code: UInt32, _ down: Bool) throws {
    guard let session else { throw NativeDesktopCommandIssue.unavailable }
    try session.sendKey(id: 0x200000 + symbol, keysym: symbol, keycode: code, down: down)
  }
  private func minimize(_ window: NSWindow, host: any NativeDesktopCommandHost) throws {
    let ticket = UUID(); minimizeID = ticket
    minimizeWindow = window; minimizeGeneration = session?.generation ?? 0
    minimizePhase = isFullscreen ? .exitingFullscreen : .minimizing
    isMinimizing = true; windowMessage = nil
    // Release capture and remote held input before AppKit starts moving Spaces.
    // The view's focus/capture gates remain closed until this operation settles.
    host.releaseKeyboardForCommand()
    do { try session?.setFocused(false) }
    catch { cancelMinimize(); throw error }
    host.clearCommandInput(); sentControl = false; sentAlt = false
    let timeout = minimizeTimeout
    minimizeDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard let self, !Task.isCancelled, self.minimizeID == ticket, self.isMinimizing else { return }
      self.cancelMinimize()
      self.windowMessage = String(localized:"desktop.the.window.could.not.be.minimized.try.minimize.again", defaultValue:"The window could not be minimized. Try Minimize again.")
      self.host?.refreshCommandFocus()
    }
    if minimizePhase == .exitingFullscreen { window.toggleFullScreen(nil) }
    else { window.miniaturize(nil) }
  }
  private func windowChanged(_ name: Notification.Name, window: NSWindow) {
    guard isMinimizing, minimizeWindow === window else { return }
    if name == NSWindow.willCloseNotification || name == NSWindow.willEnterFullScreenNotification {
      cancelMinimize(); return
    }
    if name == NSWindow.didMiniaturizeNotification {
      cancelMinimize(); host?.refreshCommandFocus(); return
    }
    guard name == NSWindow.didExitFullScreenNotification, minimizePhase == .exitingFullscreen else { return }
    guard !stopped, session?.isClosing == false, session?.generation == minimizeGeneration,
          host?.commandWindow === window, window.attachedSheet == nil,
          !window.styleMask.contains(.fullScreen), window.styleMask.contains(.miniaturizable) else {
      cancelMinimize(); host?.refreshCommandFocus(); return
    }
    minimizePhase = .minimizing
    window.miniaturize(nil)
  }
  private func cancelMinimize() {
    minimizeDeadline?.cancel(); minimizeDeadline = nil; minimizeID = UUID()
    minimizeWindow = nil; minimizePhase = nil; if isMinimizing { isMinimizing = false }
  }
  private func restoreModifiers() throws {
    guard connected, !isMinimizing, session?.isFocused == true, session?.isViewOnly == false, host != nil else { return }
    if sentControl != controlSelected { try key(0xffe3, 0x1d, controlSelected); sentControl = controlSelected }
    if sentAlt != altSelected { try key(0xffe9, 0x38, altSelected); sentAlt = altSelected }
  }
  func inputReleasedForShortcut(from host: any NativeDesktopCommandHost) { guard self.host === host else { return }; sentControl = false; sentAlt = false }
  func panAvailabilityChanged() { scheduleRecovery() }
  func captureChanged(_ active: Bool, message: String? = nil, from host: any NativeDesktopCommandHost) {
    guard self.host === host else { return }
    if keyboardCaptured != active { keyboardCaptured = active }
    if captureMessage != message { captureMessage = message }
  }
  func physicalModifierReleased(_ symbol: UInt32, from host: any NativeDesktopCommandHost) {
    guard self.host === host else { return }
    if symbol == 0xffe3 { sentControl = false }
    if symbol == 0xffe9 { sentAlt = false }
    do { try restoreModifiers() } catch { try? session?.setFocused(false) }
  }
  private func scheduleRecovery() {
    guard recovery == nil, !stopped else { return }
    let ticket = UUID(); recoveryID = ticket
    recovery = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let self, !self.stopped, self.recoveryID == ticket else { return }
      // Published callbacks run before the property changes. Reassert selected
      // menu modifiers only after the complete focus/policy update is visible.
      do { try self.restoreModifiers() }
      catch { try? self.session?.setFocused(false); self.host?.clearCommandInput() }
      if self.recoveryID == ticket { self.recovery = nil }
      self.objectWillChange.send()
    }
  }
  public func stop() {
    fullscreenOwner?.stop()
    fullscreenOwner = nil; fullscreenID = nil; fullscreenObservation = nil
    onEnterFullscreen = nil
    cancelMinimize(); windowMessage = nil
    host?.releaseKeyboardForCommand(); keyboardCaptured = false; captureMessage = nil
    stopped = true; hosts.removeAll(); recovery?.cancel(); recovery = nil; subscriptions.removeAll()
    if sentControl || sentAlt { try? session?.setFocused(false); host?.clearCommandInput() }
    controlSelected = false; altSelected = false; sentControl = false; sentAlt = false; host = nil; session = nil
  }
  static func fitFrame(window: CGRect, viewport: CGSize, desktop: CGSize, minimum: CGSize, screen: CGRect) -> CGRect? {
    guard [window.minX,window.minY,window.width,window.height,viewport.width,viewport.height,
           desktop.width,desktop.height,minimum.width,minimum.height,screen.minX,screen.minY,screen.width,screen.height].allSatisfy({ $0.isFinite }),
          viewport.width > 0, viewport.height > 0, desktop.width > 0, desktop.height > 0, screen.width > 0, screen.height > 0 else { return nil }
    let width = min(screen.width, max(minimum.width, desktop.width + max(0,window.width-viewport.width)))
    let height = min(screen.height, max(minimum.height, desktop.height + max(0,window.height-viewport.height)))
    return CGRect(x: min(max(window.minX,screen.minX),screen.maxX-width),
      y: min(max(window.maxY-height,screen.minY),screen.maxY-height), width: width, height: height)
  }
}
