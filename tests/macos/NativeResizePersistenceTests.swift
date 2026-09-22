// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message:message) } }
final class Memory: NativePreferencesBacking, NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?, count = 0
  init(_ data: Data? = nil) { bytes = data }
  var writes: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { bytes } }
  func write(_ data: Data) throws { lock.withLock { bytes = data; count += 1 } }
  func replace(_ data: Data, expected: Data?) throws {
    try lock.withLock { guard bytes == expected else { throw NativeStorageError.conflict }; bytes = data; count += 1 }
  }
}
func record(_ value: String, profile: Bool, schema: Int? = nil) -> Data {
  let body = profile ? "\"profiles\":[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\",\"endpoint\":\"host\",\"settings\":{\(value)}}],\"recentEndpoints\":[]" : "\"values\":{\(value)}"
  return Data("{\"schema\":\(schema ?? (profile ? 8 : 9)),\"revision\":\"00000000-0000-0000-0000-000000000001\",\(body)}".utf8)
}
func stores() async throws {
  for profile in [false,true] {
    for schema in 1...(profile ? 7 : 8) {
      let bytes = record("",profile:profile,schema:schema), memory = Memory(bytes)
      if profile {
        let store = NativeProfileHistoryStore(backing:memory), saved = try await store.read()
        try check(try memory.read() == bytes && memory.writes == 0 && saved.profiles[0].settings.remoteResize == nil,"old profile read preserves bytes")
        var value = saved.profiles[0]; value.settings.remoteResize = .init(enabled:false,initialSize:"0008x0004")
        _ = try await store.upsert(value,expected:saved.revision)
        let reopened = try await store.read()
        try check(reopened.profiles[0].settings.remoteResize == .init(enabled:false,initialSize:"8x4"),"profile canonical round trip")
        var invalid = reopened.profiles[0]; invalid.settings.remoteResize = .init(initialSize:"0x4")
        do { _ = try await store.upsert(invalid,expected:reopened.revision); throw Failure(message:"invalid profile save succeeded") } catch NativeStorageError.invalid {}
        try check(memory.writes == 1,"invalid profile save leaves stored bytes untouched")
        await store.close()
      } else {
        let store = NativePreferencesStore(backing:memory), saved = try await store.read()
        try check(try memory.read() == bytes && memory.writes == 0 && saved.values.remoteResize == nil,"old defaults read preserves bytes")
        _ = try await store.commit(.init(remoteResize:.init(enabled:false,initialSize:"0008x0004")),expected:saved.revision)
        let reopened = try await store.read()
        try check(reopened.values.remoteResize == .init(enabled:false,initialSize:"8x4"),"defaults canonical round trip")
        do { _ = try await store.commit(.init(remoteResize:.init(initialSize:"0x4")),expected:reopened.revision); throw Failure(message:"invalid defaults save succeeded") } catch NativePreferencesError.invalidValue {}
        try check(memory.writes == 1,"invalid defaults save leaves stored bytes untouched")
        await store.close()
      }
      try check((try JSONSerialization.jsonObject(with:memory.read()!) as! [String:Any])["schema"] as? Int == 11,"current schema writer")
    }
    let invalid = ["null","{\"enabled\":1}","{\"enabled\":\"true\"}","{\"initialSize\":null}","{\"initialSize\":false}","{\"initialSize\":\"0x2\"}","{\"unknown\":true}"]
    for value in invalid {
      let bytes = record("\"remoteResize\":\(value)",profile:profile), memory = Memory(bytes)
      if profile {
        let store = NativeProfileHistoryStore(backing:memory)
        do { _ = try await store.read(); throw Failure(message:"invalid profile accepted") }
        catch let error as NativeStorageError { try check([.corrupt,.invalid,.unsupportedFields].contains(error),"typed profile failure") }
        await store.close()
      } else {
        let store = NativePreferencesStore(backing:memory)
        do { _ = try await store.read(); throw Failure(message:"invalid defaults accepted") }
        catch let error as NativePreferencesError { try check([.corrupt,.invalidValue,.unsupportedFields].contains(error),"typed defaults failure") }
        await store.close()
      }
      try check(try memory.read() == bytes && memory.writes == 0,"invalid data preserved")
    }
    let memory = Memory(record("\"remoteResize\":{}",profile:profile,schema:profile ? 7 : 8))
    if profile {
      let store = NativeProfileHistoryStore(backing:memory)
      do { _ = try await store.read(); throw Failure(message:"old schema accepted new object") } catch NativeStorageError.unsupportedFields {}
      await store.close()
    } else {
      let store = NativePreferencesStore(backing:memory)
      do { _ = try await store.read(); throw Failure(message:"old schema accepted new object") } catch NativePreferencesError.unsupportedFields {}
      await store.close()
    }
  }
  let base = try NativePreferences(remoteResize:.init(enabled:false,initialSize:"8x4")).applying(to:.init())
  let result = try NativeConnectionProfile(name:"Lab",endpoint:"host",settings:.init(remoteResize:.init(initialSize:""))).applying(to:base)
  try check(!result.resizePolicy.enabled && result.resizePolicy.initialSize.isEmpty,"explicit blank overrides inherited size independently")
  try check(result.resizeSources[.enabled] == .appDefaults && result.resizeSources[.initialSize] == .profile,"per-field source precedence")
  print("PASS strict resize persistence, old schemas, canonicalization and per-field precedence")
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"resize persistence timeout")
}
@MainActor func windows() async throws {
  let runtime = try NativeRuntime(), defaultsMemory = Memory(), profilesMemory = Memory()
  let defaults = NativePreferencesStore(backing:defaultsMemory), profiles = NativeProfileHistoryStore(backing:profilesMemory)
  let initial = try await defaults.read()
  _ = try await defaults.commit(.init(remoteResize:.init(enabled:true,initialSize:"8x4")),expected:initial.revision)
  var profile = NativeConnectionProfile(name:"No resizing",endpoint:"host",settings:.init(remoteResize:.init(enabled:false)))
  _ = try await profiles.upsert(profile,expected:nil)
  let appWindow = NativeSessionDefaults(runtime:runtime,store:defaults)
  let profileWindow = NativeSessionDefaults(runtime:runtime,store:defaults,profileStore:profiles,profileID:profile.id)
  appWindow.load(); profileWindow.load(); try await until { appWindow.isReady && profileWindow.isReady }
  let app = appWindow.session!, overridden = profileWindow.session!
  try check(app.resizeSources[.enabled] == .appDefaults && overridden.resizeSources[.enabled] == .profile && overridden.resizeSources[.initialSize] == .appDefaults,"window captures field sources")
  let peers = (0..<3).map { _ in native_resize_peer_create()! }; defer { peers.forEach { native_resize_peer_destroy($0) } }
  let owner = UUID(), viewport = NativeResizeViewport(width:20,height:10,scale:1,unscaled:false,devicePixels:false,available:true)
  app.remoteResize.update(owner:owner,viewport:viewport); overridden.remoteResize.update(owner:owner,viewport:viewport)
  _ = try await app.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peers[0]))")
  _ = try await overridden.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peers[1]))")
  try await until { app.snapshot.width == 8 && overridden.snapshot.supportsResize }
  try await Task.sleep(for:.milliseconds(180))
  try check(native_resize_peer_count(peers[1]) == 0,"profile disables inherited initial request on wire")
  let saved = try await defaults.read()
  _ = try await defaults.commit(.init(remoteResize:.init(enabled:true,initialSize:"9x5")),expected:saved.revision)
  let nextApp = NativeSessionDefaults(runtime:runtime,store:defaults)
  nextApp.load(); try await until { nextApp.isReady }
  try check(nextApp.session?.resizePolicy.initialSize == "9x5" && nextApp.session?.resizeSources[.initialSize] == .appDefaults,"new app window captures the latest saved size and source")
  profile.settings.remoteResize = .init(enabled:true,initialSize:"")
  _ = try await profiles.upsert(profile,expected:(try await profiles.read()).revision)
  let next = NativeSessionDefaults(runtime:runtime,store:defaults,profileStore:profiles,profileID:profile.id)
  next.load(); try await until { next.isReady }
  let newer = next.session!; newer.remoteResize.update(owner:owner,viewport:viewport)
  _ = try await newer.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peers[2]))")
  try await until { newer.snapshot.supportsResize }; try await Task.sleep(for:.milliseconds(180))
  try check(native_resize_peer_count(peers[2]) == 0 && newer.resizePolicy.initialSize.isEmpty,"explicit blank profile suppresses the new defaults size")
  try check(app.resizePolicy.initialSize == "8x4" && !overridden.resizePolicy.enabled,"saved edits leave existing windows unchanged")
  let draft = NativeRemoteResizePolicyDraft(session:app); draft.enabled = false
  try check(draft.source(.enabled) == .session && draft.source(.initialSize) == .appDefaults,"draft shows changed field source only")
  try check(draft.apply() && app.resizeSources[.enabled] == .session && app.resizeSources[.initialSize] == .appDefaults,"local Apply preserves untouched source")
  try check(defaultsMemory.writes == 2 && profilesMemory.writes == 2,"local Apply writes no durable record")
  await nextApp.close(); await next.close(); await appWindow.close(); await profileWindow.close(); await defaults.close(); await profiles.close(); try await runtime.shutdown()
  print("PASS stored policies reach wire, new-window isolation and local source preservation")
}
@main struct Main {
  static func main() async {
    do { try await stores(); try await windows() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
