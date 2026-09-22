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
func record(_ security: String?,profile: Bool = false,schema: Int? = nil) -> Data {
  let values = security.map { "\"security\":\($0)" } ?? ""
  let content = profile ? "\"profiles\":[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\",\"endpoint\":\"host\",\"settings\":{\(values)}}],\"recentEndpoints\":[\"recent\"]" : "\"values\":{\(values)}"
  return Data("{\"schema\":\(schema ?? (profile ? 6 : 7)),\"revision\":\"00000000-0000-0000-0000-000000000001\",\(content)}".utf8)
}
func selectionAndStores() async throws {
  let catalog = try NativeSecuritySelection.choices(), defaults = try NativeSecuritySelection()
  try check(catalog.count == 15 && Set(catalog.map(\.id)).count == 15,"complete nonduplicated catalog")
  try check(Set(defaults.types) == Set(catalog.filter(\.available).map(\.id)),"catalog availability matches compiled defaults")
  try check(try NativeSecuritySelection(" vNcAuth,Plain, vncAuth ").canonical == "VncAuth,Plain","canonical names and duplicates")
  try check(try NativeSecuritySelection("").types.isEmpty,"empty selection denies all")
  for choice in catalog {
    if choice.available { try check(try NativeSecuritySelection(choice.name).types == [choice.id],"every compiled selection resolves") }
    else {
      do { _ = try NativeSecuritySelection(choice.name); throw Failure(message:"uncompiled choice accepted") }
      catch let error as NativeError { try check(error.status == .unsupported,"uncompiled choice typed error") }
    }
  }
  for schema in 1...6 {
    let original = record(nil,schema:schema), backing = Memory(original), store = NativePreferencesStore(backing:backing)
    let snapshot = try await store.read()
    try check(try backing.read() == original && backing.writes == 0,"legacy defaults read preserves exact bytes")
    let saved = try await store.commit(.init(security:.init(types:" vNcAuth,Plain,vncAuth ")),expected:snapshot.revision)
    let reopened = NativePreferencesStore(backing:backing), current = try await reopened.read()
    try check(current == saved && current.values.security?.types == "VncAuth,Plain","explicit save canonicalizes and survives reopen")
    try check((try JSONSerialization.jsonObject(with:backing.read()!) as! [String:Any])["schema"] as? Int == 11,"defaults schema upgrade")
    await store.close(); await reopened.close()
  }
  for schema in 1...5 {
    let original = record(nil,profile:true,schema:schema), backing = Memory(original), store = NativeProfileHistoryStore(backing:backing)
    let snapshot = try await store.read(); var draft = snapshot.profiles[0]
    try check(try backing.read() == original && backing.writes == 0,"legacy profile read preserves bytes")
    draft.settings.security = .init(types:"")
    let saved = try await store.upsert(draft,expected:snapshot.revision)
    let reopened = NativeProfileHistoryStore(backing:backing), current = try await reopened.read()
    try check(current == saved && current.profiles[0].settings.security?.types == "" && current.recentEndpoints == ["recent"],"explicit deny-all and history preserved")
    try check((try JSONSerialization.jsonObject(with:backing.read()!) as! [String:Any])["schema"] as? Int == 12,"profile schema upgrade")
    await store.close(); await reopened.close()
  }
  var base = NativeSessionConfiguration(); base.securityTypes = [2]; base.securitySource = .session
  let inherited = try NativePreferences(security:.init()).applying(to:base)
  try check(inherited.securityTypes == [2] && inherited.securitySource == .session,"nil patch inherits caller configuration")
  let app = try NativePreferences(security:.init(types:"VncAuth,Plain")).applying(to:base)
  let profile = try NativeConnectionProfile(name:"Lab",endpoint:"host",settings:.init(security:.init(types:"None"))).applying(to:app)
  try check(app.securityTypes == [2,256] && app.securitySource == .appDefaults && profile.securityTypes == [1] && profile.securitySource == .profile,"whole-list precedence without union or broadening")
  print("PASS compiled catalog, canonical selections, old-schema read preservation, explicit upgrades and whole-list precedence")
}
func invalidRecords() async throws {
  var cases: [(String,NativePreferencesError,NativeStorageError)] = [
    ("null",.corrupt,.corrupt),("[]",.corrupt,.corrupt),("{\"types\":[]}",.corrupt,.corrupt),
    ("{\"types\":1}",.corrupt,.corrupt),("{\"types\":null}",.corrupt,.corrupt),
    ("{\"secret\":\"hidden\"}",.unsupportedFields,.unsupportedFields),
    ("{\"types\":\"VeNCrypt\"}",.invalidValue,.invalid),("{\"types\":\"None,,Plain\"}",.invalidValue,.invalid),
    ("{\"types\":\"None\\u0000Plain\"}",.invalidValue,.invalid),
    ("{\"types\":\""+String(repeating:"x",count:1025)+"\"}",.invalidValue,.invalid)]
  if let unavailable = try NativeSecuritySelection.choices().first(where: { !$0.available }) {
    cases.append(("{\"types\":\"\(unavailable.name)\"}",.unsupportedValue,.unsupportedValue))
  }
  for (value,expected,profileExpected) in cases {
    let data = record(value), backing = Memory(data), store = NativePreferencesStore(backing:backing)
    do { _ = try await store.read(); throw Failure(message:"invalid defaults read") }
    catch let error as NativePreferencesError { try check(error == expected,"typed defaults error") }
    do { _ = try await store.reset(expected:.init(value:nil)); throw Failure(message:"invalid defaults reset") }
    catch let error as NativePreferencesError { try check(error == expected,"reset cannot overwrite unreadable data") }
    try check(try backing.read() == data && backing.writes == 0,"bad defaults preserved")
    let profileData = record(value,profile:true), profileBacking = Memory(profileData), library = NativeProfileHistoryStore(backing:profileBacking)
    do { _ = try await library.read(); throw Failure(message:"invalid profile read") }
    catch let error as NativeStorageError { try check(error == profileExpected,"typed profile error") }
    do { _ = try await library.clearHistory(expected:nil); throw Failure(message:"bad profile overwritten") }
    catch let error as NativeStorageError { try check(error == profileExpected,"history cannot overwrite unreadable data") }
    try check(try profileBacking.read() == profileData && profileBacking.writes == 0,"bad profile preserved")
    await store.close(); await library.close()
  }
  let old = NativePreferencesStore(backing:Memory(record("{}",schema:5)))
  do { _ = try await old.read(); throw Failure(message:"security accepted in old defaults") } catch NativePreferencesError.unsupportedFields {}
  await old.close()
  let oldProfile = NativeProfileHistoryStore(backing:Memory(record("{}",profile:true,schema:4)))
  do { _ = try await oldProfile.read(); throw Failure(message:"security accepted in old profile") } catch NativeStorageError.unsupportedFields {}
  await oldProfile.close()
  print("PASS closed security records, wrong types, unsupported/unknown methods, bounds and no fallback/rewrite")
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"model timed out")
}
@MainActor func modelsAndWire() async throws {
  let backing = Memory(), store = NativePreferencesStore(backing:backing), editor = NativePreferencesDraft(store:store)
  editor.reload(); try await until { !editor.isBusy }
  editor.values.security = .init(types:"Unknown")
  try check(!editor.canApply,"invalid security disables Apply"); editor.apply()
  try check(backing.writes == 0,"invalid draft cannot write"); editor.cancel()
  try check(editor.values.security == nil,"Cancel restores inheritance")
  editor.values.security = .init(types:"VncAuth"); editor.apply(); try await until { !editor.isBusy }
  let runtime = try NativeRuntime(), restricted = NativeSessionDefaults(runtime:runtime,store:store)
  restricted.load(); try await until { !restricted.isLoading }
  guard let restrictedSession = restricted.session else { throw Failure(message:"missing restricted session") }
  try check(restrictedSession.initialSecurityTypes == [2] && restrictedSession.initialSecuritySource == .appDefaults,"app policy installed before connection")
  let profiles = NativeProfileHistoryStore(backing:Memory()), library = NativeProfileLibrary(store:profiles,preferences:store)
  library.reload(); try await until { !library.isBusy }; library.newProfile()
  library.draft?.name = "Loopback"; library.draft?.endpoint = "localhost"
  library.draft?.settings.security = .init(types:"Unknown"); try check(!library.canSave,"invalid profile gates Save")
  library.draft?.settings.security = .init(types:"None"); library.save(); try await until { !library.isBusy }
  let profiled = NativeSessionDefaults(runtime:runtime,store:store,profileStore:profiles,profileID:library.draft!.id)
  profiled.load(); try await until { !profiled.isLoading }
  guard let session = profiled.session else { throw Failure(message:"missing profile session") }
  try check(session.initialSecurityTypes == [1] && session.initialSecuritySource == .profile,"profile replaces app allow-list")
  let acceptedPeer = native_test_peer_create_pattern(0)!, deniedPeer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(acceptedPeer); native_test_peer_destroy(deniedPeer) }
  let connection = Task { try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(acceptedPeer))") }
  do { _ = try await restrictedSession.connect(endpoint:"127.0.0.1::\(native_test_peer_port(deniedPeer))"); throw Failure(message:"connected through disabled None method") }
  catch let failure as NativeCommandFailure { try check(failure.snapshot.endReason == .protocolFailure,"no enabled method fails without authentication fallback") }
  _ = try await connection.value
  try check(session.snapshot.state == .connected && session.information?.securityType == 1 && restrictedSession.prompt == nil,"independent profile connects while defaults reject same server method")
  editor.values.security = .init(types:""); editor.apply(); try await until { !editor.isBusy }
  let next = NativeSessionDefaults(runtime:runtime,store:store); next.load(); try await until { !next.isLoading }
  try check(next.session?.initialSecurityTypes == [] && restrictedSession.initialSecurityTypes == [2] && session.initialSecurityTypes == [1],"saved deny-all affects only new windows")
  try check(session.snapshot.state == .connected,"saving security never renegotiates existing session")
  await next.close(); await profiled.close(); await restricted.close(); try await runtime.shutdown()
  await library.close(); await profiles.close(); await editor.close(); await store.close()
  print("PASS Apply/Cancel, profile validation, new-window-only policy, two real loopback sessions and no disabled-method fallback")
}

