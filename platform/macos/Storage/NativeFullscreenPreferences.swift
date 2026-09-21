// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreFoundation
import Foundation

public struct NativeFullscreenPreferences: Codable, Equatable, Sendable {
  public var startsFullscreen: Bool?, mode: String?, selectedDisplays: [String]?
  public init(startsFullscreen: Bool? = nil, mode: String? = nil, selectedDisplays: [String]? = nil) {
    self.startsFullscreen = startsFullscreen; self.mode = mode; self.selectedDisplays = selectedDisplays
  }
  // Validate patches independently: a profile's selected mode can inherit its IDs.
  func validate() throws {
    if let mode, NativeFullscreenMode(rawValue:mode) == nil { throw NativePreferencesError.invalidValue }
    if let selectedDisplays { try NativeFullscreenPolicy.validateIDs(selectedDisplays.map(NativeDisplayID.init)) }
  }
  public var isValid: Bool { (try? validate()) != nil }
  public func resolved(base: NativeFullscreenPolicy = .builtIn) throws -> NativeFullscreenPolicy {
    try validate()
    return try .init(startsFullscreen:startsFullscreen ?? base.startsFullscreen,
      mode:mode.flatMap(NativeFullscreenMode.init(rawValue:)) ?? base.mode,
      selectedDisplays:selectedDisplays?.map(NativeDisplayID.init) ?? base.selectedDisplays)
  }
  public func canonicalized() throws -> Self {
    try validate()
    return .init(startsFullscreen:startsFullscreen,mode:mode,selectedDisplays:selectedDisplays?.sorted())
  }
  static func validateObject(_ value: Any) throws {
    guard let fields = value as? [String:Any] else { throw NativePreferencesError.corrupt }
    guard Set(fields.keys).isSubset(of:Set(NativeFullscreenOption.allCases.map(\.rawValue))) else { throw NativePreferencesError.unsupportedFields }
    for (key,value) in fields {
      switch key {
      case "startsFullscreen":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw NativePreferencesError.corrupt }
      case "mode": guard value is String else { throw NativePreferencesError.corrupt }
      case "selectedDisplays": guard value is [String] else { throw NativePreferencesError.corrupt }
      default: throw NativePreferencesError.unsupportedFields
      }
    }
  }
  func applying(to configuration: NativeSessionConfiguration, source: NativeOptionSource) throws -> NativeSessionConfiguration {
    var result = configuration; result.fullscreenPolicy = try resolved(base:configuration.fullscreenPolicy)
    if startsFullscreen != nil { result.fullscreenSources[.startsFullscreen] = source }
    if mode != nil { result.fullscreenSources[.mode] = source }
    if selectedDisplays != nil { result.fullscreenSources[.selectedDisplays] = source }
    return result
  }
}
