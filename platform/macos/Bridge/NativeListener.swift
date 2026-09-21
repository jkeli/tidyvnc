// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import TidyVNC

extension tidyvnc_listener_options: ABIValue {}
extension tidyvnc_listener_snapshot: ABIValue {}
extension tidyvnc_listener_event: ABIValue {}

public struct NativeListenOptions: Sendable {
  public var address = ""
  public var port: UInt32 = 5500
  public var ipv4 = true, ipv6 = true
  public var backlog: UInt32 = 16, pendingCapacity: UInt32 = 8, eventCapacity: UInt32 = 32
  public var pendingTimeoutMilliseconds: UInt32 = 30000
  public init() {}
}
public struct NativeListenerAddress: Sendable, Equatable {
  public let host: String
  public let port: UInt32
  init(_ value: tidyvnc_listener_address) {
    host = withUnsafeBytes(of:value.host) { String(decoding:$0.prefix(while: { $0 != 0 }),as:UTF8.self) }
    port = value.port
  }
}
public struct NativeIncomingPeer: Sendable, Equatable, Identifiable {
  public let id: UInt64
  public let address: NativeListenerAddress
  fileprivate let listener: UInt64
}
public enum NativeListenerState: UInt32, Sendable { case starting, listening, stopping, closed, failed }
public enum NativeListenerFailure: UInt32, Sendable { case none, cancelled, bind, accept, invalidAddress, unsupported, eventOverflow, internalFailure }
public struct NativeListenerSnapshot: Sendable, Equatable {
  public let state: NativeListenerState
  public let failure: NativeListenerFailure
  public let nativeError: Int32
  public let pending: UInt32
  public let addresses: [NativeListenerAddress]
  init(_ value: tidyvnc_listener_snapshot) {
    state = NativeListenerState(rawValue:value.state) ?? .failed
    failure = NativeListenerFailure(rawValue:value.error) ?? .internalFailure
    nativeError = value.native_error; pending = value.pending
    addresses = [value.addresses.0,value.addresses.1].prefix(Int(min(value.address_count,2))).map(NativeListenerAddress.init)
  }
}

// One listener owns its event stream. Readiness is coalesced by the C dispatcher
// and NativeDelivery; no recurring state polling or per-peer observer is needed.
@MainActor public final class NativeListener: ObservableObject {
  @Published public private(set) var snapshot: NativeListenerSnapshot
  @Published public private(set) var incoming: [NativeIncomingPeer] = []
  @Published public private(set) var deliveryError: NativeError?
  public private(set) var isClosing = false
  private let runtime: NativeRuntime
  private let handle: NativeHandle
  private var subscription: NativeHandle?
  private var delivery: NativeDelivery?
  private var closeTask: Task<Void, Error>?
  init(runtime: NativeRuntime, options: NativeListenOptions) throws {
    self.runtime = runtime
    var config = abi(tidyvnc_listener_options.self)
    try checked { tidyvnc_listener_options_init(&config,$0) }
    config.port = options.port; config.ipv4 = options.ipv4 ? 1 : 0; config.ipv6 = options.ipv6 ? 1 : 0
    config.backlog = options.backlog; config.pending_capacity = options.pendingCapacity; config.event_capacity = options.eventCapacity
    config.pending_timeout_ms = options.pendingTimeoutMilliseconds
    var raw: UInt64 = 0
    try withText(options.address) { address in
      config.address = address; try checked { tidyvnc_listener_create(runtime.handle.raw,&config,&raw,$0) }
    }
    let owner = NativeHandle(adopting:raw); handle = owner
    var initial = abi(tidyvnc_listener_snapshot.self)
    try checked { tidyvnc_listener_get_snapshot(raw,&initial,$0) }
    snapshot = NativeListenerSnapshot(initial)
    let context = NativeDelivery { [weak self] _,_ in self?.receive() }
    delivery = context
    var callbacks = abi(tidyvnc_callbacks.self)
    callbacks.context = Unmanaged.passUnretained(context).toOpaque()
    callbacks.retain_context = retainNativeDelivery; callbacks.release_context = releaseNativeDelivery; callbacks.ready = readyNativeDelivery
    var subscribed: UInt64 = 0
    _ = try withExtendedLifetime(context) { try checked { tidyvnc_listener_subscribe(owner.raw,&callbacks,&subscribed,$0) } }
    subscription = NativeHandle(adopting:subscribed)
    // Consume queued history before exposing this owner. Otherwise the current
    // snapshot above could be Listening while the first queued event is Starting.
    receive()
  }
  private func receive() {
    guard !isClosing else { return }
    do {
      var event = abi(tidyvnc_listener_event.self)
      while try checked(allowing:[.ok,.noChange],{ tidyvnc_listener_take_event(handle.raw,&event,$0) }) == .ok {
        snapshot = NativeListenerSnapshot(event.snapshot)
        if event.kind == UInt32(TIDYVNC_LISTENER_INCOMING) {
          incoming.append(.init(id:event.incoming_id,address:NativeListenerAddress(event.peer),listener:handle.raw))
        } else if event.incoming_id != 0 {
          incoming.removeAll { $0.id == event.incoming_id }
        }
        if [.stopping,.closed,.failed].contains(snapshot.state) { incoming.removeAll() }
      }
    } catch { deliveryError = error as? NativeError ?? NativeError(.internalFailure,"Listener delivery failed") }
  }
  private func validate(_ peer: NativeIncomingPeer) throws {
    guard !isClosing else { throw NativeError(.closing,"Listener is closing") }
    guard peer.listener == handle.raw, incoming.contains(peer) else { throw NativeError(.stale,"Incoming connection is no longer available") }
  }
  public func reject(_ peer: NativeIncomingPeer) throws {
    try validate(peer); defer { receive() }
    try checked { tidyvnc_listener_reject(handle.raw,peer.id,$0) }
  }
  public func accept(_ peer: NativeIncomingPeer, into session: NativeSession) async throws -> NativeCompletion {
    try validate(peer)
    return try await session.acceptIncoming(listener:handle,incoming:peer.id)
  }
  // Stop preserves terminal event delivery and does not close accepted sessions.
  public func stop() throws { try checked { tidyvnc_listener_stop(handle.raw,$0) } }
  func beginClose() -> Task<Void,Error> {
    if let closeTask { return closeTask }
    isClosing = true; incoming.removeAll()
    let owner = handle, subscribed = subscription, context = delivery
    context?.invalidate()
    if let subscribed { _ = tidyvnc_subscription_unsubscribe(subscribed.raw,nil) }
    _ = tidyvnc_listener_stop(owner.raw,nil)
    let task = Task {
      var failure: (any Error)?
      do { try await waitForNativeDrain(owner,.listener) } catch { failure = error }
      if let subscribed {
        do { try await waitForNativeDrain(subscribed,.subscription) } catch { if failure == nil { failure = error } }
      }
      await context?.drain()
      if let failure { throw failure }
    }
    closeTask = task; return task
  }
  public func close() async throws { try await beginClose().value }
  deinit {
    delivery?.invalidate()
    if let subscription { _ = tidyvnc_subscription_unsubscribe(subscription.raw,nil) }
    _ = tidyvnc_listener_stop(handle.raw,nil)
  }
}
