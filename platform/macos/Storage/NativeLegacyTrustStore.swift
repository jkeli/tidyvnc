// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CryptoKit
import Foundation
import Darwin
import TidyVNC

extension tidyvnc_certificate_key_info: ABIValue {}
extension tidyvnc_key_digest: ABIValue {}
public enum NativeTrustStoreIssue: Error, Sendable, Equatable {
  case unavailable, denied, unsafeFile, corrupt, unsupportedFormat, unsupportedDigest, tooLarge, changed, cancelled, closed
}
public protocol NativeCertificateKeyMaterial: Sendable {
  var spki: Data { get }
  func digest(_ algorithm: UInt32) throws -> Data
}
public final class NativeCertificateKey: NativeCertificateKeyMaterial, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "NativeCertificateKey(<redacted>)" }
  public var debugDescription: String { description }
  private let owner: NativeHandle
  public let spki: Data
  public init(certificate: Data) throws {
    guard !certificate.isEmpty, certificate.count <= 65536 else { throw NativeTrustStoreIssue.corrupt }
    var raw: UInt64 = 0
    _ = try certificate.withUnsafeBytes { bytes in
      try checked { tidyvnc_certificate_key_create(.init(data: bytes.bindMemory(to: UInt8.self).baseAddress, length: UInt64(bytes.count)), &raw, $0) }
    }
    let owner = NativeHandle(adopting: raw)
    var value = abi(tidyvnc_certificate_key_info.self)
    try checked { tidyvnc_certificate_key_get(owner.raw, &value, $0) }
    self.spki = try withExtendedLifetime(owner) { try copyBytes(value.spki) }; self.owner = owner
  }
  public func digest(_ algorithm: UInt32) throws -> Data {
    var result = abi(tidyvnc_key_digest.self)
    do { try checked { tidyvnc_certificate_key_digest(owner.raw, algorithm, &result, $0) } }
    catch { throw NativeTrustStoreIssue.unsupportedDigest }
    guard result.length <= 64 else { throw NativeTrustStoreIssue.corrupt }
    return withUnsafeBytes(of: result.bytes) { Data($0.prefix(Int(result.length))) }
  }
}
public struct NativeLegacyTrustMatch: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "NativeLegacyTrustMatch(<redacted>)" }
  public var debugDescription: String { description }
  public enum State: Sendable { case missing, match, changed }
  public let state: State
  // SHA-256 fingerprints of stored DER SPKI, or the explicit legacy commitment.
  public let expectedIdentities: [String]
  public let receivedSPKIFingerprint: String
  public let hasMoreIdentities: Bool
  public let includesWildcardHost: Bool
}
public enum NativeLegacyTrustCodec {
  public static let maximumBytes = 1024 * 1024
  public static let maximumRecords = 4096
  private struct Record {
    let host: [UInt8], expiration: UInt64
    let key: Data?
    let algorithm: UInt32?
    let commitment: String?
  }
  public static func fingerprint(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined(separator: ":")
  }
  // CConn passes no service to GnuTLS, so all services match. Host spelling is
  // byte-exact; a leading '*' is the legacy wildcard rule. Do not DNS-normalize.
  public static func lookup(data: Data?, host: String, key: any NativeCertificateKeyMaterial,
                            now: UInt64) throws -> NativeLegacyTrustMatch {
    let hostBytes = Array(host.utf8)
    guard !hostBytes.isEmpty, hostBytes.count <= 4096, !hostBytes.contains(0),
          !hostBytes.contains(124), !hostBytes.contains(10), !hostBytes.contains(13),
          !key.spki.isEmpty, key.spki.count <= 65536 else { throw NativeTrustStoreIssue.corrupt }
    let records = try decode(data ?? Data())
    var expected: [String] = [], hasMore = false, matched = false, found = false, wildcard = false
    var digests: [UInt32: String] = [:]
    for record in records {
      guard record.host.first == 42 || record.host == hostBytes,
            record.expiration == 0 || now <= record.expiration else { continue }
      found = true; wildcard = wildcard || record.host.first == 42
      let identity: String
      if let stored = record.key {
        identity = "SPKI SHA-256: " + fingerprint(stored)
        matched = matched || stored == key.spki
      } else if let algorithm = record.algorithm, let commitment = record.commitment {
        if digests[algorithm] == nil {
          digests[algorithm] = try key.digest(algorithm).map { String(format: "%02x", $0) }.joined()
        }
        identity = "Legacy commitment \(algorithm): " + commitment
        matched = matched || digests[algorithm] == commitment
      } else { throw NativeTrustStoreIssue.corrupt }
      if !expected.contains(identity) {
        if expected.count < 16 { expected.append(identity) } else { hasMore = true }
      }
    }
    return NativeLegacyTrustMatch(state: matched ? .match : found ? .changed : .missing,
      expectedIdentities: expected, receivedSPKIFingerprint: fingerprint(key.spki),
      hasMoreIdentities: hasMore, includesWildcardHost: wildcard)
  }
  private static func decode(_ data: Data) throws -> [Record] {
    guard data.count <= maximumBytes else { throw NativeTrustStoreIssue.tooLarge }
    guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { throw NativeTrustStoreIssue.corrupt }
    var records: [Record] = []
    // Split bytes: Swift treats CRLF as one Character, unlike the legacy line reader.
    for bytes in text.utf8.split(separator: 10, omittingEmptySubsequences: false) {
      let raw = String(decoding: bytes, as: UTF8.self)[...]
      let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
      if line.isEmpty || line.first == "#" { continue }
      guard records.count < maximumRecords, line.utf8.count <= 131072 else { throw NativeTrustStoreIssue.tooLarge }
      let fields = line.split(separator: "|", omittingEmptySubsequences: false)
      guard fields.count >= 2, fields[0].isEmpty else { throw NativeTrustStoreIssue.corrupt }
      guard fields[1] == "g0" || fields[1] == "c0" else { throw NativeTrustStoreIssue.unsupportedFormat }
      guard fields.count == (fields[1] == "g0" ? 6 : 7),
            !fields[2].isEmpty, !fields[3].isEmpty, fields[2].utf8.count <= 4096, fields[3].utf8.count <= 4096,
            !fields[4].isEmpty, fields[4].utf8.allSatisfy({ (48...57).contains($0) }),
            let expiration = UInt64(fields[4]), expiration <= UInt64(Int64.max) else { throw NativeTrustStoreIssue.corrupt }
      let host = Array(fields[2].utf8)
      if fields[1] == "g0" {
        guard let key = Data(base64Encoded: String(fields[5])), !key.isEmpty, key.count <= 65536,
              key.base64EncodedString() == fields[5] else { throw NativeTrustStoreIssue.corrupt }
        records.append(Record(host: host, expiration: expiration, key: key, algorithm: nil, commitment: nil))
      } else {
        guard !fields[5].isEmpty, fields[5].utf8.allSatisfy({ (48...57).contains($0) }),
              let algorithm = UInt32(fields[5]), algorithm > 0,
              !fields[6].isEmpty, fields[6].count <= 128, fields[6].count % 2 == 0,
              fields[6].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NativeTrustStoreIssue.corrupt }
        records.append(Record(host: host, expiration: expiration, key: nil, algorithm: algorithm, commitment: String(fields[6])))
      }
    }
    return records
  }
}
public protocol NativeLegacyTrustBacking: Sendable { func read() throws -> Data? }
public struct NativeLegacyTrustFile: NativeLegacyTrustBacking, Sendable {
  public let url: URL
  public init(url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0), url.path.utf8.count <= 4096 else { throw NativeTrustStoreIssue.unsafeFile }
    self.url = url
  }
  public static func applicationStore(environment: [String:String] = NativePathEnvironment.capture(),
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> NativeLegacyTrustFile {
    let directory: URL
    if let override = environment["XDG_STATE_HOME"], override.hasPrefix("/") {
      guard !override.utf8.contains(0) else { throw NativeTrustStoreIssue.unsafeFile }
      directory = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      let base = environment["HOME"] ?? home.path
      guard !base.utf8.contains(0) else { throw NativeTrustStoreIssue.unsafeFile }
      directory = URL(fileURLWithPath: base + "/.local/state", isDirectory: true)
    }
    return try NativeLegacyTrustFile(url: directory.appendingPathComponent("tidyvnc/x509_known_hosts"))
  }
  public func read() throws -> Data? {
    guard !Task.isCancelled else { throw NativeTrustStoreIssue.cancelled }
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
    if fd < 0 {
      if errno == ENOENT { return nil }
      if errno == EACCES || errno == EPERM { throw NativeTrustStoreIssue.denied }
      if errno == ELOOP { throw NativeTrustStoreIssue.unsafeFile }
      throw NativeTrustStoreIssue.unavailable
    }
    defer { Darwin.close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0 else { throw NativeTrustStoreIssue.unavailable }
    guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == geteuid(),
          before.st_nlink == 1, before.st_mode & 0o022 == 0 else { throw NativeTrustStoreIssue.unsafeFile }
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      var entry: acl_entry_t?
      guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0, errno == EINVAL else { throw NativeTrustStoreIssue.unsafeFile }
    } else if errno != ENOENT { throw NativeTrustStoreIssue.unavailable }
    guard before.st_size >= 0, before.st_size <= NativeLegacyTrustCodec.maximumBytes else { throw NativeTrustStoreIssue.tooLarge }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
    while true {
      guard !Task.isCancelled else { throw NativeTrustStoreIssue.cancelled }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 { if errno == EINTR { continue }; throw NativeTrustStoreIssue.unavailable }
      if count == 0 { break }
      guard data.count + count <= NativeLegacyTrustCodec.maximumBytes else { throw NativeTrustStoreIssue.tooLarge }
      data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard fstat(fd, &after) == 0 else { throw NativeTrustStoreIssue.unavailable }
    guard before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw NativeTrustStoreIssue.changed }
    return data
  }
}
public actor NativeLegacyTrustStore {
  private let backing: any NativeLegacyTrustBacking
  private let makeKey: @Sendable (Data) throws -> any NativeCertificateKeyMaterial
  private var closed = false
  public init(backing: any NativeLegacyTrustBacking,
              makeKey: @escaping @Sendable (Data) throws -> any NativeCertificateKeyMaterial = { try NativeCertificateKey(certificate: $0) }) {
    self.backing = backing; self.makeKey = makeKey
  }
  // Actor-isolated synchronous work runs off MainActor. Regular-file reads,
  // bytes/records and returned identities are bounded; no Security UI is invoked.
  public func lookup(host: String, certificate: Data) throws -> NativeLegacyTrustMatch {
    guard !closed else { throw NativeTrustStoreIssue.closed }
    guard !Task.isCancelled else { throw NativeTrustStoreIssue.cancelled }
    do {
      let key = try makeKey(certificate), data = try backing.read()
      guard !Task.isCancelled else { throw NativeTrustStoreIssue.cancelled }
      return try NativeLegacyTrustCodec.lookup(data: data, host: host, key: key, now: UInt64(max(0,Date().timeIntervalSince1970)))
    } catch let error as NativeTrustStoreIssue { throw error }
    catch { throw NativeTrustStoreIssue.unavailable }
  }
  public func close() { closed = true }
}
