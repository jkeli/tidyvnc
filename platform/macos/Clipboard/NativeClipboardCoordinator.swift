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
  private struct Job {
    let session: NativeSession
    let generation: UInt64, epoch: UInt64
    let change: Int
    let text: String? // nil withdraws protocol availability, never OS contents.
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
  private var pending: Job?
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
    pending = nil; operation?.cancel(); active = nil; registrations.removeAll()
  }
  // stop() synchronously gates all queued native access. Await the one admitted
  // transfer separately so app shutdown can also join its completion handling.
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
    epoch &+= 1; pending = nil; operation?.cancel(); observedChange = nil
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
      pending = nil; operation?.cancel()
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
    let change = pasteboard.changeCount
    guard observedChange != change else { return }
    do {
      let content = try pasteboard.read(expectedChange: change, maximumBytes: 256 * 1024)
      observedChange = change
      let text: String?
      switch content { case .text(let value): text = value; case .remote, .unavailable: text = nil }
      pending = Job(session: session, generation: session.generation, epoch: epoch, change: change, text: text)
      startPending()
    } catch NativePasteboardError.changed { /* Retry a stable snapshot next tick. */ }
    catch {
      observedChange = change
      // A non-text/invalid new copy must not leave the previous local offer live.
      pending = Job(session: session, generation: session.generation, epoch: epoch, change: change, text: nil)
      report(session, "The local clipboard could not be sent. Copy plain text of at most 256 KiB and try again.")
      startPending()
    }
  }
  private func current(_ job: Job) -> Bool {
    active === job.session && eligible(job.session) && sendEnabled && epoch == job.epoch &&
      job.generation == job.session.generation && pasteboard.changeCount == job.change
  }
  private func startPending() {
    guard operation == nil, let job = pending else { return }; pending = nil
    operation = Task { @MainActor [weak self] in
      guard let self else { return }
      if self.current(job) && !Task.isCancelled {
        do {
          if let text = job.text {
            _ = try await job.session.offerClipboard(text, expectedGeneration: job.generation)
            if self.current(job) { self.report(job.session, nil) }
          }
          else { _ = try await job.session.clearClipboard(expectedGeneration: job.generation) }
        } catch is CancellationError {}
        catch let error as NativeError where [.stale, .notConnected, .closing, .unfocused, .viewOnly, .disabled, .echo].contains(error.status) {}
        catch {
          if self.current(job) { self.report(job.session, "Clipboard transfer failed. Copy the text again to retry.") }
        }
      }
      self.operation = nil; self.startPending()
    }
  }
  private func receive(_ update: NativeClipboardUpdate, from session: NativeSession) {
    guard !stopped else { return }
    // Do not sample local contents while processing a remote update. Native
    // publication and route validation execute without a MainActor suspension.
    let candidates = registrations.values.compactMap(\.session).filter { eligible($0) }
    guard candidates.count == 1, candidates.first === session else { return }
    if update.kind == .rejected { report(session, "The remote clipboard text could not be accepted."); return }
    guard update.kind == .text, let text = update.text else { return }
    do {
      try session.validateClipboard(update.route, sending: false)
      pending = nil; operation?.cancel()
      let change = try pasteboard.writeRemote(text.text, maximumBytes: 256 * 1024)
      observedChange = change
      report(session, nil)
    } catch NativePasteboardError.changed { observedChange = nil }
    catch let error as NativeError where [.stale, .notConnected, .closing, .unfocused, .viewOnly, .disabled].contains(error.status) {}
    catch { report(session, "The remote clipboard could not be written on this Mac. Copy it again to retry.") }
  }
  private func report(_ session: NativeSession, _ message: String?) { registrations[ObjectIdentifier(session)]?.report(message) }
}
