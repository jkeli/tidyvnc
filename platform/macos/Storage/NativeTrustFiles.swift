// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// nil inherits the previous layer; "" explicitly selects no additional file.
// Paths are exact local names, never expanded, imported or read during editing.
// GnuTLS opens them on the protocol worker for each X509 connection attempt.
public struct NativeTrustFiles: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public var caFile: String?, crlFile: String?
  public init(caFile: String? = nil, crlFile: String? = nil) { self.caFile = caFile; self.crlFile = crlFile }
  public static func isValidPath(_ value: String) -> Bool {
    value.isEmpty || (value.hasPrefix("/") && !value.utf8.contains(0) && value.utf8.prefix(4097).count <= 4096)
  }
  public func validate() throws {
    guard [caFile,crlFile].compactMap({ $0 }).allSatisfy(Self.isValidPath) else { throw NativePreferencesError.invalidValue }
  }
  public var isValid: Bool { (try? validate()) != nil }
  public func applying(to configuration: NativeSessionConfiguration) throws -> NativeSessionConfiguration {
    try validate(); var result = configuration
    if let caFile { result.caFile = caFile }
    if let crlFile { result.crlFile = crlFile }
    return result
  }
  static func validateObject(_ value: Any) throws {
    guard let fields = value as? [String: Any] else { throw NativePreferencesError.corrupt }
    guard Set(fields.keys).isSubset(of: ["caFile","crlFile"]) else { throw NativePreferencesError.unsupportedFields }
    guard fields.values.allSatisfy({ $0 is String }) else { throw NativePreferencesError.corrupt }
  }
  public var description: String { "NativeTrustFiles(redacted)" }
  public var debugDescription: String { description }
}
