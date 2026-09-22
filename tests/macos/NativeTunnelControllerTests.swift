// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
final class Memory: NativePreferencesBacking, Sendable {
  func read() -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"unexpected preferences write") }
}
final class Peer: @unchecked Sendable {
  let raw: UnsafeMutableRawPointer
  init(authentication: UInt32 = 0) throws {
    guard let raw = native_test_peer_create_reconnecting(authentication) else { throw Failure(message:"peer") }
    self.raw = raw
  }
  deinit { native_test_peer_destroy(raw) }
}
final class Vault: NativeCredentialBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [NativeCredentialKey:[UInt8]] = [:]
  func seed(_ key: NativeCredentialKey) { lock.withLock { entries[key] = Array("password".utf8) } }
  func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialSecret {
    try lock.withLock {
      guard var bytes = entries[key] else { throw NativeCredentialStoreIssue.notFound }
      return try .init(consuming:&bytes)
    }
  }
  func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode, interaction: NativeCredentialInteraction) throws {
    throw Failure(message:"unexpected credential write")
  }
  func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws { throw Failure(message:"unexpected credential deletion") }
  func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadata { throw NativeCredentialStoreIssue.notFound }
  func listMetadata(limit: Int, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadataPage { .init(entries:[],hasMore:false) }
}
final class TrustMemory: NativeAtomicFileBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func read() throws -> Data? { lock.withLock { data } }
  func replace(_ value: Data, expected: Data?) throws {
    try lock.withLock {
      guard data == expected else { throw NativeStorageError.conflict }
      data = value
    }
  }
}
// This target checks the app controller's published trust scope with real DER.
// TLS wire verification itself remains covered by the protocol trust fixtures.
@MainActor final class CertificateTarget: NativeTrustTarget {
  var prompt: NativePrompt?, generation: UInt64 = 1, isClosing = false, replies = 0
  func replyTrust(to request: NativePrompt, allowed: Bool) throws {
    try check(prompt == request && allowed,"current scoped certificate approval")
    replies += 1; prompt = nil
  }
}
struct ScopeFixtureKey: NativeCertificateKeyMaterial {
  let spki = trustFixtureSPKI
  func digest(_ algorithm: UInt32) throws -> Data { throw NativeTrustStoreIssue.unsupportedDigest }
}
final class Paths: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ path: String) { lock.withLock { values.append(path) } }
  var all: [String] { lock.withLock { values } }
  var gone: Bool { all.allSatisfy { !FileManager.default.fileExists(atPath:URL(fileURLWithPath:$0).deletingLastPathComponent().path) } }
}
// Keep the real process and forwarding service under the production controller,
// while observing transport state at the precise ordinary close boundary.
@MainActor final class ObservedTunnel: NativeTunnelOwning {
  let request: NativeSSHTunnelRequest
  let inner: NativeSSHTunnel
  let paths = Paths()
  weak var session: NativeSession?
  var closes = 0
  var closed = false
  var drainedBeforeClose = true
  var holdClose = false
  var holdPreparation = false
  var preparing = false
  var preparationDrained = false
  init(_ request: NativeSSHTunnelRequest, executable: String, behavior: String, port: UInt32, sshFiles: (key:String,known:String)? = nil) {
    self.request = request
    let paths = paths
    inner = NativeSSHTunnel(request:request,executable:executable,timeout:.seconds(5)) { command,socket in
      paths.add(socket)
      if let sshFiles {
        return ["-i",sshFiles.key,"-o","IdentitiesOnly=yes","-o","IdentityAgent=none",
          "-o","UserKnownHostsFile=\(sshFiles.known)","-o","GlobalKnownHostsFile=/dev/null"] + request.arguments(command,socket:socket)
      }
      return [command.rawValue,socket,behavior,String(port)]
    }
  }
  func prepare() async throws -> String? {
    preparing = true
    defer { preparationDrained = true }
    while holdPreparation { try await Task.sleep(for:.milliseconds(2)) }
    return nil
  }
  func start() async throws -> NativeTunnelRoute { try await inner.start() }
  func waitForExit() async -> NativeTunnelExit? { await inner.waitForExit() }
  func close() async {
    closes += 1
    if let session { drainedBeforeClose = drainedBeforeClose && [.idle,.closed,.failed].contains(session.snapshot.state) }
    while holdClose { try? await Task.sleep(for:.milliseconds(2)) }
    await inner.close(); closed = true
  }
}
@MainActor func until(_ label: String, _ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"timed out: " + label)
}
@MainActor final class Harness {
  let runtime: NativeRuntime
  let store = NativePreferencesStore(backing:Memory())
  let peerOwner: Peer
  var peer: UnsafeMutableRawPointer { peerOwner.raw }
  var owners: [ObservedTunnel] = []
  var model: ConnectionModel?
  let executable: String
  init(executable: String, authentication: UInt32 = 0) throws {
    runtime = try NativeRuntime(); self.executable = executable
    peerOwner = try Peer(authentication:authentication)
  }
  func prepare(behavior: String = "ready", credentialStore: NativeCredentialStore? = nil,
               sshFiles: (key:String,known:String)? = nil, gateway: String = "alice@gateway.invalid",
               launch: NativeInvocationLaunch? = nil, holdPreparation: Bool = false) async throws {
    let executable = executable, port = UInt32(native_test_peer_port(peer))
    model = ConnectionModel(runtime:runtime,preferences:store,document:launch?.document,invocation:launch?.invocation,
      launchCredentials:launch?.credentials,credentialStore:credentialStore,tunnelFactory:{ [unowned self] request in
      let owner = ObservedTunnel(request,executable:executable,behavior:behavior,port:port,sshFiles:sshFiles)
      owner.holdPreparation = holdPreparation
      owner.session = self.model?.session; self.owners.append(owner); return owner
    }) { _,_ in }
    try await until("defaults") { self.model?.defaults?.isReady == true || self.model?.defaults?.documentReview != nil }
    if let review = model!.defaults?.documentReview {
      try check(model!.session == nil && owners.isEmpty,"file review precedes session and tunnel allocation")
      model!.defaults!.acceptDocument(review.id)
    }
    if launch == nil {
      model!.selectDestination(.init(endpoint:sshFiles == nil ? "remote.invalid:3" : "127.0.0.1::\(port)",sshGateway:try NativeSSHGateway(gateway)))
    }
    try check(model!.canConnect,"ready routed destination")
  }
  func connect() async throws {
    model!.connect()
    try await until("connected") { self.model?.session?.snapshot.state == .connected && self.model?.busy == false }
  }
  func finish() async throws {
    await model?.close(); model = nil
    try await until("owners drained") { self.owners.allSatisfy(\.closed) }
    try check(owners.allSatisfy { $0.closes == 1 && $0.drainedBeforeClose && $0.paths.gone },"one joined tunnel close after RFB drain")
    try await runtime.shutdown(); await store.close()
  }
}
@MainActor func preparationCancellation(executable: String) async throws {
  for close in [false,true] {
    let h = try Harness(executable:executable)
    try await h.prepare(holdPreparation:true)
    h.model!.connect()
    try await until("preparation entered") { h.owners.first?.preparing == true }
    try check(h.model!.session?.snapshot.state == .idle && h.owners[0].paths.all.isEmpty,
      "preparation precedes SSH and RFB admission")
    if close { h.model!.requestClose() } else { h.model!.cancel() }
    try await until("preparation cancellation joined") { h.owners[0].closed && !h.model!.busy }
    try check(h.owners[0].preparationDrained && h.owners[0].paths.all.isEmpty,
      "cancelled preparation cannot start SSH")
    try await h.finish()
  }
}
@MainActor func startup(executable: String) async throws {
  for behavior in ["no-ready","hang-forward"] {
    for close in [false,true] {
      let h = try Harness(executable:executable); try await h.prepare(behavior:behavior)
      h.model!.connect()
      try await until("startup phase") { h.owners.first!.paths.all.count >= (behavior == "hang-forward" ? 3 : 1) }
      try check(!h.model!.canConnect,"no second startup")
      if close { h.model!.requestClose(); h.model!.requestClose() }
      else { h.model!.cancel() }
      try await until("startup revoked") { h.owners.first!.closed && !h.model!.busy }
      try check(h.model!.session?.snapshot.state != .connected,"cancelled startup never admits RFB")
      try await h.finish()
    }
  }
}
@MainActor func lifecycle(executable: String) async throws {
  let h = try Harness(executable:executable); try await h.prepare(); try await h.connect()
  let first = h.owners[0]
  try check(try h.model!.documentExport(legacyDisplays:[]).losses.contains(.sshGateway),"live export requires route-loss review")
  first.holdClose = true; h.model!.disconnect()
  try await until("transport drained before tunnel close") { first.closes == 1 }
  try check(!h.model!.canConnect && !h.model!.canEditDestination,"cleanup blocks replacement destination")
  h.model!.connect(); try check(h.owners.count == 1,"cleanup blocks new owner")
  first.holdClose = false
  try await until("reusable") { h.model!.canConnect }
  try await h.connect(); try check(h.owners.count == 2,"reconnect gets fresh owner")
  native_test_peer_disconnect(h.peer)
  try await until("remote disconnect reaps tunnel") { h.owners[1].closed && h.model!.canConnect }
  try await h.connect()
  // Killing the actual owned child wakes the matching controller observer.
  await h.owners[2].inner.close()
  try await until("child exit drains RFB") { h.owners[2].closed && h.model!.canConnect }
  // Socket EOF and process exit can arrive in either order; both must surface
  // a failure while sharing the same cleanup owner.
  try check(h.model!.message != nil || h.model!.connectionProblem != nil,"child failure is presented")
  try await h.connect()
  try check(h.model!.message == nil && h.model!.session?.snapshot.state == .connected,"old exits do not fail replacement")
  h.model!.requestClose(); h.model!.requestClose(); try await h.finish()
}
@MainActor func admissionCancellation(executable: String) async throws {
  let h = try Harness(executable:executable); try await h.prepare()
  var cancelled = false
  let observation = h.model!.session!.$snapshot.sink { snapshot in
    MainActor.assumeIsolated {
      if snapshot.state == .connected && !cancelled { cancelled = true; h.model!.cancel() }
    }
  }
  h.model!.connect()
  try await until("committed connect cancellation drained") { cancelled && h.owners.first?.closed == true && h.model!.canConnect }
  observation.cancel()
  try await h.connect(); try await h.finish()
}
@MainActor func dropped(executable: String) async throws {
  let h = try Harness(executable:executable); try await h.prepare(); try await h.connect()
  weak let presentation = h.model
  h.model = nil
  try await until("dropped presentation") { presentation == nil && h.owners[0].closed }
  try await h.finish()
}
@MainActor func credentials(executable: String) async throws {
  let vault = Vault(), store = NativeCredentialStore(backing:vault)
  let h = try Harness(executable:executable,authentication:1)
  try await h.prepare(credentialStore:store)
  let model = h.model!, gateway = model.sshGateway!
  // A numeric logical target also permits checking the direct route against
  // the exact same saved target, without depending on external DNS.
  model.endpoint = "127.0.0.1::\(native_test_peer_port(h.peer))"
  vault.seed(try NativeCredentialKey(endpoint:model.endpoint,routeIdentity:gateway.routeIdentity,authentication:.passwordOnly(securityType:2)))
  func prompt() async throws -> NativePrompt {
    model.connect(); try await until("routed authentication") { model.session?.prompt != nil }
    return model.session!.prompt!
  }
  func connected() async throws {
    try await until("authenticated") { model.session?.snapshot.state == .connected && !model.busy && !model.credentials.isWorking }
  }
  func remoteClose() async throws {
    native_test_peer_disconnect(h.peer); try await until("remote auth close") { model.canConnect }
  }
  let first = try await prompt()
  model.credentials.useSaved(first,username:"",retention:.session); try await connected(); try await remoteClose()
  let retry = try await prompt()
  try check(model.credentials.canUseSession(retry,username:""),"controller preserves same-route retry credentials")
  try model.credentials.useSession(retry,username:""); try await connected(); try await remoteClose()
  model.sshGatewayText = "bob@gateway.invalid"
  let changed = try await prompt()
  try check(!model.credentials.hasSessionCredential,"controller clears retained credential on route change")
  model.credentials.useSaved(changed,username:"")
  try await until("different route lookup") { !model.credentials.isWorking }
  try check(model.session?.prompt == changed && model.credentials.notice?.contains("No saved password") == true,"different gateway cannot use saved credential")
  model.cancel(); try await until("authentication cancellation") { model.canConnect }
  model.sshGatewayText = ""
  let direct = try await prompt()
  model.credentials.useSaved(direct,username:"")
  try await until("direct lookup") { !model.credentials.isWorking }
  try check(model.session?.prompt == direct && model.credentials.notice?.contains("No saved password") == true,"direct route cannot use gateway credential")
  model.requestClose(); model.requestClose(); try await h.finish(); await store.close()
}
@MainActor func configuredScopes(gateway: String, key: String, known: String) async throws {
  let h = try Harness(executable:"/usr/bin/ssh",authentication:1)
  let vault = Vault(), credentials = NativeCredentialStore(backing:vault)
  let material: any NativeCertificateKeyMaterial
  do { material = try NativeCertificateKey(certificate:trustFixtureCertificate) }
  catch let error as NativeError where error.status == .unsupported {
    // Sanitizer configurations omit GnuTLS. This case tests route publication,
    // not its separately tested DER/SPKI codec; keep the capability limit visible.
    material = ScopeFixtureKey()
    print("NOTE scope fixture uses public SPKI because this build omits certificate-key extraction")
  }
  let trust = NativeTrustStore(backing:TrustMemory(),makeKey:{ data in
    guard data == trustFixtureCertificate else { throw NativeTrustStoreIssue.corrupt }
    return material
  }), target = CertificateTarget()
  let home = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("tidyvnc-scope-home-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:home) }
  do {
    let directory = home.appendingPathComponent(".ssh")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let destination = try NativeSSHGateway(gateway)
    let file = directory.appendingPathComponent("config")
    func configure(host: String) throws {
      let text = "Host scope-alias\n HostName \(host)\n User \(destination.user!)\n Port \(destination.port)\n HostKeyAlias [\(destination.host)]:\(destination.port)\n IdentityFile \(key)\n IdentitiesOnly yes\n IdentityAgent none\n UserKnownHostsFile \(known)\n GlobalKnownHostsFile /dev/null\n"
      try Data(text.utf8).write(to:file)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    try configure(host:destination.host)
    let alias = try NativeSSHGateway("scope-alias")
    let prepared = try await NativeSSHPreparedGateway.prepareDefault(requested:alias,home:home)
    let route = prepared.resolved.routeIdentity
    await prepared.close()
    let endpoint = "127.0.0.1::\(native_test_peer_port(h.peer))"
    vault.seed(try NativeCredentialKey(endpoint:endpoint,routeIdentity:route,authentication:.passwordOnly(securityType:2)))
    let initial = try await trust.read()
    _ = try await trust.save(scope:NativeTrustScope(endpoint:endpoint,routeIdentity:route),certificate:trustFixtureCertificate,
      status:66,replacing:false,expected:initial.revision)
    h.model = ConnectionModel(runtime:h.runtime,preferences:h.store,credentialStore:credentials,savedTrustStore:trust,
      tunnelFactory:{ NativeConfiguredSSHTunnel(request:$0,home:home) }) { _,_ in }
    try await until("scope defaults") { h.model?.defaults?.isReady == true }
    let model = h.model!
    model.selectDestination(.init(endpoint:endpoint,sshGateway:alias))
    model.trust.bind(target)
    func authentication() async throws -> NativePrompt {
      model.connect()
      try await until("configured scope authentication") { model.session?.prompt != nil }
      return model.session!.prompt!
    }
    func connected() async throws {
      try await until("configured scope connected") { model.session?.snapshot.state == .connected && !model.busy && !model.credentials.isWorking }
    }
    func certificate(approved: Bool) async throws {
      let before = target.replies
      target.generation += 1
      target.prompt = .init(id:target.generation,generation:target.generation,kind:.certificate,secure:false,
        usernameRequired:false,certificateStatus:66,serverName:"fixture.invalid",fingerprint:"",identity:trustFixtureCertificate)
      model.trust.inspect(target.prompt)
      try await until("configured scope trust lookup") { !model.trust.isWorking }
      try check(target.replies == before + (approved ? 1 : 0),"native certificate approval follows effective route")
      try check(model.trust.savedInspection?.state == (approved ? .match : .absent),"native certificate record remains route scoped")
    }
    func remoteClose() async throws {
      native_test_peer_disconnect(h.peer)
      try await until("configured scope remote close") { model.canConnect }
    }
    let first = try await authentication()
    model.credentials.useSaved(first,username:"",retention:.session)
    try await connected(); try await certificate(approved:true); try await remoteClose()
    let retry = try await authentication()
    try check(model.credentials.canUseSession(retry,username:""),"unchanged resolution retains explicit session password")
    try model.credentials.useSession(retry,username:"")
    try await connected(); try await certificate(approved:true); try await remoteClose()
    try configure(host:"localhost")
    for direct in [false,true] {
      if direct { model.sshGatewayText = "" }
      let changed = try await authentication()
      try check(!model.credentials.hasSessionCredential,"changed effective or direct route forgets retained password")
      model.credentials.useSaved(changed,username:"")
      try await until("changed route saved lookup") { !model.credentials.isWorking }
      try check(model.session?.prompt == changed && model.credentials.notice?.contains("No saved password") == true,
        "same requested alias cannot reuse the old effective-route saved password")
      var user: [UInt8] = [], password = Array("password".utf8)
      try model.session!.replyCredentials(to:changed,username:&user,password:&password)
      try await connected(); try await certificate(approved:false); try await remoteClose()
    }
    let saved = try await trust.read()
    try check(saved.entries.count == 1,"route changes preserve the original trust record")
    try await h.finish(); await credentials.close(); await trust.close()
  } catch {
    try? await h.finish(); await credentials.close(); await trust.close(); throw error
  }
}
@MainActor func realSSH(gateway: String, key: String, known: String) async throws {
  let rejected = try Harness(executable:"/usr/bin/ssh")
  try await rejected.prepare(sshFiles:(key,known + ".missing"),gateway:gateway)
  rejected.model!.connect()
  try await until("unknown key rejected before RFB") { rejected.owners.first?.closed == true && rejected.model!.canConnect }
  try check(rejected.model!.session?.snapshot.state == .idle && rejected.model!.message != nil,"unknown SSH key cannot admit RFB")
  try await rejected.finish()
  let h = try Harness(executable:"/usr/bin/ssh")
  try await h.prepare(sshFiles:(key,known),gateway:gateway); try await h.connect()
  native_test_peer_disconnect(h.peer)
  try await until("real SSH remote close") { h.owners[0].closed && h.model!.canConnect }
  try await h.connect(); await h.owners[1].inner.close()
  try await until("real SSH child exit") { h.owners[1].closed && h.model!.canConnect }
  try await h.connect(); h.model!.requestClose(); h.model!.requestClose(); try await h.finish()
  let configured = try Harness(executable:"/usr/bin/ssh",authentication:1)
  do {
    let home = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("tidyvnc-controller-home-" + UUID().uuidString)
    let directory = home.appendingPathComponent(".ssh")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:home) }
    let target = try NativeSSHGateway(gateway)
    let configuration = "Host controller-alias\n HostName \(target.host)\n User \(target.user!)\n Port \(target.port)\n IdentityFile \(key)\n IdentitiesOnly yes\n IdentityAgent none\n UserKnownHostsFile \(known)\n GlobalKnownHostsFile /dev/null\n"
    let file = directory.appendingPathComponent("config")
    try Data(configuration.utf8).write(to:file)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    var launch = try NativeInvocationBootstrap.launch(.init(arguments:["-via=controller-alias","127.0.0.1::\(native_test_peer_port(configured.peer))"]),workingDirectory:home.path)
    var username: [UInt8]?, password: [UInt8]? = Array("password".utf8)
    launch.credentials = try .init(username:&username,password:&password)
    configured.model = ConnectionModel(runtime:configured.runtime,preferences:configured.store,invocation:launch.invocation,
      launchCredentials:launch.credentials,tunnelFactory:{ NativeConfiguredSSHTunnel(request:$0,home:home) }) { _,_ in }
    try await until("configured defaults") { configured.model?.canConnect == true }
    do { try await configured.connect() } catch { throw Failure(message:"configured connection: \(configured.model!.message ?? String(describing:configured.model!.session?.snapshot.state)); prompt=\(String(describing:configured.model!.session?.prompt))") }
    try check(configured.model!.sshGateway?.host == "controller-alias" && configured.model!.session?.prompt == nil,
      "requested alias remains editable while launch credentials bind to resolved route")
    configured.model!.disconnect()
    try await until("configured disconnected") { configured.model!.canConnect }
    configured.model!.connect()
    try await until("fresh credential after explicit disconnect") { configured.model!.session?.prompt != nil }
    var retryUser: [UInt8] = [], retryPassword = Array("password".utf8)
    try configured.model!.session!.replyCredentials(to:configured.model!.session!.prompt!,username:&retryUser,password:&retryPassword)
    try await until("configured reconnected") { configured.model!.session?.snapshot.state == .connected && !configured.model!.busy }
    configured.model!.disconnect()
    try await until("configured second disconnect") { configured.model!.canConnect }
    try Data("Host *\n ProxyCommand forbidden-command\n".utf8).write(to:file)
    configured.model!.connect()
    try await until("configuration rejected") { configured.model!.canConnect && configured.model!.message != nil }
    try check(configured.model!.session?.snapshot.state != .connected,
      "fresh attempt rejects unsupported configuration before RFB admission")
    try await configured.finish()
  } catch {
    try? await configured.finish()
    throw error
  }
  print("PASS controller with isolated OpenSSH: key rejection, forwarding, remote/child exit, fresh reconnect and joined close")
}
@MainActor func invocation(executable: String) async throws {
  let gateway = try NativeSSHGateway("ssh://alice@gateway.invalid:2222")
  let file = URL(fileURLWithPath:"/tmp/tidyvnc-tunnel-controller-" + UUID().uuidString + ".tidyvnc")
  try Data("TidyVNC Configuration file Version 1.0\nServerName=file-target.invalid::6001\nShared=on\n".utf8).write(to:file)
  defer { try? FileManager.default.removeItem(at:file) }
  for operand in ["direct-target.invalid:3",file.path] {
    let h = try Harness(executable:executable,authentication:1)
    var launch = try NativeInvocationBootstrap.launch(.init(arguments:["-via=" + gateway.canonicalURI,operand]),workingDirectory:"/launch")
    var user: [UInt8]?, password: [UInt8]? = Array("password".utf8)
    launch.credentials = try .init(username:&user,password:&password)
    try await h.prepare(launch:launch)
    try check(h.model!.sshGateway == gateway,"CLI gateway published before session credential binding")
    try await h.connect()
    try check(h.owners[0].request.endpoint == (operand == file.path ? "file-target.invalid::6001" : operand),"gateway forwards final reviewed target")
    try check(h.model!.session?.prompt == nil,"launch password admitted to matching routed attempt")
    try await h.finish()
  }
  try Data("TidyVNC Configuration file Version 1.0\nServerName=/tmp/private-rfb-socket\n".utf8).write(to:file)
  let h = try Harness(executable:executable)
  let launch = try NativeInvocationBootstrap.launch(.init(arguments:["-via=gateway",file.path]),workingDirectory:"/launch")
  let defaults = NativeSessionDefaults(runtime:h.runtime,store:h.store,invocation:launch.invocation,document:launch.document)
  defaults.load(); try await until("Unix target review") { defaults.documentReview != nil }
  defaults.acceptDocument(defaults.documentReview!.id)
  try check(defaults.session == nil && !defaults.isReady && defaults.invocationIssue?.contains("SSH forwarding requires") == true,
    "final file target rejects incompatible routing before session allocation")
  await defaults.close(); try await h.finish()
}
@main enum NativeTunnelControllerTests {
  @MainActor static func main() async {
    do {
      if CommandLine.arguments[1] == "--ssh" {
        try await realSSH(gateway:CommandLine.arguments[2],key:CommandLine.arguments[3],known:CommandLine.arguments[4])
        try await configuredScopes(gateway:CommandLine.arguments[2],key:CommandLine.arguments[3],known:CommandLine.arguments[4]); return
      }
      let executable = CommandLine.arguments[1]
      try await preparationCancellation(executable:executable)
      try await startup(executable:executable); try await lifecycle(executable:executable)
      try await admissionCancellation(executable:executable); try await dropped(executable:executable)
      try await credentials(executable:executable)
      try await invocation(executable:executable)
      print("PASS tunnel controller startup/admission cancellation, remote/child exit, reconnect, close and dropped presentation")
    } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
}
