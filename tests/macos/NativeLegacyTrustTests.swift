// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import CryptoKit
import Darwin
import TidyVNC
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message: message) }
}
func expect(_ issue: NativeTrustStoreIssue, _ body: () throws -> Void) throws {
  do { try body(); throw Failure(message: "Expected \(issue)") }
  catch let caught as NativeTrustStoreIssue { try check(caught == issue, "Wrong store error") }
}
struct Key: NativeCertificateKeyMaterial {
  let spki = Data([1,2,3])
  func digest(_ algorithm: UInt32) throws -> Data {
    guard algorithm == 6 else { throw NativeTrustStoreIssue.unsupportedDigest }
    return Data(SHA256.hash(data: spki))
  }
}
func row(_ host: String = "fixture.invalid", _ key: Data = Key().spki, expiration: UInt64 = 0, service: String = "*") -> String {
  "|g0|\(host)|\(service)|\(expiration)|\(key.base64EncodedString())\n"
}
func lookup(_ text: String?, host: String = "fixture.invalid", now: UInt64 = 100) throws -> NativeLegacyTrustMatch {
  try NativeLegacyTrustCodec.lookup(data: text.map { Data($0.utf8) }, host: host, key: Key(), now: now)
}
func codec() throws {
  try check(try lookup(nil).state == .missing, "absent store")
  try check(try lookup(row()).state == .match, "exact key")
  try check(try lookup(row(service: "5902")).state == .match, "legacy nil service covers all ports")
  try check(try lookup(row(), host: "FIXTURE.invalid").state == .missing, "byte exact host")
  let wildcard = try lookup(row("*suffix"), host: "elsewhere.invalid")
  try check(wildcard.state == .match && wildcard.includesWildcardHost, "legacy leading-star wildcard")
  try check(try lookup(row(expiration: 100)).state == .match, "expiration equality active")
  try check(try lookup(row(expiration: 99)).state == .missing, "expired ignored")
  let different = row("fixture.invalid", Data([4,5,6]))
  let changed = try lookup(different)
  try check(changed.state == .changed && changed.expectedIdentities.count == 1 && !changed.expectedIdentities[0].contains(changed.receivedSPKIFingerprint), "changed key expected and received")
  try check(try lookup(different + row() + different).state == .match, "any matching active record wins")
  let digest = try Key().digest(6).map { String(format: "%02x", $0) }.joined()
  try check(try lookup("|c0|fixture.invalid|*|0|6|\(digest)\n").state == .match, "legacy commitment")
  try check(try lookup("|c0|fixture.invalid|*|0|6|00\n").state == .changed, "commitment mismatch")
  try expect(.unsupportedDigest) { _ = try lookup("|c0|fixture.invalid|*|0|9999|00\n") }
  try expect(.unsupportedFormat) { _ = try lookup(row() + "|g1|other|*|0|AQID\n") }
  for text in ["bad", "|g0|fixture.invalid|*|-1|AQID", "|g0|fixture.invalid|*|0|AQI", "|c0|fixture.invalid|*|0|6|AB", "\u{0}"] {
    try expect(.corrupt) { _ = try lookup(text) }
  }
  try check(try lookup("# comment\r\n\r\n" + row()).state == .match, "comments and CRLF")
  try expect(.tooLarge) { _ = try lookup(String(repeating: "x", count: NativeLegacyTrustCodec.maximumBytes + 1)) }
  try expect(.tooLarge) { _ = try lookup(String(repeating: row(), count: NativeLegacyTrustCodec.maximumRecords + 1)) }
  let many = try lookup((0..<20).map { row("fixture.invalid", Data([UInt8($0)])) }.joined())
  try check(many.expectedIdentities.count == 16 && many.hasMoreIdentities, "bounded identities")
  print("PASS legacy codec scope, expiry, wildcard, commitments, changed keys, strict errors and bounds")
}
func certificateKey() throws {
  var info = tidyvnc_abi_info(); info.size = UInt32(MemoryLayout<tidyvnc_abi_info>.size); info.version = UInt32(TIDYVNC_ABI_VERSION)
  try checked { tidyvnc_get_abi(&info, $0) }
  if info.features & UInt64(TIDYVNC_FEATURE_CERTIFICATE_KEY) == 0 {
    do { _ = try NativeCertificateKey(certificate: trustFixtureCertificate); throw Failure(message: "Unavailable key accepted") }
    catch is NativeError {}
    print("PASS certificate-key unavailable in TLS-disabled build")
    return
  }
  let key = try NativeCertificateKey(certificate: trustFixtureCertificate)
  try check(key.spki == trustFixtureSPKI, "exact SPKI independent OpenSSL fixture")
  try check(try key.digest(6) == Data(SHA256.hash(data: trustFixtureSPKI)), "independent CryptoKit digest")
  try expect(.unsupportedDigest) { _ = try key.digest(UInt32.max) }
  let result = try NativeLegacyTrustCodec.lookup(data: Data(row("fixture.invalid",trustFixtureSPKI).utf8),
    host: "fixture.invalid", key: key, now: 100)
  try check(result.state == .match, "real certificate-to-record match")
  try check(String(reflecting: key) == "NativeCertificateKey(<redacted>)" && String(reflecting: result) == "NativeLegacyTrustMatch(<redacted>)", "redacted descriptions")
  print("PASS native owned certificate key, independent SPKI and digest, real record match")
}
func files() throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("known_hosts"), file = try NativeLegacyTrustFile(url: url)
  try check(try file.read() == nil, "missing file")
  let bytes = Data(row().utf8); try bytes.write(to: url); chmod(url.path, 0o644)
  try check(try file.read() == bytes, "legacy 0644 readable")
  chmod(url.path, 0o666)
  try expect(.unsafeFile) { _ = try file.read() }; chmod(url.path, 0o600)
  let alias = root.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
  try expect(.unsafeFile) { _ = try NativeLegacyTrustFile(url: alias).read() }
  try FileManager.default.removeItem(at: alias)
  try FileManager.default.linkItem(at: url, to: alias)
  try expect(.unsafeFile) { _ = try file.read() }; try FileManager.default.removeItem(at: alias)
  try expect(.unsafeFile) { _ = try NativeLegacyTrustFile(url: root).read() }
  try check(mkfifo(alias.path, 0o600) == 0, "create FIFO")
  try expect(.unsafeFile) { _ = try NativeLegacyTrustFile(url: alias).read() }
  try Data(repeating: 0, count: NativeLegacyTrustCodec.maximumBytes + 1).write(to: url)
  try expect(.tooLarge) { _ = try file.read() }
  let xdg = try NativeLegacyTrustFile.applicationStore(environment: ["XDG_STATE_HOME":root.path,"HOME":"/unused"])
  try check(xdg.url.path == root.path + "/tidyvnc/x509_known_hosts", "XDG path")
  let home = try NativeLegacyTrustFile.applicationStore(environment: ["XDG_STATE_HOME":"relative","HOME":root.path])
  try check(home.url.path == root.path + "/.local/state/tidyvnc/x509_known_hosts", "relative XDG ignored")
  try check(!FileManager.default.fileExists(atPath: xdg.url.path), "lookup construction never creates store")
  try expect(.unsafeFile) { _ = try NativeLegacyTrustFile.applicationStore(environment: ["XDG_STATE_HOME":"/tmp/invalid\u{0}path"]) }
  let emptyHome = try NativeLegacyTrustFile.applicationStore(environment: ["HOME":""])
  try check(emptyHome.url.path == "/.local/state/tidyvnc/x509_known_hosts", "legacy empty HOME path")
  print("PASS read-only file safety, legacy permissions, bounds and path selection")
}
final class Backing: NativeLegacyTrustBacking, @unchecked Sendable {
  let data: Data?, failure: NativeTrustStoreIssue?, gate: DispatchSemaphore?
  private let lock = NSLock(); private var count = 0
  init(_ text: String? = nil, failure: NativeTrustStoreIssue? = nil, gated: Bool = false) {
    data = text.map { Data($0.utf8) }; self.failure = failure; gate = gated ? DispatchSemaphore(value: 0) : nil
  }
  var reads: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { count += 1 }; gate?.wait(); if let failure { throw failure }; return data }
}
@MainActor final class Target: NativeTrustTarget {
  var prompt: NativePrompt?, generation: UInt64 = 7, isClosing = false, replies = 0
  func replyTrust(to request: NativePrompt, allowed: Bool) throws {
    try check(prompt == request && allowed, "reply bound to current prompt"); replies += 1; prompt = nil
  }
}
func request(_ id: UInt64 = 1, status: UInt32 = 66) -> NativePrompt {
  NativePrompt(id: id, generation: 7, kind: .certificate, secure: false, usernameRequired: false,
    certificateStatus: status, serverName: "fixture.invalid", fingerprint: "", identity: trustFixtureCertificate)
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
  throw Failure(message: "Timed out")
}
@MainActor func controllers() async throws {
  for (text, state) in [(row(),NativeLegacyTrustMatch.State.match), (row("fixture.invalid",Data([9])),.changed), ("",.missing)] {
    let backing = Backing(text), store = NativeLegacyTrustStore(backing: backing, makeKey: { _ in Key() })
    let target = Target(), controller = NativeCertificateTrust(store: store)
    target.prompt = request(); controller.bind(target); controller.inspect(target.prompt)
    try await until { !controller.isWorking }
    try check(controller.inspection?.state == state && target.replies == (state == .match ? 1 : 0), "automatic match only")
    if state != .match { try controller.connectOnce(target.prompt!); try check(target.replies == 1, "explicit once") }
    await controller.close(); await store.close()
    do { _ = try await store.lookup(host: "fixture.invalid", certificate: trustFixtureCertificate); throw Failure(message: "closed lookup") }
    catch NativeTrustStoreIssue.closed {}
  }
  let backing = Backing(row(), gated: true), store = NativeLegacyTrustStore(backing: backing, makeKey: { _ in Key() })
  let target = Target(), controller = NativeCertificateTrust(store: store); controller.bind(target)
  target.prompt = request(status: 34); controller.inspect(target.prompt)
  try check(!controller.isWorking && backing.reads == 0 && !controller.canConnectOnce(target.prompt!), "fatal policy before store")
  target.prompt = request(); controller.inspect(target.prompt)
  try await until { backing.reads == 1 }
  controller.cancel(); backing.gate?.signal()
  try await until { !controller.isWorking }
  try check(target.replies == 0 && controller.inspection == nil, "cancel discards late match")
  controller.beginAttempt(); target.prompt = request(2); controller.inspect(target.prompt)
  try await until { backing.reads == 2 }
  target.prompt = request(3); controller.inspect(target.prompt); backing.gate?.signal()
  try await until { backing.reads == 3 }
  try check(target.replies == 0, "stale lookup never approves newer request")
  backing.gate?.signal(); try await until { !controller.isWorking }
  try check(target.replies == 1, "latest prompt receives fresh lookup")
  await controller.close(); await store.close()
  let denied = NativeLegacyTrustStore(backing: Backing(failure: .denied), makeKey: { _ in Key() })
  let failure = NativeCertificateTrust(store: denied); target.prompt = request(4); failure.bind(target); failure.inspect(target.prompt)
  try await until { !failure.isWorking }
  try check(failure.issue == .denied && failure.inspection == nil && failure.issueMessage != nil, "typed lookup failure")
  await failure.close(); await denied.close()
  let blocked = Backing(row(), gated: true), closingStore = NativeLegacyTrustStore(backing: blocked, makeKey: { _ in Key() })
  let closing = NativeCertificateTrust(store: closingStore), closingTarget = Target()
  closingTarget.prompt = request(); closing.bind(closingTarget); closing.inspect(closingTarget.prompt)
  try await until { blocked.reads == 1 }
  var drained = false
  let join = Task { await closing.close(); drained = true }
  try await Task.sleep(for: .milliseconds(20))
  try check(!drained, "close waits for outstanding file read")
  blocked.gate?.signal(); await join.value
  try check(drained && closingTarget.replies == 0, "close discards outstanding match")
  await closingStore.close()
  let shared = NativeLegacyTrustStore(backing: Backing(row()), makeKey: { _ in Key() })
  let left = Target(), right = Target(), leftController = NativeCertificateTrust(store: shared), rightController = NativeCertificateTrust(store: shared)
  left.prompt = request(); right.prompt = request(status: 34)
  leftController.bind(left); rightController.bind(right)
  leftController.inspect(left.prompt); rightController.inspect(right.prompt)
  try await until { !leftController.isWorking && !rightController.isWorking }
  try check(left.replies == 1 && right.replies == 0, "shared store preserves independent window policy")
  await leftController.close(); await rightController.close(); await shared.close()
  print("PASS current-prompt match reuse, explicit once, fatal policy, cancellation, stale results, drain and typed failures")
}
@main struct NativeLegacyTrustTests {
  @MainActor static func main() async {
    do { try codec(); try certificateKey(); try files(); try await controllers() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
