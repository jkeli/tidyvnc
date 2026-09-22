// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

@MainActor public final class NativePreferencesDraft: ObservableObject {
  @Published public var values = NativePreferences()
  @Published public private(set) var snapshot: NativePreferencesSnapshot?
  @Published public private(set) var isBusy = false
  @Published public private(set) var error: NativePreferencesError?
  @Published public private(set) var needsReload = false
  @Published public private(set) var encodingSchema: [NativeEncodingSchema] = []
  @Published public private(set) var encodingChoices: [NativeEncodingChoice] = []
  private let store: NativePreferencesStore
  @Published public private(set) var securityChoices: [NativeSecurityChoice] = []
  @Published public private(set) var securityDefaults: NativeSecuritySelection?
  private var operation: Task<Void, Never>?
  private var stopped = false
  public init(store: NativePreferencesStore) { self.store = store }
  deinit { operation?.cancel() }
  public var hasChanges: Bool { snapshot.map { values != $0.values } ?? false }
  public var canApply: Bool { !stopped && !isBusy && !needsReload && snapshot != nil && hasChanges && (values.fullscreen == nil || (try? values.fullscreen?.resolved()) != nil) && values.remoteResize?.isValid != false && values.scaling?.isValid != false && values.trustFiles?.isValid != false && values.security?.isValid != false }
  public func reload() {
    guard !stopped, operation == nil else { return }
    isBusy = true; error = nil
    let owner = store
    operation = Task { @MainActor [weak self] in
      do {
        let result = try await owner.read()
        let schema = try NativeEncodingOptions.schema(), choices = try NativeEncodingOptions.choices()
        let securityChoices = try NativeSecuritySelection.choices(), securityDefaults = try NativeSecuritySelection()
        if let self, !self.stopped, !Task.isCancelled {
          self.snapshot = result; self.values = result.values; self.needsReload = false
          self.securityChoices = securityChoices; self.securityDefaults = securityDefaults
          self.encodingSchema = schema; self.encodingChoices = choices
        }
      } catch { self?.failed(error, reloading: true) }
      self?.isBusy = false; self?.operation = nil
    }
  }
  public func apply() {
    guard canApply, let snapshot else { return }
    let submitted = values, owner = store
    isBusy = true; error = nil
    operation = Task { @MainActor [weak self] in
      do {
        let result = try await owner.commit(submitted, expected: snapshot.revision)
        // A commit accepted despite cancellation is still a commit. Never report
        // rollback; a stopped UI simply stops publishing its completed result.
        if let self, !self.stopped {
          self.snapshot = result; self.needsReload = false
          if self.values == submitted { self.values = result.values }
        }
      } catch { self?.failed(error, reloading: false) }
      self?.isBusy = false; self?.operation = nil
    }
  }
  public func setEncoding(_ option: NativeEncodingOption, value: String) {
    guard !isBusy, !needsReload, !stopped else { return }
    do {
      var patch = values.encoding ?? NativeEncodingPreferences()
      try patch.set(option, value: value); values.encoding = patch; error = nil
    } catch { self.error = (error as? NativeError)?.status == .unsupported ? .unsupportedValue : .invalidValue }
  }
  private func failed(_ failure: any Error, reloading: Bool) {
    guard !stopped else { return }
    error = (failure as? NativePreferencesError) ?? .ioFailure
    // Includes uncertain writes: do not retry an old draft/revision blindly.
    needsReload = reloading || (error != .invalidValue && error != .invalidTLSPriority && error != .unsupportedValue)
  }
  public func cancel() {
    guard !isBusy else { return }
    if let snapshot { values = snapshot.values }
    if !needsReload { error = nil }
    // Cancel edits does not make a conflicted/corrupt store writable again.
  }
  public func restoreBuiltInDefaults() {
    guard !isBusy, !needsReload, snapshot != nil else { return }
    values = NativePreferences() // Only a draft until Apply.
    error = nil
  }
  public func stop() { stopped = true; operation?.cancel() }
  public func close() async { stop(); await operation?.value }
}

