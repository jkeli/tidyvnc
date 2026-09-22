// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import Combine
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
func document(_ body: String) throws -> NativeConnectionDocument {
  try .init(data:Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8))
}
func resolve(_ args: [String], base: NativeSessionConfiguration = .init(), displays: [NativeDisplayID] = []) throws -> NativeInvocationResolution {
  try .init(options:NativeInvocationOptions(arguments:args),endpoint:"fixture.invalid",base:base,legacyDisplays:displays,workingDirectory:"/launch")
}
func values() throws {
  let raw = try NativeInvocationSyntax(arguments:["-Shared=YES"])
  let canonical = try NativeInvocationOptions(arguments:["-Shared=YES","-QualityLevel=0x3"])
  try check(raw.assignments[0].value == "YES" && canonical.assignments.map(\.value) == ["on","3"],"raw syntax and canonical copy")
  do { _ = try NativeInvocationOptions(arguments:["-Shared=private","-Shared=on","--help"]); throw Failure(message:"invalid earlier value accepted") }
  catch let failure as NativeInvocationFailure { try check(failure.problem == .invalidValue && failure.argument == 1 && !failure.description.contains("private"),"typed redacted value failure before help") }
  for args in [["-DesktopSize=0x600","-DesktopSize=800x600"],["-DesktopSize=65536x1"],["-DesktopSize=800 x600"]] {
    do { _ = try resolve(args); throw Failure(message:"invalid host value accepted") }
    catch let failure as NativeInvocationResolutionFailure { try check(failure.reason == .invalidValue && failure.argument == 1,"every host value checked") }
  }
  for option in ["-via=private invalid"] {
    do { _ = try resolve([option]); throw Failure(message:"missing native adapter silently accepted") }
    catch let failure as NativeInvocationResolutionFailure { try check(failure.reason == .invalidValue && failure.argument == 1,"invalid gateway explicit") }
  }
  _ = try resolve(["-Log=*:stderr:30"])
  _ = try resolve(["-Log=*:file:30"])
  for option in ["-Log=private:stderr:30","-Log=*:syslog:30"] {
    do { _ = try resolve([option]); throw Failure(message:"invalid logging route accepted") }
    catch let failure as NativeInvocationResolutionFailure {
      try check(failure.reason == (option.contains(":syslog:") ? .unsupportedOption : .invalidValue) && failure.argument == 1,"logging route admission")
    }
  }
  let window = try resolve(["-geometry=800x600+-10+20","-Maximize"])
  try check(window.configuration.windowStartupPolicy.geometry?.width == 800 &&
            window.configuration.windowStartupPolicy.geometry?.x == -10 && window.configuration.windowStartupPolicy.maximize,
            "implemented window adapters resolve their actual values")
  let result = try resolve(["-Shared=on","-ViewOnly","-RemoteResize=off","-DesktopSize= +0800x+600trailing","-QualityLevel=3"])
  try check(result.configuration.shared && result.configuration.sharedSource == .commandLine,"CLI sharing provenance")
  try check(result.configuration.input.viewOnly && result.configuration.inputSources[.viewOnly] == .commandLine,"CLI input provenance")
  try check(result.configuration.resizePolicy.initialSize == "800x600" && !result.configuration.resizePolicy.enabled,"retained size spelling and native resize")
  try check(result.configuration.resizeSources[.initialSize] == .commandLine,"resize source")
  let choices = try NativeInvocationSyntax.options()
  if choices.contains(where:{ $0.name == "X509CA" && $0.available }) {
    let path = String(repeating:"x",count:300)+"/../ca.pem"
    let value = try resolve(["-X509CA="+path])
    try check(value.configuration.caFile == "/launch/"+path,"CLI paths exceed file line bounds, retain cwd and dot components")
  }
}
func layers() throws {
  let hidden = try resolve(["-AlwaysCursor=off","-CursorType=System"])
  let file = try NativeDocumentResolution(document:document("Shared=on"),base:hidden.configuration,compatibility:hidden.compatibility)
  let fileConfig = try file.configuration()
  try check(file.cursorType == .system && fileConfig.input.cursorFallback == .hidden,"inactive cursor survives absent file fields")
  let cli = try resolve(["-DotWhenNoCursor=on","-FullScreenAllMonitors=on","-Shared=on","-QualityLevel=9"])
  let inherited = try NativeDocumentResolution(document:document("AlwaysCursor=off\nCursorType=System\nFullScreenMode=Selected\nShared=off\nQualityLevel=2"),base:cli.configuration,compatibility:cli.compatibility)
  let effective = try inherited.configuration()
  try check(effective.input.cursorFallback == .dot && effective.fullscreenPolicy.mode == .all && inherited.monitorNumbers.isEmpty,"retained deprecated migration after file overlay")
  try check(effective.inputSources[.cursorFallback] == .commandLine && effective.fullscreenSources[.mode] == .commandLine,"inherited migration provenance")
  try check(inherited.fieldLines["CursorType"] == 3 && inherited.fieldLines["FullScreenMode"] == 4,"argv indices never become document lines")
  try check(!effective.shared && effective.sharedSource == .document && inherited.endpoint.isEmpty,"file wins and absent host clears")
  let quality = try effective.encoding!.value(for:.quality)
  try check(quality.value == "2" && quality.source == .document,"file encoding wins")
  let disabled = try NativeDocumentResolution(document:document("DotWhenNoCursor=off\nFullScreenAllMonitors=off\nAlwaysCursor=off\nCursorType=System\nFullScreenMode=Current"),base:cli.configuration,compatibility:cli.compatibility)
  let off = try disabled.configuration()
  try check(off.input.cursorFallback == .hidden && disabled.cursorType == .system && off.fullscreenPolicy.mode == .current,"file explicitly disables inherited deprecated flags")
  try check(off.inputSources[.cursorFallback] == .document && off.fullscreenSources[.mode] == .document,"file override provenance")
  let numbers = try NativeDocumentMonitorMapping.numbers(document:document("FullScreenMode=Selected"),base:cli.configuration,compatibility:cli.compatibility)
  try check(numbers.isEmpty,"mapping helper respects inherited all-monitors migration")
  let mapped = try resolve(["-FullScreenMode=Selected","-FullScreenSelectedMonitors=2,1,2"],displays:[.init("one"),.init("two")])
  try check(mapped.configuration.fullscreenPolicy.selectedDisplays == [.init("one"),.init("two")],"number mapping canonical stable IDs")
}
final class Memory: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock(); private var data: Data?, count = 0
  var writes: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { data } }
  func write(_ data: Data) throws { lock.withLock { self.data = data; count += 1 } }
}
actor Reader: NativeDocumentReading {
  var calls = 0
  var paused = false
  var continuation: CheckedContinuation<Void,Never>?
  func pause() { paused = true }
  func pending() -> Bool { continuation != nil }
  func resume() { continuation?.resume(); continuation = nil }
  func read(_ url: URL) async throws -> Data {
    calls += 1
    if paused { await withCheckedContinuation { continuation = $0 } }
    return Data("TidyVNC Configuration file Version 1.0\nShared=off\nFullScreenSelectedMonitors=99\n".utf8)
  }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"loading timeout")
}
@MainActor func admission() async throws {
  let runtime = try NativeRuntime(), memory = Memory(), store = NativePreferencesStore(backing:memory)
  let history = HistoryBacking(), profiles = NativeProfileHistoryStore(backing:history)
  let original = try await store.read()
  _ = try await store.commit(.init(clipboardSend:false,shared:true),expected:original.revision)
  let profile = NativeConnectionProfile(name:"Fixture",endpoint:"profile.invalid",settings:.init(shared:false,reconnectOnError:false))
  _ = try await profiles.upsert(profile,expected:nil)
  let writes = memory.writes, historyWrites = history.writes
  let request = NativeInvocationRequest(options:try .init(arguments:["-Shared=on","-CursorType=System","-AlwaysCursor=off"]),endpoint:"cli.invalid",workingDirectory:"/launch")
  let loader = NativeSessionDefaults(runtime:runtime,store:store,profileStore:profiles,profileID:profile.id,invocation:request)
  var published: String?
  let observation = loader.$session.sink { if $0 != nil { published = loader.invocationResolution?.endpoint } }
  loader.load(); try await until { !loader.isLoading }
  try check(loader.isReady && loader.session?.initialShared == true && loader.invocationResolution?.configuration.sharedSource == .commandLine,"CLI applied after profile and defaults")
  try check(loader.session?.initialReconnectOnError == false && loader.session?.clipboardSendEnabled == false,"profile and defaults absent CLI fields inherited")
  try check(published == "cli.invalid" && loader.session?.snapshot.state == .idle,"CLI metadata before publication without connection")
  observation.cancel(); await loader.close()
  var registrations = 0
  let model = ConnectionModel(runtime:runtime,preferences:store,profileStore:profiles,profileID:profile.id,invocation:request) { _,_ in registrations += 1 }
  guard let defaults = model.defaults else { throw Failure(message:"missing model defaults") }
  try await until { !defaults.isLoading }
  try check(model.endpoint == "cli.invalid" && model.canConnect && registrations == 1 && model.session?.snapshot.state == .idle,"connection model installs CLI endpoint before admission")
  model.requestClose(); await model.close()
  let reader = Reader(), file = NativeDocumentOpenRequest(url:URL(fileURLWithPath:"/fixture.tidyvnc"),workingDirectory:"/launch")
  let reviewed = NativeSessionDefaults(runtime:runtime,store:store,invocation:request,document:file,documentReader:reader,documentDisplays:{ [.init("one")] })
  reviewed.load(); try await until { !reviewed.isLoading }
  guard let mapping = reviewed.documentMapping else { throw Failure(message:"missing document mapping") }
  reviewed.resolveDocumentMapping(mapping.id,assignments:[99:.init("one")])
  guard let review = reviewed.documentReview else { throw Failure(message:"missing review") }
  try check(review.resolution.cursorType == .system && reviewed.session == nil,"inactive CLI shape survives manual mapping")
  reviewed.editDocumentMapping(review.id)
  guard let edited = reviewed.documentMapping else { throw Failure(message:"missing edited mapping") }
  reviewed.resolveDocumentMapping(edited.id,assignments:[99:.init("one")])
  reviewed.acceptDocument(reviewed.documentReview!.id)
  try check(reviewed.documentResolution?.cursorType == .system && reviewed.session?.initialShared == false,"file wins after mapping re-edit")
  await reviewed.close()
  let unsupported = NativeInvocationRequest(options:try .init(arguments:["-via=private invalid"]),endpoint:"",workingDirectory:"/launch")
  let bad = NativeSessionDefaults(runtime:runtime,store:store,invocation:unsupported,document:file,documentReader:reader)
  let count = await reader.calls
  bad.load(); try await until { !bad.isLoading }
  let finalCount = await reader.calls
  try check(bad.invocationIssue != nil && bad.session == nil && count == finalCount,"invalid gateway fails before file IO")
  await bad.close()
  await reader.pause()
  let stopped = NativeSessionDefaults(runtime:runtime,store:store,invocation:request,document:file,documentReader:reader)
  stopped.load()
  for _ in 0..<1000 { if await reader.pending() { break }; try await Task.sleep(for:.milliseconds(2)) }
  let pending = await reader.pending(); try check(pending,"read suspended")
  stopped.stop(); await reader.resume(); await stopped.close()
  try check(stopped.session == nil && stopped.documentReview == nil,"close rejects late file results")
  try check(memory.writes == writes && history.writes == historyWrites,"launch does not persist CLI values")
  try await runtime.shutdown(); await store.close(); await profiles.close()
}
@main struct NativeInvocationResolutionTests {
  static func main() async throws {
    try values(); try layers(); try await admission()
    print("PASS invocation validation, precedence, migrations, mapping, admission and cancellation")
  }
}
