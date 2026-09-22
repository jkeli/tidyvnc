// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error, CustomStringConvertible { let description: String }
func expect(_ value: @autoclosure () throws -> Bool,_ message: String) throws {
  if try !value() { throw Failure(description:message) }
}
final class Peer: @unchecked Sendable {
  let raw: UnsafeMutableRawPointer
  init() throws {
    guard let raw = native_test_peer_create(0) else { throw Failure(description:"peer creation") }
    self.raw = raw
  }
  var port: UInt32 { UInt32(native_test_peer_port(raw)) }
  deinit { native_test_peer_destroy(raw) }
}
final class Paths: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ value: String) { lock.withLock { values.append(value) } }
  var all: [String] { lock.withLock { values } }
}
func fixture(_ request: NativeSSHTunnelRequest, executable: String, behavior: String = "ready", port: UInt32 = 0,
             timeout: Duration = .seconds(2), paths: Paths = Paths()) -> NativeSSHTunnel {
  return NativeSSHTunnel(request:request,executable:executable,timeout:timeout) { command,socket in
    paths.add(socket); return [command.rawValue,socket,behavior,String(port)]
  }
}
func gone(_ paths: Paths) throws {
  for path in paths.all {
    try expect(!FileManager.default.fileExists(atPath:URL(fileURLWithPath:path).deletingLastPathComponent().path),"private directory drained")
  }
}
func requestChecks() async throws {
  // Gateway preflight does not need a target or file read. Its serialized form
  // round-trips through validation instead of trusting a caller-supplied digest.
  for text in ["alice@GATEWAY.invalid","ssh://gateway.invalid:2222","ssh://alice@[fe80::1%en0]:22"] {
    let gateway = try NativeSSHGateway(text)
    let decoded = try JSONDecoder().decode(NativeSSHGateway.self,from:JSONEncoder().encode(gateway))
    let request = try NativeSSHTunnelRequest(endpoint:"remote.invalid",gateway:decoded)
    try expect(gateway == decoded && request.gateway == gateway && request.routeIdentity == gateway.routeIdentity,
               "validated gateway survives storage and deferred target resolution")
    try expect(gateway == NativeSSHGateway(gateway.canonicalURI),"canonical URI round-trip")
  }
  for bytes in [Data("null".utf8),Data("{}".utf8),Data("\"ssh://user:password@host\"".utf8)] {
    do { _ = try JSONDecoder().decode(NativeSSHGateway.self,from:bytes); throw Failure(description:"unvalidated stored gateway accepted") }
    catch is DecodingError {}
  }
  let maximum = try NativeSSHGateway(String(repeating:"a",count:4087))
  try expect(maximum.canonicalURI.utf8.count == 4096 && maximum == NativeSSHGateway(maximum.canonicalURI),
             "canonical gateway at byte limit remains decodable")
  do { _ = try NativeSSHGateway(String(repeating:"a",count:4088)); throw Failure(description:"oversized canonical gateway accepted") }
  catch let error as NativeTunnelError { try expect(error == .invalidRequest,"canonical URI bound checked before persistence") }
  let first = try NativeSSHTunnelRequest(endpoint:"REMOTE.invalid:2",gateway:"alice@GATEWAY.invalid")
  let same = try NativeSSHTunnelRequest(endpoint:"remote.invalid::5902",gateway:"ssh://alice@gateway.invalid:22")
  try expect(first.routeIdentity == same.routeIdentity,"canonical gateway identity")
  for gateway in ["bob@gateway.invalid","gateway.invalid","ssh://alice@gateway.invalid:2222","alice@other.invalid"] {
    try expect(first.routeIdentity != NativeSSHTunnelRequest(endpoint:"remote.invalid",gateway:gateway).routeIdentity,"route identities stay distinct")
  }
  for gateway in ["", "-oProxyCommand=bad", "[-o]", "a b", "a\nb", "a@b@c", "ssh://u:password@host", "ssh://host:0", "ssh://host:65536", "host/command", "$(touch marker)", "ssh://host:22/path", "u;cmd@host"] {
    do { _ = try NativeSSHTunnelRequest(endpoint:"remote.invalid",gateway:gateway); throw Failure(description:"invalid gateway accepted") }
    catch let error as NativeTunnelError { try expect(error == .invalidRequest,"redacted gateway rejection") }
  }
  for endpoint in ["/tmp/socket", "host;command", "host$(bad)", "host::0"] {
    do { _ = try NativeSSHTunnelRequest(endpoint:endpoint,gateway:"gateway"); throw Failure(description:"invalid target accepted") }
    catch let error as NativeTunnelError { try expect(error == .unsupportedTarget,"unsupported forwarding grammar") }
  }
  let ipv6 = try NativeSSHTunnelRequest(endpoint:"[2001:db8::1%en0]::5901",gateway:"ssh://alice@[::1]:2222")
  let arguments = ipv6.arguments(.forward,socket:"/tmp/private/forward")
  try expect(arguments.contains("/tmp/private/forward:[2001:db8::1%en0]:5901") && arguments.last == "::1", "IPv6 forwarding stays one literal argument")
  try expect(!first.routeIdentity.contains("alice") && !first.routeIdentity.contains("gateway"),"route digest excludes labels")
  // The installed SSH parses these options without connecting, loading user
  // configuration, opening a terminal, or retaining its config dump.
  for command in [NativeSSHCommand.master,.forward] {
    let child = try NativeTunnelProcess.launch(executable:"/usr/bin/ssh",arguments:["-G"] + ipv6.arguments(command,socket:"/tmp/private/forward"),environment:[:],onExit:{})
    let result = await child.wait(); try expect(result == .exited(0),"system SSH accepts argv")
  }
}
func failuresAndCancellation(executable: String) async throws {
  let original = open("/dev/null",O_RDONLY)
  guard original >= 0 else { throw Failure(description:"descriptor fixture") }
  let inherited = fcntl(original,F_DUPFD,200); close(original)
  guard inherited >= 0 else { throw Failure(description:"descriptor duplication") }
  defer { close(inherited) }
  let descriptorChild = try NativeTunnelProcess.launch(executable:executable,arguments:["--descriptors",String(inherited)],environment:[:],onExit:{})
  let descriptorResult = await descriptorChild.wait()
  try expect(descriptorResult == .exited(0),"spawn closes inherited descriptors and creates its own group")
  let request = try NativeSSHTunnelRequest(endpoint:"remote.invalid",gateway:"gateway.invalid")
  for (behavior,expected) in [("exit",NativeTunnelError.startupFailed),("no-ready",.timedOut),("ignore-term",.timedOut),("temp-control",.timedOut),("fail-forward",.startupFailed),("hang-forward",.timedOut)] {
    let paths = Paths(), tunnel = fixture(request,executable:executable,behavior:behavior,timeout:.milliseconds(180),paths:paths)
    do { _ = try await tunnel.start(); throw Failure(description:"failed fixture started") }
    catch let error as NativeTunnelError { try expect(error == expected,"typed startup failure for \(behavior)") }
    await tunnel.close(); try gone(paths)
  }
  let missingPaths = Paths(), missing = fixture(request,executable:"/no/such/tidyvnc-fixture",paths:missingPaths)
  do { _ = try await missing.start(); throw Failure(description:"missing executable started") }
  catch let error as NativeTunnelError { try expect(error == .launchFailed,"launch failure") }
  try gone(missingPaths)

  for behavior in ["no-ready","hang-forward"] {
    let paths = Paths(), tunnel = fixture(request,executable:executable,behavior:behavior,paths:paths)
    let task = Task { try await tunnel.start() }
    let required = behavior == "hang-forward" ? 3 : 1
    for _ in 0..<500 where paths.all.count < required { try await Task.sleep(for:.milliseconds(2)) }
    try expect(paths.all.count >= required,"reached intended cancellation phase")
    task.cancel()
    do { _ = try await task.value; throw Failure(description:"cancelled startup returned a route") } catch is CancellationError {}
    await tunnel.close(); try gone(paths)
  }
  let paths = Paths(), tunnel = fixture(request,executable:executable,behavior:"no-ready",paths:paths)
  let starting = Task { try await tunnel.start() }
  for _ in 0..<100 where paths.all.isEmpty { try await Task.sleep(for:.milliseconds(2)) }
  do { _ = try await tunnel.start(); throw Failure(description:"concurrent start accepted") }
  catch let error as NativeTunnelError { try expect(error == .busy,"one startup per owner") }
  async let first: Void = tunnel.close(); async let second: Void = tunnel.close(); _ = await (first,second)
  do { _ = try await starting.value; throw Failure(description:"closed startup returned a route") }
  catch let error as NativeTunnelError { try expect(error == .closed || error == .startupFailed,"close revokes startup") }
  try gone(paths)
}
@MainActor func forwardingAndOwnership(executable: String) async throws {
  let request = try NativeSSHTunnelRequest(endpoint:"remote.invalid:3",gateway:"alice@gateway.invalid")
  let paths = Paths(), peer = try Peer(), tunnel = fixture(request,executable:executable,port:peer.port,paths:paths)
  let route = try await tunnel.start(), repeated = try await tunnel.start()
  try expect(route.localEndpoint == repeated.localEndpoint && route.endpoint == request.endpoint && route.routeIdentity == request.routeIdentity,"stable prepared route")
  var info = stat(); let directory = URL(fileURLWithPath:route.localEndpoint).deletingLastPathComponent().path
  try expect(lstat(directory,&info) == 0 && info.st_mode & 0o777 == 0o700,"private socket directory")
  let runtime = try NativeRuntime(); var configuration = NativeSessionConfiguration(); configuration.securityTypes = [1]
  let session = try runtime.makeSession(configuration:configuration)
  let completion = try await session.connect(endpoint:route.endpoint,through:route.localEndpoint,routeIdentity:route.routeIdentity)
  try expect(completion.snapshot.state == .connected,"RFB over owned child forwarding")
  // The transport drains before the process/socket owner is closed.
  try await session.close(); await tunnel.close(); await tunnel.close(); try await runtime.shutdown(); try gone(paths)
  let exited = await tunnel.waitForExit(); try expect(exited != nil,"joined child exit")
  do { _ = try await tunnel.start(); throw Failure(description:"closed owner restarted") }
  catch let error as NativeTunnelError { try expect(error == .closed,"fresh owner required for reconnect") }

  let droppedPaths = Paths()
  var dropped: NativeSSHTunnel? = fixture(request,executable:executable,behavior:"noisy-ready",paths:droppedPaths)
  _ = try await dropped!.start(); dropped = nil
  for _ in 0..<200 {
    if droppedPaths.all.allSatisfy({ !FileManager.default.fileExists(atPath:URL(fileURLWithPath:$0).deletingLastPathComponent().path) }) { break }
    try await Task.sleep(for:.milliseconds(5))
  }
  try gone(droppedPaths)
}
@MainActor func realSSH(gateway: String, key: String, knownHosts: String) async throws {
  let peer = try Peer(), request = try NativeSSHTunnelRequest(endpoint:"127.0.0.1::\(peer.port)",gateway:gateway)
  func owner(known: String) -> NativeSSHTunnel {
    NativeSSHTunnel(request:request,executable:"/usr/bin/ssh",timeout:.seconds(20)) { command,socket in
      ["-i",key,"-o","IdentitiesOnly=yes","-o","IdentityAgent=none","-o","UserKnownHostsFile=\(known)",
       "-o","GlobalKnownHostsFile=/dev/null"] + request.arguments(command,socket:socket)
    }
  }
  let unknown = owner(known:knownHosts + ".missing")
  do { _ = try await unknown.start(); throw Failure(description:"unknown SSH host key accepted") }
  catch let error as NativeTunnelError { try expect(error == .startupFailed,"unknown host key fails without prompting") }
  let tunnel = owner(known:knownHosts), route = try await tunnel.start()
  let runtime = try NativeRuntime(); var configuration = NativeSessionConfiguration(); configuration.securityTypes = [1]
  let session = try runtime.makeSession(configuration:configuration)
  do {
    let connected = try await session.connect(endpoint:route.endpoint,through:route.localEndpoint,routeIdentity:route.routeIdentity)
    try expect(connected.snapshot.state == .connected,"RFB negotiated over actual SSH forwarding")
    try await session.close(); await tunnel.close(); try await runtime.shutdown()
  } catch { try? await session.close(); await tunnel.close(); try? await runtime.shutdown(); throw error }
  try expect(!FileManager.default.fileExists(atPath:URL(fileURLWithPath:route.localEndpoint).deletingLastPathComponent().path),"actual SSH socket directory drained")
  print("PASS isolated OpenSSH host-key rejection, public-key authentication, routed RFB and joined cleanup")
}
@main struct Main {
  static func main() async {
    do {
      if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--ssh" {
        try await realSSH(gateway:CommandLine.arguments[2],key:CommandLine.arguments[3],knownHosts:CommandLine.arguments[4]); return
      }
      guard CommandLine.arguments.count == 2 else { throw Failure(description:"fixture path missing") }
      try await requestChecks()
      try await failuresAndCancellation(executable:CommandLine.arguments[1])
      try await forwardingAndOwnership(executable:CommandLine.arguments[1])
      print("PASS SSH argv/identity, child startup/cancellation/drain and routed RFB forwarding")
    } catch { fputs("Tunnel test failed: \(error)\n",stderr); exit(1) }
  }
}
