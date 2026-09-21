// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(message: message) } }
final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
@MainActor func until(_ label: String, _ condition: () -> Bool) async throws {
  for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out: \(label)")
}
final class Preferences: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func read() throws -> Data? { lock.withLock { data } }
  func write(_ data: Data) throws { lock.withLock { self.data = data } }
}
@MainActor func editing() async throws {
  let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing)
  let preferences = NativePreferencesStore(backing: Preferences())
  var appEncoding = NativeEncodingPreferences(); try appEncoding.set(.quality, value: "6")
  _ = try await preferences.commit(.init(clipboardSend: false, encoding: appEncoding), expected: (try await preferences.read()).revision)
  let model = NativeProfileLibrary(store: store, preferences: preferences)
  model.reload(); try await until("initial") { !model.isBusy }
  try check(model.hasLoaded && model.profiles.isEmpty && backing.writes == 0, "read doesn't create data")
  model.newProfile(); try check(!model.canSave && !model.canUse, "empty draft is not usable")
  model.draft?.name = "Lab"; model.draft?.endpoint = "[fe80::1%en0]::5901"
  let id = model.draft!.id, credential = UUID()
  model.draft?.credentialReference = credential; model.draft?.settings.clipboardSend = true
  try check(model.encodingValues[.quality]?.value == "6" && model.encodingValues[.quality]?.source == .appDefaults, "preview inherits app values")
  model.setEncoding(.quality, value: "4")
  try check(model.encodingValues[.quality]?.value == "4" && model.encodingValues[.quality]?.source == .profile, "preview profile override")
  model.setEncoding(.quality, value: nil)
  try check(model.draft?.settings.encoding == nil && model.encodingValues[.quality]?.source == .appDefaults, "per-field inheritance restores absence")
  model.setEncoding(.quality, value: "5"); model.save(); try await until("save") { !model.isBusy }
  try check(model.canUse && !model.hasChanges && model.profiles.count == 1, "save enables use")
  model.draft?.name = "Discard"; model.cancelEdits()
  try check(model.draft?.name == "Lab" && model.draft?.credentialReference == credential, "cancel and credential-reference preservation")
  let snapshot = try await store.read()
  _ = try await store.recordRecent("recent", expected: snapshot.revision)
  model.draft?.name = "Stale"; model.save(); try await until("conflict") { !model.isBusy }
  try check(model.error == .conflict && model.needsReload && model.draft?.name == "Stale", "stale save preserves draft and blocks retry")
  model.cancelEdits(); model.refreshIfClean()
  try check(model.needsReload && !model.isBusy, "cancel/activation do not clear conflict")
  model.reload(); try await until("reload") { !model.isBusy }
  try check(model.draft?.id == id && model.draft?.name == "Lab", "explicit reload retains selection, discards stale draft")
  backing.fail(afterWrite: true); model.draft?.name = "Accepted"; model.save()
  try await until("uncertain") { !model.isBusy }
  try check(model.error == .ioFailure && !model.canUse, "uncertain save needs reconciliation")
  let writes = backing.writes; backing.fail(); model.reload(); try await until("reconciled") { !model.isBusy }
  try check(model.draft?.name == "Accepted" && backing.writes == writes, "reload reconciles without replay")
  model.deleteSelected(); try await until("delete") { !model.isBusy }
  let remaining = try await store.read()
  try check(remaining.profiles.isEmpty && remaining.recentEndpoints == ["recent"], "profile deletion preserves history")
  backing.fail(read: .futureSchema); model.reload(); try await until("future") { !model.isBusy }
  try check(model.error == .futureSchema && !model.hasLoaded && model.profiles.isEmpty, "invalid read suppresses stale list")
  await model.close(); await store.close(); await preferences.close()
  print("PASS profile create/edit/cancel, inheritance, credential reference, stale and uncertain saves, delete/history isolation")
}
@MainActor func launch() async throws {
  let runtime = try NativeRuntime(), backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing)
  let preferencesBacking = Preferences(), preferences = NativePreferencesStore(backing: preferencesBacking)
  var appEncoding = NativeEncodingPreferences(); try appEncoding.set(.quality, value: "6")
  _ = try await preferences.commit(.init(clipboardSend: false, clipboardReceive: false, encoding: appEncoding), expected: (try await preferences.read()).revision)
  var profileEncoding = NativeEncodingPreferences(); try profileEncoding.set(.quality, value: "4")
  var profile = NativeConnectionProfile(name: "Lab", endpoint: "original", settings: .init(clipboardSend: true, encoding: profileEncoding))
  let original = try await store.upsert(profile, expected: nil)
  profile.endpoint = "fresh"
  let current = try await store.upsert(profile, expected: original.revision)
  let model = ConnectionModel(runtime: runtime, preferences: preferences, profileStore: store, profileID: profile.id) { _, _ in }
  try await until("profile session") { model.defaults?.isReady == true }
  guard let session = model.session else { throw Failure(message: "Missing profile session") }
  let encoding = try session.encodingOptions().value(for: .quality)
  try check(model.endpoint == "fresh" && session.clipboardSendEnabled && !session.clipboardReceiveEnabled, "fresh profile before session and clipboard precedence")
  try check(encoding.value == "4" && encoding.source == .profile, "profile encoding precedes negotiation")
  _ = try await store.deleteProfile(id: profile.id, expected: current.revision)
  try check(model.canConnect && model.endpoint == "fresh", "deleting profile doesn't mutate existing connection")
  let missing = NativeSessionDefaults(runtime: runtime, store: preferences, profileStore: store, profileID: profile.id)
  missing.load(); try await until("missing profile") { !missing.isLoading }
  missing.useBuiltInDefaults()
  try check(missing.profileError == .notFound && missing.session == nil && !missing.isLoading, "missing profile has no silent fallback")
  let restored = try await store.upsert(profile, expected: (try await store.read()).revision)
  try preferencesBacking.write(Data("corrupt".utf8))
  let fallback = NativeSessionDefaults(runtime: runtime, store: preferences, profileStore: store, profileID: profile.id)
  fallback.load(); try await until("failed app defaults") { !fallback.isLoading }
  try check(fallback.error == .corrupt && fallback.session == nil, "bad app defaults block profile session")
  fallback.useBuiltInDefaults(); try await until("explicit fallback with profile") { !fallback.isLoading }
  try check(fallback.isReady && fallback.session?.clipboardSendEnabled == true && fallback.session?.clipboardReceiveEnabled == true, "explicit built-ins still apply selected profile")
  try check(fallback.profile?.id == restored.profiles.first?.id, "fallback retains selected profile")
  await model.close(); await missing.close(); await fallback.close(); await preferences.close(); await store.close(); try await runtime.shutdown()
  print("PASS actual controller fresh profile launch, app/profile precedence, deletion isolation and explicit defaults failure recovery")
}
@MainActor func lifetime() async throws {
  let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing)
  let preferences = NativePreferencesStore(backing: Preferences()), runtime = try NativeRuntime()
  let profile = NativeConnectionProfile(name: "Held", endpoint: "localhost")
  _ = try await store.upsert(profile, expected: nil)
  let read = HistoryGate(); backing.gate(read: read)
  let defaults = NativeSessionDefaults(runtime: runtime, store: preferences, profileStore: store, profileID: profile.id)
  defaults.load(); try await until("profile read held") { read.isEntered }
  var joined = false
  let join = Task { await defaults.close(); joined = true }
  try await Task.sleep(for: .milliseconds(5)); try check(!joined, "close waits without blocking MainActor")
  read.release(); await join.value
  try check(defaults.session == nil && !defaults.isReady, "pending profile read cannot allocate late session")
  let model = NativeProfileLibrary(store: store, preferences: preferences)
  model.reload(); try await until("editor load") { !model.isBusy }; model.select(profile.id)
  model.draft?.name = "Accepted"
  let write = HistoryGate(); backing.gate(write: write); model.save()
  try await until("accepted write") { write.isEntered }
  var saved = false
  let saveJoin = Task { await model.close(); saved = true }
  try await Task.sleep(for: .milliseconds(5)); try check(!saved, "close joins accepted write")
  write.release(); await saveJoin.value
  let snapshot = try await store.read()
  try check(snapshot.profiles.first?.name == "Accepted" && model.profiles.first?.name == "Held", "accepted save survives without late publication")
  let weakGate = HistoryGate(); backing.gate(read: weakGate)
  var disposable: NativeProfileLibrary? = NativeProfileLibrary(store: store, preferences: preferences)
  let reference = WeakReference(disposable); disposable?.reload()
  try await until("weak read") { weakGate.isEntered }; disposable = nil
  try check(reference.value == nil, "pending load doesn't retain editor")
  weakGate.release(); await store.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS MainActor progress, profile-load cancellation, accepted-save drain and weak editor disposal")
}
@main struct NativeProfileLibraryTests {
  @MainActor static func main() async {
    do { try await editing(); try await launch(); try await lifetime() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
