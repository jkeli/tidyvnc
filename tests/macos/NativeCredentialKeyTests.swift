// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message: message) }
}
func key(_ endpoint: String, route: String = "", type: UInt32 = 2, username: String? = nil) throws -> NativeCredentialKey {
  try NativeCredentialKey(endpoint: endpoint, routeIdentity: route,
    authentication: username == nil ? .passwordOnly(securityType: type) : .usernamePassword(securityType: type), username: username ?? "")
}
func identity() throws {
  let canonical = try key("HOST:1")
  try check(canonical.account == "v1:30f12c29b75ce9cc7cfd537abe1c50eac5b2ddab0111ed4eefbe363441745ca2", "stable independently computed v1 account")
  for address in ["host::5901", " host: +001 ", "[Host]:1"] {
    try check(key(address) == canonical, "equivalent shared-parser spellings")
  }
  try check(key("") == key("localhost:0"), "core default endpoint semantics")
  try check(key("[2001:0DB8:0:0:0:0:0:1]:1") == key("[2001:db8::1]::5901"), "numeric IPv6 normalization")
  let distinct: [(String,String)] = [
    ("host:1","host:2"), ("host:1","host.:1"), ("localhost:1","127.0.0.1:1"),
    ("host:1","alias:1"), ("127.0.0.1:1","[::ffff:127.0.0.1]:1"),
    ("[fe80::1%en0]:1","[fe80::1%EN0]:1"), ("[fe80::1%1]:1","[fe80::1%01]:1"),
    ("/tmp/Desktop","/tmp/desktop"), ("/tmp/socket"," /tmp/socket "),
    ("./socket","/tmp/socket"), ("/tmp/a/../socket","/tmp/socket")
  ]
  for (first, second) in distinct { try check(key(first) != key(second), "destination distinctions cannot merge") }
  try check(key("host:1", route: "ssh-target-a") != key("host:1", route: "ssh-target-b"), "same local port and different tunnel target")
  try check(key("host:1", route: "ssh-target-a") != canonical, "direct and routed identities differ")
  try check(key("host:1", route: "Route") != key("host:1", route: "route"), "opaque route case is exact")
  try check(key("host:1", type: 258) != canonical, "authentication type is scoped")
  try check(key("host:1", type: 5) != key("host:1", type: 5, username: ""), "RSA password-only and empty username forms differ")
  try check(key("host:1", type: 256, username: "User") != key("host:1", type: 256, username: "user"), "username case is exact")
  try check(key("host:1", route: "a", type: 256, username: "bc") != key("host:1", route: "ab", type: 256, username: "c"), "field framing prevents concatenation collisions")
  let composed = "é", decomposed = "e\u{301}"
  try check(composed == decomposed, "Unicode equivalence fixture")
  try check(key("host", type: 256, username: composed) != key("host", type: 256, username: decomposed), "username wire bytes preserved")
  try check(key("/tmp/" + composed) != key("/tmp/" + decomposed), "path bytes preserved")
  try check(key("host", route: composed) != key("host", route: decomposed), "route bytes preserved")
  try check(String(describing: canonical) == "NativeCredentialKey(<redacted>)" && String(reflecting: canonical) == canonical.description, "diagnostics do not expose identity")
  try check(NativeCredentialKey.service == "io.github.jkeli.tidyvnc.credentials.v1", "app-scoped versioned service")
  print("PASS canonical endpoint, route/auth/user scope, byte identity, framing and stable namespaced SHA-256 account")
}
func validation() throws {
  func rejects(_ expected: NativeCredentialKeyIssue, _ build: () throws -> NativeCredentialKey) throws {
    do { _ = try build(); throw Failure(message: "Invalid credential key accepted") }
    catch let error as NativeCredentialKeyIssue { try check(error == expected, "typed safe validation") }
  }
  for type: UInt32 in [0,1,18,19,257,260] {
    try rejects(.invalidAuthentication) { try key("host", type: type) }
  }
  try rejects(.unexpectedUsername) { try NativeCredentialKey(endpoint: "host", authentication: .passwordOnly(securityType: 2), username: "private-user") }
  for value in [String(repeating: "x", count: 4097),String(repeating: "é", count: 2049)] {
    try rejects(.tooLong) { try key(value) }
    try rejects(.tooLong) { try key("host", route: value) }
    try rejects(.tooLong) { try key("host", type: 256, username: value) }
  }
  let limit = String(repeating: "é", count: 2048)
  _ = try key("host", route: limit, type: 256, username: limit)
  _ = try key("/" + String(repeating: "x", count: 4095))
  for value in ["\0", "private\0data"] {
    try rejects(.invalidText) { try key(value) }
    try rejects(.invalidText) { try key("host", route: value) }
    try rejects(.invalidText) { try key("host", type: 256, username: value) }
  }
  do {
    _ = try NativeCredentialKey(endpoint: "/tmp/private-socket", authentication: .passwordOnly(securityType: 2), allowUnixSockets: false)
    throw Failure(message: "Unsupported transport accepted")
  } catch let error as NativeError { try check(!error.description.contains("private"), "parser error redacted") }
  do { _ = try key("private-host::70000"); throw Failure(message: "Invalid endpoint accepted") }
  catch let error as NativeError { try check(!error.description.contains("private"), "syntax error redacted") }
  for secure in [false, true] {
    let prompt = NativePrompt(id: 1, generation: 1, kind: .credentials, secure: secure, usernameRequired: false,
      certificateStatus: 0, serverName: "private-host", fingerprint: "", identity: Data())
    try check(prompt.credentialProtectionMessage.contains(secure ? "protects your credentials" : "may not adequately protect"), "preserve credential policy indication")
    try check(!prompt.credentialProtectionMessage.contains("encrypted") && !prompt.credentialProtectionMessage.contains("private-host"), "no blanket encryption or identity assertion")
  }
  print("PASS input/UTF-8 limits, password-only empty user, invalid auth, NUL and transport policy")
}
func concurrent() async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    for worker in 0..<8 {
      group.addTask {
        let expected = try key("HOST:1", route: "route-\(worker)", type: 256, username: "user-\(worker)")
        for _ in 0..<100 {
          try check(key("host::5901", route: "route-\(worker)", type: 256, username: "user-\(worker)") == expected, "concurrent independent identity")
        }
      }
    }
    try await group.waitForAll()
  }
  print("PASS concurrent stateless normalization and hashing without runtime, session, IO or shared cache")
}
@main struct NativeCredentialKeyTests {
  static func main() async {
    do { try identity(); try validation(); try await concurrent() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
