// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public struct NativeSecurityPreferences: Codable, Equatable, Sendable {
  public var types: String?
  // nil inherits, empty explicitly selects the library default. Preserve syntax.
  public var tlsPriority: String?
  public init(types: String? = nil, tlsPriority: String? = nil) { self.types = types; self.tlsPriority = tlsPriority }
  public var isPriorityTextValid: Bool { tlsPriority.map { !$0.utf8.contains(0) && $0.utf8.prefix(4097).count <= 4096 } ?? true }
  public func validate() throws {
    _ = try selection()
    guard isPriorityTextValid else { throw NativePreferencesError.invalidTLSPriority }
    guard let tlsPriority else { return }
    do { try NativeTLSPriority.validate(tlsPriority) }
    catch let error as NativeError {
      switch error.status {
      case .unsupported: throw NativePreferencesError.unsupportedValue
      case .invalidArgument,.resourceLimit: throw NativePreferencesError.invalidTLSPriority
      default: throw NativePreferencesError.unavailable
      }
    }
  }
  public func selection() throws -> NativeSecuritySelection {
    do { return try NativeSecuritySelection(types) }
    catch let error as NativeError {
      switch error.status {
      case .unsupported: throw NativePreferencesError.unsupportedValue
      case .invalidArgument,.resourceLimit: throw NativePreferencesError.invalidValue
      default: throw NativePreferencesError.unavailable
      }
    }
  }
  public var isValid: Bool { isPriorityTextValid && (try? selection()) != nil }
  public func canonicalized() throws -> Self {
    let selected = try selection()
    return .init(types: types == nil ? nil : selected.canonical, tlsPriority: tlsPriority)
  }
  func applying(to configuration: NativeSessionConfiguration, source: NativeOptionSource) throws -> NativeSessionConfiguration {
    guard isPriorityTextValid else { throw NativePreferencesError.invalidTLSPriority }
    var result = configuration
    if types != nil { result.securityTypes = try selection().types; result.securitySource = source }
    if let tlsPriority { result.tlsPriority = tlsPriority; result.tlsPrioritySource = source }
    return result
  }
  static func validateObject(_ value: Any, priorityAllowed: Bool) throws {
    guard let fields = value as? [String:Any] else { throw NativePreferencesError.corrupt }
    guard Set(fields.keys).isSubset(of: priorityAllowed ? ["types","tlsPriority"] : ["types"]) else { throw NativePreferencesError.unsupportedFields }
    guard fields.values.allSatisfy({ $0 is String }) else { throw NativePreferencesError.corrupt }
  }
}
