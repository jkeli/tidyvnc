// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

// Synchronization covers only the scheduling gate. The action and drain waiters
// belong to MainActor; no C callback touches observable session state.
final class NativeDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true, queued = false
  private var generation: UInt64 = 0
  private let action: @MainActor @Sendable (UInt64, UInt64) -> Void
  @MainActor private var waiters: [CheckedContinuation<Void, Never>] = []
  init(action: @escaping @MainActor @Sendable (UInt64, UInt64) -> Void) { self.action = action }
  func invalidate() { lock.withLock { active = false } }
  private var hasQueuedDelivery: Bool { lock.withLock { queued } }
  func signal(subscription: UInt64, generation: UInt64) {
    let shouldQueue = lock.withLock {
      guard active else { return false }
      self.generation = generation
      guard !queued else { return false }
      queued = true; return true
    }
    guard shouldQueue else { return }
    // A queued host closure owns both its context and subscription. This retain
    // is distinct from the session's subscription reference and the C context.
    guard let owner = try? NativeHandle(retaining: subscription) else {
      Task { @MainActor [self] in finishWithoutDelivery() }; return
    }
    Task { @MainActor [self, owner] in deliver(owner) }
  }
  @MainActor private func take() -> UInt64? {
    lock.withLock { queued = false; return active ? generation : nil }
  }
  @MainActor private func finishWaiters() {
    let pending = waiters; waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
  @MainActor private func finishWithoutDelivery() { _ = take(); finishWaiters() }
  @MainActor private func deliver(_ subscription: NativeHandle) {
    defer { finishWaiters() }
    guard let generation = take(),
          tidyvnc_subscription_validate(subscription.raw, generation, nil) == UInt32(TIDYVNC_OK) else { return }
    action(subscription.raw, generation)
  }
  // Invalidate first. No later C callback can queue new host work, and any
  // existing MainActor task acknowledges its capture disposal before close.
  @MainActor func drain() async {
    if hasQueuedDelivery { await withCheckedContinuation { waiters.append($0) } }
  }
}

func retainNativeDelivery(_ context: UnsafeMutableRawPointer?) {
  guard let context else { return }; _ = Unmanaged<NativeDelivery>.fromOpaque(context).retain()
}
func releaseNativeDelivery(_ context: UnsafeMutableRawPointer?) {
  guard let context else { return }; Unmanaged<NativeDelivery>.fromOpaque(context).release()
}
func readyNativeDelivery(_ context: UnsafeMutableRawPointer?, _ subscription: UInt64, _ generation: UInt64) {
  guard let context else { return }
  Unmanaged<NativeDelivery>.fromOpaque(context).takeUnretainedValue().signal(subscription: subscription, generation: generation)
}

enum NativeDrain { case session, subscription, runtime, listener }
// Control-plane drain polling only, never frame/state polling. Suspension keeps
// MainActor responsive. Cleanup tasks are not cancelled by callers abandoning an
// await; deinit still only issues cancellation/release and never joins a worker.
func waitForNativeDrain(_ handle: NativeHandle, _ kind: NativeDrain) async throws {
  while true {
    let result = try checked(allowing: [.ok, .pending]) { error in
      switch kind {
      case .session: return tidyvnc_session_poll_drained(handle.raw, error)
      case .subscription: return tidyvnc_subscription_poll_drained(handle.raw, error)
      case .runtime: return tidyvnc_runtime_poll_drained(handle.raw, error)
      case .listener: return tidyvnc_listener_poll_drained(handle.raw, error)
      }
    }
    if result == .ok { return }
    try await Task.sleep(for: .milliseconds(2))
  }
}
