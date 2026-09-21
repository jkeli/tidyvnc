// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
func data(_ body: String) -> Data { Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8) }
final class Backing: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?, denied = false, count = 0
  func read() throws -> Data? { try lock.withLock { if denied { throw NativePreferencesError.denied }; return bytes } }
  func write(_ data: Data) { lock.withLock { bytes = data; count += 1 } }
  func replace(_ data: Data?) { lock.withLock { bytes = data } }
  func deny(_ flag: Bool) { lock.withLock { denied = flag } }
  var writes: Int { lock.withLock { count } }
}
struct Fixture {
  let root: URL, paths: NativeImportPaths
  let backing = Backing()
  let store: NativePreferencesStore
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-import-flow-"+UUID().uuidString)
    paths = try NativeImportPaths(homeDirectory:root.path,environment:[:])
    store = NativePreferencesStore(backing:backing)
  }
  func write(_ url: URL, _ bytes: Data) throws {
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    try bytes.write(to:url)
  }
  func remove(_ url: URL) throws { try FileManager.default.removeItem(at:url) }
  func cleanup() { try? FileManager.default.removeItem(at:root) }
  var service: NativeDefaultsImportService { NativeDefaultsImportService(paths:paths,store:store) }
}
func sourceError(_ expected: NativeImportSourceError, _ action: () async throws -> Void) async throws {
  do { try await action(); throw Failure(message:"Source admitted unexpectedly") }
  catch let error as NativeImportSourceError { try check(error == expected,"source error \(error)") }
}
func pathPolicy() throws {
  let fallback = try NativeImportPaths(homeDirectory:"/fixture-home",environment:["XDG_CONFIG_HOME":"relative","XDG_STATE_HOME":"~/.state"])
  try check(fallback.currentDefaults.path == "/fixture-home/.config/tidyvnc/default.tidyvnc","relative config ignored")
  try check(fallback.currentHistory.path == "/fixture-home/.local/state/tidyvnc/tidyvnc.history","tilde state ignored")
  try check(fallback.legacyDefaults.map(\.path) == ["/fixture-home/.config/tigervnc/default.tigervnc","/fixture-home/.vnc/default.tigervnc"],"legacy defaults precedence")
  try check(fallback.legacyHistory.map(\.path) == ["/fixture-home/.local/state/tigervnc/tigervnc.history","/fixture-home/.vnc/tigervnc.history"],"separate history paths")
  let absolute = try NativeImportPaths(homeDirectory:"/fixture-home/",environment:["XDG_CONFIG_HOME":"/fixture-config/","XDG_STATE_HOME":"/fixture-state"])
  try check(absolute.currentDefaults.path == "/fixture-config/tidyvnc/default.tidyvnc" && absolute.currentHistory.path == "/fixture-state/tidyvnc/tidyvnc.history","independent absolute overrides")
  let dot = try NativeImportPaths(homeDirectory:"/fixture-home",environment:["XDG_CONFIG_HOME":"/fixture-link/../config"])
  try check(dot.currentDefaults.path == "/fixture-link/../config/tidyvnc/default.tidyvnc","no lexical symlink-parent normalization")
  for home in ["relative","", "/invalid\0home", "/"+String(repeating:"a",count:4096)] {
    do { _ = try NativeImportPaths(homeDirectory:home,environment:[:]); throw Failure(message:"invalid home accepted") }
    catch let error as NativeImportSourceError { try check(error == .invalidPath,"invalid home rejected") }
  }
  for override in ["/invalid\0config", "/"+String(repeating:"a",count:4080)] {
    do { _ = try NativeImportPaths(homeDirectory:"/fixture-home",environment:["XDG_CONFIG_HOME":override]); throw Failure(message:"invalid override accepted") }
    catch let error as NativeImportSourceError { try check(error == .invalidPath,"invalid absolute override never falls back") }
  }
}
func discovery() async throws {
  let f = try Fixture(); defer { f.cleanup() }
  let service = f.service
  let missing = try await service.prepare(origin:.currentXDG,legacyDisplays:[])
  try check(missing == nil && !FileManager.default.fileExists(atPath:f.root.path),"discovery creates nothing")
  try f.write(f.paths.legacyDefaults[1],data("Shared=off"))
  let fallback = try await service.prepare(origin:.legacy,legacyDisplays:[])!
  try check(fallback.source == f.paths.legacyDefaults[1],"missing XDG chooses dot-vnc")
  let noCurrent = try await service.prepare(origin:.currentXDG,legacyDisplays:[])
  try check(noCurrent == nil,"current never automatically reads legacy")
  try f.write(f.paths.legacyDefaults[0],data("Shared=on"))
  let preferred = try await service.prepare(origin:.legacy,legacyDisplays:[])!
  try check(preferred.source == f.paths.legacyDefaults[0],"legacy XDG wins")
  try check(chmod(f.paths.legacyDefaults[0].path,0o400) == 0,"read-only fixture")
  _ = try await service.prepare(origin:.legacy,legacyDisplays:[])
  var mode = stat(); try check(stat(f.paths.legacyDefaults[0].path,&mode) == 0 && mode.st_mode & 0o777 == 0o400,"read-only source remains read-only")
  try check(chmod(f.paths.legacyDefaults[0].path,0) == 0,"unreadable fixture")
  do { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]); throw Failure(message:"unreadable source fell back") }
  catch let error as NativeDocumentOpenError { try check(error == .unreadable,"unreadable source fails") }
  try check(chmod(f.paths.legacyDefaults[0].path,0o600) == 0,"restore own fixture access")
  try f.write(f.paths.legacyDefaults[0],Data("broken-private-source".utf8))
  do { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]); throw Failure(message:"corrupt source fell back") }
  catch is NativeDocumentFailure {}
  try f.remove(f.paths.legacyDefaults[0])
  try FileManager.default.createSymbolicLink(atPath:f.paths.legacyDefaults[0].path,withDestinationPath:f.root.appendingPathComponent("missing").path)
  do { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]); throw Failure(message:"dangling source fell back") }
  catch let error as NativeDocumentOpenError { try check(error == .unreadable,"dangling source fails") }
  try f.remove(f.paths.legacyDefaults[0])
  try FileManager.default.createDirectory(at:f.paths.legacyDefaults[0],withIntermediateDirectories:false)
  do { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]); throw Failure(message:"directory fell back") }
  catch let error as NativeDocumentOpenError { try check(error == .notRegular,"directory source fails") }
  try f.remove(f.paths.legacyDefaults[0])
  try check(mkfifo(f.paths.legacyDefaults[0].path,0o600) == 0,"fixture FIFO")
  do { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]); throw Failure(message:"FIFO fell back") }
  catch let error as NativeDocumentOpenError { try check(error == .notRegular,"FIFO rejected without blocking") }
  try f.remove(f.paths.legacyDefaults[0])
  try f.write(f.paths.legacyDefaults[0],Data(repeating:10,count:1024*1024+1))
  do { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]); throw Failure(message:"oversized source fell back") }
  catch let error as NativeDocumentOpenError { try check(error == .tooLarge,"bounded source read") }
  try f.write(f.paths.currentDefaults,Data("malformed-current".utf8))
  try await sourceError(.currentSourceExists) { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]) }
  try f.remove(f.paths.currentDefaults)
  try FileManager.default.createSymbolicLink(atPath:f.paths.currentDefaults.path,withDestinationPath:"missing")
  try await sourceError(.currentSourceExists) { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]) }
  try f.remove(f.paths.currentDefaults)
  // A dangling ancestor must not disappear into ENOENT fallback either.
  try f.remove(f.paths.currentDefaults.deletingLastPathComponent())
  try FileManager.default.createSymbolicLink(atPath:f.paths.currentDefaults.deletingLastPathComponent().path,withDestinationPath:"missing")
  try await sourceError(.inaccessible) { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]) }
  try f.remove(f.paths.currentDefaults.deletingLastPathComponent())
  try f.write(f.paths.currentDefaults.deletingLastPathComponent(),data("Shared=off"))
  try await sourceError(.inaccessible) { _ = try await service.prepare(origin:.currentXDG,legacyDisplays:[]) }
  try f.remove(f.paths.currentDefaults.deletingLastPathComponent())
  try f.write(f.paths.currentDefaults,data("Shared=on"))
  let target = f.root.appendingPathComponent("symlink-target.tidyvnc")
  try f.write(target,data("Shared=off")); try f.remove(f.paths.currentDefaults)
  try FileManager.default.createSymbolicLink(atPath:f.paths.currentDefaults.path,withDestinationPath:target.path)
  let linked = try await service.prepare(origin:.currentXDG,legacyDisplays:[])!
  try check(try linked.proposal.preferences().shared == false,"regular-file symlink can be reviewed")
  try check(f.backing.writes == 0,"source inspection never writes native state")
  await f.store.close()
}
func admissionAndSnapshot() async throws {
  let f = try Fixture(); defer { f.cleanup() }
  try f.write(f.paths.currentDefaults,data("Shared=on\nPassword=private-fixture"))
  let original = try Data(contentsOf:f.paths.currentDefaults), service = f.service
  f.backing.replace(Data("malformed-native".utf8))
  do { _ = try await service.prepare(origin:.currentXDG,legacyDisplays:[]); throw Failure(message:"corrupt native bypassed") }
  catch let error as NativePreferencesError { try check(error == .corrupt,"native errors precede discovery") }
  f.backing.replace(nil); f.backing.deny(true)
  do { _ = try await service.prepare(origin:.legacy,legacyDisplays:[]); throw Failure(message:"denied native bypassed") }
  catch let error as NativePreferencesError { try check(error == .denied,"native denial precedes existing current source") }
  f.backing.deny(false)
  let review = try await service.prepare(origin:.currentXDG,legacyDisplays:[])!
  try f.write(f.paths.currentDefaults,data("Shared=off"))
  do { _ = try await service.commit(review,acknowledging:[],currentDisplays:[]); throw Failure(message:"missing acknowledgement accepted") }
  catch let error as NativeDefaultsImportError { try check(error == .reviewRequired,"service preserves review gate") }
  let imported = try await service.commit(review,acknowledging:[3],currentDisplays:[])
  try check(imported.values.shared == true && imported.importedFrom == .currentXDG,"commit imports reviewed bytes despite source edit")
  try check(try Data(contentsOf:f.paths.currentDefaults) != original,"test changed source")
  try check(try Data(contentsOf:f.paths.currentDefaults) == data("Shared=off"),"import leaves source unchanged")
  try await sourceError(.nativeStateExists) { _ = try await service.prepare(origin:.currentXDG,legacyDisplays:[]) }
  await f.store.close()

  let race = try Fixture(); defer { race.cleanup() }
  try race.write(race.paths.currentDefaults,data("FullScreenMode=Selected\nFullScreenSelectedMonitors=2"))
  let displayIDs: [NativeDisplayID] = [.init("left"),.init("right")], raceService = race.service
  let mapped = try await raceService.prepare(origin:.currentXDG,legacyDisplays:displayIDs)!
  try await sourceError(.invalidDisplayMapping) {
    _ = try await raceService.prepare(origin:.currentXDG,legacyDisplays:[displayIDs[0],displayIDs[0]])
  }
  try await sourceError(.topologyChanged) { _ = try await raceService.commit(mapped,acknowledging:[3],currentDisplays:Array(displayIDs.reversed())) }
  try check(race.backing.writes == 0,"stale mapping cannot mark migration")
  _ = try await race.store.commit(.init(shared:false),expected:.init(value:nil))
  do { _ = try await raceService.commit(mapped,acknowledging:[3],currentDisplays:displayIDs); throw Failure(message:"new native values overwritten") }
  catch let error as NativePreferencesError { try check(error == .conflict,"fresh native state wins at commit") }
  await race.store.close()
}

