// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import Darwin

public enum NativeCredentialStoreIssue: Error, Sendable, Equatable {
  case notFound, unavailable, denied, interactionRequired, cancelled, missingEntitlement
  case duplicate, corrupt, tooLarge, busy, closed, secretCleared
  case failed(Int32)
}
public enum NativeCredentialInteraction: Sendable { case forbid, allow }
// createOrReplace adds the item, or updates it if one exists, in one store
// operation, so a closing window cannot cancel it between the two steps.
public enum NativeCredentialSaveMode: Sendable { case create, replace, createOrReplace }

// Own one mutable allocation. OS, Foundation and caller copies are outside this
// buffer's control; do not claim that clearing it zeroizes every runtime copy.
public final class NativeCredentialSecret: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public static let maximumBytes = 4096
  private let lock = NSLock()
  private let storage: UnsafeMutableRawPointer
  private let capacity: Int
  private var count: Int?
  public var description: String { "NativeCredentialSecret(<redacted>)" }
  public var debugDescription: String { description }
  public init(consuming bytes: inout [UInt8]) throws {
    defer { bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } } }
    guard bytes.count <= Self.maximumBytes else { throw NativeCredentialStoreIssue.tooLarge }
    capacity = max(bytes.count,1); count = bytes.count
    storage = .allocate(byteCount: capacity, alignment: 1)
    bytes.withUnsafeBytes { if let base = $0.baseAddress, !$0.isEmpty { storage.copyMemory(from: base, byteCount: $0.count) } }
  }
  public func clear() { lock.withLock { _ = memset_s(storage,capacity,0,capacity); count = nil } }
  // The caller owns and must clear this copy after passing it to the protocol.
  public func copyBytes() throws -> [UInt8] {
    try lock.withLock {
      guard let count else { throw NativeCredentialStoreIssue.secretCleared }
      return Array(UnsafeRawBufferPointer(start: storage, count: count))
    }
  }
  deinit { _ = memset_s(storage,capacity,0,capacity); storage.deallocate() }
}
public struct NativeCredentialMetadata: Sendable, Equatable {
  public let key: NativeCredentialKey
  public let created: Date?, modified: Date?
}
public struct NativeCredentialMetadataPage: Sendable, Equatable {
  public let entries: [NativeCredentialMetadata]
  public let hasMore: Bool
}
// Backends are synchronous and invoked on the store's serial utility queue.
// They must report committed outcomes even if cancellation arrives during IO.
public protocol NativeCredentialBacking: Sendable {
  func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialSecret
  func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode,
            interaction: NativeCredentialInteraction) throws
  func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws
  func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadata
  func listMetadata(limit: Int, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadataPage
}
private final class CredentialAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false, started = false
  func cancel() { lock.withLock { if !started { cancelled = true } } }
  func start() -> Bool { lock.withLock { guard !cancelled else { return false }; started = true; return true } }
}
public actor NativeCredentialStore {
  private let backing: any NativeCredentialBacking
  private let queue = DispatchQueue(label: "io.github.jkeli.tidyvnc.credentials", qos: .utility)
  private var pending: [UUID: CredentialAdmission] = [:]
  private var closed = false
  private var drain: CheckedContinuation<Void,Never>?
  private var closeTask: Task<Void,Never>?
  public init(backing: any NativeCredentialBacking = NativeKeychainBacking()) { self.backing = backing }
  private func perform<T: Sendable>(_ body: @escaping @Sendable (any NativeCredentialBacking) throws -> T) async throws -> T {
    guard !closed else { throw NativeCredentialStoreIssue.closed }
    guard !Task.isCancelled else { throw NativeCredentialStoreIssue.cancelled }
    guard pending.count < 16 else { throw NativeCredentialStoreIssue.busy }
    let id = UUID(), admission = CredentialAdmission(), backing = backing
    pending[id] = admission
    defer {
      pending.removeValue(forKey: id)
      if pending.isEmpty { drain?.resume(); drain = nil }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          guard admission.start() else { continuation.resume(throwing: NativeCredentialStoreIssue.cancelled); return }
          let result: Result<T, Error> = autoreleasepool {
            do { return .success(try body(backing)) }
            catch let error as NativeCredentialStoreIssue { return .failure(error) }
            catch { return .failure(NativeCredentialStoreIssue.failed(0)) }
          }
          continuation.resume(with: result)
        }
      }
    } onCancel: { admission.cancel() }
  }
  public func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction = .forbid) async throws -> NativeCredentialSecret {
    try await perform { try $0.lookup(key, interaction: interaction) }
  }
  public func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode = .create,
                   interaction: NativeCredentialInteraction = .forbid) async throws {
    try await perform { try $0.save(key, secret: secret, mode: mode, interaction: interaction) }
  }
  public func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction = .forbid) async throws {
    try await perform { try $0.delete(key, interaction: interaction) }
  }
  public func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction = .forbid) async throws -> NativeCredentialMetadata {
    try await perform { try $0.metadata(key, interaction: interaction) }
  }
  public func listMetadata(limit: Int = 128, interaction: NativeCredentialInteraction = .forbid) async throws -> NativeCredentialMetadataPage {
    guard (1...256).contains(limit) else { throw NativeCredentialStoreIssue.tooLarge }
    return try await perform { try $0.listMetadata(limit: limit, interaction: interaction) }
  }
  public func close() async {
    if let closeTask { await closeTask.value; return }
    closed = true; for admission in pending.values { admission.cancel() }
    let task = Task<Void,Never> { [weak self] in
      guard let self else { return }
      await self.waitForDrain()
    }
    closeTask = task; await task.value
  }
  private func waitForDrain() async {
    if !pending.isEmpty { await withCheckedContinuation { drain = $0 } }
    // A resumed caller can reach this actor before the queue closure releases
    // its captures. Cross a serial-queue barrier before declaring close drained.
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }
  var pendingCount: Int { pending.count }
}
