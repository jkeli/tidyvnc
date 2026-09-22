// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CryptoKit
import Foundation

enum NativeSSHConfigurationIssue: Error, Sendable, Equatable, CustomStringConvertible {
  case failed, timedOut, invalidOutput, changedPolicy
  var description: String { "SSH configuration could not be resolved." }
}

// Only copied routing values survive the probe. Arbitrary configuration output
// (which can include paths or command text) is never returned, logged or persisted.
struct NativeSSHResolvedGateway: Sendable, Equatable {
  let gateway: NativeSSHGateway
  let hostKeyAlias: String?
  let hostKeyLookupName: String
  let routeIdentity: String
  private let policyDigest: Data
  init(output: Data) throws {
    guard output.count <= 262144, !output.contains(0), !output.contains(13),
          let text = String(data:output,encoding:.utf8) else { throw NativeSSHConfigurationIssue.invalidOutput }
    var fields: [String:String] = [:], policy = Data()
    // These values are authoritative native launch controls or separately
    // validated routing fields. Every remaining emitted option must replay.
    let controlled: Set<String> = ["hostname","user","port","hostkeyalias","canonicalizehostname",
      "loglevel","logverbose","batchmode","stricthostkeychecking","fingerprinthash","updatehostkeys","exitonforwardfailure",
      "streamlocalbindmask","streamlocalbindunlink","controlpath","controlmaster","controlpersist",
      "forkafterauthentication","connectionattempts","connecttimeout","addressfamily","forwardagent",
      "forwardx11","permitlocalcommand","sessiontype","stdinnull","requesttty","knownhostscommand"]
    for line in text.split(separator:"\n") {
      let pieces = line.split(separator:" ",maxSplits:1,omittingEmptySubsequences:false)
      guard pieces.count == 2, !pieces[0].isEmpty,
            pieces[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) else {
        throw NativeSSHConfigurationIssue.invalidOutput
      }
      let name = pieces[0].lowercased()
      if !controlled.contains(name) { policy.append(contentsOf:(name + " " + pieces[1] + "\n").utf8) }
      if ["hostname","user","port","hostkeyalias"].contains(name) {
        guard fields.updateValue(String(pieces[1]),forKey:name) == nil else { throw NativeSSHConfigurationIssue.invalidOutput }
      }
    }
    guard let host = fields["hostname"], let user = fields["user"], let port = fields["port"],
          let number = NativeListenPort.parse(port), number > 0 else { throw NativeSSHConfigurationIssue.invalidOutput }
    let literal = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
    do { gateway = try NativeSSHGateway("ssh://" + user + "@" + literal + ":" + String(number)) }
    catch { throw NativeSSHConfigurationIssue.invalidOutput }
    if let alias = fields["hostkeyalias"] {
      let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]%@".utf8)
      guard !alias.isEmpty, alias.utf8.count <= 1024, alias.utf8.allSatisfy({ allowed.contains($0) }) else {
        throw NativeSSHConfigurationIssue.invalidOutput
      }
      hostKeyAlias = alias
    } else { hostKeyAlias = nil }
    // OpenSSH uses an explicit alias verbatim, including at a nondefault port.
    hostKeyLookupName = hostKeyAlias ?? (gateway.port == 22 ? gateway.host : "[\(gateway.host)]:\(gateway.port)")
    var hash = SHA256()
    for field in ["tidyvnc-ssh-resolved-v2",gateway.host,gateway.user!,String(gateway.port),
                  hostKeyAlias == nil ? "default-host-key" : "explicit-host-key",hostKeyLookupName] {
      var length = UInt32(field.utf8.count).bigEndian
      withUnsafeBytes(of:&length) { hash.update(data:Data($0)) }; hash.update(data:Data(field.utf8))
    }
    policyDigest = Data(SHA256.hash(data:policy))
    routeIdentity = "ssh-v2:" + hash.finalize().map { String(format:"%02x",$0) }.joined()
  }
}

