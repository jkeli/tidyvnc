// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

@MainActor public protocol NativeTrustTarget: AnyObject {
  var prompt: NativePrompt? { get }
  var generation: UInt64 { get }
  var isClosing: Bool { get }
  func replyTrust(to request: NativePrompt, allowed: Bool) throws
}
extension NativeSession: NativeTrustTarget {}

@MainActor public final class NativeCertificateTrust: ObservableObject {
  @Published public private(set) var inspection: NativeLegacyTrustMatch?
  @Published public private(set) var savedInspection: NativeSavedTrustInspection?
  @Published public private(set) var savedIssue: NativeStorageError?
  @Published public private(set) var notice: String?
  @Published public private(set) var needsReload = false
  @Published public private(set) var issue: NativeTrustStoreIssue?
  @Published public private(set) var isWorking = false
  private weak var target: (any NativeTrustTarget)?
  private let store: NativeLegacyTrustStore?
  private let savedStore: NativeTrustStore?
  private var scope: NativeTrustScope?
  private var hostScope: NativeTrustScope?
  private let hostKeyStore: NativeTrustStore?
  private var latest: NativePrompt?
  private var work: Task<Void,Never>?
  private var epoch: UInt64 = 0
  private var suspended = false, stopped = false
  public init(store: NativeLegacyTrustStore? = nil, savedStore: NativeTrustStore? = nil, hostKeyStore: NativeTrustStore? = nil) { self.store = store; self.savedStore = savedStore; self.hostKeyStore = hostKeyStore }
  public func bind(_ target: any NativeTrustTarget) { self.target = target }
  public func beginAttempt(endpoint: String? = nil, routeIdentity: String = "") {
    suspended = false; scope = endpoint.flatMap { try? NativeTrustScope(endpoint: $0,routeIdentity: routeIdentity) }
    hostScope = endpoint.flatMap { try? NativeTrustScope(endpoint: $0,routeIdentity: routeIdentity,kind: .hostKey) }; inspect(nil)
  }
  public func inspect(_ request: NativePrompt?) {
    epoch &+= 1; work?.cancel(); latest = request; inspection = nil; issue = nil; savedInspection = nil; savedIssue = nil; notice = nil; needsReload = false
    if work == nil { startIfNeeded() }
  }
  private func current(_ request: NativePrompt, ticket: UInt64) -> Bool {
    !stopped && !suspended && epoch == ticket && !Task.isCancelled &&
      target?.isClosing == false && target?.generation == request.generation && target?.prompt == request
  }
  private func startIfNeeded() {
    guard !stopped, !suspended, let request = latest, request.kind == .certificate || request.kind == .hostKey,
          NativeTrustPresentation(request).mayConnectOnce else { return }
    let store = store, savedStore = request.kind == .hostKey ? hostKeyStore : savedStore, scope = request.kind == .hostKey ? hostScope : scope
    let ticket = epoch; isWorking = true
    work = Task { [weak self] in
      defer { self?.finish(ticket: ticket) }
      do {
        if let savedStore {
          guard let scope else { throw NativeStorageError.invalid }
          let saved: NativeSavedTrustInspection
          if request.kind == .hostKey { saved = try await savedStore.inspectHostKey(scope: scope,key: request.identity) }
          else { saved = try await savedStore.inspect(scope: scope,certificate: request.identity) }
          guard let self, self.current(request,ticket: ticket) else { return }
          self.savedInspection = saved
          if saved.state == .match { try self.target?.replyTrust(to: request,allowed: true); return }
          // Explicit endpoint decisions take precedence. Forgetting never revives
          // a pre-existing broad legacy exception for this destination.
          if saved.state != .absent { return }
        }
        if request.kind == .hostKey { return }
        guard let store else { throw NativeTrustStoreIssue.unavailable }
        let result = try await store.lookup(host: request.serverName, certificate: request.identity)
        guard let self, self.current(request,ticket: ticket) else { return }
        self.inspection = result
        if result.state == .match {
          // Preserve the legacy exception decision only for this currently
          // pending certificate and after the non-overridable policy gate.
          try self.target?.replyTrust(to: request, allowed: true)
        }
      } catch {
        guard let self, self.current(request,ticket: ticket) else { return }
        if let saved = error as? NativeStorageError { self.savedIssue = saved; self.needsReload = true }
        else { self.issue = error as? NativeTrustStoreIssue ?? .unavailable }
      }
    }
  }
  private func finish(ticket: UInt64) {
    work = nil; isWorking = false
    if epoch != ticket { startIfNeeded() }
  }
  public func canConnectOnce(_ request: NativePrompt) -> Bool {
    !isWorking && current(request,ticket: epoch) && NativeTrustPresentation(request).mayConnectOnce
  }
  public func connectOnce(_ request: NativePrompt) throws {
    guard canConnectOnce(request), let target else { throw NativeError(.stale,"Inactive trust request") }
    try target.replyTrust(to: request, allowed: true)
  }
  public func canSave(_ request: NativePrompt) -> Bool {
    canConnectOnce(request) && (request.kind == .hostKey ? hostKeyStore != nil && hostScope != nil : savedStore != nil && scope != nil) &&
      savedInspection != nil && savedInspection?.state != .match && savedIssue == nil && !needsReload
  }
  public var replacesSavedKey: Bool { savedInspection?.state == .changed }
  public func reload() { if work == nil, let latest { inspect(latest) } }
  public func saveAndConnect(_ request: NativePrompt) { change(request,forget: false) }
  public func forget(_ request: NativePrompt) { change(request,forget: true) }
  private func change(_ request: NativePrompt, forget: Bool) {
    guard canSave(request), let savedStore = request.kind == .hostKey ? hostKeyStore : savedStore,
          let scope = request.kind == .hostKey ? hostScope : scope, let saved = savedInspection else { return }
    let ticket = epoch; isWorking = true; notice = nil; savedIssue = nil
    work = Task { [weak self] in
      defer { self?.finish(ticket: ticket) }
      do {
        let result: NativeTrustCommit
        if forget { result = try await savedStore.forget(scope: scope,expected: saved.revision) }
        else if request.kind == .hostKey { result = try await savedStore.saveHostKey(scope: scope,key: request.identity,replacing: saved.state == .changed,expected: saved.revision) }
        else { result = try await savedStore.save(scope: scope,certificate: request.identity,status: request.certificateStatus,
          replacing: saved.state == .changed,expected: saved.revision) }
        guard let self, self.current(request,ticket: ticket) else { return }
        self.inspection = nil
        self.savedInspection = .init(state: forget ? .forgotten : .match,revision: result.snapshot.revision,
          expectedFingerprint: forget ? nil : saved.receivedFingerprint,receivedFingerprint: saved.receivedFingerprint)
        if result.durabilityUncertain {
          self.needsReload = true
          self.notice = "The decision was written, but its durability could not be confirmed. Reload to check the saved decision."
        } else if forget {
          self.notice = request.kind == .hostKey ? "Forgot the saved server key for this destination. Compare the key again before continuing." : "Forgot the saved key for this destination. Older host-wide exceptions will not be reused here."
        } else { try self.target?.replyTrust(to: request,allowed: true) }
      } catch {
        guard let self, self.current(request,ticket: ticket) else { return }
        self.savedIssue = error as? NativeStorageError ?? .ioFailure; self.needsReload = true
      }
    }
  }
  public func cancel() { suspended = true; inspect(nil) }
  public func stop() { stopped = true; cancel(); target = nil }
  public func close() async { stop(); await work?.value }
  public var issueMessage: String? {
    if let savedIssue { return nativeTrustStorageMessage(savedIssue) }
    guard let issue else { return nil }
    switch issue {
    case .denied: return "Saved certificate exceptions could not be read because access was denied."
    case .unsafeFile: return "The saved certificate exception file has unsafe ownership, permissions or file type."
    case .corrupt: return "The saved certificate exception file is malformed. It has not been changed."
    case .unsupportedFormat, .unsupportedDigest: return "The saved certificate exceptions use an unsupported format or digest."
    case .tooLarge: return "The saved certificate exception file exceeds the supported size."
    case .changed: return "The saved certificate exceptions changed while being read. Connect again to check them."
    case .cancelled, .closed: return "The certificate exception check was cancelled."
    case .unavailable: return "Saved certificate exceptions could not be checked."
    }
  }
}
