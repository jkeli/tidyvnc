// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import Darwin

public enum NativeCredentialRetention: Sendable { case useOnce, session, remember, replaceRemembered }

// One controller per connection window. Secrets never enter published state.
// Reuse is explicit at a current credential prompt, after protocol trust callbacks.
@MainActor public final class NativeAuthenticationCredentials: ObservableObject {
  @Published public private(set) var notice: String?
  @Published public private(set) var isWorking = false
  @Published public private(set) var hasSessionCredential = false
  public var supportsRemembering: Bool { store != nil }
  private weak var session: NativeSession?
  private let store: NativeCredentialStore?
  private var endpoint: String?
  private var routeIdentity = ""
  private var stopped = false
  private var epoch: UInt64 = 0
  private var work: Task<Void,Never>?
  private struct Candidate {
    let key: NativeCredentialKey
    let secret: NativeCredentialSecret
    let generation: UInt64
    let retention: NativeCredentialRetention
  }
  private var pending: Candidate?
  private var retained: Candidate?
  private var savedSubmission: UInt64?
  private var launch: NativeLaunchCredentialPayload?
  private var launchEndpoint: String?
  private var launchRouteIdentity: String?
  private let passwordFileReader: any NativePasswordFileReading
  private var automaticPrompt: NativePrompt?
  public init(store: NativeCredentialStore? = nil, launchInputs: NativeLaunchCredentialInputs? = nil,
              passwordFileReader: any NativePasswordFileReading = NativePasswordFileReader()) {
    self.store = store; launch = launchInputs?.claim(); self.passwordFileReader = passwordFileReader
  }
  // The resolved initial CLI/file endpoint binds before editable UI admission.
  // An empty form binds on its first explicit connection attempt.
  public func bindLaunchEndpoint(_ endpoint: String, routeIdentity: String? = nil) {
    guard launch != nil, !endpoint.isEmpty else { return }
    if launchEndpoint == nil { launchEndpoint = endpoint }
    else { endpointChanged(to:endpoint) }
    if let routeIdentity, launch != nil {
      if let expected = launchRouteIdentity, !expected.utf8.elementsEqual(routeIdentity.utf8) {
        discardLaunch(); epoch &+= 1
        if automaticPrompt != nil { work?.cancel(); automaticPrompt = nil }
      } else { launchRouteIdentity = routeIdentity }
    }
  }
  public func endpointChanged(to endpoint: String) {
    if let expected = launchEndpoint, !expected.utf8.elementsEqual(endpoint.utf8) {
      discardLaunch(); epoch &+= 1
      if automaticPrompt != nil { work?.cancel(); automaticPrompt = nil }
    }
  }
  private func discardLaunch() { launch?.clear(); launch = nil; launchEndpoint = nil; launchRouteIdentity = nil }
  // Combine publishes before NativeSession.prompt changes. Schedule admission
  // on the main actor, then recheck the published prompt before accessing input.
  public func inspect(_ request: NativePrompt?) {
    guard let request, request.kind == .credentials else {
      if automaticPrompt != nil { epoch &+= 1; work?.cancel(); automaticPrompt = nil }
      return
    }
    guard !stopped, !isWorking, let source = launch,
          source.hasEnvironment(usernameRequired:request.usernameRequired) || (!request.usernameRequired && source.file != nil) else { return }
    let ticket = epoch, reader = passwordFileReader
    automaticPrompt = request; isWorking = true; notice = nil
    work = Task { [weak self] in
      defer { self?.finishWork() }
      do {
        guard self?.epoch == ticket, self?.isCurrent(request) == true, !Task.isCancelled else { return }
        if try self?.submitImmediateLaunch(request,source:source) == true { return }
        guard let file = source.file, !request.usernameRequired else { return }
        let block = try await reader.read(file)
        defer { block.clear() }
        guard let self, self.epoch == ticket, self.isCurrent(request), !Task.isCancelled, let session = self.session else { return }
        var bytes = try block.copyBytes(); defer { Self.wipe(&bytes) }
        try session.replyPasswordFile(to:request,block:&bytes)
        self.notice = nil
      } catch {
        guard let self, self.epoch == ticket, self.isCurrent(request), !Task.isCancelled else { return }
        self.notice = ((error as? NativePasswordFileIssue)?.description ?? "The launch credentials could not be used.") + " Enter a password or cancel this attempt."
      }
    }
  }
  private func submitImmediateLaunch(_ request: NativePrompt, source: NativeLaunchCredentialPayload) throws -> Bool {
    guard isCurrent(request), let session else { throw NativeError(.stale,"Inactive credential request") }
    if source.hasEnvironment(usernameRequired:request.usernameRequired) {
      var user = request.usernameRequired ? try source.username!.copyBytes() : []
      defer { Self.wipe(&user) }
      var password = try source.password!.copyBytes(); defer { Self.wipe(&password) }
      try session.replyCredentialBytes(to:request,username:&user,password:&password)
      pending?.secret.clear(); pending = nil; forgetSession(); savedSubmission = nil; notice = nil
      return true
    }
    // Explicitly retained, nonempty credentials precede a launch password file.
    // Ordinary windows keep their existing explicit Use Session Password action.
    if !request.usernameRequired, source.file != nil, let retained,
       retained.key == (try key(request,username:"")) {
      var bytes = try retained.secret.copyBytes(); defer { Self.wipe(&bytes) }
      if !bytes.isEmpty {
        self.retained = nil; hasSessionCredential = false
        do { try forward(request,username:"",key:retained.key,secret:retained.secret,retention:.session) }
        catch { retained.secret.clear(); throw error }
        return true
      }
    }
    return false
  }
  public func bind(_ session: NativeSession) { self.session = session }
  public func beginAttempt(endpoint: String, routeIdentity: String = "") {
    guard !stopped, !isWorking else { return }
    bindLaunchEndpoint(endpoint,routeIdentity:routeIdentity)
    if (self.endpoint.map({ !$0.utf8.elementsEqual(endpoint.utf8) }) ?? false) ||
       !self.routeIdentity.utf8.elementsEqual(routeIdentity.utf8) { forgetSession() }
    pending?.secret.clear(); pending = nil; savedSubmission = nil
    self.endpoint = endpoint; self.routeIdentity = routeIdentity; notice = nil; epoch &+= 1
  }
  private func isCurrent(_ request: NativePrompt) -> Bool {
    !stopped && request.kind == .credentials && session?.isClosing == false &&
      session?.generation == request.generation && session?.prompt == request
  }
  private func key(_ request: NativePrompt, username: String) throws -> NativeCredentialKey {
    guard isCurrent(request), let endpoint else { throw NativeError(.stale, "Inactive credential request") }
    return try NativeCredentialKey(endpoint: endpoint, routeIdentity: routeIdentity,
      authentication: request.usernameRequired ? .usernamePassword(securityType: request.securityType) : .passwordOnly(securityType: request.securityType),
      username: request.usernameRequired ? username : "")
  }
  private static func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } }
  }
  // All paths consume/clear input, including validation failures and stale prompts.
  public func submit(_ request: NativePrompt, username: inout [UInt8], password: inout [UInt8],
                     retention: NativeCredentialRetention = .useOnce) throws {
    defer { Self.wipe(&username); Self.wipe(&password) }
    guard !isWorking else { throw NativeCredentialStoreIssue.busy }
    guard username.count <= 4096, let user = String(bytes: username, encoding: .utf8) else { throw NativeCredentialKeyIssue.invalidText }
    if retention == .remember || retention == .replaceRemembered {
      guard store != nil else { throw NativeCredentialStoreIssue.unavailable }
    }
    let key = try key(request, username: user)
    let secret = try NativeCredentialSecret(consuming: &password)
    do { try forward(request, username: user, key: key, secret: secret, retention: retention) }
    catch { secret.clear(); throw error }
  }
  private func forward(_ request: NativePrompt, username: String, key: NativeCredentialKey,
                       secret: NativeCredentialSecret, retention: NativeCredentialRetention) throws {
    guard isCurrent(request), let session else { throw NativeError(.stale, "Inactive credential request") }
    var user = request.usernameRequired ? Array(username.utf8) : [], bytes = try secret.copyBytes()
    defer { Self.wipe(&user); Self.wipe(&bytes) }
    try session.replyCredentials(to: request, username: &user, password: &bytes)
    pending?.secret.clear(); pending = nil
    forgetSession(); savedSubmission = nil; notice = nil
    if retention == .useOnce { secret.clear() }
    else { pending = Candidate(key: key, secret: secret, generation: request.generation, retention: retention) }
  }
  public func canUseSession(_ request: NativePrompt, username: String) -> Bool {
    guard !isWorking, let retained, let key = try? key(request, username: username) else { return false }
    return retained.key == key
  }
  public func useSession(_ request: NativePrompt, username: String) throws {
    guard canUseSession(request, username: username), let retained else { throw NativeError(.stale, "No matching session credential") }
    // Transfer ownership so forward cannot wipe the value it is submitting.
    self.retained = nil; hasSessionCredential = false
    do { try forward(request, username: username, key: retained.key, secret: retained.secret, retention: .session) }
    catch { retained.secret.clear(); throw error }
  }
  public func forgetSession() {
    retained?.secret.clear(); retained = nil; hasSessionCredential = false
  }
  public func useSaved(_ request: NativePrompt, username: String, retention: NativeCredentialRetention = .useOnce) {
    guard !isWorking, let store else { return }
    let key: NativeCredentialKey
    do { key = try self.key(request, username: username) }
    catch { notice = "This authentication request is no longer available."; return }
    let ticket = epoch; isWorking = true; notice = nil
    work = Task { [weak self] in
      defer { self?.finishWork() }
      do {
        let secret = try await store.lookup(key, interaction: .allow)
        var transferred = false
        defer { if !transferred { secret.clear() } }
        guard let self, self.epoch == ticket, self.isCurrent(request), !Task.isCancelled else { return }
        // Existing durable entries do not need to be written again. Only the
        // explicit session choice extends the in-memory lifetime.
        let selected: NativeCredentialRetention = retention == .session ? .session : .useOnce
        try self.forward(request, username: username, key: key, secret: secret, retention: selected)
        transferred = selected == .session
        self.savedSubmission = request.generation
      } catch {
        guard let self, self.epoch == ticket, self.isCurrent(request), !Task.isCancelled else { return }
        self.notice = Self.storeMessage(error)
      }
    }
  }
  // This is an explicit UI action, never automatic recovery from rejection.
  public func forgetSaved(_ request: NativePrompt, username: String) {
    guard !isWorking, let store else { return }
    let key: NativeCredentialKey
    do { key = try self.key(request, username: username) }
    catch { notice = "This authentication request is no longer available."; return }
    forgetSession()
    let ticket = epoch; isWorking = true; notice = nil
    work = Task { [weak self] in
      defer { self?.finishWork() }
      do {
        try await store.delete(key, interaction: .allow)
        if let self, self.epoch == ticket, !self.stopped { self.notice = "The saved password was removed from this Mac." }
      } catch {
        if let self, self.epoch == ticket, !self.stopped { self.notice = Self.storeMessage(error) }
      }
    }
  }
  public func observe(_ snapshot: NativeSnapshot) {
    if snapshot.state == .connected, let candidate = pending, candidate.generation == snapshot.generation {
      pending = nil
      if candidate.retention == .session {
        retained = candidate; hasSessionCredential = true
      } else if let store {
        let ticket = epoch; isWorking = true
        work = Task { [weak self] in
          defer { candidate.secret.clear(); self?.finishWork() }
          do {
            try await store.save(candidate.key, secret: candidate.secret,
              mode: candidate.retention == .replaceRemembered ? .replace : .create, interaction: .forbid)
            if let self, self.epoch == ticket, !self.stopped { self.notice = "Password saved on this Mac." }
          } catch {
            if let self, self.epoch == ticket, !self.stopped {
              self.notice = "The connection succeeded, but saving the password could not be confirmed. " + Self.storeMessage(error)
            }
          }
        }
      } else { candidate.secret.clear() }
    }
    if [.closed, .failed].contains(snapshot.state) {
      if automaticPrompt != nil { epoch &+= 1; work?.cancel(); automaticPrompt = nil }
      if pending?.generation == snapshot.generation { pending?.secret.clear(); pending = nil }
      if snapshot.endReason == .authenticationRejected {
        forgetSession()
        if savedSubmission == snapshot.generation {
          notice = "The server rejected the saved password. Retry to enter a replacement or explicitly forget it; the saved entry has not been deleted."
        }
      }
    }
  }
  private func finishWork() { automaticPrompt = nil; isWorking = false; work = nil }
  public func clear() {
    epoch &+= 1; work?.cancel(); automaticPrompt = nil; pending?.secret.clear(); pending = nil
    discardLaunch(); forgetSession(); savedSubmission = nil; notice = nil
  }
  public func stop() { stopped = true; clear(); endpoint = nil; routeIdentity = ""; session = nil }
  public func close() async { stop(); await work?.value }
  public func dismissNotice() { notice = nil }
  private static func storeMessage(_ error: Error) -> String {
    switch error as? NativeCredentialStoreIssue {
    case .notFound: return "No saved password matches this server, authentication method and username."
    case .unavailable: return "The Keychain is unavailable. Enter a password to continue."
    case .denied: return "Keychain access was denied."
    case .interactionRequired: return "Keychain access requires interaction. Use the saved-password control to try again."
    case .cancelled: return "Keychain access was cancelled."
    case .missingEntitlement: return "This app build lacks the signing identity required for Keychain access."
    case .duplicate: return "A saved password already exists. Choose explicit replacement on a subsequent authentication."
    case .corrupt: return "The saved credential could not be read. It has not been changed."
    default: return "The Keychain operation failed. No plaintext copy was saved."
    }
  }
}
