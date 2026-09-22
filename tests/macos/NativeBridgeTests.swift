// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import NativeTestSupport
import TidyVNC
@testable import TidyVNCNative

struct TestFailure: Error, CustomStringConvertible { let description: String }
final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw TestFailure(description: message) }
}
final class Peer: @unchecked Sendable {
  let raw: UnsafeMutableRawPointer
  init(authentication: Bool = false) throws {
    guard let raw = native_test_peer_create(authentication ? 1 : 0) else { throw TestFailure(description: "Loopback fixture construction failed") }
    self.raw = raw
  }
  var endpoint: String { "127.0.0.1::\(native_test_peer_port(raw))" }
  var verified: Bool { native_test_peer_verified(raw) != 0 }
  var hasKey: Bool { native_test_peer_has_key(raw) != 0 }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor final class ValueWaiter<T: Sendable> {
  var subscription: AnyCancellable?
  var continuation: CheckedContinuation<T, Never>?
  init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
  func finish(_ value: T) {
    precondition(Thread.isMainThread)
    guard let continuation else { return }
    self.continuation = nil; subscription?.cancel(); subscription = nil; continuation.resume(returning: value)
  }
}
@MainActor func next<P: Publisher>(_ publisher: P, matching predicate: @escaping @MainActor (P.Output) -> Bool) async -> P.Output where P.Output: Sendable, P.Failure == Never {
  await withCheckedContinuation { continuation in
    let waiter = ValueWaiter(continuation)
    let subscription = publisher.sink { value in
      MainActor.assumeIsolated { if predicate(value) { waiter.finish(value) } }
    }
    // Current-value publishers can emit synchronously during sink installation.
    if waiter.continuation != nil { waiter.subscription = subscription } else { subscription.cancel() }
  }
}
@MainActor func configuration(_ security: UInt32) -> NativeSessionConfiguration {
  var value = NativeSessionConfiguration(); value.securityTypes = [security]; return value
}
@MainActor func serverFrame(_ session: NativeSession) async -> NativeImage {
  let value = await next(session.frameUpdates) { image in (try? image?.copyPixels().first) == 10 }
  return value!
}

@MainActor func connectFramesInputReconnect() async throws {
  var bounded = abi(tidyvnc_connection_info.self); bounded.name_truncated = 1
  withUnsafeMutableBytes(of: &bounded.desktop_name) { bytes in
    bytes.initializeMemory(as: UInt8.self, repeating: 0x61)
    bytes[1023] = 0xf0; bytes[1024] = 0
  }
  let decoded = NativeConnectionInformation(bounded)
  try expect(decoded.nameTruncated && decoded.desktopName.count == 1024 && decoded.desktopName.last == "�",
    "bounded name decoding replaces a truncated UTF-8 scalar")
  try expect(!decoded.redactedDiagnostics.contains(String(repeating: "a", count: 10)), "redaction excludes even long remote names")
  let runtime = try NativeRuntime(); let session = try runtime.makeSession(configuration: configuration(1))
  let peer = try Peer(); let connected = try await session.connect(endpoint: peer.endpoint)
  try expect(connected.snapshot.state == .connected && connected.operation.generation == session.generation, "connect completion")
  let retained = await serverFrame(session)
  let information = await next(session.informationUpdates) { ($0?.frames ?? 0) > 0 }
  try expect(information?.desktopName == "peer" && information?.protocolMajor == 3 && information?.protocolMinor == 8,
    "copied negotiated desktop/protocol metadata")
  try expect(information?.securityType == 1 && information?.credentialsSecure == false && information?.lastEncoding == 0 && information?.pixelFormat.contains("24") == true,
    "actual security, encoding and wire pixel format")
  try expect(information?.redactedDiagnostics.contains(peer.endpoint) == false && information?.redactedDiagnostics.contains("peer") == false,
    "diagnostics omit endpoint and remote desktop name")
  try expect(retained.width == 2 && retained.height == 2, "frame geometry")
  try session.setFocused(true); try session.sendKey(id: 1, keysym: 65, down: true)
  try session.sendKey(id: 1, keysym: 65, down: false); try session.sendPointer(x: 1, y: 1, buttons: 0)
  for _ in 0..<100 where !peer.hasKey { try await Task.sleep(for: .milliseconds(2)) }
  try expect(peer.hasKey, "actual wire key input")
  let refreshed = try await session.refresh(); try expect(refreshed.operation.id != connected.operation.id, "reserved operation identity")
  _ = try await session.disconnect()
  try expect(session.frame == nil && session.cursor == nil && session.information == nil, "disconnect clears obsolete desktop presentation and metadata")
  let second = try Peer(); let reconnected = try await session.connect(endpoint: second.endpoint)
  try expect(reconnected.operation.generation > connected.operation.generation, "reconnect generation")
  let newFrame = await serverFrame(session); try expect(newFrame.generation == session.generation, "current frame routing")
  let nextInformation = await next(session.informationUpdates) { $0?.generation == session.generation }
  try expect(nextInformation?.generation != information?.generation, "reconnect replaces attempt metadata")
  try await session.close(); try await session.close(); try await runtime.shutdown()
  try expect(session.frame == nil && session.cursor == nil && session.prompt == nil && session.isClosing, "close clears presentation")
  try expect(session.snapshot.state == .closed, "joined close publishes final native state")
  try expect(session.information == nil && information?.desktopName == "peer", "copied information survives close without remaining published")
  try expect(retained.alpha == .opaque, "opaque pixels ignore their padding byte")
  try expect(try retained.copyPixels() == Data([10,20,30,0,10,20,30,0,10,20,30,0,10,20,30,0]), "retained old frame survives shutdown")
}

@MainActor func credentialsAreOwnedAndWiped() async throws {
  let runtime = try NativeRuntime(); let session = try runtime.makeSession(configuration: configuration(2)); let peer = try Peer(authentication: true)
  let connecting = Task { try await session.connect(endpoint: peer.endpoint) }
  let request = await next(session.$prompt) { $0 != nil }
  try expect(request!.kind == .credentials && !request!.secure, "VNC prompt metadata")
  var user: [UInt8] = [], password = Array("password".utf8)
  try session.replyCredentials(to: request!, username: &user, password: &password)
  try expect(password.allSatisfy { $0 == 0 }, "submitted password buffer wiped")
  _ = try await connecting.value; _ = await serverFrame(session); try expect(peer.verified, "independent VNC challenge response")
  let information = await next(session.informationUpdates) { $0 != nil }
  try expect(information?.securityType == 2 && information?.securityName == "VncAuth" && information?.credentialsSecure == false,
    "negotiated authentication differs from unauthenticated connection")
  try expect(information?.redactedDiagnostics.contains("password") == false, "diagnostics omit submitted credentials")
  try await runtime.shutdown()
  try expect(!request!.serverName.isEmpty, "copied prompt outlives native metadata handle")
  password = Array("stale".utf8)
  do { try session.replyCredentials(to: request!, username: &user, password: &password); throw TestFailure(description: "stale credentials accepted") }
  catch is NativeError {}
  try expect(password.allSatisfy { $0 == 0 }, "rejected password buffer wiped")
}

@MainActor func routedConnectionUsesPreparedLocalTransport() async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession(configuration:configuration(1))
  let peer = try Peer()
  for route in ["", "bad\0route"] {
    do {
      _ = try await session.connect(endpoint:"remote.invalid:1",through:peer.endpoint,routeIdentity:route)
      throw TestFailure(description:"Invalid tunnel route admitted")
    } catch let error as NativeError { try expect(error.status == .invalidArgument,"typed tunnel admission rejection") }
  }
  try expect(session.snapshot.state == .idle,"invalid tunnel admission leaves session reusable")
  let connected = try await session.connect(endpoint:"remote.invalid:1",through:peer.endpoint,routeIdentity:"ssh:gateway")
  try expect(connected.snapshot.state == .connected,"routed RFB connection does not resolve logical target")
  _ = await serverFrame(session)
  _ = try await session.disconnect()
  let nextPeer = try Peer()
  _ = try await session.connect(endpoint:nextPeer.endpoint)
  _ = await serverFrame(session)
  try await runtime.shutdown()
}

