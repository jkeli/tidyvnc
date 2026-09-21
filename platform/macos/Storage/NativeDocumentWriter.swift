// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

public enum NativeDocumentSaveError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidDestination, denied, changed, overwriteRequired, busy, writeFailed, committedUncertain
  public var description: String {
    switch self {
    case .invalidDestination: "Choose a regular .tidyvnc file in an existing folder. Symbolic links and special files cannot be replaced."
    case .denied: "The connection file cannot be written here. Check access or choose another location."
    case .changed: "The destination changed after selection. Choose it again before saving."
    case .overwriteRequired: "Confirm replacement of the existing connection file before saving."
    case .busy: "Another save is using this folder. Try again when it finishes."
    case .writeFailed: "The connection file could not be saved. The destination was not replaced."
    case .committedUncertain: "The file was replaced, but the final save check failed. Inspect the destination before retrying."
    }
  }
}
private struct DocumentFileIdentity: Equatable, Sendable {
  let device: Int32, inode: UInt64
  let size: Int64, modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
  let mode: UInt16, owner: UInt32, group: UInt32, links: UInt16, flags: UInt32
  init(_ value: stat) {
    device = value.st_dev; inode = value.st_ino; size = value.st_size
    modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
    changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    mode = value.st_mode; owner = value.st_uid; group = value.st_gid; links = value.st_nlink; flags = value.st_flags
  }
}
public struct NativeDocumentDestination: Sendable {
  public let url: URL
  public var exists: Bool { file != nil }
  fileprivate let writerID: UUID
  fileprivate let directoryDevice: Int32, directoryInode: UInt64
  fileprivate let file: DocumentFileIdentity?
}
public protocol NativeDocumentWriting: Sendable {
  func prepare(_ url: URL) async throws -> NativeDocumentDestination
  func write(_ export: NativeDocumentExport, acknowledging: Set<NativeDocumentExportLoss>,
             to destination: NativeDocumentDestination, overwrite: Bool) async throws
}

