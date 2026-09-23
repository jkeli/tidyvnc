// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

@MainActor public final class NativeClipboardCoordinator {
  private final class Registration {
    weak var session: NativeSession?
    let report: (String?) -> Void
    var subscriptions = Set<AnyCancellable>()
    init(_ session: NativeSession, _ report: @escaping (String?) -> Void) { self.session = session; self.report = report }
  }
  private struct RemoteJob {
    let session: NativeSession
    let update: NativeClipboardUpdate
    let epoch: UInt64
  }
  private let pasteboard: any NativePasteboardAccess
  private let automaticPolling: Bool
  private var registrations: [ObjectIdentifier: Registration] = [:]
  private weak var active: NativeSession?
  private var applicationActive = true
  private var stopped = false, reconciliationQueued = false
  private var polling: Task<Void, Never>?
  private var epoch: UInt64 = 0
  private var observedChange: Int?
  private var sendEnabled = false
  private var pendingRemote: RemoteJob?
  private var pollRequested = false
  private var operation: Task<Void, Never>?
  public init(pasteboard: any NativePasteboardAccess = NativePasteboard(), automaticPolling: Bool = true) {
    self.pasteboard = pasteboard; self.automaticPolling = automaticPolling
  }
  deinit { polling?.cancel(); operation?.cancel() }
  public func register(_ session: NativeSession, onStatus: @escaping (String?) -> Void = { _ in }) {
    guard !stopped, registrations[ObjectIdentifier(session)] == nil else { return }
    let entry = Registration(session, onStatus); registrations[ObjectIdentifier(session)] = entry
    let changes = [session.$isFocused.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      session.$isClosing.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      session.$isViewOnly.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      session.$snapshot.map(\.state).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      session.$clipboardSendEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      session.$clipboardReceiveEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher()]
    Publishers.MergeMany(changes).sink { [weak self] in MainActor.assumeIsolated { self?.routingChanged() } }.store(in: &entry.subscriptions)
    // Registration must not replay a cached remote copy over a newer OS copy.
    session.$clipboard.dropFirst().sink { [weak self, weak session] update in MainActor.assumeIsolated {
      if let session, let update { self?.receive(update, from: session) }
    } }.store(in: &entry.subscriptions)
    scheduleReconciliation()
  }
  public func unregister(_ session: NativeSession) {
    registrations.removeValue(forKey: ObjectIdentifier(session)); reconcile()
  }
  public func setApplicationActive(_ enabled: Bool) {
    applicationActive = enabled
    if !enabled {
      // Also invalidates already-admitted sends and delayed remote replies.
      for entry in registrations.values { try? entry.session?.setFocused(false) }
    }
    reconcile()
  }
  public func stop() {
    stopped = true; polling?.cancel(); polling = nil
    pendingRemote = nil; pollRequested = false; operation?.cancel(); active = nil; registrations.removeAll()
  }
  // Cancellation skips queued native access. An already executing OS call cannot
  // be interrupted; close drains it asynchronously and discards its result.
  public func close() async { stop(); await operation?.value }
  private func scheduleReconciliation() {
    guard !stopped, !reconciliationQueued else { return }
    reconciliationQueued = true
    // Published emits before storing its value. Reconcile next actor turn and
    // coalesce focus/state changes, rather than reading the old property value.
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.reconciliationQueued = false; self.reconcile()
    }
  }
  private func routingChanged() {
    // Invalidate immediately even if focus loses/regains or policy toggles twice
    // before the coalesced reconciliation runs. Final-state equality is not proof
    // that pending clipboard work still belongs to the same focus interval.
    epoch &+= 1; pendingRemote = nil; pollRequested = false; operation?.cancel(); observedChange = nil
    scheduleReconciliation()
  }
  private func eligible(_ session: NativeSession) -> Bool {
    applicationActive && !stopped && session.isFocused && !session.isViewOnly && !session.isClosing && session.snapshot.state == .connected
  }
  private func reconcile() {
    guard !stopped else { return }
    registrations = registrations.filter { $0.value.session != nil }
    let candidates = registrations.values.compactMap(\.session).filter { eligible($0) }
    // Ambiguous host focus never routes clipboard data to an arbitrary session.
    let selected = candidates.count == 1 ? candidates[0] : nil
    let enabled = selected?.clipboardSendEnabled == true
    if active !== selected || sendEnabled != enabled {
      active = selected; sendEnabled = enabled; epoch &+= 1; observedChange = nil
      pendingRemote = nil; pollRequested = false; operation?.cancel()
    }
    if active != nil && sendEnabled && automaticPolling && polling == nil {
      polling = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
          self?.poll()
        }
      }
    } else if active == nil || !sendEnabled { polling?.cancel(); polling = nil }
    pollCurrent()
  }
  // Exposed for an event-driven host and deterministic adapter tests. The app
  // uses one cancellable 250 ms observation task while a desktop can send.
  public func poll() { reconcile() }
  private func pollCurrent() {
    guard let session = active, eligible(session), sendEnabled else { return }
    pollRequested = true
    startPending()
  }
  private func current(_ session: NativeSession, generation: UInt64, epoch: UInt64) -> Bool {
    !Task.isCancelled && active === session && eligible(session) && sendEnabled &&
      self.epoch == epoch && generation == session.generation
  }
  private func startPending() {
    // One operation owns all native access, including reads and remote writes.
    // Poll ticks collapse to a bit and remote updates to the latest value. Never
    // launch another read just because the previous OS request was cancelled.
    guard !stopped, operation == nil, pendingRemote != nil || pollRequested else { return }
    operation = Task { @MainActor [weak self] in
      guard let self else { return }
      if let remote = self.pendingRemote {
        self.pendingRemote = nil
        await self.writeRemote(remote)
      } else {
        self.pollRequested = false
        if let session = self.active {
          await self.readLocal(session, generation: session.generation, epoch: self.epoch)
        }
      }
      self.operation = nil
      self.startPending()
    }
  }
  private func readLocal(_ session: NativeSession, generation: UInt64, epoch: UInt64) async {
    guard current(session, generation: generation, epoch: epoch) else { return }
    var sampledChange: Int?
    do {
      let change = try await pasteboard.currentChange()
      guard current(session, generation: generation, epoch: epoch), observedChange != change else { return }
      sampledChange = change
      let content = try await pasteboard.read(expectedChange: change, maximumBytes: 256 * 1024)
      guard current(session, generation: generation, epoch: epoch) else { return }
      let latest = try await pasteboard.currentChange()
      guard current(session, generation: generation, epoch: epoch) else { return }
      guard latest == change else { pollRequested = true; return }
      observedChange = change
      switch content {
      case .text(let text):
        _ = try await session.offerClipboard(text, expectedGeneration: generation)
        if current(session, generation: generation, epoch: epoch) { report(session, nil) }
      case .remote, .unavailable:
        _ = try await session.clearClipboard(expectedGeneration: generation)
      }
    } catch is CancellationError {
    } catch NativePasteboardError.changed {
      // Retry on the next tick rather than spinning against an unstable owner.
    } catch let error as NativeError where [.stale, .notConnected, .closing, .unfocused, .viewOnly, .disabled, .echo].contains(error.status) {
    } catch {
      guard current(session, generation: generation, epoch: epoch) else { return }
      // Failures from an obsolete clipboard snapshot must not clear a newer offer
      // or display an error for a connection that no longer owns the operation.
      guard let change = sampledChange,
            let latest = try? await pasteboard.currentChange(), latest == change,
            current(session, generation: generation, epoch: epoch) else { return }
      observedChange = change
      if error is NativePasteboardError {
        report(session, String(localized:"clipboard.recovery.the.local.clipboard.could.not.be.sent.copy.plain.text.of.at", defaultValue:"The local clipboard could not be sent. Copy plain text of at most 256 KiB and try again."))
        _ = try? await session.clearClipboard(expectedGeneration: generation)
      } else {
        report(session, String(localized:"clipboard.recovery.clipboard.transfer.failed.copy.the.text.again.to.retry", defaultValue:"Clipboard transfer failed. Copy the text again to retry."))
      }
    }
  }
  private func receive(_ update: NativeClipboardUpdate, from session: NativeSession) {
    guard !stopped else { return }
    let candidates = registrations.values.compactMap(\.session).filter { eligible($0) }
    guard candidates.count == 1, candidates.first === session else { return }
    if update.kind == .rejected { report(session, String(localized:"clipboard.recovery.the.remote.clipboard.text.could.not.be.accepted", defaultValue:"The remote clipboard text could not be accepted.")); return }
    guard update.kind == .text, update.text != nil else { return }
    do { try session.validateClipboard(update.route, sending: false) } catch { return }
    epoch &+= 1
    operation?.cancel()
    pollRequested = false
    pendingRemote = RemoteJob(session: session, update: update, epoch: epoch)
    startPending()
  }
  private func writeRemote(_ job: RemoteJob) async {
    let session = job.session
    guard !stopped, !Task.isCancelled, epoch == job.epoch, eligible(session),
          let text = job.update.text else { return }
    do {
      try session.validateClipboard(job.update.route, sending: false)
      let change = try await pasteboard.writeRemote(text.text, maximumBytes: 256 * 1024)
      guard !stopped, !Task.isCancelled, epoch == job.epoch, eligible(session) else { return }
      try session.validateClipboard(job.update.route, sending: false)
      observedChange = change
      report(session, nil)
    } catch is CancellationError {
    } catch NativePasteboardError.changed { observedChange = nil }
    catch let error as NativeError where [.stale, .notConnected, .closing, .unfocused, .viewOnly, .disabled].contains(error.status) {}
    catch {
      if !stopped, !Task.isCancelled, epoch == job.epoch, eligible(session) {
        report(session, String(localized:"clipboard.recovery.the.remote.clipboard.could.not.be.written.on.this.mac.copy.it", defaultValue:"The remote clipboard could not be written on this Mac. Copy it again to retry."))
      }
    }
  }
  private func report(_ session: NativeSession, _ message: String?) { registrations[ObjectIdentifier(session)]?.report(message) }
}
