// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CryptoKit
import Darwin
import Foundation
import TidyVNC

public enum NativeTunnelError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidRequest, unsupportedTarget, privateSocketUnavailable, launchFailed, startupFailed, timedOut, closed, busy, configurationUnavailable, unsupportedConfiguration, hostKeySaveFailed
  public var description: String {
    switch self {
    case .hostKeySaveFailed: String(localized:"tunnel.error.ssh.could.not.save.the.gateway.key.check.known.hosts.file.access", defaultValue:"SSH could not save the gateway key. Check known-hosts file access and try again. The VNC connection was not started.")
    case .configurationUnavailable: String(localized:"tunnel.error.ssh.configuration.could.not.be.prepared.check.file.access.and.host.match", defaultValue:"SSH configuration could not be prepared. Check file access and Host/Match settings.")
    case .unsupportedConfiguration: String(localized:"tunnel.error.ssh.configuration.contains.unsupported.settings.command.execution.proxy.hops.and.network.dependent", defaultValue:"SSH configuration contains unsupported settings. Command execution, proxy hops and network-dependent Match rules are not supported.")
    case .invalidRequest: String(localized:"tunnel.error.the.ssh.gateway.or.forwarding.request.is.invalid", defaultValue:"The SSH gateway or forwarding request is invalid.")
    case .unsupportedTarget: String(localized:"tunnel.error.ssh.forwarding.requires.a.tcp.server.address", defaultValue:"SSH forwarding requires a TCP server address.")
    case .privateSocketUnavailable: String(localized:"tunnel.error.a.private.tunnel.socket.could.not.be.prepared", defaultValue:"A private tunnel socket could not be prepared.")
    case .launchFailed: String(localized:"tunnel.error.the.ssh.process.could.not.be.started", defaultValue:"The SSH process could not be started.")
    case .startupFailed: String(localized:"tunnel.error.ssh.did.not.establish.the.tunnel.check.the.gateway.host.key.verification", defaultValue:"SSH did not establish the tunnel. Check the gateway, host-key verification and SSH authentication.")
    case .timedOut: String(localized:"tunnel.error.ssh.tunnel.startup.timed.out", defaultValue:"SSH tunnel startup timed out.")
    case .closed: String(localized:"tunnel.error.the.ssh.tunnel.is.closed", defaultValue:"The SSH tunnel is closed.")
    case .busy: String(localized:"tunnel.error.ssh.tunnel.startup.is.already.in.progress", defaultValue:"SSH tunnel startup is already in progress.")
    }
  }
}

extension tidyvnc_ssh_gateway_info: ABIValue {}
private struct TunnelEndpoint: Sendable {
  let host: String, scope: String
  let port: UInt32
  init(_ endpoint: String) throws {
    var raw: UInt64 = 0
    do {
      _ = try withText(endpoint) { bytes in try checked { tidyvnc_endpoint_create(bytes,.init(data:nil,length:0),0,&raw,$0) } }
      let owner = NativeHandle(adopting:raw)
      var value = abi(tidyvnc_endpoint_info.self)
      try checked { tidyvnc_endpoint_get(owner.raw,&value,$0) }
      host = String(decoding:try copyBytes(value.host),as:UTF8.self)
      scope = String(decoding:try copyBytes(value.scope),as:UTF8.self); port = value.port
    } catch { throw NativeTunnelError.unsupportedTarget }
    // These values enter OpenSSH's colon-delimited forwarding grammar, not a
    // shell. Exclude every delimiter not needed for DNS, numeric IP or scope.
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:".utf8)
    let scopeAllowed = allowed.subtracting([58])
    guard !host.isEmpty, host.utf8.allSatisfy({ allowed.contains($0) }),
          scope.utf8.allSatisfy({ scopeAllowed.contains($0) }), port > 0 else { throw NativeTunnelError.unsupportedTarget }
  }
  var forwardingHost: String {
    let name = host + (scope.isEmpty ? "" : "%" + scope)
    return host.contains(":") ? "[\(name)]" : name
  }
}