func priorityStores() async throws {
  let tlsAvailable = try NativeSecuritySelection.choices().contains { $0.protection == .x509TLS && $0.available }
  let expression = "NORMAL:-VERS-ALL:+VERS-TLS1.2"
  for profile in [false,true] {
    let schema = profile ? 6 : 7
    for fields in ["{\"tlsPriority\":null}","{\"tlsPriority\":1}","{\"extra\":\"NORMAL\"}"] {
      let bytes = record(fields,profile:profile), memory = Memory(bytes)
      if profile {
        let store = NativeProfileHistoryStore(backing:memory)
        do { _ = try await store.read(); throw Failure(message:"bad priority record accepted") }
        catch is NativeStorageError {}
        await store.close()
      } else {
        let store = NativePreferencesStore(backing:memory)
        do { _ = try await store.read(); throw Failure(message:"bad priority record accepted") }
        catch is NativePreferencesError {}
        await store.close()
      }
      try check(try memory.read() == bytes && memory.writes == 0,"invalid priority preserves record")
    }
    let bytes = record("{\"tlsPriority\":\"\"}",profile:profile,schema:schema-1), memory = Memory(bytes)
    if profile {
      let store = NativeProfileHistoryStore(backing:memory)
      do { _ = try await store.read(); throw Failure(message:"old profile accepted new priority field") }
      catch NativeStorageError.unsupportedFields {}
      await store.close()
    } else {
      let store = NativePreferencesStore(backing:memory)
      do { _ = try await store.read(); throw Failure(message:"old defaults accepted new priority field") }
      catch NativePreferencesError.unsupportedFields {}
      await store.close()
    }
    try check(try memory.read() == bytes && memory.writes == 0,"old schema preserves unsupported fields")
  }
  let memory = Memory(), store = NativePreferencesStore(backing:memory), initial = try await store.read()
  for invalid in ["NORMAL:+not-an-algorithm", "NORMAL\0suffix", String(repeating:"x",count:4097)] {
    do { _ = try await store.commit(.init(security:.init(tlsPriority:invalid)),expected:initial.revision); throw Failure(message:"bad priority saved") }
    catch let error as NativePreferencesError {
      try check(error == .invalidTLSPriority || (!tlsAvailable && error == .unsupportedValue),"typed invalid or unsupported priority")
    }
    try check(memory.writes == 0,"rejection precedes write")
  }
  let saved = try await store.commit(.init(security:.init(types:" vNcAuth ",tlsPriority:tlsAvailable ? expression : "")),expected:initial.revision)
  let read = try await store.read()
  try check(saved == read && read.values.security?.tlsPriority == (tlsAvailable ? expression : ""),"priority expression round trip without canonicalization")
  var base = try read.values.applying(to:NativeSessionConfiguration())
  try check(base.securitySource == .appDefaults && base.tlsPrioritySource == .appDefaults,"independent app sources")
  let profile = NativeConnectionProfile(name:"TLS",endpoint:"host",settings:.init(security:.init(tlsPriority:"")))
  base = try profile.applying(to:base)
  try check(base.tlsPriority.isEmpty && base.tlsPrioritySource == .profile && base.securityTypes == [2] && base.securitySource == .appDefaults,"priority-only profile resets library default and inherits method list")
  await store.close()
  print("PASS priority bounds, backend availability, closed schemas, prewrite rejection, exact persistence and independent inheritance")
}
@MainActor func priorityModels() async throws {
  let available = try NativeSecuritySelection.choices().contains { $0.protection == .x509TLS && $0.available }
  let memory = Memory(), store = NativePreferencesStore(backing:memory), model = NativePreferencesDraft(store:store)
  model.reload(); try await until { !model.isBusy }
  if available {
    model.values.security = .init(tlsPriority:"NORMAL:+bad-algorithm"); model.apply(); try await until { !model.isBusy }
    try check(model.error == .invalidTLSPriority && !model.needsReload && memory.writes == 0,"invalid Apply remains correctable without changing revision")
  }
  model.values.security = .init(tlsPriority:available ? "NORMAL" : "")
  model.cancel(); try check(model.values.security == nil,"priority Cancel restores inheritance")
  model.values.security = .init(tlsPriority:available ? "NORMAL" : ""); model.apply(); try await until { !model.isBusy }
  let runtime = try NativeRuntime(), old = NativeSessionDefaults(runtime:runtime,store:store)
  old.load(); try await until { !old.isLoading }
  try check(old.session?.initialTLSPriority == (available ? "NORMAL" : "") && old.session?.initialTLSPrioritySource == .appDefaults,"session captured priority and source")
  let profiles = NativeProfileHistoryStore(backing:Memory()), library = NativeProfileLibrary(store:profiles,preferences:store)
  library.reload(); try await until { !library.isBusy }; library.newProfile()
  library.draft?.name = "TLS"; library.draft?.endpoint = "localhost"
  if available {
    library.draft?.settings.security = .init(tlsPriority:"NORMAL:+bad-algorithm"); library.save(); try await until { !library.isBusy }
    try check(library.error == .invalidTLSPriority && !library.needsReload && library.canEdit,"invalid profile Save remains correctable")
  }
  library.draft?.settings.security = .init(tlsPriority:""); library.save(); try await until { !library.isBusy }
  let profiled = NativeSessionDefaults(runtime:runtime,store:store,profileStore:profiles,profileID:library.draft!.id)
  profiled.load(); try await until { !profiled.isLoading }
  try check(profiled.session?.initialTLSPriority == "" && profiled.session?.initialTLSPrioritySource == .profile,"profile reset captured before connection")
  model.values.security = .init(tlsPriority:""); model.apply(); try await until { !model.isBusy }
  let next = NativeSessionDefaults(runtime:runtime,store:store); next.load(); try await until { !next.isLoading }
  try check(next.session?.initialTLSPriority == "" && old.session?.initialTLSPriority == (available ? "NORMAL" : ""),"later saves affect only new windows")
  await next.close(); await profiled.close(); await old.close(); try await runtime.shutdown()
  await library.close(); await profiles.close(); await model.close(); await store.close()
  print("PASS priority Apply/Cancel, correctable profile errors and per-window snapshots")
}

