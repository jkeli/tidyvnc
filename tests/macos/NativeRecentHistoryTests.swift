// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(message: message) } }
final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
@MainActor func until(_ label: String, _ condition: () -> Bool) async throws {
  for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out: \(label)")
}
@MainActor func editAndRecovery() async throws {
  let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing), model = NativeRecentHistory(store: store)
  model.reload(); try await until("initial read") { !model.isBusy }
  try check(model.hasLoaded && model.endpoints.isEmpty && backing.writes == 0, "initial read does not write")
  model.recordSuccessful("first"); model.recordSuccessful("second")
  try await until("records saved") { !model.isBusy }
  try check(model.endpoints == ["second", "first"], "success order is shared newest-first")
  let before = try await store.read()
  let profile = NativeConnectionProfile(name: "Keep", endpoint: "profile-host")
  let changed = try await store.upsert(profile, expected: before.revision)
  model.remove("first"); try await until("stale removal") { !model.isBusy }
  try check(model.error == .conflict && !model.canEdit, "observed stale removal requires reload")
  model.reload(); try await until("conflict reload") { !model.isBusy }
  try check(model.endpoints.contains("first"), "reload never replays destructive removal")
  model.remove("first"); try await until("remove") { !model.isBusy }
  try check(model.endpoints == ["second"], "individual removal")
  model.clear(); try await until("clear") { !model.isBusy }
  let cleared = try await store.read()
  try check(cleared.profiles == changed.profiles && model.endpoints.isEmpty, "clear recent list preserves profiles")
  backing.fail(afterWrite: true)
  model.recordSuccessful("accepted"); try await until("uncertain update") { !model.isBusy }
  try check(model.error == .ioFailure && !model.canEdit, "unconfirmed save blocks edits")
  let accepted = try await store.read()
  try check(accepted.recentEndpoints == ["accepted"], "accepted failure has persisted result")
  let count = backing.writes
  try await Task.sleep(for: .milliseconds(20)); try check(backing.writes == count, "failure never automatically retries")
  backing.fail(); model.reload(); try await until("reconciled retry") { !model.isBusy }
  try check(model.error == nil && model.endpoints == ["accepted"], "explicit reload reconciles and deduplicates retry")
  backing.fail(read: .futureSchema); model.reload(); try await until("future data") { !model.isBusy }
  try check(model.error == .futureSchema && model.endpoints.isEmpty && !model.hasLoaded, "future/corrupt read never presents cached entries as current")
  await model.close(); await store.close()
  print("PASS no-write read, recent ordering/removal/clear, profile isolation, conflict and uncertain-save recovery")
}
@MainActor func queueAndLifetime() async throws {
  let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing), gate = HistoryGate()
  let model = NativeRecentHistory(store: store)
  backing.gate(write: gate); model.recordSuccessful("initial")
  try await until("held history write") { gate.isEntered }
  for index in 0..<30 { model.recordSuccessful("host\(index)") }
  model.recordSuccessful("host15")
  for _ in 0..<20 { model.reload() }
  try check(model.isBusy && !model.canEdit && backing.writes == 1, "one in-flight update with bounded coalescing")
  gate.release(); try await until("queued history") { !model.isBusy }
  try check(backing.writes == 21 && model.endpoints.count == 20 && model.endpoints.first == "host15" && !model.endpoints.contains("host9"), "only latest 20 pending successes survive, duplicate recency preserved")
  await model.close(); await store.close()
  let secondBacking = HistoryBacking(), secondStore = NativeProfileHistoryStore(backing: secondBacking), readGate = HistoryGate()
  let stopping = NativeRecentHistory(store: secondStore)
  secondBacking.gate(read: readGate); stopping.reload()
  try await until("held read") { readGate.isEntered }
  var joined = false
  let join = Task { await stopping.close(); joined = true }
  for _ in 0..<5 { try await Task.sleep(for: .milliseconds(1)) }
  try check(!joined, "MainActor remains responsive while close waits for store")
  readGate.release(); await join.value
  try check(!stopping.hasLoaded && stopping.endpoints.isEmpty, "late read cannot publish after stop")
  stopping.recordSuccessful("after-close"); try check(secondBacking.writes == 0, "stop gates new history writes")
  let writeGate = HistoryGate(), acceptedModel = NativeRecentHistory(store: secondStore)
  secondBacking.gate(write: writeGate); acceptedModel.recordSuccessful("accepted-before-close")
  try await until("accepted save") { writeGate.isEntered }
  var saveJoined = false
  let saveJoin = Task { await acceptedModel.close(); saveJoined = true }
  try await Task.sleep(for: .milliseconds(5)); try check(!saveJoined, "close waits for accepted save")
  writeGate.release(); await saveJoin.value
  let saved = try await secondStore.read()
  try check(saved.recentEndpoints == ["accepted-before-close"] && !acceptedModel.hasLoaded, "accepted save is retained without late model publication")
  let disposalGate = HistoryGate(); secondBacking.gate(read: disposalGate)
  var owner: NativeRecentHistory? = NativeRecentHistory(store: secondStore)
  let reference = WeakReference(owner)
  owner?.reload(); try await until("held disposal") { disposalGate.isEntered }
  owner?.stop(); owner = nil
  try check(reference.value == nil, "pending operation does not retain model")
  disposalGate.release(); await secondStore.close()
  print("PASS latest-only pending bound, coalesced refresh, MainActor progress, late-read suppression and weak disposal")
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message: "Unexpected preferences write") }
}
final class Peer {
  let raw: UnsafeMutableRawPointer
  init(auth: Bool = false) throws {
    guard let raw = native_test_peer_create(auth ? 1 : 0) else { throw Failure(message: "Missing peer") }
    self.raw = raw
  }
  var endpoint: String { "127.0.0.1::\(native_test_peer_port(raw))" }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func connectionRouting() async throws {
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing), history = NativeRecentHistory(store: store)
  let first = ConnectionModel(runtime: runtime, preferences: preferences, history: history) { _, _ in }
  let second = ConnectionModel(runtime: runtime, preferences: preferences, history: history) { _, _ in }
  try await until("session defaults") { first.defaults?.isReady == true && second.defaults?.isReady == true }
  let peer = try Peer(); first.endpoint = peer.endpoint; first.connect()
  try await until("successful connection history") { !first.busy && !history.isBusy && history.endpoints == [peer.endpoint] }
  try check(first.message == nil && first.session?.snapshot.state == .connected, "history independent of successful connection status")
  second.endpoint = "host::99999"; second.connect(); try await until("invalid connection") { !second.busy }
  try check(history.endpoints == [peer.endpoint], "failed endpoint never enters history")
  let auth = try Peer(auth: true); second.endpoint = auth.endpoint; second.connect()
  try await until("authentication") { second.session?.prompt != nil }
  second.cancel(); try await until("cancelled connection") { !second.busy }
  try check(history.endpoints == [peer.endpoint], "cancelled authentication never enters history")
  backing.fail(write: .denied)
  let next = try Peer(); second.endpoint = next.endpoint; second.connect()
  try await until("history failure") { !second.busy && !history.isBusy && history.error != nil }
  try check(second.session?.snapshot.state == .connected && second.message == nil && history.error == .denied, "history error never fails live connection")
  backing.fail(); history.reload(); try await until("history retry") { !history.isBusy }
  try check(history.endpoints.first == next.endpoint && first.endpoint == peer.endpoint, "shared history does not mutate another connection field")
  await first.close(); await second.close(); await history.close(); await store.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS actual controllers: successful-only recording, failed/cancelled exclusion, two-window isolation and nonfatal history failure")
}
@main struct NativeRecentHistoryTests {
  @MainActor static func main() async {
    do { try await editAndRecovery(); try await queueAndLifetime(); try await connectionRouting() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
