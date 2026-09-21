// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

@MainActor public final class NativeConnectionDraft: ObservableObject, Identifiable {
  public nonisolated let id = UUID()
  @Published public var shared: Bool?
  @Published public var reconnectOnError: Bool?
  @Published public private(set) var baseline: NativeConnectionOptions?
  @Published public private(set) var error: String?
  @Published public private(set) var needsReload = false
  @Published public private(set) var didApply = false
  public let initialShared: Bool, initialReconnectOnError: Bool
  private weak var session: NativeSession?
  private var observations: [AnyCancellable] = []
  private var stopped = false
  public init(session: NativeSession) {
    self.session = session; initialShared = session.initialShared; initialReconnectOnError = session.initialReconnectOnError
    observations = [session.$snapshot.sink { [weak self] snapshot in
      MainActor.assumeIsolated {
        guard let self, let baseline = self.baseline else { return }
        if baseline.generation != snapshot.generation || ![.idle,.closed,.failed].contains(snapshot.state) {
          self.needsReload = true; self.didApply = false; self.error = "The connection changed. Reload before applying."
        }
      }
    },session.$isClosing.sink { [weak self] closing in if closing { MainActor.assumeIsolated { self?.stop() } } }]
  }
  public var hasChanges: Bool { baseline.map { $0.shared != (shared ?? initialShared) || $0.reconnectOnError != (reconnectOnError ?? initialReconnectOnError) } ?? false }
  public var canReload: Bool { !stopped && session?.isClosing == false && session.map { [.idle,.closed,.failed].contains($0.snapshot.state) } == true }
  public var canApply: Bool { canReload && !needsReload && hasChanges }
  public func reload() {
    guard canReload, let session else { return }
    do {
      let value = try session.connectionOptions()
      guard value.editable else { throw NativeError(.busy,"Connection still active") }
      baseline = value; shared = value.shared == initialShared ? nil : value.shared
      reconnectOnError = value.reconnectOnError == initialReconnectOnError ? nil : value.reconnectOnError
      needsReload = false; error = nil; didApply = false
    } catch { self.error = "Disconnect and wait for the connection to close, then reload."; needsReload = true }
  }
  public func apply() {
    guard canApply, let session, let baseline else { return }
    do {
      try session.setConnectionOptions(shared:shared ?? initialShared,reconnectOnError:reconnectOnError ?? initialReconnectOnError,expected:baseline)
      self.baseline = try session.connectionOptions(); didApply = true; error = nil
    } catch { needsReload = true; self.error = "The connection or options changed. Reload before applying." }
  }
  public func cancel() { stop() }
  public func stop() { stopped = true; observations.removeAll() }
}
