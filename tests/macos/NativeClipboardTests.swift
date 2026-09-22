// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message: message) }
}
@MainActor func until(_ message: String, _ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out: \(message)")
}
final class Peer {
  let raw: UnsafeMutableRawPointer
  init(reconnecting: Bool = false) { raw = reconnecting ? native_test_peer_create_reconnecting(0)! : native_test_peer_create(0)! }
  var endpoint: String { "127.0.0.1::\(native_test_peer_port(raw))" }
  func count(_ bytes: [UInt8]) -> UInt32 {
    bytes.withUnsafeBufferPointer { native_test_peer_count_clipboard(raw, $0.baseAddress, UInt32($0.count)) }
  }
  func count(_ text: String) -> UInt32 { count(Array(text.utf8)) }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor final class FakePasteboard: NativePasteboardAccess {
  var changeCount = 1, reads = 0, writes = 0
  var content = NativePasteboardContent.unavailable
  var readError: NativePasteboardError?, writeError: NativePasteboardError?
  var racingWrite: String?
  var suspendRead = false
  var readContinuation: CheckedContinuation<Void, Never>?
  func resumeRead() { suspendRead = false; readContinuation?.resume(); readContinuation = nil }
  func currentChange() -> Int { changeCount }
  func read(expectedChange: Int, maximumBytes: Int) async throws -> NativePasteboardContent {
    reads += 1
    if expectedChange != changeCount { throw NativePasteboardError.changed }
    let snapshot = content
    if suspendRead { await withCheckedContinuation { readContinuation = $0 } }
    if let readError { throw readError }
    return snapshot
  }
  func writeRemote(_ text: String, maximumBytes: Int) throws -> Int {
    writes += 1
    if let value = racingWrite { racingWrite = nil; local(value); throw NativePasteboardError.changed }
    if let writeError { throw writeError }
    changeCount += 1; content = .remote; return changeCount
  }
  func local(_ text: String) { content = .text(text); changeCount += 1 }
}
@MainActor func configuration() -> NativeSessionConfiguration {
  var value = NativeSessionConfiguration(); value.securityTypes = [1]; return value
}
@MainActor func adapterContract() async throws {
  let board = NSPasteboard(name: NSPasteboard.Name("io.github.jkeli.tidyvnc.tests.\(UUID().uuidString)"))
  defer { board.releaseGlobally() }
  let adapter = NativePasteboard(board)
  board.clearContents(); board.setString("local\r\ntext", forType: .string)
  let old = board.changeCount
  let snapshot1 = try await adapter.read(expectedChange: old, maximumBytes: 32)
  try check(snapshot1 == .text("local\r\ntext"), "local plain text snapshot")
  _ = try await adapter.writeRemote("remote\ntext", maximumBytes: 32)
  try check(board.string(forType: .string) == "remote\ntext", "real isolated pasteboard remote write")
  let snapshot2 = try await adapter.read(expectedChange: board.changeCount, maximumBytes: 32)
  try check(snapshot2 == .remote, "remote marker suppresses echo")
  do { _ = try await adapter.read(expectedChange: old, maximumBytes: 32); throw Failure(message: "stale read accepted") }
  catch NativePasteboardError.changed {}
  board.clearContents(); board.setString("", forType: .string)
  let snapshot3 = try await adapter.read(expectedChange: board.changeCount, maximumBytes: 1)
  try check(snapshot3 == .text(""), "empty text is distinct from unavailable")
  board.clearContents(); board.setString("éé", forType: .string)
  do { _ = try await adapter.read(expectedChange: board.changeCount, maximumBytes: 3); throw Failure(message: "UTF-8 byte limit ignored") }
  catch NativePasteboardError.tooLarge {}
  let count = board.changeCount
  do { _ = try await adapter.writeRemote("a\0b", maximumBytes: 32); throw Failure(message: "NUL accepted") }
  catch NativePasteboardError.invalidText {}
  try check(board.changeCount == count, "invalid write preserves existing contents")
  board.clearContents(); board.setData(Data([1,2,3]), forType: .png)
  let snapshot4 = try await adapter.read(expectedChange: board.changeCount, maximumBytes: 32)
  try check(snapshot4 == .unavailable, "non-text format remains local")
  print("PASS isolated NSPasteboard formats, provenance, byte limits, stale reads and non-destructive validation")
}
@MainActor func routedPasteboard() async throws {
  let board = NSPasteboard(name: NSPasteboard.Name("io.github.jkeli.tidyvnc.tests.\(UUID().uuidString)"))
  defer { board.releaseGlobally() }
  let worker = PasteboardWorker(board)
  func local(_ text: String) async throws {
    _ = try await worker.perform { board in board.clearContents(); return board.setString(text,forType:.string) }
  }
  func text() async throws -> String? { try await worker.perform { $0.string(forType:.string) } }
  func change() async throws -> Int { try await worker.perform { $0.changeCount } }
  func waitForText(_ expected: String) async throws {
    for _ in 0..<1000 {
      if try await text() == expected { return }
      try await Task.sleep(for:.milliseconds(2))
    }
    throw Failure(message:"Timed out waiting for serialized pasteboard text")
  }
  try await local("alpha")
  let coordinator = NativeClipboardCoordinator(pasteboard: NativePasteboard(worker:worker), automaticPolling: false)
  defer { coordinator.stop() }
  let runtime = try NativeRuntime(), first = try runtime.makeSession(configuration: configuration()), second = try runtime.makeSession(configuration: configuration())
  let a = Peer(), b = Peer()
  _ = try await first.connect(endpoint: a.endpoint); _ = try await second.connect(endpoint: b.endpoint)
  try first.setFocused(false); try second.setFocused(false)
  var errors: [String] = []
  coordinator.register(first) { if let value = $0 { errors.append(value) } }
  coordinator.register(second) { if let value = $0 { errors.append(value) } }
  coordinator.poll(); try await Task.sleep(for: .milliseconds(20))
  try check(a.count("alpha") == 0 && b.count("alpha") == 0, "no unfocused sends")
  try first.setFocused(true); coordinator.poll()
  try await until("first local clipboard wire") { a.count("alpha") == 1 }
  coordinator.poll(); coordinator.poll(); try await Task.sleep(for: .milliseconds(20))
  try check(a.count("alpha") == 1 && b.count("alpha") == 0, "unchanged board sent once to one session")
  native_test_peer_clipboard(a.raw)
  try await waitForText("café\n")
  let remoteCount = try await change()
  try first.setFocused(false); try second.setFocused(true); coordinator.poll()
  try await Task.sleep(for: .milliseconds(30))
  try check(b.count([99,97,102,233,10]) == 0, "remote provenance survives cross-session focus change")
  try await local("beta"); coordinator.poll()
  try await until("second local clipboard wire") { b.count("beta") == 1 }
  let betaChange = try await change()
  try check(a.count("beta") == 0 && betaChange > remoteCount, "new local copy routes to second only")
  try second.setClipboardPolicy(send: false, receive: true)
  try await local("blocked"); coordinator.poll()
  try await Task.sleep(for: .milliseconds(30)); try check(b.count("blocked") == 0, "send disabled independently")
  native_test_peer_clipboard(b.raw)
  try await waitForText("café\n")
  try second.setClipboardPolicy(send: true, receive: false)
  try await local("gamma"); coordinator.poll()
  try await until("send while receive disabled") { b.count("gamma") == 1 }
  native_test_peer_clipboard(b.raw); try await Task.sleep(for: .milliseconds(40))
  let gamma = try await text()
  try check(gamma == "gamma", "receive disabled preserves board")
  try first.setFocused(true)
  try await local("ambiguous"); coordinator.poll()
  try await Task.sleep(for: .milliseconds(30))
  try check(a.count("ambiguous") == 0 && b.count("ambiguous") == 0, "ambiguous focus sends to neither session")
  try first.setFocused(false); try second.setViewOnly(true)
  try await local("view-only"); coordinator.poll()
  native_test_peer_clipboard(b.raw); try await Task.sleep(for: .milliseconds(30))
  let viewOnly = try await text()
  try check(b.count("view-only") == 0 && viewOnly == "view-only", "view-only blocks both native directions")
  try second.setViewOnly(false)
  coordinator.setApplicationActive(false)
  try await local("background"); coordinator.poll()
  try await Task.sleep(for: .milliseconds(30)); try check(b.count("background") == 0 && !second.isFocused, "app deactivation invalidates input routing")
  coordinator.setApplicationActive(true); try second.setFocused(true)
  try await local("cancel-before-admission"); coordinator.poll()
  try second.setFocused(false); coordinator.poll()
  try await Task.sleep(for: .milliseconds(30)); try check(b.count("cancel-before-admission") == 0, "queued host work rejects lost focus")
  coordinator.unregister(first); coordinator.unregister(second); await coordinator.close()
  try await runtime.shutdown(); try check(errors.isEmpty, "no clipboard errors")
  print("PASS real NSPasteboard and two-session wire routing, directions, origin suppression, activation and queued focus loss")
}
@MainActor func fakeFailuresAndCoalescing() async throws {
  let board = FakePasteboard(), runtime = try NativeRuntime(), peer = Peer()
  let session = try runtime.makeSession(configuration: configuration())
  _ = try await session.connect(endpoint: peer.endpoint); try session.setFocused(true)
  let coordinator = NativeClipboardCoordinator(pasteboard: board, automaticPolling: false)
  var messages: [String] = []
  coordinator.register(session) { if let value = $0 { messages.append(value) } }
  for index in 0..<100 { board.local("value-\(index)"); coordinator.poll() }
  try await until("coalesced latest value") { peer.count("value-99") == 1 }
  try check(peer.count("value-0") == 0 && peer.count("value-98") == 0, "one queued latest value survives a burst")
  let beforeFocusInterval = board.reads
  try session.setFocused(false); try session.setFocused(true)
  try await until("focus interval resampled") { board.reads > beforeFocusInterval }
  board.readError = .changed; board.local("retry"); coordinator.poll()
  board.readError = nil; coordinator.poll()
  try await until("changed read retry") { peer.count("retry") == 1 }
  board.readError = .unavailable; board.local("never sent"); coordinator.poll()
  try await until("read error status") { !messages.isEmpty }
  try check(peer.count("never sent") == 0 && !messages.joined().contains("never sent"), "read failure redacts payload")
  board.readError = nil; board.writeError = .writeFailed
  native_test_peer_clipboard(peer.raw)
  try await until("write error status") { messages.contains { $0.contains("written") } }
  try check(session.snapshot.state == .connected, "pasteboard failure preserves live connection")
  board.writeError = nil; board.racingWrite = "external-copy"
  let failures = messages.count, priorWrites = board.writes
  native_test_peer_clipboard(peer.raw)
  try await until("concurrent native writer") { board.writes > priorWrites }
  coordinator.poll()
  try await until("external copy survives write race") { peer.count("external-copy") == 1 }
  try check(messages.count == failures, "ordinary ownership change is retried without a failure alert")
  let reads = board.reads, writes = board.writes
  coordinator.stop(); board.local("stopped"); coordinator.poll(); native_test_peer_clipboard(peer.raw)
  try await Task.sleep(for: .milliseconds(30))
  try check(board.reads == reads && board.writes == writes, "stopped coordinator performs no native access")
  board.writeError = nil; board.content = .unavailable; board.changeCount += 1
  let replacement = NativeClipboardCoordinator(pasteboard: board, automaticPolling: false)
  replacement.register(session); replacement.poll()
  try await Task.sleep(for: .milliseconds(20))
  try check(board.writes == writes, "new coordinator never replays cached remote text over a newer native copy")
  await replacement.close(); await coordinator.close()
  try await runtime.shutdown()
  print("PASS coalescing, changed-read retry, read/write failure, redaction and stopped-service cleanup")
}
final class WeakReference<T: AnyObject> {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}
@MainActor func automaticObservationAndLifetime() async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession(configuration: configuration()), peer = Peer()
  let board = FakePasteboard()
  _ = try await session.connect(endpoint: peer.endpoint); try session.setFocused(true)
  var coordinator: NativeClipboardCoordinator? = NativeClipboardCoordinator(pasteboard: board)
  coordinator!.register(session)
  try await until("initial observation") { board.reads == 1 }
  board.local("automatic")
  try await until("automatic clipboard observation") { peer.count("automatic") == 1 }
  let held = WeakReference(coordinator)
  coordinator = nil
  try await until("coordinator disposal without explicit stop") { held.value == nil }
  let reads = board.reads; board.local("after-disposal")
  try await Task.sleep(for: .milliseconds(300))
  try check(board.reads == reads && peer.count("after-disposal") == 0, "observation task cancelled on disposal")
  try await runtime.shutdown()
  print("PASS automatic observation and weak coordinator disposal without a persistent timer/task")
}
// Exercise the actual serial executor with a blocking operation. The main actor
// must continue, and a cancelled queued operation must never touch the board.
final class WorkerProbe: @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var started = false, queuedRan = false
  func markStarted() { lock.lock(); defer { lock.unlock() }; started = true }
  func markQueued() { lock.lock(); defer { lock.unlock() }; queuedRan = true }
  var state: (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (started, queuedRan) }
}
@MainActor func blockedWorker() async throws {
  let board = NSPasteboard(name: .init("io.github.jkeli.tidyvnc.tests.\(UUID().uuidString)"))
  defer { board.releaseGlobally() }
  let worker = PasteboardWorker(board), probe = WorkerProbe()
  let first = Task {
    try await worker.perform { _ in
      probe.markStarted()
      guard probe.release.wait(timeout: .now() + 5) == .success else { throw Failure(message: "Main actor did not release worker") }
      return Thread.isMainThread
    }
  }
  defer { probe.release.signal() }
  try await until("blocking worker started while MainActor remains responsive") { probe.state.0 }
  let second = Task { try await worker.perform { _ in probe.markQueued(); return 1 } }
  try await Task.sleep(for: .milliseconds(20))
  try check(!probe.state.1, "worker operations are serialized")
  second.cancel(); probe.release.signal()
  let ranOnMain = try await first.value
  try check(!ranOnMain, "blocking pasteboard work runs off main thread")
  do { _ = try await second.value; throw Failure(message: "cancelled queued operation ran") }
  catch is CancellationError {}
  try check(!probe.state.1, "cancelled work never accesses pasteboard")
  print("PASS blocked serial worker leaves MainActor responsive and skips cancelled queued access")
}
@MainActor func delayedReadRouting() async throws {
  let runtime = try NativeRuntime(), peer = Peer(reconnecting: true), otherPeer = Peer()
  let session = try runtime.makeSession(configuration: configuration())
  let other = try runtime.makeSession(configuration: configuration())
  _ = try await session.connect(endpoint: peer.endpoint)
  _ = try await other.connect(endpoint: otherPeer.endpoint)
  try session.setFocused(true); try other.setFocused(false)
  let board = FakePasteboard()
  let coordinator = NativeClipboardCoordinator(pasteboard: board, automaticPolling: false)
  var messages: [String] = []
  coordinator.register(session) { if let message = $0 { messages.append(message) } }
  coordinator.register(other)
  // Each gate simulates an OS read which ignores cancellation until it returns.
  for scenario in 0..<7 {
    try session.setClipboardPolicy(send: true, receive: true)
    try session.setViewOnly(false)
    try other.setFocused(false); try session.setFocused(true)
    await Task.yield()
    let stale = "delayed-\(scenario)"
    board.local(stale); board.suspendRead = true; coordinator.poll()
    try await until("read held open") { board.readContinuation != nil }
    let reads = board.reads
    for _ in 0..<100 { coordinator.poll() }
    switch scenario {
    case 0: board.local("replacement")
    case 1: try session.setFocused(false); try other.setFocused(true)
    case 2: try session.setClipboardPolicy(send: false, receive: true)
    case 3: try session.setViewOnly(true)
    case 4: coordinator.setApplicationActive(false)
    case 5:
      _ = try await session.disconnect()
      _ = try await session.connect(endpoint: peer.endpoint)
      try session.setFocused(true)
    default: coordinator.stop()
    }
    // Change the board in focus/policy cases too, so any fresh eligible read is
    // distinguishable from leaking the old result after cancellation.
    if scenario != 0 { board.local("fresh-\(scenario)") }
    for _ in 0..<100 { coordinator.poll() }
    try await Task.sleep(for: .milliseconds(20))
    try check(board.reads == reads, "no overlapping or unbounded reads while stalled")
    board.resumeRead()
    coordinator.poll()
    if scenario == 0 {
      try await until("latest clipboard after delayed read") { peer.count("replacement") == 1 }
    } else if scenario == 1 {
      try await until("new focus receives only fresh copy") { otherPeer.count("fresh-1") == 1 }
    }
    try await Task.sleep(for: .milliseconds(20))
    try check(peer.count(stale) == 0 && otherPeer.count(stale) == 0, "stale clipboard never reaches either server")
    if scenario == 4 { coordinator.setApplicationActive(true) }
  }
  await coordinator.close()
  try check(messages.isEmpty, "discarded reads do not report errors")
  try await runtime.shutdown()
  print("PASS delayed reads coalesce and reject clipboard, focus, policy, view-only, activation, reconnect and stop changes")
}
@main struct NativeClipboardTests {
  @MainActor static func main() async {
    do { try await blockedWorker(); try await adapterContract(); try await delayedReadRouting(); try await routedPasteboard(); try await fakeFailuresAndCoalescing(); try await automaticObservationAndLifetime() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
