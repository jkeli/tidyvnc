// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
import NativeTestSupport
import TidyVNCNative
struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Password-file authentication timed out")
}
@main struct NativePasswordFileTests {
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-password-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    defer { try? FileManager.default.removeItem(at:root) }
    let path = root.appendingPathComponent("private-\u{00e9}.passwd")
    let cipher: [UInt8] = [0xdb,0xd8,0x3c,0xfd,0x72,0x7a,0x14,0x58]
    let reader = NativePasswordFileReader()
    for size in 0..<8 {
      try Data(repeating:0,count:size).write(to:path)
      do { _ = try await reader.read(path); throw Failure(message:"Short file accepted") }
      catch NativePasswordFileIssue.truncated {}
    }
    // A second/view-only block and arbitrary trailing bytes are ignored, matching
    // the retained first-eight-byte read without allocating from file size.
    try Data(cipher+[UInt8](repeating:0x55,count:1_000_000)).write(to:path)
    let selected = try await reader.read(path)
    try check(try selected.copyBytes() == cipher,"owned first block")
    selected.clear()
    do { _ = try selected.copyBytes(); throw Failure(message:"Cleared file block survived") }
    catch NativeCredentialStoreIssue.secretCleared {}
    let link = root.appendingPathComponent("selected-link")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:path)
    let linked = try await reader.read(link)
    try check(try linked.copyBytes() == cipher,"selected symlink compatibility"); linked.clear()
    let pipe = root.appendingPathComponent("pipe")
    try check(mkfifo(pipe.path,0o600) == 0,"FIFO fixture")
    for special in [pipe,root] {
      do { _ = try await reader.read(special); throw Failure(message:"Nonregular password file accepted") }
      catch NativePasswordFileIssue.notRegular {}
    }
    do { _ = try await reader.read(root.appendingPathComponent("missing-private")); throw Failure(message:"Missing file accepted") }
    catch let issue as NativePasswordFileIssue {
      try check(issue == .unreadable && !issue.description.contains("private"),"fixed file error")
    }
    let cancelled = Task { @MainActor in try await reader.read(path) }
    cancelled.cancel()
    do { _ = try await cancelled.value; throw Failure(message:"Cancelled read succeeded") }
    catch NativePasswordFileIssue.cancelled {}

    guard let peer = native_test_peer_create(1) else { throw Failure(message:"Peer fixture failed") }
    defer { native_test_peer_destroy(peer) }
    let runtime = try NativeRuntime()
    var configuration = NativeSessionConfiguration(); configuration.securityTypes = [2]
    let session = try runtime.makeSession(configuration:configuration)
    let connect = Task { try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))") }
    try await until { session.prompt != nil }
    let prompt = session.prompt!
    let block = try await reader.read(path)
    var bytes = try block.copyBytes(); block.clear()
    try session.replyPasswordFile(to:prompt,block:&bytes)
    try check(bytes.allSatisfy { $0 == 0 },"native submitted block cleared")
    _ = try await connect.value
    try check(session.snapshot.state == .connected && native_test_peer_verified(peer) != 0,"real VNC password-file response")
    bytes = cipher
    do { try session.replyPasswordFile(to:prompt,block:&bytes); throw Failure(message:"Repeated file reply accepted") }
    catch let error as NativeError { try check(error.status == .notPending,"repeated reply rejected") }
    try check(bytes.allSatisfy { $0 == 0 },"failed submission cleared")
    try await session.close(); try await runtime.shutdown()
    print("PASS bounded password-file reader, ownership, cancellation and wire authentication")
  }
}
