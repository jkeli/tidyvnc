// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
final class Memory: NativePreferencesBacking, @unchecked Sendable {
  func read() -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"launch must not write stores") }
}
actor Reader: NativeDocumentReading {
  var data = Data(), calls = 0, paused = false
  var continuation: CheckedContinuation<Void,Never>?
  func configure(_ body: String, paused: Bool = false) {
    data = Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8); self.paused = paused
  }
  func pending() -> Bool { continuation != nil }
  func resume() { continuation?.resume(); continuation = nil }
  func read(_ url: URL) async -> Data {
    calls += 1; let copy = data
    if paused { await withCheckedContinuation { continuation = $0 } }
    return copy
  }
}
@MainActor final class Fixture {
  let runtime: NativeRuntime, store = NativePreferencesStore(backing:Memory()), reader = Reader()
  var ordered: [NativeDisplayID] = [.init("one")]
  var available: [NativeDisplayID] = [.init("one"),.init("two")]
  init() throws { runtime = try NativeRuntime() }
  func make(_ arguments: [String], _ body: String, mapping: [Int:NativeDisplayID]? = nil,
            paused: Bool = false) async throws -> NativeSessionDefaults {
    await reader.configure(body,paused:paused)
    let invocation = NativeInvocationRequest(options:try .init(arguments:arguments),endpoint:"cli.invalid",
      workingDirectory:"/launch",monitorMapping:mapping)
    let loader = NativeSessionDefaults(runtime:runtime,store:store,invocation:invocation,
      document:.init(url:URL(fileURLWithPath:"/fixture.tidyvnc"),workingDirectory:"/launch"),documentReader:reader,
      documentDisplays:{ [self] in ordered },documentAvailableDisplays:{ [self] in available })
    loader.load()
    if !paused { try await until { !loader.isLoading } }
    return loader
  }
  func close() async throws { try await runtime.shutdown(); await store.close() }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"fixture timed out")
}
@MainActor func review(_ loader: NativeSessionDefaults) throws -> NativeDocumentReview {
  guard let review = loader.documentReview else { throw Failure(message:"missing review: \(loader.documentIssue ?? loader.invocationIssue ?? "none")") }
  try check(loader.session == nil && !loader.isReady && loader.invocationResolution == nil,"pending CLI candidate is never a public resolved session")
  return review
}
@MainActor func precedence(_ fixture: Fixture) async throws {
  let cli = ["-FullScreenMode=Selected","-FullScreenSelectedMonitors=99","-Shared=on"]
  let loader = try await fixture.make(cli,"FullScreenSelectedMonitors=1\nShared=off",mapping:[99:.init("disconnected")])
  let item = try review(loader), config = try item.resolution.configuration()
  try check(item.resolution.monitorNumbers == [1] && item.resolution.monitorSource == .document,"file replaces obsolete CLI number")
  try check(item.resolution.resolvedMonitorMapping == [1:.init("one")] && item.monitorMapping == nil,"obsolete CLI mapping keys and disconnected IDs discarded")
  try check(config.fullscreenPolicy.mode == .selected && config.fullscreenSources[.mode] == .commandLine,"CLI mode survives with original provenance")
  try check(config.fullscreenSources[.selectedDisplays] == .document && !config.shared,"file selection and connection value win")
  loader.acceptDocument(item.id)
  try check(loader.session?.initialFullscreenPolicy.selectedDisplays == [.init("one")] && loader.session?.snapshot.state == .idle,"only final mapped policy reaches idle session")
  await loader.close()

  fixture.ordered = []; fixture.available = []
  let implicit = try await fixture.make(["-FullScreenMode=Selected"],"FullScreenMode=Current")
  let overridden = try review(implicit)
  try check(overridden.resolution.monitorNumbers.isEmpty && overridden.resolution.configuration().fullscreenPolicy.mode == .current,"file replaces implicit CLI monitor requirement without displays")
  await implicit.close()
  fixture.ordered = [.init("one")]; fixture.available = [.init("one"),.init("two")]

  let migration = try await fixture.make(["-FullScreenMode=Selected","-FullScreenAllMonitors=on"],"FullScreenAllMonitors=off")
  let migrated = try review(migration)
  try check(migrated.resolution.configuration().fullscreenPolicy.mode == .all && migrated.resolution.monitorNumbers.isEmpty,"CLI migration runs before file disabling alias; prior all mode persists")
  try check(migrated.resolution.configuration().fullscreenSources[.mode] == .commandLine,"prior migrated mode source preserved")
  await migration.close()
  let modern = try await fixture.make(["-FullScreenAllMonitors=on"],"FullScreenAllMonitors=off\nFullScreenMode=Selected")
  let selected = try review(modern)
  try check(selected.resolution.monitorNumbers == [1] && selected.resolution.monitorSource == .document,"file selects implicit monitor after disabling inherited all flag")
  await modern.close()
}
@MainActor func recovery(_ fixture: Fixture) async throws {
  let loader = try await fixture.make(["-FullScreenMode=Selected","-FullScreenSelectedMonitors=2147483647","-CursorType=System"],"Shared=on")
  guard let initial = loader.documentMapping else { throw Failure(message:"missing inherited CLI mapping") }
  try check(initial.numbers == [2147483647] && initial.monitorSource == .commandLine && initial.suggested.isEmpty,"sparse inherited CLI numbers exposed without array allocation")
  let reads = await fixture.reader.calls
  loader.resolveDocumentMapping(UUID(),assignments:[2147483647:.init("one")])
  try check(loader.documentReview == nil,"stale mapping identity ignored")
  loader.resolveDocumentMapping(initial.id,assignments:[2147483647:.init("disconnected")])
  try check(loader.documentReview == nil && loader.documentIssue != nil,"disconnected assignment rejected")
  loader.resolveDocumentMapping(initial.id,assignments:[2147483647:.init("two")])
  let mapped = try review(loader)
  try check(mapped.resolution.monitorSource == .commandLine && mapped.resolution.cursorType == .system,"CLI provenance and inactive cursor survive recovery")
  try check(mapped.resolution.configuration().fullscreenSources[.selectedDisplays] == .commandLine,"mapping does not falsely relabel CLI selection as file")
  loader.editDocumentMapping(mapped.id)
  guard let editing = loader.documentMapping else { throw Failure(message:"missing edited mapping") }
  try check(editing.suggested == [2147483647:.init("two")],"editing retains accepted manual choice")
  loader.resolveDocumentMapping(editing.id,assignments:[2147483647:.init("one")])
  let latest = try review(loader)
  loader.acceptDocument(mapped.id)
  try check(loader.session == nil && loader.documentReview?.id == latest.id,"stale review cannot accept newer choice")
  fixture.ordered = [.init("two"),.init("one")]
  loader.acceptDocument(latest.id)
  try check(loader.session?.initialFullscreenPolicy.selectedDisplays == [.init("one")],"stable manual choice survives same-ID reordering")
  let finalReads = await fixture.reader.calls
  try check(reads == finalReads,"review and edits do not reread source")
  await loader.close(); fixture.ordered = [.init("one")]

  let inherited = try await fixture.make(["-FullScreenMode=Selected","-FullScreenSelectedMonitors=99"],"Shared=on",mapping:[99:.init("two")])
  let ready = try review(inherited)
  try check(ready.monitorMapping == [99:.init("two")] && ready.resolution.resolvedMonitorMapping == ready.monitorMapping,"surviving host mapping is visible as explicit choice")
  fixture.available = [.init("one")]
  inherited.acceptDocument(ready.id)
  guard let changed = inherited.documentMapping else { throw Failure(message:"missing topology recovery") }
  try check(changed.suggested.isEmpty && inherited.session == nil,"removed explicit CLI display requires a new assignment")
  inherited.resolveDocumentMapping(changed.id,assignments:[99:.init("one")])
  inherited.acceptDocument(inherited.documentReview!.id)
  try check(inherited.session?.initialFullscreenPolicy.selectedDisplays == [.init("one")],"disconnected host choice can be recovered")
  await inherited.close(); fixture.available = [.init("one"),.init("two")]
}
@MainActor func lateAndInvalid(_ fixture: Fixture) async throws {
  let args = ["-FullScreenMode=Selected","-FullScreenSelectedMonitors=1"]
  let loader = try await fixture.make(args,"Shared=on",paused:true)
  for _ in 0..<1000 { if await fixture.reader.pending() { break }; try await Task.sleep(for:.milliseconds(2)) }
  let pending = await fixture.reader.pending(); try check(pending,"file read suspended")
  fixture.ordered = [.init("two")]
  await fixture.reader.resume(); try await until { !loader.isLoading }
  let fresh = try review(loader)
  try check(fresh.resolution.resolvedMonitorMapping == [1:.init("two")],"CLI numbers use fresh post-IO topology")
  await loader.close(); fixture.ordered = [.init("one")]

  let invalidFile = try await fixture.make(args,"FullScreenSelectedMonitors=invalid\nFullScreenSelectedMonitors=1")
  try check(invalidFile.documentIssue != nil && invalidFile.documentReview == nil && invalidFile.session == nil,"earlier malformed file number cannot be masked")
  await invalidFile.close()
  let before = await fixture.reader.calls
  let invalidHost = try await fixture.make(["-DesktopSize=0x600","-FullScreenSelectedMonitors=99"],"FullScreenSelectedMonitors=1")
  let after = await fixture.reader.calls
  try check(invalidHost.invocationIssue != nil && before == after && invalidHost.session == nil,"non-display CLI failure still prevents source IO")
  await invalidHost.close()
  let closed = try await fixture.make(args,"Shared=on",paused:true)
  for _ in 0..<1000 { if await fixture.reader.pending() { break }; try await Task.sleep(for:.milliseconds(2)) }
  let held = await fixture.reader.pending(); try check(held,"late-close read suspended")
  closed.stop(); await fixture.reader.resume(); await closed.close()
  try check(closed.documentReview == nil && closed.documentMapping == nil && closed.session == nil,"close discards pending combined resolution")
}
@main struct NativeInvocationMonitorTests {
  @MainActor static func main() async throws {
    let fixture = try Fixture()
    try await precedence(fixture); try await recovery(fixture); try await lateAndInvalid(fixture)
    try await fixture.close()
    print("PASS CLI/file monitor precedence, deferred mapping, provenance, topology recovery and cancellation")
  }
}
