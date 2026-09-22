// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message: message) }
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message: "Unexpected preferences write") }
}
final class Vault: NativeCredentialBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [NativeCredentialKey: [UInt8]] = [:]
  private var operations: [String] = []
  private var failure: NativeCredentialStoreIssue?
  let lookupEntered = DispatchSemaphore(value: 0), lookupRelease = DispatchSemaphore(value: 0)
  private var blockLookup = false, blockSave = false
  let saveEntered = DispatchSemaphore(value: 0), saveRelease = DispatchSemaphore(value: 0)
  func blockNextSave() { lock.withLock { blockSave = true } }
  var calls: [String] { lock.withLock { operations } }
  func fail(_ issue: NativeCredentialStoreIssue?) { lock.withLock { failure = issue } }
  func blockNextLookup() { lock.withLock { blockLookup = true } }
  func seed(_ key: NativeCredentialKey, password: String) { lock.withLock { entries[key] = Array(password.utf8) } }
  func contains(_ key: NativeCredentialKey) -> Bool { lock.withLock { entries[key] != nil } }
  func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialSecret {
    let blocked = lock.withLock { operations.append("lookup"); let value = blockLookup; blockLookup = false; return value }
    if blocked { lookupEntered.signal(); lookupRelease.wait() }
    return try lock.withLock {
      if let failure { throw failure }
      guard var bytes = entries[key] else { throw NativeCredentialStoreIssue.notFound }
      return try NativeCredentialSecret(consuming: &bytes)
    }
  }
  func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode, interaction: NativeCredentialInteraction) throws {
    let blocked = lock.withLock { let value = blockSave; blockSave = false; return value }
    if blocked { saveEntered.signal(); saveRelease.wait() }
    try lock.withLock {
      operations.append(mode == .create ? "create" : "replace")
      try check(interaction == .forbid && !Thread.isMainThread, "post-auth save forbids prompts off MainActor")
      if let failure { throw failure }
      if mode == .create && entries[key] != nil { throw NativeCredentialStoreIssue.duplicate }
      if mode == .replace && entries[key] == nil { throw NativeCredentialStoreIssue.notFound }
      entries[key] = try secret.copyBytes()
    }
  }
  func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws {
    try lock.withLock {
      operations.append("delete"); if let failure { throw failure }
      guard entries.removeValue(forKey: key) != nil else { throw NativeCredentialStoreIssue.notFound }
    }
  }
  func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadata { throw NativeCredentialStoreIssue.notFound }
  func listMetadata(limit: Int, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadataPage { NativeCredentialMetadataPage(entries: [], hasMore: false) }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out waiting for authentication lifecycle")
}
@MainActor func submit(_ model: ConnectionModel, _ retention: NativeCredentialRetention, password: String = "password") throws {
  var user: [UInt8] = [], secret = Array(password.utf8)
  try model.credentials.submit(model.session!.prompt!, username: &user, password: &secret, retention: retention)
  try check(secret.allSatisfy { $0 == 0 }, "submitted caller buffer cleared")
}
@MainActor func run() async throws {
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let vault = Vault(), store = NativeCredentialStore(backing: vault)
  let model = ConnectionModel(runtime: runtime, preferences: preferences, credentialStore: store) { _,_ in }
  let other = ConnectionModel(runtime: runtime, preferences: preferences, credentialStore: store) { _,_ in }
  try await until { model.canConnect == false && model.defaults?.isReady == true && other.defaults?.isReady == true }
  let peer = native_test_peer_create_reconnecting(1)!
  defer { native_test_peer_destroy(peer) }
  let endpoint = "127.0.0.1::\(native_test_peer_port(peer))"
  model.endpoint = endpoint
  let key = try NativeCredentialKey(endpoint: endpoint, authentication: .passwordOnly(securityType: 2))
  func start() async throws -> NativePrompt {
    try await until { model.canConnect }
    model.connect(); try await until { model.session?.prompt != nil }
    let prompt = model.session!.prompt!
    try check(prompt.securityType == 2, "negotiated method carried to native prompt")
    return prompt
  }
  func connected() async throws {
    try await until { !model.busy && model.session?.snapshot.state == .connected && !model.credentials.isWorking }
  }
  func disconnect() async throws {
    model.disconnect(); try await until { !model.busy && model.session?.snapshot.state == .closed }
  }

  _ = try await start(); try submit(model, .useOnce); try await connected()
  try check(vault.calls.isEmpty && !model.credentials.hasSessionCredential, "use-once never retained or persisted")
  try await disconnect()

  _ = try await start(); try submit(model, .session); try await connected()
  try check(model.credentials.hasSessionCredential && !other.credentials.hasSessionCredential && vault.calls.isEmpty, "session secret is isolated and not persisted")
  native_test_peer_disconnect(peer)
  try await until { model.session?.snapshot.state == .closed || model.session?.snapshot.state == .failed }
  try check(model.credentials.hasSessionCredential, "unexpected interruption retains reconnect credential")
  let reconnect = try await start()
  try check(model.credentials.canUseSession(reconnect, username: ""), "same endpoint/method prompt can reuse session password")
  try check(model.session?.prompt != nil && vault.calls.isEmpty, "reconnect requires explicit credential submission")
  try model.credentials.useSession(reconnect, username: ""); try await connected()
  try await disconnect()
  try check(!model.credentials.hasSessionCredential, "explicit disconnect clears session secret")

  native_test_peer_hold_authentication(peer,1)
  _ = try await start(); try submit(model, .remember)
  try await Task.sleep(for: .milliseconds(40))
  try check(vault.calls.isEmpty && model.session?.snapshot.state != .connected, "nothing saved while server authentication result is pending")
  native_test_peer_hold_authentication(peer,0); try await connected()
  try check(vault.calls == ["create"] && model.credentials.notice == "Password saved on this Mac.", "exactly one save after authenticated connection")
  try await disconnect()

  let savedPrompt = try await start(); model.credentials.useSaved(savedPrompt, username: "")
  model.credentials.useSaved(savedPrompt, username: "") // A repeated button cannot enqueue another lookup.
  try await connected()
  try check(vault.calls == ["create","lookup"] && !model.credentials.hasSessionCredential, "explicit stored lookup submits once without resaving or static cache")
  try await disconnect()

  let savedForSession = try await start()
  model.credentials.useSaved(savedForSession, username: "", retention: .session)
  try await connected()
  try check(model.credentials.hasSessionCredential && vault.calls.last == "lookup", "explicit saved-password session choice retains without resaving")
  native_test_peer_disconnect(peer)
  try await until { model.session?.snapshot.state == .closed || model.session?.snapshot.state == .failed }
  let savedReconnect = try await start()
  try model.credentials.useSession(savedReconnect, username: ""); try await connected(); try await disconnect()

  _ = try await start(); try submit(model, .remember); try await connected()
  try check(model.credentials.notice?.contains("already exists") == true, "duplicate create leaves live session connected and requests explicit replacement")
  try await disconnect()
  _ = try await start(); try submit(model, .replaceRemembered); try await connected()
  try check(vault.calls.last == "replace", "explicit replacement saves after success")
  try await disconnect()

  vault.fail(.missingEntitlement)
  _ = try await start(); try submit(model, .remember); try await connected()
  try check(model.credentials.notice?.contains("signing identity") == true && model.connectionProblem == nil, "save failure does not fail established session")
  vault.fail(nil); try await disconnect()

  vault.seed(key,password: "wrong")
  let rejected = try await start(); model.credentials.useSaved(rejected, username: "")
  try await until { !model.busy && model.session?.snapshot.endReason == .authenticationRejected }
  try check(model.credentials.notice?.contains("has not been deleted") == true && !vault.calls.contains("delete"), "rejected saved secret produces no delete or automatic retry")
  let rejectedGeneration = model.session!.generation, beforeRetry = vault.calls.count
  try await Task.sleep(for: .milliseconds(30))
  try check(model.session?.generation == rejectedGeneration && vault.calls.count == beforeRetry, "rejection cannot loop")
  let forget = try await start(); model.credentials.forgetSaved(forget, username: "")
  try await until { !model.credentials.isWorking }
  try check(vault.calls.last == "delete" && model.session?.prompt == forget, "explicit forget only targets matching credential and preserves prompt")
  let beforeFailure = vault.calls.count
  try submit(model, .remember, password: "wrong")
  try await until { !model.busy }
  try check(vault.calls.count == beforeFailure, "rejected manual credential never persisted")

  vault.seed(key,password: "password"); vault.blockNextLookup()
  let parked = try await start(); model.credentials.useSaved(parked, username: "")
  try await until { vault.lookupEntered.wait(timeout: .now()) == .success }
  model.cancel(); try await until { !model.busy }
  try check(!model.canConnect && model.credentials.isWorking, "cancelled in-flight OS lookup keeps admission closed until drain")
  vault.lookupRelease.signal(); try await until { !model.credentials.isWorking }
  try check(model.session?.prompt == nil && model.credentials.notice == nil && !model.credentials.hasSessionCredential, "late lookup cannot submit or repopulate after cancellation")

  let stale = try await start(); model.cancel(); try await until { !model.busy }
  var user: [UInt8] = [], secret = Array("password".utf8)
  do { try model.credentials.submit(stale, username: &user, password: &secret, retention: .session); throw Failure(message: "Stale reply accepted") }
  catch is NativeError {}
  try check(secret.allSatisfy { $0 == 0 } && !model.credentials.hasSessionCredential, "stale failure clears input")

  _ = try await start(); try submit(model, .session); try await connected()
  model.requestClose()
  try check(!model.credentials.hasSessionCredential, "window close immediately clears retained secret")
  await model.close()
  // Closing a window must join an already running save without clearing its
  // buffer under the backend or falsely reporting that a committed write rolled back.
  other.endpoint = endpoint; other.connect(); try await until { other.session?.prompt != nil }
  vault.blockNextSave(); try submit(other, .replaceRemembered)
  try await until { vault.saveEntered.wait(timeout: .now()) == .success }
  var closed = false
  let closing = Task { await other.close(); closed = true }
  try await Task.sleep(for: .milliseconds(20))
  try check(!closed && other.closing, "window close waits asynchronously for running save")
  vault.saveRelease.signal(); await closing.value
  try check(closed && !other.credentials.isWorking && other.credentials.notice == nil && vault.calls.last == "replace", "close drains committed save without resurrecting UI")
  await store.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS use-once/session/remember, post-success save, explicit reuse/replace/forget, rejection, cancellation, isolation and joined shutdown")
}
@main struct NativeCredentialRetentionTests {
  @MainActor static func main() async {
    do { try await run(); try await routeScopes() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}

@MainActor func routeScopes() async throws {
  let runtime = try NativeRuntime(), vault = Vault(), store = NativeCredentialStore(backing:vault)
  var configuration = NativeSessionConfiguration(); configuration.securityTypes = [2]
  let session = try runtime.makeSession(configuration:configuration)
  let credentials = NativeAuthenticationCredentials(store:store); credentials.bind(session)
  let peer = native_test_peer_create_reconnecting(1)!
  defer { native_test_peer_destroy(peer) }
  let endpoint = "127.0.0.1::\(native_test_peer_port(peer))"
  let keyA = try NativeCredentialKey(endpoint:endpoint,routeIdentity:"gateway-A",authentication:.passwordOnly(securityType:2))
  let keyB = try NativeCredentialKey(endpoint:endpoint,routeIdentity:"gateway-B",authentication:.passwordOnly(securityType:2))
  let direct = try NativeCredentialKey(endpoint:endpoint,authentication:.passwordOnly(securityType:2))
  func start(_ route: String) async throws -> (NativePrompt,Task<NativeCompletion,Error>) {
    credentials.beginAttempt(endpoint:endpoint,routeIdentity:route)
    let operation = Task {
      if route.isEmpty { return try await session.connect(endpoint:endpoint) }
      return try await session.connect(endpoint:endpoint,through:endpoint,routeIdentity:route)
    }
    try await until { session.prompt != nil }
    return (session.prompt!,operation)
  }
  func answer(_ prompt: NativePrompt,_ retention: NativeCredentialRetention) throws {
    var user: [UInt8] = [], password = Array("password".utf8)
    try credentials.submit(prompt,username:&user,password:&password,retention:retention)
  }
  func finish(_ operation: Task<NativeCompletion,Error>) async throws {
    _ = try await operation.value; credentials.observe(session.snapshot)
    try await until { !credentials.isWorking }
    _ = try await session.disconnect(); credentials.observe(session.snapshot)
  }
  let (first,firstOperation) = try await start("gateway-A")
  try answer(first,.remember); try await finish(firstOperation)
  try check(vault.contains(keyA) && !vault.contains(keyB) && !vault.contains(direct),"remembered password belongs to target plus route")
  let (second,secondOperation) = try await start("gateway-B")
  credentials.useSaved(second,username:""); try await until { !credentials.isWorking }
  try check(session.prompt == second && credentials.notice?.contains("No saved password") == true,"another gateway cannot read the remembered password")
  try answer(second,.session); try await finish(secondOperation)
  let (same,sameOperation) = try await start("gateway-B")
  try check(credentials.canUseSession(same,username:""),"session credential survives a retry on the same route")
  try credentials.useSession(same,username:""); try await finish(sameOperation)
  let (changed,changedOperation) = try await start("gateway-A")
  try check(!credentials.hasSessionCredential && !credentials.canUseSession(changed,username:""),"route change clears retained session credential")
  credentials.useSaved(changed,username:""); try await finish(changedOperation)
  let (plain,plainOperation) = try await start("")
  credentials.useSaved(plain,username:""); try await until { !credentials.isWorking }
  try check(session.prompt == plain && credentials.notice?.contains("No saved password") == true,"direct connection cannot read tunnel credentials")
  try answer(plain,.useOnce); try await finish(plainOperation)
  await credentials.close(); await store.close(); try await runtime.shutdown()
  print("PASS credential retention and remembered lookup isolate gateway routes and direct connections")
}