@MainActor final class Counter { var value = 0 }
@MainActor func cancellationAndIndependentProgress() async throws {
  let runtime = try NativeRuntime(); let parked = try runtime.makeSession(configuration: configuration(2)); let waiting = try Peer(authentication: true)
  let connecting = Task { try await parked.connect(endpoint: waiting.endpoint) }
  _ = await next(parked.$prompt) { $0 != nil }
  let ticks = Counter()
  let heartbeat = Task { for _ in 0..<10 { try await Task.sleep(for: .milliseconds(2)); ticks.value += 1 } }
  let second = try runtime.makeSession(configuration: configuration(1)); let peer = try Peer()
  _ = try await second.connect(endpoint: peer.endpoint); _ = await serverFrame(second)
  try await heartbeat.value; try expect(ticks.value == 10, "MainActor advances while another worker waits for credentials")
  connecting.cancel()
  do { _ = try await connecting.value; throw TestFailure(description: "cancelled connect returned success") } catch is CancellationError {}
  try expect(second.snapshot.state == .connected, "independent session remains connected")
  try await runtime.shutdown()
}

@MainActor func closeResumesPendingCommandsAndDoesNotRetainModels() async throws {
  let runtime = try NativeRuntime(sessionCapacity: 1)
  var session: NativeSession? = try runtime.makeSession(configuration: configuration(2))
  let observer = WeakReference(session); let peer = try Peer(authentication: true)
  let connecting = Task { [current = session!] in try await current.connect(endpoint: peer.endpoint) }
  _ = await next(session!.$prompt) { $0 != nil }
  let closing = Task { [current = session!] in try await current.close() }
  closing.cancel() // Caller cancellation must not cancel the cleanup task.
  try await closing.value
  do { _ = try await connecting.value; throw TestFailure(description: "close left connect successful") }
  catch let error as NativeError { try expect(error.status == .closing, "typed closing error") }
  session = nil; await Task.yield(); try expect(observer.value == nil, "model has no callback/runtime ownership cycle")
  // Closed workers release their capacity; weak registry entries are pruned.
  for _ in 0..<80 {
    var fresh: NativeSession? = try runtime.makeSession(configuration: configuration(1))
    let old = WeakReference(fresh); try await fresh!.close(); fresh = nil
    await Task.yield(); try expect(old.value == nil, "repeated session/context cleanup")
  }
  try await runtime.shutdown(); try await runtime.shutdown()
  do { _ = try runtime.makeSession(); throw TestFailure(description: "shutdown admitted session") }
  catch let error as NativeError { try expect(error.status == .closing, "runtime closing error") }
}

