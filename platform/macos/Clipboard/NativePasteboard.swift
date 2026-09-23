// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit

public enum NativePasteboardError: Error, Equatable, Sendable {
  case changed, tooLarge, invalidText, unavailable, writeFailed
}
public enum NativePasteboardContent: Equatable, Sendable {
  case text(String), remote, unavailable
}
// Small host contract, also implemented by deterministic test adapters. The
// coordinator owns routing on MainActor; native access runs on a serial worker.
@MainActor public protocol NativePasteboardAccess: AnyObject {
  func currentChange() async throws -> Int
  func read(expectedChange: Int, maximumBytes: Int) async throws -> NativePasteboardContent
  func writeRemote(_ text: String, maximumBytes: Int) async throws -> Int
  // Local-origin text written by the app itself (no remote provenance marker).
  func writeLocal(_ text: String, maximumBytes: Int) async throws -> Int
}
// Only this worker queue touches the owned NSPasteboard. @unchecked Sendable
// covers that queue confinement, not arbitrary concurrent AppKit access.
final class PasteboardWorker: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.jkeli.tidyvnc.clipboard", qos: .utility)
  private let board: NSPasteboard
  init(_ board: NSPasteboard) { self.board = board }
  func perform<T: Sendable>(_ body: @escaping @Sendable (NSPasteboard) throws -> T) async throws -> T {
    let cancellation = PasteboardCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let result: T = try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          do {
            try cancellation.check()
            let value = try autoreleasepool { try body(board) }
            continuation.resume(returning: value)
          } catch { continuation.resume(throwing: error) }
        }
      }
      try Task.checkCancellation()
      return result
    } onCancel: { cancellation.cancel() }
  }
}
private final class PasteboardCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
  func check() throws {
    lock.lock(); defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }
}
@MainActor public final class NativePasteboard: NativePasteboardAccess {
  nonisolated static let remoteType = NSPasteboard.PasteboardType("io.github.jkeli.tidyvnc.remote-clipboard")
  private let worker: PasteboardWorker
  public init(_ board: NSPasteboard = .general) { worker = PasteboardWorker(board) }
  // Test hosts can share the same queue for simulated local pasteboard changes;
  // they must not access the worker's NSPasteboard concurrently on MainActor.
  init(worker: PasteboardWorker) { self.worker = worker }
  public func currentChange() async throws -> Int { try await worker.perform { $0.changeCount } }
  nonisolated static func validate(_ text: String, maximumBytes: Int) throws {
    guard maximumBytes > 0, maximumBytes <= 16 * 1024 * 1024 else { throw NativePasteboardError.tooLarge }
    guard maximumBytes > 0, text.utf8.prefix(maximumBytes + 1).count <= maximumBytes else { throw NativePasteboardError.tooLarge }
    guard !text.utf8.contains(0) else { throw NativePasteboardError.invalidText }
  }
  public func read(expectedChange: Int, maximumBytes: Int) async throws -> NativePasteboardContent {
    try await worker.perform { board in
      guard board.changeCount == expectedChange else { throw NativePasteboardError.changed }
      let value: NativePasteboardContent
      // Provenance survives focus changes, session teardown and app restart. It
      // carries no endpoint or clipboard data, and is never an authorization token.
      if board.availableType(from: [Self.remoteType]) != nil { value = .remote }
      else if board.availableType(from: [.string]) == nil { value = .unavailable }
      else {
        guard let text = board.string(forType: .string) else { throw NativePasteboardError.unavailable }
        // AppKit materializes a provider's String before its size can be checked.
        // Limit protocol admission; do not claim bounded OS/provider allocation.
        try Self.validate(text, maximumBytes: maximumBytes); value = .text(text)
    }
    guard board.changeCount == expectedChange else { throw NativePasteboardError.changed }
    return value
    }
  }
  public func writeRemote(_ text: String, maximumBytes: Int) async throws -> Int {
    try await worker.perform { board in
      try Self.validate(text, maximumBytes: maximumBytes)
      let item = NSPasteboardItem()
      let origin = UUID().uuidString
      guard item.setString(text, forType: .string), item.setString(origin, forType: Self.remoteType) else { throw NativePasteboardError.writeFailed }
      // Prepare the complete item before changing the board. NSPasteboard does
      // not provide a cross-process CAS/transaction; report failures honestly.
      board.clearContents()
      guard board.writeObjects([item]) else { throw NativePasteboardError.writeFailed }
      let written = board.changeCount
      guard board.string(forType: Self.remoteType) == origin, board.changeCount == written else { throw NativePasteboardError.changed }
      return written
    }
  }
  public func writeLocal(_ text: String, maximumBytes: Int) async throws -> Int {
    try await worker.perform { board in
      try Self.validate(text, maximumBytes: maximumBytes)
      board.clearContents()
      guard board.setString(text, forType: .string) else { throw NativePasteboardError.writeFailed }
      return board.changeCount
    }
  }
}
