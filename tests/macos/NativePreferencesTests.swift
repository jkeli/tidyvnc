// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw Failure(message: message) }
}
final class Backing: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?, reads = 0, writes = 0
  private var readFailure: NativePreferencesError?, writeFailure: NativePreferencesError?
  private var cancelOnWrite = false, failAfterWrite = false
  func read() throws -> Data? { try lock.withLock { reads += 1; if let readFailure { throw readFailure }; return data } }
  func write(_ value: Data) throws {
    let cancel = try lock.withLock {
      if let writeFailure { throw writeFailure }
      writes += 1; data = value
      if failAfterWrite { throw NativePreferencesError.ioFailure }
      return cancelOnWrite
    }
    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
  }
  func replace(_ value: Data?) { lock.withLock { data = value } }
  func failures(read: NativePreferencesError? = nil, write: NativePreferencesError? = nil) {
    lock.withLock { readFailure = read; writeFailure = write }
  }
  func cancelDuringWrite() { lock.withLock { cancelOnWrite = true } }
  func failAfterAcceptance(_ enabled: Bool) { lock.withLock { failAfterWrite = enabled } }
  var counts: (reads: Int, writes: Int) { lock.withLock { (reads, writes) } }
}
func expect(_ expected: NativePreferencesError, _ operation: () async throws -> Void) async throws {
  do { try await operation(); throw Failure(message: "Expected \(expected)") }
  catch let actual as NativePreferencesError { try check(actual == expected, "typed error \(actual), expected \(expected)") }
}
func record(_ values: String = "{}", schema: String = "1") -> Data {
  Data("{\"schema\":\(schema),\"revision\":\"00000000-0000-0000-0000-000000000001\",\"values\":\(values)}".utf8)
}
func revisionsAndNotifications() async throws {
  let backing = Backing(), store = NativePreferencesStore(backing: backing)
  let initial = try await store.read()
  try check(!initial.isStored && initial.values == NativePreferences() && backing.counts.writes == 0, "missing domain does not create data")
  let stream = try await store.changes()
  var iterator = stream.makeAsyncIterator()
  let first = await iterator.next(); try check(first == initial, "subscription starts with fresh snapshot")
  let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
    for enabled in [true, false] {
      group.addTask {
        do { _ = try await store.commit(NativePreferences(clipboardSend: enabled), expected: initial.revision); return 0 }
        catch NativePreferencesError.conflict { return 1 }
        catch { return 2 }
      }
    }
    var values: [Int] = []; for await value in group { values.append(value) }; return values
  }
  try check(results.sorted() == [0,1] && backing.counts.writes == 1, "one concurrent stale draft wins and the other reports conflict")
  var current = try await store.read()
  try check(current.isStored && current.revision != initial.revision, "first commit gets revision")
  for enabled in [false, true, false] {
    current = try await store.commit(NativePreferences(clipboardSend: enabled, clipboardReceive: !enabled), expected: current.revision)
  }
  let latest = await iterator.next(); try check(latest == current, "slow subscriber receives latest bounded value")
  let reset = try await store.reset(expected: current.revision)
  try check(reset.isStored && reset.values == initial.values && reset.revision != current.revision, "reset persists a fresh empty patch")
  try await expect(.conflict) { _ = try await store.commit(NativePreferences(), expected: initial.revision) }
  backing.replace(record("{\"clipboardSend\":false}"))
  try await expect(.conflict) { _ = try await store.reset(expected: reset.revision) }
  let external = await iterator.next(); try check(external?.values.clipboardSend == false, "observed external revision publishes on conflict")
  backing.replace(nil)
  let newStream = try await store.changes()
  var newIterator = newStream.makeAsyncIterator()
  let refreshed = await iterator.next(), newInitial = await newIterator.next()
  try check(refreshed == initial && newInitial == initial, "subscription's fresh read publishes observed removal to every observer")
  await store.close()
  let terminal = await iterator.next(); try check(terminal == nil, "close finishes subscriptions")
  try await expect(.closed) { _ = try await store.read() }
  print("PASS serialized revision conflicts, reset identity, observed external edits, bounded subscriptions and close")
}
func invalidRecordsAndFailures() async throws {
  let cases: [(Data, NativePreferencesError)] = [
    (Data("broken".utf8), .corrupt), (record(schema: "12"), .futureSchema),
    (record(schema: "true"), .corrupt), (record(schema: "0"), .corrupt),
    (record("{\"password\":\"never accepted\"}"), .unsupportedFields),
    (record("{\"clipboardSend\":1}"), .corrupt), (record("{\"clipboardReceive\":null}"), .corrupt),
    (Data(repeating: 32, count: 65537), .tooLarge)]
  for (bytes, failure) in cases {
    let backing = Backing(); backing.replace(bytes)
    let store = NativePreferencesStore(backing: backing)
    try await expect(failure) { _ = try await store.read() }
    try await expect(failure) { _ = try await store.reset(expected: NativePreferencesRevision(value: nil)) }
    let after = try backing.read()
    try check(after == bytes && backing.counts.writes == 0, "invalid/future record preserved byte-for-byte")
    await store.close()
  }
  let backing = Backing(), store = NativePreferencesStore(backing: backing)
  let initial = try await store.read()
  for failure in [NativePreferencesError.denied, .unavailable, .ioFailure] {
    backing.failures(read: failure)
    try await expect(failure) { _ = try await store.read() }
    backing.failures(write: failure)
    try await expect(failure) { _ = try await store.commit(NativePreferences(clipboardSend: false), expected: initial.revision) }
    try check(backing.counts.writes == 0, "failed backing write never advances revision")
  }
  backing.failures()
  let recovered = try await store.commit(NativePreferences(clipboardReceive: false), expected: initial.revision)
  try check(recovered.values.clipboardReceive == false, "retry after backend recovery")
  backing.failAfterAcceptance(true)
  try await expect(.ioFailure) { _ = try await store.commit(NativePreferences(clipboardSend: false), expected: recovered.revision) }
  backing.failAfterAcceptance(false)
  let reconciled = try await store.read()
  try check(reconciled.revision != recovered.revision && reconciled.values.clipboardSend == false, "uncertain write outcome reconciled by fresh read")
  try await expect(.conflict) { _ = try await store.reset(expected: recovered.revision) }
  await store.close()
  print("PASS corruption/future/unknown fields, strict Boolean typing, payload limits, typed failure and recovery")
}
func cancellationAndCapacity() async throws {
  let backing = Backing(), store = NativePreferencesStore(backing: backing), initial = try await store.read()
  let cancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    try await expect(.cancelled) { _ = try await store.commit(NativePreferences(), expected: initial.revision) }
  }
  try await cancelled.value
  try check(backing.counts.writes == 0, "cancel before admission does not write")
  backing.cancelDuringWrite()
  let committed = Task { () throws -> NativePreferencesSnapshot in
    let result = try await store.commit(NativePreferences(clipboardSend: false), expected: initial.revision)
    try check(Task.isCancelled, "cancellation injected after acceptance")
    return result
  }
  let outcome = try await committed.value
  try check(outcome.isStored && backing.counts.writes == 1, "accepted commit is not reported as rolled back")
  var subscriptions: [AsyncStream<NativePreferencesSnapshot>] = []
  for _ in 0..<64 { subscriptions.append(try await store.changes()) }
  try await expect(.resourceLimit) { _ = try await store.changes() }
  await store.close()
  for stream in subscriptions {
    var iterator = stream.makeAsyncIterator(); _ = await iterator.next()
    let end = await iterator.next(); try check(end == nil, "bounded subscriber closes")
  }
  print("PASS cancellation before/after acceptance and bounded subscriber capacity")
}
final class WeakReference<T: AnyObject> {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}
func subscriptionLifetime() async throws {
  var store: NativePreferencesStore? = NativePreferencesStore(backing: Backing())
  let weakStore = WeakReference(store)
  var streams: [AsyncStream<NativePreferencesSnapshot>] = []
  for _ in 0..<64 { streams.append(try await store!.changes()) }
  streams.removeAll()
  var recovered: AsyncStream<NativePreferencesSnapshot>?
  for _ in 0..<1000 {
    do { recovered = try await store!.changes(); break }
    catch NativePreferencesError.resourceLimit { try await Task.sleep(for: .milliseconds(1)) }
  }
  try check(recovered != nil, "dropped streams return subscriber capacity")
  store = nil
  // Termination schedules bounded actor removals; allow those admitted tasks to
  // drain before checking that the surviving stream has no ownership cycle.
  for _ in 0..<1000 {
    if weakStore.value == nil { break }
    try await Task.sleep(for: .milliseconds(1))
  }
  try check(weakStore.value == nil, "retained stream does not retain store")
  var iterator = recovered!.makeAsyncIterator(); _ = await iterator.next()
  let end = await iterator.next(); try check(end == nil, "store disposal finishes retained stream")
  print("PASS dropped-subscriber capacity recovery and weak store disposal")
}
func encodingPersistence() async throws {
  let backing = Backing(), store = NativePreferencesStore(backing: backing)
  let legacy = record("{\"clipboardSend\":false}")
  backing.replace(legacy)
  let initial = try await store.read()
  let legacyRead = try backing.read()
  try check(legacyRead == legacy && backing.counts.writes == 0, "schema 1 read preserves exact bytes")
  var encoding = NativeEncodingPreferences()
  try encoding.set(.quality, value: "0x5"); try encoding.set(.preferred, value: "raw")
  try encoding.set(.autoSelect, value: "off")
  try check(encoding.qualityLevel == 5 && encoding.preferredEncoding == "Raw", "core canonicalizes typed preferences")
  var values = initial.values; values.encoding = encoding
  let saved = try await store.commit(values, expected: initial.revision)
  let bytes = try backing.read()!
  let envelope = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
  try check(envelope["schema"] as? Int == 11 && saved.revision != initial.revision, "explicit save upgrades envelope and revision")
  let reread = try await store.read()
  try check(reread == saved, "typed encoding round trip")
  let resolved = try reread.values.encoding!.resolved()
  let quality = try resolved.value(for: .quality), compression = try resolved.value(for: .compression)
  try check(quality.value == "5" && quality.source == .appDefaults && compression.source == .compiled, "field-specific inherited provenance")
  let writes = backing.counts.writes
  values.encoding?.qualityLevel = 100
  try await expect(.invalidValue) { _ = try await store.commit(values, expected: saved.revision) }
  try check(backing.counts.writes == writes, "invalid encoding commit does not write")
  await store.close()
  let cases: [(String, NativePreferencesError)] = [
    ("{\"qualityLevel\":100}", .invalidValue), ("{\"preferredEncoding\":\"bogus\"}", .invalidValue),
    ("{\"qualityLevel\":true}", .corrupt), ("{\"autoSelect\":1}", .corrupt),
    ("{\"qualityLevel\":null}", .corrupt), ("{\"unknown\":false}", .unsupportedFields)]
  for (fields, error) in cases {
    let backend = Backing(), invalid = record("{\"encoding\":\(fields)}", schema: "2")
    backend.replace(invalid); let owner = NativePreferencesStore(backing: backend)
    try await expect(error) { _ = try await owner.read() }
    try await expect(error) { _ = try await owner.reset(expected: initial.revision) }
    let after = try backend.read()
    try check(after == invalid && backend.counts.writes == 0, "invalid nested encoding remains intact")
    await owner.close()
  }
  if let unavailable = try NativeEncodingOptions.choices().first(where: { !$0.available }) {
    let backend = Backing(), owner = NativePreferencesStore(backing: backend)
    var patch = NativeEncodingPreferences(); patch.preferredEncoding = unavailable.name
    let snapshot = try await owner.read()
    try await expect(.unsupportedValue) { _ = try await owner.commit(NativePreferences(encoding: patch), expected: snapshot.revision) }
    try check(backend.counts.writes == 0, "unavailable decoder never written")
    await owner.close()
  }
  print("PASS schema 1 preservation and explicit schema 2 upgrade, canonical shared validation, strict nested fields and source inheritance")
}
@MainActor func encodingSessionDefaults() async throws {
  let backing = Backing(), store = NativePreferencesStore(backing: backing), runtime = try NativeRuntime()
  let draft = NativePreferencesDraft(store: store)
  draft.reload(); try await until("encoding draft") { !draft.isBusy }
  draft.setEncoding(.autoSelect, value: "off"); draft.setEncoding(.quality, value: "3")
  draft.apply(); try await until("encoding save") { !draft.isBusy }
  let first = NativeSessionDefaults(runtime: runtime, store: store)
  try check(first.session == nil, "no session before defaults load")
  first.load(); try await until("encoding initial session") { !first.isLoading }
  guard let session = first.session else { throw Failure(message: "Missing configured session") }
  let initial = try session.encodingOptions().value(for: .quality)
  try check(session.snapshot.state == .idle && initial.value == "3" && initial.source == .appDefaults, "encoding installed before connect")
  draft.values.encoding?.qualityLevel = 99; draft.apply()
  try await until("invalid draft") { !draft.isBusy }
  try check(draft.error == .invalidValue && !draft.needsReload && draft.hasChanges, "invalid draft remains correctable")
  draft.cancel()
  try check(draft.error == nil && !draft.hasChanges && draft.values.encoding?.qualityLevel == 3, "cancel invalid draft restores saved values and clears validation error")
  draft.setEncoding(.quality, value: "5"); draft.apply(); try await until("corrected draft") { !draft.isBusy }
  try check(draft.error == nil && !draft.hasChanges, "corrected draft saved without reload")
  let second = NativeSessionDefaults(runtime: runtime, store: store)
  second.load(); try await until("later encoding session") { !second.isLoading }
  guard let later = second.session else { throw Failure(message: "Missing later session") }
  let oldQuality = try session.encodingOptions().value(for: .quality), newQuality = try later.encodingOptions().value(for: .quality)
  try check(oldQuality.value == "3" && newQuality.value == "5", "new encoding defaults never mutate an existing session")
  await first.close(); await second.close(); await draft.close(); await store.close(); try await runtime.shutdown()
  print("PASS pre-connect encoding defaults, correctable invalid drafts and existing-session isolation")
}
func isolatedUserDefaults() async throws {
  let domain = "io.github.jkeli.tidyvnc.tests.preferences.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: domain)!
  defer { defaults.removePersistentDomain(forName: domain) }
  defaults.register(defaults: ["preferences": record("{\"clipboardSend\":false}")])
  let store = NativePreferencesStore(backing: try UserDefaultsPreferencesBacking(domain: domain))
  let initial = try await store.read()
  try check(!initial.isStored, "persistent-domain read ignores registration fallback")
  defaults.set("keep", forKey: "unrelated-test-key")
  let saved = try await store.commit(NativePreferences(clipboardSend: false, clipboardReceive: true), expected: initial.revision)
  let reopened = NativePreferencesStore(backing: try UserDefaultsPreferencesBacking(domain: domain))
  let reread = try await reopened.read()
  try check(reread == saved && defaults.string(forKey: "unrelated-test-key") == "keep", "fresh adapter reads accepted record without replacing other keys")
  var configuration = NativeSessionConfiguration(); configuration.clipboardSend = true; configuration.clipboardReceive = false
  let applied = try saved.values.applying(to: configuration)
  let inherited = try NativePreferences().applying(to: configuration)
  try check(!applied.clipboardSend && applied.clipboardReceive && inherited.clipboardSend && !inherited.clipboardReceive, "typed patch preserves compiled/invocation defaults for absent values")
  defaults.set("wrong type", forKey: "preferences")
  try await expect(.corrupt) { _ = try await reopened.read() }
  try await expect(.corrupt) { _ = try await reopened.reset(expected: saved.revision) }
  try check(defaults.string(forKey: "preferences") == "wrong type", "non-data persistent value preserved")
  await store.close(); await reopened.close()
  print("PASS disposable UserDefaults domain read/write/reopen, no fallback, unrelated-key preservation and typed configuration patch")
}
@MainActor func until(_ message: String, _ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out: \(message)")
}
@MainActor func draftsAndSessionIsolation() async throws {
  let backing = Backing(), store = NativePreferencesStore(backing: backing)
  let first = NativePreferencesDraft(store: store), second = NativePreferencesDraft(store: store)
  first.reload(); second.reload()
  try await until("draft loading") { !first.isBusy && !second.isBusy }
  try check(first.snapshot != nil && !first.canApply, "loaded empty draft")
  first.values.clipboardSend = false
  try check(first.canApply && backing.counts.writes == 0, "editing does not save")
  first.cancel(); try check(!first.hasChanges && backing.counts.writes == 0, "Cancel discards without writing")
  first.values.clipboardSend = false; first.apply()
  try await until("first apply") { !first.isBusy }
  try check(first.error == nil && !first.hasChanges, "apply commits draft")
  second.values.clipboardReceive = false; second.apply()
  try await until("stale apply") { !second.isBusy }
  try check(second.error == .conflict && second.needsReload && !second.canApply && second.values.clipboardReceive == false, "conflict preserves draft and requires reload")
  second.cancel(); try check(second.needsReload, "Cancel does not clear conflict gate")
  second.reload(); try await until("explicit reload") { !second.isBusy }
  try check(second.values.clipboardSend == false && second.values.clipboardReceive == nil && second.error == nil, "reload obtains new baseline")
  let runtime = try NativeRuntime()
  let aDefaults = NativeSessionDefaults(runtime: runtime, store: store)
  aDefaults.load(); try await until("first session defaults") { !aDefaults.isLoading }
  guard let a = aDefaults.session else { throw Failure(message: "Missing first session") }
  try check(aDefaults.isReady && !a.clipboardSendEnabled && a.clipboardReceiveEnabled, "new session gets saved patch plus inherited receive")
  second.values = NativePreferences(clipboardSend: true, clipboardReceive: false); second.apply()
  try await until("changed app defaults") { !second.isBusy }
  try check(!a.clipboardSendEnabled && a.clipboardReceiveEnabled, "saving app defaults leaves existing session unchanged")
  let bDefaults = NativeSessionDefaults(runtime: runtime, store: store)
  bDefaults.load(); try await until("second session defaults") { !bDefaults.isLoading }
  guard let b = bDefaults.session else { throw Failure(message: "Missing second session") }
  try check(bDefaults.isReady && b.clipboardSendEnabled && !b.clipboardReceiveEnabled, "later session uses new defaults")
  let writes = backing.counts.writes
  try aDefaults.setClipboard(send: true)
  try check(a.clipboardSendEnabled && a.clipboardReceiveEnabled && !b.clipboardReceiveEnabled && backing.counts.writes == writes, "live override affects one direction in one session only")
  try check(aDefaults.overrides.clipboardSend == true && aDefaults.overrides.clipboardReceive == nil && aDefaults.inherited.clipboardSend == false, "effective source retains inherited baseline and field-specific override")
  aDefaults.load(); try check(!aDefaults.isLoading && a.clipboardReceiveEnabled, "existing sessions do not reload defaults")
  second.restoreBuiltInDefaults(); try check(second.hasChanges && backing.counts.writes == writes, "restore changes only draft")
  second.cancel(); try check(second.values.clipboardSend == true && second.values.clipboardReceive == false, "restore can be cancelled")
  backing.replace(Data("corrupt".utf8))
  let cDefaults = NativeSessionDefaults(runtime: runtime, store: store)
  cDefaults.load(); try await until("corrupt defaults") { !cDefaults.isLoading }
  try check(cDefaults.session == nil && !cDefaults.isReady && cDefaults.error == .corrupt, "corruption blocks connection readiness")
  cDefaults.useBuiltInDefaults()
  try await until("explicit fallback") { !cDefaults.isLoading }
  guard let c = cDefaults.session else { throw Failure(message: "Missing fallback session") }
  try check(cDefaults.isReady && c.clipboardSendEnabled && c.clipboardReceiveEnabled && backing.counts.writes == writes, "explicit built-in fallback affects session without repairing store")
  await first.close(); await second.close(); await aDefaults.close(); await bDefaults.close(); await cDefaults.close()
  await store.close(); try await runtime.shutdown()
  print("PASS draft/apply/cancel/conflict, new-session defaults, existing-session isolation, per-field sources and explicit corruption fallback")
}
final class GatedBacking: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
  private var data: Data?
  private var blockRead = false, blockWrite = false, entered = false
  func arm(read: Bool) { lock.withLock { blockRead = read; blockWrite = !read; entered = false } }
  var hasEntered: Bool { lock.withLock { entered } }
  func release() { gate.signal() }
  private func pause() throws {
    lock.withLock { entered = true }
    guard gate.wait(timeout: .now() + 5) == .success else { throw NativePreferencesError.ioFailure }
  }
  func read() throws -> Data? {
    let (value, blocked) = lock.withLock { let blocked = blockRead; blockRead = false; return (data, blocked) }
    if blocked { try pause() }; return value
  }
  func write(_ value: Data) throws {
    let blocked = lock.withLock { data = value; let blocked = blockWrite; blockWrite = false; return blocked }
    if blocked { try pause() }
  }
}
@MainActor func closeDuringStoreOperations() async throws {
  let backing = GatedBacking(), store = NativePreferencesStore(backing: backing)
  let runtime = try NativeRuntime(sessionCapacity: 1)
  let defaults = NativeSessionDefaults(runtime: runtime, store: store)
  backing.arm(read: true); defaults.load()
  try await until("pending store read") { backing.hasEntered }
  defaults.stop()
  let join = Task { await defaults.close() }
  var heartbeats = 0
  for _ in 0..<10 { try await Task.sleep(for: .milliseconds(1)); heartbeats += 1 }
  try check(heartbeats == 10, "MainActor remains responsive with a blocked store")
  backing.release(); await join.value
  try check(!defaults.isReady && !defaults.isLoading && defaults.session == nil, "cancelled late read never creates a session")
  let capacityProbe = try runtime.makeSession()
  try await capacityProbe.close()
  let draft = NativePreferencesDraft(store: store)
  draft.reload(); try await until("draft before close") { !draft.isBusy }
  draft.values.clipboardSend = false
  backing.arm(read: false); draft.apply()
  try await until("accepted pending save") { backing.hasEntered }
  draft.stop(); let saveJoin = Task { await draft.close() }
  backing.release(); await saveJoin.value
  let saved = try await store.read()
  try check(saved.values.clipboardSend == false && !draft.canApply, "close joins accepted save without claiming rollback")
  try await runtime.shutdown(); await store.close()
  print("PASS responsive MainActor, close during pending defaults read, stale-result suppression and accepted-save join")
}
@main struct NativePreferencesTests {
  static func main() async {
    do {
      try await revisionsAndNotifications(); try await invalidRecordsAndFailures(); try await cancellationAndCapacity()
      try await encodingPersistence(); try await encodingSessionDefaults(); try await subscriptionLifetime(); try await isolatedUserDefaults(); try await draftsAndSessionIsolation(); try await closeDuringStoreOperations()
    }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
