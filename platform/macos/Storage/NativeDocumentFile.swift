// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

public enum NativeDocumentOpenError: Error, Equatable, Sendable, CustomStringConvertible {
  case unreadable, notRegular, tooLarge, changed, cancelled, topologyChanged
  public var description: String {
    switch self {
    case .unreadable: "The connection file could not be read. Check its location and access, then retry."
    case .notRegular: "Select a regular connection file."
    case .tooLarge: "The connection file exceeds the 1 MiB limit."
    case .changed: "The connection file changed while being read. Retry to review its current contents."
    case .cancelled: "Opening the connection file was cancelled."
    case .topologyChanged: "The display arrangement changed. Review the file's monitor selection again."
    }
  }
}
public struct NativeDocumentOpenRequest: Hashable, Codable, Sendable {
  public let id: UUID
  public let url: URL
  public let workingDirectory: String
  public init(url: URL, workingDirectory: String = FileManager.default.currentDirectoryPath) {
    id = UUID(); self.url = url; self.workingDirectory = workingDirectory
  }
}
public protocol NativeDocumentReading: Sendable {
  func read(_ url: URL) async throws -> Data
}
// No main-thread IO, unbounded Data(contentsOf:), or FIFO/device reads. A selected
// symlink may resolve to a regular file; the opened descriptor is the read identity.
public actor NativeDocumentFileReader: NativeDocumentReading {
  public init() {}
  public func read(_ url: URL) async throws -> Data {
    try Task.checkCancellation()
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw NativeDocumentOpenError.unreadable }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let fd = url.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0,O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
    }
    guard fd >= 0 else { throw NativeDocumentOpenError.unreadable }
    defer { Darwin.close(fd) }
    var before = stat()
    guard fstat(fd,&before) == 0 else { throw NativeDocumentOpenError.unreadable }
    guard before.st_mode & S_IFMT == S_IFREG else { throw NativeDocumentOpenError.notRegular }
    let limit = 1024 * 1024
    guard before.st_size <= limit else { throw NativeDocumentOpenError.tooLarge }
    var data = Data(), bytes = [UInt8](repeating:0,count:16384)
    while true {
      try Task.checkCancellation()
      let count = bytes.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress, min($0.count,limit + 1 - data.count)) }
      if count < 0 { if errno == EINTR { continue }; throw NativeDocumentOpenError.unreadable }
      if count == 0 { break }
      data.append(contentsOf:bytes.prefix(count))
      guard data.count <= limit else { throw NativeDocumentOpenError.tooLarge }
    }
    var after = stat()
    guard fstat(fd,&after) == 0 else { throw NativeDocumentOpenError.unreadable }
    guard before.st_size == after.st_size, after.st_size == data.count,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw NativeDocumentOpenError.changed }
    return data
  }
}

public struct NativeDocumentReview: Identifiable, Sendable {
  public let id = UUID()
  public let resolution: NativeDocumentResolution
  public let legacyDisplays: [NativeDisplayID]
  public let monitorMapping: [Int:NativeDisplayID]?
  public let availableDisplays: [NativeDisplayID]
  init(resolution: NativeDocumentResolution, legacyDisplays: [NativeDisplayID],
       monitorMapping: [Int:NativeDisplayID]? = nil, availableDisplays: [NativeDisplayID] = []) {
    self.resolution = resolution; self.legacyDisplays = legacyDisplays
    self.monitorMapping = monitorMapping; self.availableDisplays = availableDisplays
  }
}

extension NativeDisplaySnapshot {
  // Retained MonitorIndicesParameter orders by x, then y. Coincident rectangles
  // are mirrored there, but choosing one arbitrary UUID here would lose identity.
  // Refuse ambiguous origins, including mirrors, until a manual mapping is chosen.
  public func documentMonitorOrder() throws -> [NativeDisplayID] {
    guard error == nil, !displays.isEmpty else { throw NativeDisplayError.unavailable }
    let ordered = displays.sorted {
      $0.bounds.x == $1.bounds.x ? $0.bounds.y < $1.bounds.y : $0.bounds.x < $1.bounds.x
    }
    for pair in zip(ordered,ordered.dropFirst()) {
      guard pair.0.bounds.x != pair.1.bounds.x || pair.0.bounds.y != pair.1.bounds.y else { throw NativeDisplayError.invalidSnapshot }
    }
    return ordered.map(\.id)
  }
}
