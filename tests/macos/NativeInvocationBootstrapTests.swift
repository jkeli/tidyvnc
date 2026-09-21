// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
func expect(_ reason: NativeInvocationProblem, _ argument: UInt32, _ body: () throws -> Void) throws {
  do { try body(); throw Failure(message:"invalid argv accepted") }
  catch let error as NativeInvocationFailure {
    try check(error.problem == reason && error.argument == argument && !error.description.contains("private"),"typed redacted argv failure")
  }
}
func raw(_ inputs: [[UInt8]]) throws -> [String] {
  let pointers = inputs.map { input -> UnsafeMutablePointer<CChar>? in
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity:input.count+1)
    for (index,byte) in input.enumerated() { pointer[index] = CChar(bitPattern:byte) }
    pointer[input.count] = 0; return pointer
  }
  defer { for pointer in pointers { pointer?.deallocate() } }
  var argv = pointers
  return try argv.withUnsafeMutableBufferPointer { try NativeInvocationArguments.read(argc:Int32($0.count),argv:$0.baseAddress!) }
}
func arguments() throws {
  try check(try raw([Array("private executable".utf8),Array("-Shared=on".utf8),Array("秘密.invalid".utf8)]) == ["-Shared=on","秘密.invalid"],"strict raw argv excludes executable and owns Unicode")
  try expect(.invalidText,2) { _ = try raw([[],Array("--help".utf8),[0xff]]) }
  try expect(.nullByte,1) { _ = try NativeInvocationArguments.decode([Data([65,0,66])]) }
  try expect(.tooLarge,1) { _ = try NativeInvocationArguments.decode([Data(repeating:65,count:65537)]) }
  try expect(.tooManyArguments,0) { _ = try NativeInvocationArguments.decode(Array(repeating:Data(),count:4097)) }
  try expect(.tooLarge,17) { _ = try NativeInvocationArguments.decode(Array(repeating:Data(repeating:65,count:65536),count:17)) }
  try expect(.invalidValue,1) { _ = try NativeInvocationOptions(arguments:["-Shared=private","--help"]) }
  let help = try NativeInvocationBootstrap.terminal(.init(arguments:["-PasswordFile=private-path","--help"]),version:"fixture")!
  try check(help.exitCode == 1 && help.text.contains("TidyVNC vfixture") && !help.text.contains("private-path"),"retained help status and no input reflection")
  for option in try NativeInvocationSyntax.options() { try check(help.text.contains("  "+option.name+" "),"shared help catalog") }
  try check(help.text.contains("PasswordFile <value> (alias: passwd)\n") && help.text.contains("Shared [on|off]\n"),"native support status and aliases")
  let version = try NativeInvocationBootstrap.terminal(.init(arguments:["--version"]),version:NativeBuildInfo.version)!
  try check(version.exitCode == 0 && version.text.contains(NativeBuildInfo.version) && !version.text.contains("Parameters"),"build-derived version")
  try check(try NativeInvocationBootstrap.terminal(.init(arguments:[]),version:"fixture") == nil,"ordinary launch does not print terminal output")
}
final class Inspector: NativeInvocationPathInspecting, @unchecked Sendable {
  private let lock = NSLock(); private var paths: [String] = []
  let result: NativeInvocationPathKind
  init(_ result: NativeInvocationPathKind) { self.result = result }
  var calls: [String] { lock.withLock { paths } }
  func kind(at path: String) -> NativeInvocationPathKind { lock.withLock { paths.append(path) }; return result }
}
func classification() async throws {
  let inspector = Inspector(.file)
  let bare = try NativeInvocationBootstrap.launch(.init(arguments:["file.tidyvnc"]),workingDirectory:"/launch",inspector:inspector)
  try check(bare.invocation.endpoint == "file.tidyvnc" && bare.connectsOnReady && inspector.calls.isEmpty,"bare file-like name remains retained host spelling")
  let relative = try NativeInvocationBootstrap.launch(.init(arguments:["./file.tidyvnc"]),workingDirectory:"/launch",inspector:inspector)
  try check(relative.document != nil && relative.invocation.endpoint.isEmpty && !relative.connectsOnReady && inspector.calls == ["/launch/./file.tidyvnc"],"relative explicit file classified using captured cwd")
  let untouched = Inspector(.socket)
  do {
    _ = try NativeInvocationBootstrap.launch(.init(arguments:["-via=private","/private-path"]),workingDirectory:"/launch",inspector:untouched)
    throw Failure(message:"unsupported adapter accepted")
  } catch let failure as NativeInvocationResolutionFailure { try check(failure.reason == .unsupportedOption && untouched.calls.isEmpty,"native option preflight precedes path inspection") }
  let listen = try NativeInvocationBootstrap.launch(.init(arguments:["-listen"]),workingDirectory:"/launch",inspector:untouched)
  try check(listen.listen?.port == 5500 && listen.listen?.ipv4 == true && listen.listen?.ipv6 == true &&
    listen.invocation.endpoint.isEmpty && !listen.connectsOnReady && listen.document == nil,"listen defaults never create an outbound endpoint")
  let ephemeral = try NativeInvocationBootstrap.launch(.init(arguments:["-listen=off","-LISTEN","-UseIPv6=off","0"]),workingDirectory:"/launch")
  try check(ephemeral.listen?.port == 0 && ephemeral.listen?.ipv6 == false,"last boolean assignment and ephemeral listen port")
  let outbound = try NativeInvocationBootstrap.launch(.init(arguments:["-listen","-listen=off","host"]),workingDirectory:"/launch")
  try check(outbound.listen == nil && outbound.connectsOnReady,"disabled listen retains outbound launch")
  let emptyListen = try NativeInvocationBootstrap.launch(.init(arguments:["-listen",""]),workingDirectory:"/launch")
  try check(emptyListen.listen?.port == 5500,"shared parser ignores empty argv operands")
  for port in ["65536","99999999999999999999999999","5500tail","host","+5500"," 5500"] {
    do {
      _ = try NativeInvocationBootstrap.launch(.init(arguments:["-listen",port]),workingDirectory:"/launch")
      throw Failure(message:"invalid listen port admitted")
    } catch let failure as NativeInvocationResolutionFailure { try check(failure.reason == .invalidListenPort,"strict listen port failure") }
  }
  for path in ["./private.tidyvnc","/private-socket"] {
    do {
      _ = try NativeInvocationBootstrap.launch(.init(arguments:["-listen",path]),workingDirectory:"/launch",inspector:untouched)
      throw Failure(message:"unimplemented listen file accepted")
    } catch let failure as NativeInvocationResolutionFailure { try check(failure.reason == .listenFileUnsupported && untouched.calls.isEmpty,"listen file fails before path inspection") }
  }
  do {
    _ = try NativeInvocationBootstrap.launch(.init(arguments:["-listen","-UseIPv4=off","-UseIPv6=off"]),workingDirectory:"/launch")
    throw Failure(message:"disabled listen network accepted")
  } catch let failure as NativeInvocationResolutionFailure { try check(failure.reason == .invalidValue,"listen requires enabled family") }
  let empty = try NativeInvocationBootstrap.launch(.init(arguments:["-Shared"]),workingDirectory:"/launch",inspector:untouched)
  try check(empty.document == nil && empty.invocation.endpoint.isEmpty && !empty.connectsOnReady,"options without operand open form")
  let root = URL(fileURLWithPath:"/tmp/tidy-cli-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:root) }
  let socketPath = root.appendingPathComponent("socket").path
  let fd = socket(AF_UNIX,SOCK_STREAM,0); try check(fd >= 0,"Unix socket fixture")
  defer { Darwin.close(fd) }
  var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of:&address.sun_path) { target in target.copyBytes(from:Array(socketPath.utf8)+[0]) }
  let bound = withUnsafePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) {
    Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))
  } }
  try check(bound == 0,"Unix fixture bind")
  let local = try NativeInvocationBootstrap.launch(.init(arguments:["./socket"]),workingDirectory:root.path)
  try check(local.document == nil && local.connectsOnReady && local.invocation.endpoint == root.path+"/./socket","actual relative Unix socket becomes cwd-anchored endpoint")
  let fifo = root.appendingPathComponent("pipe"); try check(mkfifo(fifo.path,0o600) == 0,"FIFO fixture")
  let special = try NativeInvocationBootstrap.launch(.init(arguments:[fifo.path]),workingDirectory:root.path)
  do { _ = try await NativeDocumentFileReader().read(special.document!.url); throw Failure(message:"FIFO read accepted") }
  catch NativeDocumentOpenError.notRegular {}
  let physical = root.appendingPathComponent("physical")
  try FileManager.default.createDirectory(at:physical.appendingPathComponent("child"),withIntermediateDirectories:true)
  try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:physical.appendingPathComponent("child"))
  let expected = Data("correct physical parent".utf8)
  try expected.write(to:physical.appendingPathComponent("target.tidyvnc"))
  try Data("incorrect lexical parent".utf8).write(to:root.appendingPathComponent("target.tidyvnc"))
  let linked = try NativeInvocationBootstrap.launch(.init(arguments:["./link/../target.tidyvnc"]),workingDirectory:root.path)
  let bytes = try await NativeDocumentFileReader().read(linked.document!.url)
  try check(bytes == expected,"file classification and reader preserve symlink/parent OS semantics")
}
final class Memory: NativePreferencesBacking, @unchecked Sendable {
  func read() -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"startup must not write preferences") }
}
@MainActor func until(_ label: String = "startup", _ condition: () -> Bool) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"startup fixture timeout: "+label)
}
@MainActor func ownershipAndConnection() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:Memory())
  guard let peer = native_test_peer_create_pattern(0) else { throw Failure(message:"missing local peer") }
  defer { native_test_peer_destroy(peer) }
  let launch = try NativeInvocationBootstrap.launch(.init(arguments:["-Shared","127.0.0.1::\(native_test_peer_port(peer))"]),workingDirectory:"/launch")
  let startup = NativeInvocationStartup(launch)
  let taken = startup.take()!
  try check(startup.take() == nil,"first window consumes request exactly once")
  let stopped = NativeInvocationStartup(launch); stopped.stop(); try check(stopped.take() == nil,"quit discards unopened launch")
  var registrations = 0
  let model = ConnectionModel(runtime:runtime,preferences:store,invocation:taken.invocation,connectOnReady:taken.connectsOnReady) { _,_ in registrations += 1 }
  try await until("connected") { model.session?.snapshot.state == .connected && !model.busy }
  try check(registrations == 1 && native_test_peer_shared(peer) == 1 && model.endpoint == launch.invocation.endpoint,"direct host auto-connects once with applied CLI policy")
  model.disconnect(); try await until("disconnected") { model.session?.snapshot.state == .closed && !model.busy }
  try await Task.sleep(for:.milliseconds(40))
  try check(model.session?.snapshot.state == .closed,"disconnect does not replay startup connection")
  await model.close()
  var initialGeneration: UInt64 = 0
  let cancelled = ConnectionModel(runtime:runtime,preferences:store,invocation:taken.invocation,connectOnReady:true) { session,model in initialGeneration = session.generation; model.requestClose() }
  try await until("cancelled publication") { cancelled.closing }
  await cancelled.close(); try check(cancelled.session?.generation == initialGeneration,"close during publication revokes automatic connection")
  let edited = ConnectionModel(runtime:runtime,preferences:store,invocation:taken.invocation,connectOnReady:true) { _,model in model.endpoint = "edited.invalid" }
  try await until("edited admission") { edited.defaults?.isReady == true }
  try await Task.sleep(for:.milliseconds(20))
  try check(edited.session?.snapshot.state == .idle,"endpoint edit revokes startup intent")
  await edited.close(); try await runtime.shutdown(); await store.close()
}
@MainActor final class Screens: NativeDisplaySource {
  var connected = true
  func read() -> [NativeDisplay] {
    guard connected else { return [] }
    let bounds = NativeDisplayRectangle(x:0,y:0,width:1000,height:800)
    return [.init(id:.init("fixture-display"),name:"Fixture Display",bounds:bounds,workArea:bounds,backingScale:1,isPrimary:true)]
  }
}
@MainActor func directMapping() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:Memory()), screens = Screens()
  let displays = NativeDisplayService(source:screens,notifications:NotificationCenter(),workspaceNotifications:NotificationCenter())
  guard let peer = native_test_peer_create_pattern(0) else { throw Failure(message:"missing mapping peer") }
  defer { native_test_peer_destroy(peer) }
  let launch = try NativeInvocationBootstrap.launch(.init(arguments:["-Shared","-FullScreenMode=Selected",
    "-FullScreenSelectedMonitors=2147483647","127.0.0.1::\(native_test_peer_port(peer))"]),workingDirectory:"/launch")
  let model = ConnectionModel(runtime:runtime,preferences:store,displays:displays,invocation:launch.invocation,connectOnReady:launch.connectsOnReady) { _,_ in }
  guard let defaults = model.defaults else { throw Failure(message:"missing defaults") }
  try await until("direct mapping") { !defaults.isLoading }
  guard let mapping = defaults.invocationMapping else { throw Failure(message:"missing direct mapping") }
  try check(model.session == nil && !model.canConnect && mapping.numbers == [2147483647],"no session before sparse CLI mapping")
  defaults.resolveInvocationMapping(UUID(),assignments:[2147483647:.init("fixture-display")])
  try check(model.session == nil,"stale mapping ID rejected")
  defaults.resolveInvocationMapping(mapping.id,assignments:[:])
  try check(defaults.invocationIssue != nil && model.session == nil,"incomplete mapping rejected")
  screens.connected = false; displays.refresh()
  defaults.resolveInvocationMapping(mapping.id,assignments:[2147483647:.init("fixture-display")])
  try check(model.session == nil,"disconnected display rejected")
  screens.connected = true; displays.refresh()
  defaults.resolveInvocationMapping(mapping.id,assignments:[2147483647:.init("fixture-display")])
  try await until("mapped auto-connect") { model.session?.snapshot.state == .connected && !model.busy }
  try check(defaults.invocationMapping == nil && native_test_peer_shared(peer) == 1 &&
    model.session?.initialFullscreenPolicy.selectedDisplays == [.init("fixture-display")],"explicit CLI mapping resumes exactly the requested connection")
  await model.close()
  let formLaunch = try NativeInvocationBootstrap.launch(.init(arguments:["-FullScreenMode=Selected","-FullScreenSelectedMonitors=99"]),workingDirectory:"/launch")
  let form = ConnectionModel(runtime:runtime,preferences:store,displays:displays,invocation:formLaunch.invocation,connectOnReady:formLaunch.connectsOnReady) { _,_ in }
  try await until("empty-host mapping") { form.defaults?.isLoading == false }
  let formDefaults = form.defaults!, old = formDefaults.invocationMapping!.id
  formDefaults.cancelInvocationMapping(UUID()); try check(formDefaults.invocationMapping != nil,"stale cancel ignored")
  formDefaults.cancelInvocationMapping(old)
  try check(form.session == nil && formDefaults.invocationMapping == nil,"cancel never admits session")
  formDefaults.load(); try await until("mapping retry") { !formDefaults.isLoading }
  let fresh = formDefaults.invocationMapping!.id
  formDefaults.resolveInvocationMapping(old,assignments:[99:.init("fixture-display")])
  try check(form.session == nil,"old callback cannot apply after retry")
  formDefaults.resolveInvocationMapping(fresh,assignments:[99:.init("fixture-display")])
  try await until("empty-host form") { formDefaults.isReady }
  try check(form.session?.snapshot.state == .idle && form.endpoint.isEmpty && !form.canConnect,"no-host CLI opens idle form after mapping")
  await form.close(); displays.stop(); try await runtime.shutdown(); await store.close()
}
@main struct NativeInvocationBootstrapTests {
  static func main() async throws {
    try arguments(); try await classification(); try await ownershipAndConnection(); try await directMapping()
    print("PASS strict raw argv, terminal actions, file/socket classification, one-shot ownership and CLI auto-connect")
  }
}
