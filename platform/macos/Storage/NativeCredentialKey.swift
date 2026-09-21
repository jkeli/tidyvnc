// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CryptoKit
import Foundation
import TidyVNC

public enum NativeCredentialKeyIssue: Error, Sendable, Equatable {
  case tooLong, invalidText, invalidAuthentication, unexpectedUsername
}
public enum NativeCredentialAuthentication: Sendable, Equatable {
  // Use the negotiated security type (including VeNCrypt subtype), not the
  // configured list. Authentication shape also distinguishes RSA-AES subtypes.
  case passwordOnly(securityType: UInt32)
  case usernamePassword(securityType: UInt32)
}
extension tidyvnc_endpoint_info: ABIValue {}

// An account identifier, never proof of trust or permission to send credentials.
// The opaque account is versioned and domain-separated from all other app data.
// Store only the digest: no endpoint, route, username or secret remains in this value.
public struct NativeCredentialKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
  public static let service = "io.github.jkeli.tidyvnc.credentials.v1"
  public let account: String
  public var description: String { "NativeCredentialKey(<redacted>)" }
  public var debugDescription: String { description }

  init(storedAccount: String) throws {
    let bytes = Array(storedAccount.utf8.prefix(68))
    guard bytes.count == 67, bytes.starts(with: Array("v1:".utf8)),
          bytes.dropFirst(3).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw NativeCredentialKeyIssue.invalidText
    }
    account = storedAccount
  }

  public init(endpoint: String, routeIdentity: String = "", authentication: NativeCredentialAuthentication,
              username: String = "", allowUnixSockets: Bool = true) throws {
    func bounded(_ value: String) throws -> [UInt8] {
      let bytes = Array(value.utf8.prefix(4097))
      guard bytes.count <= 4096 else { throw NativeCredentialKeyIssue.tooLong }
      guard !bytes.contains(0) else { throw NativeCredentialKeyIssue.invalidText }
      return bytes
    }
    let address = try bounded(endpoint), route = try bounded(routeIdentity), user = try bounded(username)
    let securityType: UInt32, shape: UInt32
    switch authentication {
    case .passwordOnly(let type):
      guard user.isEmpty else { throw NativeCredentialKeyIssue.unexpectedUsername }
      securityType = type; shape = 1
    case .usernamePassword(let type): securityType = type; shape = 2
    }
    // None, invalid and negotiation wrapper types do not identify a
    // credential authentication method. The actual chosen subtype is required.
    guard securityType != 0, securityType != 1, securityType != 18, securityType != 19,
          securityType != 257, securityType != 260 else {
      throw NativeCredentialKeyIssue.invalidAuthentication
    }
    var raw: UInt64 = 0
    _ = try address.withUnsafeBufferPointer { address in
      try route.withUnsafeBufferPointer { route in
        try checked {
          tidyvnc_endpoint_create(
            tidyvnc_bytes(data: address.baseAddress, length: UInt64(address.count)),
            tidyvnc_bytes(data: route.baseAddress, length: UInt64(route.count)),
            allowUnixSockets ? 1 : 0, &raw, $0)
        }
      }
    }
    let owner = NativeHandle(adopting: raw)
    account = try withExtendedLifetime(owner) {
      var canonical = abi(tidyvnc_endpoint_info.self)
      try checked { tidyvnc_endpoint_get(owner.raw, &canonical, $0) }
      var hash = SHA256()
      func number(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
      }
      func field(_ bytes: [UInt8]) {
        hash.update(data: Data(number(UInt32(bytes.count))))
        hash.update(data: Data(bytes))
      }
      func text(_ value: tidyvnc_bytes) throws -> [UInt8] { Array(try copyBytes(value)) }
      // Stable v1 format: 32-bit big-endian byte length followed by each field.
      // UTF-8 is byte-exact: Swift's Unicode-equivalent String equality must not
      // merge filesystem paths, routes or usernames with different wire bytes.
      field(Array(Self.service.utf8)); field(number(canonical.transport))
      field(try text(canonical.host)); field(try text(canonical.scope)); field(number(canonical.port))
      field(try text(canonical.path)); field(try text(canonical.route))
      field(number(securityType)); field(number(shape)); field(user)
      return "v1:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
}
