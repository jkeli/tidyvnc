// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreFoundation
import Foundation

public enum NativeInputOption: String, CaseIterable, Sendable {
  case viewOnly, emulateMiddle, shortcutModifiers, fullscreenSystemKeys, cursorFallback
}
// Absence inherits a field; an explicit empty modifier mask disables shortcuts.
public struct NativeInputPreferences: Codable, Equatable, Sendable {
  public var viewOnly: Bool?, emulateMiddle: Bool?, fullscreenSystemKeys: Bool?
  public var shortcutModifiers: UInt32?
  public var cursorFallback: NativeCursorFallback?
  public init() {}
  public func contains(_ option: NativeInputOption) -> Bool {
    switch option {
    case .viewOnly: viewOnly != nil
    case .emulateMiddle: emulateMiddle != nil
    case .shortcutModifiers: shortcutModifiers != nil
    case .fullscreenSystemKeys: fullscreenSystemKeys != nil
    case .cursorFallback: cursorFallback != nil
    }
  }
  public func resolved(base: NativeInputSettings = .init()) throws -> NativeInputSettings {
    let modifiers = shortcutModifiers.map { NativeShortcutModifiers(rawValue: $0) } ?? base.shortcutModifiers
    guard modifiers.rawValue & ~15 == 0 else { throw NativePreferencesError.invalidValue }
    return .init(viewOnly: viewOnly ?? base.viewOnly, emulateMiddle: emulateMiddle ?? base.emulateMiddle,
      shortcutModifiers: modifiers, fullscreenSystemKeys: fullscreenSystemKeys ?? base.fullscreenSystemKeys,
      cursorFallback: cursorFallback ?? base.cursorFallback)
  }
  // Inspect before Codable so unknown fields and explicit nulls cannot vanish
  // on a later save. Booleans and numbers must retain their distinct JSON types.
  static func validateObject(_ value: Any) throws {
    guard let fields = value as? [String: Any] else { throw NativePreferencesError.corrupt }
    guard Set(fields.keys).isSubset(of: Set(NativeInputOption.allCases.map(\.rawValue))) else { throw NativePreferencesError.unsupportedFields }
    for (key,value) in fields {
      switch key {
      case "viewOnly", "emulateMiddle", "fullscreenSystemKeys":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw NativePreferencesError.corrupt }
      case "shortcutModifiers":
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw NativePreferencesError.corrupt }
        guard number.doubleValue <= 15 else { throw NativePreferencesError.invalidValue }
      case "cursorFallback":
        guard let token = value as? String else { throw NativePreferencesError.corrupt }
        guard NativeCursorFallback(rawValue: token) != nil else { throw NativePreferencesError.invalidValue }
      default: throw NativePreferencesError.unsupportedFields
      }
    }
  }
  func applying(to configuration: NativeSessionConfiguration, source: NativeOptionSource) throws -> NativeSessionConfiguration {
    var result = configuration
    result.input = try resolved(base: configuration.input)
    for option in NativeInputOption.allCases where contains(option) { result.inputSources[option] = source }
    return result
  }
}
