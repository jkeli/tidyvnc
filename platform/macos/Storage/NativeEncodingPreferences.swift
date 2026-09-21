// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// Closed typed persistence fields. Defaults, canonical tokens, ranges, aliases
// and decoder availability are always resolved by the shared core schema.
public struct NativeEncodingPreferences: Codable, Equatable, Sendable {
  public var autoSelect: Bool?, fullColor: Bool?, lowColorLevel: Int?
  public var preferredEncoding: String?
  public var customCompressLevel: Bool?, compressLevel: Int?, noJPEG: Bool?, qualityLevel: Int?
  public init() {}
  enum CodingKeys: String, CodingKey, CaseIterable {
    case autoSelect, fullColor, lowColorLevel, preferredEncoding, customCompressLevel, compressLevel, noJPEG, qualityLevel
  }
  static let fieldNames = Set(CodingKeys.allCases.map(\.rawValue))
  public func value(for option: NativeEncodingOption) -> String? {
    func boolean(_ value: Bool?) -> String? { value.map { $0 ? "on" : "off" } }
    switch option {
    case .autoSelect: return boolean(autoSelect)
    case .fullColor: return boolean(fullColor)
    case .lowColorLevel: return lowColorLevel.map(String.init)
    case .preferred: return preferredEncoding
    case .customCompression: return boolean(customCompressLevel)
    case .compression: return compressLevel.map(String.init)
    case .noJPEG: return boolean(noJPEG)
    case .quality: return qualityLevel.map(String.init)
    }
  }
  public func resolved(base: NativeEncodingOptions? = nil, source: NativeOptionSource = .appDefaults) throws -> NativeEncodingOptions {
    let patch = try NativeEncodingOptions.schema().compactMap { field in
      value(for: field.id).map { NativeEncodingAssignment(field.name, $0) }
    }
    return try (base ?? NativeEncodingOptions()).applying(patch, source: source)
  }
  public mutating func set(_ option: NativeEncodingOption, value: String) throws {
    guard let field = try NativeEncodingOptions.schema().first(where: { $0.id == option }) else { throw NativePreferencesError.unsupportedFields }
    let validated = try NativeEncodingOptions(patch: [NativeEncodingAssignment(field.name, value)])
    let canonical = try validated.value(for: option).value
    switch option {
    case .autoSelect: autoSelect = canonical == "on"
    case .fullColor: fullColor = canonical == "on"
    case .lowColorLevel: lowColorLevel = Int(canonical)
    case .preferred: preferredEncoding = canonical
    case .customCompression: customCompressLevel = canonical == "on"
    case .compression: compressLevel = Int(canonical)
    case .noJPEG: noJPEG = canonical == "on"
    case .quality: qualityLevel = Int(canonical)
    }
  }
  public mutating func clear(_ option: NativeEncodingOption) {
    switch option {
    case .autoSelect: autoSelect = nil
    case .fullColor: fullColor = nil
    case .lowColorLevel: lowColorLevel = nil
    case .preferred: preferredEncoding = nil
    case .customCompression: customCompressLevel = nil
    case .compression: compressLevel = nil
    case .noJPEG: noJPEG = nil
    case .quality: qualityLevel = nil
    }
  }
}
