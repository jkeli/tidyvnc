// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import TidyVNCNative

struct ConnectionProblem: Identifiable, Equatable {
  let id = UUID()
  let generation: UInt64
  let issue: NativeConnectionIssue
}
// A reverse source port is an observation, not an outbound destination or saved
// server identity. This request stays in memory and never enters scene restoration.
@MainActor struct ReverseConnectionRequest {
  let listener: NativeListener
  let peer: NativeIncomingPeer
  var invocation: NativeInvocationRequest? = nil
  var credentials: NativeLaunchCredentialInputs? = nil
  var prepared: NativePreparedSessionDefaults? = nil
  var endpoint: String {
    let host = peer.address.host.contains(":") ? "[\(peer.address.host)]" : peer.address.host
    return "\(host)::\(peer.address.port)"
  }
}

// A tunnel belongs to exactly one connection attempt. Cleanup runs in its own
// uncancelled task and is shared by failure, disconnect, close and deallocation.
@MainActor private final class ConnectionTunnelAttempt {
  let owner: any NativeTunnelOwning
  let session: NativeSession
  let initialGeneration: UInt64
  private(set) var admitted = false
  private(set) var stopping = false
  private var observation: Task<Void,Never>?
  private var cleanup: Task<Void,Never>?
  init(owner: any NativeTunnelOwning, session: NativeSession) {
    self.owner = owner; self.session = session; initialGeneration = session.generation
  }
  func connect(destination: NativeConnectionDestination, onExit: @escaping @MainActor () -> Void) async throws -> NativeCompletion {
    let route = try await owner.start()
    try Task.checkCancellation()
    guard !stopping, route.endpoint.utf8.elementsEqual(destination.endpoint.utf8),
          route.routeIdentity == destination.sshGateway?.routeIdentity else { throw NativeTunnelError.invalidRequest }
    let owner = owner
    observation = Task { [weak self] in
      let exit = await owner.waitForExit()
      guard exit != nil, let self, !self.stopping, !Task.isCancelled else { return }
      onExit()
    }
    admitted = true
    return try await session.connect(endpoint:destination.endpoint,through:route.localEndpoint,routeIdentity:route.routeIdentity)
  }
  func drain() -> Task<Void,Never> {
    if let cleanup { return cleanup }
    stopping = true; observation?.cancel()
    let owner = owner, session = session, observation = observation
    let task = Task {
      await Self.drain(session)
      await owner.close()
      await observation?.value
    }
    cleanup = task; return task
  }
  private static func drain(_ session: NativeSession) async {
    if session.isClosing { try? await session.close(); return }
    do { _ = try await session.disconnect() }
    catch let error as NativeError where error.status == .closing || error.status == .notConnected {
      // The native worker may already be finishing. Its terminal snapshot is
      // published only after transport/decoder/observer drain; preserve reuse.
      while !session.isClosing && ![.idle,.closed,.failed].contains(session.snapshot.state) {
        try? await Task.sleep(for:.milliseconds(10))
      }
      if session.isClosing { try? await session.close() }
    } catch {
      if session.isClosing || ![.idle,.closed,.failed].contains(session.snapshot.state) { try? await session.close() }
    }
  }
  deinit {
    observation?.cancel()
    if cleanup == nil {
      let owner = owner, session = session, observation = observation
      Task { @MainActor in
        await Self.drain(session); await owner.close(); await observation?.value
      }
    }
  }
}