// One owner retains the exact admitted files and typed result for an attempt.
// The connection must drain every SSH consumer before closing this preparation.
// The app adapter binds its effective identity before launching the pinned master.
final class NativeSSHPreparedGateway: Sendable {
  let requested: NativeSSHGateway, resolved: NativeSSHResolvedGateway
  let environment: [String:String]
  let network: NativeNetworkPolicy
  private let snapshot: NativeSSHConfigurationSnapshot
  var configurationURL: URL { snapshot.configurationURL }
  private init(requested: NativeSSHGateway, resolved: NativeSSHResolvedGateway, snapshot: NativeSSHConfigurationSnapshot, environment: [String:String], network: NativeNetworkPolicy) {
    self.requested = requested; self.resolved = resolved; self.snapshot = snapshot; self.environment = environment; self.network = network
  }
  static func prepare(requested: NativeSSHGateway, root: URL, includeBase: URL, home: URL,
                      network: NativeNetworkPolicy = .builtIn, allowMissingRoot: Bool = false,
                      checkpoint: @escaping @Sendable (URL) throws -> Void = { _ in }) async throws -> NativeSSHPreparedGateway {
    guard network.ipv4 || network.ipv6 else { throw NativeTunnelError.invalidRequest }
    let snapshot = try await NativeSSHConfigurationSnapshot.capture(root:root,includeBase:includeBase,home:home,allowMissingRoot:allowMissingRoot,checkpoint:checkpoint)
    do {
      var environment = ["PATH":"/usr/bin:/bin","LC_ALL":"C"]
      if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], socket.hasPrefix("/"), socket.utf8.count <= 4096, !socket.utf8.contains(0) {
        environment["SSH_AUTH_SOCK"] = socket
      }
      let resolved = try await NativeSSHConfigurationProbe.resolve(requested,snapshot:snapshot,environment:environment,network:network)
      try Task.checkCancellation()
      return NativeSSHPreparedGateway(requested:requested,resolved:resolved,snapshot:snapshot,environment:environment,network:network)
    } catch { await snapshot.close(); throw error }
  }
  static func prepareDefault(requested: NativeSSHGateway, home: URL, network: NativeNetworkPolicy = .builtIn) async throws -> NativeSSHPreparedGateway {
    let base = home.appendingPathComponent(".ssh",isDirectory:true)
    return try await prepare(requested:requested,root:base.appendingPathComponent("config"),includeBase:base,home:home,
      network:network,allowMissingRoot:true)
  }
  func arguments(_ request: NativeSSHTunnelRequest, command: NativeSSHCommand, socket: String, interactive: Bool) -> [String] {
    var arguments = request.arguments(command,socket:socket,interactive:interactive)
    // request is constructed from the effective account/port; retain the original
    // alias as argv's destination so Host/originalhost selection stays meaningful.
    arguments[1] = configurationURL.path
    arguments[arguments.count-1] = requested.host
    var fixed = ["-o","HostName=" + resolved.gateway.host.replacingOccurrences(of:"%",with:"%%"),"-o","CanonicalizeHostname=no"]
    if let alias = resolved.hostKeyAlias { fixed += ["-o","HostKeyAlias=" + alias] }
    return fixed + arguments
  }
  func verify(masterArguments: [String]) async throws {
    let replay = try await NativeSSHConfigurationProbe.run(executable:"/usr/bin/ssh",arguments:["-G"] + masterArguments,
      timeout:.seconds(5),environment:environment)
    guard replay == resolved else { throw NativeSSHConfigurationIssue.changedPolicy }
  }
  func close() async { await snapshot.close() }
}