@MainActor func typedValidationAndRejectedAdmission() async throws {
  let runtime = try NativeRuntime(sessionCapacity: 1)
  var invalid = configuration(1); invalid.commandCapacity = 0
  do { _ = try runtime.makeSession(configuration: invalid); throw TestFailure(description: "invalid capacity accepted") }
  catch let error as NativeError { try expect(error.status == .invalidArgument, "typed configuration error") }
  let session = try runtime.makeSession(configuration: configuration(1))
  do { _ = try runtime.makeSession(); throw TestFailure(description: "full runtime accepted session") }
  catch let error as NativeError { try expect(error.status == .resourceLimit, "typed capacity error") }
  do { _ = try await session.connect(endpoint: "bad\0host"); throw TestFailure(description: "NUL endpoint accepted") }
  catch let error as NativeError { try expect(error.status == .invalidArgument, "typed endpoint error") }
  do { _ = try await session.refresh(); throw TestFailure(description: "idle refresh accepted") }
  catch let error as NativeError { try expect(error.status == .notConnected, "typed state rejection") }
  let peer = try Peer(); let connecting = Task { try await session.connect(endpoint: peer.endpoint) }; connecting.cancel()
  do { _ = try await connecting.value; throw TestFailure(description: "pre-cancelled task connected") } catch is CancellationError {}
  try expect(session.generation == 1, "pre-cancelled operation was never admitted")
  try await runtime.shutdown()
}

