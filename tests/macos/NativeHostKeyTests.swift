// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool,_ message: String) throws { if try !value() { throw Failure(message: message) } }
@MainActor func expect(_ error: NativeStorageError,_ body: () async throws -> Void) async throws {
  do { try await body(); throw Failure(message: "Expected \(error)") }
  catch let actual as NativeStorageError { try check(actual == error,"Wrong storage error") }
}
final class Memory: NativeAtomicFileBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?, count = 0
  var writes: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { data } }
  func replace(_ value: Data,expected: Data?) throws {
    try lock.withLock { guard expected == data else { throw NativeStorageError.conflict }; data = value; count += 1 }
  }
  func force(_ value: Data?) { lock.withLock { data = value } }
}
func service(_ backing: any NativeAtomicFileBacking) -> NativeTrustStore {
  NativeTrustStore(kind: .hostKey,backing: backing,makeKey: { _ in throw NativeStorageError.invalid })
}
func scope(_ endpoint: String = "HOST:1",route: String = "") throws -> NativeTrustScope {
  try NativeTrustScope(endpoint: endpoint,routeIdentity: route,kind: .hostKey)
}
func otherKey() -> Data { var value = hostKeyFixture; value[259] ^= 2; return value }
@MainActor func identityAndStore() async throws {
  let key = try NativeHostKey(hostKeyFixture), destination = try scope()
  try check(key.bits == 2048 && key.identity == hostKeyFixture,"owned protocol encoding")
  let prompt = NativePrompt(id: 1,generation: 1,kind: .hostKey,secure: false,usernameRequired: false,certificateStatus: 0,
    serverName: "fixture.invalid",fingerprint: "not-used",identity: hostKeyFixture)
  let display = NativeTrustPresentation(prompt)
  try check(display.mayConnectOnce && display.sha256Fingerprint == hostKeyFixtureSHA256 && display.compatibilityFingerprint == hostKeyFixtureCompatibility,"independent SHA-256 and truncated SHA-1 goldens")
  try check(String(reflecting: key) == "NativeHostKey(<redacted>)","redacted identity")
  try check(destination.id == "v1:e7b57e476818d834a4cd00296ef76f1a855a9686eab263dfb9c4e06acd40169e" && destination == scope("host::5901"),"host scope independent golden")
  try check(destination != NativeTrustScope(endpoint: "HOST:1"),"certificate and host-key domains cannot collide")
  try check(destination != scope("host:2") && destination != scope(route: "ssh-route"),"port and route isolation")
  for invalid in [Data(),Data([1,2,3]),trustFixtureCertificate,Data(repeating: 0,count: 2053)] {
    try await expect(.invalid) { _ = try NativeHostKey(invalid) }
  }
  let memory = Memory(), store = service(memory), initial = try await store.read()
  let accepted = try await store.saveHostKey(scope: destination,key: hostKeyFixture,replacing: false,expected: initial.revision)
  try check(!accepted.durabilityUncertain && accepted.snapshot.entries[0].scope.kind == .hostKey,"explicit persisted host identity")
  let reused = try await store.inspectHostKey(scope: scope("host::5901"),key: hostKeyFixture)
  let changed = try await store.inspectHostKey(scope: destination,key: otherKey())
  try check(reused.state == .match && changed.state == .changed && changed.expectedFingerprint != changed.receivedFingerprint,"match and changed-key comparison")
  try await expect(.invalid) { _ = try await store.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: true,expected: accepted.snapshot.revision) }
  try await expect(.invalid) { _ = try await store.inspectHostKey(scope: NativeTrustScope(endpoint: "HOST:1"),key: hostKeyFixture) }
  try await expect(.conflict) { _ = try await store.saveHostKey(scope: destination,key: otherKey(),replacing: false,expected: accepted.snapshot.revision) }
  let replaced = try await store.saveHostKey(scope: destination,key: otherKey(),replacing: true,expected: accepted.snapshot.revision)
  let forgotten = try await store.forget(scope: destination,expected: replaced.snapshot.revision)
  try check(forgotten.snapshot.entries[0].isForgotten && forgotten.snapshot.entries[0].fingerprint == nil,"forget removes the RSA key")
  let missing = try await store.inspectHostKey(scope: destination,key: otherKey())
  try check(missing.state == .forgotten,"forgotten state persists")
  try await expect(.conflict) { _ = try await store.forget(scope: destination,expected: initial.revision) }
  let library = NativeTrustLibrary(store: store); library.reload(); try await until { !library.isWorking }
  library.forgetDestination("other.invalid:3"); try await until { !library.isWorking }
  try check(library.entries.count == 2 && library.entries.allSatisfy { $0.scope.kind == .hostKey },"management uses host scope")
  await library.close(); await store.close()
  print("PASS RSA encoding, fingerprint/scope goldens, disjoint trust kinds, add/replace/forget and typed management")
}
@MainActor func filesAndSchema() async throws {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: parent,withIntermediateDirectories: false,attributes: [.posixPermissions:0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let backend = try NativeTrustFile.file(kind: .hostKey,environment: ["XDG_STATE_HOME":parent.path])
  let certificateBackend = try NativeTrustFile.file(environment: ["XDG_STATE_HOME":parent.path])
  let store = service(backend), initial = try await store.read()
  try check(try backend.read() == nil && !FileManager.default.fileExists(atPath: backend.directory.path),"read creates no files")
  _ = try await store.saveHostKey(scope: scope(),key: hostKeyFixture,replacing: false,expected: initial.revision)
  try check(try certificateBackend.read() == nil && FileManager.default.fileExists(atPath: backend.directory.appendingPathComponent("server-keys.json").path),"dedicated host-key filename")
  let original = try backend.read()!
  let root = try JSONSerialization.jsonObject(with: original) as! [String:Any]
  try check(root["kind"] as? String == "rsa-aes","file kind explicit")
  let memory = Memory(), corrupt = service(memory)
  for (name,value,error): (String,Any,NativeStorageError) in [("schema",2,.futureSchema),("kind","x509-spki",.unsupportedValue),("secret","not-allowed",.unsupportedFields)] {
    var record = root; record[name] = value; let bytes = try JSONSerialization.data(withJSONObject: record); memory.force(bytes)
    try await expect(error) { _ = try await corrupt.read() }; try check(try memory.read() == bytes,"bad schema preserved")
  }
  var record = root, entries = root["entries"] as! [[String:Any]]
  entries[0]["hostKey"] = Data([1,2,3]).base64EncodedString(); record["entries"] = entries; memory.force(try JSONSerialization.data(withJSONObject: record))
  try await expect(.corrupt) { _ = try await corrupt.read() }
  memory.force(original)
  let certificateStore = NativeTrustStore(backing: memory)
  try await expect(.unsupportedFields) { _ = try await certificateStore.read() }
  await certificateStore.close(); await corrupt.close(); await store.close()
  print("PASS dedicated private XDG host store, explicit kind, schema/key validation and cross-file rejection")
}
@MainActor final class Target: NativeTrustTarget {
  var prompt: NativePrompt?, generation: UInt64 = 7, isClosing = false, replies = 0
  func replyTrust(to request: NativePrompt,allowed: Bool) throws { try check(prompt == request && allowed,"current trust reply"); replies += 1; prompt = nil }
}
final class LegacySpy: NativeLegacyTrustBacking, @unchecked Sendable {
  private let lock = NSLock(); private var count = 0
  var reads: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { count += 1 }; throw NativeTrustStoreIssue.unavailable }
}
@MainActor func until(_ body: () -> Bool) async throws {
  for _ in 0..<1000 { if body() { return }; try await Task.sleep(for: .milliseconds(5)) }
  throw Failure(message: "Timed out")
}
func request(_ id: UInt64 = 1,key: Data = hostKeyFixture) -> NativePrompt {
  .init(id: id,generation: 7,kind: .hostKey,secure: false,usernameRequired: false,certificateStatus: 0,
    serverName: "fixture.invalid",fingerprint: hostKeyFixtureCompatibility,identity: key)
}
@MainActor func controller() async throws {
  let memory = Memory(), store = service(memory), spy = LegacySpy(), legacy = NativeLegacyTrustStore(backing: spy)
  let target = Target(), controller = NativeCertificateTrust(store: legacy,hostKeyStore: store)
  controller.bind(target); controller.beginAttempt(endpoint: "fixture.invalid:1"); target.prompt = request(); controller.inspect(target.prompt)
  try await until { !controller.isWorking }
  try check(controller.savedInspection?.state == .absent && controller.canSave(target.prompt!) && spy.reads == 0,"first key is explicit and never consults X509 legacy store")
  controller.saveAndConnect(target.prompt!); try await until { !controller.isWorking }
  try check(target.replies == 1 && memory.writes == 1,"host save before approval")
  controller.beginAttempt(endpoint: "fixture.invalid::5901"); target.prompt = request(2); controller.inspect(target.prompt)
  try await until { !controller.isWorking }; try check(target.replies == 2 && memory.writes == 1,"same endpoint automatic host reuse")
  controller.beginAttempt(endpoint: "fixture.invalid:1"); target.prompt = request(3,key: otherKey()); controller.inspect(target.prompt)
  try await until { !controller.isWorking }
  try check(controller.replacesSavedKey && target.replies == 2,"changed key cannot inherit approval")
  let current = try await store.read(); _ = try await store.forget(scope: scope("fixture.invalid:1"),expected: current.revision)
  controller.saveAndConnect(target.prompt!); try await until { !controller.isWorking }
  try check(controller.savedIssue == .conflict && target.replies == 2,"stale changed-key save denied")
  controller.reload(); try await until { !controller.isWorking }
  try check(controller.savedInspection?.state == .forgotten && controller.canSave(target.prompt!),"explicit reload after forget")
  controller.saveAndConnect(target.prompt!); try await until { !controller.isWorking }
  try check(target.replies == 3,"explicit new key after forget")
  controller.beginAttempt(endpoint: "fixture.invalid:1"); target.prompt = request(4,key: Data([1,2,3])); controller.inspect(target.prompt)
  try check(!controller.canSave(target.prompt!) && !controller.canConnectOnce(target.prompt!) && !controller.isWorking,"malformed key cannot be reused or saved")
  memory.force(Data("corrupt".utf8))
  controller.beginAttempt(endpoint: "fixture.invalid:1"); target.prompt = request(5); controller.inspect(target.prompt)
  try await until { !controller.isWorking }
  try check(controller.savedIssue == .corrupt && target.replies == 3 && spy.reads == 0,"host store error cannot fall back to X509 trust")
  await controller.close(); await store.close(); await legacy.close()
  print("PASS first-use/save/reuse/changed/forget host prompts, stale revisions, malformed/error denial and no certificate fallback")
}
@main struct NativeHostKeyTests {
  @MainActor static func main() async {
    do { try await identityAndStore(); try await filesAndSchema(); try await controller() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