@MainActor final class ConnectionModel: ObservableObject {
  private let reverse: ReverseConnectionRequest?
  private var reverseAttempted = false
  var isReverse: Bool { reverse != nil }
  var session: NativeSession? { defaults?.session }
  let defaults: NativeSessionDefaults?
  let history: NativeRecentHistory?
  private weak var displays: NativeDisplayService?
  let trust: NativeCertificateTrust
  private var trustObservation: AnyCancellable?
  private var promptObservation: AnyCancellable?
  let credentials: NativeAuthenticationCredentials
  private var credentialsObservation: AnyCancellable?
  let desktopCommands = NativeDesktopCommands()
  let fullscreen: NativeFullscreenState
  @Published private(set) var fullscreenDraft: NativeFullscreenDraft?
  private var fullscreenObservation: AnyCancellable?
  @Published private(set) var informationID: UUID?
  @Published private(set) var showsStatistics = false { didSet { fullscreen.showsStatistics = showsStatistics } }
  private var commandsObservation: AnyCancellable?
  let documentSave = NativeDocumentSaveState()
  private var documentSaveObservation: AnyCancellable?
  let input = NativeInputState()
  @Published private(set) var inputDraft: NativeInputDraft?
  let scaling = NativeScalingState()
  @Published private(set) var resizePolicyDraft: NativeRemoteResizePolicyDraft?
  private var resizeObservation: AnyCancellable?
  @Published private(set) var remoteResizeDraft: NativeRemoteResizeDraft?
  private var remoteResizeCleanup: Task<Void,Never>?
  @Published private(set) var scalingDraft: NativeScalingDraft?
  @Published var endpoint = "" { didSet { endpointIssue = NativeEndpoint.issue(for: endpoint); credentials.endpointChanged(to:endpoint) } }
  @Published private(set) var endpointIssue: NativeEndpointIssue? = .required
  @Published var busy = false
  @Published var message: String? { didSet { if message != nil { prepareErrorPresentation() } } }
  @Published private(set) var connectionProblem: ConnectionProblem?
  private var retryProblem: ConnectionProblem?
  @Published var sshGatewayText = "" {
    didSet {
      if destinationPublished {
        credentials.bindLaunchEndpoint(endpoint,routeIdentity:sshGatewayText.isEmpty ? "" : sshGateway?.routeIdentity ?? "invalid-ssh-gateway")
      }
    }
  }
  private var destinationPublished = false
  var sshGateway: NativeSSHGateway? { try? NativeSSHGateway(sshGatewayText) }
  var gatewayIssue: String? {
    guard !sshGatewayText.isEmpty else { return nil }
    do {
      let gateway = try NativeSSHGateway(sshGatewayText)
      if endpointIssue == nil { _ = try NativeSSHTunnelRequest(endpoint:endpoint,gateway:gateway) }
      return nil
    } catch { return (error as? NativeTunnelError)?.description ?? NativeTunnelError.invalidRequest.description }
  }
  var destination: NativeConnectionDestination { .init(endpoint:endpoint,sshGateway:sshGateway) }
  var canEditDestination: Bool {
    !isReverse && !busy && !closing && session?.isClosing == false &&
      [.idle,.closed,.failed].contains(session?.snapshot.state ?? .idle)
  }
  func selectDestination(_ value: NativeConnectionDestination) {
    guard canEditDestination else { return }
    endpoint = value.endpoint; sshGatewayText = value.sshGateway?.canonicalURI ?? ""
  }
  private var tunnelFactory: @MainActor (NativeSSHTunnelRequest) -> any NativeTunnelOwning = { NativeSSHTunnel(request:$0) }
  private var tunnelAttempt: ConnectionTunnelAttempt?
  private var attemptDestination: NativeConnectionDestination?
  private var attemptEndpoint: String?
  var authenticationEndpoint: String { attemptEndpoint ?? endpoint }
  private var suppressConnectionProblem = false
  private var reportedGeneration: UInt64?
  @Published var clipboardMessage: String?
  @Published var closing = false
  @Published private(set) var encodingDraft: NativeSessionEncodingDraft?
  private var encodingCleanup: Task<Void, Never>?
  @Published private(set) var securityDraft: NativeSessionSecurityDraft?
  @Published private(set) var connectionOptionsDraft: NativeConnectionDraft?
  private var securityCleanup: Task<Void,Never>?
  private var operation: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var stateObservation: AnyCancellable?
  private var defaultsObservation: AnyCancellable?
  private var sessionObservation: AnyCancellable?
  init(runtime: NativeRuntime, preferences: NativePreferencesStore, fullscreen: NativeFullscreenState = NativeFullscreenState(), displays: NativeDisplayService? = nil, history: NativeRecentHistory? = nil,
       profileStore: NativeProfileHistoryStore? = nil, profileID: UUID? = nil, document: NativeDocumentOpenRequest? = nil,
       invocation: NativeInvocationRequest? = nil, connectOnReady: Bool = false, reverse: ReverseConnectionRequest? = nil,
       launchCredentials: NativeLaunchCredentialInputs? = nil, passwordFileReader: any NativePasswordFileReading = NativePasswordFileReader(),
       credentialStore: NativeCredentialStore? = nil, trustStore: NativeLegacyTrustStore? = nil, savedTrustStore: NativeTrustStore? = nil, hostKeyStore: NativeTrustStore? = nil,
       tunnelFactory: @escaping @MainActor (NativeSSHTunnelRequest) -> any NativeTunnelOwning = { NativeSSHTunnel(request:$0) },
       onSession: @escaping @MainActor (NativeSession, ConnectionModel) -> Void) {
    self.tunnelFactory = tunnelFactory
    self.fullscreen = fullscreen
    self.reverse = reverse
    self.history = reverse == nil ? history : nil; self.displays = displays
    let credentialInputs: NativeLaunchCredentialInputs?
    if let reverse { credentialInputs = reverse.credentials }
    else if let launchCredentials { credentialInputs = launchCredentials }
    else if let invocation { credentialInputs = try? NativeLaunchCredentialInputs.fileOnly(invocation) }
    else { credentialInputs = nil }
    credentials = NativeAuthenticationCredentials(store: reverse == nil ? credentialStore : nil,launchInputs:credentialInputs,passwordFileReader:passwordFileReader)
    trust = NativeCertificateTrust(store: reverse == nil ? trustStore : nil,savedStore: reverse == nil ? savedTrustStore : nil,hostKeyStore: reverse == nil ? hostKeyStore : nil)
    let defaults = NativeSessionDefaults(runtime: runtime, store: preferences, profileStore: profileStore, profileID: profileID,invocation:reverse?.invocation ?? invocation,
      document:document,documentDisplays:{ [weak displays] in
        displays?.refresh()
        return (try? displays?.snapshot.documentMonitorOrder()) ?? []
      },documentAvailableDisplays:{ [weak displays] in
        displays?.refresh()
        return displays?.snapshot.displays.map(\.id) ?? []
      },prepared:reverse?.prepared)
    self.defaults = defaults
    documentSaveObservation = documentSave.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    commandsObservation = desktopCommands.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
    fullscreenObservation = fullscreen.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
      Task { @MainActor [weak self] in if self?.message != nil { self?.prepareErrorPresentation() } }
    }
    defaultsObservation = defaults.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
    sessionObservation = defaults.$session.sink { [weak self] session in
      MainActor.assumeIsolated {
        guard let self, let session else { return }
        self.resizeObservation = session.remoteResize.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        self.trust.bind(session)
        self.promptObservation = session.$prompt.sink { [weak self] prompt in
          MainActor.assumeIsolated { self?.trust.inspect(prompt); self?.credentials.inspect(prompt) }
        }
        self.credentials.bind(session)
        self.input.bind(session,inactiveCursor:self.defaults?.documentResolution?.cursorType ?? self.defaults?.invocationResolution?.cursorType ?? .dot)
        self.fullscreen.windowStartup.configure(session.initialWindowStartupPolicy)
        self.scaling.bind(session); self.desktopCommands.bind(session)
        if let displays = self.displays { self.fullscreen.bind(session:session,displays:displays,scaling:self.scaling,input:self.input,commands:self.desktopCommands) }
        if let reverse { self.endpoint = reverse.endpoint }
        else if let document = self.defaults?.documentResolution { self.endpoint = document.endpoint }
        else if let invocation = self.defaults?.invocationResolution { self.endpoint = invocation.endpoint }
        else if let profile = self.defaults?.profile { self.endpoint = profile.endpoint }
        self.sshGatewayText = reverse == nil ? self.defaults?.profile?.sshGateway?.canonicalURI ?? "" : ""
        self.destinationPublished = true
        self.credentials.bindLaunchEndpoint(self.endpoint,routeIdentity:self.sshGateway?.routeIdentity ?? "")
        self.stateObservation = session.$snapshot.sink { [weak self] snapshot in
          MainActor.assumeIsolated {
            if snapshot.state != .connected { self?.closeFullscreen(); self?.closeRemoteResize(); self?.closeEncoding(); self?.closeScaling(); self?.closeInput(); self?.closeInformation(); self?.showsStatistics = false }
            if ![.idle,.closed,.failed].contains(snapshot.state) { self?.closeSecurity(); self?.closeConnectionOptions() }
            self?.credentials.observe(snapshot)
            self?.observeConnection(snapshot)
            self?.objectWillChange.send()
          }
        }
        onSession(session, self)
        if reverse != nil {
          Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.session === session, self.canConnect else { return }
            self.connect()
          }
        } else if connectOnReady, let address = invocation?.endpoint, !address.isEmpty, document == nil {
          // Publication precedes isReady. Schedule once after this synchronous
          // admission finishes; close or an intervening endpoint edit revokes it.
          Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.session === session,
                  self.endpoint == address, self.canConnect else { return }
            self.connect()
          }
        }
      }
    }
    trustObservation = trust.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
    credentialsObservation = credentials.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
    defaults.load()
  }
  init(error: String) { reverse = nil; fullscreen = NativeFullscreenState(); defaults = nil; history = nil; credentials = NativeAuthenticationCredentials(); trust = NativeCertificateTrust(); message = error }
  func beginDocumentExport() {
    guard canExportDocument, fullscreen.prepareForSettings({ [weak self] in self?.beginDocumentExport() }) else { return }
    displays?.refresh()
    do {
      let order = (try? displays?.snapshot.documentMonitorOrder()) ?? []
      let names = Dictionary((displays?.snapshot.displays ?? []).map { ($0.id,$0.name) },uniquingKeysWith:{ first,_ in first })
      _ = try documentSave.begin(documentExportCapture(legacyDisplays:order,displayNames:names))
    } catch {
      message = (error as? NativeDocumentExportError)?.description ??
        (error as? NativeDocumentFailure)?.description ?? "The connection settings cannot be exported. Review them and try again."
    }
  }
  var canExportDocument: Bool {
    guard !isReverse else { return false }
    guard let session else { return false }
    return defaults?.isReady == true && gatewayIssue == nil && (endpoint.isEmpty || endpointIssue == nil) && !closing && !busy && !session.isClosing && session.prompt == nil &&
      !credentials.isWorking && !trust.isWorking && fullscreen.canPresentSettings && !documentSave.hasPending &&
      fullscreenDraft == nil && resizePolicyDraft == nil && remoteResizeDraft == nil && remoteResizeCleanup == nil &&
      connectionOptionsDraft == nil && securityDraft == nil && securityCleanup == nil && informationID == nil &&
      inputDraft == nil && encodingDraft == nil && encodingCleanup == nil && scalingDraft == nil &&
      [.idle,.connected,.closed,.failed].contains(session.snapshot.state)
  }
  // Capture synchronously on the main actor. Every field comes from its current
  // session owner; no initial/default value can overwrite an applied edit.
  func documentExport(legacyDisplays: [NativeDisplayID]) throws -> NativeDocumentExport {
    try documentExportCapture(legacyDisplays:legacyDisplays).automaticExport()
  }
  func documentExportCapture(legacyDisplays: [NativeDisplayID], displayNames: [NativeDisplayID:String] = [:]) throws -> NativeDocumentExportCapture {
    guard canExportDocument, let session else { throw NativeDocumentExportError.unavailable }
    let connection = try session.connectionOptions(), security = try session.securityConfiguration()
    var configuration = NativeSessionConfiguration()
    configuration.windowStartupPolicy = session.initialWindowStartupPolicy
    configuration.windowStartupSources = session.initialWindowStartupSources
    configuration.maxCutText = session.maxCutText
    configuration.maxCutTextSource = session.maxCutTextSource
    configuration.pointerEventIntervalMilliseconds = session.pointerEventIntervalMilliseconds
    configuration.pointerEventIntervalSource = session.pointerEventIntervalSource
    configuration.networkPolicy = session.networkPolicy; configuration.networkSources = session.networkSources
    configuration.shared = connection.shared; configuration.reconnectOnError = connection.reconnectOnError
    configuration.securityTypes = try security.preferences.selection().types
    configuration.tlsPriority = security.preferences.tlsPriority ?? ""
    configuration.caFile = security.trustFiles.caFile ?? ""; configuration.crlFile = security.trustFiles.crlFile ?? ""
    configuration.encoding = try session.encodingOptions()
    configuration.clipboardSend = session.clipboardSendEnabled; configuration.clipboardReceive = session.clipboardReceiveEnabled
    configuration.input = input.value; configuration.scaling = scaling.value
    configuration.fullscreenPolicy = displays == nil ? session.initialFullscreenPolicy : fullscreen.policy
    configuration.resizePolicy = session.resizePolicy
    return try NativeDocumentExportCapture(endpoint:endpoint,configuration:configuration,inactiveCursor:input.inactiveCursor,
      legacyDisplays:legacyDisplays,displayNames:displayNames,ignoredInput:defaults?.documentResolution?.notices.isEmpty == false,sshGateway:sshGateway)
  }
  var canConnect: Bool {
    guard !isReverse || !reverseAttempted else { return false }
    guard let session else { return false }
    return defaults?.isReady == true && gatewayIssue == nil && tunnelAttempt == nil && !documentSave.hasPending && fullscreenDraft == nil && resizePolicyDraft == nil && remoteResizeDraft == nil && remoteResizeCleanup == nil && connectionOptionsDraft == nil && securityDraft == nil && securityCleanup == nil && !busy && !closing && !credentials.isWorking && !trust.isWorking && endpointIssue == nil && [.idle, .closed, .failed].contains(session.snapshot.state)
  }
  func connect() {
    guard canConnect, let session else { return }
    let destination = destination, address = endpoint, reverse = reverse
    let attempt: ConnectionTunnelAttempt?
    do {
      if reverse == nil, let gateway = destination.sshGateway {
        let request = try NativeSSHTunnelRequest(endpoint:address,gateway:gateway,network:session.networkPolicy)
        attempt = ConnectionTunnelAttempt(owner:tunnelFactory(request),session:session)
      } else { attempt = nil }
    } catch { message = (error as? NativeTunnelError)?.description; return }
    tunnelAttempt = attempt
    busy = true; message = nil; connectionProblem = nil; retryProblem = nil
    if reverse != nil { reverseAttempted = true }
    trust.beginAttempt(endpoint:reverse == nil ? address : nil,routeIdentity:destination.sshGateway?.routeIdentity ?? "")
    credentials.beginAttempt(endpoint:address,routeIdentity:destination.sshGateway?.routeIdentity ?? "")
    attemptDestination = destination; attemptEndpoint = address; suppressConnectionProblem = false; reportedGeneration = nil
    operation = Task { [weak self] in
      var connected = false
      do {
        let completion: NativeCompletion
        if let reverse { completion = try await reverse.listener.accept(reverse.peer,into:session) }
        else if let attempt {
          completion = try await attempt.connect(destination:destination) { [weak self, weak attempt] in
            guard let self, let attempt else { return }; self.tunnelExited(attempt)
          }
        } else { completion = try await session.connect(endpoint:address) }
        try Task.checkCancellation()
        connected = self?.closing == false && session.snapshot.state == .connected
        if connected, completion.operation.generation == session.generation, completion.snapshot.state == .connected {
          self?.history?.recordSuccessful(destination)
        }
      }
      catch is CancellationError {}
      catch {
        if let failure = error as? NativeTunnelError {
          if self?.closing == false, self?.suppressConnectionProblem == false { self?.message = failure.description }
        } else if reverse != nil, !(error is NativeCommandFailure) {
          if self?.closing == false { self?.message = "This incoming connection is no longer available. Ask the server to make a new connection to the listener." }
        } else if let issue = NativeConnectionIssue(error:error) {
          self?.reportConnection(issue,generation:(error as? NativeCommandFailure)?.operation.generation ?? session.generation)
        }
      }
      if let attempt, !connected {
        await attempt.drain().value
        if self?.tunnelAttempt === attempt { self?.tunnelAttempt = nil }
      }
      self?.busy = false; self?.operation = nil
    }
  }
  private func tunnelExited(_ attempt: ConnectionTunnelAttempt) {
    guard !closing, tunnelAttempt === attempt, !attempt.stopping else { return }
    suppressConnectionProblem = true; connectionProblem = nil; retryProblem = nil
    message = "The SSH tunnel closed. Check the gateway and connect again."
    trust.cancel(); credentials.clear()
    if let operation { operation.cancel() }
    else { finishTunnel(attempt) }
  }
  private func finishTunnel(_ attempt: ConnectionTunnelAttempt) {
    guard !closing, tunnelAttempt === attempt, operation == nil else { return }
    busy = true
    operation = Task { [weak self] in
      await attempt.drain().value
      if self?.tunnelAttempt === attempt { self?.tunnelAttempt = nil }
      self?.busy = false; self?.operation = nil
    }
  }
  func cancel() {
    if let reverse { try? reverse.listener.reject(reverse.peer) }
    trust.cancel(); credentials.clear()
    suppressConnectionProblem = true; connectionProblem = nil; retryProblem = nil; operation?.cancel()
  }
  func disconnect() {
    guard let session, !closing else { return }
    if busy { cancel(); return }
    trust.cancel(); credentials.clear()
    suppressConnectionProblem = true; connectionProblem = nil; retryProblem = nil
    busy = true; message = nil
    let attempt = tunnelAttempt
    operation = Task { [weak self] in
      do { _ = try await session.disconnect() }
      catch { if self?.closing == false { self?.message = NativeConnectionIssue(error: error)?.message } }
      if let attempt {
        await attempt.drain().value
        if self?.tunnelAttempt === attempt { self?.tunnelAttempt = nil }
      }
      self?.busy = false; self?.operation = nil
    }
  }
  func refresh() {
    guard let session, session.snapshot.state == .connected, !closing else { return }
    let generation = session.generation
    Task { [weak self] in
      do { _ = try await session.refresh() }
      catch {
        guard let self, !self.closing, session.generation == generation,
              self.connectionProblem == nil else { return }
        self.message = NativeConnectionIssue(error: error)?.message
      }
    }
  }
  private func observeConnection(_ snapshot: NativeSnapshot) {
    if let attempt = tunnelAttempt, attempt.admitted, snapshot.generation != attempt.initialGeneration,
       [.closed,.failed].contains(snapshot.state) { finishTunnel(attempt) }
    guard let issue = NativeConnectionIssue(snapshot: snapshot) else { return }
    reportConnection(issue, generation: snapshot.generation)
  }
  private func reportConnection(_ issue: NativeConnectionIssue, generation: UInt64) {
    guard !closing, !suppressConnectionProblem, session?.generation == generation,
          reportedGeneration != generation else { return }
    reportedGeneration = generation
    message = nil
    let problem = ConnectionProblem(generation: generation, issue: issue)
    retryProblem = problem; connectionProblem = problem
  }
  // SwiftUI can dismiss an alert before invoking its selected button. Hiding
  // releases presentation only; Cancel explicitly revokes the retry intent.
  func hideConnectionProblem(_ id: UUID) {
    if connectionProblem?.id == id { connectionProblem = nil }
  }
  func dismissConnectionProblem(_ id: UUID) {
    hideConnectionProblem(id)
    if retryProblem?.id == id { retryProblem = nil }
  }
  func offersRetryConnection(_ problem: ConnectionProblem) -> Bool {
    !isReverse && problem.issue.permitsReconnect && session?.reconnectOnErrorEnabled == true
  }
  func canRetryConnection(_ problem: ConnectionProblem) -> Bool {
    retryProblem?.id == problem.id && offersRetryConnection(problem) && canConnect &&
      session?.generation == problem.generation && attemptDestination == destination
  }
  func retryConnection(_ problem: ConnectionProblem) {
    guard canRetryConnection(problem) else { return }
    connect()
  }
  var canOpenConnectionOptions: Bool { canOpenSecurity }
  func openConnectionOptions() {
    guard canOpenConnectionOptions, fullscreen.prepareForSettings({ [weak self] in self?.openConnectionOptions() }), let session else { return }
    let draft = NativeConnectionDraft(session:session); draft.reload(); connectionOptionsDraft = draft
  }
  func closeConnectionOptions() { connectionOptionsDraft?.stop(); connectionOptionsDraft = nil }
  var canOpenSecurity: Bool {
    guard let session else { return false }
    return fullscreen.canPresentSettings && !documentSave.hasPending && !closing && !busy && !credentials.isWorking && !trust.isWorking && session.prompt == nil &&
      informationID == nil && inputDraft == nil && scalingDraft == nil && encodingDraft == nil && encodingCleanup == nil &&
      fullscreenDraft == nil && resizePolicyDraft == nil && remoteResizeDraft == nil && remoteResizeCleanup == nil && connectionOptionsDraft == nil && securityDraft == nil && securityCleanup == nil && [.idle,.closed,.failed].contains(session.snapshot.state)
  }
  func openSecurity() {
    guard canOpenSecurity, fullscreen.prepareForSettings({ [weak self] in self?.openSecurity() }), let session else { return }
    do {
      let draft = try NativeSessionSecurityDraft(session:session,onApplied: { [weak self] in
        self?.credentials.clear(); self?.trust.cancel()
        self?.connectionProblem = nil; self?.retryProblem = nil
      })
      draft.reload(); securityDraft = draft
    } catch { message = "Security settings are unavailable for this connection." }
  }
  func closeSecurity() {
    guard let draft = securityDraft else { return }
    draft.stop(); securityDraft = nil
    securityCleanup = Task { @MainActor [weak self] in
      await draft.close(); self?.securityCleanup = nil; self?.objectWillChange.send()
    }
  }
  var canOpenEncoding: Bool {
    fullscreen.canPresentSettings && !documentSave.hasPending && !closing && !busy && fullscreenDraft == nil && resizePolicyDraft == nil && remoteResizeDraft == nil && remoteResizeCleanup == nil && connectionOptionsDraft == nil && securityDraft == nil && securityCleanup == nil && informationID == nil && inputDraft == nil && scalingDraft == nil && encodingDraft == nil && encodingCleanup == nil && session?.snapshot.state == .connected
  }
  func openEncoding() {
    guard canOpenEncoding, fullscreen.prepareForSettings({ [weak self] in self?.openEncoding() }), let session else { return }
    let draft = NativeSessionEncodingDraft(session: session)
    draft.reload(); encodingDraft = draft
  }
  func closeEncoding() {
    guard let draft = encodingDraft else { return }
    draft.stop(); encodingDraft = nil
    // Reopening is gated until cancellation/completion has drained, so a prior
    // sheet cannot apply late over a newer editor's baseline.
    encodingCleanup = Task { @MainActor [weak self] in
      await draft.close()
      self?.encodingCleanup = nil; self?.objectWillChange.send()
    }
  }
  var canOpenFullscreen: Bool { canOpenScaling && fullscreen.displaySnapshot != nil }
  func openFullscreen() {
    guard canOpenFullscreen, fullscreen.prepareForSettings({ [weak self] in self?.openFullscreen() }) else { return }
    fullscreenDraft = NativeFullscreenDraft(state:fullscreen)
  }
  func closeFullscreen() { fullscreenDraft?.cancel(); fullscreenDraft = nil }
  var canOpenResizePolicy: Bool { canOpenScaling || canOpenSecurity }
  func openResizePolicy() {
    guard canOpenResizePolicy, fullscreen.prepareForSettings({ [weak self] in self?.openResizePolicy() }), let session else { return }
    resizePolicyDraft = NativeRemoteResizePolicyDraft(session:session)
  }
  func closeResizePolicy() { resizePolicyDraft?.cancel(); resizePolicyDraft = nil }
  var canOpenRemoteResize: Bool {
    canOpenScaling && session?.snapshot.supportsResize == true && session?.snapshot.resizePending == false && session?.isViewOnly == false
  }
  func openRemoteResize() {
    guard canOpenRemoteResize, fullscreen.prepareForSettings({ [weak self] in self?.openRemoteResize() }), let session else { return }
    let draft = NativeRemoteResizeDraft(session:session,displays:displays); draft.reload(); remoteResizeDraft = draft
  }
  func closeRemoteResize() {
    guard let draft = remoteResizeDraft else { return }
    draft.stop(); remoteResizeDraft = nil
    remoteResizeCleanup = Task { @MainActor [weak self] in
      await draft.close(); self?.remoteResizeCleanup = nil; self?.objectWillChange.send()
    }
  }
  var canOpenScaling: Bool {
    fullscreen.canPresentSettings && !documentSave.hasPending && !closing && !busy && fullscreenDraft == nil && resizePolicyDraft == nil && remoteResizeDraft == nil && remoteResizeCleanup == nil && connectionOptionsDraft == nil && securityDraft == nil && securityCleanup == nil && informationID == nil && inputDraft == nil && encodingCleanup == nil && encodingDraft == nil && scalingDraft == nil && session?.snapshot.state == .connected
  }
  func openScaling() {
    guard canOpenScaling, fullscreen.prepareForSettings({ [weak self] in self?.openScaling() }) else { return }
    scalingDraft = NativeScalingDraft(state: scaling)
  }
  func closeScaling() { scalingDraft?.cancel(); scalingDraft = nil }
  var canOpenInput: Bool {
    fullscreen.canPresentSettings && !documentSave.hasPending && !closing && !busy && fullscreenDraft == nil && resizePolicyDraft == nil && remoteResizeDraft == nil && remoteResizeCleanup == nil && connectionOptionsDraft == nil && securityDraft == nil && securityCleanup == nil && informationID == nil && inputDraft == nil && scalingDraft == nil && encodingDraft == nil && encodingCleanup == nil && session?.snapshot.state == .connected
  }
  func openInput() {
    guard canOpenInput, fullscreen.prepareForSettings({ [weak self] in self?.openInput() }) else { return }
    inputDraft = NativeInputDraft(state: input)
  }
  func closeInput() { inputDraft?.cancel(); inputDraft = nil }
  var canOpenInformation: Bool {
    fullscreen.canPresentSettings && !documentSave.hasPending && !closing && !busy && fullscreenDraft == nil && resizePolicyDraft == nil && remoteResizeDraft == nil && remoteResizeCleanup == nil && connectionOptionsDraft == nil && securityDraft == nil && securityCleanup == nil && informationID == nil && inputDraft == nil && scalingDraft == nil && encodingDraft == nil && encodingCleanup == nil && session?.snapshot.state == .connected
  }
  func openInformation() {
    guard canOpenInformation, fullscreen.prepareForSettings({ [weak self] in self?.openInformation() }) else { return }
    informationID = UUID()
  }
  func closeInformation() { informationID = nil }
  private func prepareErrorPresentation() {
    if fullscreen.phase == .active { _ = fullscreen.prepareForSettings({}) }
  }
  var canToggleStatistics: Bool {
    fullscreen.canPresentSettings && !documentSave.hasPending && (showsStatistics || (!closing && !busy && session?.information != nil))
  }
  func toggleStatistics() {
    guard canToggleStatistics else { return }
    showsStatistics.toggle()
  }
  func performDesktop(_ command: NativeDesktopCommand) {
    guard !closing && !busy else { return }
    do { try desktopCommands.perform(command) }
    catch { message = "This desktop command is unavailable. Focus the connected desktop and try again." }
  }
  func requestClose() {
    guard cleanup == nil else { return }
    if let reverse { try? reverse.listener.reject(reverse.peer) }
    documentSave.stop(); trust.stop(); credentials.stop()
    closing = true; connectionProblem = nil; retryProblem = nil; attemptEndpoint = nil; showsStatistics = false; operation?.cancel(); closeFullscreen(); fullscreen.stop(); closeResizePolicy(); closeRemoteResize(); closeConnectionOptions(); closeSecurity(); closeEncoding(); closeScaling(); closeInput(); closeInformation(); desktopCommands.stop(); scaling.stop(); input.stop()
    defaults?.stop()
    let owner = session, attempt = tunnelAttempt, operationJoin = operation
    let defaultsOwner = defaults
    let encodingJoin = encodingCleanup, securityJoin = securityCleanup, resizeJoin = remoteResizeCleanup
    let saveOwner = documentSave
    let credentialOwner = credentials, trustOwner = trust
    cleanup = Task {
      if let owner { try? await owner.close() }
      await operationJoin?.value
      if let attempt { await attempt.drain().value }
      await saveOwner.close(); await trustOwner.close(); await credentialOwner.close()
      await resizeJoin?.value; await securityJoin?.value; await encodingJoin?.value; await defaultsOwner?.close()
    }
  }
  func close() async { requestClose(); await cleanup?.value }
  deinit { operation?.cancel() }
}
