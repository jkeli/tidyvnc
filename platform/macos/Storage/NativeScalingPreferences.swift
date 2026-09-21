// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreFoundation
import Foundation

public enum NativeScalingOption: String, CaseIterable, Sendable { case scaling, devicePixels, filter }
public extension NativeScalingFilter {
  var storageToken: String { switch self { case .nearest: "nearest"; case .bilinear: "bilinear"; case .area: "area" } }
  init?(storageToken: String) {
    switch storageToken { case "nearest": self = .nearest; case "bilinear": self = .bilinear; case "area": self = .area; default: return nil }
  }
}
public struct NativeScalingPreferences: Codable, Equatable, Sendable {
  public var scaling: String?, devicePixels: Bool?, filter: String?
  public init() {}
  public func contains(_ option: NativeScalingOption) -> Bool {
    switch option { case .scaling: scaling != nil; case .devicePixels: devicePixels != nil; case .filter: filter != nil }
  }
  public func resolved(base: NativeScaling = .builtIn) throws -> NativeScaling {
    let quality: NativeScalingFilter
    if let filter {
      guard let value = NativeScalingFilter(storageToken: filter) else { throw NativePreferencesError.invalidValue }
      quality = value
    } else { quality = base.filter }
    do { return try NativeScaling(scaling ?? base.canonical, devicePixels: devicePixels ?? base.devicePixels, filter: quality) }
    catch let error as NativeError {
      if [.invalidArgument,.resourceLimit].contains(error.status) { throw NativePreferencesError.invalidValue }
      throw NativePreferencesError.unavailable
    } catch { throw NativePreferencesError.invalidValue }
  }
  public var isValid: Bool { (try? resolved()) != nil }
  public func canonicalized() throws -> Self {
    let value = try resolved(); var result = self
    if scaling != nil { result.scaling = value.canonical }
    return result
  }
  static func validateObject(_ value: Any) throws {
    guard let fields = value as? [String: Any] else { throw NativePreferencesError.corrupt }
    guard Set(fields.keys).isSubset(of: Set(NativeScalingOption.allCases.map(\.rawValue))) else { throw NativePreferencesError.unsupportedFields }
    for (key,value) in fields {
      switch key {
      case "scaling", "filter": guard value is String else { throw NativePreferencesError.corrupt }
      case "devicePixels":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw NativePreferencesError.corrupt }
      default: throw NativePreferencesError.unsupportedFields
      }
    }
  }
  func applying(to configuration: NativeSessionConfiguration, source: NativeOptionSource) throws -> NativeSessionConfiguration {
    var result = configuration
    result.scaling = try resolved(base: configuration.scaling ?? .builtIn)
    for option in NativeScalingOption.allCases where contains(option) { result.scalingSources[option] = source }
    return result
  }
}
