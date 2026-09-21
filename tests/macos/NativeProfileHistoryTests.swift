// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message: message) }
}
func expect(_ error: NativeStorageError, _ body: () async throws -> Void) async throws {
  do { try await body(); throw Failure(message: "Expected \(error)") }
  catch let actual as NativeStorageError { try check(actual == error, "Got \(actual), expected \(error)") }
}
final class Fixture: @unchecked Sendable {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-profile-tests-" + UUID().uuidString, isDirectory: true)
  var directory: URL { parent.appendingPathComponent("native", isDirectory: true) }
  var file: URL { directory.appendingPathComponent("profiles-history.json") }
  init() throws { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
  deinit { try? FileManager.default.removeItem(at: parent) }
}
func mode(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as! NSNumber).intValue
}
func deferredParentSetup() async throws {
  let fixture = try Fixture()
  let parent = fixture.directory.appendingPathComponent("Application Support", isDirectory: true)
  let root = parent.appendingPathComponent("native", isDirectory: true)
  let backend = try NativePrivateFile(directory: root, prepareParent: true, checkpoint: { _ in })
  try check(try backend.read() == nil && !FileManager.default.fileExists(atPath: parent.path), "missing parent read is side-effect-free")
  try backend.replace(envelope(), expected: nil)
  try check(try mode(parent) == 0o700 && mode(root) == 0o700 && backend.read() == envelope(), "first write creates missing host parent with private mode")
  print("PASS deferred host-parent creation without first-read side effects")
}
func persistenceAndHistory() async throws {
  let fixture = try Fixture(), backend = try NativePrivateFile(directory: fixture.directory)
  let store = NativeProfileHistoryStore(backing: backend)
  var current = try await store.read()
  try check(current.revision == nil && current.profiles.isEmpty && !FileManager.default.fileExists(atPath: fixture.directory.path), "absent read creates no data")
  var encoding = NativeEncodingPreferences(); try encoding.set(.quality, value: "5")
  var profile = NativeConnectionProfile(name: "Lab", endpoint: "HOST:2", settings: NativePreferences(clipboardSend: false, encoding: encoding), credentialReference: UUID())
  current = try await store.upsert(profile, expected: current.revision)
  try check(try mode(fixture.directory) == 0o700 && mode(fixture.file) == 0o600, "private directory and data modes")
  let reopened = NativeProfileHistoryStore(backing: try NativePrivateFile(directory: fixture.directory))
  let fresh = try await reopened.read(), listed = try await reopened.profile(id: profile.id)
  try check(fresh == current && listed == profile, "fresh reopen preserves profile identity and settings")
  let applied = try profile.applying(to: NativeSessionConfiguration())
  try check(try applied.encoding?.value(for: .quality).source == .profile && applied.encoding?.value(for: .compression).source == .compiled && !applied.clipboardSend, "profile-specific provenance")
  let stale = current.revision
  profile.name = "Renamed"; current = try await store.upsert(profile, expected: current.revision)
  try check(current.profiles.count == 1 && current.profiles[0].name == "Renamed", "upsert stable identity")
  try await expect(.conflict) { _ = try await reopened.deleteProfile(id: profile.id, expected: stale) }
  for index in 0..<25 { current = try await store.recordRecent("host\(index)", expected: current.revision) }
  try check(current.recentEndpoints.count == 20 && current.recentEndpoints.first == "host24" && current.recentEndpoints.last == "host5", "bounded newest-first history")
  current = try await store.recordRecent("host10", expected: current.revision)
  try check(current.recentEndpoints.first == "host10" && Set(current.recentEndpoints).count == 20, "deduplicated recent entry")
  current = try await store.removeRecent("host10", expected: current.revision)
  try await expect(.notFound) { _ = try await store.removeRecent("absent", expected: current.revision) }
  current = try await store.clearHistory(expected: current.revision)
  try check(current.recentEndpoints.isEmpty && current.profiles == [profile], "clear history preserves profiles")
  current = try await store.deleteProfile(id: profile.id, expected: current.revision)
  try check(current.profiles.isEmpty && current.revision != nil, "delete preserves non-reusable revision")
  try await expect(.notFound) { _ = try await store.profile(id: profile.id) }
  let cancelled = Task { [revision = current.revision] in withUnsafeCurrentTask { $0?.cancel() }; return try await store.recordRecent("cancelled", expected: revision) }
  try await expect(.cancelled) { _ = try await cancelled.value }
  await store.close(); try await expect(.closed) { _ = try await store.read() }; await reopened.close()
  print("PASS private files, reopen, profile upsert/delete/provenance, bounded history and cancellation")
}
final class Memory: NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?, writeCount = 0
  var writes: Int { lock.withLock { writeCount } }
  init(_ bytes: Data? = nil) { self.bytes = bytes }
  func read() throws -> Data? { lock.withLock { bytes } }
  func replace(_ data: Data, expected: Data?) throws {
    try lock.withLock { guard bytes == expected else { throw NativeStorageError.conflict }; bytes = data; writeCount += 1 }
  }
}
func envelope(_ profiles: String = "[]", history: String = "[]", schema: String = "1") -> Data {
  Data("{\"schema\":\(schema),\"revision\":\"00000000-0000-0000-0000-000000000001\",\"profiles\":\(profiles),\"recentEndpoints\":\(history)}".utf8)
}
func validationAndPreservation() async throws {
  let profile = "{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\",\"endpoint\":\"host\",\"settings\":{}}"
  func withSettings(_ value: String) -> Data { envelope("[" + profile.replacingOccurrences(of: "\"settings\":{}", with: "\"settings\":\(value)") + "]") }
  let cases: [(Data, NativeStorageError)] = [
    (Data("partial".utf8), .corrupt), (envelope(schema: "11"), .futureSchema), (envelope(schema: "true"), .corrupt),
    (withSettings("{\"password\":\"rejected\"}"), .unsupportedFields), (withSettings("{\"clipboardSend\":1}"), .corrupt),
    (withSettings("{\"encoding\":{\"qualityLevel\":100}}"), .invalid), (withSettings("{\"encoding\":{\"qualityLevel\":null}}"), .corrupt),
    (envelope("[\(profile),\(profile)]"), .corrupt), (envelope(history: "[\"host\",\"host\"]"), .corrupt),
    (Data(repeating: 0, count: NativePrivateFile.maximumBytes + 1), .tooLarge)]
  for (bytes, error) in cases {
    let backend = Memory(bytes), store = NativeProfileHistoryStore(backing: backend)
    try await expect(error) { _ = try await store.read() }
    try await expect(error) { _ = try await store.clearHistory(expected: nil) }
    try check(try backend.read() == bytes && backend.writes == 0, "invalid/future bytes preserved")
    await store.close()
  }
  let backend = Memory(), store = NativeProfileHistoryStore(backing: backend)
  var current = try await store.read()
  for index in 0..<NativeProfileHistoryStore.profileCapacity {
    current = try await store.upsert(NativeConnectionProfile(name: "Profile \(index)", endpoint: "host"), expected: current.revision)
  }
  try await expect(.resourceLimit) { _ = try await store.upsert(NativeConnectionProfile(name: "Overflow", endpoint: "host"), expected: current.revision) }
  try await expect(.invalid) { _ = try await store.recordRecent(String(repeating: "x", count: 4097), expected: current.revision) }
  await store.close()
  print("PASS closed schema, unknown/secret fields, strict types, future/corrupt preservation and bounds")
}
func interruptions() async throws {
  for point in [NativePrivateFile.Checkpoint.written, .willReplace, .didReplace] {
    let fixture = try Fixture(), old = Data("old".utf8), new = Data("new".utf8)
    try NativePrivateFile(directory: fixture.directory).replace(old, expected: nil)
    let failed = try NativePrivateFile(directory: fixture.directory) { stage in if stage == point { throw NativeStorageError.ioFailure } }
    try await expect(.ioFailure) { try failed.replace(new, expected: old) }
    try check(try failed.read() == (point == .didReplace ? new : old), "atomic visibility at replacement")
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    try check(!names.contains { $0.hasSuffix(".tmp") }, "failure cleans its temporary file")
  }
  for point in [NativePrivateFile.Checkpoint.willReplace, .didReplace] {
    let fixture = try Fixture(), old = Data("old".utf8), new = Data("new".utf8)
    try NativePrivateFile(directory: fixture.directory).replace(old, expected: nil)
    let backing = try NativePrivateFile(directory: fixture.directory) { stage in
      if stage == point { withUnsafeCurrentTask { $0?.cancel() } }
    }
    let task = Task.detached { try backing.replace(new, expected: old) }
    if point == .willReplace { try await expect(.cancelled) { try await task.value } }
    else { try await task.value }
    try check(try backing.read() == (point == .willReplace ? old : new), "cancellation cannot roll back replacement")
  }
  let fixture = try Fixture(), backing = try NativePrivateFile(directory: fixture.directory)
  try backing.replace(envelope(), expected: nil)
  try Data("partial".utf8).write(to: fixture.directory.appendingPathComponent(".profiles-history.interrupted.tmp"))
  let store = NativeProfileHistoryStore(backing: backing), current = try await store.read()
  try check(current.revision != nil && current.profiles.isEmpty, "orphan temporary file never becomes committed state")
  _ = try await store.recordRecent("recovered", expected: current.revision); await store.close()
  let uncertainFixture = try Fixture(), normal = try NativePrivateFile(directory: uncertainFixture.directory)
  let normalStore = NativeProfileHistoryStore(backing: normal)
  let initial = try await normalStore.recordRecent("old", expected: nil)
  let uncertain = NativeProfileHistoryStore(backing: try NativePrivateFile(directory: uncertainFixture.directory) { point in
    if point == .didReplace { throw NativeStorageError.ioFailure }
  })
  try await expect(.ioFailure) { _ = try await uncertain.recordRecent("accepted", expected: initial.revision) }
  let reconciled = try await normalStore.read()
  try check(reconciled.revision != initial.revision && reconciled.recentEndpoints.first == "accepted", "fresh read reconciles an accepted but unconfirmed store commit")
  try await expect(.conflict) { _ = try await uncertain.clearHistory(expected: initial.revision) }
  await normalStore.close(); await uncertain.close()
  print("PASS interrupted writes, temporary cleanup/orphan isolation and cancellation around commit")
}
final class Gate: @unchecked Sendable {
  private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
  private var entered = false
  var isEntered: Bool { lock.withLock { entered } }
  func hold() throws {
    lock.withLock { entered = true }
    guard signal.wait(timeout: .now() + 5) == .success else { throw NativeStorageError.ioFailure }
  }
  func release() { signal.signal() }
}
func concurrentWriters() async throws {
  let fixture = try Fixture(), gate = Gate(), old = envelope()
  let first = try NativePrivateFile(directory: fixture.directory) { point in if point == .willReplace { try gate.hold() } }
  let other = try NativePrivateFile(directory: fixture.directory)
  let write = Task.detached { try first.replace(old, expected: nil) }
  for _ in 0..<1000 { if gate.isEntered { break }; try await Task.sleep(for: .milliseconds(2)) }
  try check(gate.isEntered, "writer holds commit lock")
  try check(try other.read() == nil, "reader cannot see temporary data")
  try await expect(.busy) { try other.replace(Data("other".utf8), expected: nil) }
  let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  child.arguments = ["--locked-write-probe", fixture.directory.path]
  try child.run(); child.waitUntilExit()
  try check(child.terminationStatus == 0, "a separate process observes the cooperative lock")
  gate.release(); try await write.value
  try await expect(.conflict) { try other.replace(Data("other".utf8), expected: nil) }
  let a = NativeProfileHistoryStore(backing: first), b = NativeProfileHistoryStore(backing: other)
  let initial = try await a.read(), saved = try await b.recordRecent("first", expected: initial.revision)
  try await expect(.conflict) { _ = try await a.recordRecent("stale", expected: initial.revision) }
  try check(try other.read() != old && saved.recentEndpoints == ["first"], "independent stale writer preserves winner")
  await a.close(); await b.close()
  print("PASS cooperative nonblocking lock, atomic read visibility and independent stale writers")
}
func filesystemRefusals() async throws {
  let fixture = try Fixture(), backing = try NativePrivateFile(directory: fixture.directory), original = envelope()
  try backing.replace(original, expected: nil)
  chmod(fixture.file.path, 0o400)
  try check(try backing.read() == original, "private read-only file remains readable")
  try await expect(.denied) { try backing.replace(Data(), expected: original) }
  chmod(fixture.file.path, 0o600); chmod(fixture.directory.path, 0o500)
  try await expect(.denied) { try backing.replace(Data(), expected: original) }
  chmod(fixture.directory.path, 0o700); chmod(fixture.file.path, 0o644)
  try await expect(.denied) { _ = try backing.read() }; chmod(fixture.file.path, 0o600)
  let alias = fixture.parent.appendingPathComponent("alias")
  try check(link(fixture.file.path, alias.path) == 0, "create disposable hard link")
  try await expect(.invalid) { _ = try backing.read() }; unlink(alias.path)
  try FileManager.default.moveItem(at: fixture.file, to: alias)
  try FileManager.default.createSymbolicLink(atPath: fixture.file.path, withDestinationPath: alias.path)
  try await expect(.denied) { _ = try backing.read() }
  try await expect(.denied) { try backing.replace(Data(), expected: original) }
  try check(try Data(contentsOf: alias) == original, "symlink target untouched")
  unlink(fixture.file.path); try FileManager.default.moveItem(at: alias, to: fixture.file)
  let command = Process(); command.executableURL = URL(fileURLWithPath: "/bin/chmod")
  command.arguments = ["+a", "everyone allow read", fixture.file.path]
  try command.run(); command.waitUntilExit(); try check(command.terminationStatus == 0, "install test ACL")
  try await expect(.denied) { _ = try backing.read() }
  let clear = Process(); clear.executableURL = URL(fileURLWithPath: "/bin/chmod"); clear.arguments = ["-N", fixture.file.path]
  try clear.run(); clear.waitUntilExit(); try check(clear.terminationStatus == 0, "remove only test ACL")
  try check(try backing.read() == original, "permission failures preserve bytes")
  let lockFile = fixture.directory.appendingPathComponent(".profiles-history.lock")
  unlink(lockFile.path)
  try FileManager.default.createSymbolicLink(atPath: lockFile.path, withDestinationPath: fixture.file.path)
  try await expect(.denied) { try backing.replace(Data(), expected: original) }
  unlink(lockFile.path)
  try FileManager.default.moveItem(at: fixture.file, to: alias)
  try check(mkfifo(fixture.file.path, 0o600) == 0, "create disposable FIFO")
  try await expect(.invalid) { _ = try backing.read() }
  unlink(fixture.file.path); try FileManager.default.moveItem(at: alias, to: fixture.file)
  let fd = Darwin.open(fixture.file.path, O_WRONLY)
  try check(fd >= 0 && ftruncate(fd, off_t(NativePrivateFile.maximumBytes + 1)) == 0, "create oversized sparse fixture")
  Darwin.close(fd)
  try await expect(.tooLarge) { _ = try backing.read() }
  print("PASS actual read-only/private permissions, hard links, symlinks and extended ACL refusal")
}
@main struct NativeProfileHistoryTests {
  static func main() async {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--locked-write-probe" {
      do {
        let backend = try NativePrivateFile(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        try backend.replace(Data("child probe".utf8), expected: nil)
        exit(2)
      } catch NativeStorageError.busy { exit(0) }
      catch { exit(3) }
    }
    do {
      try await deferredParentSetup(); try await persistenceAndHistory(); try await validationAndPreservation(); try await interruptions()
      try await concurrentWriters(); try await filesystemRefusals()
    } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
