// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

// One app-owned editor. Store revisions cover both profiles and recent history;
// a stale draft never silently overwrites either collection.
@MainActor public final class NativeProfileLibrary: ObservableObject {
  @Published public private(set) var profiles: [NativeConnectionProfile] = []
  @Published public var draft: NativeConnectionProfile?
  @Published public var gatewayText = ""
  @Published public private(set) var isBusy = false
  @Published public private(set) var hasLoaded = false
  @Published public private(set) var needsReload = false
  @Published public private(set) var error: NativeStorageError?
  @Published public private(set) var defaultsError: NativePreferencesError?
  @Published public private(set) var schema: [NativeEncodingSchema] = []
  @Published public private(set) var choices: [NativeEncodingChoice] = []
  private var baseline: NativeConnectionProfile?
  private var revision: UUID?
  private var defaults = NativePreferences()
  private let store: NativeProfileHistoryStore
  private let preferences: NativePreferencesStore
  @Published public private(set) var securityChoices: [NativeSecurityChoice] = []
  @Published public private(set) var securityDefaults: NativeSecuritySelection?
  private var operation: Task<Void, Never>?
  private var stopped = false
  public init(store: NativeProfileHistoryStore, preferences: NativePreferencesStore) {
    self.store = store; self.preferences = preferences
  }
  deinit { operation?.cancel() }
  public var hasChanges: Bool { draft != baseline || gatewayText != (baseline?.sshGateway?.canonicalURI ?? "") }
  public var canEdit: Bool { !stopped && !isBusy && hasLoaded && !needsReload }
  public var endpointIssue: NativeEndpointIssue? { NativeEndpoint.issue(for: draft?.endpoint ?? "") }
  public var gatewayIssue: String? {
    guard !gatewayText.isEmpty else { return nil }
    do {
      let gateway = try NativeSSHGateway(gatewayText)
      if endpointIssue == nil { _ = try NativeSSHTunnelRequest(endpoint:draft?.endpoint ?? "",gateway:gateway) }
      return nil
    } catch { return (error as? NativeTunnelError)?.description ?? NativeTunnelError.invalidRequest.description }
  }
  public var canSave: Bool {
    guard canEdit, hasChanges, gatewayIssue == nil, let draft else { return false }
    return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      !draft.name.utf8.contains(0) && draft.name.utf8.prefix(257).count <= 256 &&
      endpointIssue == nil && (draft.settings.fullscreen == nil || (try? draft.settings.fullscreen?.resolved(base:inheritedFullscreenPolicy)) != nil) && draft.settings.remoteResize?.isValid != false && draft.settings.scaling?.isValid != false && draft.settings.trustFiles?.isValid != false && draft.settings.security?.isValid != false
  }
  public var canUse: Bool { canEdit && !hasChanges && baseline != nil }
  public var inheritedFullscreenPolicy: NativeFullscreenPolicy { (try? defaults.fullscreen?.resolved()) ?? .builtIn }
  public var inheritedResizePolicy: NativeRemoteResizePolicy { (try? defaults.remoteResize?.resolved()) ?? .builtIn }
  public var inheritedShared: Bool { defaults.shared ?? false }
  public var inheritedReconnectOnError: Bool { defaults.reconnectOnError ?? true }
  public var inheritedTLSPriority: String { defaults.security?.tlsPriority ?? "" }
  public var inheritedSecurity: NativeSecuritySelection? { try? NativeSecuritySelection(defaults.security?.types) }
  public var inheritedTrustFiles: NativeTrustFiles { defaults.trustFiles ?? NativeTrustFiles() }
  public var inheritedScaling: NativeScaling { (try? defaults.scaling?.resolved()) ?? .builtIn }
  public var inheritedInput: NativeInputSettings { (try? defaults.input?.resolved()) ?? NativeInputSettings() }
  public var encodingValues: [NativeEncodingOption: NativeEncodingValue] {
    guard let base = try? defaults.encoding?.resolved() ?? NativeEncodingOptions(),
          let options = try? (draft?.settings.encoding ?? NativeEncodingPreferences()).resolved(base: base, source: .profile),
          let values = try? schema.map({ ($0.id, try options.value(for: $0.id)) }) else { return [:] }
    return Dictionary(uniqueKeysWithValues: values)
  }
  public func refreshIfClean() { if !needsReload && !hasChanges && !isBusy { reload() } }
  // Explicit reload discards the draft only after both reads succeed.
  public func reload() {
    guard !stopped, operation == nil else { return }
    let owner = store, preferences = preferences, selection = draft?.id
    isBusy = true; error = nil; defaultsError = nil
    operation = Task { @MainActor [weak self] in
      do {
        let snapshot = try await owner.read()
        let defaults = try await preferences.read()
        let schema = try NativeEncodingOptions.schema(), choices = try NativeEncodingOptions.choices()
        let securityChoices = try NativeSecuritySelection.choices(), securityDefaults = try NativeSecuritySelection()
        if let self, !self.stopped, !Task.isCancelled {
          self.profiles = snapshot.profiles; self.revision = snapshot.revision
          self.securityChoices = securityChoices; self.securityDefaults = securityDefaults
          self.defaults = defaults.values; self.schema = schema; self.choices = choices
          self.baseline = snapshot.profiles.first { $0.id == selection }
          self.draft = self.baseline; self.gatewayText = self.baseline?.sshGateway?.canonicalURI ?? ""; self.hasLoaded = true; self.needsReload = false
        }
      } catch {
        if let self, !self.stopped {
          self.failed(error); self.profiles = []; self.hasLoaded = false; self.needsReload = true
        }
      }
      self?.isBusy = false; self?.operation = nil
    }
  }
  public func select(_ id: UUID) {
    guard canEdit, !hasChanges, let value = profiles.first(where: { $0.id == id }) else { return }
    baseline = value; draft = value; gatewayText = value.sshGateway?.canonicalURI ?? ""; error = nil
  }
  public func newProfile() {
    guard canEdit, !hasChanges, profiles.count < NativeProfileHistoryStore.profileCapacity else { return }
    baseline = nil; draft = .init(name: "", endpoint: ""); gatewayText = ""; error = nil
  }
  public func cancelEdits() {
    guard !isBusy, !stopped else { return }
    draft = baseline; gatewayText = baseline?.sshGateway?.canonicalURI ?? ""
    if !needsReload { error = nil }
  }
  public func setEncoding(_ option: NativeEncodingOption, value: String?) {
    guard canEdit, draft != nil else { return }
    do {
      var patch = draft?.settings.encoding ?? NativeEncodingPreferences()
      if let value { try patch.set(option, value: value) } else { patch.clear(option) }
      draft?.settings.encoding = patch == NativeEncodingPreferences() ? nil : patch
      error = nil
    } catch { self.error = (error as? NativeError)?.status == .unsupported ? .unsupportedValue : .invalid }
  }
  public func inheritEncoding() {
    guard canEdit else { return }
    draft?.settings.encoding = nil; error = nil
  }
  public func save() {
    guard canSave, var submitted = draft else { return }
    submitted.sshGateway = try? NativeSSHGateway(gatewayText)
    mutate { [submitted] store, revision in try await store.upsert(submitted, expected: revision) }
  }
  public func deleteSelected() {
    guard canUse, let id = baseline?.id else { return }
    mutate { store, revision in try await store.deleteProfile(id: id, expected: revision) }
  }
  private func mutate(_ action: @escaping @Sendable (NativeProfileHistoryStore, UUID?) async throws -> NativeProfileHistorySnapshot) {
    let owner = store, revision = revision, selection = draft?.id
    isBusy = true; error = nil
    operation = Task { @MainActor [weak self] in
      do {
        let result = try await action(owner, revision)
        if let self, !self.stopped {
          self.profiles = result.profiles; self.revision = result.revision
          self.baseline = result.profiles.first { $0.id == selection }; self.draft = self.baseline; self.gatewayText = self.baseline?.sshGateway?.canonicalURI ?? ""
        }
      } catch { if let self, !self.stopped { self.failed(error) } }
      self?.isBusy = false; self?.operation = nil
    }
  }
  private func failed(_ failure: any Error) {
    defaultsError = failure as? NativePreferencesError
    error = defaultsError == nil ? (failure as? NativeStorageError) ?? .unavailable : nil
    needsReload = error != .invalidTLSPriority // Syntax rejection occurs before writes; uncertain commits still require reload.
  }
  public func stop() { stopped = true; operation?.cancel() }
  public func close() async { stop(); await operation?.value }
}
