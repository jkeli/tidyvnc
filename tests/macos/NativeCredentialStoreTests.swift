// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import Security
import LocalAuthentication
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message: message) }
}
func expect(_ issue: NativeCredentialStoreIssue, _ body: () throws -> Void) throws {
  do { try body(); throw Failure(message: "Expected typed error") }
  catch let result as NativeCredentialStoreIssue { try check(result == issue, "typed failure mismatch") }
}
func key(_ host: String = "test.invalid") throws -> NativeCredentialKey {
  try NativeCredentialKey(endpoint: host, authentication: .passwordOnly(securityType: 2))
}
func secret() throws -> NativeCredentialSecret {
  var bytes: [UInt8] = [1,2,3]; return try NativeCredentialSecret(consuming: &bytes)
}
final class Client: NativeSecItemClient, @unchecked Sendable {
  let lock = NSLock()
  var status: OSStatus = errSecSuccess
  var returned: CFTypeRef?
  var calls = 0, wasMain = false
  var interactionNotAllowed: Bool?
  var query: [String:Any] = [:], attributes: [String:Any] = [:]
  func configure(_ status: OSStatus, result: CFTypeRef? = nil) { lock.withLock { self.status = status; returned = result } }
  func record(_ query: [String:Any], attributes: [String:Any] = [:]) -> OSStatus {
    lock.withLock {
      calls += 1; wasMain = Thread.isMainThread
      interactionNotAllowed = (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed
      self.query = query; self.attributes = attributes; return status
    }
  }
  func copy(_ query: [String:Any]) -> (OSStatus,CFTypeRef?) {
    let status = record(query); return lock.withLock { (status, returned) }
  }
  func add(_ attributes: [String:Any]) -> OSStatus { record(attributes) }
  func update(_ query: [String:Any], attributes: [String:Any]) -> OSStatus { record(query,attributes: attributes) }
  func delete(_ query: [String:Any]) -> OSStatus { record(query) }
  func policy(_ key: NativeCredentialKey?, interaction: Bool) throws {
    try lock.withLock {
      try check(query[kSecClass as String] as? String == kSecClassGenericPassword as String, "generic passwords only")
      try check(query[kSecUseDataProtectionKeychain as String] as? Bool == true, "explicit data protection backend")
      try check(query[kSecAttrSynchronizable as String] as? Bool == false, "no synchronization")
      try check(query[kSecAttrService as String] as? String == NativeCredentialKey.service, "app service scope")
      try check(query[kSecAttrAccount as String] as? String == key?.account, "exact account or bounded metadata listing")
      try check(query[kSecAttrAccessGroup as String] == nil && query[kSecAttrAccessControl as String] == nil && query[kSecAttrAccess as String] == nil, "no shared group, ACL override or biometric requirement")
      try check(interactionNotAllowed == !interaction, "per-call OS interaction policy")
    }
  }
}
func metadataFields(_ key: NativeCredentialKey) -> [String:Any] {
  [kSecAttrAccount as String: key.account, kSecAttrService as String: NativeCredentialKey.service,
   kSecAttrCreationDate as String: Date(timeIntervalSince1970: 10), kSecAttrModificationDate as String: Date(timeIntervalSince1970: 20)]
}
func backend() throws {
  let client = Client(), backend = NativeKeychainBacking(client: client), key = try key(), secret = try secret()
  defer { secret.clear() }
  client.configure(errSecSuccess,result: Data([1,2,3]) as CFData)
  let received = try backend.lookup(key,interaction: .forbid)
  try check(received.copyBytes() == [1,2,3], "owned lookup data")
  received.clear(); try expect(.secretCleared) { _ = try received.copyBytes() }
  try client.policy(key,interaction: false)
  try check(client.query[kSecReturnData as String] as? Bool == true, "lookup requests secret explicitly")
  try backend.save(key,secret: secret,mode: .create,interaction: .allow)
  try client.policy(key,interaction: true)
  try check(client.query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, "local unlocked-only accessibility")
  try check(client.query[kSecValueData as String] as? Data == Data([1,2,3]), "create stores secret payload")
  client.configure(errSecDuplicateItem)
  let before = client.calls
  try expect(.duplicate) { try backend.save(key,secret: secret,mode: .create,interaction: .forbid) }
  try check(client.calls == before+1, "duplicate creation never replaces implicitly")
  client.configure(errSecSuccess)
  try backend.save(key,secret: secret,mode: .replace,interaction: .forbid)
  try client.policy(key,interaction: false)
  try check(client.query[kSecValueData as String] == nil && client.attributes[kSecValueData as String] as? Data == Data([1,2,3]), "replace separates query and update")
  client.configure(errSecItemNotFound)
  let beforeReplace = client.calls
  try expect(.notFound) { try backend.save(key,secret: secret,mode: .replace,interaction: .forbid) }
  try check(client.calls == beforeReplace+1, "missing replacement never adds implicitly")
  client.configure(errSecSuccess)
  try backend.delete(key,interaction: .forbid); try client.policy(key,interaction: false)
  try check(client.query[kSecValueData as String] == nil, "delete is exact and secret-free")
  client.configure(errSecSuccess,result: metadataFields(key) as CFDictionary)
  let metadata = try backend.metadata(key,interaction: .forbid)
  try check(metadata.key == key && metadata.created == Date(timeIntervalSince1970: 10), "typed metadata")
  try check(client.query[kSecReturnData as String] == nil && client.query[kSecReturnAttributes as String] as? Bool == true, "metadata does not read passwords")
  let other = try selfKey()
  client.configure(errSecSuccess,result: [metadataFields(key), metadataFields(other)] as CFArray)
  let page = try backend.listMetadata(limit: 1,interaction: .forbid)
  try client.policy(nil,interaction: false)
  try check(page.entries.count == 1 && page.hasMore && client.query[kSecMatchLimit as String] as? Int == 2, "metadata bound and truncation signal")
  client.configure(errSecItemNotFound)
  try check(backend.listMetadata(limit: 2,interaction: .forbid).entries.isEmpty, "missing list is empty")
  client.configure(errSecSuccess,result: metadataFields(other) as CFDictionary)
  try expect(.corrupt) { _ = try backend.metadata(key,interaction: .forbid) }
  var malformed = metadataFields(key); malformed[kSecValueData as String] = Data([9])
  client.configure(errSecSuccess,result: malformed as CFDictionary)
  try expect(.corrupt) { _ = try backend.metadata(key,interaction: .forbid) }
  client.configure(errSecSuccess,result: Data(repeating: 1,count: 4097) as CFData)
  try expect(.tooLarge) { _ = try backend.lookup(key,interaction: .forbid) }
  client.configure(errSecSuccess,result: "not a password record" as CFString)
  try expect(.corrupt) { _ = try backend.lookup(key,interaction: .forbid) }
  print("PASS scoped SecItem queries, OS interaction/access policy, explicit create/replace, bounded metadata and malformed output")
}
func selfKey() throws -> NativeCredentialKey { try key("other.invalid") }
func failures() throws {
  for (status, issue) in [(errSecItemNotFound,NativeCredentialStoreIssue.notFound),
    (errSecNotAvailable,.unavailable),(errSecAuthFailed,.denied),(errSecInteractionNotAllowed,.interactionRequired),
    (errSecInteractionRequired,.interactionRequired),(errSecUserCanceled,.cancelled),
    (errSecMissingEntitlement,.missingEntitlement),(errSecDuplicateItem,.duplicate),(errSecDecode,.corrupt),(-99999,.failed(-99999))] {
    try expect(issue) { try NativeKeychainBacking.check(status) }
  }
  var bytes: [UInt8] = [1,2,3]
  let secret = try NativeCredentialSecret(consuming: &bytes)
  try check(bytes == [0,0,0] && secret.copyBytes() == [1,2,3], "consumes and clears caller storage")
  try check(String(describing: secret) == "NativeCredentialSecret(<redacted>)" && String(reflecting: secret) == secret.description, "secret diagnostics redacted")
  secret.clear(); secret.clear(); try expect(.secretCleared) { _ = try secret.copyBytes() }
  var oversized = [UInt8](repeating: 1,count: 4097)
  try expect(.tooLarge) { _ = try NativeCredentialSecret(consuming: &oversized) }
  try check(oversized.allSatisfy { $0 == 0 }, "rejected owned input wiped")
  var empty: [UInt8] = []; let blank = try NativeCredentialSecret(consuming: &empty)
  try check(blank.copyBytes().isEmpty, "empty password represented explicitly"); blank.clear()
  for account in ["v2:"+String(repeating:"a",count:64), "v1:"+String(repeating:"A",count:64), "v1:a", String(repeating:"a",count:999)] {
    do { _ = try NativeCredentialKey(storedAccount: account); throw Failure(message:"Malformed account accepted") }
    catch is NativeCredentialKeyIssue {}
  }
  print("PASS status categories, opaque account validation, owned secret clearing and redaction")
}
final class BlockingBacking: NativeCredentialBacking, @unchecked Sendable {
  let lock = NSLock(), gate = DispatchSemaphore(value: 0)
  var started = false, calls = 0, committed = false, onMain = false
  func state() -> (Bool,Int,Bool,Bool) { lock.withLock { (started,calls,committed,onMain) } }
  func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialSecret { throw NSError(domain: "private credential context",code: 99) }
  func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode, interaction: NativeCredentialInteraction) throws {
    lock.withLock { started = true; calls += 1; onMain = Thread.isMainThread }
    gate.wait(); lock.withLock { committed = true }
  }
  func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws { lock.withLock { calls += 1 } }
  func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadata { throw NativeCredentialStoreIssue.notFound }
  func listMetadata(limit: Int, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadataPage { NativeCredentialMetadataPage(entries: [],hasMore: false) }
}
@MainActor func until(_ condition: () async -> Bool) async throws {
  for _ in 0..<2000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
@MainActor func lifetime() async throws {
  let backing = BlockingBacking(), store = NativeCredentialStore(backing: backing), key = try key(), secret = try secret()
  defer { secret.clear(); backing.gate.signal() }
  let writing = Task { try await store.save(key,secret: secret) }
  try await until { backing.state().0 }
  try check(!backing.state().3, "OS work is off MainActor")
  writing.cancel()
  let queued = Task { try await store.delete(key) }
  try await until { await store.pendingCount == 2 }
  queued.cancel()
  var jobs: [Task<Void,Error>] = []
  for _ in 0..<14 { jobs.append(Task { try await store.delete(key) }) }
  try await until { await store.pendingCount == 16 }
  do { try await store.delete(key); throw Failure(message: "Unbounded admission") }
  catch let error as NativeCredentialStoreIssue { try check(error == .busy, "bounded queue") }
  let closing = Task { await store.close() }
  let alsoClosing = Task { await store.close() }
  try await Task.sleep(for: .milliseconds(10))
  try check(!backing.state().2 && backing.state().1 == 1, "close waits asynchronously without starting queued operations")
  backing.gate.signal()
  try await writing.value
  do { try await queued.value; throw Failure(message: "Cancelled queued operation ran") }
  catch let error as NativeCredentialStoreIssue { try check(error == .cancelled, "queued cancellation") }
  for job in jobs {
    do { try await job.value; throw Failure(message: "Closed queue ran") }
    catch let error as NativeCredentialStoreIssue { try check(error == .cancelled, "close cancels queued work") }
  }
  await closing.value; await alsoClosing.value
  try check(backing.state().2 && backing.state().1 == 1, "running committed result survives cancellation")
  do { _ = try await store.lookup(key); throw Failure(message: "Closed store admitted work") }
  catch let error as NativeCredentialStoreIssue { try check(error == .closed, "closed store") }
  print("PASS MainActor responsiveness, bounded admission, queued cancellation, committed save outcome and idempotent drain")
}
@MainActor func integrated() async throws {
  let client = Client(), store = NativeCredentialStore(backing: NativeKeychainBacking(client: client)), key = try key()
  let cancelled = Task { try await store.lookup(key) }; cancelled.cancel()
  do { _ = try await cancelled.value; throw Failure(message: "Pre-admission cancellation ignored") }
  catch let error as NativeCredentialStoreIssue { try check(error == .cancelled, "pre-admission cancellation") }
  try check(client.calls == 0, "cancel before admission does no OS work")
  client.configure(errSecSuccess,result: Data([1,2,3]) as CFData)
  let value = try await store.lookup(key)
  try client.policy(key,interaction: false)
  try check(!client.wasMain && value.copyBytes() == [1,2,3], "actual adapter executes through utility queue")
  value.clear(); await store.close()
  let failing = NativeCredentialStore(backing: BlockingBacking())
  do { _ = try await failing.lookup(key); throw Failure(message: "Unknown backend failure lost") }
  catch let error as NativeCredentialStoreIssue { try check(error == .failed(0), "unknown backend text redacted") }
  await failing.close()
  print("PASS complete store/adapter path, default interaction refusal, pre-admission cancellation and redacted backend failures")
}
@main struct NativeCredentialStoreTests {
  @MainActor static func main() async {
    do { try backend(); try failures(); try await lifetime(); try await integrated() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
