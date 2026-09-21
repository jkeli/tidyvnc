// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import ColorSync
import Combine

public struct NativeDisplayID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}
// Global logical points, origin at the primary display's top-left, positive Y
// downward. Displays above or left of it have negative coordinates. Never mix
// these rectangles with CGDisplayBounds (device pixels on some configurations).
public struct NativeDisplayRectangle: Equatable, Sendable {
  public let x: Double, y: Double, width: Double, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
  fileprivate var valid: Bool {
    [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite) && width >= 0 && height >= 0
  }
}
public struct NativeDisplay: Equatable, Sendable, Identifiable {
  public let id: NativeDisplayID
  public let name: String
  public let bounds: NativeDisplayRectangle, workArea: NativeDisplayRectangle
  public let backingScale: Double
  public let isPrimary: Bool
  public init(id: NativeDisplayID, name: String, bounds: NativeDisplayRectangle,
              workArea: NativeDisplayRectangle, backingScale: Double, isPrimary: Bool) {
    self.id = id; self.name = name; self.bounds = bounds; self.workArea = workArea
    self.backingScale = backingScale; self.isPrimary = isPrimary
  }
}
public enum NativeDisplayError: Error, Equatable, Sendable {
  case unavailable, invalidSnapshot, tooManyDisplays
}
public struct NativeDisplaySelection: Equatable, Sendable {
  public let displays: [NativeDisplay]
  public let missing: [NativeDisplayID]
  public let usedFallback: Bool
}
public struct NativeDisplaySnapshot: Equatable, Sendable {
  public let generation: UInt64
  public let displays: [NativeDisplay]
  public let error: NativeDisplayError?
  public var primary: NativeDisplay? { displays.first { $0.isPrimary } }
  public func display(_ id: NativeDisplayID) -> NativeDisplay? { displays.first { $0.id == id } }
  // Preserve the caller's saved IDs; report missing ones rather than replacing
  // preferences with transient array indices. Only fall back if none survive.
  public func resolve(_ requested: [NativeDisplayID], current: NativeDisplayID? = nil) -> NativeDisplaySelection {
    var seen = Set<NativeDisplayID>(), available: [NativeDisplay] = [], missing: [NativeDisplayID] = []
    for id in requested where seen.insert(id).inserted {
      if let value = display(id) { available.append(value) } else { missing.append(id) }
    }
    if !available.isEmpty { return NativeDisplaySelection(displays: available, missing: missing, usedFallback: false) }
    let fallback = current.flatMap { display($0) } ?? primary
    return NativeDisplaySelection(displays: fallback.map { [$0] } ?? [], missing: missing, usedFallback: fallback != nil)
  }
}
@MainActor public protocol NativeDisplaySource: AnyObject {
  func read() throws -> [NativeDisplay]
}
@MainActor public final class AppKitDisplaySource: NativeDisplaySource {
  public init() {}
  static func identity(_ screen: NSScreen) throws -> NativeDisplayID {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          number.uint32Value != 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
          let text = CFUUIDCreateString(nil, uuid) else { throw NativeDisplayError.unavailable }
    return NativeDisplayID("macos-display:" + (text as String).lowercased())
  }
  // One tested orientation boundary for both full and visible rectangles.
  static func rectangle(_ value: CGRect, primary: CGRect) -> NativeDisplayRectangle {
    NativeDisplayRectangle(x: value.minX - primary.minX, y: primary.maxY - value.maxY,
      width: value.width, height: value.height)
  }
  public func read() throws -> [NativeDisplay] {
    _ = NSApplication.shared
    let screens = NSScreen.screens // Fresh on every notification; never cache NSScreen objects.
    guard let primary = screens.first else { return [] }
    guard screens.count <= 64 else { throw NativeDisplayError.tooManyDisplays }
    return try screens.enumerated().map { index, screen in
      return NativeDisplay(id: try Self.identity(screen),
        name: screen.localizedName, bounds: Self.rectangle(screen.frame, primary: primary.frame),
        workArea: Self.rectangle(screen.visibleFrame, primary: primary.frame),
        backingScale: Double(screen.backingScaleFactor), isPrimary: index == 0)
    }
  }
}

@MainActor public final class NativeDisplayService: NSObject, ObservableObject {
  @Published public private(set) var snapshot = NativeDisplaySnapshot(generation: 0, displays: [], error: nil)
  private let source: any NativeDisplaySource
  private let notifications: NotificationCenter
  private let workspaceNotifications: NotificationCenter
  private var stopped = false, refreshing = false
  public init(source: any NativeDisplaySource = AppKitDisplaySource(), notifications: NotificationCenter = .default,
              workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
    self.source = source; self.notifications = notifications; self.workspaceNotifications = workspaceNotifications
    super.init()
    notifications.addObserver(self, selector: #selector(parametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    workspaceNotifications.addObserver(self, selector: #selector(parametersChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    refresh()
  }
  @objc private func parametersChanged(_ notification: Notification) { refresh() }
  public func refresh() {
    guard !stopped, !refreshing else { return }
    refreshing = true; defer { refreshing = false }
    let displays: [NativeDisplay], problem: NativeDisplayError?
    do { displays = try Self.validate(source.read()); problem = nil }
    catch let failure as NativeDisplayError { displays = []; problem = failure }
    catch { displays = []; problem = .unavailable }
    // Publish an empty failed snapshot instead of offering stale monitor geometry.
    guard snapshot.generation == 0 || snapshot.displays != displays || snapshot.error != problem else { return }
    snapshot = NativeDisplaySnapshot(generation: snapshot.generation + 1, displays: displays, error: problem)
  }
  private static func validate(_ displays: [NativeDisplay]) throws -> [NativeDisplay] {
    guard displays.count <= 64 else { throw NativeDisplayError.tooManyDisplays }
    var ids = Set<NativeDisplayID>()
    for display in displays {
      let b = display.bounds, w = display.workArea
      guard !display.id.rawValue.isEmpty, display.id.rawValue.utf8.count <= 256,
            ids.insert(display.id).inserted, b.valid, w.valid, b.width > 0, b.height > 0,
            display.backingScale.isFinite, display.backingScale > 0,
            w.x >= b.x, w.y >= b.y, w.x + w.width <= b.x + b.width, w.y + w.height <= b.y + b.height
      else { throw NativeDisplayError.invalidSnapshot }
    }
    guard displays.isEmpty || displays.filter(\.isPrimary).count == 1 else { throw NativeDisplayError.invalidSnapshot }
    // Order changes alone do not create a new topology generation.
    return displays.sorted { $0.id.rawValue < $1.id.rawValue }
  }
  public func stop() {
    guard !stopped else { return }; stopped = true
    notifications.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    workspaceNotifications.removeObserver(self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
  }
  // Selector notification registrations do not retain their target; NSObject
  // destruction unregisters it. No timer, worker or async cleanup is owned here.
}
