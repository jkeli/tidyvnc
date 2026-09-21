// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(message: message) } }
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message: "Unexpected defaults write") }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
func syntax() throws {
  try NativeEndpoint.validate("") // Core compatibility is independent of form policy.
  try check(NativeEndpoint.issue(for: "") == .required, "native form requires an address")
  for address in [" \t\r\n", ":1", "::99", "host:100", "host::65535", "host: +005 ", "[]:1", "2001::1",
                  " [HOST]::5901 ", "[::1]:2", "2001:db8::20:1", "[FE80::1%en0]::5901", " ./VNC socket:1 ", "/tmp/桌面.sock"] {
    try NativeEndpoint.validate(address)
    try check(NativeEndpoint.issue(for: address) == nil, "shared supported syntax")
  }
  let fixtures: [(String, NativeEndpointIssue)] = [
    ("ho st", .invalidHost), ("[gggg::1]", .invalidHost), ("[fe80::1%]", .invalidHost), ("[::1", .unmatchedBracket),
    ("host::0", .invalidPort), ("host::65536", .invalidPort), ("host::4294967297", .invalidPort), ("host:1x", .invalidPort),
    ("[::1] :1", .invalidPort), ("host\0name", .invalidText), ("/tmp/a\0b", .invalidText),
    (String(repeating: "x", count: 4097), .tooLong), (String(repeating: "é", count: 2049), .tooLong)
  ]
  for (address, issue) in fixtures { try check(NativeEndpoint.issue(for: address) == issue, "structured endpoint reason") }
  try check(NativeEndpoint.issue(for: String(repeating: "é", count: 2048)) == nil, "UTF-8 byte boundary")
  try check(NativeEndpoint.issue(for: "/tmp/socket", allowUnixSockets: false) == .unsupportedTransport, "host transport policy")
  do { try NativeEndpoint.validate("private-host::70000"); throw Failure(message: "Accepted invalid port") }
  catch let error as NativeError { try check(error.description == "Invalid argument", "redacted diagnostic") }
  print("PASS shared address forms, typed errors, UTF-8 bounds, explicit Unix policy and redacted failures")
}
@MainActor func forms() async throws {
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let connection = ConnectionModel(runtime: runtime, preferences: preferences) { _, _ in }
  try await until { connection.defaults?.isReady == true }
  let snapshot = connection.session?.snapshot
  try check(connection.endpointIssue == .required && !connection.canConnect, "empty connection disabled")
  connection.endpoint = "host::70000"
  try check(connection.endpointIssue == .invalidPort && !connection.canConnect, "invalid connection disabled")
  connection.connect()
  try check(!connection.busy && connection.message == nil && connection.session?.snapshot == snapshot, "invalid entry cannot allocate operation or start connection")
  connection.endpoint = "[::1]:1"
  try check(connection.endpointIssue == nil && connection.canConnect && connection.session?.snapshot == snapshot, "editing valid address enables Connect without connecting")
  connection.endpoint = "[::1"
  try check(connection.endpointIssue == .unmatchedBracket && !connection.canConnect, "new invalid edit replaces prior result")
  let backing = HistoryBacking(), store = NativeProfileHistoryStore(backing: backing)
  let library = NativeProfileLibrary(store: store, preferences: preferences)
  library.reload(); try await until { !library.isBusy }; library.newProfile()
  library.draft?.name = "Lab"; library.draft?.endpoint = "host::70000"
  try check(library.endpointIssue == .invalidPort && !library.canSave, "invalid profile disabled")
  library.save(); try check(backing.writes == 0 && !library.isBusy, "invalid profile save performs no IO")
  library.draft?.endpoint = "/tmp/VNC socket"
  try check(library.endpointIssue == nil && library.canSave, "valid Unix path accepted without probing filesystem")
  library.save(); try await until { !library.isBusy }
  try check(library.canUse && library.profiles.first?.endpoint == "/tmp/VNC socket", "original path is saved without normalization")
  await library.close(); await connection.close(); await store.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS actual controller and profile forms gate invalid actions, update validation and preserve original valid text")
}
@main struct NativeEndpointTests {
  @MainActor static func main() async {
    do { try syntax(); try await forms() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
