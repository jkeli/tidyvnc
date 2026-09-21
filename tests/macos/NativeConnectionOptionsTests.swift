// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool,_ message: String) throws { if try !value() { throw Failure(message:message) } }
final class Memory: NativePreferencesBacking, NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?, count = 0
  init(_ bytes: Data? = nil) { self.bytes = bytes }
  var writes: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { bytes } }
  func write(_ data: Data) throws { lock.withLock { bytes = data; count += 1 } }
  func replace(_ data: Data,expected: Data?) throws {
    try lock.withLock { guard bytes == expected else { throw NativeStorageError.conflict }; bytes = data; count += 1 }
  }
}

func record(_ values: String, profile: Bool = false, schema: Int? = nil) -> Data {
  let body = profile ? "\"profiles\":[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\",\"endpoint\":\"host\",\"settings\":{\(values)}}],\"recentEndpoints\":[]" : "\"values\":{\(values)}"
  return Data("{\"schema\":\(schema ?? (profile ? 7 : 8)),\"revision\":\"00000000-0000-0000-0000-000000000001\",\(body)}".utf8)
}
func stores() async throws {
  for profile in [false,true] {
    for schema in 1...(profile ? 6 : 7) {
      let bytes = record("",profile:profile,schema:schema), memory = Memory(bytes)
      if profile {
        let store = NativeProfileHistoryStore(backing:memory), snapshot = try await store.read()
        try check(try memory.read() == bytes && memory.writes == 0,"legacy profile read preserves bytes")
        var value = snapshot.profiles[0]; value.settings.shared = true; value.settings.reconnectOnError = false
        _ = try await store.upsert(value,expected:snapshot.revision)
        let reopened = try await store.read()
        try check(reopened.profiles[0].settings.shared == true && reopened.profiles[0].settings.reconnectOnError == false,"profile booleans survive explicit upgrade")
        await store.close()
      } else {
        let store = NativePreferencesStore(backing:memory), snapshot = try await store.read()
        try check(try memory.read() == bytes && memory.writes == 0,"legacy defaults read preserves bytes")
        _ = try await store.commit(.init(shared:true,reconnectOnError:false),expected:snapshot.revision)
        let reopened = try await store.read()
        try check(reopened.values.shared == true && reopened.values.reconnectOnError == false,"default booleans survive explicit upgrade")
        await store.close()
      }
      try check((try JSONSerialization.jsonObject(with:memory.read()!) as! [String:Any])["schema"] as? Int == (profile ? 10 : 11),"current schema writer")
    }
    for value in ["\"shared\":null","\"shared\":1","\"reconnectOnError\":\"false\""] {
      let bytes = record(value,profile:profile), memory = Memory(bytes)
      if profile {
        let store = NativeProfileHistoryStore(backing:memory)
        do { _ = try await store.read(); throw Failure(message:"invalid profile boolean accepted") } catch NativeStorageError.corrupt {}
        await store.close()
      } else {
        let store = NativePreferencesStore(backing:memory)
        do { _ = try await store.read(); throw Failure(message:"invalid defaults boolean accepted") } catch NativePreferencesError.corrupt {}
        await store.close()
      }
      try check(try memory.read() == bytes && memory.writes == 0,"invalid record preserved")
    }
    let memory = Memory(record("\"shared\":true",profile:profile,schema:profile ? 6 : 7))
    if profile {
      let store = NativeProfileHistoryStore(backing:memory)
      do { _ = try await store.read(); throw Failure(message:"old profile accepted new field") } catch NativeStorageError.unsupportedFields {}
      await store.close()
    } else {
      let store = NativePreferencesStore(backing:memory)
      do { _ = try await store.read(); throw Failure(message:"old defaults accepted new field") } catch NativePreferencesError.unsupportedFields {}
      await store.close()
    }
  }
  let defaults = try NativePreferences(shared:true,reconnectOnError:false).applying(to:.init())
  let result = try NativeConnectionProfile(name:"Lab",endpoint:"host",settings:.init(shared:false)).applying(to:defaults)
  try check(!result.shared && !result.reconnectOnError && result.sharedSource == .profile && result.reconnectSource == .appDefaults,"profile precedence is independent per field")
  print("PASS strict boolean persistence, schema compatibility and independent precedence")
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"model timeout")
}
@MainActor func wireAndEditor() async throws {
  let runtime = try NativeRuntime()
  var configuration = NativeSessionConfiguration(); configuration.shared = true; configuration.sharedSource = .profile
  let shared = try runtime.makeSession(configuration:configuration), exclusive = try runtime.makeSession()
  let cancelled = NativeConnectionDraft(session:shared); cancelled.reload(); cancelled.shared = false; cancelled.cancel(); cancelled.apply()
  try check(try shared.connectionOptions().shared,"cancelled editor cannot change the next handshake")
  let peers = (0..<3).map { _ in native_test_peer_create_pattern(0)! }; defer { for peer in peers { native_test_peer_destroy(peer) } }
  func address(_ index: Int) -> String { "127.0.0.1::\(native_test_peer_port(peers[index]))" }
  _ = try await shared.connect(endpoint:address(0)); _ = try await exclusive.connect(endpoint:address(1))
  try check(native_test_peer_shared(peers[0]) == 1 && native_test_peer_shared(peers[1]) == 0,"independent real ClientInit shared bytes")
  let active = try shared.connectionOptions()
  do { try shared.setConnectionOptions(shared:false,reconnectOnError:false,expected:active); throw Failure(message:"active options accepted") }
  catch let error as NativeError { try check(error.status == .busy,"connected edit refused") }
  _ = try await shared.disconnect()
  let draft = NativeConnectionDraft(session:shared), stale = NativeConnectionDraft(session:shared)
  draft.reload(); stale.reload(); draft.reconnectOnError = false; draft.apply()
  try check(draft.didApply && draft.baseline?.sharedSource == .profile && draft.baseline?.reconnectSource == .session,"unchanged field retains its source")
  stale.shared = false; stale.apply(); try check(stale.needsReload,"competing revision rejected")
  draft.shared = false; draft.apply(); try check(draft.didApply,"disconnected edit accepted")
  _ = try await shared.connect(endpoint:address(2))
  try check(native_test_peer_shared(peers[2]) == 0 && exclusive.snapshot.state == .connected,"next handshake changes without affecting another window")
  try check(draft.needsReload,"new attempt invalidates draft")
  draft.stop(); stale.stop(); try await shared.close(); try await exclusive.close(); try await runtime.shutdown()
  print("PASS real shared/exclusive wire bytes, source retention, CAS and session isolation")
}
@MainActor func retryPolicy() async throws {
  let runtime = try NativeRuntime(), memory = Memory(), store = NativePreferencesStore(backing:memory)
  let initial = try await store.read(); _ = try await store.commit(.init(reconnectOnError:false),expected:initial.revision)
  let model = ConnectionModel(runtime:runtime,preferences:store,onSession:{ _,_ in })
  try await until { model.session != nil }
  let saved = try await store.read()
  _ = try await store.commit(.init(shared:true,reconnectOnError:true),expected:saved.revision)
  let next = NativeSessionDefaults(runtime:runtime,store:store); next.load(); try await until { !next.isLoading }
  try check(next.session?.initialShared == true && next.session?.reconnectOnErrorEnabled == true && model.session?.reconnectOnErrorEnabled == false,"defaults save affects a new window only")
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  model.endpoint = "127.0.0.1::\(native_test_peer_port(peer))"; model.connect()
  try await until { model.session?.snapshot.state == .connected && !model.busy }
  native_test_peer_disconnect(peer); try await until { model.connectionProblem != nil }
  let problem = model.connectionProblem!
  try check(!model.offersRetryConnection(problem) && !model.canRetryConnection(problem) && model.canConnect,"Retry disabled but manual Connect remains available")
  model.dismissConnectionProblem(problem.id); model.openConnectionOptions()
  try check(model.connectionOptionsDraft != nil && !model.canConnect && !model.canOpenSecurity,"options editor excludes Connect and other settings")
  model.connectionOptionsDraft?.reconnectOnError = true; model.connectionOptionsDraft?.apply()
  try check(model.offersRetryConnection(problem) && memory.writes == 2,"local Retry change never writes defaults")
  model.closeConnectionOptions(); await next.close(); await model.close(); await store.close(); try await runtime.shutdown()
  print("PASS error Retry policy, explicit connection gating and no durable writes")
}
@main struct NativeConnectionOptionsTests {
  @MainActor static func main() async {
    do { try await stores(); try await wireAndEditor(); try await retryPolicy() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
