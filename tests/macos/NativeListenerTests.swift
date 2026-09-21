// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool,_ message: String) throws { if !value() { throw Failure(message:message) } }
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Listener fixture timed out")
}
final class Peer: @unchecked Sendable {
  let raw: UnsafeMutableRawPointer
  init(port: UInt32, authentication: Bool = false) throws {
    guard let raw = native_test_peer_create_reverse(UInt16(port),authentication ? 1 : 0) else { throw Failure(message:"Reverse peer failed") }
    self.raw = raw
  }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func options() -> NativeListenOptions {
  var value = NativeListenOptions(); value.address = "127.0.0.1"; value.port = 0; value.ipv6 = false; return value
}
@MainActor func handoffAndLifetime() async throws {
  let runtime = try NativeRuntime()
  let listener = try runtime.makeListener(options:options())
  var states: [NativeListenerState] = []
  let observation = listener.$snapshot.sink { states.append($0.state) }
  defer { observation.cancel() }
  try await until { listener.snapshot.state == .listening }
  if let listening = states.firstIndex(of:.listening) {
    try check(!states[listening...].contains(.starting),"initial event history cannot regress published listener state")
  }
  let other = try runtime.makeListener(options:options())
  try await until { other.snapshot.state == .listening }
  let peer = try Peer(port:listener.snapshot.addresses[0].port)
  let otherPeer = try Peer(port:other.snapshot.addresses[0].port)
  defer { withExtendedLifetime((peer,otherPeer)) {} }
  try await until { listener.incoming.count == 1 && other.incoming.count == 1 }
  let incoming = listener.incoming[0]
  try check(incoming.address.host == "127.0.0.1" && incoming.address.port != 0,"copied numeric peer")
  do { try other.reject(incoming); throw Failure(message:"Cross-listener identity accepted") }
  catch let error as NativeError { try check(error.status == .stale,"listener-scoped peer ID") }
  try other.reject(other.incoming[0]); try check(other.incoming.isEmpty,"explicit rejection removes pending peer")
  var config = NativeSessionConfiguration(); config.securityTypes = [1]
  let session = try runtime.makeSession(configuration:config)
  try check(session.snapshot.state == .idle,"incoming does not begin protocol before acceptance")
  let connected = try await listener.accept(incoming,into:session)
  try check(connected.snapshot.state == .connected,"reverse handshake reaches existing session completion")
  try await until { listener.incoming.isEmpty && session.hasFrame }
  try listener.stop(); try await until { listener.snapshot.state == .closed }
  try check(session.snapshot.state == .connected,"listener stop preserves accepted session")
  try await listener.close(); try await other.close()
  _ = try await session.disconnect()
  // A configured logical session can admit another explicit reverse connection.
  let next = try runtime.makeListener(options:options())
  try await until { next.snapshot.state == .listening }
  let again = try Peer(port:next.snapshot.addresses[0].port)
  defer { withExtendedLifetime(again) {} }
  try await until { next.incoming.count == 1 }
  let reconnected = try await next.accept(next.incoming[0],into:session)
  try check(reconnected.operation.generation > connected.operation.generation,"reusable session advances reverse generation")
  try await runtime.shutdown()
  try check(next.isClosing && next.incoming.isEmpty && session.isClosing,"runtime drains listeners and sessions")
}
@MainActor func authenticationExpiryAndRelease() async throws {
  let runtime = try NativeRuntime()
  var expiring = options(); expiring.pendingTimeoutMilliseconds = 40
  let expiry = try runtime.makeListener(options:expiring)
  try await until { expiry.snapshot.state == .listening }
  let waiting = try Peer(port:expiry.snapshot.addresses[0].port)
  defer { withExtendedLifetime(waiting) {} }
  try await until { !expiry.incoming.isEmpty }; try await until { expiry.incoming.isEmpty }
  let listener = try runtime.makeListener(options:options())
  try await until { listener.snapshot.state == .listening }
  let peer = try Peer(port:listener.snapshot.addresses[0].port,authentication:true)
  defer { withExtendedLifetime(peer) {} }
  var config = NativeSessionConfiguration(); config.securityTypes = [2]
  let session = try runtime.makeSession(configuration:config)
  try await until { listener.incoming.count == 1 }
  let accepted = Task { try await listener.accept(listener.incoming[0],into:session) }
  try await until { session.prompt != nil }
  let prompt = session.prompt!
  try check(prompt.serverName == "127.0.0.1","reverse prompt uses numeric peer identity")
  var username: [UInt8] = [], password = Array("password".utf8)
  try session.replyCredentials(to:prompt,username:&username,password:&password)
  _ = try await accepted.value
  try check(native_test_peer_verified(peer.raw) != 0,"reverse authentication replies via ordinary session")
  try await runtime.shutdown()
  var detachedRuntime: NativeRuntime? = try NativeRuntime()
  weak var weakListener: NativeListener?
  do { let ephemeral = try detachedRuntime!.makeListener(options:options()); weakListener = ephemeral }
  try await until { weakListener == nil }
  try await detachedRuntime!.shutdown(); detachedRuntime = nil
}
@main struct Main {
  @MainActor static func main() async throws {
    try await handoffAndLifetime(); try await authenticationExpiryAndRelease()
    print("PASS native listener callbacks, scoped peers, reverse sessions, authentication and drain")
  }
}
