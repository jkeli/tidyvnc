// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
func expect(_ error: NativeStorageError, _ action: () async throws -> Void) async throws {
  do { try await action(); throw Failure(message:"Expected \(error)") }
  catch let actual as NativeStorageError { try check(actual == error,"storage error \(actual)") }
}
func historyError(_ error: NativeHistoryImportError, _ action: () async throws -> Void) async throws {
  do { try await action(); throw Failure(message:"Expected history error") }
  catch let actual as NativeHistoryImportError { try check(actual == error,"redacted history error") }
}
func proposal(_ body: String = "newest\nolder\n", origin: NativeImportOrigin = .currentXDG) throws -> NativeHistoryImport {
  try .init(data:Data(body.utf8),origin:origin)
}
final class Memory: NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?, readError: NativeStorageError?, writeError: NativeStorageError?, count = 0
  init(_ bytes: Data? = nil) { self.bytes = bytes }
  func read() throws -> Data? { try lock.withLock { if let readError { throw readError }; return bytes } }
  func replace(_ data: Data, expected: Data?) throws {
    try lock.withLock {
      if let writeError { throw writeError }
      guard bytes == expected else { throw NativeStorageError.conflict }
      bytes = data; count += 1
    }
  }
  func fail(read: NativeStorageError? = nil, write: NativeStorageError? = nil) { lock.withLock { readError = read; writeError = write } }
  var writes: Int { lock.withLock { count } }
}
func envelope(schema: Int = 10, state: Any? = "uninitialized", endpoints: [String] = []) throws -> Data {
  var object: [String:Any] = ["schema":schema,"revision":UUID().uuidString,"profiles":[],"recentEndpoints":endpoints]
  if let state { object["historyState"] = state }
  return try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
}
func parsing() async throws {
  let source = "HOST:0\r\nhost::5900\nHOST:0\n[fe80::1%en0]:1\n/path with spaces/socket\n\n spaced-host \r\n"
  let value = try proposal(source)
  try check(value.endpoints == ["HOST:0","host::5900","[fe80::1%en0]:1","/path with spaces/socket"," spaced-host "],"preserve order, spelling, scope and whitespace")
  try check(value.duplicateCount == 1 && value.omittedOlderCount == 0 && value.requiresOmissionReview,"duplicate notice")
  try await historyError(.reviewRequired) { _ = try value.reviewedEndpoints(acknowledgingOmissions:false) }
  try check(try value.reviewedEndpoints(acknowledgingOmissions:true) == value.endpoints,"explicit omission review")
  let many = try proposal((0..<25).map { "host\($0)" }.joined(separator:"\n")+"\nhost24\nhost0\n",origin:.legacy)
  try check(many.origin == .legacy && many.endpoints == (0..<20).map { "host\($0)" } && many.duplicateCount == 2 && many.omittedOlderCount == 5,"first 20 unique entries and complete omission counts")
  try check(try proposal("\n\r\n").endpoints.isEmpty,"blank lines omitted")
  try check(try proposal(String(repeating:"é",count:127)+"\r\n").endpoints[0].utf8.count == 254,"byte bound with UTF8 and CRLF")
  try await historyError(.lineTooLong(2)) { _ = try proposal("host\n"+String(repeating:"x",count:255)) }
  try await historyError(.invalidText(2)) { _ = try proposal("host\nprivate-secret\0value") }
  try await historyError(.invalidText(2)) { _ = try NativeHistoryImport(data:Data([104,10,255]),origin:.legacy) }
  let pastCapacity = (0..<20).map { "h\($0)" }.joined(separator:"\n")
  try await historyError(.lineTooLong(21)) { _ = try proposal(pastCapacity+"\n"+String(repeating:"x",count:255)) }
  let boundary = try NativeHistoryImport(data:Data(repeating:10,count:NativeHistoryImport.maximumBytes),origin:.currentXDG)
  try check(boundary.endpoints.isEmpty,"whole-file bound accepts exact maximum")
  try await historyError(.tooLarge) { _ = try NativeHistoryImport(data:Data(repeating:10,count:NativeHistoryImport.maximumBytes+1),origin:.legacy) }
  try check(!NativeHistoryImportError.invalidText(2).description.contains("private-secret"),"errors contain no source values")
}
func schemaAndPrecedence() async throws {
  let imported = try proposal()
  for version in 1...9 {
    let bytes = try envelope(schema:version,state:nil), memory = Memory(bytes), store = NativeProfileHistoryStore(backing:memory)
    let historical = try await store.read()
    try check(historical.historyState == .native && !historical.canImportHistory,"historical empty history is authoritative")
    try await expect(.conflict) { _ = try await store.importHistory(imported,expected:historical.revision,acknowledgingOmissions:true) }
    try check(try memory.read() == bytes && memory.writes == 0,"read never upgrades history or marks migration")
    let upgraded = try await store.upsert(.init(name:"Profile",endpoint:"host"),expected:historical.revision)
    try check(upgraded.historyState == .native && !upgraded.canImportHistory,"explicit upgrade preserves historical precedence")
    await store.close()
  }
  let malformed: [(Data,NativeStorageError)] = [
    (try envelope(schema:12),.futureSchema), (try envelope(schema:9),.unsupportedFields),
    (try envelope(state:nil),.corrupt), (try envelope(state:NSNull()),.corrupt),
    (try envelope(state:true),.corrupt), (try envelope(state:"future"),.unsupportedValue),
    (try envelope(endpoints:["host"]),.corrupt), (Data("malformed-native".utf8),.corrupt)]
  for (bytes,error) in malformed {
    let memory = Memory(bytes), store = NativeProfileHistoryStore(backing:memory)
    try await expect(error) { _ = try await store.importHistory(imported,expected:nil,acknowledgingOmissions:true) }
    try check(try memory.read() == bytes && memory.writes == 0,"invalid metadata preserved")
    await store.close()
  }
  let memory = Memory(), store = NativeProfileHistoryStore(backing:memory)
  let absent = try await store.read()
  try check(absent.canImportHistory && absent.historyImportOrigin == nil && memory.writes == 0,"absent store permits explicit history import")
  let profile = NativeConnectionProfile(name:"Profile",endpoint:"native-host",settings:.init(clipboardSend:false),credentialReference:UUID())
  let profileOnly = try await store.upsert(profile,expected:nil)
  try check(profileOnly.canImportHistory && profileOnly.profiles == [profile],"profile edits do not initialize history")
  let accepted = try await store.importHistory(imported,expected:profileOnly.revision,acknowledgingOmissions:true)
  try check(accepted.profiles == [profile] && accepted.recentEndpoints == imported.endpoints && accepted.historyImportOrigin == .currentXDG,"history import preserves native profiles and opaque references")
  let object = try JSONSerialization.jsonObject(with:memory.read()!) as! [String:Any]
  try check(object["schema"] as? Int == 11 && object["historyState"] as? String == "currentXDG","schema 11 marker in the history transaction")
  let recorded = try await store.recordRecent("native-new",expected:accepted.revision)
  let cleared = try await store.clearHistory(expected:recorded.revision)
  try check(cleared.historyImportOrigin == .currentXDG && !cleared.canImportHistory && cleared.recentEndpoints.isEmpty,"record/clear retain import marker")
  try await expect(.conflict) { _ = try await store.importHistory(imported,expected:cleared.revision,acknowledgingOmissions:true) }
  await store.close()
  for recording in [false,true] {
    let store = NativeProfileHistoryStore(backing:Memory())
    let initialized = recording ? try await store.recordRecent("native",expected:nil) : try await store.clearHistory(expected:nil)
    try check(initialized.historyState == .native && !initialized.canImportHistory,"native recording and explicit empty clear block import")
    try await expect(.conflict) { _ = try await store.importHistory(imported,expected:initialized.revision,acknowledgingOmissions:true) }
    await store.close()
  }
  let profileStore = NativeProfileHistoryStore(backing:Memory())
  let profileSnapshot = try await profileStore.upsert(.init(name:"Temporary",endpoint:"host"),expected:nil)
  let deleted = try await profileStore.deleteProfile(id:profileSnapshot.profiles[0].id,expected:profileSnapshot.revision)
  try check(deleted.profiles.isEmpty && deleted.canImportHistory,"deleting the last profile does not imply a history clear")
  await profileStore.close()
}
func failureAndRace() async throws {
  let value = try proposal("same\nsame\n",origin:.legacy), memory = Memory(), store = NativeProfileHistoryStore(backing:memory)
  try await historyError(.reviewRequired) { _ = try await store.importHistory(value,expected:nil,acknowledgingOmissions:false) }
  let cancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    try await expect(.cancelled) { _ = try await store.importHistory(value,expected:nil,acknowledgingOmissions:true) }
  }
  try await cancelled.value
  memory.fail(read:.denied)
  try await expect(.denied) { _ = try await store.importHistory(value,expected:nil,acknowledgingOmissions:true) }
  memory.fail(write:.ioFailure)
  try await expect(.ioFailure) { _ = try await store.importHistory(value,expected:nil,acknowledgingOmissions:true) }
  memory.fail(); try check(memory.writes == 0 && memory.read() == nil,"failed/cancelled operations cannot initialize history")
  let a = NativeProfileHistoryStore(backing:memory), b = NativeProfileHistoryStore(backing:memory)
  let winners = await withTaskGroup(of:Bool.self,returning:[Bool].self) { group in
    for owner in [a,b] { group.addTask { (try? await owner.importHistory(value,expected:nil,acknowledgingOmissions:true)) != nil } }
    var values: [Bool] = []; for await value in group { values.append(value) }; return values
  }
  try check(winners.filter({$0}).count == 1 && memory.writes == 1,"independent stores cannot both import")
  let committed = try await store.read(); try check(committed.historyImportOrigin == .legacy,"winner has legacy marker")
  await a.close(); await b.close(); await store.close()
  try await expect(.closed) { _ = try await store.importHistory(value,expected:committed.revision,acknowledgingOmissions:true) }
}
func fileTransactions() async throws {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-history-import-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:parent) }
  let value = try proposal()
  for (index,point) in [NativePrivateFile.Checkpoint.written,.willReplace,.didReplace].enumerated() {
    let root = parent.appendingPathComponent(String(index)), plain = try NativePrivateFile(directory:root)
    let owner = NativeProfileHistoryStore(backing:plain)
    let profile = NativeConnectionProfile(name:"Keep",endpoint:"native")
    let before = try await owner.upsert(profile,expected:nil), original = try plain.read()
    let failing = NativeProfileHistoryStore(backing:try NativePrivateFile(directory:root) { stage in
      if stage == point { throw NativeStorageError.ioFailure }
    })
    try await expect(.ioFailure) { _ = try await failing.importHistory(value,expected:before.revision,acknowledgingOmissions:true) }
    let after = try await owner.read()
    try check(after.profiles == [profile],"interruption preserves profiles")
    if point == .didReplace {
      try check(after.historyImportOrigin == .currentXDG && after.recentEndpoints == value.endpoints,"accepted but uncertain write stores marker and values together")
      try await expect(.conflict) { _ = try await owner.importHistory(value,expected:after.revision,acknowledgingOmissions:true) }
    } else { try check(after.canImportHistory && plain.read() == original,"precommit failure leaves bytes and eligibility unchanged") }
    let file = root.appendingPathComponent("profiles-history.json")
    let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
    try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,"private imported history record")
    let names = try FileManager.default.contentsOfDirectory(atPath:root.path)
    try check(!names.contains(where:{$0.hasSuffix(".tmp")}),"failed import cleans temporary output")
    await owner.close(); await failing.close()
  }
}
func discoveryAndReviewedSnapshot() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-history-sources-"+UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let paths = try NativeImportPaths(homeDirectory:root.path,environment:[:]), memory = Memory()
  let store = NativeProfileHistoryStore(backing:memory), service = NativeHistoryImportService(paths:paths,store:store)
  func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data(text.utf8).write(to:url)
  }
  let absent = try await service.prepare(origin:.currentXDG)
  try check(absent == nil && !FileManager.default.fileExists(atPath:root.path),"missing read creates nothing")
  memory.fail(read:.denied)
  try await expect(.denied) { _ = try await service.prepare(origin:.legacy) }
  memory.fail()
  try write(paths.legacyHistory[1],"fallback\n")
  let fallback = try await service.prepare(origin:.legacy)!
  try check(fallback.source == paths.legacyHistory[1],"legacy home fallback only on absence")
  try write(paths.legacyHistory[0],"legacy\n")
  let preferred = try await service.prepare(origin:.legacy)!
  try check(preferred.source == paths.legacyHistory[0],"legacy XDG precedence")
  try write(paths.legacyHistory[0],"invalid\0history")
  try await historyError(.invalidText(1)) { _ = try await service.prepare(origin:.legacy) }
  try write(paths.legacyHistory[0],"legacy\n")
  try write(paths.currentDefaults,"malformed unrelated settings")
  _ = try await service.prepare(origin:.legacy) // Defaults are not history consent or precedence.
  try write(paths.currentHistory,"private\0broken")
  try await historyError(.currentHistoryExists) { _ = try await service.prepare(origin:.legacy) }
  try await historyError(.invalidText(1)) { _ = try await service.prepare(origin:.currentXDG) }
  try write(paths.currentHistory,"reviewed\n")
  let review = try await service.prepare(origin:.currentXDG)!
  let profileOnly = try await store.upsert(.init(name:"Native",endpoint:"keep"),expected:nil)
  try await expect(.conflict) { _ = try await service.commit(review,acknowledgingOmissions:true) }
  let refreshed = try await service.prepare(origin:.currentXDG)!
  try write(paths.currentHistory,"edited-after-review\n")
  let accepted = try await service.commit(refreshed,acknowledgingOmissions:true)
  try check(accepted.recentEndpoints == ["reviewed"] && accepted.profiles == profileOnly.profiles,"immutable reviewed history and preserved latest profiles")
  try check(try String(contentsOf:paths.currentHistory,encoding:.utf8) == "edited-after-review\n","source never written by import")
  try await historyError(.nativeHistoryExists) { _ = try await service.prepare(origin:.legacy) }
  await store.close()
}
actor GateReader: NativeDocumentReading {
  private var continuation: CheckedContinuation<Data,Never>?
  var entered: Bool { continuation != nil }
  func read(_ url: URL) async throws -> Data { await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(returning:Data("cancelled-source\n".utf8)); continuation = nil }
}
func cancelDuringRead() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-history-cancel-"+UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let paths = try NativeImportPaths(homeDirectory:root.path,environment:[:])
  try FileManager.default.createDirectory(at:paths.currentHistory.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data("source\n".utf8).write(to:paths.currentHistory)
  let memory = Memory(), store = NativeProfileHistoryStore(backing:memory), reader = GateReader()
  let service = NativeHistoryImportService(paths:paths,store:store,reader:reader)
  let request = Task { try await service.prepare(origin:.currentXDG) }
  for _ in 0..<1000 { if await reader.entered { break }; try await Task.sleep(for:.milliseconds(2)) }
  let entered = await reader.entered; try check(entered,"read suspended at fixture gate")
  request.cancel(); await reader.release()
  do { _ = try await request.value; throw Failure(message:"cancelled source returned a review") }
  catch is CancellationError {}
  try check(try memory.read() == nil && memory.writes == 0,"late cancelled read cannot initialize or mark history")
  await store.close()
}
@main struct NativeHistoryImportTests {
  static func main() async throws {
    try await parsing(); try await schemaAndPrecedence(); try await failureAndRace()
    try await fileTransactions(); try await discoveryAndReviewedSnapshot(); try await cancelDuringRead()
    print("PASS separate bounded history import, explicit initialization, profile preservation and atomic migration")
  }
}
