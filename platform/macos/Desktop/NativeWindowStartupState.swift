// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine

// Initial placement belongs to one logical connection's ordinary window. It is
// never replayed by reconnect, view reconstruction, display changes or fullscreen.
@MainActor public final class NativeWindowStartupState {
  public private(set) var resolved = false
  private var configured = false, stopped = false
  private var policy = NativeWindowStartupPolicy.builtIn
  private weak var window: NSWindow?
  private var windowID: ObjectIdentifier?
  private var observations = Set<AnyCancellable>()
  var onResolved: (() -> Void)?
  public init() {}
  public func configure(_ policy: NativeWindowStartupPolicy) {
    guard !stopped, !configured else { return }
    configured = true; self.policy = policy
    if !policy.hasPlacement { finish() } else { apply() }
  }
  public func attach(_ window: NSWindow) {
    guard !stopped, !resolved else { return }
    let id = ObjectIdentifier(window)
    guard windowID == nil || self.window === window else { return }
    if windowID == nil {
      windowID = id; self.window = window
      for name in [NSWindow.willCloseNotification, NSWindow.didEndSheetNotification,
                   NSWindow.didDeminiaturizeNotification, NSApplication.didChangeScreenParametersNotification] {
        NotificationCenter.default.publisher(for:name).sink { [weak self] notice in MainActor.assumeIsolated {
          guard let self else { return }
          if notice.name == NSApplication.didChangeScreenParametersNotification { self.apply(); return }
          guard (notice.object as? NSWindow) === self.window else { return }
          if notice.name == NSWindow.willCloseNotification { self.stop() } else { self.apply() }
        } }.store(in:&observations)
      }
    }
    apply()
  }
  private func finish() { resolved = true; observations.removeAll(); onResolved?() }
  private func apply() {
    guard !stopped, configured, !resolved, let window else { return }
    // A user-owned fullscreen transition supersedes initial window placement.
    if window.styleMask.contains(.fullScreen) { finish(); return }
    guard window.attachedSheet == nil, !window.isMiniaturized else { return }
    let screens = NSScreen.screens
    guard let primary = screens.first else { return }
    let top = policy.geometry.flatMap { value -> NSPoint? in
      guard let x = value.x, let y = value.y else { return nil }
      return NSPoint(x:primary.frame.minX+CGFloat(x),y:primary.frame.maxY-CGFloat(y))
    }
    let screen: NSScreen
    if let top {
      // Top/left coordinates on a boundary refer to the screen below/right.
      screen = screens.first { $0.frame.contains(NSPoint(x:top.x+0.5,y:top.y-0.5)) } ?? primary
    } else { screen = window.screen ?? primary }
    let content = window.contentRect(forFrameRect:window.frame)
    let decoration = window.frameRect(forContentRect:NSRect(origin:.zero,size:.zero))
    let desired = Self.contentRect(policy:policy,current:content,workArea:screen.visibleFrame,
      decoration:decoration,minimum:window.contentMinSize,maximum:window.contentMaxSize,topLeft:top)
    window.setFrame(window.frameRect(forContentRect:desired),display:window.isVisible)
    finish()
  }
  // Pure placement arithmetic; NSScreen selection and NSWindow mutations stay
  // above. Screen and content rectangles use AppKit logical points, never pixels.
  static func contentRect(policy: NativeWindowStartupPolicy, current: NSRect, workArea: NSRect,
                          decoration: NSRect, minimum: NSSize, maximum: NSSize, topLeft: NSPoint?) -> NSRect {
    let available = NSSize(width:max(1,workArea.width-decoration.width),height:max(1,workArea.height-decoration.height))
    var size = current.size
    if let width = policy.geometry?.width, let height = policy.geometry?.height { size = NSSize(width:CGFloat(width),height:CGFloat(height)) }
    if policy.maximize { size = available }
    size.width = min(max(size.width,minimum.width),max(min(available.width,maximum.width),minimum.width))
    size.height = min(max(size.height,minimum.height),max(min(available.height,maximum.height),minimum.height))
    // A specified position survives Maximize; otherwise maximization fills the
    // selected work area. Ordinary sizing preserves the content's top-left.
    let top = topLeft ?? (policy.maximize
      ? NSPoint(x:workArea.minX-decoration.minX,y:workArea.maxY-decoration.maxY)
      : NSPoint(x:current.minX,y:current.maxY))
    return NSRect(x:top.x,y:top.y-size.height,width:size.width,height:size.height)
  }
  public func stop() { stopped = true; observations.removeAll(); window = nil; onResolved = nil }
}
