// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

public enum NativeStorageError: Error, Equatable, Sendable {
  case notFound, denied, unavailable, invalid, invalidTLSPriority, conflict, busy, ioFailure, cancelled, closed
  case corrupt, futureSchema, unsupportedFields, unsupportedValue, tooLarge, resourceLimit
}
public protocol NativeAtomicFileBacking: Sendable {
  func read() throws -> Data?
  // Cooperating writers compare exact previously read bytes under one file lock.
  // A throwing write may already have replaced the record; reread to reconcile.
  func replace(_ data: Data, expected: Data?) throws
}

public typealias NativeProfileHistoryBacking = NativeAtomicFileBacking

// All paths and descriptors remain in the macOS storage layer. No user-selected
// path components enter filenames. Read never creates directories or lock files.
public final class NativePrivateFile: NativeProfileHistoryBacking, @unchecked Sendable {
  public static let maximumBytes = 2 * 1024 * 1024
  public let directory: URL
  private let prepareParent: Bool
  public enum RecordKind: Sendable {
    case profileHistory, trustExceptions, serverKeys
    var stem: String {
      switch self { case .profileHistory: "profiles-history"; case .trustExceptions: "trust-exceptions"; case .serverKeys: "server-keys" }
    }
  }
  private let record: RecordKind
  private var filename: String { record.stem + ".json" }
  enum Checkpoint: Sendable { case written, willReplace, didReplace }
  private let checkpoint: @Sendable (Checkpoint) throws -> Void
  public convenience init(directory: URL, record: RecordKind = .profileHistory) throws { try self.init(directory: directory, record: record, checkpoint: { _ in }) }
  init(directory: URL, record: RecordKind = .profileHistory, prepareParent: Bool = false, checkpoint: @escaping @Sendable (Checkpoint) throws -> Void) throws {
    guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else { throw NativeStorageError.invalid }
    self.directory = directory; self.record = record; self.prepareParent = prepareParent; self.checkpoint = checkpoint
  }
  public static func applicationSupport(record: RecordKind = .profileHistory) throws -> NativePrivateFile {
    guard let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw NativeStorageError.unavailable }
    return try NativePrivateFile(directory: parent.appendingPathComponent("io.github.jkeli.tidyvnc.native", isDirectory: true), record: record, prepareParent: true, checkpoint: { _ in })
  }
  private func failure(_ code: Int32 = errno) -> NativeStorageError {
    switch code {
    case ENOENT: return .notFound
    case EACCES, EPERM, EROFS, ELOOP: return .denied
    case EAGAIN: return .busy
    case ENOTDIR, EISDIR: return .invalid
    default: return .ioFailure
    }
  }
  private func aclIsEmpty(_ fd: Int32) throws -> Bool {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
      // Darwin reports an absent extended ACL as ENOENT even for a valid fd.
      if errno == ENOENT { return true }
      throw failure()
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    if result == 0 { return false }
    // Darwin reports no entry with -1/EINVAL (rather than POSIX's zero).
    if errno == EINVAL { return true }
    throw failure()
  }
  private func makePrivate(_ fd: Int32, directory: Bool) throws {
    guard let acl = acl_init(0) else { throw failure() }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0,
          fchmod(fd, directory ? 0o700 : 0o600) == 0 else { throw failure() }
  }
  private func inspect(_ fd: Int32, directory: Bool, writing: Bool) throws -> stat {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw failure() }
    let kind = info.st_mode & mode_t(S_IFMT)
    guard kind == mode_t(directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw NativeStorageError.invalid }
    guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
          info.st_mode & 0o400 != 0, !directory || info.st_mode & 0o100 != 0,
          !writing || info.st_mode & 0o200 != 0, try aclIsEmpty(fd) else { throw NativeStorageError.denied }
    return info
  }
  private func openDirectory(create: Bool) throws -> Int32? {
    var created = false
    if create {
      if mkdir(directory.path, 0o700) == 0 { created = true }
      else if errno == ENOENT && prepareParent {
        do {
          try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        } catch let error as NSError {
          if error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) {
            throw NativeStorageError.denied
          }
          throw NativeStorageError.ioFailure
        }
        if mkdir(directory.path, 0o700) == 0 { created = true }
        else if errno != EEXIST { throw failure() }
      } else if errno != EEXIST { throw failure() }
    }
    let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      if !create && errno == ENOENT { return nil }
      throw failure()
    }
    do {
      if created { try makePrivate(fd, directory: true) }
      _ = try inspect(fd, directory: true, writing: create)
      return fd
    } catch { Darwin.close(fd); throw error }
  }
  private func read(at root: Int32, writing: Bool = false) throws -> Data? {
    let fd = openat(root, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 { if errno == ENOENT { return nil }; throw failure() }
    defer { Darwin.close(fd) }
    let info = try inspect(fd, directory: false, writing: writing)
    guard info.st_size >= 0, info.st_size <= Self.maximumBytes else { throw NativeStorageError.tooLarge }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 { if errno == EINTR { continue }; throw failure() }
      if count == 0 { break }
      guard result.count + count <= Self.maximumBytes else { throw NativeStorageError.tooLarge }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }
  public func read() throws -> Data? {
    guard !Task.isCancelled else { throw NativeStorageError.cancelled }
    guard let root = try openDirectory(create: false) else { return nil }
    defer { Darwin.close(root) }
    return try read(at: root)
  }
  public func replace(_ data: Data, expected: Data?) throws {
    guard !Task.isCancelled else { throw NativeStorageError.cancelled }
    guard data.count <= Self.maximumBytes else { throw NativeStorageError.tooLarge }
    guard let root = try openDirectory(create: true) else { throw NativeStorageError.unavailable }
    defer { Darwin.close(root) }
    var lock = openat(root, ".\(record.stem).lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    let createdLock = lock >= 0
    if lock < 0 && errno == EEXIST { lock = openat(root, ".\(record.stem).lock", O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
    guard lock >= 0 else { throw failure() }
    defer { Darwin.close(lock) }
    if createdLock { try makePrivate(lock, directory: false) }
    _ = try inspect(lock, directory: false, writing: true)
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw failure() }
    defer { flock(lock, LOCK_UN) }
    guard try read(at: root, writing: true) == expected else { throw NativeStorageError.conflict }
    let temporary = ".\(record.stem).\(UUID().uuidString).tmp"
    let output = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw failure() }
    var replaced = false
    defer { Darwin.close(output); if !replaced { unlinkat(root, temporary, 0) } }
    try makePrivate(output, directory: false)
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(output, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0 { if errno == EINTR { continue }; throw failure() }
        guard count > 0 else { throw NativeStorageError.ioFailure }
        offset += count
      }
    }
    try checkpoint(.written)
    guard fsync(output) == 0 else { throw failure() }
    try checkpoint(.willReplace)
    guard !Task.isCancelled else { throw NativeStorageError.cancelled }
    guard renameat(root, temporary, root, filename) == 0 else { throw failure() }
    replaced = true
    // From here cancellation cannot roll back. A failing directory sync or
    // later checkpoint has an uncertain committed outcome, requiring reread.
    try checkpoint(.didReplace)
    guard fsync(root) == 0 else { throw failure() }
  }
}

// Resolve the host location on access so app construction cannot fail or touch
// disk. One owning store actor still serializes every operation.
public struct NativeApplicationSupportProfiles: NativeProfileHistoryBacking {
  public init() {}
  public func read() throws -> Data? { try NativePrivateFile.applicationSupport().read() }
  public func replace(_ data: Data, expected: Data?) throws {
    try NativePrivateFile.applicationSupport().replace(data, expected: expected)
  }
}
