// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative

final class HistoryGate: @unchecked Sendable {
  private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
  private var entered = false
  var isEntered: Bool { lock.withLock { entered } }
  func hold() throws {
    lock.withLock { entered = true }
    guard signal.wait(timeout: .now() + 5) == .success else { throw NativeStorageError.ioFailure }
  }
  func release() { signal.signal() }
}
final class HistoryBacking: NativeProfileHistoryBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?, readFailure: NativeStorageError?, writeFailure: NativeStorageError?
  private var readGate: HistoryGate?, writeGate: HistoryGate?
  private var uncertain = false, writeCount = 0
  var writes: Int { lock.withLock { writeCount } }
  func fail(read: NativeStorageError? = nil, write: NativeStorageError? = nil, afterWrite: Bool = false) {
    lock.withLock { readFailure = read; writeFailure = write; uncertain = afterWrite }
  }
  func gate(read: HistoryGate? = nil, write: HistoryGate? = nil) { lock.withLock { readGate = read; writeGate = write } }
  func read() throws -> Data? {
    let (data, gate) = try lock.withLock {
      if let readFailure { throw readFailure }
      let gate = readGate; readGate = nil; return (bytes, gate)
    }
    try gate?.hold(); return data
  }
  func replace(_ data: Data, expected: Data?) throws {
    let (gate, failure) = try lock.withLock {
      if let writeFailure { throw writeFailure }
      guard bytes == expected else { throw NativeStorageError.conflict }
      bytes = data; writeCount += 1
      let gate = writeGate; writeGate = nil; return (gate, uncertain)
    }
    try gate?.hold()
    if failure { throw NativeStorageError.ioFailure }
  }
}