enum NativeSSHCommand: String, Sendable { case master, check, forward }
// Validated independently of the remote target so invocation preflight can run
// before reading a connection file. Persistence encodes a canonical SSH URI and
// decodes through the same parser; a route digest is never a gateway address.
// Port intent affects saved destination equality and launch-secret scope. The
// legacy route digest remains for explicit unconfigured service callers.
public struct NativeSSHGateway: Sendable, Hashable, Codable {
  public let host: String, user: String?, port: UInt32, routeIdentity: String
  public let canonicalURI: String
  public var intentIdentity: String { "ssh-request-v2:" + SHA256.hash(data:Data(("tidyvnc-ssh-intent-v2\0" + canonicalURI).utf8)).map { String(format:"%02x",$0) }.joined() }
  public let portIsExplicit: Bool
  public init(_ gateway: String) throws {
    // Grammar, limits and canonical URI are the portable core's (SSHGateway).
    var raw: UInt64 = 0
    var value = abi(tidyvnc_ssh_gateway_info.self)
    let owner: NativeHandle, host: String, scope: String, user: String?
    do {
      _ = try withText(gateway) { bytes in try checked { tidyvnc_ssh_gateway_create(bytes,&raw,$0) } }
      owner = NativeHandle(adopting:raw)
      try checked { tidyvnc_ssh_gateway_get(owner.raw,&value,$0) }
      host = String(decoding:try copyBytes(value.host),as:UTF8.self)
      scope = String(decoding:try copyBytes(value.scope),as:UTF8.self)
      user = value.flags & UInt32(TIDYVNC_SSH_GATEWAY_USER) != 0 ? String(decoding:try copyBytes(value.user),as:UTF8.self) : nil
      canonicalURI = String(decoding:try copyBytes(value.canonical_uri),as:UTF8.self)
    } catch { throw NativeTunnelError.invalidRequest }
    withExtendedLifetime(owner) {}
    // SSH destination is passed as one final argument; scope bytes are exact.
    self.host = host + (scope.isEmpty ? "" : "%" + scope)
    port = value.port; self.user = user
    portIsExplicit = value.flags & UInt32(TIDYVNC_SSH_GATEWAY_EXPLICIT_PORT) != 0
    var hash = SHA256()
    for field in ["tidyvnc-ssh-v1",host,scope,String(port),user == nil ? "implicit-user" : "explicit-user",user ?? ""] {
      var length = UInt32(field.utf8.count).bigEndian
      withUnsafeBytes(of:&length) { hash.update(data:Data($0)) }; hash.update(data:Data(field.utf8))
    }
    routeIdentity = "ssh-v1:" + hash.finalize().map { String(format:"%02x",$0) }.joined()
  }
  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static let version = Key(stringValue:"version"), uri = Key(stringValue:"uri")
  }
  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    do {
      if let legacy = try? value.decode(String.self) {
        // Version-one strings always meant a concrete port, even when a
        // hand-authored historical record omitted :22. Never reinterpret them.
        let parsed = try Self(legacy)
        try self.init(parsed.canonicalURI + (parsed.portIsExplicit ? "" : ":22"))
      } else {
        let object = try decoder.container(keyedBy:Key.self)
        guard Set(object.allKeys.map(\.stringValue)) == ["version","uri"],
              try object.decode(Int.self,forKey:.version) == 2 else { throw NativeTunnelError.invalidRequest }
        try self.init(object.decode(String.self,forKey:.uri))
      }
    } catch { throw DecodingError.dataCorruptedError(in:value,debugDescription:"Invalid SSH gateway") }
  }
  public func encode(to encoder: any Encoder) throws {
    var object = encoder.container(keyedBy:Key.self)
    try object.encode(2,forKey:.version); try object.encode(canonicalURI,forKey:.uri)
  }
}

