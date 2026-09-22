// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Dispatch
import Foundation

enum NativeTunnelOutputIssue: Error, Sendable { case unavailable, ioFailure, tooLarge }

// Match only a fixed OpenSSH log-line prefix. No host, path, prompt or remote
// diagnostic text is retained or exposed. A forged line can only deny admission.
final class NativeSSHSaveFailure: @unchecked Sendable {
  private static let prefix = Array("Failed to add the host to the list of known hosts (".utf8)
  private let lock = NSLock()
  private var offset = 0, rejected = false, found = false
  var failed: Bool { lock.withLock { found } }
  func consume(_ bytes: ArraySlice<UInt8>) {
    lock.withLock {
      guard !found else { return }
      var remaining = bytes
      if rejected {
        let newline = bytes.withUnsafeBufferPointer { buffer -> Int? in
          guard let start = buffer.baseAddress, let match = memchr(start,10,buffer.count) else { return nil }
          return UnsafeRawPointer(start).distance(to:UnsafeRawPointer(match))
        }
        guard let newline else { return }
        remaining = bytes.dropFirst(newline + 1); offset = 0; rejected = false
      }
      for byte in remaining {
        if byte == 10 { offset = 0; rejected = false; continue }
        guard !found, !rejected else { continue }
        if byte != Self.prefix[offset] { rejected = true; continue }
        offset += 1
        if offset == Self.prefix.count { found = true }
      }
    }
  }
}

// Single-consumer bounded output. Configuration probes retain stdout; SSH
// diagnostics reduce stderr to a fixed failure flag without retaining raw text.
// The read source owns its descriptor through its cancellation handler, avoiding
// close/read descriptor reuse races. No pipe read or join runs on MainActor.
final class NativeTunnelOutput: @unchecked Sendable {
  private let lock = NSLock(), maximum: Int
  private let queue = DispatchQueue(label:"io.github.jkeli.tidyvnc.ssh-output",qos:.utility)
  private let saveFailure: NativeSSHSaveFailure?
  private var reading: Int32, writing: Int32
  private var claimed = false, finished = false, taken = false
  private var bytes: [UInt8] = []
  private var issue: NativeTunnelOutputIssue?
  private var source: DispatchSourceRead?
  private var cancelChild: (@Sendable () -> Void)?
  private var waiter: CheckedContinuation<Data,any Error>?
  init(maximum: Int = 262144, saveFailure: NativeSSHSaveFailure? = nil) throws {
    guard maximum > 0, maximum <= 262144 else { throw NativeTunnelOutputIssue.unavailable }
    self.maximum = maximum; self.saveFailure = saveFailure
    var descriptors: [Int32] = [-1,-1]
    guard pipe(&descriptors) == 0 else { throw NativeTunnelOutputIssue.unavailable }
    // Keep file actions independent of whether the embedding host closed stdio.
    reading = fcntl(descriptors[0],F_DUPFD_CLOEXEC,3)
    writing = fcntl(descriptors[1],F_DUPFD_CLOEXEC,3)
    Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
    guard reading >= 0, writing >= 0, fcntl(reading,F_SETFL,O_NONBLOCK) == 0 else {
      if reading >= 0 { Darwin.close(reading) }; if writing >= 0 { Darwin.close(writing) }
      reading = -1; writing = -1; throw NativeTunnelOutputIssue.unavailable
    }
  }
  func claimWriter() throws -> Int32 {
    try lock.withLock {
      guard !claimed, !finished, writing >= 0 else { throw NativeTunnelOutputIssue.unavailable }
      claimed = true; return writing
    }
  }
  // Called only after the child PID has been installed. Starting earlier could
  // let a fast overflowing child invoke cancellation before process ownership.
  func didSpawn(cancel: @escaping @Sendable () -> Void) {
    let source = lock.withLock {
      Darwin.close(writing); writing = -1; cancelChild = cancel
      let source = DispatchSource.makeReadSource(fileDescriptor:reading,queue:queue)
      self.source = source
      source.setEventHandler { [self] in readAvailable() }
      source.setCancelHandler { [self] in finish() }
      return source
    }
    source.activate()
  }
  func launchFailed() {
    lock.withLock {
      if writing >= 0 { Darwin.close(writing); writing = -1 }
      issue = .unavailable
    }
    finish()
  }
  func take() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let result: Result<Data,any Error>? = lock.withLock {
        guard !taken else { return .failure(NativeTunnelOutputIssue.unavailable) }
        taken = true
        if finished { return consume() }
        waiter = continuation; return nil
      }
      if let result { continuation.resume(with:result) }
    }
  }
  // The master's readiness acknowledgement follows its initial host-key write.
  // Drain bytes already in the pipe before admitting the forwarded connection.
  func drainAvailable() async throws {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if lock.withLock({ !finished && source != nil }) { readAvailable() }
        continuation.resume()
      }
    }
    if let issue = lock.withLock({ issue }) { throw issue }
  }
  // Caller holds lock. Copy out once, then clear the accumulator on all outcomes.
  private func consume() -> Result<Data,any Error> {
    let result: Result<Data,any Error> = issue.map { .failure($0) } ?? .success(Data(bytes))
    bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base,$0.count,0,$0.count) } }
    bytes.removeAll(); return result
  }
  private func readAvailable() {
    var chunk = [UInt8](repeating:0,count:4096)
    defer { chunk.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base,$0.count,0,$0.count) } } }
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(reading,$0.baseAddress,$0.count) }
      if count < 0 && errno == EINTR { continue }
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
      let stop = lock.withLock { () -> Bool in
        if count < 0 { issue = .ioFailure; return true }
        if count == 0 { return true }
        if let saveFailure { saveFailure.consume(chunk.prefix(count)) }
        else {
          guard count <= maximum - bytes.count else { issue = .tooLarge; return true }
          bytes.append(contentsOf:chunk.prefix(count))
        }
        return false
      }
      if stop {
        let cancel = lock.withLock { issue == nil ? nil : cancelChild }
        cancel?(); source?.cancel(); return
      }
    }
  }
  private func finish() {
    let delivery: (CheckedContinuation<Data,any Error>,Result<Data,any Error>)? = lock.withLock {
      guard !finished else { return nil }
      if reading >= 0 { Darwin.close(reading); reading = -1 }
      finished = true; source = nil; cancelChild = nil
      guard let waiter else { return nil }
      self.waiter = nil; return (waiter,consume())
    }
    if let delivery { delivery.0.resume(with:delivery.1) }
  }
  deinit {
    if reading >= 0 { Darwin.close(reading) }; if writing >= 0 { Darwin.close(writing) }
    bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base,$0.count,0,$0.count) } }
  }
}
