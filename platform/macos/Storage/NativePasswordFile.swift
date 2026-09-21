// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

public enum NativePasswordFileIssue: Error, Sendable, Equatable, CustomStringConvertible {
  case unreadable, notRegular, truncated, changed, cancelled
  public var description: String {
    switch self {
    case .unreadable: "The password file could not be read. Check its location and access, then retry."
    case .notRegular: "The password file must be a regular file."
    case .truncated: "The password file does not contain a complete legacy password block."
    case .changed: "The password file changed while being read. Retry with its current contents."
    case .cancelled: "Reading the password file was cancelled."
    }
  }
}
public protocol NativePasswordFileReading: Sendable {
  // Owns only the first eight obfuscated bytes. This legacy format is not
  // encryption. The caller must clear the returned block after use/cancellation.
  func read(_ url: URL) async throws -> NativeCredentialSecret
}
// No main-actor isolation, unbounded allocation, FIFO/device reads or plaintext
// decoding. A selected symlink may resolve to a regular file, as in the retained
// viewer. Access scope and descriptor close before the block crosses actors.
public actor NativePasswordFileReader: NativePasswordFileReading {
  public init() {}
  public func read(_ url: URL) async throws -> NativeCredentialSecret {
    func checkCancellation() throws { if Task.isCancelled { throw NativePasswordFileIssue.cancelled } }
    try checkCancellation()
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw NativePasswordFileIssue.unreadable }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let fd = url.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0,O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
    }
    guard fd >= 0 else { throw NativePasswordFileIssue.unreadable }
    defer { Darwin.close(fd) }
    var before = stat()
    guard fstat(fd,&before) == 0 else { throw NativePasswordFileIssue.unreadable }
    guard before.st_mode & S_IFMT == S_IFREG else { throw NativePasswordFileIssue.notRegular }
    guard before.st_size >= 8 else { throw NativePasswordFileIssue.truncated }
    var bytes = [UInt8](repeating:0,count:8), offset = 0
    defer { bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base,$0.count,0,$0.count) } } }
    while offset < bytes.count {
      try checkCancellation()
      let count = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
      }
      if count < 0 { if errno == EINTR { continue }; throw NativePasswordFileIssue.unreadable }
      guard count > 0 else { throw NativePasswordFileIssue.truncated }
      offset += count
    }
    var after = stat()
    guard fstat(fd,&after) == 0 else { throw NativePasswordFileIssue.unreadable }
    guard before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw NativePasswordFileIssue.changed }
    try checkCancellation()
    return try NativeCredentialSecret(consuming:&bytes)
  }
}
