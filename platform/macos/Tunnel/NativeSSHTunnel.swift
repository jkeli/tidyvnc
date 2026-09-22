// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CryptoKit
import Darwin
import Foundation
import TidyVNC

public enum NativeTunnelError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidRequest, unsupportedTarget, privateSocketUnavailable, launchFailed, startupFailed, timedOut, closed, busy
  public var description: String {
    switch self {
    case .invalidRequest: "The SSH gateway or forwarding request is invalid."
    case .unsupportedTarget: "SSH forwarding requires a TCP server address."
    case .privateSocketUnavailable: "A private tunnel socket could not be prepared."
    case .launchFailed: "The SSH process could not be started."
    case .startupFailed: "SSH did not establish the tunnel. Check the gateway, existing host key and key or agent authentication."
    case .timedOut: "SSH tunnel startup timed out."
    case .closed: "The SSH tunnel is closed."
    case .busy: "SSH tunnel startup is already in progress."
    }
  }
}

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
public struct NativeSSHGateway: Sendable, Hashable, Codable {
  public let host: String, user: String?, port: UInt32, routeIdentity: String
  public let canonicalURI: String
  public init(_ gateway: String) throws {
    guard gateway.utf8.count <= 4096, !gateway.isEmpty,
          !gateway.utf8.contains(0) else { throw NativeTunnelError.invalidRequest }
    let uri = gateway.hasPrefix("ssh://")
    var destination = uri ? String(gateway.dropFirst(6)) : gateway
    let userParts = destination.split(separator:"@",omittingEmptySubsequences:false)
    guard userParts.count <= 2 else { throw NativeTunnelError.invalidRequest }
    let user: String?
    if userParts.count == 2 {
      let candidate = String(userParts[0]), allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
      guard !candidate.isEmpty, candidate.utf8.count <= 255,
            candidate.utf8.allSatisfy({ allowed.contains($0) }) else { throw NativeTunnelError.invalidRequest }
      user = candidate; destination = String(userParts[1])
    } else { user = nil }
    var host = destination, port: UInt32 = 22
    if destination.hasPrefix("[") {
      guard let end = destination.firstIndex(of:"]") else { throw NativeTunnelError.invalidRequest }
      host = String(destination[...end]); let suffix = String(destination[destination.index(after:end)...])
      if !suffix.isEmpty {
        guard uri, suffix.hasPrefix(":"), let number = NativeListenPort.parse(String(suffix.dropFirst())), number > 0 else { throw NativeTunnelError.invalidRequest }
        port = number
      }
    } else if destination.contains(":") {
      guard uri, destination.filter({ $0 == ":" }).count == 1,
            let delimiter = destination.firstIndex(of:":"),
            let number = NativeListenPort.parse(String(destination[destination.index(after:delimiter)...])), number > 0 else { throw NativeTunnelError.invalidRequest }
      host = String(destination[..<delimiter]); port = number
    }
    guard !host.isEmpty, !host.hasPrefix("-"), !host.contains("/"), !host.contains("\\") else { throw NativeTunnelError.invalidRequest }
    let parsed: TunnelEndpoint
    do { parsed = try TunnelEndpoint("\(host)::\(port)") } catch { throw NativeTunnelError.invalidRequest }
    // SSH destination is passed as one final argument; scope bytes are exact.
    guard !parsed.host.hasPrefix("-") else { throw NativeTunnelError.invalidRequest }
    self.host = parsed.host + (parsed.scope.isEmpty ? "" : "%" + parsed.scope)
    self.port = port; self.user = user
    canonicalURI = "ssh://" + (user.map { $0 + "@" } ?? "") + parsed.forwardingHost + ":" + String(port)
    // Every admitted value must remain admissible after encode/decode. Adding
    // the URI scheme and default port can otherwise exceed the input bound.
    guard canonicalURI.utf8.count <= 4096 else { throw NativeTunnelError.invalidRequest }
    var hash = SHA256()
    for field in ["tidyvnc-ssh-v1",parsed.host,parsed.scope,String(port),user == nil ? "implicit-user" : "explicit-user",user ?? ""] {
      var length = UInt32(field.utf8.count).bigEndian
      withUnsafeBytes(of:&length) { hash.update(data:Data($0)) }; hash.update(data:Data(field.utf8))
    }
    routeIdentity = "ssh-v1:" + hash.finalize().map { String(format:"%02x",$0) }.joined()
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    do { try self.init(container.decode(String.self)) }
    catch { throw DecodingError.dataCorruptedError(in:container,debugDescription:"Invalid SSH gateway") }
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer(); try container.encode(canonicalURI)
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
  public init(endpoint: String, gateway: String, network: NativeNetworkPolicy = .builtIn) throws {
    try self.init(endpoint:endpoint,gateway:NativeSSHGateway(gateway),network:network)
  }
  public init(endpoint: String, gateway: NativeSSHGateway, network: NativeNetworkPolicy = .builtIn) throws {
    guard !endpoint.isEmpty, network.ipv4 || network.ipv6 else { throw NativeTunnelError.invalidRequest }
    remote = try TunnelEndpoint(endpoint); self.endpoint = endpoint; self.gateway = gateway
    family = network.ipv4 && network.ipv6 ? "any" : (network.ipv4 ? "inet" : "inet6")
  }
  // First implementation supports known host keys and noninteractive key/agent
  // auth. Config commands, other masters and detached children are excluded.
  // A private master acknowledges each forward before RFB admission.
  // UI/CLI support must disclose these capabilities.
  func arguments(_ command: NativeSSHCommand, socket: String) -> [String] {
    let control = URL(fileURLWithPath:socket).deletingLastPathComponent().appendingPathComponent("control").path
    var result = ["-F","/dev/null","-T","-n","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes",
      "-o","UpdateHostKeys=no","-o","ExitOnForwardFailure=yes","-o","StreamLocalBindMask=0177",
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
  func start() async throws -> NativeTunnelRoute
  func waitForExit() async -> NativeTunnelExit?
  func close() async
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
  private var child: NativeTunnelProcess?
  private var controlChild: NativeTunnelProcess?
  private var directory: TunnelDirectory?
  private var starting = false, closed = false
  private var route: NativeTunnelRoute?
  public init(request: NativeSSHTunnelRequest) {
    self.request = request; executable = "/usr/bin/ssh"; arguments = { request.arguments($0,socket:$1) }; timeout = .seconds(20)
    var environment = ["PATH":"/usr/bin:/bin","LC_ALL":"C","SSH_ASKPASS_REQUIRE":"never"]
    if let raw = getenv("SSH_AUTH_SOCK"), strnlen(raw,4097) <= 4096, let socket = String(validatingCString:raw), socket.hasPrefix("/") {
      environment["SSH_AUTH_SOCK"] = socket
    }
    self.environment = environment
  }
  // A private test executable exercises actual process ownership without SSH
  // credentials, network hosts, external config, or user stores.
  init(request: NativeSSHTunnelRequest, executable: String, timeout: Duration,
       arguments: @escaping @Sendable (NativeSSHCommand,String) -> [String]) {
    self.request = request; self.executable = executable; self.timeout = timeout; self.arguments = arguments; environment = [:]
  }
  public func start() async throws -> NativeTunnelRoute {
    guard !closed else { throw NativeTunnelError.closed }
    guard !starting else { throw NativeTunnelError.busy }
    if let route, child?.exit == nil { return route }
    guard child == nil else { throw NativeTunnelError.closed }
    try Task.checkCancellation(); starting = true; defer { starting = false }
    do {
      let directory = try TunnelDirectory(); self.directory = directory
      let child = try NativeTunnelProcess.launch(executable:executable,arguments:arguments(.master,directory.socket),environment:environment) { directory.remove() }
      self.child = child
      return try await withTaskCancellationHandler {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by:timeout)
        while clock.now < deadline {
          try Task.checkCancellation()
          guard !closed else { throw NativeTunnelError.closed }
          guard child.exit == nil else { throw NativeTunnelError.startupFailed }
          if directory.ready("control"), try await command(.check,directory:directory,deadline:deadline) == .exited(0) {
            guard try await command(.forward,directory:directory,deadline:deadline) == .exited(0),
                  child.exit == nil, directory.ready("forward") else { throw NativeTunnelError.startupFailed }
            try Task.checkCancellation()
            guard !closed else { throw NativeTunnelError.closed }
            let route = NativeTunnelRoute(endpoint:request.endpoint,localEndpoint:directory.socket,routeIdentity:request.routeIdentity)
            self.route = route; return route
          }
          try await Task.sleep(for:.milliseconds(20))
        }
        throw NativeTunnelError.timedOut
      } onCancel: { child.cancel() }
    } catch {
      await close(); throw error
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
    child?.cancel(); controlChild?.cancel()
    if let controlChild { _ = await controlChild.wait() }
    if let child { _ = await child.wait() }
    directory?.remove(); directory = nil
  }
  deinit { child?.cancel(); controlChild?.cancel(); if child == nil { directory?.remove() } }
}
