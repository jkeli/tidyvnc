// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
func reject(_ expected: NativeDocumentSaveError, _ action: @Sendable () async throws -> Void) async throws {
  do { try await action(); throw Failure(message:"Unsafe save accepted") }
  catch let error as NativeDocumentSaveError { try check(error == expected,"typed save error") }
}
func contents(_ url: URL) throws -> Data { try Data(contentsOf:url) }
func scratch() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-save-"+UUID().uuidString,isDirectory:true)
  try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
  return url
}
func noTemporary(_ root: URL) throws {
  let names = try FileManager.default.contentsOfDirectory(atPath:root.path)
  try check(!names.contains(where: { $0.hasPrefix(".tidyvnc-export-") }),"temporary files removed")
}
func fileSafety() async throws {
  let root = try scratch(); defer { try? FileManager.default.removeItem(at:root) }
  let url = root.appendingPathComponent("Connection.tidyvnc"), writer = NativeDocumentFileWriter()
  let export = try NativeDocumentExport(endpoint:"save.invalid",configuration:.init()), bytes = try export.serializedData(acknowledging:export.losses)
  let fresh = try await writer.prepare(url)
  try check(!fresh.exists && !FileManager.default.fileExists(atPath:url.path),"prepare is read-only")
  do { try await writer.write(export,acknowledging:[],to:fresh,overwrite:false); throw Failure(message:"Loss review bypassed") }
  catch let error as NativeDocumentExportError { try check(error == .reviewRequired,"writer enforces loss acknowledgement") }
  try noTemporary(root)
  try await writer.write(export,acknowledging:export.losses,to:fresh,overwrite:false)
  let actual = try contents(url)
  try check(actual == bytes,"exact preflighted output")
  var mode = stat(); try check(lstat(url.path,&mode) == 0 && mode.st_mode & 0o777 == 0o600,"private output permissions")
  let original = Data("original".utf8); try original.write(to:url)
  try check(chmod(url.path,0o644) == 0,"shared-permission fixture")
  let existing = try await writer.prepare(url)
  try await reject(.overwriteRequired) { try await writer.write(export,acknowledging:export.losses,to:existing,overwrite:false) }
  try check(tryOriginal(url) == original,"unapproved overwrite preserved")
  try await writer.write(export,acknowledging:export.losses,to:existing,overwrite:true)
  try check(tryOriginal(url) == bytes,"explicit overwrite succeeds")
  try check(lstat(url.path,&mode) == 0 && mode.st_mode & 0o777 == 0o600,"replacement removes public permissions")
  let fd = Darwin.open(url.path,O_RDONLY); defer { if fd >= 0 { Darwin.close(fd) } }
  if let acl = acl_get_fd_np(fd,ACL_TYPE_EXTENDED) {
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    try check(acl_get_entry(acl,Int32(ACL_FIRST_ENTRY.rawValue),&entry) == -1 && errno == EINVAL,"output ACL empty")
  } else { try check(errno == ENOENT,"output ACL absent") }
  try await reject(.changed) { try await writer.write(export,acknowledging:export.losses,to:fresh,overwrite:true) }
  let baseline = try await writer.prepare(url)
  try Data("concurrent edit".utf8).write(to:url)
  try await reject(.changed) { try await writer.write(export,acknowledging:export.losses,to:baseline,overwrite:true) }
  try check(tryOriginal(url) == Data("concurrent edit".utf8),"concurrent edit preserved")
  let other = NativeDocumentFileWriter()
  try await reject(.changed) { try await other.write(export,acknowledging:export.losses,to:baseline,overwrite:true) }
  let linked = root.appendingPathComponent("Link.tidyvnc")
  try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:url)
  try await reject(.invalidDestination) { _ = try await writer.prepare(linked) }
  let fifo = root.appendingPathComponent("Pipe.tidyvnc")
  try check(mkfifo(fifo.path,0o600) == 0,"FIFO fixture")
  try await reject(.invalidDestination) { _ = try await writer.prepare(fifo) }
  let directory = root.appendingPathComponent("Folder.tidyvnc")
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
  try await reject(.invalidDestination) { _ = try await writer.prepare(directory) }
  let hard = root.appendingPathComponent("Hard.tidyvnc")
  try FileManager.default.linkItem(at:url,to:hard)
  try await reject(.invalidDestination) { _ = try await writer.prepare(hard) }
  try FileManager.default.removeItem(at:hard)
  try check(chmod(url.path,0o400) == 0,"read-only fixture")
  try await reject(.denied) { _ = try await writer.prepare(url) }
  try check(chmod(url.path,0o600) == 0,"restore fixture")
  try await reject(.invalidDestination) { _ = try await writer.prepare(root.appendingPathComponent("Wrong.txt")) }
  try await reject(.invalidDestination) { _ = try await writer.prepare(URL(string:"https://example.invalid/Connection.tidyvnc")!) }
  let parent = root.appendingPathComponent("Parent",isDirectory:true)
  try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false)
  let movedTarget = try await writer.prepare(parent.appendingPathComponent("New.tidyvnc"))
  try FileManager.default.moveItem(at:parent,to:root.appendingPathComponent("Old",isDirectory:true))
  try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false)
  try await reject(.changed) { try await writer.write(export,acknowledging:export.losses,to:movedTarget,overwrite:false) }
  try noTemporary(root)
}
func tryOriginal(_ url: URL) -> Data? { try? contents(url) }
func failures() async throws {
  let root = try scratch(); defer { try? FileManager.default.removeItem(at:root) }
  let url = root.appendingPathComponent("Connection.tidyvnc"), original = Data("before".utf8)
  let export = try NativeDocumentExport(endpoint:"after.invalid",configuration:.init())
  for afterCommit in [false,true] {
    try original.write(to:url)
    let writer = NativeDocumentFileWriter { phase,_ in
      switch phase {
      case .written where !afterCommit: throw NativeDocumentSaveError.writeFailed
      case .didReplace where afterCommit: throw NativeDocumentSaveError.writeFailed
      default: break
      }
    }
    let target = try await writer.prepare(url)
    try await reject(afterCommit ? .committedUncertain : .writeFailed) { try await writer.write(export,acknowledging:export.losses,to:target,overwrite:true) }
    let expected = afterCommit ? try export.serializedData(acknowledging:export.losses) : original
    try check(tryOriginal(url) == expected,"failure reports actual commit boundary")
    try noTemporary(root)
  }
  try original.write(to:url)
  let racing = NativeDocumentFileWriter { phase,url in
    if case .willReplace = phase { try Data("intervening".utf8).write(to:url) }
  }
  let target = try await racing.prepare(url)
  try await reject(.changed) { try await racing.write(export,acknowledging:export.losses,to:target,overwrite:true) }
  try check(tryOriginal(url) == Data("intervening".utf8),"last precommit metadata check")
  try noTemporary(root)
}
final class Gate: @unchecked Sendable {
  private let lock = NSLock(), released = DispatchSemaphore(value:0)
  private var entered = false
  var reached: Bool { lock.lock(); defer { lock.unlock() }; return entered }
  func wait() throws {
    lock.lock(); entered = true; lock.unlock()
    guard released.wait(timeout:.now()+10) == .success else { throw Failure(message:"Gate timed out") }
  }
  func release() { released.signal() }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Timed out")
}
@MainActor func cancellation() async throws {
  let root = try scratch(); defer { try? FileManager.default.removeItem(at:root) }
  let url = root.appendingPathComponent("Connection.tidyvnc"), original = Data("before".utf8)
  let export = try NativeDocumentExport(endpoint:"after.invalid",configuration:.init())
  for afterCommit in [false,true] {
    try original.write(to:url)
    let gate = Gate()
    let writer = NativeDocumentFileWriter { phase,_ in
      switch phase {
      case .willReplace where !afterCommit, .didReplace where afterCommit: try gate.wait()
      default: break
      }
    }
    let target = try await writer.prepare(url)
    let task = Task { try await writer.write(export,acknowledging:export.losses,to:target,overwrite:true) }
    try await until { gate.reached }
    if !afterCommit {
      let competing = NativeDocumentFileWriter(), competingTarget = try await competing.prepare(root.appendingPathComponent("Other.tidyvnc"))
      try await reject(.busy) { try await competing.write(export,acknowledging:export.losses,to:competingTarget,overwrite:false) }
    }
    task.cancel(); gate.release()
    if afterCommit { try await task.value }
    else {
      do { try await task.value; throw Failure(message:"Cancelled save committed") }
      catch is CancellationError {}
    }
    let expected = afterCommit ? try export.serializedData(acknowledging:export.losses) : original
    try check(tryOriginal(url) == expected,"cancellation respects commit boundary")
    try noTemporary(root)
  }
}
@MainActor func lifecycle() async throws {
  _ = NSApplication.shared
  let root = try scratch(); defer { try? FileManager.default.removeItem(at:root) }
  let url = root.appendingPathComponent("Connection.tidyvnc")
  let state = NativeDocumentSaveState(), export = try NativeDocumentExport(endpoint:"review.invalid",configuration:.init())
  try check(state.begin(export) && state.review?.id == export.id,"begin review")
  state.approve(UUID()); state.choose(url,id:export.id,overwrite:false)
  try check(state.review != nil && !state.isWriting && !FileManager.default.fileExists(atPath:url.path),"stale approval and early picker callback ignored")
  state.cancel(export.id); try check(!state.hasPending,"cancel review")
  try check(state.begin(export),"begin again"); state.approve(export.id)
  state.choose(url,id:UUID(),overwrite:false); try check(state.choosing == export.id,"stale picker ignored")
  state.cancel(export.id); try check(!state.hasPending,"cancel picker")
  try check(state.begin(export),"begin accepted save"); state.approve(export.id); state.choose(url,id:export.id,overwrite:false)
  try await until { !state.hasPending }
  try check(state.savedURL == url && state.issue == nil,"save result")
  let saved = try NativeDocumentResolution(document:NativeConnectionDocument(data:contents(url)))
  try check(saved.endpoint == "review.invalid","reviewed snapshot written")
  state.dismissResult(); try check(state.savedURL == nil,"dismiss result")
  let gate = Gate(), blocking = NativeDocumentFileWriter { phase,_ in if case .willReplace = phase { try gate.wait() } }
  let closing = NativeDocumentSaveState(writer:blocking), newURL = root.appendingPathComponent("Cancelled.tidyvnc")
  try check(closing.begin(export),"begin closing fixture"); closing.approve(export.id); closing.choose(newURL,id:export.id,overwrite:false)
  try await until { gate.reached }; closing.stop(); gate.release(); await closing.close()
  try check(!closing.hasPending && closing.savedURL == nil && closing.issue == nil && !FileManager.default.fileExists(atPath:newURL.path),"close cancels and joins writer without late result")
  try check(!closing.begin(export),"closed state cannot reopen")
  await state.close(); try noTemporary(root)
  let view = NSHostingView(rootView:DocumentExportView(export:export,approve:{},cancel:{}))
  view.frame = CGRect(x:0,y:0,width:560,height:440); view.layoutSubtreeIfNeeded()
  try check(view.fittingSize.width >= 560 && view.fittingSize.height > 100,"native export review lays out")
}
@main struct NativeDocumentSaveTests {
  @MainActor static func main() async throws {
    try await fileSafety(); try await failures(); try await cancellation(); try await lifecycle()
    print("PASS atomic private save, overwrite conflicts, failure/cancellation boundaries and review lifecycle")
  }
}
