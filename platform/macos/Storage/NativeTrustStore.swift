// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreFoundation
import CryptoKit
import Foundation
import TidyVNC

public enum NativeTrustKind: String, Sendable {
  case certificate = "x509-spki", hostKey = "rsa-aes"
  var domain: String { "io.github.jkeli.tidyvnc.trust." + rawValue + ".v1" }
  public func savedFingerprintMessage(_ fingerprint: String) -> String {
    switch self {
    case .certificate: String(localized:"trust.library.saved.spki", defaultValue:"Saved SPKI SHA-256: \(fingerprint)")
    case .hostKey: String(localized:"trust.library.saved.serverKey", defaultValue:"Saved Server-key SHA-256: \(fingerprint)")
    }
  }
}
// Domain-separated canonical endpoint identity. Original labels are retained only
// for management UI; stored scopes are rederived on load, never trusted as labels.
public struct NativeTrustScope: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let id: String, endpoint: String, routeIdentity: String
  public let kind: NativeTrustKind
  public var description: String { "NativeTrustScope(<redacted>)" }
  public var debugDescription: String { description }
  public static func ==(lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  public func hash(into hasher: inout Hasher) { hasher.combine(id) }
  public init(endpoint: String, routeIdentity: String = "", kind: NativeTrustKind = .certificate) throws {
    func bounded(_ value: String) throws -> [UInt8] {
      let result = Array(value.utf8.prefix(4097))
      guard result.count <= 4096, !result.contains(0) else { throw NativeStorageError.invalid }
      return result
    }
    let address = try bounded(endpoint), route = try bounded(routeIdentity)
    guard !address.isEmpty else { throw NativeStorageError.invalid }
    var raw: UInt64 = 0
    _ = try address.withUnsafeBufferPointer { address in
      try route.withUnsafeBufferPointer { route in
        try checked { tidyvnc_endpoint_create(.init(data: address.baseAddress,length: UInt64(address.count)),
          .init(data: route.baseAddress,length: UInt64(route.count)),1,&raw,$0) }
      }
    }
    let owner = NativeHandle(adopting: raw)
    id = try withExtendedLifetime(owner) {
      var value = abi(tidyvnc_endpoint_info.self)
      try checked { tidyvnc_endpoint_get(owner.raw,&value,$0) }
      var hash = SHA256()
      func number(_ value: UInt32) -> Data { var big = value.bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
      func field(_ bytes: Data) { hash.update(data: number(UInt32(bytes.count))); hash.update(data: bytes) }
      field(Data(kind.domain.utf8))
      field(number(value.transport)); field(try copyBytes(value.host)); field(try copyBytes(value.scope)); field(number(value.port))
      field(try copyBytes(value.path)); field(try copyBytes(value.route))
      return "v1:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    self.endpoint = endpoint; self.routeIdentity = routeIdentity; self.kind = kind
  }
}
public struct NativeTrustRevision: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  fileprivate let digest: Data?
  public var description: String { "NativeTrustRevision(<redacted>)" }
  public var debugDescription: String { description }
  fileprivate init(_ data: Data?) { digest = data.map { Data(SHA256.hash(data: $0)) } }
}
public struct NativeSavedTrustEntry: Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
  public var id: String { scope.id }
  public let scope: NativeTrustScope
  // nil means forgotten: do not fall back to an older broad host exception.
  let identity: Data?
  public var fingerprint: String? { identity.map { NativeLegacyTrustCodec.fingerprint($0) } }
  public var isForgotten: Bool { identity == nil }
  public var description: String { "NativeSavedTrustEntry(<redacted>)" }
  public var debugDescription: String { description }
}
public struct NativeSavedTrustSnapshot: Sendable {
  public let revision: NativeTrustRevision
  public let entries: [NativeSavedTrustEntry]
}
public struct NativeSavedTrustInspection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "NativeSavedTrustInspection(<redacted>)" }
  public var debugDescription: String { description }
  public enum State: Sendable { case absent, forgotten, match, changed }
  public let state: State, revision: NativeTrustRevision
  public let expectedFingerprint: String?, receivedFingerprint: String
}
public struct NativeTrustCommit: Sendable {
  public let snapshot: NativeSavedTrustSnapshot
  // Replacement is observed on disk, but a post-rename sync failed. Never
  // translate this to cancellation or retry the write without a fresh read.
  public let durabilityUncertain: Bool
}
public struct NativeTrustFile: NativeAtomicFileBacking {
  public let kind: NativeTrustKind
  public init(kind: NativeTrustKind = .certificate) { self.kind = kind }
  public static func file(kind: NativeTrustKind = .certificate, environment: [String:String] = NativePathEnvironment.capture(),
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> NativePrivateFile {
    let legacy = try NativeLegacyTrustFile.applicationStore(environment: environment,home: home)
    let directory = legacy.url.deletingLastPathComponent().appendingPathComponent("native-trust",isDirectory: true)
    return try NativePrivateFile(directory: directory,record: kind == .certificate ? .trustExceptions : .serverKeys,prepareParent: true,checkpoint: { _ in })
  }
  public func read() throws -> Data? { try Self.file(kind: kind).read() }
  public func replace(_ data: Data, expected: Data?) throws { try Self.file(kind: kind).replace(data,expected: expected) }
}
public actor NativeTrustStore {
  public static let capacity = 256
  public nonisolated let kind: NativeTrustKind
  private struct Entry: Codable {
    let scope: String, endpoint: String, route: String, decision: String
    let spki: Data?, hostKey: Data?
    var identity: Data? { spki ?? hostKey }
  }
  private struct Record: Codable { let schema: UInt32; let kind: String?; var entries: [Entry] }
  private let backing: any NativeAtomicFileBacking
  private let makeKey: @Sendable (Data) throws -> any NativeCertificateKeyMaterial
  private var closed = false
  public init(kind: NativeTrustKind = .certificate, backing: (any NativeAtomicFileBacking)? = nil,
              makeKey: @escaping @Sendable (Data) throws -> any NativeCertificateKeyMaterial = { try NativeCertificateKey(certificate: $0) }) {
    self.kind = kind; self.backing = backing ?? NativeTrustFile(kind: kind); self.makeKey = makeKey
  }
  private func admission() throws {
    guard !closed else { throw NativeStorageError.closed }
    guard !Task.isCancelled else { throw NativeStorageError.cancelled }
  }
  private func snapshot(_ record: Record, data: Data?) throws -> NativeSavedTrustSnapshot {
    guard record.entries.count <= Self.capacity else { throw NativeStorageError.resourceLimit }
    var seen = Set<String>(), entries: [NativeSavedTrustEntry] = []
    for entry in record.entries {
      let scope = try NativeTrustScope(endpoint: entry.endpoint,routeIdentity: entry.route,kind: kind)
      guard scope.id == entry.scope, seen.insert(scope.id).inserted else { throw NativeStorageError.corrupt }
      guard entry.decision == "accept" || entry.decision == "forget" else { throw NativeStorageError.unsupportedValue }
      if entry.decision == "accept" {
        guard let key = entry.identity, !key.isEmpty, key.count <= 65536 else { throw NativeStorageError.corrupt }
        if kind == .hostKey { do { _ = try NativeHostKey(key) } catch { throw NativeStorageError.corrupt } }
      } else if entry.identity != nil { throw NativeStorageError.corrupt }
      entries.append(.init(scope: scope,identity: entry.identity))
    }
    return .init(revision: NativeTrustRevision(data),entries: entries)
  }
  private func load() throws -> (Record,NativeSavedTrustSnapshot,Data?) {
    let data = try backing.read()
    guard let data else {
      let record = Record(schema: 1,kind: kind == .certificate ? nil : kind.rawValue,entries: [])
      return (record,try snapshot(record,data: nil),nil)
    }
    guard data.count <= NativePrivateFile.maximumBytes else { throw NativeStorageError.tooLarge }
    do {
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String:Any],
            let schema = root["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
            schema.doubleValue >= 1, schema.doubleValue.rounded() == schema.doubleValue else { throw NativeStorageError.corrupt }
      guard schema.doubleValue == 1 else { throw NativeStorageError.futureSchema }
      let rootFields: Set<String> = kind == .certificate ? ["schema","entries"] : ["schema","kind","entries"]
      guard Set(root.keys) == rootFields else { throw NativeStorageError.unsupportedFields }
      if kind == .hostKey, root["kind"] as? String != kind.rawValue { throw NativeStorageError.unsupportedValue }
      guard let entries = root["entries"] as? [[String:Any]] else { throw NativeStorageError.corrupt }
      guard entries.count <= Self.capacity else { throw NativeStorageError.resourceLimit }
      for entry in entries {
        let required: Set<String> = ["scope","endpoint","route","decision"]
        guard required.isSubset(of: Set(entry.keys)), Set(entry.keys).isSubset(of: required.union([kind == .certificate ? "spki" : "hostKey"])) else { throw NativeStorageError.unsupportedFields }
        guard !entry.values.contains(where: { $0 is NSNull }) else { throw NativeStorageError.corrupt }
      }
      let record = try JSONDecoder().decode(Record.self,from: data)
      return (record,try snapshot(record,data: data),data)
    } catch let error as NativeStorageError { throw error }
    catch { throw NativeStorageError.corrupt }
  }
  public func read() throws -> NativeSavedTrustSnapshot { try admission(); return try load().1 }
  public func inspect(scope: NativeTrustScope, certificate: Data) throws -> NativeSavedTrustInspection {
    try admission()
    guard kind == .certificate, scope.kind == kind else { throw NativeStorageError.invalid }
    return try inspectIdentity(scope: scope,identity: makeKey(certificate).spki)
  }
  public func inspectHostKey(scope: NativeTrustScope, key: Data) throws -> NativeSavedTrustInspection {
    try admission()
    guard kind == .hostKey, scope.kind == kind else { throw NativeStorageError.invalid }
    return try inspectIdentity(scope: scope,identity: NativeHostKey(key).identity)
  }
  private func inspectIdentity(scope: NativeTrustScope,identity: Data) throws -> NativeSavedTrustInspection {
    let snapshot = try load().1, entry = snapshot.entries.first { $0.id == scope.id }
    return .init(state: entry == nil ? .absent : entry!.isForgotten ? .forgotten : entry!.identity == identity ? .match : .changed,
      revision: snapshot.revision,expectedFingerprint: entry?.fingerprint,receivedFingerprint: NativeLegacyTrustCodec.fingerprint(identity))
  }
  private func mutate(scope: NativeTrustScope, key: Data?, replacing: Bool, expected: NativeTrustRevision) throws -> NativeTrustCommit {
    try admission()
    guard scope.kind == kind else { throw NativeStorageError.invalid }
    var (record, original, bytes) = try load()
    guard original.revision == expected else { throw NativeStorageError.conflict }
    let index = record.entries.firstIndex { $0.scope == scope.id }
    let hasKey = index.map { record.entries[$0].identity != nil } ?? false
    if key != nil { guard replacing == hasKey else { throw NativeStorageError.conflict } }
    let entry = Entry(scope: scope.id,endpoint: scope.endpoint,route: scope.routeIdentity,decision: key == nil ? "forget" : "accept",spki: kind == .certificate ? key : nil,hostKey: kind == .hostKey ? key : nil)
    if let index { record.entries[index] = entry } else { record.entries.append(entry) }
    _ = try snapshot(record,data: nil)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(record)
    guard encoded.count <= NativePrivateFile.maximumBytes else { throw NativeStorageError.tooLarge }
    let result = try snapshot(record,data: encoded)
    try admission()
    do { try backing.replace(encoded,expected: bytes) }
    catch {
      // A failed post-rename sync cannot be rolled back. Reconcile exact bytes;
      // no automatic retry, no overwrite of a third writer's later decision.
      if (try? backing.read()) == encoded { return .init(snapshot: result,durabilityUncertain: true) }
      throw error
    }
    return .init(snapshot: result,durabilityUncertain: false)
  }
  public func save(scope: NativeTrustScope, certificate: Data, status: UInt32, replacing: Bool,
                   expected: NativeTrustRevision) throws -> NativeTrustCommit {
    try admission()
    guard kind == .certificate, scope.kind == kind, try NativeCertificatePolicy(status: status).mayOverride else { throw NativeStorageError.invalid }
    let key = try makeKey(certificate).spki
    guard !key.isEmpty, key.count <= 65536 else { throw NativeStorageError.invalid }
    return try mutate(scope: scope,key: key,replacing: replacing,expected: expected)
  }
  public func saveHostKey(scope: NativeTrustScope, key: Data, replacing: Bool,
                          expected: NativeTrustRevision) throws -> NativeTrustCommit {
    try admission()
    guard kind == .hostKey, scope.kind == kind else { throw NativeStorageError.invalid }
    return try mutate(scope: scope,key: NativeHostKey(key).identity,replacing: replacing,expected: expected)
  }
  public func forget(scope: NativeTrustScope, expected: NativeTrustRevision) throws -> NativeTrustCommit {
    try mutate(scope: scope,key: nil,replacing: false,expected: expected)
  }
  public func close() { closed = true }
}
