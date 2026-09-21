// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_security_choice: ABIValue {}
extension tidyvnc_security_selection: ABIValue {}
public struct NativeSecurityChoice: Sendable, Identifiable {
  public enum Protection: UInt32, CaseIterable, Sendable { case unencrypted = 0, anonymousTLS, x509TLS, rsaAES, rsaAuthentication, legacyAuthentication }
  public enum Credentials: UInt32, Sendable { case none = 0, password, usernamePassword, serverSelected }
  public let id: UInt32, name: String, available: Bool
  public let protection: Protection, credentials: Credentials, aesBits: UInt32
}
func securityText<T>(_ value: T) -> String {
  withUnsafeBytes(of: value) { String(decoding: $0.prefix(while: { $0 != 0 }),as: UTF8.self) }
}
public struct NativeSecuritySelection: Equatable, Sendable {
  public let types: [UInt32]
  public let canonical: String
  // nil is the compiled default; "" explicitly denies all methods.
  public init(_ text: String? = nil) throws {
    guard (text?.utf8.prefix(1025).count ?? 0) <= 1024 else { throw NativeError(.resourceLimit,"Security selection is too long") }
    var result = abi(tidyvnc_security_selection.self)
    _ = try withText(text ?? "") { input in
      try checked { tidyvnc_security_resolve(input,text == nil ? 1 : 0,&result,$0) }
    }
    guard result.count <= 32 else { throw NativeError(.internalFailure,"Invalid security selection count") }
    types = withUnsafeBytes(of: result.types) { Array($0.bindMemory(to: UInt32.self).prefix(Int(result.count))) }
    canonical = securityText(result.canonical)
  }
  public static func choices() throws -> [NativeSecurityChoice] {
    var result: [NativeSecurityChoice] = []
    for index in 0..<32 {
      var value = abi(tidyvnc_security_choice.self)
      if try checked(allowing: [.ok,.noChange], { tidyvnc_security_choice_at(UInt32(index),&value,$0) }) == .noChange { return result }
      guard let protection = NativeSecurityChoice.Protection(rawValue:value.protection),
            let credentials = NativeSecurityChoice.Credentials(rawValue:value.credentials) else { throw NativeError(.unsupported,"Unknown security metadata") }
      result.append(.init(id:value.type,name:securityText(value.name),available:value.available != 0,
        protection:protection,credentials:credentials,aesBits:value.aes_bits))
    }
    throw NativeError(.resourceLimit,"Security catalog exceeds its limit")
  }
}

// GnuTLS may consult library configuration. Storage actors call this preflight;
// view bodies and per-keystroke validity checks must remain free of library I/O.
public enum NativeTLSPriority {
  public static func validate(_ text: String) throws {
    guard text.utf8.prefix(4097).count <= 4096 else { throw NativeError(.resourceLimit,"TLS priority is too long") }
    _ = try withText(text) { input in try checked { tidyvnc_tls_priority_validate(input,$0) } }
  }
}

extension tidyvnc_security_configuration: ABIValue {}
extension tidyvnc_security_update: ABIValue {}
public struct NativeSessionSecurity: Equatable, Sendable {
  public let revision: UInt64, generation: UInt64, editable: Bool
  public let preferences: NativeSecurityPreferences
  public let trustFiles: NativeTrustFiles
}

extension tidyvnc_sharing: ABIValue {}
public struct NativeConnectionOptions: Equatable, Sendable {
  public let shared: Bool, reconnectOnError: Bool, editable: Bool
  public let revision: UInt64, generation: UInt64
  public let sharedSource: NativeOptionSource, reconnectSource: NativeOptionSource
}