func ignoreContext(_ context: UnsafeMutableRawPointer?) {}
func ignoreReady(_ context: UnsafeMutableRawPointer?, _ subscription: UInt64, _ generation: UInt64) {}
@MainActor final class RawSession {
  let runtime: NativeHandle, session: NativeHandle, subscription: NativeHandle
  init() throws {
    var settings = abi(tidyvnc_runtime_options.self); try checked { tidyvnc_runtime_options_init(&settings, $0) }
    var raw: UInt64 = 0; try checked { tidyvnc_runtime_create(&settings, &raw, $0) }; let runtimeOwner = NativeHandle(adopting: raw)
    var options = abi(tidyvnc_session_options.self); try checked { tidyvnc_session_options_init(&options, $0) }
    try checked { tidyvnc_session_create(runtimeOwner.raw, &options, &raw, $0) }; let sessionOwner = NativeHandle(adopting: raw)
    var callbacks = abi(tidyvnc_callbacks.self); callbacks.retain_context = ignoreContext; callbacks.release_context = ignoreContext; callbacks.ready = ignoreReady
    try checked { tidyvnc_session_subscribe(sessionOwner.raw, &callbacks, &raw, $0) }
    runtime = runtimeOwner; session = sessionOwner; subscription = NativeHandle(adopting: raw)
  }
  func close() async throws {
    try checked { tidyvnc_session_close(session.raw, $0) }; try checked { tidyvnc_subscription_unsubscribe(subscription.raw, $0) }
    try checked { tidyvnc_runtime_shutdown(runtime.raw, $0) }
    try await waitForNativeDrain(session, .session); try await waitForNativeDrain(subscription, .subscription)
    try await waitForNativeDrain(runtime, .runtime)
  }
}
@MainActor func queuedDeliveryCoalescesAndRejectsTeardownAndOldGenerations() async throws {
  let raw = try RawSession(); let calls = Counter()
  var delivery: NativeDelivery? = NativeDelivery { _, _ in calls.value += 1 }
  for _ in 0..<1_000 { delivery!.signal(subscription: raw.subscription.raw, generation: 1) }
  try await Task.sleep(for: .milliseconds(2)); try expect(calls.value == 1, "one coalesced MainActor delivery")
  for _ in 0..<1_000 { delivery!.signal(subscription: raw.subscription.raw, generation: 1) }
  delivery!.invalidate(); await delivery!.drain(); try expect(calls.value == 1, "queued delivery invalidated before teardown")
  let released = WeakReference(delivery); delivery = nil; await Task.yield(); try expect(released.value == nil, "queued task releases its context")
  let stale = NativeDelivery { _, _ in calls.value += 1 }
  stale.signal(subscription: raw.subscription.raw, generation: 1)
  let peer = try Peer(); var options = abi(tidyvnc_connect_options.self); try checked { tidyvnc_connect_options_init(&options, $0) }
  var operation = abi(tidyvnc_operation.self)
  try withText(peer.endpoint) { endpoint in
    options.endpoint = endpoint; try checked { tidyvnc_session_connect(raw.session.raw, &options, &operation, $0) }
  }
  try await Task.sleep(for: .milliseconds(2)); try expect(calls.value == 1, "queued old generation never reaches UI action")
  stale.invalidate(); await stale.drain(); try await raw.close()
}

@MainActor func clipboardOwnershipRoutingAndCommands() async throws {
  let runtime = try NativeRuntime()
  var options = configuration(1); options.clipboardSend = false
  let session = try runtime.makeSession(configuration: options), peer = try Peer()
  _ = try await session.connect(endpoint: peer.endpoint); _ = await serverFrame(session)
  try session.setFocused(true)
  native_test_peer_clipboard(peer.raw)
  let update = await next(session.$clipboard) { $0?.kind == .text }
  let retained = update!.text!
  try expect(retained.fromRemote && retained.text == "café\n", "owned normalized clipboard text")
  try session.validateClipboard(retained.route, sending: false)
  do { _ = try await session.offerClipboard("local"); throw TestFailure(description: "disabled send accepted") }
  catch let error as NativeError { try expect(error.status == .disabled, "independent send policy") }
  try session.setClipboardPolicy(send: true, receive: false)
  do { try session.validateClipboard(retained.route, sending: false); throw TestFailure(description: "old policy token accepted") }
  catch let error as NativeError { try expect(error.status == .stale, "stale clipboard policy route") }
  do { _ = try await session.offerClipboard(retained.text, origin: retained); throw TestFailure(description: "remote echo accepted") }
  catch let error as NativeError { try expect(error.status == .echo, "remote-origin echo suppressed") }
  _ = try await session.offerClipboard("café\r\n", changeID: 42)
  for _ in 0..<100 where native_test_peer_has_clipboard(peer.raw) == 0 { try await Task.sleep(for: .milliseconds(2)) }
  try expect(native_test_peer_has_clipboard(peer.raw) != 0, "clipboard text reached wire")
  let second = try runtime.makeSession(configuration: options), otherPeer = try Peer()
  _ = try await second.connect(endpoint: otherPeer.endpoint); _ = await serverFrame(second)
  try second.setFocused(true)
  do { try second.validateClipboard(retained.route, sending: false); throw TestFailure(description: "foreign session token accepted") }
  catch let error as NativeError { try expect(error.status == .stale, "session-scoped clipboard route") }
  try second.setClipboardPolicy(send: true, receive: true)
  do { _ = try await second.offerClipboard(retained.text, origin: retained); throw TestFailure(description: "cross-session echo accepted") }
  catch let error as NativeError { try expect(error.status == .echo, "cross-session provenance") }
  try session.setFocused(false)
  do { _ = try await session.offerClipboard("local"); throw TestFailure(description: "unfocused offer accepted") }
  catch let error as NativeError { try expect(error.status == .unfocused, "focus policy") }
  try session.setFocused(true); _ = try await session.clearClipboard()
  try await runtime.shutdown()
  try expect(retained.text == "café\n" && session.clipboard == nil && !session.isFocused, "clipboard lifetime and closed presentation")
}

