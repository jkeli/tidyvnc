// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import Darwin
import NativeTestSupport
import TidyVNC
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message: message) }
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message: "Unexpected defaults write") }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
func snapshot(_ reason: NativeEndReason, code: Int32 = 0, state: NativeSessionState = .failed) -> NativeSnapshot {
  var value = abi(tidyvnc_snapshot.self)
  value.generation = 9; value.state = state.rawValue; value.end_reason = reason.rawValue; value.native_error = code
  return NativeSnapshot(value)
}
func classification() throws {
  let expected: [(NativeEndReason, NativeConnectionIssue?)] = [
    (.none,nil),(.cancelled,nil),(.peerClosed,.peerClosed),(.promptTimeout,.promptTimeout),
    (.authenticationRejected,.authenticationRejected),(.transport,.transport),(.protocolFailure,.protocolFailure),
    (.resource,.resource),(.internalFailure,.internalFailure),(.eventOverflow,.resource),
    (.resolution,.resolution),(.connection,.connection),(.resolutionTimeout,.resolutionTimeout),
    (.connectionTimeout,.connectionTimeout),(.unsupportedEndpoint,.unsupportedEndpoint),(.invalidEndpoint,.invalidEndpoint)
  ]
  for (reason, issue) in expected {
    try check(NativeConnectionIssue(snapshot: snapshot(reason)) == issue, "every terminal reason has a safe category")
    try check(NativeConnectionIssue(snapshot: snapshot(reason, state: .connected)) == nil, "nonterminal snapshots do not create alerts")
  }
  for reason in [NativeEndReason.connection, .transport] {
    for code in [EACCES, EPERM] {
      try check(NativeConnectionIssue(snapshot: snapshot(reason, code: code)) == .networkPolicy, "policy suspicion is distinct")
    }
    for code in [ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH] {
      try check(NativeConnectionIssue(snapshot: snapshot(reason, code: code)) == .routing, "routing does not imply privacy denial")
    }
    try check(NativeConnectionIssue(snapshot: snapshot(reason, code: ECONNREFUSED)) == .refused, "refused service")
    try check(NativeConnectionIssue(snapshot: snapshot(reason, code: ETIMEDOUT)) == .connectionTimeout, "socket timeout")
  }
  try check(NativeConnectionIssue(snapshot: snapshot(.resolution, code: EACCES)) == .resolution, "DNS native codes are not socket errno")
  try check(!NativeConnectionIssue.routing.message.contains("Local Network") && NativeConnectionIssue.networkPolicy.message.contains("may"), "permission guidance retains uncertainty")
  let secret = "password=private-secret /Users/private/certificate.pem private-server"
  for status in [NativeStatus.failed, .internalFailure, .unsupported, .invalidArgument, .busy, .queueFull, .resourceLimit, .outOfMemory, .notConnected, .viewOnly] {
    let issue = NativeConnectionIssue(error: NativeError(status, secret))!
    try check(!issue.message.contains("private") && !issue.title.contains("private"), "native error text is never displayed")
  }
  let foreign = NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret])
  try check(NativeConnectionIssue(error: foreign) == .internalFailure, "unknown error safe fallback")
  for status in [NativeStatus.cancelled, .closing, .stale, .notPending] {
    try check(NativeConnectionIssue(error: NativeError(status, secret)) == nil, "benign lifecycle outcomes do not alert")
  }
  try check(NativeConnectionIssue(error: CancellationError()) == nil, "task cancellation silent")
  for (reason, expected) in [(NativeCommandFailure.Reason.timedOut, NativeConnectionIssue.operationTimeout), (.serverRejected,.serverRejected),(.none,.operationFailed)] {
    let failure = NativeCommandFailure(operation: NativeOperation(id: 4, generation: 9), result: .failed,
      reason: reason, nativeResult: 99, snapshot: snapshot(.none, state: .connected))
    try check(NativeConnectionIssue(error: failure) == expected, "command failure is distinct from connection failure")
  }
  for issue in NativeConnectionIssue.allCases {
    try check(!issue.title.isEmpty && !issue.message.isEmpty, "complete native presentation")
  }
  print("PASS every terminal category, errno scope, cancellation, command outcomes and redacted fallback")
}
// Obtain a local ephemeral port using the same fixture strategy as SocketConnector.
// macOS drops SYNs while a bound, non-listening socket is held, so close before dialing.
func refusedSocket() throws -> (Int32, String) {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw Failure(message: "socket failed") }
  var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let named = withUnsafeMutablePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
  }
  guard bound == 0, named == 0 else { Darwin.close(fd); throw Failure(message: "bind failed") }
  return (fd, "127.0.0.1::\(UInt16(bigEndian: address.sin_port))")
}
@MainActor func lifecycle() async throws {
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let model = ConnectionModel(runtime: runtime, preferences: preferences) { _,_ in }
  let other = ConnectionModel(runtime: runtime, preferences: preferences) { _,_ in }
  try await until { model.defaults?.isReady == true && other.defaults?.isReady == true }
  let (fd, endpoint) = try refusedSocket(); Darwin.close(fd)
  model.endpoint = endpoint; model.connect()
  try await until { !model.busy && model.connectionProblem != nil }
  let first = model.connectionProblem!, session = model.session!
  try check(first.issue == .refused && model.message == nil && model.canRetryConnection(first), "real refusal has typed retry: issue=\(first.issue), reason=\(session.snapshot.endReason), errno=\(session.snapshot.nativeCode), state=\(session.snapshot.state), retry=\(model.canRetryConnection(first))")
  try check(other.connectionProblem == nil, "failure scoped to owning window")
  model.endpoint = "127.0.0.1::1"
  let generation = session.generation; model.retryConnection(first)
  try check(!model.busy && session.generation == generation, "edited address cannot reuse old retry")
  model.endpoint = endpoint
  model.hideConnectionProblem(first.id) // SwiftUI may do this before the button.
  model.retryConnection(first)
  try check(model.busy, "retry survives automatic alert dismissal")
  model.retryConnection(first)
  try await until { !model.busy && model.connectionProblem != nil }
  let second = model.connectionProblem!
  try check(second.id != first.id && second.generation == generation + 1, "one explicit retry starts one fresh attempt")
  model.dismissConnectionProblem(first.id); model.retryConnection(first)
  try check(model.connectionProblem?.id == second.id && !model.busy, "old dismissal/retry cannot affect new failure")
  model.dismissConnectionProblem(second.id); model.retryConnection(second)
  try check(model.connectionProblem == nil && !model.busy, "Cancel revokes retry")

  var peer: UnsafeMutableRawPointer? = native_test_peer_create_pattern(0)!
  defer { if let peer { native_test_peer_destroy(peer) } }
  model.endpoint = "127.0.0.1::\(native_test_peer_port(peer))"; model.connect()
  try await until { !model.busy && session.snapshot.state == .connected && session.frame != nil }
  try check(model.connectionProblem == nil, "new successful attempt clears error")
  native_test_peer_destroy(peer); peer = nil
  try await until { model.connectionProblem != nil }
  let interrupted = model.connectionProblem!
  try check([.peerClosed,.transport].contains(interrupted.issue) && model.canRetryConnection(interrupted), "unsolicited disconnect produces reconnect action")
  let stoppedGeneration = session.generation
  try await Task.sleep(for: .milliseconds(30))
  try check(session.generation == stoppedGeneration && !model.busy, "no automatic reconnect")
  model.requestClose(); model.retryConnection(interrupted)
  try check(model.connectionProblem == nil && !model.busy && !model.canRetryConnection(interrupted), "close revokes pending retry")

  let authPeer = native_test_peer_create_pattern(1)!
  defer { native_test_peer_destroy(authPeer) }
  other.endpoint = "127.0.0.1::\(native_test_peer_port(authPeer))"; other.connect()
  try await until { other.session?.prompt != nil }
  other.cancel(); try await until { !other.busy }
  try check(other.connectionProblem == nil && other.message == nil, "authentication cancellation stays silent")
  let finalPeer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(finalPeer) }
  other.endpoint = "127.0.0.1::\(native_test_peer_port(finalPeer))"; other.connect()
  try await until { !other.busy && other.session?.snapshot.state == .connected }
  other.disconnect(); try await until { !other.busy }
  try check(other.connectionProblem == nil && other.message == nil, "requested disconnect stays silent")
  await model.close(); await other.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS real refused connections, retry identity/generation, edited address, window isolation, remote close, cancel and shutdown")
}
@main struct NativeConnectionIssueTests {
  @MainActor static func main() async {
    do { try classification(); try await lifecycle() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