// Selected-file IO stays off MainActor. No directories, lock files or persistent
// access grants are created. A directory flock serializes cooperating writers;
// metadata is checked again immediately before rename for other normal editors.
// POSIX rename is atomic replacement, not a CAS against uncoordinated writers.
public actor NativeDocumentFileWriter: NativeDocumentWriting {
  private let id = UUID()
  enum Checkpoint: Sendable { case written, willReplace, didReplace }
  private let checkpoint: @Sendable (Checkpoint, URL) throws -> Void
  public init() { checkpoint = { _,_ in } }
  init(checkpoint: @escaping @Sendable (Checkpoint, URL) throws -> Void) { self.checkpoint = checkpoint }
  private func failure() -> NativeDocumentSaveError {
    switch errno {
    case EACCES, EPERM, EROFS: .denied
    case ELOOP, ENOTDIR, EISDIR, ENAMETOOLONG: .invalidDestination
    default: .writeFailed
    }
  }
  private func validate(_ url: URL) throws {
    guard url.isFileURL, [nil,"","localhost"].contains(url.host), url.path.hasPrefix("/"),
          !url.path.utf8.contains(0), url.path.utf8.count <= 4096,
          url.pathExtension.lowercased() == "tidyvnc", !url.hasDirectoryPath,
          url.lastPathComponent.utf8.count <= 255 else { throw NativeDocumentSaveError.invalidDestination }
  }
  private func directory(_ url: URL) throws -> Int32 {
    let fd = Darwin.open(url.deletingLastPathComponent().path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw failure() }
    return fd
  }
  private func directoryIdentity(_ fd: Int32) throws -> stat {
    var value = stat()
    guard fstat(fd,&value) == 0 else { throw failure() }
    return value
  }
  private func inspect(_ root: Int32, _ name: String) throws -> DocumentFileIdentity? {
    var value = stat()
    if fstatat(root,name,&value,AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return nil }; throw failure()
    }
    guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw NativeDocumentSaveError.invalidDestination }
    guard value.st_uid == geteuid(), value.st_mode & 0o200 != 0,
          faccessat(root,name,W_OK,AT_EACCESS) == 0 else { throw NativeDocumentSaveError.denied }
    return DocumentFileIdentity(value)
  }
  public func prepare(_ url: URL) async throws -> NativeDocumentDestination {
    try Task.checkCancellation(); try validate(url)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let root = try directory(url); defer { Darwin.close(root) }
    let parent = try directoryIdentity(root), file = try inspect(root,url.lastPathComponent)
    try Task.checkCancellation()
    return NativeDocumentDestination(url:url,writerID:id,directoryDevice:parent.st_dev,directoryInode:parent.st_ino,file:file)
  }
  public func write(_ export: NativeDocumentExport, acknowledging losses: Set<NativeDocumentExportLoss>,
                    to destination: NativeDocumentDestination, overwrite: Bool) async throws {
    // Required loss review and complete output validation precede all writes.
    let data = try export.serializedData(acknowledging:losses)
    try Task.checkCancellation()
    guard destination.writerID == id else { throw NativeDocumentSaveError.changed }
    guard !destination.exists || overwrite else { throw NativeDocumentSaveError.overwriteRequired }
    let url = destination.url
    try validate(url)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let root = try directory(url); defer { Darwin.close(root) }
    let parent = try directoryIdentity(root)
    guard parent.st_dev == destination.directoryDevice, parent.st_ino == destination.directoryInode else { throw NativeDocumentSaveError.changed }
    guard flock(root,LOCK_EX | LOCK_NB) == 0 else { throw NativeDocumentSaveError.busy }
    defer { flock(root,LOCK_UN) }
    let name = url.lastPathComponent
    guard try inspect(root,name) == destination.file else { throw NativeDocumentSaveError.changed }
    let temporary = ".tidyvnc-export-\(UUID().uuidString).tmp"
    let output = openat(root,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
    guard output >= 0 else { throw failure() }
    var committed = false
    defer { Darwin.close(output); if !committed { unlinkat(root,temporary,0) } }
    guard let acl = acl_init(0) else { throw failure() }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_fd_np(output,acl,ACL_TYPE_EXTENDED) == 0, fchmod(output,0o600) == 0 else { throw failure() }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        try Task.checkCancellation()
        let count = Darwin.write(output,bytes.baseAddress?.advanced(by:offset),min(16384,bytes.count-offset))
        if count < 0 { if errno == EINTR { continue }; throw failure() }
        guard count > 0 else { throw NativeDocumentSaveError.writeFailed }
        offset += count
      }
    }
    try checkpoint(.written,url)
    guard fsync(output) == 0 else { throw failure() }
    try checkpoint(.willReplace,url)
    try Task.checkCancellation()
    guard try inspect(root,name) == destination.file else { throw NativeDocumentSaveError.changed }
    // A replaced/moved parent path must not redirect the selected destination.
    let currentRoot = try directory(url); defer { Darwin.close(currentRoot) }
    let currentParent = try directoryIdentity(currentRoot)
    guard currentParent.st_dev == parent.st_dev, currentParent.st_ino == parent.st_ino else { throw NativeDocumentSaveError.changed }
    let result = destination.exists ? renameat(root,temporary,root,name) :
      renameatx_np(root,temporary,root,name,UInt32(RENAME_EXCL))
    guard result == 0 else {
      if errno == EEXIST { throw NativeDocumentSaveError.changed }; throw failure()
    }
    committed = true
    // Cancellation after commit cannot roll back a successful rename. A later
    // failure must never be reported as preserving the old destination.
    do {
      try checkpoint(.didReplace,url)
      guard fsync(root) == 0 else { throw NativeDocumentSaveError.committedUncertain }
    } catch { throw NativeDocumentSaveError.committedUncertain }
  }
}