enum NativeSSHConfigurationProbe {
  // Establish the owned probe boundary before admitting configuration files.
  // App routing is not switched to this resolver until snapshots and resolved
  // credential/host-key identities can be installed atomically for an attempt.
  static func baseline(_ gateway: NativeSSHGateway) async throws -> NativeSSHResolvedGateway {
    var arguments = ["-G","-F","/dev/null","-p",String(gateway.port)]
    if let user = gateway.user { arguments += ["-l",user] }
    return try await run(executable:"/usr/bin/ssh",arguments:arguments + ["--",gateway.host],timeout:.seconds(5))
  }
  static func resolve(_ requested: NativeSSHGateway, snapshot: NativeSSHConfigurationSnapshot, environment: [String:String] = ["PATH":"/usr/bin:/bin","LC_ALL":"C"], network: NativeNetworkPolicy = .builtIn) async throws -> NativeSSHResolvedGateway {
    guard network.ipv4 || network.ipv6 else { throw NativeTunnelError.invalidRequest }
    let family = network.ipv4 && network.ipv6 ? "any" : network.ipv4 ? "inet" : "inet6"
    var arguments = ["-G","-F",snapshot.configurationURL.path,"-o","AddressFamily=" + family]
    if requested.portIsExplicit { arguments += ["-p",String(requested.port)] }
    if let user = requested.user { arguments += ["-l",user] }
    return try await run(executable:"/usr/bin/ssh",arguments:arguments + ["--",requested.host],timeout:.seconds(5),environment:environment)
  }
  static func run(executable: String, arguments: [String], timeout: Duration, environment: [String:String] = ["PATH":"/usr/bin:/bin","LC_ALL":"C"]) async throws -> NativeSSHResolvedGateway {
    try Task.checkCancellation()
    let output: NativeTunnelOutput, child: NativeTunnelProcess
    do {
      output = try NativeTunnelOutput()
      child = try NativeTunnelProcess.launch(executable:executable,arguments:arguments,
        environment:environment,output:output,onExit:{})
    } catch { throw NativeSSHConfigurationIssue.failed }
    do {
      return try await withTaskCancellationHandler {
        let deadline = ContinuousClock.now.advanced(by:timeout)
        while child.exit == nil {
          try Task.checkCancellation()
          guard ContinuousClock.now < deadline else { throw NativeSSHConfigurationIssue.timedOut }
          try await Task.sleep(for:.milliseconds(10))
        }
        let exit = await child.wait()
        var data: Data
        do { data = try await output.take() } catch { throw NativeSSHConfigurationIssue.invalidOutput }
        defer { data.resetBytes(in:0..<data.count) }
        try Task.checkCancellation()
        guard exit == .exited(0) else { throw NativeSSHConfigurationIssue.failed }
        return try NativeSSHResolvedGateway(output:data)
      } onCancel: { child.cancel() }
    } catch {
      child.cancel(); _ = await child.wait(); _ = try? await output.take()
      throw error
    }
  }
}


// Public app adapter owns preparation before SSH/RFB admission. The request and
// home are captured at construction; each reconnect gets a fresh owner.
public actor NativeConfiguredSSHTunnel: NativeTunnelOwning {
  private let request: NativeSSHTunnelRequest, home: URL
  private let authentication: NativeSSHAuthentication?
  private var work: Task<NativeSSHPreparedGateway,any Error>?
  private var owner: NativeSSHTunnel?
  private var identity: String?
  private var closed = false
  public init(request: NativeSSHTunnelRequest, home: URL = FileManager.default.homeDirectoryForCurrentUser,
              authentication: NativeSSHAuthentication? = nil) {
    self.request = request; self.home = home; self.authentication = authentication
  }
  public func prepare() async throws -> String? {
    guard !closed else { throw NativeTunnelError.closed }
    if let identity { return identity }
    guard work == nil else { throw NativeTunnelError.busy }
    let request = request, home = home
    let task = Task { try await NativeSSHPreparedGateway.prepareDefault(requested:request.gateway,home:home,network:request.network) }
    work = task
    do {
      let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      do {
        try Task.checkCancellation(); guard !closed else { throw NativeTunnelError.closed }
        owner = try NativeSSHTunnel(prepared:prepared,endpoint:request.endpoint,authentication:authentication)
        identity = prepared.resolved.routeIdentity; work = nil
        return identity
      } catch { await prepared.close(); throw error }
    } catch {
      work = nil
      if error is CancellationError { throw CancellationError() }
      if let error = error as? NativeTunnelError { throw error }
      if let error = error as? NativeSSHConfigurationSnapshotIssue, error == .unsupported {
        throw NativeTunnelError.unsupportedConfiguration
      }
      throw NativeTunnelError.configurationUnavailable
    }
  }
  public func start() async throws -> NativeTunnelRoute {
    _ = try await prepare()
    guard !closed, let owner else { throw NativeTunnelError.closed }
    do { return try await owner.start() }
    catch let error as NativeSSHConfigurationIssue {
      if error == .timedOut { throw NativeTunnelError.timedOut }
      throw NativeTunnelError.configurationUnavailable
    }
  }
  public func waitForExit() async -> NativeTunnelExit? { await owner?.waitForExit() }
  public func close() async {
    closed = true
    let task = work; task?.cancel()
    let result = await task?.result
    await owner?.close()
    if case .success(let prepared) = result { await prepared.close() }
    work = nil
  }
  deinit {
    let task = work, owner = owner; task?.cancel()
    Task {
      let result = await task?.result
      await owner?.close()
      if case .success(let prepared) = result { await prepared.close() }
    }
  }
}
