// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

public struct NativeShortcutModifiers: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let control = Self(rawValue: 1), shift = Self(rawValue: 2)
  public static let option = Self(rawValue: 4), command = Self(rawValue: 8)
  public static let builtIn: Self = [.control, .option]
}
public enum NativeShortcutAction: UInt32, Sendable { case normal, unarm, shortcut, ignore }

// One classifier per input surface. It owns no session or view. Hosts must release
// remote held keys and reset routing when changing modifiers or losing focus.
@MainActor public final class NativeShortcutState {
  private let handle: NativeHandle
  public init(modifiers: NativeShortcutModifiers = .builtIn) throws {
    var raw: UInt64 = 0
    try checked { tidyvnc_shortcut_create(modifiers.rawValue, &raw, $0) }
    handle = NativeHandle(adopting: raw)
  }
  public func setModifiers(_ value: NativeShortcutModifiers) throws {
    try checked { tidyvnc_shortcut_modifiers(handle.raw, value.rawValue, $0) }
  }
  public func reset() throws { try checked { tidyvnc_shortcut_reset(handle.raw, $0) } }
  public func key(id: Int32, keysym: UInt32, down: Bool) throws -> NativeShortcutAction {
    var action: UInt32 = 0
    try checked { tidyvnc_shortcut_key(handle.raw, id, keysym, down ? 1 : 0, &action, $0) }
    guard let value = NativeShortcutAction(rawValue: action) else { throw NativeError(.internalFailure, "Invalid shortcut action") }
    return value
  }
}

// The retained viewer's Space bypass and command selection, ready for native
// desktop dispatch. A decision describes effects; it never changes wire state.
public struct NativeShortcutDecision: Equatable, Sendable {
  public enum Route: Equatable, Sendable { case remote, suppress, releaseKeyboard, captureKeyboard, contextMenu, toggleFullscreen }
  public let route: Route
  public let releaseRemoteKeys: Bool
  init(_ route: Route, release: Bool = false) { self.route = route; releaseRemoteKeys = release }
}
@MainActor public final class NativeShortcutRouter {
  private let state: NativeShortcutState
  private var pressed = Set<Int32>()
  private var bypass = false, active = false
  public init(modifiers: NativeShortcutModifiers = .builtIn) throws { state = try NativeShortcutState(modifiers: modifiers) }
  public func setModifiers(_ modifiers: NativeShortcutModifiers) throws {
    try state.setModifiers(modifiers); pressed.removeAll(); bypass = false; active = false
  }
  public func reset() throws { try state.reset(); pressed.removeAll(); bypass = false; active = false }
  // Candidates are ordered layout translations, including unmodified variants.
  // The host resolves them from the physical key, not only its modified text.
  public var routesKeyEquivalents: Bool { active || bypass }
  public func press(id: Int32, keysym: UInt32, candidates: @autoclosure () -> [UInt32]) throws -> NativeShortcutDecision {
    // Bound bypass bookkeeping too: the shared classifier is idle in that mode.
    guard pressed.contains(id) || pressed.count < 1024 else { throw NativeError(.resourceLimit, "Shortcut key capacity exceeded") }
    let action = bypass ? NativeShortcutAction.normal : try state.key(id: id, keysym: keysym, down: true)
    pressed.insert(id)
    switch action {
    case .ignore: return .init(.suppress)
    case .shortcut:
      let symbol = candidates().first { [0x20,0x47,0x67,0x4d,0x6d,0xff0d,0xff8d].contains($0) }
      if symbol == 0x20 {
        if !active { try state.reset(); bypass = true }
        return .init(.suppress)
      }
      active = true
      switch symbol {
      case 0x47,0x67: return .init(.captureKeyboard, release: true)
      case 0x4d,0x6d: return .init(.contextMenu, release: true)
      case 0xff0d,0xff8d: return .init(.toggleFullscreen, release: true)
      default: return .init(.suppress, release: true)
      }
    default: return .init(.remote)
    }
  }
  public func release(id: Int32) throws -> NativeShortcutDecision {
    let action = bypass ? NativeShortcutAction.normal : try state.key(id: id, keysym: 0, down: false)
    pressed.remove(id)
    if pressed.isEmpty { active = false }
    switch action {
    case .ignore, .shortcut: return .init(.suppress)
    case .unarm: return .init(.releaseKeyboard, release: true)
    default:
      if pressed.isEmpty { bypass = false }
      return .init(.remote)
    }
  }
}
