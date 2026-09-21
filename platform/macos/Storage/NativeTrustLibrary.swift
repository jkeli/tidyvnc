// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

public func nativeTrustStorageMessage(_ error: NativeStorageError) -> String {
  switch error {
  case .conflict: return "Saved trust decisions changed elsewhere. Reload before making another change."
  case .busy: return "Another window or process is updating trust decisions. Reload and try again."
  case .denied: return "Access to saved trust decisions was denied. Check access and reload."
  case .futureSchema, .unsupportedFields, .unsupportedValue: return "Saved trust decisions require an unsupported format. Existing data has been preserved."
  case .corrupt, .invalid: return "Saved trust decisions could not be read or validated. Existing data has been preserved."
  case .tooLarge, .resourceLimit: return "The saved trust decisions exceed the supported size or count."
  case .cancelled, .ioFailure: return "The trust decision could not be confirmed. Reload to check its saved state before trying again."
  default: return "Saved trust decisions are unavailable. Reload to try again."
  }
}
@MainActor public final class NativeTrustLibrary: ObservableObject {
  @Published public private(set) var snapshot: NativeSavedTrustSnapshot?
  @Published public private(set) var isWorking = false
  @Published public private(set) var needsReload = false
  @Published public private(set) var message: String?
  public var entries: [NativeSavedTrustEntry] { snapshot?.entries ?? [] }
  public var kind: NativeTrustKind { store.kind }
  private let store: NativeTrustStore
  private var work: Task<Void,Never>?
  private var stopped = false
  public init(store: NativeTrustStore) { self.store = store }
  public func reload() {
    guard !stopped, work == nil else { return }
    isWorking = true; message = nil
    work = Task { [weak self, store] in
      defer { self?.work = nil; self?.isWorking = false }
      do {
        let snapshot = try await store.read()
        guard let self, !self.stopped, !Task.isCancelled else { return }
        self.snapshot = snapshot; self.needsReload = false
      } catch { self?.failed(error) }
    }
  }
  public func forget(_ id: String) {
    guard !stopped, work == nil, !needsReload, let snapshot,
          let entry = snapshot.entries.first(where: { $0.id == id }), !entry.isForgotten else { return }
    forget(scope: entry.scope,revision: snapshot.revision)
  }
  public func forgetDestination(_ endpoint: String) {
    guard !stopped, work == nil, !needsReload, let snapshot else { return }
    do { forget(scope: try NativeTrustScope(endpoint: endpoint,kind: kind),revision: snapshot.revision) }
    catch { failed(error) }
  }
  private func forget(scope: NativeTrustScope,revision: NativeTrustRevision) {
    isWorking = true; message = nil
    work = Task { [weak self, store] in
      defer { self?.work = nil; self?.isWorking = false }
      do {
        let result = try await store.forget(scope: scope,expected: revision)
        guard let self, !self.stopped, !Task.isCancelled else { return }
        self.snapshot = result.snapshot; self.needsReload = result.durabilityUncertain
        self.message = result.durabilityUncertain ? "The decision was written, but its durability could not be confirmed. Reload to check it." : "Forgot the saved key. This destination will ask again when identity verification is needed. Existing connections are unchanged."
      } catch { self?.failed(error) }
    }
  }
  private func failed(_ error: Error) {
    guard !stopped, !Task.isCancelled else { return }
    needsReload = true; message = nativeTrustStorageMessage(error as? NativeStorageError ?? .unavailable)
  }
  public func stop() { stopped = true; work?.cancel() }
  public func close() async { stop(); await work?.value }
}