// One-time defaults loading for one newly created session. There is intentionally
// no subscription that could mutate an existing connection after an app save.
// Approved settings may be shared by incoming windows without rereading stores
// or files. This value has no session, credential owner or restoration payload.
public struct NativePreparedSessionDefaults: Sendable {
  public let configuration: NativeSessionConfiguration
  public let inherited: NativePreferences
  public let document: NativeDocumentResolution?
  public let invocation: NativeInvocationResolution?
}
public enum NativeSessionDefaultsPurpose: Sendable { case connection, listener }

@MainActor public final class NativeSessionDefaults: ObservableObject {
  @Published public private(set) var isReady = false
  @Published public private(set) var isLoading = false
  @Published public private(set) var error: NativePreferencesError?
  @Published public private(set) var inherited = NativePreferences()
  @Published public private(set) var overrides = NativePreferences()
  @Published public private(set) var profile: NativeConnectionProfile?
  @Published public private(set) var sshGateway: NativeSSHGateway?
  @Published public private(set) var profileError: NativeStorageError?
  @Published public private(set) var session: NativeSession?
  @Published public private(set) var prepared: NativePreparedSessionDefaults?
  @Published public private(set) var documentReview: NativeDocumentReview?
  @Published public private(set) var documentResolution: NativeDocumentResolution?
  @Published public private(set) var documentIssue: String?
  @Published public private(set) var documentMapping: NativeDocumentMonitorMapping?
  @Published public private(set) var invocationMapping: NativeInvocationMonitorMapping?
  @Published public private(set) var invocationResolution: NativeInvocationResolution?
  @Published public private(set) var invocationIssue: String?
  public let documentRequest: NativeDocumentOpenRequest?
  public let invocationRequest: NativeInvocationRequest?
  private let documentReader: any NativeDocumentReading
  private let documentDisplays: @MainActor () -> [NativeDisplayID]
  private let documentAvailableDisplays: (@MainActor () -> [NativeDisplayID])?
  private var documentMappingContext: NativeDocumentMonitorMapping?
  private let runtime: NativeRuntime
  private let store: NativePreferencesStore
  private let base: NativeSessionConfiguration
  private let purpose: NativeSessionDefaultsPurpose
  private let initialPreparation: NativePreparedSessionDefaults?
  private let profileStore: NativeProfileHistoryStore?
  private let profileID: UUID?
  private var operation: Task<Void, Never>?
  private var stopped = false
  public init(runtime: NativeRuntime, store: NativePreferencesStore, base: NativeSessionConfiguration = NativeSessionConfiguration(),
              profileStore: NativeProfileHistoryStore? = nil, profileID: UUID? = nil,
              invocation: NativeInvocationRequest? = nil,
              document: NativeDocumentOpenRequest? = nil, documentReader: any NativeDocumentReading = NativeDocumentFileReader(),
              documentDisplays: @escaping @MainActor () -> [NativeDisplayID] = { [] },
              documentAvailableDisplays: (@MainActor () -> [NativeDisplayID])? = nil,
              purpose: NativeSessionDefaultsPurpose = .connection, prepared: NativePreparedSessionDefaults? = nil) {
    self.runtime = runtime; self.store = store; self.base = base
    self.purpose = purpose; initialPreparation = prepared
    self.profileStore = profileStore; self.profileID = profileID
    invocationRequest = invocation
    documentRequest = document; self.documentReader = documentReader; self.documentDisplays = documentDisplays
    self.documentAvailableDisplays = documentAvailableDisplays
  }
  deinit { operation?.cancel() }
  public func load() {
    beginLoad(useBuiltIns: false)
  }
  private func beginLoad(useBuiltIns: Bool) {
    guard !stopped, !isReady, operation == nil else { return }
    isLoading = true; error = nil; profileError = nil; documentIssue = nil; documentReview = nil
    invocationResolution = nil; invocationIssue = nil; invocationMapping = nil
    documentMapping = nil; documentMappingContext = nil
    let owner = store, profileStore = profileStore, profileID = profileID
    operation = Task { @MainActor [weak self] in
      do {
        if let self, let ready = self.initialPreparation {
          guard !self.stopped, !Task.isCancelled else { self.finish(); return }
          self.documentResolution = ready.document; self.invocationResolution = ready.invocation
          try self.install(ready.inherited,profile:nil,configuration:ready.configuration)
          self.finish(); return
        }
        let values = useBuiltIns ? NativePreferences() : try await owner.read().values
        var profile: NativeConnectionProfile?
        if let profileID {
          guard let profileStore else { throw NativeStorageError.unavailable }
          profile = try await profileStore.profile(id: profileID)
        }
        guard let self, !self.stopped, !Task.isCancelled else { self?.finish(); return }
        // Validate native option support before opening an explicit source file.
        let prepared = try self.resolveConfiguration(values,profile:profile)
        let configuration = prepared.configuration
        if let request = self.documentRequest {
          let data: Data
          do { data = try await self.documentReader.read(request.url) }
          catch { self.documentFailed(error); self.finish(); return }
          guard !self.stopped, !Task.isCancelled else { self.finish(); return }
          do {
            let displays = self.documentDisplays()
            // Pending numeric selections resolve only after file precedence,
            // against the fresh display snapshot after source IO.
            let document = try NativeConnectionDocument(data:data)
            self.inherited = values; self.profile = profile
            do {
              let resolution = try NativeDocumentResolution(document:document,base:configuration,
                legacyDisplays:displays,workingDirectory:request.workingDirectory,compatibility:prepared.compatibility,
                availableDisplays:self.availableDocumentDisplays(),endpointUse:self.documentEndpointUse)
              self.documentMappingContext = try NativeDocumentMonitorMapping(document:document,base:configuration,
                workingDirectory:request.workingDirectory,legacyDisplays:displays,available:self.availableDocumentDisplays(),
                compatibility:prepared.compatibility,endpointUse:self.documentEndpointUse)
              self.documentReview = NativeDocumentReview(resolution:resolution,legacyDisplays:displays,
                monitorMapping:resolution.explicitMonitorMapping ? resolution.resolvedMonitorMapping : nil,
                availableDisplays:self.availableDocumentDisplays())
            } catch let failure as NativeDocumentResolutionFailure where failure.reason == .displayMappingRequired {
              // All ordinary fields were validated before monitor resolution.
              // Preserve this exact document and base; mapping does not reread IO.
              let mapping = try NativeDocumentMonitorMapping(document:document,base:configuration,
                workingDirectory:request.workingDirectory,legacyDisplays:displays,available:self.availableDocumentDisplays(),
                compatibility:prepared.compatibility,endpointUse:self.documentEndpointUse)
              guard !mapping.numbers.isEmpty else { throw failure }
              self.documentMappingContext = mapping; self.documentMapping = mapping
            }
          } catch { self.documentFailed(error) }
        } else if let candidate = prepared.invocation, let request = self.invocationRequest {
          let displays = self.documentDisplays(), available = self.availableDocumentDisplays()
          do {
            let resolution = try NativeInvocationResolution(prepared:candidate,endpoint:request.endpoint,
              legacyDisplays:displays,monitorMapping:request.monitorMapping,availableDisplays:available)
            self.invocationResolution = resolution
            try self.install(values,profile:profile,configuration:resolution.configuration)
          } catch let failure as NativeInvocationResolutionFailure where failure.reason == .displayMappingRequired {
            self.invocationMapping = try NativeInvocationMonitorMapping(prepared:candidate,request:request,
              legacyDisplays:displays,available:available)
            self.inherited = values; self.profile = profile
          }
        } else { try self.install(values, profile: profile, configuration:configuration) }
      } catch {
        if let self, !self.stopped {
          if let error = error as? NativeInvocationResolutionFailure { self.invocationIssue = error.description }
          else if let error = error as? NativeStorageError { self.profileError = error }
          else { self.error = (error as? NativePreferencesError) ?? .unavailable }
        }
      }
      self?.finish()
    }
  }
  private func finish() { isLoading = false; operation = nil }
  private func availableDocumentDisplays() -> [NativeDisplayID] {
    documentAvailableDisplays?() ?? documentDisplays()
  }
  private var documentEndpointUse: NativeDocumentEndpointUse { purpose == .listener ? .listenPort : .connection }
  public func editDocumentMapping(_ id: UUID) {
    guard !stopped, !isLoading, !isReady, documentReview?.id == id,
          let context = documentMappingContext, !context.numbers.isEmpty else { return }
    do {
      documentMapping = try NativeDocumentMonitorMapping(document:context.document,base:context.base,
        workingDirectory:context.workingDirectory,legacyDisplays:documentDisplays(),available:availableDocumentDisplays(),
        previous:documentReview?.monitorMapping,compatibility:context.compatibility,endpointUse:context.endpointUse)
      documentReview = nil; documentIssue = nil
    } catch { documentFailed(error) }
  }
  public func resolveDocumentMapping(_ id: UUID, assignments: [Int:NativeDisplayID]) {
    guard !stopped, !isLoading, !isReady, session == nil, let mapping = documentMapping, mapping.id == id else { return }
    let available = availableDocumentDisplays()
    guard Set(assignments.keys) == Set(mapping.numbers), assignments.values.allSatisfy({ available.contains($0) }) else {
      documentIssue = String(localized:"document.choose.a.connected.display.for.every.monitor.number.before.continuing", defaultValue:"Choose a connected display for every monitor number before continuing."); return
    }
    do {
      let resolution = try NativeDocumentResolution(document:mapping.document,base:mapping.base,
        workingDirectory:mapping.workingDirectory,monitorMapping:assignments,compatibility:mapping.compatibility,
        availableDisplays:available,endpointUse:mapping.endpointUse)
      documentReview = NativeDocumentReview(resolution:resolution,legacyDisplays:[],
        monitorMapping:assignments,availableDisplays:available)
      documentMapping = nil; documentIssue = nil
    } catch { documentFailed(error) }
  }
  public func cancelDocumentMapping(_ id: UUID) {
    guard !stopped, documentMapping?.id == id, !isReady else { return }
    documentMapping = nil; documentMappingContext = nil
    documentIssue = NativeDocumentOpenError.cancelled.description
  }
  private func documentFailed(_ failure: any Error) {
    guard !stopped else { return }
    if let failure = failure as? NativeInvocationResolutionFailure { invocationIssue = failure.description }
    else if let failure = failure as? NativeDocumentFailure { documentIssue = failure.description }
    else if let failure = failure as? NativeDocumentResolutionFailure { documentIssue = failure.line == 0 ? failure.description : String(localized:"document.error.description.line", defaultValue:"\(failure.description) (Line \(failure.line.formatted()))") }
    else if let failure = failure as? NativeDocumentOpenError { documentIssue = failure.description }
    else if failure is CancellationError { documentIssue = NativeDocumentOpenError.cancelled.description }
    else { documentIssue = String(localized:"document.the.connection.file.s.settings.could.not.be.applied.check.the.file", defaultValue:"The connection file's settings could not be applied. Check the file and compiled capabilities, then retry.") }
  }
  public func acceptDocument(_ id: UUID) {
    guard !stopped, !isLoading, !isReady, session == nil, let review = documentReview, review.id == id else { return }
    let topologyMatches = review.monitorMapping == nil ? documentDisplays() == review.legacyDisplays :
      Set(availableDocumentDisplays()) == Set(review.availableDisplays)
    guard topologyMatches else {
      if let context = documentMappingContext, !context.numbers.isEmpty {
        documentMapping = try? NativeDocumentMonitorMapping(document:context.document,base:context.base,
          workingDirectory:context.workingDirectory,legacyDisplays:documentDisplays(),available:availableDocumentDisplays(),
          previous:review.monitorMapping,compatibility:context.compatibility,endpointUse:context.endpointUse)
      }
      documentReview = nil; documentIssue = NativeDocumentOpenError.topologyChanged.description; return
    }
    do {
      let configuration = try review.resolution.configuration(acknowledging:Set(review.resolution.notices.map(\.line)))
      let gateway = try resolvedGateway(profile:profile,endpoint:review.resolution.endpoint)
      let created = purpose == .connection ? try runtime.makeSession(configuration:configuration) : nil
      // Metadata precedes session publication so subscribers set the file address
      // (including an explicit empty one) before enabling connection admission.
      sshGateway = gateway; documentResolution = review.resolution; documentReview = nil; documentMappingContext = nil
      prepared = .init(configuration:configuration,inherited:inherited,document:documentResolution,invocation:invocationResolution)
      session = created; isReady = true; documentIssue = nil
    } catch { documentReview = nil; documentFailed(error) }
  }
  public func cancelDocument(_ id: UUID) {
    guard documentReview?.id == id, !isReady else { return }
    documentReview = nil; documentIssue = NativeDocumentOpenError.cancelled.description
    documentMappingContext = nil
  }
  public func resolveInvocationMapping(_ id: UUID, assignments: [Int:NativeDisplayID]) {
    guard !stopped, !isLoading, !isReady, session == nil, let mapping = invocationMapping, mapping.id == id else { return }
    do {
      let resolution = try mapping.resolve(assignments,available:availableDocumentDisplays())
      invocationResolution = resolution
      try install(inherited,profile:profile,configuration:resolution.configuration)
      invocationMapping = nil; invocationIssue = nil
    } catch let failure as NativeInvocationResolutionFailure { invocationIssue = failure.description }
    catch { invocationIssue = String(localized:"document.the.command.line.settings.could.not.be.applied.review.the.options.and", defaultValue:"The command-line settings could not be applied. Review the options and retry.") }
  }
  public func cancelInvocationMapping(_ id: UUID) {
    guard !stopped, !isLoading, !isReady, invocationMapping?.id == id else { return }
    invocationMapping = nil; invocationIssue = String(localized:"document.command.line.display.selection.was.cancelled", defaultValue:"Command-line display selection was cancelled.")
  }
  private func resolveConfiguration(_ values: NativePreferences, profile: NativeConnectionProfile?) throws
    -> (configuration:NativeSessionConfiguration,compatibility:NativeCompatibilityState?,invocation:NativeInvocationPreparation?) {
    var configuration = try values.applying(to:base)
    if let profile { configuration = try profile.applying(to:configuration) }
    if let request = invocationRequest {
      let prepared = try NativeInvocationPreparation(options:request.options,endpoint:request.endpoint,base:configuration,
        legacyDisplays:[],workingDirectory:request.workingDirectory,monitorMapping:request.monitorMapping,deferDisplayMapping:true)
      return (prepared.configuration,prepared.overlay.compatibility,prepared)
    }
    return (configuration,nil,nil)
  }
  private func install(_ values: NativePreferences, profile: NativeConnectionProfile?, configuration: NativeSessionConfiguration) throws {
    guard session == nil else { throw NativePreferencesError.unavailable }
    let gateway = try resolvedGateway(profile:profile,endpoint:invocationResolution?.endpoint ?? profile?.endpoint ?? "")
    // Publish profile metadata before the session so the connection controller
    // installs its address before exposing Connect. Never apply a late profile.
    self.profile = profile
    sshGateway = gateway
    let created = purpose == .connection ? try runtime.makeSession(configuration:configuration) : nil
    prepared = .init(configuration:configuration,inherited:values,document:documentResolution,invocation:invocationResolution)
    session = created
    inherited = values; overrides = NativePreferences(); error = nil; isReady = true
  }
  private func resolvedGateway(profile: NativeConnectionProfile?, endpoint: String) throws -> NativeSSHGateway? {
    let gateway: NativeSSHGateway?
    if let invocationRequest { gateway = try invocationRequest.gateway(inheriting:profile?.sshGateway,endpoint:endpoint) }
    else { gateway = profile?.sshGateway }
    if gateway != nil && purpose == .listener {
      throw NativeInvocationResolutionFailure(reason:.tunnelListenUnsupported,argument:0)
    }
    return gateway
  }
  public func useBuiltInDefaults() {
    guard !stopped, !isLoading, !isReady, error != nil else { return }
    beginLoad(useBuiltIns: true) // Still requires a successful selected-profile read.
  }
  public func setClipboard(send: Bool? = nil, receive: Bool? = nil) throws {
    guard !stopped, isReady, let session else { throw NativePreferencesError.unavailable }
    try session.setClipboardPolicy(send: send ?? session.clipboardSendEnabled, receive: receive ?? session.clipboardReceiveEnabled)
    if let send { overrides.clipboardSend = send }
    if let receive { overrides.clipboardReceive = receive }
  }
  public func stop() { stopped = true; invocationMapping = nil; documentReview = nil; documentMapping = nil; documentMappingContext = nil; operation?.cancel() }
  public func close() async { stop(); await operation?.value; try? await session?.close() }
}