@MainActor func reconfigureSession() async throws {
  let runtime = try NativeRuntime()
  var config = NativeSessionConfiguration(); config.securityTypes = [1,1]
  let session = try runtime.makeSession(configuration:config), other = try runtime.makeSession(configuration:config)
  let peers = (0..<4).map { _ in native_test_peer_create_pattern(0)! }
  defer { for peer in peers { native_test_peer_destroy(peer) } }
  func address(_ index: Int) -> String { "127.0.0.1::\(native_test_peer_port(peers[index]))" }
  if try NativeSecuritySelection.choices().contains(where: { $0.protection == .x509TLS && $0.available }) {
    var bounded = config; bounded.caFile = "/" + String(repeating:"c",count:4095)
    bounded.tlsPriority = String(repeating:"p",count:4096)
    let copy = try runtime.makeSession(configuration:bounded)
    let owned = try copy.securityConfiguration()
    try check(owned.trustFiles.caFile == bounded.caFile && owned.preferences.tlsPriority == bounded.tlsPriority,"full 4096-byte C arrays survive Swift import without truncation")
    try await copy.close()
  }
  let initial = try session.securityConfiguration()
  try check(initial.editable && initial.revision == 1 && initial.preferences.types == "None","owned initial security snapshot")
  _ = try await session.connect(endpoint:address(0)); _ = try await other.connect(endpoint:address(1))
  let connected = try session.securityConfiguration()
  do { try session.setSecurity(.init(types:"VncAuth",tlsPriority:""),trustFiles:.init(caFile:"",crlFile:""),expected:connected); throw Failure(message:"changed active security") }
  catch let error as NativeError { try check(error.status == .busy,"active attempt rejects policy mutation") }
  _ = try await session.disconnect()
  var commits = 0
  let editor = try NativeSessionSecurityDraft(session:session,onApplied: { commits += 1 })
  editor.reload(); try check(!editor.hasChanges && editor.preferences.types == nil,"initial duplicate allow-list resolves to inherited canonical policy")
  editor.preferences.types = "VncAuth"; editor.cancelEdits()
  try check(!editor.hasChanges && commits == 0,"Cancel restores connection draft without committing")
  if editor.choices.contains(where: { $0.protection == .x509TLS && $0.available }) {
    editor.preferences.tlsPriority = "NORMAL:+invalid-algorithm"
  } else { editor.trustFiles.caFile = "/missing/unsupported.pem" }
  editor.apply(); try await until { !editor.isBusy }
  try check(editor.error != nil && !editor.needsReload && commits == 0,"invalid or unsupported connection setting remains correctable without applying")
  editor.cancelEdits()
  editor.preferences.types = "VncAuth"; editor.apply(); editor.cancelApply(); try await until { !editor.isBusy }
  try check(try session.securityConfiguration().revision == 1 && commits == 0,"cancelled preflight cannot mutate policy")
  let stale = try NativeSessionSecurityDraft(session:session); stale.reload()
  editor.preferences.types = "VncAuth"; editor.apply(); try await until { !editor.isBusy }
  try check(editor.didApply && commits == 1 && session.initialSecurityTypes == [1,1],"explicit connection override leaves original snapshot intact")
  stale.preferences.types = "Plain"; stale.apply(); try await until { !stale.isBusy }
  try check(stale.needsReload && !stale.didApply,"competing editor revision is rejected")
  try check(try other.securityConfiguration().revision == 1 && other.snapshot.state == .connected,"other window stays connected with unchanged security")
  do { _ = try await session.connect(endpoint:address(2)); throw Failure(message:"new method restriction not used on reconnect") }
  catch let failure as NativeCommandFailure { try check(failure.snapshot.endReason == .protocolFailure,"updated policy denies None-only peer") }
  try check(editor.needsReload,"attempt generation invalidates open draft")
  editor.reload(); editor.preferences.types = nil // Restore this window's initial None selection.
  editor.apply(); try await until { !editor.isBusy }
  try check(editor.didApply && commits == 2,"restore initial security for next attempt")
  _ = try await session.connect(endpoint:address(3))
  try check(session.snapshot.state == .connected && other.snapshot.state == .connected,"same session reconnects under new policy while other remains live")
  await editor.close(); await stale.close(); try await session.close(); try await other.close(); try await runtime.shutdown()
  print("PASS disconnected security CAS, cancellation, competing drafts, reconnect policy and independent live sessions")
}
@MainActor func reconfigureController() async throws {
  let runtime = try NativeRuntime(), memory = Memory(), preferences = NativePreferencesStore(backing:memory)
  let controller = ConnectionModel(runtime:runtime,preferences:preferences,onSession: { _,_ in })
  try await until { controller.session != nil }; controller.endpoint = "localhost"
  try check(controller.canOpenSecurity && controller.canConnect,"idle connection offers security editing")
  controller.openSecurity(); guard let draft = controller.securityDraft else { throw Failure(message:"missing controller security draft") }
  try check(!controller.canConnect && !controller.canOpenSecurity,"editor excludes connection admission and duplicate editor")
  draft.preferences.types = "None"; draft.apply(); try await until { !draft.isBusy }
  try check(draft.didApply && memory.writes == 0,"connection override never writes durable defaults")
  controller.closeSecurity(); try await until { controller.canOpenSecurity }
  controller.openSecurity(); controller.securityDraft?.preferences.types = "Plain"
  controller.securityDraft?.apply(); controller.requestClose(); await controller.close()
  try check(controller.closing && controller.securityDraft == nil,"close cancels editor and joins preflight")
  await preferences.close(); try await runtime.shutdown()
  print("PASS controller editor admission, session-only changes and close/drain")
}
@main struct NativeSecurityTests {
  @MainActor static func main() async {
    do { try await reconfigureSession(); try await reconfigureController(); try await priorityStores(); try await priorityModels(); try await selectionAndStores(); try await invalidRecords(); try await modelsAndWire() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