public struct NativeSSHTunnelRequest: Sendable {
  public let endpoint: String, gateway: NativeSSHGateway
  public var routeIdentity: String { gateway.routeIdentity }
  public var gatewayHost: String { gateway.host }
  public var gatewayUser: String? { gateway.user }
  public var gatewayPort: UInt32 { gateway.port }
  private let remote: TunnelEndpoint
  private let family: String
  let network: NativeNetworkPolicy
  public init(endpoint: String, gateway: String, network: NativeNetworkPolicy = .builtIn) throws {
    try self.init(endpoint:endpoint,gateway:NativeSSHGateway(gateway),network:network)
  }
  public init(endpoint: String, gateway: NativeSSHGateway, network: NativeNetworkPolicy = .builtIn) throws {
    guard !endpoint.isEmpty, network.ipv4 || network.ipv6 else { throw NativeTunnelError.invalidRequest }
    self.network = network
    remote = try TunnelEndpoint(endpoint); self.endpoint = endpoint; self.gateway = gateway
    family = network.ipv4 && network.ipv6 ? "any" : (network.ipv4 ? "inet" : "inet6")
  }
  // Authentication and new-key review use optional native prompts. Config
  // commands, other masters and detached children are excluded.
  // A private master acknowledges each forward before RFB admission.
  // UI/CLI support must disclose these capabilities.
  func arguments(_ command: NativeSSHCommand, socket: String, interactive: Bool = false) -> [String] {
    let control = URL(fileURLWithPath:socket).deletingLastPathComponent().appendingPathComponent("control").path
    var result = ["-F","/dev/null","-T","-n","-o",interactive ? "BatchMode=no" : "BatchMode=yes","-o",interactive ? "StrictHostKeyChecking=ask" : "StrictHostKeyChecking=yes",
      "-o","FingerprintHash=sha256",
      "-o","UpdateHostKeys=no","-o","LogLevel=INFO","-o","LogVerbose=none","-o","ExitOnForwardFailure=yes","-o","StreamLocalBindMask=0177",
      "-o","StreamLocalBindUnlink=no","-S",control,"-o","ControlPersist=no",
      "-o","ForkAfterAuthentication=no","-o","ConnectionAttempts=1","-o","ConnectTimeout=15",
      "-o","AddressFamily=\(family)","-o","ForwardAgent=no","-o","ForwardX11=no","-o","PermitLocalCommand=no",
      "-p",String(gatewayPort)]
    switch command {
    case .master: result += ["-M","-N"]
    case .check: result += ["-O","check"]
    case .forward: result += ["-O","forward","-L","\(socket):\(remote.forwardingHost):\(remote.port)"]
    }
    if let gatewayUser { result += ["-l",gatewayUser] }
    return result + ["--",gatewayHost]
  }
}

public struct NativeTunnelRoute: Sendable {
  public let endpoint: String, localEndpoint: String, routeIdentity: String
}
public protocol NativeTunnelOwning: Sendable {
  func prepare() async throws -> String?
  func start() async throws -> NativeTunnelRoute
  func waitForExit() async -> NativeTunnelExit?
  func close() async
}

public extension NativeTunnelOwning {
  // Existing explicit-route adapters need no asynchronous resolution.
  func prepare() async throws -> String? { nil }
}

