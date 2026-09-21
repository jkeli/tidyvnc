// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

// One app-wide presentation/operation owner. Connection success enqueues a
// bounded address only; no disk IO or await extends the connection operation.
@MainActor public final class NativeRecentHistory: ObservableObject {
  @Published public private(set) var endpoints: [String] = []
  @Published public private(set) var isBusy = false
  @Published public private(set) var error: NativeStorageError?
  @Published public private(set) var hasLoaded = false
  @Published public private(set) var importOfferDismissed = false
  @Published private var importEligible = false
  public var canImportHistory: Bool { canEdit && importEligible }
  public func dismissImportOffer() { importOfferDismissed = true }
  private let store: NativeProfileHistoryStore
  private var revision: UUID?
  private enum Request: Sendable { case read, record(String), remove(String, UUID?), clear(UUID?) }
  private var operation: Task<Void, Never>?
  private var pending: [String] = [] // Oldest first, coalesced to latest 20.
  private var refreshPending = false
  private var stopped = false
  public init(store: NativeProfileHistoryStore) { self.store = store }
  deinit { operation?.cancel() }
  public var canEdit: Bool { !stopped && !isBusy && hasLoaded && error == nil }
  public func reload() {
    guard !stopped else { return }
    guard operation == nil else { refreshPending = true; return }
    begin(.read)
  }
  public func recordSuccessful(_ endpoint: String) {
    guard !stopped else { return }
    guard !endpoint.isEmpty, endpoint.utf8.prefix(4097).count <= 4096, !endpoint.utf8.contains(0) else { error = .invalid; return }
    pending.removeAll(where: { $0 == endpoint }); pending.append(endpoint)
    pending = Array(pending.suffix(NativeProfileHistoryStore.historyCapacity))
    advance()
  }
  public func remove(_ endpoint: String) {
    guard canEdit, endpoints.contains(endpoint) else { return }
    begin(.remove(endpoint, revision))
  }
  public func clear() {
    guard canEdit, !endpoints.isEmpty else { return }
    begin(.clear(revision))
  }
  private func advance() {
    guard !stopped, operation == nil, error == nil else { return }
    if !pending.isEmpty { begin(.record(pending.removeFirst())) }
    else if refreshPending { refreshPending = false; begin(.read) }
  }
  private func begin(_ request: Request) {
    isBusy = true; error = nil
    let owner = store
    operation = Task { @MainActor [weak self] in
      do {
        let snapshot: NativeProfileHistorySnapshot
        switch request {
        case .read: snapshot = try await owner.read()
        case .record(let endpoint):
          let current = try await owner.read()
          snapshot = try await owner.recordRecent(endpoint, expected: current.revision)
        case .remove(let endpoint, let revision): snapshot = try await owner.removeRecent(endpoint, expected: revision)
        case .clear(let revision): snapshot = try await owner.clearHistory(expected: revision)
        }
        if let self, !self.stopped {
          self.revision = snapshot.revision; self.endpoints = snapshot.recentEndpoints; self.hasLoaded = true
          self.importEligible = snapshot.canImportHistory
        }
      } catch {
        if let self, !self.stopped {
          self.importEligible = false
          self.error = (error as? NativeStorageError) ?? .ioFailure
          self.refreshPending = false // No automatic retry loop after failure.
          if case .record(let endpoint) = request, !self.pending.contains(endpoint) {
            self.pending.insert(endpoint, at: 0)
            self.pending = Array(self.pending.suffix(NativeProfileHistoryStore.historyCapacity))
          }
          if case .read = request { self.hasLoaded = false; self.endpoints = []; self.revision = nil }
        }
      }
      self?.operation = nil; self?.isBusy = false; self?.advance()
    }
  }
  public func stop() {
    guard !stopped else { return }
    stopped = true; importEligible = false; pending.removeAll(); refreshPending = false; operation?.cancel()
  }
  public func close() async { stop(); await operation?.value }
}
