// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
func resolution(_ arguments: [String], base: NativeSessionConfiguration = .init()) throws -> NativeInvocationResolution {
  try .init(options:.init(arguments:arguments),endpoint:"",base:base,workingDirectory:"/launch")
}
func valuesAndDocuments() throws {
  let defaults = try resolution([]).configuration
  try check(defaults.networkPolicy == .builtIn && defaults.networkSources.isEmpty,"native dual-stack defaults")
  var base = NativeSessionConfiguration()
  base.networkPolicy = .init(ipv4:false,ipv6:false); base.networkSources = [.ipv4:.session,.ipv6:.session]
  let resolved = try resolution(["-UseIPv4=off","-useipv4=YES"],base:base).configuration
  try check(resolved.networkPolicy == .init(ipv4:true,ipv6:false) &&
    resolved.networkSources[.ipv4] == .commandLine && resolved.networkSources[.ipv6] == .session,
    "per-field inherited policy and last valid occurrence provenance")
  do {
    _ = try NativeInvocationOptions(arguments:["-UseIPv6=private-invalid","-UseIPv6=off"])
    throw Failure(message:"invalid earlier family value accepted")
  } catch let failure as NativeInvocationFailure {
    try check(failure.problem == .invalidValue && failure.argument == 1,"shared per-occurrence validation")
  }
  let document = try NativeConnectionDocument(data:Data("TidyVNC Configuration file Version 1.0\nShared=on\nUseIPv6=on\n".utf8))
  let file = try NativeDocumentResolution(document:document,base:resolved)
  let config = try file.configuration(acknowledging:Set(file.notices.map(\.line)))
  try check(config.networkPolicy == resolved.networkPolicy && config.networkSources == resolved.networkSources &&
    file.notices.count == 1,"file format cannot override CLI network settings; ignored field requires review")
  let export = try NativeDocumentExport(endpoint:"",configuration:config)
  try check(export.losses.contains(.networkFamilies),"network omission disclosed")
  do {
    _ = try export.serializedData(acknowledging:export.losses.subtracting([.networkFamilies]))
    throw Failure(message:"unacknowledged network omission accepted")
  } catch NativeDocumentExportError.reviewRequired {}
  let encoded = try NativeConnectionDocument(data:export.serializedData(acknowledging:export.losses))
  try check(!encoded.entries.contains { ["UseIPv4","UseIPv6"].contains($0.name) },"no unsupported format extension")
  let restored = try NativeDocumentResolution(document:encoded,base:base).configuration()
  try check(restored.networkPolicy == base.networkPolicy,"reviewed omission uses receiving session policy")
  let help = try NativeInvocationBootstrap.terminal(.init(arguments:["--help"]),version:"fixture")!
  try check(help.text.contains("  UseIPv4 [on|off]\n") && help.text.contains("  UseIPv6 [on|off]\n"),"native help advertises implemented family adapters")
}
final class Peer {
  let raw: UnsafeMutableRawPointer
  let endpoint: String
  init(_ family: UInt32) throws {
    let path = "/tmp/tidy-net-"+UUID().uuidString
    let peer = family == 0 ? path.withCString { native_test_peer_create_network(0,$0) } : native_test_peer_create_network(family,nil)
    guard let peer else { throw Failure(message:"local network fixture unavailable") }
    raw = peer
    endpoint = family == 0 ? path : (family == 4 ? "127.0.0.1" : "[::1]")+"::\(native_test_peer_port(peer))"
  }
  var hostname: String { "localhost::\(native_test_peer_port(raw))" }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func rejected(_ session: NativeSession, endpoint: String) async throws {
  do { _ = try await session.connect(endpoint:endpoint); throw Failure(message:"disabled address family connected") }
  catch let error as NativeCommandFailure {
    try check(error.snapshot.state == .failed && error.snapshot.endReason == .invalidEndpoint,
              "disabled numeric family reaches typed core failure without fallback")
  }
}
@MainActor func connections() async throws {
  let runtime = try NativeRuntime(), four = try Peer(4), six = try Peer(6), local = try Peer(0)
  let v4 = try runtime.makeSession(configuration:resolution(["-UseIPv6=off"]).configuration)
  let v6 = try runtime.makeSession(configuration:resolution(["-UseIPv4=off"]).configuration)
  let unix = try runtime.makeSession(configuration:resolution(["-UseIPv4=off","-UseIPv6=off"]).configuration)
  let first = try await v4.connect(endpoint:four.endpoint)
  let second = try await v6.connect(endpoint:six.endpoint)
  let third = try await unix.connect(endpoint:local.endpoint)
  try check(first.snapshot.state == .connected,"IPv4-only numeric connection")
  try check(second.snapshot.state == .connected,"IPv6-only numeric connection")
  try check(third.snapshot.state == .connected,"Unix sockets independent of disabled IP families")
  try check(v4.snapshot.state == .connected && v6.snapshot.state == .connected && unix.snapshot.state == .connected,
            "different family policies coexist in one runtime")
  _ = try await v4.disconnect(); _ = try await v6.disconnect(); _ = try await unix.disconnect()
  let generation = unix.generation
  do { _ = try await unix.connect(endpoint:four.endpoint); throw Failure(message:"TCP accepted with both families disabled") }
  catch let failure as NativeError { try check(failure.status == .invalidArgument && unix.generation == generation,"both-disabled TCP rejected before attempt") }
  try await rejected(v4,endpoint:six.endpoint); try await rejected(v6,endpoint:four.endpoint)
  _ = try await v4.connect(endpoint:four.hostname); _ = try await v6.connect(endpoint:six.hostname)
  _ = try await unix.connect(endpoint:local.endpoint)
  try check(v4.snapshot.state == .connected && v6.snapshot.state == .connected && unix.snapshot.state == .connected,
            "hostname lookup respects selected families and reconnect retains every session policy")
  try check(v4.networkSources[.ipv6] == .commandLine && v6.networkSources[.ipv4] == .commandLine,"session captures field provenance")
  try await runtime.shutdown()
}
final class Memory: NativePreferencesBacking, Sendable {
  func read() -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"network launch must not write defaults") }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"network launch timed out")
}
@MainActor func launchAndReview() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:Memory()), peer = try Peer(6)
  let launch = try NativeInvocationBootstrap.launch(.init(arguments:["-UseIPv4=off",peer.endpoint]),workingDirectory:"/launch")
  let model = ConnectionModel(runtime:runtime,preferences:store,invocation:launch.invocation,connectOnReady:true) { _,_ in }
  try await until { model.session?.snapshot.state == .connected && !model.busy }
  try check(model.session?.networkPolicy == .init(ipv4:false),"production model auto-connect applies CLI policy")
  let export = try model.documentExport(legacyDisplays:[])
  try check(export.losses.contains(.networkFamilies),"live Save As reviews omitted network settings")
  await model.close()
  let file = URL(fileURLWithPath:"/tmp/tidy-network-file-"+UUID().uuidString+".tidyvnc")
  try Data(("TidyVNC Configuration file Version 1.0\nServerName="+peer.endpoint+"\nShared=on\n").utf8).write(to:file)
  defer { try? FileManager.default.removeItem(at:file) }
  let request = try NativeInvocationBootstrap.launch(.init(arguments:["-UseIPv4=off",file.path]),workingDirectory:"/launch")
  let reviewed = ConnectionModel(runtime:runtime,preferences:store,document:request.document,invocation:request.invocation,connectOnReady:request.connectsOnReady) { _,_ in }
  try await until { reviewed.defaults?.documentReview != nil }
  reviewed.defaults!.acceptDocument(reviewed.defaults!.documentReview!.id)
  try check(reviewed.session?.networkPolicy == .init(ipv4:false) && reviewed.session?.snapshot.state == .idle,"reviewed file retains invocation policy")
  reviewed.connect(); try await until { reviewed.session?.snapshot.state == .connected && !reviewed.busy }
  try check(native_test_peer_shared(peer.raw) == 1,"file settings and CLI family selection reach same attempt")
  await reviewed.close(); try await runtime.shutdown(); await store.close()
}
@main enum NativeNetworkPolicyTests {
  @MainActor static func main() async {
    do { try valuesAndDocuments(); try await connections(); try await launchAndReview(); print("Native IPv4/IPv6 selection, isolation, reconnect, Unix and export review passed") }
    catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
}