@MainActor func encodingSchemaOwnershipAndCommands() async throws {
  let schema = try NativeEncodingOptions.schema(), choices = try NativeEncodingOptions.choices()
  try expect(schema.count == 8 && schema.first { $0.id == .quality }?.maximum == 9, "shared schema limits")
  try expect(schema.first { $0.id == .fullColor }?.alias == "FullColour" && choices.contains { $0.name == "Raw" && $0.available }, "shared aliases and decoder capabilities")
  let original = try NativeEncodingOptions(patch: [.init("AutoSelect", "off"), .init("QualityLevel", "3")], source: .appDefaults)
  let modified = try original.applying([.init("qualitylevel", "0x5"), .init("PreferredEncoding", "Raw")], source: .session)
  try expect(try original.value(for: .quality).value == "3" && modified.value(for: .quality).value == "5", "immutable canonical patches")
  do { _ = try modified.applying([.init("QualityLevel", "10")], source: .session); throw TestFailure(description: "invalid quality accepted") }
  catch let error as NativeError { try expect(error.encodingProblem == .invalidValue && error.encodingOption == .quality, "structured option error") }
  for choice in choices where !choice.available {
    do { _ = try modified.applying([.init("PreferredEncoding", choice.name)], source: .session); throw TestFailure(description: "unavailable decoder accepted") }
    catch let error as NativeError { try expect(error.status == .unsupported && error.encodingProblem == .unavailable, "capability rejection") }
  }
  try await withThrowingTaskGroup(of: Void.self) { group in
    for _ in 0..<32 { group.addTask { try expect(try original.value(for: .quality).value == "3", "concurrent immutable reads") } }
    try await group.waitForAll()
  }
  let runtime = try NativeRuntime(); var options = configuration(1); options.encoding = original
  let first = try runtime.makeSession(configuration: options), peer = try Peer()
  try expect(try first.encodingOptions().value(for: .quality).source == .appDefaults, "configured before negotiation")
  _ = try await first.connect(endpoint: peer.endpoint); _ = await serverFrame(first)
  _ = try await first.applyEncoding(modified)
  let updatedInformation = await next(first.informationUpdates) { $0?.requestedEncoding == 0 }
  try expect(updatedInformation?.lastEncoding == 0, "idle desktop publishes requested and last received encoding separately")
  let retained = try first.encodingOptions()
  try expect(try retained.value(for: .quality).value == "5" && retained.value(for: .quality).source == .session, "async completion exposes applied snapshot")
  let second = try runtime.makeSession(configuration: options)
  try expect(try second.encodingOptions().value(for: .quality).value == "3", "another session retains independent defaults")
  do { _ = try await first.applyEncoding(original, expectedGeneration: first.generation + 1); throw TestFailure(description: "stale apply accepted") }
  catch let error as NativeError { try expect(error.status == .stale, "generation checked at admission") }
  let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await first.applyEncoding(original) }
  do { _ = try await cancelled.value; throw TestFailure(description: "cancelled apply succeeded") } catch is CancellationError {}
  try await runtime.shutdown()
  try expect(try retained.value(for: .quality).value == "5", "encoding snapshot survives runtime close")
}

@main struct NativeBridgeTests {
  @MainActor static func main() async {
    do {
      try await connectFramesInputReconnect(); print("PASS connect, frames, wire input, reconnect, retained images")
      try await credentialsAreOwnedAndWiped(); print("PASS owned VNC prompt and secret submission")
      try await routedConnectionUsesPreparedLocalTransport(); print("PASS routed transport, validation and direct reconnect")
      try await cancellationAndIndependentProgress(); print("PASS task cancellation, MainActor heartbeat and independent session")
      try await closeResumesPendingCommandsAndDoesNotRetainModels(); print("PASS close/drain, pending continuations and repeated ownership cleanup")
      try await queuedDeliveryCoalescesAndRejectsTeardownAndOldGenerations(); print("PASS coalesced delivery, queued teardown and stale generation")
      try await clipboardOwnershipRoutingAndCommands(); print("PASS clipboard ownership, wire commands, directions, routes and echo suppression")
      try await encodingSchemaOwnershipAndCommands(); print("PASS encoding schema, ownership, typed validation, independent sessions and async commands")
      try await typedValidationAndRejectedAdmission(); print("PASS typed errors, capacity rejection and cancellation before admission")
    } catch {
      FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1)
    }
  }
}
