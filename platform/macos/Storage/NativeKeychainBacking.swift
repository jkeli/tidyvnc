// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import Security
import LocalAuthentication

// Kept internal: production callers cannot supply arbitrary SecItem queries or
// turn a scoped deletion into a service-wide deletion.
protocol NativeSecItemClient: Sendable {
  func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  func delete(_ query: [String: Any]) -> OSStatus
}
private struct SystemSecItemClient: NativeSecItemClient {
  func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status,result)
  }
  func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary,nil) }
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary,attributes as CFDictionary) }
  func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
// Immutable configuration, with per-call dictionaries and LAContexts. The store
// serializes calls; no process-wide interaction flags or authentication cache.
public final class NativeKeychainBacking: NativeCredentialBacking, Sendable {
  private let client: any NativeSecItemClient
  private let service: String
  public init() { client = SystemSecItemClient(); service = NativeCredentialKey.service }
  init(client: any NativeSecItemClient, service: String = NativeCredentialKey.service) {
    self.client = client; self.service = service
  }
  private func query(_ key: NativeCredentialKey?, context: LAContext) -> [String: Any] {
    var result: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
      kSecAttrService as String: service,
      kSecUseAuthenticationContext as String: context
    ]
    if let key { result[kSecAttrAccount as String] = key.account }
    return result
  }
  private func context(_ interaction: NativeCredentialInteraction) -> LAContext {
    let value = LAContext(); value.interactionNotAllowed = interaction == .forbid
    value.localizedReason = String(localized:"credentials.keychain.access.reason", defaultValue:"Access a saved TidyVNC credential.")
    return value
  }
  static func check(_ status: OSStatus) throws {
    switch status {
    case errSecSuccess: return
    case errSecItemNotFound: throw NativeCredentialStoreIssue.notFound
    case errSecNotAvailable, errSecNoSuchKeychain, errSecInvalidKeychain: throw NativeCredentialStoreIssue.unavailable
    case errSecAuthFailed: throw NativeCredentialStoreIssue.denied
    case errSecInteractionNotAllowed, errSecInteractionRequired: throw NativeCredentialStoreIssue.interactionRequired
    case errSecUserCanceled: throw NativeCredentialStoreIssue.cancelled
    case errSecMissingEntitlement: throw NativeCredentialStoreIssue.missingEntitlement
    case errSecDuplicateItem: throw NativeCredentialStoreIssue.duplicate
    case errSecDecode: throw NativeCredentialStoreIssue.corrupt
    default: throw NativeCredentialStoreIssue.failed(status)
    }
  }
  public func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialSecret {
    let context = context(interaction); defer { context.invalidate() }
    var query = query(key, context: context)
    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status,result) = client.copy(query); try Self.check(status)
    guard let data = result as? Data else { throw NativeCredentialStoreIssue.corrupt }
    guard data.count <= NativeCredentialSecret.maximumBytes else { throw NativeCredentialStoreIssue.tooLarge }
    var bytes = Array(data)
    return try NativeCredentialSecret(consuming: &bytes)
  }
  public func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode,
                   interaction: NativeCredentialInteraction) throws {
    let context = context(interaction); defer { context.invalidate() }
    var bytes = try secret.copyBytes()
    defer { bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } } }
    var data = Data(bytes); defer { data.resetBytes(in: 0..<data.count) }
    var attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]
    switch mode {
    case .create:
      attributes.merge(query(key, context: context)) { _,new in new }
      attributes[kSecAttrLabel as String] = String(localized:"credentials.keychain.item.label", defaultValue:"TidyVNC credential")
      try Self.check(client.add(attributes))
    case .replace:
      try Self.check(client.update(query(key, context: context),attributes: attributes))
    }
  }
  public func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws {
    let context = context(interaction); defer { context.invalidate() }
    try Self.check(client.delete(query(key, context: context)))
  }
  private func metadata(_ value: Any, expected: NativeCredentialKey? = nil) throws -> NativeCredentialMetadata {
    guard let fields = value as? [String: Any], let account = fields[kSecAttrAccount as String] as? String,
          fields[kSecAttrService as String] as? String == service,
          fields[kSecValueData as String] == nil else { throw NativeCredentialStoreIssue.corrupt }
    let key: NativeCredentialKey
    do { key = try NativeCredentialKey(storedAccount: account) }
    catch { throw NativeCredentialStoreIssue.corrupt }
    guard expected == nil || expected == key else { throw NativeCredentialStoreIssue.corrupt }
    func date(_ name: CFString) throws -> Date? {
      guard let value = fields[name as String] else { return nil }
      guard let date = value as? Date else { throw NativeCredentialStoreIssue.corrupt }
      return date
    }
    return try NativeCredentialMetadata(key: key, created: date(kSecAttrCreationDate), modified: date(kSecAttrModificationDate))
  }
  public func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadata {
    let context = context(interaction); defer { context.invalidate() }
    var query = query(key, context: context)
    query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status,result) = client.copy(query); try Self.check(status)
    guard let result else { throw NativeCredentialStoreIssue.corrupt }
    return try metadata(result, expected: key)
  }
  public func listMetadata(limit: Int, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadataPage {
    guard (1...256).contains(limit) else { throw NativeCredentialStoreIssue.tooLarge }
    let context = context(interaction); defer { context.invalidate() }
    var query = query(nil, context: context)
    query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = limit + 1
    let (status,result) = client.copy(query)
    if status == errSecItemNotFound { return NativeCredentialMetadataPage(entries: [],hasMore: false) }
    try Self.check(status)
    guard let values = result as? [Any], values.count <= limit + 1 else { throw NativeCredentialStoreIssue.corrupt }
    let metadata = try values.map { try self.metadata($0) }
    return NativeCredentialMetadataPage(entries: Array(metadata.prefix(limit)),hasMore: metadata.count > limit)
  }
}
