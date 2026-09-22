// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
final class Memory: NativePreferencesBacking, NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private var count = 0
  init(_ data: Data? = nil) { self.data = data }
  var writes: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { data } }
  func write(_ data: Data) throws { lock.withLock { self.data = data; count += 1 } }
  func replace(_ data: Data, expected: Data?) throws {
    try lock.withLock { guard self.data == expected else { throw NativeStorageError.conflict }; self.data = data; count += 1 }
  }
}
func preferences(_ input: String?, schema: Int = 3) -> Data {
  Data("{\"schema\":\(schema),\"revision\":\"00000000-0000-0000-0000-000000000001\",\"values\":{\(input.map { "\"input\":\($0)" } ?? "")}}".utf8)
}
func profiles(_ input: String?, schema: Int = 2) -> Data {
  Data("{\"schema\":\(schema),\"revision\":\"00000000-0000-0000-0000-000000000001\",\"profiles\":[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\",\"endpoint\":\"host\",\"settings\":{\(input.map { "\"input\":\($0)" } ?? "")}}],\"recentEndpoints\":[\"recent\"]}".utf8)
}
func persistence() async throws {
  for mask in UInt32(0)...15 {
    var value = NativeInputPreferences(); value.shortcutModifiers = mask
    try check(try value.resolved().shortcutModifiers.rawValue == mask, "all supported modifier masks round trip")
  }
  var patch = NativeInputPreferences(); patch.viewOnly = true; patch.emulateMiddle = true
  patch.fullscreenSystemKeys = false; patch.shortcutModifiers = 0; patch.cursorFallback = .system
  for schema in [1,2] {
    let original = preferences(nil,schema: schema), backing = Memory(original), store = NativePreferencesStore(backing: backing)
    let initial = try await store.read()
    try check(initial.values.input == nil && (try backing.read()) == original && backing.writes == 0, "legacy preference read is side-effect-free")
    let saved = try await store.commit(.init(input: patch), expected: initial.revision)
    let reopened = NativePreferencesStore(backing: backing), result = try await reopened.read()
    try check(result == saved && result.values.input == patch, "input patch survives preferences reopen")
    let envelope = try JSONSerialization.jsonObject(with: backing.read()!) as! [String: Any]
    try check(envelope["schema"] as? Int == 11, "explicit commit upgrades to schema 11")
    do { _ = try await store.commit(.init(), expected: initial.revision); throw Failure(message: "stale preferences saved") }
    catch NativePreferencesError.conflict {}
    await reopened.close(); await store.close()
  }
  let original = profiles(nil,schema: 1), backing = Memory(original), store = NativeProfileHistoryStore(backing: backing)
  let initial = try await store.read(); var profile = initial.profiles[0]
  try check(try backing.read() == original && backing.writes == 0, "legacy profile read preserves bytes")
  profile.settings.input = patch
  let saved = try await store.upsert(profile, expected: initial.revision)
  let reopened = NativeProfileHistoryStore(backing: backing), result = try await reopened.read()
  try check(result == saved && result.profiles[0].settings.input == patch && result.recentEndpoints == ["recent"], "profile patch and history survive reopen")
  let envelope = try JSONSerialization.jsonObject(with: backing.read()!) as! [String: Any]
  try check(envelope["schema"] as? Int == 12, "explicit profile commit upgrades schema")
  var invalid = patch; invalid.shortcutModifiers = 16; profile.settings.input = invalid
  let writes = backing.writes
  do { _ = try await store.upsert(profile, expected: saved.revision); throw Failure(message: "invalid mask saved") }
  catch NativeStorageError.invalid {}
  try check(backing.writes == writes, "invalid profile cannot write")
  await reopened.close(); await store.close()
  print("PASS legacy preservation, explicit schema upgrades, all-field roundtrip, empty modifier override, revision guards and history preservation")
}
func invalidRecords() async throws {
  let cases: [(String,NativePreferencesError,NativeStorageError)] = [
    ("null",.corrupt,.corrupt), ("[]",.corrupt,.corrupt),
    ("{\"viewOnly\":1}",.corrupt,.corrupt), ("{\"emulateMiddle\":null}",.corrupt,.corrupt),
    ("{\"fullscreenSystemKeys\":\"true\"}",.corrupt,.corrupt),
    ("{\"shortcutModifiers\":true}",.corrupt,.corrupt), ("{\"shortcutModifiers\":-1}",.corrupt,.corrupt),
    ("{\"shortcutModifiers\":1.5}",.corrupt,.corrupt), ("{\"shortcutModifiers\":16}",.invalidValue,.invalid),
    ("{\"shortcutModifiers\":18446744073709551615}",.invalidValue,.invalid),
    ("{\"cursorFallback\":\"other\"}",.invalidValue,.invalid), ("{\"cursorFallback\":null}",.corrupt,.corrupt),
    ("{\"password\":\"no\"}",.unsupportedFields,.unsupportedFields)]
  for (input,prefError,profileError) in cases {
    let bytes = preferences(input), memory = Memory(bytes), store = NativePreferencesStore(backing: memory)
    do { _ = try await store.read(); throw Failure(message: "read invalid preferences \(input)") }
    catch let error as NativePreferencesError { try check(error == prefError,"typed preferences failure \(input): \(error)") }
    do { _ = try await store.commit(.init(),expected: .init(value: nil)); throw Failure(message: "overwrote invalid preferences") }
    catch let error as NativePreferencesError { try check(error == prefError,"commit preserves unreadable data") }
    try check(try memory.read() == bytes && memory.writes == 0,"invalid preferences untouched")
    await store.close()
    let data = profiles(input), backend = Memory(data), library = NativeProfileHistoryStore(backing: backend)
    do { _ = try await library.read(); throw Failure(message: "read invalid profile \(input)") }
    catch let error as NativeStorageError { try check(error == profileError,"typed profile failure \(input): \(error)") }
    do { _ = try await library.clearHistory(expected: nil); throw Failure(message: "overwrote invalid profile") }
    catch let error as NativeStorageError { try check(error == profileError,"history mutation preserves unreadable profiles") }
    try check(try backend.read() == data && backend.writes == 0,"invalid profile untouched")
    await library.close()
  }
  let old = NativePreferencesStore(backing: Memory(preferences("{}",schema: 2)))
  do { _ = try await old.read(); throw Failure(message: "input allowed in old schema") } catch NativePreferencesError.unsupportedFields {}
  await old.close()
  let oldProfile = NativeProfileHistoryStore(backing: Memory(profiles("{}",schema: 1)))
  do { _ = try await oldProfile.read(); throw Failure(message: "input allowed in old profile schema") } catch NativeStorageError.unsupportedFields {}
  await oldProfile.close()
  print("PASS strict nested typing, bounds, unknown fields, old-schema rejection and preservation on attempted writes")
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
@MainActor func installation() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), backing = Memory(), preferences = NativePreferencesStore(backing: backing)
  let profileBacking = Memory(), store = NativeProfileHistoryStore(backing: profileBacking)
  var app = NativeInputPreferences(); app.viewOnly = true; app.emulateMiddle = true; app.shortcutModifiers = 0
  app.fullscreenSystemKeys = false; app.cursorFallback = .dot
  let saved = try await preferences.commit(.init(input: app), expected: (try await preferences.read()).revision)
  var patch = NativeInputPreferences(); patch.cursorFallback = .system; patch.shortcutModifiers = 15
  var profile = NativeConnectionProfile(name: "Lab", endpoint: "host", settings: .init(input: patch))
  _ = try await store.upsert(profile, expected: nil)
  let editor = NativePreferencesDraft(store: preferences)
  editor.reload(); try await until { !editor.isBusy }
  editor.values.input?.shortcutModifiers = 16; editor.apply(); try await until { !editor.isBusy }
  try check(editor.error == .invalidValue && !editor.needsReload, "invalid input draft remains correctable")
  editor.cancel(); try check(editor.values.input == app && !editor.hasChanges && editor.error == nil, "input Cancel restores saved patch")
  editor.restoreBuiltInDefaults(); try check(editor.values.input == nil && editor.hasChanges, "restore removes only draft overrides")
  editor.cancel(); await editor.close()
  let first = ConnectionModel(runtime: runtime, preferences: preferences, profileStore: store, profileID: profile.id) { _,_ in }
  try await until { first.defaults?.isReady == true }
  let session = first.session!
  try check(session.snapshot.state == .idle && session.isViewOnly && session.emulatesMiddleButton, "input policy installed before Connect")
  try check(first.input.value.cursorFallback == .system && first.input.value.shortcutModifiers.rawValue == 15 && !first.input.value.fullscreenSystemKeys, "host settings installed from fieldwise app/profile precedence")
  try check(first.input.sources[.viewOnly] == .appDefaults && first.input.sources[.cursorFallback] == .profile && first.input.sources[.shortcutModifiers] == .profile,"fieldwise provenance")
  let view = NativeDesktopView(frame: CGRect(x: 0,y: 0,width: 200,height: 200)); view.bind(session)
  try check(view.cursorFallback == .system,"bare desktop also installs configured host settings")
  view.observeInput(first.input)
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.frame != nil && !view.isRendering }
  try session.setFocused(true)
  do { try session.sendKey(id: 1,keysym: 65,down: true); throw Failure(message: "configured view-only sent input") }
  catch let error as NativeError { try check(error.status == .viewOnly,"core enforces saved view-only") }
  let draft = NativeInputDraft(state: first.input); draft.viewOnly = false
  try check(draft.source(for: .viewOnly) == .session && draft.source(for: .cursorFallback) == .profile,"draft effective sources")
  let writes = backing.writes, profileWrites = profileBacking.writes
  try check(draft.apply() && !session.isViewOnly && first.input.sources[.viewOnly] == .session && first.input.sources[.emulateMiddle] == .appDefaults,"live override changes only edited source")
  try check(backing.writes == writes && profileBacking.writes == profileWrites,"live override never persists")
  var later = app; later.viewOnly = false; later.emulateMiddle = false; later.cursorFallback = .hidden
  _ = try await preferences.commit(.init(input: later),expected: saved.revision)
  profile.settings.input = nil
  _ = try await store.upsert(profile,expected: (try await store.read()).revision)
  let second = ConnectionModel(runtime: runtime, preferences: preferences, profileStore: store, profileID: profile.id) { _,_ in }
  try await until { second.defaults?.isReady == true }
  try check(!second.session!.isViewOnly && !second.session!.emulatesMiddleButton && second.input.value.shortcutModifiers.isEmpty && second.input.value.cursorFallback == .hidden,"new connection rereads changed defaults/profile")
  try check(session.emulatesMiddleButton && first.input.value.cursorFallback == .system && first.input.value.shortcutModifiers.rawValue == 15,"saving defaults/profile cannot mutate existing connection")
  try session.setViewOnly(true)
  try check(first.input.sources[.viewOnly] == .session,"external session policy updates provenance")
  let late = NativeInputState(); late.bind(session)
  try check(late.sources[.viewOnly] == .session && late.sources[.emulateMiddle] == .appDefaults,
    "late binding retains live source even after a value returns to its initial value")
  late.stop()
  _ = try await session.disconnect()
  let reconnect = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(reconnect) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(reconnect))")
  try check(session.isViewOnly && session.emulatesMiddleButton && first.input.value.cursorFallback == .system, "reconnect keeps live policy instead of reloading saved changes")
  let library = NativeProfileLibrary(store: store,preferences: preferences)
  library.reload(); try await until { !library.isBusy }; library.select(profile.id)
  try check(library.inheritedInput.cursorFallback == .hidden && library.inheritedInput.shortcutModifiers.isEmpty,"profile editor previews latest app defaults")
  library.draft?.settings.input = patch; library.cancelEdits()
  try check(library.draft?.settings.input == nil,"profile Cancel discards input edits")
  library.draft?.settings.input = patch; library.save(); try await until { !library.isBusy }
  try check(library.error == nil && library.draft?.settings.input == patch,"profile editor saves input patch")
  view.detach(); await library.close(); await first.close(); await second.close()
  await store.close(); await preferences.close(); try await runtime.shutdown()
  let bounded = try NativeRuntime(sessionCapacity: 1)
  var invalid = NativeSessionConfiguration(); invalid.input = .init(shortcutModifiers: .init(rawValue: 16))
  do { _ = try bounded.makeSession(configuration: invalid); throw Failure(message: "invalid configuration admitted") }
  catch let error as NativeError { try check(error.status == .invalidArgument, "invalid native configuration status") }
  let valid = try bounded.makeSession(); try await valid.close(); try await bounded.shutdown()
  print("PASS pre-connect core/host installation, per-field precedence/source, direct desktop configuration, live isolation, new-session reload and profile editing")
}
@main struct NativeInputPersistenceTests {
  @MainActor static func main() async {
    do { try await persistence(); try await invalidRecords(); try await installation() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
