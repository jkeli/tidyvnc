// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC
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
  let values = fields.map { "\"trustFiles\":\($0)" } ?? ""
  let content = profile ? "\"profiles\":[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\",\"endpoint\":\"host\",\"settings\":{\(values)}}],\"recentEndpoints\":[\"recent\"]" : "\"values\":{\(values)}"
  return Data("{\"schema\":\(schema ?? (profile ? 4 : 5)),\"revision\":\"00000000-0000-0000-0000-000000000001\",\(content)}".utf8)
}
func persistence() async throws {
  // Nonexistent paths demonstrate that editing/storage performs no file IO.
  let files = NativeTrustFiles(caFile: "/missing/测试 CA.pem",crlFile: "")
  for profile in [false,true] {
    for schema in 1...(profile ? 3 : 4) {
      let original = record(nil,profile: profile,schema: schema), backing = Memory(original)
      if profile {
        let store = NativeProfileHistoryStore(backing: backing), snapshot = try await store.read()
        try check(try backing.read() == original && backing.writes == 0,"old profile bytes unchanged on read")
        var draft = snapshot.profiles[0]; draft.settings.trustFiles = files
        let saved = try await store.upsert(draft,expected: snapshot.revision)
        let reopened = NativeProfileHistoryStore(backing: backing), current = try await reopened.read()
        try check(current == saved && current.profiles[0].settings.trustFiles == files && current.recentEndpoints == ["recent"],"profile exact paths, explicit empty and history preserved")
        try check((try JSONSerialization.jsonObject(with: backing.read()!) as! [String:Any])["schema"] as? Int == 10,"profile upgrade on save")
        await reopened.close(); await store.close()
      } else {
        let store = NativePreferencesStore(backing: backing), snapshot = try await store.read()
        try check(try backing.read() == original && backing.writes == 0,"old defaults bytes unchanged on read")
        let saved = try await store.commit(.init(trustFiles: files),expected: snapshot.revision)
        let reopened = NativePreferencesStore(backing: backing), current = try await reopened.read()
        try check(current == saved && current.values.trustFiles == files,"defaults exact path and explicit empty preserved")
        try check((try JSONSerialization.jsonObject(with: backing.read()!) as! [String:Any])["schema"] as? Int == 11,"defaults upgrade on save")
        await reopened.close(); await store.close()
      }
    }
  }
  var base = NativeSessionConfiguration(); base.caFile = "/base/ca.pem"; base.crlFile = "/base/crl.pem"
  let app = try NativePreferences(trustFiles: .init(caFile: "/app/ca.pem")).applying(to: base)
  let profile = NativeConnectionProfile(name: "Lab",endpoint: "host",settings: .init(trustFiles: .init(crlFile: "")))
  let resolved = try profile.applying(to: app)
  try check(resolved.caFile == "/app/ca.pem" && resolved.crlFile.isEmpty && base.caFile == "/base/ca.pem","independent field inheritance and explicit no-file override")
  try check(!String(describing: files).contains("missing") && !String(reflecting: files).contains("测试"),"diagnostic descriptions redact paths")
  print("PASS defaults/profile schema upgrades, no read rewrites, exact path ownership and independent inheritance")
}
func validation() async throws {
  let cases: [(String,NativePreferencesError,NativeStorageError)] = [
    ("null",.corrupt,.corrupt),("[]",.corrupt,.corrupt),("{\"caFile\":false}",.corrupt,.corrupt),
    ("{\"crlFile\":null}",.corrupt,.corrupt),("{\"crlFile\":2}",.corrupt,.corrupt),
    ("{\"unknown\":\"\"}",.unsupportedFields,.unsupportedFields),
    ("{\"caFile\":\"~/ca.pem\"}",.invalidValue,.invalid),("{\"crlFile\":\"relative.pem\"}",.invalidValue,.invalid),
    ("{\"caFile\":\"/bad\\u0000.pem\"}",.invalidValue,.invalid),
    ("{\"caFile\":\"/"+String(repeating:"x",count:4096)+"\"}",.invalidValue,.invalid)]
  for (fields,expected,profileExpected) in cases {
    let bytes = record(fields), backing = Memory(bytes), store = NativePreferencesStore(backing: backing)
    do { _ = try await store.read(); throw Failure(message: "accepted invalid defaults") }
    catch let error as NativePreferencesError { try check(error == expected,"typed defaults error") }
    do { _ = try await store.reset(expected: .init(value:nil)); throw Failure(message:"reset invalid defaults") }
    catch let error as NativePreferencesError { try check(error == expected,"invalid defaults preserved") }
    try check(try backing.read() == bytes && backing.writes == 0,"default bytes preserved")
    let profileBytes = record(fields,profile:true), profileBacking = Memory(profileBytes), profiles = NativeProfileHistoryStore(backing:profileBacking)
    do { _ = try await profiles.read(); throw Failure(message:"accepted invalid profile") }
    catch let error as NativeStorageError { try check(error == profileExpected,"typed profile error") }
    do { _ = try await profiles.clearHistory(expected:nil); throw Failure(message:"overwrote invalid profile") }
    catch let error as NativeStorageError { try check(error == profileExpected,"invalid profile preserved") }
    try check(try profileBacking.read() == profileBytes && profileBacking.writes == 0,"profile bytes preserved")
    await profiles.close(); await store.close()
  }
  let old = NativePreferencesStore(backing:Memory(record("{}",schema:4)))
  do { _ = try await old.read(); throw Failure(message:"new field in old defaults schema") } catch NativePreferencesError.unsupportedFields {}
  await old.close()
  let oldProfile = NativeProfileHistoryStore(backing:Memory(record("{}",profile:true,schema:3)))
  do { _ = try await oldProfile.read(); throw Failure(message:"new field in old profile schema") } catch NativeStorageError.unsupportedFields {}
  await oldProfile.close()
  try check(NativeTrustFiles.isValidPath("/"+String(repeating:"x",count:4095)),"exact path byte bound")
  try check(!NativeTrustFiles.isValidPath("/"+String(repeating:"é",count:2048)),"bound counts UTF-8 bytes")
  print("PASS closed typed records, path bounds, old schema rejection and corrupt-state preservation")
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"model timed out")
}
@MainActor func models() async throws {
  let backing = Memory(), store = NativePreferencesStore(backing:backing), draft = NativePreferencesDraft(store:store)
  draft.reload(); try await until { !draft.isBusy }
  draft.values.trustFiles = .init(caFile:"relative")
  try check(!draft.canApply,"invalid file disables Apply"); draft.apply()
  try check(backing.writes == 0,"invalid Apply cannot write")
  draft.values.trustFiles = .init(caFile:"/app/ca.pem",crlFile:"/app/crl.pem")
  draft.cancel(); try check(draft.values.trustFiles == nil && backing.writes == 0,"Cancel discards paths")
  draft.values.trustFiles = .init(caFile:"/app/ca.pem",crlFile:"/app/crl.pem")
  draft.apply(); try await until { !draft.isBusy }
  try check(!draft.hasChanges && draft.error == nil,"Apply stores valid path syntax")
  let profiles = NativeProfileHistoryStore(backing:Memory()), library = NativeProfileLibrary(store:profiles,preferences:store)
  library.reload(); try await until { !library.isBusy }; library.newProfile()
  library.draft?.name = "Lab"; library.draft?.endpoint = "host"
  library.draft?.settings.trustFiles = .init(crlFile:"relative")
  try check(!library.canSave,"invalid path disables profile Save")
  library.draft?.settings.trustFiles = .init(crlFile:"")
  library.save(); try await until { !library.isBusy }
  try check(library.canUse && library.inheritedTrustFiles.caFile == "/app/ca.pem","profile saved with independent inheritance")
  let runtime = try NativeRuntime()
  let defaults = NativeSessionDefaults(runtime:runtime,store:store,profileStore:profiles,profileID:library.draft!.id)
  defaults.load(); try await until { !defaults.isLoading }
  var abiInfo = tidyvnc_abi_info(); abiInfo.size = UInt32(MemoryLayout<tidyvnc_abi_info>.size); abiInfo.version = UInt32(TIDYVNC_ABI_VERSION)
  try checked { tidyvnc_get_abi(&abiInfo,$0) }
  if abiInfo.features & UInt64(TIDYVNC_FEATURE_CERTIFICATE_KEY) != 0 {
    guard let session = defaults.session else { throw Failure(message:"missing configured native session") }
    try check(session.initialTrustFiles == NativeTrustFiles(caFile:"/app/ca.pem",crlFile:""),"profile merged before session construction")
    draft.restoreBuiltInDefaults(); draft.apply(); try await until { !draft.isBusy }
    try check(session.initialTrustFiles.caFile == "/app/ca.pem","changing app defaults leaves existing session immutable")
    let next = NativeSessionDefaults(runtime:runtime,store:store); next.load(); try await until { !next.isLoading }
    try check(next.session?.initialTrustFiles == NativeTrustFiles(caFile:"",crlFile:""),"new window sees reset defaults")
    await next.close()
  } else {
    try check(defaults.session == nil && defaults.error != nil,"TLS-disabled build rejects configured files before connection")
  }
  await defaults.close(); try await runtime.shutdown()
  await library.close(); await profiles.close(); await draft.close(); await store.close()
  print("PASS Apply/Cancel and profile gating, pre-construction merge, existing/new window isolation and unavailable crypto")
}
@main struct NativeTrustFileTests {
  @MainActor static func main() async {
    do { try await persistence(); try await validation(); try await models() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
