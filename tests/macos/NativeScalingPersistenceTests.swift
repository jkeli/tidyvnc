// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
final class Memory: NativePreferencesBacking, NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?, count = 0
  init(_ data: Data? = nil) { self.data = data }
  var writes: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { data } }
  func write(_ data: Data) throws { lock.withLock { self.data = data; count += 1 } }
  func replace(_ data: Data, expected: Data?) throws {
    try lock.withLock { guard self.data == expected else { throw NativeStorageError.conflict }; self.data = data; count += 1 }
  }
}
func record(_ fields: String?, profile: Bool = false, schema: Int? = nil) -> Data {
  let values = fields.map { "\"scaling\":\($0)" } ?? ""
  let content = profile ? "\"profiles\":[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\",\"endpoint\":\"host\",\"settings\":{\(values)}}],\"recentEndpoints\":[\"recent\"]" : "\"values\":{\(values)}"
  return Data("{\"schema\":\(schema ?? (profile ? 3 : 4)),\"revision\":\"00000000-0000-0000-0000-000000000001\",\(content)}".utf8)
}
func stores() async throws {
  for mode in NativeScalingMode.allCases {
    for filter in NativeScalingFilter.allCases {
      var patch = NativeScalingPreferences(); patch.scaling = mode.initialText; patch.devicePixels = true; patch.filter = filter.storageToken
      let resolved = try patch.resolved()
      try check(resolved.mode == mode && resolved.filter == filter && resolved.devicePixels, "all eight modes and three filters resolve through shared parser")
    }
  }
  for schema in [1,2,3] {
    let original = record(nil,schema: schema), backing = Memory(original), store = NativePreferencesStore(backing: backing)
    let initial = try await store.read()
    try check(try backing.read() == original && backing.writes == 0,"old preference schemas never rewrite during read")
    var patch = NativeScalingPreferences(); patch.scaling = "137.50%"; patch.devicePixels = true; patch.filter = "area"
    let saved = try await store.commit(.init(scaling: patch),expected: initial.revision)
    let reopened = NativePreferencesStore(backing: backing), read = try await reopened.read()
    try check(read == saved && read.values.scaling?.scaling == "137.5" && read.values.scaling?.filter == "area" && read.values.scaling?.devicePixels == true,"canonical scaling survives reopen")
    try check((try JSONSerialization.jsonObject(with: backing.read()!) as! [String: Any])["schema"] as? Int == 11,"preference explicit upgrade")
    let writes = backing.writes; patch.scaling = "1x0"
    do { _ = try await store.commit(.init(scaling: patch),expected: saved.revision); throw Failure(message: "saved invalid size") }
    catch NativePreferencesError.invalidValue {}
    try check(backing.writes == writes,"invalid size cannot write")
    await reopened.close(); await store.close()
  }
  for schema in [1,2] {
    let original = record(nil,profile: true,schema: schema), backing = Memory(original), store = NativeProfileHistoryStore(backing: backing)
    let initial = try await store.read(); var profile = initial.profiles[0]
    try check(try backing.read() == original && backing.writes == 0,"old profile schema preserves bytes")
    var patch = NativeScalingPreferences(); patch.scaling = "125.00%x80.00%"; patch.filter = "nearest"
    profile.settings.scaling = patch
    let saved = try await store.upsert(profile,expected: initial.revision)
    let reopened = NativeProfileHistoryStore(backing: backing), read = try await reopened.read()
    try check(read == saved && read.recentEndpoints == ["recent"] && read.profiles[0].settings.scaling?.scaling == "125%x80%" && read.profiles[0].settings.scaling?.devicePixels == nil,"profile canonical sizing and absence survive reopen")
    try check((try JSONSerialization.jsonObject(with: backing.read()!) as! [String: Any])["schema"] as? Int == 11,"profile explicit upgrade")
    do { _ = try await store.upsert(profile,expected: initial.revision); throw Failure(message: "overwrote stale profile") }
    catch NativeStorageError.conflict {}
    await reopened.close(); await store.close()
  }
  // Reads preserve even valid noncanonical payloads until an explicit commit.
  let original = record("{\"scaling\":\"137.50%\"}"), backing = Memory(original), store = NativePreferencesStore(backing: backing)
  let read = try await store.read()
  try check(read.values.scaling?.scaling == "137.50%" && (try backing.read()) == original && backing.writes == 0,"read does not normalize stored bytes")
  await store.close()
  print("PASS all modes/filters, canonical explicit saves, legacy byte preservation, omitted-field inheritance and stale-write guards")
}
func invalid() async throws {
  let cases: [(String,NativePreferencesError,NativeStorageError)] = [
    ("null",.corrupt,.corrupt), ("[]",.corrupt,.corrupt), ("{\"scaling\":100}",.corrupt,.corrupt),
    ("{\"devicePixels\":1}",.corrupt,.corrupt), ("{\"filter\":null}",.corrupt,.corrupt),
    ("{\"filter\":\"unknown\"}",.invalidValue,.invalid), ("{\"scaling\":\"1x0\"}",.invalidValue,.invalid),
    ("{\"scaling\":\"10000.01\"}",.invalidValue,.invalid), ("{\"scaling\":\"1.001\"}",.invalidValue,.invalid),
    ("{\"scaling\":\"" + String(repeating: "1",count: 65) + "\"}",.invalidValue,.invalid),
    ("{\"unknown\":false}",.unsupportedFields,.unsupportedFields)]
  for (fields,expected,profileExpected) in cases {
    let data = record(fields), backing = Memory(data), store = NativePreferencesStore(backing: backing)
    do { _ = try await store.read(); throw Failure(message: "read invalid scaling defaults") }
    catch let error as NativePreferencesError { try check(error == expected,"preference failure \(fields): \(error)") }
    do { _ = try await store.reset(expected: .init(value: nil)); throw Failure(message: "reset invalid defaults") }
    catch let error as NativePreferencesError { try check(error == expected,"reset preserves unreadable defaults") }
    try check(try backing.read() == data && backing.writes == 0,"invalid defaults intact")
    await store.close()
    let bytes = record(fields,profile: true), backend = Memory(bytes), library = NativeProfileHistoryStore(backing: backend)
    do { _ = try await library.read(); throw Failure(message: "read invalid scaling profile") }
    catch let error as NativeStorageError { try check(error == profileExpected,"profile failure \(fields): \(error)") }
    do { _ = try await library.clearHistory(expected: nil); throw Failure(message: "overwrote invalid profile") }
    catch let error as NativeStorageError { try check(error == profileExpected,"history preserves unreadable profile") }
    try check(try backend.read() == bytes && backend.writes == 0,"invalid profile intact")
    await library.close()
  }
  let older = NativePreferencesStore(backing: Memory(record("{}",schema: 3)))
  do { _ = try await older.read(); throw Failure(message: "scaling allowed in old schema") } catch NativePreferencesError.unsupportedFields {}
  await older.close()
  let oldProfile = NativeProfileHistoryStore(backing: Memory(record("{}",profile: true,schema: 2)))
  do { _ = try await oldProfile.read(); throw Failure(message: "scaling allowed in old profile schema") } catch NativeStorageError.unsupportedFields {}
  await oldProfile.close()
  print("PASS strict scaling records, parser bounds, unknown filters/fields and write preservation")
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
@MainActor func integration() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), backing = Memory(), preferences = NativePreferencesStore(backing: backing)
  let profileBacking = Memory(), store = NativeProfileHistoryStore(backing: profileBacking)
  let editor = NativePreferencesDraft(store: preferences)
  editor.reload(); try await until { !editor.isBusy }
  var app = NativeScalingPreferences(); app.scaling = "137.50%"; app.devicePixels = true; app.filter = "area"
  editor.values.scaling = app; editor.cancel()
  try check(editor.values.scaling == nil && backing.writes == 0,"Cancel scaling defaults")
  editor.values.scaling = app; editor.values.scaling?.scaling = "0"
  try check(!editor.canApply,"invalid sizing disables defaults Apply")
  editor.values.scaling = app; editor.apply(); try await until { !editor.isBusy }
  try check(editor.error == nil && !editor.hasChanges && editor.values.scaling?.scaling == "137.5","canonical accepted value reconciles editor baseline")
  var override = NativeScalingPreferences(); override.scaling = "120x80"; override.filter = "nearest"
  var profile = NativeConnectionProfile(name: "Lab",endpoint: "host",settings: .init(scaling: override))
  _ = try await store.upsert(profile,expected: nil)
  let model = ConnectionModel(runtime: runtime,preferences: preferences,profileStore: store,profileID: profile.id) { _,_ in }
  try await until { model.defaults?.isReady == true }
  let session = model.session!, state = model.scaling
  try check(state.value.canonical == "120x80" && state.value.devicePixels && state.value.filter == .nearest && session.snapshot.state == .idle,"resolved scaling installed before connect")
  try check(state.sources[.scaling] == .profile && state.sources[.filter] == .profile && state.sources[.devicePixels] == .appDefaults,"fieldwise profile/app sources")
  let view = NativeDesktopView(frame: CGRect(x: 0,y: 0,width: 300,height: 200)); view.bind(session)
  try check(view.scaling == "120x80" && view.devicePixels && view.filter == .nearest,"bare view gets configured scaling before frame subscription")
  view.observeScaling(state)
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { view.displayedSequence != 0 && !view.isRendering }
  try check(view.desktopRectangle == CGRect(x: 90,y: 60,width: 120,height: 80),"first frame uses saved scaling")
  let writes = backing.writes, profileWrites = profileBacking.writes
  let draft = NativeScalingDraft(state: state); draft.filter = .bilinear
  try check(draft.source(for: .filter) == .session && draft.source(for: .scaling) == .profile,"live draft sources")
  try check(draft.apply() && state.sources[.filter] == .session && state.sources[.scaling] == .profile,"filter-only apply preserves untouched sources")
  try check(backing.writes == writes && profileBacking.writes == profileWrites,"live scaling writes neither store")
  editor.values.scaling?.scaling = "300x180"; editor.values.scaling?.filter = "area"; editor.apply(); try await until { !editor.isBusy }
  profile.settings.scaling = nil
  _ = try await store.upsert(profile,expected: (try await store.read()).revision)
  let later = ConnectionModel(runtime: runtime,preferences: preferences,profileStore: store,profileID: profile.id) { _,_ in }
  try await until { later.defaults?.isReady == true }
  try check(later.scaling.value.canonical == "300x180" && later.scaling.value.filter == .area && state.value.canonical == "120x80" && state.value.filter == .bilinear,"saved updates reach new connections only")
  state.bind(session); try check(state.value.filter == .bilinear,"rebinding same session preserves live scaling")
  _ = try await session.disconnect()
  let reconnect = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(reconnect) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(reconnect))")
  try check(state.value.canonical == "120x80" && state.value.filter == .bilinear,"reconnect keeps live scaling")
  let library = NativeProfileLibrary(store: store,preferences: preferences)
  library.reload(); try await until { !library.isBusy }; library.select(profile.id)
  try check(library.inheritedScaling.canonical == "300x180","profile preview inherits current app sizing")
  var patch = NativeScalingPreferences(); patch.scaling = "bad"
  library.draft?.settings.scaling = patch; try check(!library.canSave,"invalid profile sizing disables Save")
  patch.scaling = "125.00%x80.00%"; library.draft?.settings.scaling = patch
  library.save(); try await until { !library.isBusy }
  try check(library.error == nil && !library.hasChanges && library.draft?.settings.scaling?.scaling == "125%x80%","profile save canonicalizes and reconciles draft")
  library.draft?.settings.scaling = nil; library.cancelEdits()
  try check(library.draft?.settings.scaling?.scaling == "125%x80%","profile Cancel restores saved sizing")
  view.detach(); await library.close(); await editor.close(); await model.close(); await later.close()
  await preferences.close(); await store.close(); try await runtime.shutdown()
  print("PASS draft validation/cancellation/canonicalization, initial frame geometry, source inheritance, live/new-session isolation, reconnect and profile editing")
}
@main struct NativeScalingPersistenceTests {
  @MainActor static func main() async {
    do { try await stores(); try await invalid(); try await integration() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
