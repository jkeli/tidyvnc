// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
func data(_ body: String) -> Data { Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8) }
func values(_ proposal: NativeDefaultsImport) throws -> NativePreferences { try proposal.preferences(acknowledging:Set(proposal.notices.map(\.line))) }
func projection() throws {
  let source = data("""
  ServerName=private-fixture::0
  SecurityTypes=None
  X509CA=private-fixture.pem
  X509CRL=/private-fixture/crl
  Password=private-fixture\\q
  TLSPriority=private-fixture\\q
  Via=private-fixture\\q
  Future=private-fixture\\q
  Audio=private-fixture\\q
  Shared=yes
  ReconnectOnError=no
  SendClipboard=off
  AcceptClipboard=on
  QualityLevel=3
  ViewOnly=on
  EmulateMiddleButton=on
  FullscreenSystemKeys=off
  ShortcutModifiers=Ctrl,Alt
  AlwaysCursor=off
  CursorType=System
  ScalingFactor=125%
  ScalingQuality=AREA
  DesktopPixelUnits=Device
  FullScreen=on
  FullScreenMode=Selected
  FullScreenSelectedMonitors=2
  """)
  for origin in NativeImportOrigin.allCases {
    let proposal = try NativeDefaultsImport(data:source,origin:origin,legacyDisplays:[.init("left"),.init("right")])
    try check(proposal.origin == origin && proposal.categories == Set(NativeDefaultsImportCategory.allCases),"explicit origin and categories")
    do { _ = try proposal.preferences(); throw Failure(message:"Review bypassed") }
    catch let error as NativeDefaultsImportError { try check(error == .reviewRequired,"review all omissions") }
    let value = try values(proposal)
    try check(value.security == nil && value.trustFiles == nil && value.remoteResize == nil,"security and unrepresented settings excluded")
    try check(value.shared == true && value.reconnectOnError == false && value.clipboardSend == false && value.clipboardReceive == true,"ordinary connection/clipboard settings")
    try check(value.encoding?.qualityLevel == 3 && value.encoding?.autoSelect == nil,"only explicit encoding fields")
    try check(value.input?.viewOnly == true && value.input?.emulateMiddle == true && value.input?.shortcutModifiers == 5 && value.input?.fullscreenSystemKeys == false,"input conversion")
    try check(value.input?.cursorFallback == .hidden && proposal.notices.contains(where:{$0.kind == .inactiveCursor && $0.line == 21}),"inactive shape loss surfaced at original line")
    try check(value.scaling?.scaling == "125" && value.scaling?.filter == "area" && value.scaling?.devicePixels == true,"canonical scaling")
    try check(value.fullscreen?.selectedDisplays == ["right"] && value.fullscreen?.mode == "selected" && value.fullscreen?.startsFullscreen == true,"stable monitor mapping")
    try check(proposal.notices.contains(where:{$0.kind == .displayMapping && $0.line == 27}),"mapping acknowledgement")
    try check(proposal.notices.filter({$0.kind == .excluded}).map(\.line) == Array(2...8).map(UInt32.init),"excluded source categories")
    let encoded = String(data:try JSONEncoder().encode(value),encoding:.utf8)!
    try check(!encoded.contains("private-fixture") && !encoded.contains("security") && !encoded.contains("trustFiles"),"excluded data cannot enter native record")
  }
  let migration = try NativeDefaultsImport(data:data("DotWhenNoCursor=on\nAlwaysCursor=off\nCursorType=System\nFullScreenAllMonitors=on\nFullScreenMode=Current"),origin:.legacy)
  let migrated = try values(migration)
  try check(migrated.input?.cursorFallback == .dot && migrated.fullscreen?.mode == "all","shared post-file deprecated migrations")
  let implicitMonitor = try NativeDefaultsImport(data:data("FullScreenMode=Selected"),origin:.currentXDG,legacyDisplays:[.init("first")])
  try check(tryValues(implicitMonitor)?.fullscreen?.selectedDisplays == ["first"],"selected mode imports explicit mapped default")
  let empty = try NativeDefaultsImport(data:data("Password=private-fixture\\q"),origin:.legacy)
  try check(tryValues(empty) == NativePreferences() && empty.categories.isEmpty,"excluded-only import has no ordinary values")
  let resetMigration = try NativeDefaultsImport(data:data("DotWhenNoCursor=on\nDotWhenNoCursor=off"),origin:.legacy)
  try check(tryValues(resetMigration)?.input == nil,"false migration flag does not materialize defaults")
}
func tryValues(_ proposal: NativeDefaultsImport) -> NativePreferences? { try? values(proposal) }
func malformedAndBounds() throws {
  for body in ["Shared=private-fixture\nShared=on","SecurityTypes=private-fixture","X509CA=private-fixture\\q"] {
    do { _ = try NativeDefaultsImport(data:data(body),origin:.currentXDG); throw Failure(message:"Malformed known field accepted") }
    catch let error as NativeDocumentFailure {
      try check(error.line == 2 && !error.description.contains("private-fixture"),"original line and redaction")
    }
  }
  do { _ = try NativeDefaultsImport(data:data("Password=private\n\nFullScreenMode=Selected\nFullScreenSelectedMonitors=2"),origin:.legacy,legacyDisplays:[.init("one")]); throw Failure(message:"Unmapped monitor accepted") }
  catch let error as NativeDocumentResolutionFailure { try check(error.line == 5 && error.reason == .displayMappingRequired,"mapping source line survives projection") }
  let header = data(""), tail = Data("Shared=on".utf8)
  var largest = header; largest.append(Data(repeating:10,count:NativeConnectionDocument.maximumBytes-header.count-tail.count)); largest.append(tail)
  let result = try NativeDefaultsImport(data:largest,origin:.currentXDG)
  try check(tryValues(result)?.shared == true,"valid limit-size document without final newline")
  largest.append(10)
  do { _ = try NativeDefaultsImport(data:largest,origin:.currentXDG); throw Failure(message:"Oversized input accepted") }
  catch let error as NativeDocumentFailure { try check(error.problem == .tooLarge,"shared whole-file bound") }
}
final class Backing: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?, failure: NativePreferencesError?, writeFailure: NativePreferencesError?, after = false
  private var count = 0
  func read() throws -> Data? { try lock.withLock { if let failure { throw failure }; return data } }
  func write(_ value: Data) throws {
    try lock.withLock { if let failure { throw failure }; if let writeFailure { throw writeFailure }; data = value; count += 1; if after { throw NativePreferencesError.ioFailure } }
  }
  func replace(_ value: Data?) { lock.withLock { data = value } }
  func fail(_ value: NativePreferencesError?) { lock.withLock { failure = value } }
  func failWrite(_ value: NativePreferencesError?) { lock.withLock { writeFailure = value } }
  func failAfter(_ value: Bool) { lock.withLock { after = value } }
  var writes: Int { lock.withLock { count } }
}
func reject(_ expected: NativePreferencesError, _ action: @Sendable () async throws -> Void) async throws {
  do { try await action(); throw Failure(message:"Unsafe import accepted") }
  catch let error as NativePreferencesError { try check(error == expected,"typed store error") }
}
func stores() async throws {
  let proposal = try NativeDefaultsImport(data:data("Shared=on"),origin:.currentXDG)
  let backing = Backing(), store = NativePreferencesStore(backing:backing)
  let initial = try await store.read()
  try check(!initial.isStored && initial.importedFrom == nil && backing.writes == 0,"read does not migrate")
  let results = await withTaskGroup(of:Bool.self,returning:[Bool].self) { group in
    for _ in 0..<2 { group.addTask { (try? await store.importDefaults(proposal,acknowledging:[])) != nil } }
    var result: [Bool] = []; for await value in group { result.append(value) }; return result
  }
  try check(results.filter({$0}).count == 1 && backing.writes == 1,"one explicit import wins")
  let imported = try await store.read()
  try check(imported.importedFrom == .currentXDG && imported.values.shared == true,"marker and values committed together")
  let json = try JSONSerialization.jsonObject(with:backing.read()!) as! [String:Any]
  try check(json["schema"] as? Int == 11 && json["importedFrom"] as? String == "currentXDG","schema 11 origin marker")
  let reset = try await store.reset(expected:imported.revision)
  try check(reset.values == NativePreferences() && reset.importedFrom == .currentXDG,"reset retains migration marker")
  try await reject(.conflict) { _ = try await store.importDefaults(proposal,acknowledging:[]) }
  await store.close()
  try await reject(.closed) { _ = try await store.importDefaults(proposal,acknowledging:[]) }
  let legacyBacking = Backing(), legacyStore = NativePreferencesStore(backing:legacyBacking)
  let legacy = try NativeDefaultsImport(data:data("Shared=off\nPassword=private-fixture"),origin:.legacy)
  do { _ = try await legacyStore.importDefaults(legacy,acknowledging:[]); throw Failure(message:"Store bypassed review") }
  catch let error as NativeDefaultsImportError { try check(error == .reviewRequired && legacyBacking.writes == 0,"review failure cannot mark migration") }
  let cancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    try await reject(.cancelled) { _ = try await legacyStore.importDefaults(legacy,acknowledging:[3]) }
  }
  try await cancelled.value; try check(legacyBacking.writes == 0,"cancellation cannot mark migration")
  legacyBacking.fail(.denied)
  try await reject(.denied) { _ = try await legacyStore.importDefaults(legacy,acknowledging:[3]) }
  legacyBacking.fail(nil); legacyBacking.failWrite(.ioFailure)
  try await reject(.ioFailure) { _ = try await legacyStore.importDefaults(legacy,acknowledging:[3]) }
  let absentAfterFailure = try await legacyStore.read()
  try check(!absentAfterFailure.isStored && absentAfterFailure.importedFrom == nil && legacyBacking.writes == 0,"failed write cannot mark migration")
  legacyBacking.failWrite(nil); legacyBacking.failAfter(true)
  try await reject(.ioFailure) { _ = try await legacyStore.importDefaults(legacy,acknowledging:[3]) }
  let recovered = try await legacyStore.read()
  try check(recovered.importedFrom == .legacy && recovered.values.shared == false,"uncertain accepted write reconciles marker and values")
  try await reject(.conflict) { _ = try await legacyStore.importDefaults(legacy,acknowledging:[3]) }
  await legacyStore.close()
  for (raw,expected) in [("broken",NativePreferencesError.corrupt),("{\"schema\":12}",.futureSchema)] {
    let blocked = Backing(); blocked.replace(Data(raw.utf8)); let store = NativePreferencesStore(backing:blocked)
    try await reject(expected) { _ = try await store.importDefaults(proposal,acknowledging:[]) }
    try check(blocked.writes == 0,"invalid native state is never absence"); await store.close()
  }
  let native = Backing(), nativeStore = NativePreferencesStore(backing:native)
  _ = try await nativeStore.commit(.init(),expected:.init(value:nil))
  try await reject(.conflict) { _ = try await nativeStore.importDefaults(proposal,acknowledging:[]) }
  let unchanged = try await nativeStore.read()
  try check(unchanged.importedFrom == nil && native.writes == 1,"existing empty native values win")
  await nativeStore.close()
}
func markerValidation() async throws {
  let proposal = try NativeDefaultsImport(data:data("Shared=on"),origin:.currentXDG)
  for (schema,marker,failure) in [(10,"\"legacy\"",NativePreferencesError.unsupportedFields),(11,"null",.corrupt),(11,"\"future\"",.unsupportedValue),(11,"true",.corrupt)] {
    let backing = Backing()
    let bytes = Data("{\"schema\":\(schema),\"revision\":\"00000000-0000-0000-0000-000000000001\",\"values\":{},\"importedFrom\":\(marker)}".utf8)
    backing.replace(bytes); let store = NativePreferencesStore(backing:backing)
    try await reject(failure) { _ = try await store.importDefaults(proposal,acknowledging:[]) }
    let after = try backing.read(); try check(after == bytes && backing.writes == 0,"invalid marker preserved")
    await store.close()
  }
}
@main struct NativeDefaultsImportTests {
  static func main() async throws {
    try projection(); try malformedAndBounds(); try await stores(); try await markerValidation()
    print("PASS defaults-only import projection, loss review, absence-only commit and atomic migration marker")
  }
}
