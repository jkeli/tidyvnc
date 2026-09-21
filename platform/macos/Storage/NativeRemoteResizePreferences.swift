// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreFoundation
import Foundation

public enum NativeResizeOption: String, CaseIterable, Sendable { case enabled, initialSize }
public struct NativeRemoteResizePreferences: Codable, Equatable, Sendable {
  public var enabled: Bool?
  // nil inherits; empty explicitly retains the server's initial size.
  public var initialSize: String?
  public init(enabled: Bool? = nil, initialSize: String? = nil) { self.enabled = enabled; self.initialSize = initialSize }
  public func resolved(base: NativeRemoteResizePolicy = .builtIn) throws -> NativeRemoteResizePolicy {
    do { return try NativeRemoteResizePolicy(enabled:enabled ?? base.enabled,initialSize:initialSize ?? base.initialSize) }
    catch { throw NativePreferencesError.invalidValue }
  }
  public var isValid: Bool { (try? resolved()) != nil }
  public func canonicalized() throws -> Self {
    let value = try resolved()
    return .init(enabled:enabled,initialSize:initialSize == nil ? nil : value.initialSize)
  }
  static func validateObject(_ value: Any) throws {
    guard let fields = value as? [String:Any] else { throw NativePreferencesError.corrupt }
    guard Set(fields.keys).isSubset(of:Set(NativeResizeOption.allCases.map(\.rawValue))) else { throw NativePreferencesError.unsupportedFields }
    for (key,value) in fields {
      if key == "enabled" {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw NativePreferencesError.corrupt }
      } else { guard value is String else { throw NativePreferencesError.corrupt } }
    }
  }
  func applying(to configuration: NativeSessionConfiguration,source: NativeOptionSource) throws -> NativeSessionConfiguration {
    var value = configuration; value.resizePolicy = try resolved(base:configuration.resizePolicy)
    if enabled != nil { value.resizeSources[.enabled] = source }
    if initialSize != nil { value.resizeSources[.initialSize] = source }
    return value
  }
}
