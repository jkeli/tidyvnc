// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

public enum NativeLaunchCredentialIssue: Error, Sendable, CustomStringConvertible {
  case invalidEnvironment
  public var description: String { String(localized:"credentials.launch.invalid.environment", defaultValue:"A launch credential exceeds its byte limit or contains invalid data.") }
}
// A single claim transfers these inputs to one connection. No Codable, observable
// secret, global cache or reread of the process environment is permitted.
public final class NativeLaunchCredentialInputs: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  private let lock = NSLock()
  private var pending: NativeLaunchCredentialPayload?
  public var description: String { "NativeLaunchCredentialInputs(<redacted>)" }
  public var debugDescription: String { description }
  public init(username: inout [UInt8]?, password: inout [UInt8]?, passwordFile: URL? = nil) throws {
    defer { Self.wipe(&username); Self.wipe(&password) }
    for value in [username,password] {
      guard value == nil || (value!.count <= 4096 && !value!.contains(0)) else { throw NativeLaunchCredentialIssue.invalidEnvironment }
    }
    func consume(_ input: [UInt8]?) throws -> NativeCredentialSecret? {
      guard var bytes = input else { return nil }
      return try NativeCredentialSecret(consuming:&bytes)
    }
    let user = try consume(username)
    do { pending = NativeLaunchCredentialPayload(username:user,password:try consume(password),file:passwordFile) }
    catch { user?.clear(); throw error }
  }
  private static func wipe(_ value: inout [UInt8]?) {
    value?.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base,$0.count,0,$0.count) } }
  }
  // Called once after complete terminal/preflight handling, before worker threads.
  // getenv storage belongs to the process; only the bounded owned copies are
  // cleared. No promise is made to erase the original environment or caller copies.
  public static func capture(passwordFile: URL?) throws -> NativeLaunchCredentialInputs {
    func read(_ name: String) throws -> [UInt8]? {
      guard let value = getenv(name) else { return nil }
      let count = strnlen(value,4097)
      guard count <= 4096 else { throw NativeLaunchCredentialIssue.invalidEnvironment }
      return Array(UnsafeBufferPointer(start:UnsafeRawPointer(value).assumingMemoryBound(to:UInt8.self),count:count))
    }
    var username: [UInt8]?, password: [UInt8]?
    defer { wipe(&username); wipe(&password) }
    username = try read("VNC_USERNAME"); password = try read("VNC_PASSWORD")
    return try .init(username:&username,password:&password,passwordFile:passwordFile)
  }
  public static func passwordFile(_ options: NativeInvocationOptions, workingDirectory: String?) throws -> URL? {
    var selected: URL?
    for field in options.assignments where field.name == "PasswordFile" {
      if field.value.isEmpty { selected = nil; continue }
      var path = field.value
      if !path.hasPrefix("/") {
        guard let base = workingDirectory, base.hasPrefix("/"), !base.utf8.contains(0) else {
          throw NativeInvocationResolutionFailure(reason:.relativePathNeedsBase,argument:field.argument)
        }
        path = base + (base.hasSuffix("/") ? "" : "/") + path
      }
      guard !path.utf8.contains(0), path.utf8.count <= NativeInvocationSyntax.maximumArgumentBytes else {
        throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:field.argument)
      }
      selected = URL(fileURLWithPath:path)
    }
    return selected
  }
  // Embedding hosts that supply an invocation without a process capture still
  // get its explicit file policy; never consult environment state after launch.
  public static func fileOnly(_ request: NativeInvocationRequest) throws -> NativeLaunchCredentialInputs? {
    guard let file = try passwordFile(request.options,workingDirectory:request.workingDirectory) else { return nil }
    var user: [UInt8]?, password: [UInt8]?
    return try .init(username:&user,password:&password,passwordFile:file)
  }
  func claim() -> NativeLaunchCredentialPayload? {
    lock.withLock { defer { pending = nil }; return pending }
  }
  public func clear() { lock.withLock { pending?.clear(); pending = nil } }
  deinit { pending?.clear() }
}
// Only a claimed connection owner may read these references. Clearing also
// invalidates references captured by an in-flight task before it can submit.
final class NativeLaunchCredentialPayload: Sendable {
  let username: NativeCredentialSecret?, password: NativeCredentialSecret?
  let file: URL?
  init(username: NativeCredentialSecret?, password: NativeCredentialSecret?, file: URL?) {
    self.username = username; self.password = password; self.file = file
  }
  func hasEnvironment(usernameRequired: Bool) -> Bool { password != nil && (!usernameRequired || username != nil) }
  func clear() { username?.clear(); password?.clear() }
  deinit { clear() }
}