// Exact private directory and leaf only; cleanup never recursively follows a
// path supplied by SSH. The fd pins the created directory through child exit.
private final class TunnelDirectory: @unchecked Sendable {
  let path: String
  private let lock = NSLock()
  private var fd: Int32
  var socket: String { path + "/forward" }
  init() throws {
    var template = Array("/tmp/tidyvnc-ssh-XXXXXX".utf8CString)
    guard let name = mkdtemp(&template) else { throw NativeTunnelError.privateSocketUnavailable }
    path = String(cString:name); fd = open(path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { rmdir(path); throw NativeTunnelError.privateSocketUnavailable }
    guard let acl = acl_init(0) else { close(fd); fd = -1; rmdir(path); throw NativeTunnelError.privateSocketUnavailable }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_fd_np(fd,acl,ACL_TYPE_EXTENDED) == 0, fchmod(fd,0o700) == 0 else {
      close(fd); fd = -1; rmdir(path); throw NativeTunnelError.privateSocketUnavailable
    }
  }
  func ready(_ name: String) -> Bool {
    lock.withLock {
      guard fd >= 0 else { return false }
      var info = stat()
      return fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFSOCK &&
        info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }
  }
  func remove() {
    lock.withLock {
      guard fd >= 0 else { return }
      unlinkat(fd,"forward",0); unlinkat(fd,"control",0)
      // OpenSSH may stage a control socket as control.<random> before linking
      // its final name. SIGKILL in that interval must not leave the directory.
      // Inspect only bounded direct leaves through the pinned fd; never recurse
      // or remove a regular file, symlink or directory supplied by another actor.
      let listing = dup(fd)
      if listing >= 0 {
        if let stream = fdopendir(listing) {
          defer { closedir(stream) }
          for _ in 0..<32 {
            guard let entry = readdir(stream) else { break }
            let name = withUnsafePointer(to:&entry.pointee.d_name) {
              $0.withMemoryRebound(to:CChar.self,capacity:Int(entry.pointee.d_namlen)+1) { String(cString:$0) }
            }
            var info = stat()
            if name.hasPrefix("control."), fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0,
               info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() { unlinkat(fd,name,0) }
          }
        } else { close(listing) }
      }
      close(fd); fd = -1; rmdir(path)
    }
  }
  deinit { remove() }
}

public actor NativeSSHTunnel: NativeTunnelOwning {
  private let request: NativeSSHTunnelRequest
  private let executable: String
  private let arguments: @Sendable (NativeSSHCommand,String) -> [String]
  private let environment: [String:String]
  private let timeout: Duration
  private let authentication: NativeSSHAuthentication?
  private let preparation: NativeSSHPreparedGateway?
  private var diagnostics: NativeTunnelOutput?
  private var diagnosticDrain: Task<Void,Never>?
  private var preflight: Task<Void,any Error>?
  private var askpass: NativeSSHAskpass?
  private var child: NativeTunnelProcess?
  private var controlChild: NativeTunnelProcess?
  private var directory: TunnelDirectory?
  private var starting = false, closed = false
  private var route: NativeTunnelRoute?
  public init(request: NativeSSHTunnelRequest, authentication: NativeSSHAuthentication? = nil) {
    preparation = nil
    self.request = request; self.authentication = authentication; executable = "/usr/bin/ssh"
    arguments = { request.arguments($0,socket:$1,interactive:authentication != nil) }
    timeout = .seconds(authentication == nil ? 20 : 300)
    var environment = ["PATH":"/usr/bin:/bin","LC_ALL":"C","SSH_ASKPASS_REQUIRE":"never"]
    if let raw = getenv("SSH_AUTH_SOCK"), strnlen(raw,4097) <= 4096, let socket = String(validatingCString:raw), socket.hasPrefix("/") {
      environment["SSH_AUTH_SOCK"] = socket
    }
    self.environment = environment
  }
  init(prepared: NativeSSHPreparedGateway, endpoint: String, network: NativeNetworkPolicy? = nil,
       authentication: NativeSSHAuthentication? = nil) throws {
    let network = network ?? prepared.network
    guard network == prepared.network else { throw NativeTunnelError.invalidRequest }
    let request = try NativeSSHTunnelRequest(endpoint:endpoint,gateway:prepared.resolved.gateway,network:network)
    self.request = request; self.preparation = prepared; self.authentication = authentication
    executable = "/usr/bin/ssh"; timeout = .seconds(authentication == nil ? 20 : 300)
    arguments = { prepared.arguments(request,command:$0,socket:$1,interactive:authentication != nil) }
    var environment = prepared.environment; environment["SSH_ASKPASS_REQUIRE"] = "never"
    self.environment = environment
  }
  // A private test executable exercises actual process ownership without SSH
  // credentials, network hosts, external config, or user stores.
  init(request: NativeSSHTunnelRequest, executable: String, timeout: Duration, authentication: NativeSSHAuthentication? = nil,
       arguments: @escaping @Sendable (NativeSSHCommand,String) -> [String]) {
    preparation = nil
    self.request = request; self.executable = executable; self.timeout = timeout; self.arguments = arguments
    self.authentication = authentication; environment = [:]
  }
  public func start() async throws -> NativeTunnelRoute {
    guard !closed else { throw NativeTunnelError.closed }
    guard !starting else { throw NativeTunnelError.busy }
    if let route, child?.exit == nil { return route }
    guard child == nil else { throw NativeTunnelError.closed }
    try Task.checkCancellation(); starting = true; defer { starting = false }
    let saveFailure = NativeSSHSaveFailure()
    do {
      let directory = try TunnelDirectory(); self.directory = directory
      var environment = environment
      var masterArguments = arguments(.master,directory.socket)
      if let preparation {
        let values = masterArguments
        let work = Task { try await preparation.verify(masterArguments:values) }; preflight = work
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        preflight = nil
        try Task.checkCancellation(); guard !closed else { throw NativeTunnelError.closed }
      }
      let askpass: NativeSSHAskpass?
      if let authentication {
        guard authentication.helper.isFileURL, authentication.helper.path.hasPrefix("/"),
              !authentication.helper.path.utf8.contains(0),
              FileManager.default.isExecutableFile(atPath:authentication.helper.path) else { throw NativeTunnelError.launchFailed }
        askpass = try NativeSSHAskpass(directory:directory.path,request:request,hostKeyLookupName:preparation?.resolved.hostKeyLookupName) { await authentication.interaction.ask($0) }
        environment["SSH_ASKPASS"] = authentication.helper.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["TIDYVNC_ASKPASS_SOCKET"] = directory.path + "/askpass"
        // KnownHostsCommand is parsed into argv by OpenSSH, not a shell. Only
        // this fixed program/argument template is supplied; the path is quoted
        // for that parser and the executable token is not percent-expanded.
        let helper = authentication.helper.path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        masterArguments = ["-o","KnownHostsCommand=\"\(helper)\" --host-key %I %H %t %K"] + masterArguments
      } else { askpass = nil }
      self.askpass = askpass
      let diagnostics = try NativeTunnelOutput(saveFailure:saveFailure); self.diagnostics = diagnostics
      let child = try NativeTunnelProcess.launch(executable:executable,arguments:masterArguments,environment:environment,output:diagnostics,standardError:true) {
        // A dropped tunnel still drains its prompt before removing the parent.
        askpass?.stop()
        Task { await askpass?.close(); directory.remove() }
      }
      self.child = child
      return try await withTaskCancellationHandler {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by:timeout)
        while clock.now < deadline {
          try Task.checkCancellation()
          guard !closed else { throw NativeTunnelError.closed }
          guard child.exit == nil else { throw NativeTunnelError.startupFailed }
          if directory.ready("control"), try await command(.check,directory:directory,deadline:deadline) == .exited(0) {
            do { try await diagnostics.drainAvailable() } catch { throw NativeTunnelError.startupFailed }
            if saveFailure.failed { throw NativeTunnelError.hostKeySaveFailed }
            guard try await command(.forward,directory:directory,deadline:deadline) == .exited(0),
                  child.exit == nil, directory.ready("forward") else { throw NativeTunnelError.startupFailed }
            try Task.checkCancellation()
            guard !closed else { throw NativeTunnelError.closed }
            let route = NativeTunnelRoute(endpoint:request.endpoint,localEndpoint:directory.socket,routeIdentity:preparation?.resolved.routeIdentity ?? request.routeIdentity)
            self.route = route; return route
          }
          try await Task.sleep(for:.milliseconds(20))
        }
        throw NativeTunnelError.timedOut
      } onCancel: { askpass?.stop(); child.cancel() }
    } catch {
      await close()
      // Authentication can end before the master acknowledges readiness. Drain
      // diagnostics first so that its earlier save failure is still reported.
      if !Task.isCancelled, (error as? NativeTunnelError) != .closed, saveFailure.failed {
        throw NativeTunnelError.hostKeySaveFailed
      }
      throw error
    }
  }
  private func command(_ command: NativeSSHCommand, directory: TunnelDirectory,
                       deadline: ContinuousClock.Instant) async throws -> NativeTunnelExit {
    try Task.checkCancellation()
    guard !closed else { throw NativeTunnelError.closed }
    let process = try NativeTunnelProcess.launch(executable:executable,arguments:arguments(command,directory.socket),environment:environment,onExit:{})
    controlChild = process
    while process.exit == nil {
      try Task.checkCancellation()
      guard !closed else { throw NativeTunnelError.closed }
      guard child?.exit == nil else { throw NativeTunnelError.startupFailed }
      guard ContinuousClock.now < deadline else { throw NativeTunnelError.timedOut }
      try await Task.sleep(for:.milliseconds(20))
    }
    let result = await process.wait(); controlChild = nil; return result
  }
  public func waitForExit() async -> NativeTunnelExit? { guard let child else { return nil }; return await child.wait() }
  public func close() async {
    closed = true; route = nil
    preflight?.cancel(); if let preflight { _ = await preflight.result }; preflight = nil
    askpass?.stop()
    child?.cancel(); controlChild?.cancel()
    if let controlChild { _ = await controlChild.wait() }
    if let child { _ = await child.wait() }
    await drainDiagnostics()
    await askpass?.close(); askpass = nil
    directory?.remove(); directory = nil
    await preparation?.close()
  }
  private func drainDiagnostics() async {
    if let diagnosticDrain { await diagnosticDrain.value; return }
    guard let diagnostics else { return }
    let task = Task { _ = try? await diagnostics.take() }
    diagnosticDrain = task
    await task.value; self.diagnostics = nil
  }
  deinit {
    preflight?.cancel(); askpass?.stop(); child?.cancel(); controlChild?.cancel()
    let preflight = preflight, preparation = preparation, directory = directory
    let child = child, controlChild = controlChild, askpass = askpass, diagnostics = diagnostics, diagnosticDrain = diagnosticDrain
    Task {
      _ = await preflight?.result
      if let controlChild { _ = await controlChild.wait() }
      if let child { _ = await child.wait() }
      if let diagnosticDrain { await diagnosticDrain.value }
      else { _ = try? await diagnostics?.take() }
      await askpass?.close(); directory?.remove(); await preparation?.close()
    }
  }
}