actor GateReader: NativeDocumentReading {
  private var continuation: CheckedContinuation<Data,Never>?
  var entered: Bool { continuation != nil }
  func read(_ url: URL) async throws -> Data { await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(returning:data("Shared=on\nPassword=private-fixture")); continuation = nil }
}
actor CommitGate: NativeDefaultsImportServing {
  let service: NativeDefaultsImportService
  let afterAcceptance: Bool
  var entered = false
  private var continuation: CheckedContinuation<Void,Never>?
  init(_ service: NativeDefaultsImportService, afterAcceptance: Bool) { self.service = service; self.afterAcceptance = afterAcceptance }
  func prepare(origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID]) async throws -> NativeDefaultsImportReview? {
    try await service.prepare(origin:origin,legacyDisplays:legacyDisplays)
  }
  func commit(_ review: NativeDefaultsImportReview, acknowledging lines: Set<UInt32>, currentDisplays: [NativeDisplayID]) async throws -> NativePreferencesSnapshot {
    let result = afterAcceptance ? try await service.commit(review,acknowledging:lines,currentDisplays:currentDisplays) : nil
    entered = true
    await withCheckedContinuation { continuation = $0 }
    if let result { return result }
    return try await service.commit(review,acknowledging:lines,currentDisplays:currentDisplays)
  }
  func release() { continuation?.resume(); continuation = nil }
}
@MainActor func waitFor(_ condition: () async -> Bool) async throws {
  for _ in 0..<2000 { if await condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"asynchronous operation timed out")
}
@MainActor func lifecycle() async throws {
  let f = try Fixture(); defer { f.cleanup() }
  try f.write(f.paths.currentDefaults,data("Shared=on\nPassword=private-fixture"))
  let reader = GateReader(), service = NativeDefaultsImportService(paths:f.paths,store:f.store,reader:reader)
  let state = NativeDefaultsImportState(service:service)
  let cancelled = state.begin(origin:.currentXDG,legacyDisplays:[])!
  try await waitFor { await reader.entered }
  state.cancel(UUID()); try check(state.hasPending && state.isLoading,"foreign cancel ignored")
  state.cancel(cancelled); try check(state.begin(origin:.legacy,legacyDisplays:[]) == nil,"cancelled read must drain before restart")
  await reader.release(); try await waitFor { !state.hasPending }
  try check(state.review == nil && state.issue == nil && f.backing.writes == 0,"late cancelled source cannot publish or write")
  let fresh = state.begin(origin:.currentXDG,legacyDisplays:[])!
  try await waitFor { await reader.entered }; await reader.release()
  try await waitFor { state.review != nil }
  let first = state.review!
  state.approve(cancelled,acknowledging:[3],currentDisplays:[])
  state.approve(fresh,acknowledging:[3],currentDisplays:[])
  try check(state.review?.id == first.id && !state.isWriting,"request identities cannot approve preview")
  state.cancel(first.id)
  _ = state.begin(origin:.currentXDG,legacyDisplays:[])
  try await waitFor { await reader.entered }; await reader.release()
  try await waitFor { state.review != nil }
  let second = state.review!
  state.approve(first.id,acknowledging:[3],currentDisplays:[])
  try check(state.review?.id == second.id && !state.isWriting,"stale preview cannot approve replacement")
  state.approve(second.id,acknowledging:[],currentDisplays:[])
  try check(state.review?.id == second.id && state.issue != nil && f.backing.writes == 0,"incomplete review remains editable")
  state.approve(second.id,acknowledging:[3],currentDisplays:[])
  try await waitFor { !state.hasPending }
  try check(state.imported?.values.shared == true && f.backing.writes == 1 && state.issue == nil,"approved preview commits once")
  await state.close(); try check(state.begin(origin:.legacy,legacyDisplays:[]) == nil,"closed state rejects new requests")
  await f.store.close()

  for accepted in [false,true] {
    let f = try Fixture(); defer { f.cleanup() }
    try f.write(f.paths.currentDefaults,data("Shared=on"))
    let gate = CommitGate(f.service,afterAcceptance:accepted), state = NativeDefaultsImportState(service:gate)
    _ = state.begin(origin:.currentXDG,legacyDisplays:[])
    try await waitFor { state.review != nil }
    state.approve(state.review!.id,acknowledging:[],currentDisplays:[])
    try await waitFor { await gate.entered }
    state.cancel(state.requestID!); try check(state.isWriting && state.hasPending,"review cancellation cannot claim to roll back a commit")
    state.stop(); await gate.release(); await state.close()
    try check(!state.hasPending && state.imported == nil && state.issue == nil,"shutdown joins and suppresses late commit UI")
    try check(f.backing.writes == (accepted ? 1 : 0),"shutdown cancellation respects acceptance boundary")
    await f.store.close()
  }
  let absent = try Fixture(); defer { absent.cleanup() }
  let empty = NativeDefaultsImportState(service:absent.service)
  _ = empty.begin(origin:.currentXDG,legacyDisplays:[]); try await waitFor { !empty.hasPending }
  try check(empty.foundNoSource && empty.issue == nil,"absence differs from failure")
  absent.backing.replace(Data("private-malformed-native".utf8))
  _ = empty.begin(origin:.currentXDG,legacyDisplays:[]); try await waitFor { !empty.hasPending }
  try check(!empty.foundNoSource && empty.issue != nil && !empty.issue!.contains("private-"),"corruption surfaced without source values")
  await empty.close(); await absent.store.close()
}
@main struct NativeImportFlowTests {
  static func main() async throws {
    try pathPolicy(); try await discovery(); try await admissionAndSnapshot(); try await lifecycle()
    print("PASS bounded import discovery, precedence, reviewed snapshots, topology and cancellation lifecycle")
  }
}
