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
  return Data("{\"schema\":\(schema ?? (profile ? 9 : 10)),\"revision\":\"00000000-0000-0000-0000-000000000001\",\(body)}".utf8)
}
func stores() async throws {
  for profile in [false,true] {
    for schema in 1...(profile ? 8 : 9) {
      let bytes = record("",profile:profile,schema:schema), memory = Memory(bytes)
      if profile {
        let store = NativeProfileHistoryStore(backing:memory), saved = try await store.read()
        try check(try memory.read() == bytes && memory.writes == 0 && saved.profiles[0].settings.fullscreen == nil,"old profile read preserves bytes")
        var value = saved.profiles[0]; value.settings.fullscreen = .init(startsFullscreen:true,mode:"selected",selectedDisplays:["z","a"])
        _ = try await store.upsert(value,expected:saved.revision)
        let reopened = try await store.read()
        try check(reopened.profiles[0].settings.fullscreen == .init(startsFullscreen:true,mode:"selected",selectedDisplays:["a","z"]),"profile canonical round trip")
        var invalid = reopened.profiles[0]; invalid.settings.fullscreen = .init(mode:"bogus")
        do { _ = try await store.upsert(invalid,expected:reopened.revision); throw Failure(message:"invalid profile save succeeded") } catch NativeStorageError.invalid {}
        try check(memory.writes == 1,"invalid profile save leaves stored bytes untouched")
        await store.close()
      } else {
        let store = NativePreferencesStore(backing:memory), saved = try await store.read()
        try check(try memory.read() == bytes && memory.writes == 0 && saved.values.fullscreen == nil,"old defaults read preserves bytes")
        _ = try await store.commit(.init(fullscreen:.init(startsFullscreen:true,mode:"selected",selectedDisplays:["z","a"])),expected:saved.revision)
        let reopened = try await store.read()
        try check(reopened.values.fullscreen == .init(startsFullscreen:true,mode:"selected",selectedDisplays:["a","z"]),"defaults canonical round trip")
        do { _ = try await store.commit(.init(fullscreen:.init(mode:"bogus")),expected:reopened.revision); throw Failure(message:"invalid defaults save succeeded") } catch NativePreferencesError.invalidValue {}
        try check(memory.writes == 1,"invalid defaults save leaves stored bytes untouched")
        await store.close()
      }
      try check((try JSONSerialization.jsonObject(with:memory.read()!) as! [String:Any])["schema"] as? Int == (profile ? 10 : 11),"current schema writer")
    }
    let invalid = ["null", "[]", "{\"startsFullscreen\":1}", "{\"startsFullscreen\":\"true\"}", "{\"startsFullscreen\":null}", "{\"mode\":false}", "{\"mode\":\"bogus\"}", "{\"selectedDisplays\":null}", "{\"selectedDisplays\":[1]}", "{\"selectedDisplays\":[\"a\",\"a\"]}", "{\"selectedDisplays\":[\"\"]}", "{\"selectedDisplays\":[\"a\\n\"]}", "{\"unknown\":true}", "{\"selectedDisplays\":[\"" + String(repeating:"a",count:257) + "\"]}", "{\"selectedDisplays\":[" + (0..<65).map { "\"id\($0)\"" }.joined(separator:",") + "]}"]
    for value in invalid {
      let bytes = record("\"fullscreen\":\(value)",profile:profile), memory = Memory(bytes)
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
    let memory = Memory(record("\"fullscreen\":{}",profile:profile,schema:profile ? 8 : 9))
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
  let base = try NativePreferences(fullscreen:.init(startsFullscreen:true,mode:"all",selectedDisplays:["missing"])).applying(to:.init())
  let result = try NativeConnectionProfile(name:"Lab",endpoint:"host",settings:.init(fullscreen:.init(mode:"selected"))).applying(to:base)
  try check(result.fullscreenPolicy.startsFullscreen && result.fullscreenPolicy.selection == .selected([.init("missing")]),"profile inherits saved IDs independently")
  try check(result.fullscreenSources[.startsFullscreen] == .appDefaults && result.fullscreenSources[.mode] == .profile && result.fullscreenSources[.selectedDisplays] == .appDefaults,"per-field source precedence")
  let cleared = try NativeConnectionProfile(name:"Lab",endpoint:"host",settings:.init(fullscreen:.init(selectedDisplays:[]))).applying(to:base)
  try check(cleared.fullscreenPolicy.selectedDisplays.isEmpty && cleared.fullscreenPolicy.mode == .all,"explicit empty clears inactive IDs")
  do { _ = try NativeFullscreenPreferences(mode:"selected",selectedDisplays:[]).resolved(); throw Failure(message:"empty selection resolved") } catch NativePreferencesError.invalidValue {}
  let memory = Memory(), store = NativeProfileHistoryStore(backing:memory)
  let profile = NativeConnectionProfile(name:"Inherited",endpoint:"host",settings:.init(fullscreen:.init(mode:"selected")))
  _ = try await store.upsert(profile,expected:nil)
  let reopened = try await store.read()
  try check(reopened.profiles[0].settings.fullscreen?.selectedDisplays == nil,"profile can save independent inherited IDs")
  await store.close()
  print("PASS strict fullscreen persistence, old schemas, canonicalization and per-field precedence")
}
@MainActor func isolation() async throws {
  let runtime = try NativeRuntime(), memory = Memory(), store = NativePreferencesStore(backing:memory)
  let initial = try await store.read()
  _ = try await store.commit(.init(fullscreen:.init(startsFullscreen:true,mode:"selected",selectedDisplays:["missing"])),expected:initial.revision)
  let first = try NativeSession(runtime:runtime,configuration:(try await store.read()).values.applying(to:.init()))
  _ = try await store.commit(.init(fullscreen:.init(startsFullscreen:false,mode:"all")),expected:(try await store.read()).revision)
  let second = try NativeSession(runtime:runtime,configuration:(try await store.read()).values.applying(to:.init()))
  try check(first.initialFullscreenPolicy.startsFullscreen && first.initialFullscreenPolicy.selectedDisplays == [.init("missing")] && !second.initialFullscreenPolicy.startsFullscreen && second.initialFullscreenPolicy.mode == .all,"saved changes affect only new sessions")
  try check(first.initialFullscreenSources[.selectedDisplays] == .appDefaults && second.initialFullscreenSources[.selectedDisplays] == nil,"new sessions capture independent field sources")
  try await first.close(); try await second.close(); await store.close(); try await runtime.shutdown()
}
@main struct Main {
  static func main() async {
    do { try await stores(); try await isolation() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
