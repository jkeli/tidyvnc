// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
@MainActor func expect(_ error: NativeStorageError, _ body: () async throws -> Void) async throws {
  do { try await body(); throw Failure(message: "Expected \(error)") }
  catch let actual as NativeStorageError { try check(actual == error,"Wrong storage error: \(actual)") }
}
struct Key: NativeCertificateKeyMaterial {
  let spki: Data
  init(_ bytes: [UInt8] = [1,2,3]) { spki = Data(bytes) }
  func digest(_ algorithm: UInt32) throws -> Data { throw NativeTrustStoreIssue.unsupportedDigest }
}
final class Memory: NativeAtomicFileBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Data?
  private var count = 0
  init(_ data: Data? = nil) { value = data }
  var writes: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { value } }
  func replace(_ data: Data,expected: Data?) throws {
    try lock.withLock {
      guard value == expected else { throw NativeStorageError.conflict }
      value = data; count += 1
    }
  }
  func force(_ data: Data?) { lock.withLock { value = data } }
}
final class Fixture: @unchecked Sendable {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-trust-" + UUID().uuidString,isDirectory: true)
  var directory: URL { parent.appendingPathComponent("native",isDirectory: true) }
  init() throws { try FileManager.default.createDirectory(at: parent,withIntermediateDirectories: false,attributes: [.posixPermissions:0o700]) }
  deinit { try? FileManager.default.removeItem(at: parent) }
}
func store(_ backing: any NativeAtomicFileBacking, key: Key = Key()) -> NativeTrustStore { NativeTrustStore(backing: backing,makeKey: { _ in key }) }
func scope(_ address: String = "HOST:1", route: String = "") throws -> NativeTrustScope { try NativeTrustScope(endpoint: address,routeIdentity: route) }
func scopes() throws {
  let original = try scope(), equivalent = try scope("host::5901")
  try check(original == equivalent && original.id == "v1:c0f8fafc6b5249a1e7119d3a3594523a5947e50d04d78ec64be2ec1192f0d047", "canonical scope independent golden")
  for other in [try scope("host:2"),try scope("host:1",route: "ssh"),try scope("other:1"),try scope("/tmp/vnc") ] {
    try check(original != other,"destination/route isolation")
  }
  try check(try scope("[fe80::1%en0]:1") != scope("[fe80::1%en1]:1"),"IPv6 scope isolation")
  try check(try scope("/tmp/Café") != scope("/tmp/Cafe\u{301}"),"byte-exact Unix path")
  try check(try scope(route: "A") != scope(route: "a"),"byte-exact route")
  let credential = try NativeCredentialKey(endpoint: "HOST:1",authentication: .passwordOnly(securityType: 2))
  try check(original.id != credential.account && String(reflecting: original) == "NativeTrustScope(<redacted>)","domain separation and redaction")
  print("PASS canonical destination scopes, port/route/IPv6/Unicode isolation, independent golden and redaction")
}
@MainActor func persistence() async throws {
  let fixture = try Fixture(), backend = try NativePrivateFile(directory: fixture.directory,record: .trustExceptions)
  let service = store(backend), other = store(backend), destination = try scope()
  let initial = try await service.read()
  try check(initial.entries.isEmpty && !FileManager.default.fileExists(atPath: fixture.directory.path),"read has no side effects")
  let xdg = try NativeTrustFile.file(environment: ["XDG_STATE_HOME":fixture.parent.path,"HOME":"/unused"])
  try check(xdg.directory.path == fixture.parent.path + "/tidyvnc/native-trust", "dedicated trust path honors XDG override")
  let home = try NativeTrustFile.file(environment: ["HOME":fixture.parent.path,"XDG_STATE_HOME":"relative"])
  try check(home.directory.path == fixture.parent.path + "/.local/state/tidyvnc/native-trust", "dedicated trust path uses retained fallback")
  try check(try xdg.read() == nil && !FileManager.default.fileExists(atPath: xdg.directory.path), "path resolution and missing read create no state")
  let saved = try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: initial.revision)
  try check(!saved.durabilityUncertain && saved.snapshot.entries.count == 1,"explicit add")
  let match = try await other.inspect(scope: scope("host::5901"),certificate: trustFixtureCertificate)
  let isolated = try await other.inspect(scope: scope("host:2"),certificate: trustFixtureCertificate)
  try check(match.state == .match && isolated.state == .absent,"persisted match and port isolation")
  let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("trust-exceptions.json").path)
  try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,"private trust file")
  let profile = try NativePrivateFile(directory: fixture.directory)
  try profile.replace(Data("profile fixture".utf8),expected: nil)
  try check(try profile.read() == Data("profile fixture".utf8),"independent profile record")
  try await expect(.conflict) { _ = try await service.forget(scope: destination,expected: initial.revision) }
  try await expect(.conflict) { _ = try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: saved.snapshot.revision) }
  let changed = store(backend,key: Key([9]))
  let changedInspection = try await changed.inspect(scope: destination,certificate: trustFixtureCertificate)
  try check(changedInspection.state == .changed && changedInspection.expectedFingerprint != changedInspection.receivedFingerprint,"changed identity")
  let replaced = try await changed.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: true,expected: saved.snapshot.revision)
  let forgotten = try await service.forget(scope: destination,expected: replaced.snapshot.revision)
  try check(forgotten.snapshot.entries[0].isForgotten && forgotten.snapshot.entries[0].fingerprint == nil,"forget removes key, retains suppression")
  let suppressed = try await other.inspect(scope: destination,certificate: trustFixtureCertificate)
  try check(suppressed.state == .forgotten,"forgotten persists across owners")
  _ = try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: forgotten.snapshot.revision)
  let current = try await service.read()
  try await expect(.invalid) { _ = try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 34,replacing: true,expected: current.revision) }
  try check(try backend.read() != nil && profile.read() == Data("profile fixture".utf8),"trust changes preserve profile file")
  await service.close(); await other.close(); await changed.close()
  try await expect(.closed) { _ = try await service.read() }
  print("PASS durable add/replace/forget, exact scope, file privacy, cross-owner revision conflicts, fatal denial and profile separation")
}
@MainActor func malformed() async throws {
  let memory = Memory(), service = store(memory), destination = try scope(), initial = try await service.read()
  let saved = try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: initial.revision)
  let valid = try memory.read()!
  var root = try JSONSerialization.jsonObject(with: valid) as! [String:Any]
  for (field,value,error): (String,Any,NativeStorageError) in [("schema",2,.futureSchema),("schema",true,.corrupt),("password","must-not-be-stored",.unsupportedFields)] {
    var invalid = root; invalid[field] = value
    let bytes = try JSONSerialization.data(withJSONObject: invalid); memory.force(bytes)
    try await expect(error) { _ = try await service.read() }
    try check(try memory.read() == bytes,"unsupported data preserved")
  }
  var entries = root["entries"] as! [[String:Any]]
  entries[0]["endpoint"] = "another-destination"; root["entries"] = entries
  memory.force(try JSONSerialization.data(withJSONObject: root))
  try await expect(.corrupt) { _ = try await service.read() }
  memory.force(valid + Data(" ".utf8))
  try await expect(.conflict) { _ = try await service.forget(scope: destination,expected: saved.snapshot.revision) }
  memory.force(Data(repeating: 1,count: NativePrivateFile.maximumBytes + 1))
  try await expect(.tooLarge) { _ = try await service.read() }
  memory.force(Data("{broken".utf8)); try await expect(.corrupt) { _ = try await service.read() }
  let capacityEntries: [[String:Any]] = try (0..<NativeTrustStore.capacity).map { index in
    let value = try scope("bounded-\(index).invalid")
    return ["scope":value.id,"endpoint":value.endpoint,"route":"","decision":"forget"]
  }
  memory.force(try JSONSerialization.data(withJSONObject: ["schema":1,"entries":capacityEntries]))
  let full = try await service.read()
  try await expect(.resourceLimit) { _ = try await service.forget(scope: destination,expected: full.revision) }
  let stillFull = try await service.read()
  try check(stillFull.entries.count == NativeTrustStore.capacity,"capacity failure preserves existing decisions")
  await service.close()
  print("PASS strict schema, unknown-field preservation, label/scope validation, byte revisions and file bounds")
}
@MainActor func failures() async throws {
  for point in [NativePrivateFile.Checkpoint.written,.willReplace,.didReplace] {
    let fixture = try Fixture(), baseline = try NativePrivateFile(directory: fixture.directory,record: .trustExceptions)
    let original = store(baseline), empty = try await original.read(), destination = try scope()
    let failed = try NativePrivateFile(directory: fixture.directory,record: .trustExceptions,checkpoint: { stage in if stage == point { throw NativeStorageError.ioFailure } })
    let service = store(failed)
    if point == .didReplace {
      let result = try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: empty.revision)
      try check(result.durabilityUncertain && result.snapshot.entries.count == 1,"post-rename reconciliation")
    } else {
      try await expect(.ioFailure) { _ = try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: empty.revision) }
      try check(try baseline.read() == nil,"pre-rename failure preserves missing record")
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    try check(!names.contains { $0.hasSuffix(".tmp") },"temporary cleanup")
    await service.close(); await original.close()
  }
  for point in [NativePrivateFile.Checkpoint.willReplace,.didReplace] {
    let fixture = try Fixture(), backend = try NativePrivateFile(directory: fixture.directory,record: .trustExceptions,checkpoint: { stage in if stage == point { withUnsafeCurrentTask { $0?.cancel() } } })
    let service = store(backend), empty = try await service.read(), destination = try scope()
    let task = Task.detached { try await service.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: empty.revision) }
    if point == .willReplace { try await expect(.cancelled) { _ = try await task.value } }
    else { let result = try await task.value; try check(!result.durabilityUncertain,"post-commit cancellation returns actual success") }
    let entries = try await service.read().entries
    try check(entries.isEmpty == (point == .willReplace),"cancellation boundary")
    await service.close()
  }
  print("PASS atomic visibility, failed-write reconciliation, temporary cleanup and cancellation before/after commit")
}
@MainActor final class Target: NativeTrustTarget {
  var prompt: NativePrompt?, generation: UInt64 = 7, isClosing = false, replies = 0
  func replyTrust(to request: NativePrompt,allowed: Bool) throws { try check(prompt == request && allowed,"current reply"); replies += 1; prompt = nil }
}
struct Legacy: NativeLegacyTrustBacking {
  let match: Bool
  func read() throws -> Data? { Data("|g0|fixture.invalid|*|0|\(match ? "AQID" : "CQ==")\n".utf8) }
}
func request(_ id: UInt64 = 1,status: UInt32 = 66) -> NativePrompt {
  .init(id: id,generation: 7,kind: .certificate,secure: false,usernameRequired: false,certificateStatus: status,
    serverName: "fixture.invalid",fingerprint: "",identity: trustFixtureCertificate)
}
@MainActor func until(_ body: () -> Bool) async throws {
  for _ in 0..<1000 { if body() { return }; try await Task.sleep(for: .milliseconds(5)) }
  throw Failure(message: "Timed out")
}
@MainActor func controllers() async throws {
  let memory = Memory(), service = store(memory), target = Target()
  let legacy = NativeLegacyTrustStore(backing: Legacy(match: false),makeKey: { _ in Key() })
  let controller = NativeCertificateTrust(store: legacy,savedStore: service); controller.bind(target)
  controller.beginAttempt(endpoint: "fixture.invalid::5901"); target.prompt = request(); controller.inspect(target.prompt)
  try await until { !controller.isWorking }
  try check(controller.canSave(target.prompt!) && controller.inspection?.state == .changed,"explicit scoped add available over legacy mismatch")
  controller.saveAndConnect(target.prompt!); try await until { !controller.isWorking }
  try check(target.replies == 1 && memory.writes == 1,"save commits before current approval")
  controller.beginAttempt(endpoint: "fixture.invalid::5901"); target.prompt = request(2); controller.inspect(target.prompt)
  try await until { !controller.isWorking }
  try check(target.replies == 2 && memory.writes == 1,"saved scope reuse without writes")
  let library = NativeTrustLibrary(store: service); library.reload(); try await until { !library.isWorking }
  library.forget(library.entries[0].id); try await until { !library.isWorking }
  try check(library.entries[0].isForgotten && !library.needsReload,"management forget")
  let broad = NativeLegacyTrustStore(backing: Legacy(match: true),makeKey: { _ in Key() })
  let suppressed = NativeCertificateTrust(store: broad,savedStore: service); suppressed.bind(target)
  suppressed.beginAttempt(endpoint: "fixture.invalid::5901"); target.prompt = request(3); suppressed.inspect(target.prompt)
  try await until { !suppressed.isWorking }
  try check(target.replies == 2 && suppressed.savedInspection?.state == .forgotten && suppressed.inspection == nil,"forget suppresses matching legacy host rule")
  suppressed.beginAttempt(endpoint: "fixture.invalid::5902"); target.prompt = request(4); suppressed.inspect(target.prompt)
  try await until { !suppressed.isWorking }
  try check(target.replies == 3,"other port preserves legacy behavior")
  suppressed.beginAttempt(endpoint: "fixture.invalid::5901"); target.prompt = request(5); suppressed.inspect(target.prompt)
  try await until { !suppressed.isWorking }
  // A separate owner changes the whole file after this prompt's inspection.
  let empty = try await service.read()
  _ = try await service.forget(scope: scope("another.invalid"),expected: empty.revision)
  suppressed.saveAndConnect(target.prompt!); try await until { !suppressed.isWorking }
  try check(suppressed.savedIssue == .conflict && suppressed.needsReload && target.replies == 3,"stale save cannot approve or overwrite")
  suppressed.beginAttempt(endpoint: "fixture.invalid::5901"); target.prompt = request(6,status: 34); suppressed.inspect(target.prompt)
  try check(!suppressed.isWorking && !suppressed.canSave(target.prompt!),"fatal status cannot persist")
  memory.force(Data("corrupt".utf8))
  suppressed.beginAttempt(endpoint: "fixture.invalid::5902"); target.prompt = request(7); suppressed.inspect(target.prompt)
  try await until { !suppressed.isWorking }
  try check(suppressed.savedIssue == .corrupt && target.replies == 3,"unreadable scoped state never falls back to legacy acceptance")
  await controller.close(); await suppressed.close(); await library.close(); await legacy.close(); await broad.close(); await service.close()
  print("PASS explicit save, automatic current-scope reuse, management forget, legacy suppression, stale revision and fatal/read-failure gating")
}
final class Gate: @unchecked Sendable {
  private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
  private var entered = false
  var isEntered: Bool { lock.withLock { entered } }
  func hold() throws {
    lock.withLock { entered = true }
    guard semaphore.wait(timeout: .now() + 5) == .success else { throw NativeStorageError.ioFailure }
  }
  func release() { semaphore.signal() }
}
@MainActor func concurrentWritersAndClose() async throws {
  let fixture = try Fixture(), gate = Gate()
  let first = store(try NativePrivateFile(directory: fixture.directory,record: .trustExceptions,checkpoint: { if $0 == .willReplace { try gate.hold() } }))
  let second = store(try NativePrivateFile(directory: fixture.directory,record: .trustExceptions))
  let empty = try await first.read(), destination = try scope()
  let writer = Task { try await first.save(scope: destination,certificate: trustFixtureCertificate,status: 66,replacing: false,expected: empty.revision) }
  try await until { gate.isEntered }
  try await expect(.busy) { _ = try await second.forget(scope: destination,expected: empty.revision) }
  gate.release(); let committed = try await writer.value
  try await expect(.conflict) { _ = try await second.forget(scope: destination,expected: empty.revision) }
  let final = try await second.read()
  try check(final.revision == committed.snapshot.revision && !final.entries[0].isForgotten,"concurrent writer cannot lose first commit")
  await first.close(); await second.close()
  for point in [NativePrivateFile.Checkpoint.willReplace,.didReplace] {
    let fixture = try Fixture(), gate = Gate()
    let backing = try NativePrivateFile(directory: fixture.directory,record: .trustExceptions,checkpoint: { if $0 == point { try gate.hold() } })
    let service = store(backing), controller = NativeCertificateTrust(savedStore: service), target = Target()
    controller.bind(target); controller.beginAttempt(endpoint: "fixture.invalid"); target.prompt = request(); controller.inspect(target.prompt)
    try await until { !controller.isWorking }
    controller.saveAndConnect(target.prompt!); try await until { gate.isEntered }
    var drained = false
    let closer = Task { await controller.close(); drained = true }
    try await Task.sleep(for: .milliseconds(20))
    try check(!drained,"window close waits for committed or pending write")
    gate.release(); await closer.value
    let result = try await service.read()
    try check(target.replies == 0 && result.entries.isEmpty == (point == .willReplace),"closed prompt never approved, actual disk outcome preserved")
    await service.close()
  }
  let memory = Memory(), service = store(memory), library = NativeTrustLibrary(store: service)
  library.reload(); try await until { !library.isWorking }
  library.forgetDestination("legacy-only.invalid::5909"); try await until { !library.isWorking }
  try check(library.entries.count == 1 && library.entries[0].isForgotten,"explicit ask-again suppresses legacy without a prior native record")
  await library.close(); await service.close()
  print("PASS independent writer lock/revision conflicts, close during pending/committed writes, and legacy-only suppression management")
}
@main struct NativeTrustStoreTests {
  @MainActor static func main() async {
    do { try scopes(); try await persistence(); try await malformed(); try await failures(); try await controllers(); try await concurrentWritersAndClose() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
