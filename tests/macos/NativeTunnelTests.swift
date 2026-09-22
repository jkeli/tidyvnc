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
  let inherited = try NativeSSHGateway("gateway.invalid"), explicit = try NativeSSHGateway("ssh://gateway.invalid:22")
  try expect(!inherited.portIsExplicit && explicit.portIsExplicit && inherited != explicit,"requested port intent survives canonicalization")
  let legacy = try JSONDecoder().decode(NativeSSHGateway.self,from:Data("\"gateway.invalid\"".utf8))
  try expect(legacy == explicit,"legacy omitted port retains concrete 22 semantics")
  for invalid in ["{\"version\":true,\"uri\":\"host\"}", "{\"version\":3,\"uri\":\"host\"}",
                  "{\"version\":2,\"uri\":\"host\",\"extra\":1}"] {
    do { _ = try JSONDecoder().decode(NativeSSHGateway.self,from:Data(invalid.utf8)); throw Failure(description:"invalid gateway record admitted") }
    catch is DecodingError {}
  }
  let maximum = try NativeSSHGateway(String(repeating:"a",count:4090))
  try expect(maximum.canonicalURI.utf8.count == 4096 && maximum == NativeSSHGateway(maximum.canonicalURI),
             "canonical gateway at byte limit remains decodable")
  do { _ = try NativeSSHGateway(String(repeating:"a",count:4091)); throw Failure(description:"oversized canonical gateway accepted") }
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
func boundedOutput(executable: String) async throws {
  for stream in ["--output","--output-stderr"] {
    let failure = NativeSSHSaveFailure()
    // Keep one classifier with its corresponding pipe; raw stderr is discarded.
    let diagnostics = try NativeTunnelOutput(maximum:65536,saveFailure:failure)
    let child = try NativeTunnelProcess.launch(executable:executable,arguments:[stream,"save-failure"],environment:[:],output:diagnostics,standardError:true,onExit:{})
    _ = await child.wait(); try await diagnostics.drainAvailable()
    let data = try await diagnostics.take()
    try expect(data.isEmpty && failure.failed == (stream == "--output-stderr"),"stderr classification retains no raw diagnostic text and ignores stdout")
  }
  let failure = NativeSSHSaveFailure()
  let diagnostics = try NativeTunnelOutput(maximum:65536,saveFailure:failure)
  let noisy = try NativeTunnelProcess.launch(executable:executable,arguments:["--output-stderr","large"],environment:[:],output:diagnostics,standardError:true,onExit:{})
  let noisyExit = await noisy.wait(), discarded = try await diagnostics.take()
  try expect(noisyExit == .exited(0) && discarded.isEmpty && !failure.failed,
    "large diagnostic streams drain in constant space without retention or false failure")
  for mode in ["small","exact","large","descendant","hang"] {
    let output = try NativeTunnelOutput(maximum:65536)
    let child = try NativeTunnelProcess.launch(executable:executable,arguments:["--output",mode],environment:[:],output:output,onExit:{})
    if mode == "hang" { child.cancel() }
    let exit = await child.wait()
    if mode == "large" {
      do { _ = try await output.take(); throw Failure(description:"excess output accepted") }
      catch NativeTunnelOutputIssue.tooLarge {}
    } else {
      let data = try await output.take()
      if mode == "small" { try expect(data == Data("hostname gateway.invalid\nuser fixture\nport 2222\n".utf8),"fragmented output drained after child exit") }
      if mode == "exact" { try expect(data == Data(repeating:120,count:65536),"exact limit and pipe backpressure") }
      if mode == "descendant" || mode == "hang" { try expect(data.isEmpty,"cancelled process group releases all stdout writers") }
      if mode != "hang" { try expect(exit == .exited(0),"capture does not change exit status") }
    }
    do { _ = try await output.take(); throw Failure(description:"stdout consumed twice") } catch NativeTunnelOutputIssue.unavailable {}
    do {
      _ = try NativeTunnelProcess.launch(executable:executable,arguments:["--output","small"],environment:[:],output:output,onExit:{})
      throw Failure(description:"capture reused")
    } catch NativeTunnelOutputIssue.unavailable {}
  }
  let output = try NativeTunnelOutput()
  do {
    _ = try NativeTunnelProcess.launch(executable:"/missing/tidyvnc-fixture",arguments:[],environment:[:],output:output,onExit:{})
    throw Failure(description:"missing capture child started")
  } catch NativeTunnelError.launchFailed {}
  do { _ = try await output.take(); throw Failure(description:"failed launch output") } catch NativeTunnelOutputIssue.unavailable {}
  let configuration = try NativeTunnelOutput()
  let child = try NativeTunnelProcess.launch(executable:"/usr/bin/ssh",arguments:["-G","-F","/dev/null","-p","2222","-l","fixture","--","gateway.invalid"],environment:["PATH":"/usr/bin:/bin","LC_ALL":"C"],output:configuration,onExit:{})
  let exit = await child.wait(), data = try await configuration.take()
  let text = String(decoding:data,as:UTF8.self)
  try expect(exit == .exited(0) && text.contains("hostname gateway.invalid\n") && text.contains("user fixture\n") && text.contains("port 2222\n"),"system SSH configuration probe without network or user config")
}
func configurationProbe(executable: String) async throws {
  let expected = try NativeSSHGateway("ssh://fixture@gateway.invalid:2222")
  let real = try await NativeSSHConfigurationProbe.baseline(expected)
  try expect(real.gateway == expected,"typed system configuration result")
  let ipv6 = try NativeSSHResolvedGateway(output:Data("hostname ::1\nuser fixture\nport 2222\n".utf8))
  try expect(ipv6.gateway == NativeSSHGateway("ssh://fixture@[::1]:2222"),"IPv6 output is validated as one gateway")
  let valid = "hostname gateway.invalid\nuser fixture\nport 2222\n"
  try expect(NativeSSHResolvedGateway(output:Data((valid + "canonicalizePermittedcnames none\n").utf8)).gateway == expected,"mixed-case OpenSSH option names")
  for invalid in [valid + "port 22\n",valid + "PORT 22\n",valid.replacingOccurrences(of:"2222",with:"0"),
    valid.replacingOccurrences(of:"fixture",with:"bad user"),valid.replacingOccurrences(of:"gateway.invalid",with:"host;command"),
    valid.replacingOccurrences(of:"hostname gateway.invalid\n",with:""),valid + "nul\0byte\n",valid + "carriage\rreturn\n"] {
    do { _ = try NativeSSHResolvedGateway(output:Data(invalid.utf8)); throw Failure(description:"unvalidated configuration output") }
    catch NativeSSHConfigurationIssue.invalidOutput {}
  }
  let fixture = try await NativeSSHConfigurationProbe.run(executable:executable,arguments:["--output","small"],timeout:.seconds(1))
  try expect(fixture.gateway == expected,"fragmented probe output parsed")
  do {
    _ = try await NativeSSHConfigurationProbe.run(executable:executable,arguments:["--output","hang"],timeout:.milliseconds(100))
    throw Failure(description:"configuration deadline ignored")
  } catch NativeSSHConfigurationIssue.timedOut {}
  let task = Task { try await NativeSSHConfigurationProbe.run(executable:executable,arguments:["--output","hang"],timeout:.seconds(10)) }
  try await Task.sleep(for:.milliseconds(30)); task.cancel()
  do { _ = try await task.value; throw Failure(description:"cancelled probe completed") } catch is CancellationError {}
  do {
    _ = try await NativeSSHConfigurationProbe.run(executable:executable,arguments:["--output","large"],timeout:.seconds(1))
    throw Failure(description:"oversized probe accepted")
  } catch NativeSSHConfigurationIssue.invalidOutput {}
}
func defaultGatewayConfiguration() async throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-default-config-" + UUID().uuidString)
  try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  defer { try? FileManager.default.removeItem(at:home) }
  let requested = try NativeSSHGateway("fixture@gateway.invalid")
  for network in [NativeNetworkPolicy(),.init(ipv4:true,ipv6:false),.init(ipv4:false,ipv6:true)] {
    let prepared = try await NativeSSHPreparedGateway.prepareDefault(requested:requested,home:home,network:network)
    let path = prepared.configurationURL.deletingLastPathComponent().path
    do {
      try expect(prepared.network == network && prepared.resolved.gateway == NativeSSHGateway("ssh://fixture@gateway.invalid:22") && Data(contentsOf:prepared.configurationURL).isEmpty,"absent default config captures empty settings and network policy")
      let request = try NativeSSHTunnelRequest(endpoint:"target.invalid",gateway:prepared.resolved.gateway,network:network)
      try await prepared.verify(masterArguments:prepared.arguments(request,command:.master,socket:"/tmp/default-check/forward",interactive:false))
      let different = NativeNetworkPolicy(ipv4:!network.ipv4,ipv6:!network.ipv6)
      do { _ = try NativeSSHTunnel(prepared:prepared,endpoint:"target.invalid",network:different); throw Failure(description:"network policy changed after preparation") }
      catch NativeTunnelError.invalidRequest {}
      let owner = try NativeSSHTunnel(prepared:prepared,endpoint:"target.invalid")
      await owner.close()
    } catch { await prepared.close(); throw error }
    try expect(!FileManager.default.fileExists(atPath:path),"default preparation drains owned empty snapshot")
  }
  let base = home.appendingPathComponent(".ssh"), root = base.appendingPathComponent("config")
  do {
    let value = try await NativeSSHPreparedGateway.prepare(requested:requested,root:root,includeBase:base,home:home)
    await value.close(); throw Failure(description:"explicit missing config ignored")
  } catch NativeSSHConfigurationSnapshotIssue.unsafeFile {}
  do {
    let value = try await NativeSSHPreparedGateway.prepareDefault(requested:requested,home:home,network:.init(ipv4:false,ipv6:false))
    await value.close(); throw Failure(description:"disabled TCP families admitted")
  } catch NativeTunnelError.invalidRequest {}
  try Data("not a directory".utf8).write(to:base)
  do {
    let value = try await NativeSSHPreparedGateway.prepareDefault(requested:requested,home:home)
    await value.close(); throw Failure(description:"bad default parent ignored")
  } catch NativeSSHConfigurationSnapshotIssue.unsafeFile {}
  try FileManager.default.removeItem(at:base)
  try FileManager.default.createSymbolicLink(at:base,withDestinationURL:home.appendingPathComponent("missing-directory"))
  do {
    let value = try await NativeSSHPreparedGateway.prepareDefault(requested:requested,home:home)
    await value.close(); throw Failure(description:"broken default parent symlink ignored")
  } catch NativeSSHConfigurationSnapshotIssue.unsafeFile {}
  try FileManager.default.removeItem(at:base)
  try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false)
  try FileManager.default.createSymbolicLink(at:root,withDestinationURL:home.appendingPathComponent("missing"))
  do {
    let value = try await NativeSSHPreparedGateway.prepareDefault(requested:requested,home:home)
    await value.close(); throw Failure(description:"dangling default symlink ignored")
  } catch NativeSSHConfigurationSnapshotIssue.unsafeFile {}
  try FileManager.default.removeItem(at:root)
  do {
    let value = try await NativeSSHPreparedGateway.prepare(requested:requested,root:root,includeBase:base,home:home,allowMissingRoot:true) { _ in
      try Data("Host *\n User appeared\n".utf8).write(to:root)
    }
    await value.close(); throw Failure(description:"new default config during capture ignored")
  } catch NativeSSHConfigurationSnapshotIssue.changed {}
}
func preparedGateways() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-prepared-" + UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  defer { try? FileManager.default.removeItem(at:root) }
  let source = root.appendingPathComponent("config")
  func write(_ text: String) throws {
    try Data(text.utf8).write(to:source)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:source.path)
  }
  let contents = "Host alias other-alias\n HostName gateway.invalid\n User configured\n Port 2207\n HostKeyAlias key-alias\n"
  try write(contents)
  let alias = try NativeSSHGateway("alias")
  let prepared = try await NativeSSHPreparedGateway.prepare(requested:alias,root:source,includeBase:root,home:root)
  let directory = prepared.configurationURL.deletingLastPathComponent()
  do {
    try expect(prepared.requested == alias && prepared.resolved.gateway == NativeSSHGateway("ssh://configured@gateway.invalid:2207"),"alias resolves configured user and inherited port")
    try expect(prepared.resolved.hostKeyAlias == "key-alias" && prepared.resolved.hostKeyLookupName == "key-alias","explicit host-key alias remains unqualified by port")
    let launchRequest = try NativeSSHTunnelRequest(endpoint:"target.invalid",gateway:prepared.resolved.gateway)
    let launchArguments = prepared.arguments(launchRequest,command:.master,socket:"/tmp/prepared-check/forward",interactive:false)
    try await prepared.verify(masterArguments:launchArguments)
    try expect(launchArguments.last == alias.host && launchArguments.contains("HostName=gateway.invalid"),"launch pins effective host while retaining requested alias")
    let explicit = try await NativeSSHPreparedGateway.prepare(requested:NativeSSHGateway("ssh://chosen@alias:22"),root:source,includeBase:root,home:root)
    let explicitGateway = explicit.resolved.gateway
    await explicit.close()
    try expect(explicitGateway == NativeSSHGateway("ssh://chosen@gateway.invalid:22"),"explicit invocation user and port override config")
    let other = try await NativeSSHPreparedGateway.prepare(requested:NativeSSHGateway("other-alias"),root:source,includeBase:root,home:root)
    let equivalent = other.resolved.routeIdentity == prepared.resolved.routeIdentity
    await other.close()
    try expect(equivalent,"equivalent aliases bind the same effective route")
    try write(contents.replacingOccurrences(of:"gateway.invalid",with:"changed.invalid"))
    let frozen = prepared.resolved
    let repeated = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G","-F",prepared.configurationURL.path,"--",alias.host],timeout:.seconds(5))
    try expect(repeated == frozen,"prepared owner retains the same resolvable snapshot after source edits")
    try expect(frozen.gateway == NativeSSHGateway("ssh://configured@gateway.invalid:2207"),"prepared values do not reread live sources")
    let changed = try await NativeSSHPreparedGateway.prepare(requested:alias,root:source,includeBase:root,home:root)
    let separate = changed.resolved.routeIdentity != frozen.routeIdentity
    await changed.close()
    try expect(separate,"a later source resolution has a distinct route")
    let base = "hostname gateway.invalid\nuser configured\nport 2207\n"
    let plain = try NativeSSHResolvedGateway(output:Data(base.utf8))
    try expect(plain.hostKeyLookupName == "[gateway.invalid]:2207" && plain.routeIdentity != frozen.routeIdentity && plain.routeIdentity != alias.routeIdentity,"default key lookup and resolved namespace differ from alias intent")
    for altered in [base.replacingOccurrences(of:"configured",with:"other"),base.replacingOccurrences(of:"2207",with:"22"),base + "hostkeyalias other-key\n"] {
      let value = try NativeSSHResolvedGateway(output:Data(altered.utf8))
      try expect(value.routeIdentity != plain.routeIdentity,"effective account, port and key lookup separate routes")
    }
    let scoped = try NativeSSHResolvedGateway(output:Data("hostname fe80::1%en0\nuser configured\nport 2222\n".utf8))
    try expect(scoped.gateway == NativeSSHGateway("ssh://configured@[fe80::1%en0]:2222") && scoped.hostKeyLookupName == "[fe80::1%en0]:2222","scoped IPv6 has one effective lookup name")
    let namedNone = try NativeSSHResolvedGateway(output:Data((base + "hostkeyalias none\n").utf8))
    try expect(namedNone.hostKeyAlias == "none" && namedNone.routeIdentity != plain.routeIdentity,"literal alias none is not discarded")
    let oldKey = try NativeCredentialKey(endpoint:"target.invalid",routeIdentity:alias.routeIdentity,authentication:.passwordOnly(securityType:2))
    let resolvedKey = try NativeCredentialKey(endpoint:"target.invalid",routeIdentity:frozen.routeIdentity,authentication:.passwordOnly(securityType:2))
    try expect(oldKey != resolvedKey && NativeTrustScope(endpoint:"target.invalid",routeIdentity:alias.routeIdentity) != NativeTrustScope(endpoint:"target.invalid",routeIdentity:frozen.routeIdentity),"resolved routes cannot silently reuse alias-bound credentials or trust")
    for invalid in [base + "hostkeyalias a\nhostkeyalias b\n",base + "hostkeyalias \n",base + "hostkeyalias bad name\n",base + "hostkeyalias " + String(repeating:"a",count:1025) + "\n"] {
      do { _ = try NativeSSHResolvedGateway(output:Data(invalid.utf8)); throw Failure(description:"invalid key alias admitted") }
      catch NativeSSHConfigurationIssue.invalidOutput {}
    }
  } catch { await prepared.close(); throw error }
  await prepared.close(); await prepared.close()
  try expect(!FileManager.default.fileExists(atPath:directory.path),"prepared owner joins snapshot removal")
  try write("Host alias\n HostName fe80::1%%en0\n User configured\n Port 2222\n")
  let scopedPreparation = try await NativeSSHPreparedGateway.prepare(requested:alias,root:source,includeBase:root,home:root)
  let scopedRequest = try NativeSSHTunnelRequest(endpoint:"target.invalid",gateway:scopedPreparation.resolved.gateway)
  do {
    try await scopedPreparation.verify(masterArguments:scopedPreparation.arguments(scopedRequest,command:.master,socket:"/tmp/prepared-check/forward",interactive:false))
  } catch { await scopedPreparation.close(); throw error }
  await scopedPreparation.close()
  // HostName supplied up front must not silently change Match-selected policy.
  try write("Match host gateway.invalid\n IdentityFile /tmp/changed-identity\nHost alias\n HostName gateway.invalid\n User configured\n Port 2207\n")
  let unstable = try await NativeSSHPreparedGateway.prepare(requested:alias,root:source,includeBase:root,home:root)
  let unstableRequest = try NativeSSHTunnelRequest(endpoint:"target.invalid",gateway:unstable.resolved.gateway)
  do {
    try await unstable.verify(masterArguments:unstable.arguments(unstableRequest,command:.master,socket:"/tmp/prepared-check/forward",interactive:false))
    await unstable.close(); throw Failure(description:"changed Match policy admitted")
  } catch NativeSSHConfigurationIssue.changedPolicy { await unstable.close() }
  try write("Match localnetwork 127.0.0.0/8\n User configured\n")
  do {
    let value = try await NativeSSHPreparedGateway.prepare(requested:alias,root:source,includeBase:root,home:root)
    await value.close(); throw Failure(description:"dynamic network Match admitted")
  } catch NativeSSHConfigurationSnapshotIssue.unsupported {}
  try write("Port definitely-invalid\n")
  let captured = Paths()
  do {
    let value = try await NativeSSHPreparedGateway.prepare(requested:alias,root:source,includeBase:root,home:root) { captured.add($0.path) }
    await value.close(); throw Failure(description:"invalid OpenSSH settings accepted")
  } catch NativeSSHConfigurationIssue.failed {}
  try expect(captured.all.count == 1,"invalid value reached admitted snapshot")
  for path in captured.all { try expect(!FileManager.default.fileExists(atPath:path),"failed resolution joins cleanup") }
}
func configurationSnapshots() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-config-test-" + UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  defer { try? FileManager.default.removeItem(at:root) }
  let source = root.appendingPathComponent("config"), included = root.appendingPathComponent("fragment.conf")
  func write(_ text: String, _ url: URL) throws {
    try Data(text.utf8).write(to:url); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
  }
  try write("User fixture\nMatch host unrelated.invalid\n Port 2299\n",included)
  let contents = "Host gateway-alias\n HostName gateway.invalid\n Include \"" + included.path + "\"\n Port 2201\nHost *\n User fallback\n"
  try write(contents,source)
  let snapshot = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root)
  let directory = snapshot.configurationURL.deletingLastPathComponent()
  do {
    let before = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G","-F",source.path,"--","gateway-alias"],timeout:.seconds(5))
    try write("Host *\n HostName changed.invalid\n User changed\n Port 2229\n",source)
    try write("User changed\n",included)
    let after = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G","-F",snapshot.configurationURL.path,"--","gateway-alias"],timeout:.seconds(5))
    try expect(before.gateway == after.gateway && after.gateway == NativeSSHGateway("ssh://fixture@gateway.invalid:2201"),"Include Match scope and immutable source capture")
  } catch { await snapshot.close(); throw error }
  await snapshot.close(); await snapshot.close()
  try expect(!FileManager.default.fileExists(atPath:directory.path),"snapshot cleanup joined")
  for invalid in ["Match exec \"touch marker\"\n HostName gateway.invalid\n", "ProxyCommand touch marker\n", "KnownHostsCommand touch marker\n", "LocalForward 2222 other:22\n", "Include ${HOME}/config\n"] {
    try write(invalid,source)
    do {
      let value = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root); await value.close()
      throw Failure(description:"unsafe configuration admitted")
    } catch NativeSSHConfigurationSnapshotIssue.unsupported {}
  }
  try write("Include \"" + source.path + "\"\n",source)
  do {
    let value = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root); await value.close()
    throw Failure(description:"include cycle admitted")
  } catch NativeSSHConfigurationSnapshotIssue.invalid {}
  try write(contents,source); try write("User fixture\n",included)
  do {
    let value = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root) { _ in
      try Data("User changed-after-read\n".utf8).write(to:included)
    }; await value.close(); throw Failure(description:"changed source admitted")
  } catch NativeSSHConfigurationSnapshotIssue.changed {}
  // Compare expansion order, quoted paths and hidden-file behavior with OpenSSH.
  let fragments = root.appendingPathComponent("ordered fragments")
  try FileManager.default.createDirectory(at:fragments,withIntermediateDirectories:false)
  try write("User first\n",fragments.appendingPathComponent("10.conf"))
  try write("User second\n",fragments.appendingPathComponent("20.conf"))
  try write("User hidden\n",fragments.appendingPathComponent(".00.conf"))
  try write("Host *\n HostName gateway.invalid\n Include \"" + fragments.path + "/*.conf\"\n Include \"" + root.path + "/missing/*.conf\"\n Port 2201\n",source)
  let ordered = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root)
  do {
    let original = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G","-F",source.path,"--","gateway-alias"],timeout:.seconds(5))
    let copied = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G","-F",ordered.configurationURL.path,"--","gateway-alias"],timeout:.seconds(5))
    try expect(original.gateway == copied.gateway && copied.gateway == NativeSSHGateway("ssh://first@gateway.invalid:2201"),"glob ordering, quoting and hidden files match OpenSSH")
  } catch { await ordered.close(); throw error }
  await ordered.close()
  let hashFragment = root.appendingPathComponent("hash#fragment")
  try write("User hashuser\n",hashFragment)
  for pattern in [hashFragment.path, "\"" + hashFragment.path + "\"", "'" + hashFragment.path + "'", hashFragment.path + " # comment"] {
    try write("Host *\n HostName gateway.invalid\n Include " + pattern + "\n User fallback\n Port 2201\n",source)
    let copy = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root)
    do {
      let original = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G","-F",source.path,"--","gateway-alias"],timeout:.seconds(5))
      let copied = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G","-F",copy.configurationURL.path,"--","gateway-alias"],timeout:.seconds(5))
      try expect(original.gateway == copied.gateway && copied.gateway == NativeSSHGateway("ssh://hashuser@gateway.invalid:2201"),"literal hash and quote/comment semantics match OpenSSH")
    } catch { await copy.close(); throw error }
    await copy.close()
  }
  func rejected(_ expected: NativeSSHConfigurationSnapshotIssue) async throws {
    do {
      let value = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root)
      await value.close(); throw Failure(description:"unsafe source accepted")
    } catch let error as NativeSSHConfigurationSnapshotIssue {
      try expect(error == expected,"expected snapshot rejection: \(expected), got \(error)")
    }
  }
  try write("\u{00a0}Host *\n",source)
  try await rejected(.unsupported)
  let loop = root.appendingPathComponent("loop")
  try FileManager.default.createSymbolicLink(atPath:loop.path,withDestinationPath:loop.path)
  for suffix in ["/config", "/*.conf"] {
    try write("Include \"" + loop.path + suffix + "\"\n",source)
    try await rejected(.unsafeFile)
  }
  let link = root.appendingPathComponent("link.conf")
  try FileManager.default.createSymbolicLink(at:link,withDestinationURL:included)
  try write("Include \"" + link.path + "\"\n",source)
  try await rejected(.unsafeFile)
  let fifo = root.appendingPathComponent("fifo.conf")
  try expect(mkfifo(fifo.path,0o600) == 0,"FIFO fixture")
  try write("Include \"" + fifo.path + "\"\n",source)
  try await rejected(.unsafeFile)
  // A second path to the same inode must be revalidated as well.
  let aliasDirectory = root.appendingPathComponent("aliases")
  try FileManager.default.createDirectory(at:aliasDirectory,withIntermediateDirectories:false)
  let alias = aliasDirectory.appendingPathComponent("fragment.conf")
  try FileManager.default.linkItem(at:included,to:alias)
  try write("Include \"" + included.path + "\" \"" + alias.path + "\"\n",source)
  do {
    let value = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root) { _ in
      try FileManager.default.moveItem(at:aliasDirectory,to:root.appendingPathComponent("moved-aliases"))
    }
    await value.close(); throw Failure(description:"changed secondary source path admitted")
  } catch NativeSSHConfigurationSnapshotIssue.changed {}
  try write("Include escaped\\*.conf\n",source)
  try await rejected(.unsupported)
  try write(String(repeating:"#",count:65537),source)
  try await rejected(.limit)
  try write("Host " + String(repeating:"a",count:8192),source)
  try await rejected(.invalid)
  for index in 0...9 {
    let next = root.appendingPathComponent("depth-\(index).conf")
    try write(index == 9 ? "User fixture\n" : "Include \"" + root.appendingPathComponent("depth-\(index+1).conf").path + "\"\n",next)
  }
  try write("Include \"" + root.appendingPathComponent("depth-0.conf").path + "\"\n",source)
  try await rejected(.limit)
  try write("Include \"" + included.path + "\"\n" + String(repeating:"Include \"" + included.path + "\"\n",count:128),source)
  try await rejected(.limit)
  // Exact file-size admission, aggregate-byte and unique-file limits.
  try write(String(repeating:"#",count:65536),source)
  let exact = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root)
  await exact.close()
  let aggregate = root.appendingPathComponent("aggregate")
  try FileManager.default.createDirectory(at:aggregate,withIntermediateDirectories:false)
  for index in 0..<4 { try write(String(repeating:"#",count:65536),aggregate.appendingPathComponent("\(index).conf")) }
  try write("Include \"" + aggregate.path + "/*.conf\"\n",source)
  try await rejected(.limit)
  let countDirectory = root.appendingPathComponent("count")
  try FileManager.default.createDirectory(at:countDirectory,withIntermediateDirectories:false)
  for index in 0..<32 { try write("User fixture\n",countDirectory.appendingPathComponent("\(index).conf")) }
  try write("Include \"" + countDirectory.path + "/*.conf\"\n",source)
  try await rejected(.limit)
  try write(contents,source)
  let aclChild = try NativeTunnelProcess.launch(executable:"/bin/chmod",arguments:["+a","everyone allow read",source.path],environment:[:],onExit:{})
  let aclExit = await aclChild.wait()
  try expect(aclExit == .exited(0),"ACL fixture prepared")
  try await rejected(.unsafeFile)
  let clearACL = try NativeTunnelProcess.launch(executable:"/bin/chmod",arguments:["-N",source.path],environment:[:],onExit:{})
  let clearExit = await clearACL.wait()
  try expect(clearExit == .exited(0),"ACL fixture reset")
  let failedPreparation = Paths()
  do {
    let value = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root) { directory in
      failedPreparation.add(directory.path)
      throw NativeSSHConfigurationSnapshotIssue.changed
    }
    await value.close(); throw Failure(description:"construction failure was ignored")
  } catch NativeSSHConfigurationSnapshotIssue.changed {}
  for path in failedPreparation.all { try expect(!FileManager.default.fileExists(atPath:path),"construction failure joins cleanup") }
  let displaced = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root)
  let oldPath = displaced.configurationURL.deletingLastPathComponent(), moved = root.appendingPathComponent("moved-private")
  try FileManager.default.moveItem(at:oldPath,to:moved)
  try FileManager.default.createDirectory(at:oldPath,withIntermediateDirectories:false)
  await displaced.close()
  try expect(FileManager.default.fileExists(atPath:oldPath.path),"cleanup preserves a replacement directory")
  try expect(FileManager.default.contentsOfDirectory(atPath:moved.path).isEmpty,"cleanup uses the original directory descriptor")
  try FileManager.default.removeItem(at:oldPath)
  // Cancel after all private files exist, then verify cleanup before return.
  try write(contents,source)
  let prepared = Paths()
  let capture = Task {
    try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root) { directory in
      prepared.add(directory.path)
      let deadline = ContinuousClock.now.advanced(by:.seconds(5))
      while !Task.isCancelled && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval:0.001) }
      try Task.checkCancellation()
    }
  }
  let deadline = ContinuousClock.now.advanced(by:.seconds(5))
  while prepared.all.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(1)) }
  capture.cancel()
  do {
    let value = try await capture.value; await value.close(); throw Failure(description:"cancelled snapshot returned")
  } catch is CancellationError {}
  try expect(prepared.all.count == 1,"snapshot reached cancellation checkpoint")
  for path in prepared.all { try expect(!FileManager.default.fileExists(atPath:path),"cancel joins private snapshot cleanup") }
  try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:source.path)
  do {
    let value = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:root,home:root); await value.close()
    throw Failure(description:"writable-by-others config admitted")
  } catch NativeSSHConfigurationSnapshotIssue.unsafeFile {}
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
  // Exercise configuration-to-RFB through the actual prepared-owner initializer.
  for aliasKey in [false,true] {
    let configuredPeer = try Peer()
    let configuredEndpoint = "127.0.0.1::\(configuredPeer.port)"
    let configURL = URL(fileURLWithPath:knownHosts + ".client-config")
    let knownURL = URL(fileURLWithPath:knownHosts + ".configured-known")
    let knownText = try String(contentsOfFile:knownHosts,encoding:.utf8)
    let keyText = aliasKey ? "fixture-key " + knownText.split(separator:" ",maxSplits:1).last! : knownText
    try Data(keyText.utf8).write(to:knownURL)
    let configText = "Host fixture-alias\n HostName " + request.gatewayHost + "\n User " + request.gatewayUser! +
      "\n Port \(request.gatewayPort)\n IdentityFile \"" + key + "\"\n IdentitiesOnly yes\n IdentityAgent none\n UserKnownHostsFile \"" + knownURL.path +
      "\"\n GlobalKnownHostsFile /dev/null\n" + (aliasKey ? " HostKeyAlias fixture-key\n" : "")
    try Data(configText.utf8).write(to:configURL)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
    let prepared = try await NativeSSHPreparedGateway.prepare(requested:NativeSSHGateway("fixture-alias"),root:configURL,includeBase:configURL.deletingLastPathComponent(),home:configURL.deletingLastPathComponent())
    let preparedPath = prepared.configurationURL.deletingLastPathComponent().path
    try Data("ProxyCommand rejected-live-change\n".utf8).write(to:configURL)
    let configured = try NativeSSHTunnel(prepared:prepared,endpoint:configuredEndpoint)
    let owner = try NativeRuntime(), connection = try owner.makeSession(configuration:configuration)
    do {
      let result = try await configured.start()
      try expect(result.routeIdentity == prepared.resolved.routeIdentity && result.routeIdentity != request.routeIdentity,"configured master publishes effective route")
      let connected = try await connection.connect(endpoint:result.endpoint,through:result.localEndpoint,routeIdentity:result.routeIdentity)
      try expect(connected.snapshot.state == .connected,"configured alias/key lookup reaches RFB")
      try await connection.close(); await configured.close(); try await owner.shutdown()
    } catch { try? await connection.close(); await configured.close(); try? await owner.shutdown(); throw error }
    try expect(!FileManager.default.fileExists(atPath:preparedPath),"configured close joins snapshot cleanup")
    try Data(configText.utf8).write(to:configURL)
    let cancelledPreparation = try await NativeSSHPreparedGateway.prepare(requested:NativeSSHGateway("fixture-alias"),root:configURL,includeBase:configURL.deletingLastPathComponent(),home:configURL.deletingLastPathComponent())
    let cancelledPath = cancelledPreparation.configurationURL.deletingLastPathComponent().path
    let cancelled = try NativeSSHTunnel(prepared:cancelledPreparation,endpoint:configuredEndpoint)
    let starting = Task { try await cancelled.start() }
    try await Task.sleep(for:.milliseconds(1))
    await cancelled.close()
    do { _ = try await starting.value }
    catch is CancellationError {}
    catch let error as NativeTunnelError { try expect(error == .closed || error == .startupFailed,"close revokes prepared startup") }
    try expect(!FileManager.default.fileExists(atPath:cancelledPath),"prepared startup close joins preflight and snapshot cleanup")
    do { _ = try await cancelled.start(); throw Failure(description:"closed prepared owner restarted") }
    catch NativeTunnelError.closed {}
    let droppedPreparation = try await NativeSSHPreparedGateway.prepare(requested:NativeSSHGateway("fixture-alias"),root:configURL,includeBase:configURL.deletingLastPathComponent(),home:configURL.deletingLastPathComponent())
    let droppedPath = droppedPreparation.configurationURL.deletingLastPathComponent().path
    var dropped: NativeSSHTunnel? = try NativeSSHTunnel(prepared:droppedPreparation,endpoint:configuredEndpoint)
    let droppedRoute = try await dropped!.start(); dropped = nil
    for _ in 0..<1000 where FileManager.default.fileExists(atPath:droppedPath) { try await Task.sleep(for:.milliseconds(5)) }
    try expect(!FileManager.default.fileExists(atPath:droppedPath) && !FileManager.default.fileExists(atPath:URL(fileURLWithPath:droppedRoute.localEndpoint).deletingLastPathComponent().path),"dropped prepared owner drains both private directories")

  }
  print("PASS isolated OpenSSH host-key rejection, public-key authentication, routed RFB and joined cleanup")
}
func snapshotRestrictiveUmask() async throws {
  let source = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-config-umask-" + UUID().uuidString)
  try Data("Host *\n User fixture\n".utf8).write(to:source)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:source.path)
  defer { try? FileManager.default.removeItem(at:source) }
  let previous = umask(0o777)
  defer { umask(previous) }
  let snapshot = try await NativeSSHConfigurationSnapshot.capture(root:source,includeBase:source.deletingLastPathComponent(),home:source.deletingLastPathComponent())
  var file = stat(), directory = stat()
  let valid = lstat(snapshot.configurationURL.path,&file) == 0 && file.st_mode & 0o777 == 0o600 &&
    lstat(snapshot.configurationURL.deletingLastPathComponent().path,&directory) == 0 && directory.st_mode & 0o777 == 0o700
  await snapshot.close()
  try expect(valid,"snapshot permissions are independent of restrictive umask")
}
@main struct Main {
  static func main() async {
    do {
      if CommandLine.arguments == [CommandLine.arguments[0],"--snapshot-umask"] { try await snapshotRestrictiveUmask(); return }
      if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--ssh" {
        try await realSSH(gateway:CommandLine.arguments[2],key:CommandLine.arguments[3],knownHosts:CommandLine.arguments[4]); return
      }
      guard CommandLine.arguments.count == 2 else { throw Failure(description:"fixture path missing") }
      try await requestChecks()
      try await boundedOutput(executable:CommandLine.arguments[1])
      try await configurationProbe(executable:CommandLine.arguments[1])
      try await configurationSnapshots()
      try await preparedGateways()
      try await defaultGatewayConfiguration()
      let umaskChild = try NativeTunnelProcess.launch(executable:CommandLine.arguments[0],arguments:["--snapshot-umask"],environment:[:],onExit:{})
      let umaskResult = await umaskChild.wait()
      try expect(umaskResult == .exited(0),"isolated restrictive-umask snapshot")
      try await failuresAndCancellation(executable:CommandLine.arguments[1])
      try await forwardingAndOwnership(executable:CommandLine.arguments[1])
      print("PASS SSH argv/identity, child startup/cancellation/drain and routed RFB forwarding")
    } catch { fputs("Tunnel test failed: \(error)\n",stderr); exit(1) }
  }
}
