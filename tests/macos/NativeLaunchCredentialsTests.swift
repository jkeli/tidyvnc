// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
@testable import TidyVNCNative
struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"Unexpected preferences write") }
}
final class Vault: NativeCredentialBacking, @unchecked Sendable {
  private let lock = NSLock(); private var operations = 0
  var count: Int { lock.withLock { operations } }
  func fail() throws -> Never { lock.withLock { operations += 1 }; throw NativeCredentialStoreIssue.unavailable }
  func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialSecret { try fail() }
  func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode, interaction: NativeCredentialInteraction) throws { try fail() }
  func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws { try fail() }
  func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadata { try fail() }
  func listMetadata(limit: Int, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadataPage { try fail() }
}
actor Reader: NativePasswordFileReading {
  var calls = 0, blocked = false, failing = false
  var paths: [String] = []
  var release: CheckedContinuation<Void,Never>?
  var last: NativeCredentialSecret?
  func hold() { blocked = true }
  func fail() { failing = true }
  func resume() { blocked = false; release?.resume(); release = nil }
  func read(_ url: URL) async throws -> NativeCredentialSecret {
    calls += 1; paths.append(url.path)
    if blocked { await withCheckedContinuation { release = $0 } }
    if failing { throw NativePasswordFileIssue.unreadable }
    var cipher: [UInt8] = [0xdb,0xd8,0x3c,0xfd,0x72,0x7a,0x14,0x58]
    let value = try NativeCredentialSecret(consuming:&cipher); last = value; return value
  }
}
final class Peer: @unchecked Sendable {
  let raw: UnsafeMutableRawPointer
  init(user: [UInt8]? = nil, password: [UInt8] = Array("password".utf8)) throws {
    let pointer: UnsafeMutableRawPointer?
    if let user {
      pointer = user.withUnsafeBufferPointer { u in password.withUnsafeBufferPointer { p in
        native_test_peer_create_plain(u.baseAddress,UInt32(u.count),p.baseAddress,UInt32(p.count))
      } }
    } else { pointer = native_test_peer_create_reconnecting(1) }
    guard let pointer else { throw Failure(message:"Credential peer fixture failed") }
    raw = pointer
  }
  var endpoint: String { "127.0.0.1::\(native_test_peer_port(raw))" }
  var verified: Bool { native_test_peer_verified(raw) != 0 }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func until(_ condition: () async -> Bool) async throws {
  for _ in 0..<3000 { if await condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Launch credential lifecycle timed out")
}
func inputs(user: [UInt8]? = nil, password: [UInt8]? = nil, file: URL? = nil) throws -> NativeLaunchCredentialInputs {
  var u = user, p = password
  let value = try NativeLaunchCredentialInputs(username:&u,password:&p,passwordFile:file)
  try check(u?.allSatisfy { $0 == 0 } ?? true,"username capture consumed")
  try check(p?.allSatisfy { $0 == 0 } ?? true,"password capture consumed")
  try check(!String(reflecting:value).contains("password"),"redacted owner description")
  return value
}
@MainActor func run(capture: Bool) async throws {
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing:Preferences())
  let vault = Vault(), store = NativeCredentialStore(backing:vault)
  let file = URL(fileURLWithPath:"/private-fixture/passwd")
  func model(_ input: NativeLaunchCredentialInputs?, _ peer: Peer, reader: Reader = Reader(), plain: Bool = false, fileOption: Bool = false) throws -> ConnectionModel {
    var arguments = plain ? ["-SecurityTypes=Plain"] : ["-SecurityTypes=VncAuth"]
    if fileOption { arguments.append("-passwd=relative-password") }
    let options = try NativeInvocationOptions(arguments:arguments)
    return ConnectionModel(runtime:runtime,preferences:preferences,
      invocation:NativeInvocationRequest(options:options,endpoint:peer.endpoint,workingDirectory:"/launch"),
      launchCredentials:input,passwordFileReader:reader,credentialStore:store) { _,_ in }
  }
  func start(_ value: ConnectionModel) async throws {
    try await until { value.canConnect }; value.connect()
  }
  func connected(_ value: ConnectionModel) async throws {
    try await until { !value.busy && value.session?.snapshot.state == .connected && !value.credentials.isWorking }
  }
  if capture {
    // CTest supplies both variables with fixture values; never inspect the user's
    // ambient credentials in the ordinary fixture invocation.
    let peer = try Peer(), captured = try NativeLaunchCredentialInputs.capture(passwordFile:nil)
    let value = try model(captured,peer)
    try await start(value); try await connected(value)
    try check(peer.verified,"bounded getenv capture authenticates")
    try check(NativePathEnvironment.capture()["VNC_PASSWORD"] == nil,"storage environment excludes credentials")
    await value.close()
  } else {
    var huge: [UInt8]? = [UInt8](repeating:0x55,count:4097), other: [UInt8]? = [1]
    do { _ = try NativeLaunchCredentialInputs(username:&other,password:&huge); throw Failure(message:"Oversized capture accepted") }
    catch NativeLaunchCredentialIssue.invalidEnvironment {}
    try check(huge!.allSatisfy { $0 == 0 } && other!.allSatisfy { $0 == 0 },"failed capture clears both inputs")
    let unclaimed = try inputs(password:Array("password".utf8))
    var startupLaunch = try NativeInvocationBootstrap.launch(.init(arguments:[]),workingDirectory:"/launch")
    startupLaunch.credentials = unclaimed
    let startup = NativeInvocationStartup(startupLaunch); startup.stop()
    if unclaimed.claim() != nil { throw Failure(message:"Stopped startup retained credentials") }
    let selected = try NativeLaunchCredentialInputs.passwordFile(.init(arguments:["-passwd=first","-PasswordFile=second"]),workingDirectory:"/launch")
    try check(selected?.path == "/launch/second","last path uses captured cwd")
    let disabled = try NativeLaunchCredentialInputs.passwordFile(.init(arguments:["-passwd=first","-PasswordFile="]),workingDirectory:"/launch")
    try check(disabled == nil,"explicit empty path disables file")
    do { _ = try NativeLaunchCredentialInputs.passwordFile(.init(arguments:["-passwd=relative"]),workingDirectory:nil); throw Failure(message:"Relative path lost cwd") }
    catch let error as NativeInvocationResolutionFailure { try check(error.argument == 1,"path error retains argument") }

    // Environment wins over the file, remains scoped to one claim, and preserves
    // non-UTF-8 bytes. A second window cannot reuse the same handoff object.
    let peer = try Peer(), reader = Reader()
    let handoff = try inputs(password:[0xf0,0xe1,0xf3,0xf3,0xf7,0xef,0xf2,0xe4],file:file)
    let first = try model(handoff,peer,reader:reader)
    let independentPeer = try Peer(), second = try model(handoff,independentPeer)
    try await start(first); try await connected(first)
    try check(peer.verified,"raw environment password response")
    let reads = await reader.calls; try check(reads == 0 && vault.count == 0,"environment precedes file without vault access")
    native_test_peer_disconnect(peer.raw)
    try await until { !first.busy && [.closed,.failed].contains(first.session!.snapshot.state) }
    try await start(first); try await connected(first)
    try await start(second); try await until { second.session?.prompt != nil }
    try check(!second.credentials.isWorking && !independentPeer.verified,"second claim gets no credential")
    second.cancel(); await second.close(); await first.close()

    // Both raw environment fields are required for username/password auth;
    // explicitly empty fields count as present, and files never answer it.
    for pair in [([UInt8]([0xff,0x61]),[UInt8]([0xfe,0x62])),([],[])] {
      let peer = try Peer(user:pair.0,password:pair.1), reader = Reader()
      let value = try model(inputs(user:pair.0,password:pair.1,file:file),peer,reader:reader,plain:true)
      try await start(value); try await connected(value)
      let reads = await reader.calls
      try check(peer.verified && reads == 0,"raw complete environment pair reaches Plain unchanged")
      await value.close()
    }
    let plainPeer = try Peer(user:Array("user".utf8)), plainReader = Reader()
    let incomplete = try model(inputs(password:Array("password".utf8),file:file),plainPeer,reader:plainReader,plain:true)
    try await start(incomplete); try await until { incomplete.session?.prompt != nil }
    try await Task.sleep(for:.milliseconds(30))
    let ineligibleReads = await plainReader.calls
    try check(incomplete.session?.prompt?.usernameRequired == true && ineligibleReads == 0 && !incomplete.credentials.isWorking,"incomplete pair and file leave username prompt interactive")
    incomplete.cancel(); await incomplete.close()

    let filePeer = try Peer(), fileReader = Reader()
    let fromFile = try model(inputs(user:Array("unused".utf8),file:file),filePeer,reader:fileReader)
    try await start(fromFile); try await connected(fromFile)
    let fileReads = await fileReader.calls
    try check(fileReads == 1 && filePeer.verified,"username-only environment permits password file")
    let block = await fileReader.last!
    do { _ = try block.copyBytes(); throw Failure(message:"File block retained after submission") }
    catch NativeCredentialStoreIssue.secretCleared {}
    await fromFile.close()

    let invokedPeer = try Peer(), invokedReader = Reader()
    let invoked = try model(nil,invokedPeer,reader:invokedReader,fileOption:true)
    try await until { invoked.canConnect }
    let beforePrompt = await invokedReader.calls
    try check(beforePrompt == 0,"CLI file admission does not read before authentication")
    try await start(invoked); try await connected(invoked)
    let invokedPaths = await invokedReader.paths
    try check(invokedPaths == ["/launch/relative-password"] && invokedPeer.verified,"injected invocation applies cwd-anchored file policy without environment capture")
    await invoked.close()

    // A failed file is explicit and keeps an interactive prompt. A manually
    // retained password wins over the file on an unexpected reconnect.
    let retryPeer = try Peer(), failing = Reader(); await failing.fail()
    let retry = try model(inputs(file:file),retryPeer,reader:failing)
    try await start(retry); try await until { retry.credentials.notice != nil && !retry.credentials.isWorking }
    try check(retry.session?.prompt != nil && !retry.credentials.notice!.contains("private-fixture"),"file error is fixed and recoverable")
    var user: [UInt8] = [], password = Array("password".utf8)
    try retry.credentials.submit(retry.session!.prompt!,username:&user,password:&password,retention:.session)
    try await connected(retry); native_test_peer_disconnect(retryPeer.raw)
    try await until { !retry.busy && [.closed,.failed].contains(retry.session!.snapshot.state) }
    try await start(retry); try await connected(retry)
    let retryReads = await failing.calls
    try check(retryReads == 1 && retry.credentials.hasSessionCredential,"retained password precedes file reread")
    await retry.close()

    // Editing the initially bound destination revokes all automatic inputs.
    let oldPeer = try Peer(), newPeer = try Peer()
    let edited = try model(inputs(password:Array("password".utf8)),oldPeer)
    try await until { edited.canConnect }; edited.endpoint = newPeer.endpoint
    try await start(edited); try await until { edited.session?.prompt != nil }
    try check(!newPeer.verified && !edited.credentials.isWorking,"edited endpoint cannot receive launch secret")
    edited.cancel(); await edited.close()

    // Explicit cancellation revokes the launch source, discards a late read and
    // keeps reconnect admission closed until the provider has actually returned.
    let cancelledPeer = try Peer(), cancelledReader = Reader(); await cancelledReader.hold()
    let cancelled = try model(inputs(file:file),cancelledPeer,reader:cancelledReader)
    try await start(cancelled); try await until { await cancelledReader.calls == 1 }
    cancelled.cancel(); try await until { !cancelled.busy && cancelled.session?.prompt == nil }
    try check(cancelled.credentials.isWorking && !cancelled.canConnect,"cancel waits for read before retry admission")
    await cancelledReader.resume(); try await until { !cancelled.credentials.isWorking }
    let cancelledBlock = await cancelledReader.last!
    do { _ = try cancelledBlock.copyBytes(); throw Failure(message:"Cancelled read retained its block") }
    catch NativeCredentialStoreIssue.secretCleared {}
    try await start(cancelled); try await until { cancelled.session?.prompt != nil }
    let afterCancelReads = await cancelledReader.calls
    try check(afterCancelReads == 1 && !cancelled.credentials.isWorking,"cancelled launch source is not replayed")
    cancelled.cancel(); await cancelled.close()

    // A deliberately cancellation-insensitive provider proves close joins IO and
    // destroys its late result without a reply or any observable secret/notice.
    let slowPeer = try Peer(), slow = Reader(); await slow.hold()
    let closing = try model(inputs(file:file),slowPeer,reader:slow)
    try await start(closing); try await until { await slow.calls == 1 }
    var drained = false
    let close = Task { await closing.close(); drained = true }
    try await Task.sleep(for:.milliseconds(30))
    try check(!drained && closing.closing && closing.session?.prompt == nil,"close waits for outstanding credential IO")
    await slow.resume(); await close.value
    let late = await slow.last!
    do { _ = try late.copyBytes(); throw Failure(message:"Late file block survived close") }
    catch NativeCredentialStoreIssue.secretCleared {}
    try check(!slowPeer.verified && closing.credentials.notice == nil && !closing.credentials.isWorking,"late result cannot resurrect authentication")
  }
  try check(vault.count == 0,"automatic sources never access Keychain")
  await store.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS launch credential ownership, precedence, raw bytes, endpoint scope and drained cancellation")
}
@main struct NativeLaunchCredentialsTests {
  @MainActor static func main() async throws { try await run(capture:CommandLine.arguments.contains("--capture")) }
}
