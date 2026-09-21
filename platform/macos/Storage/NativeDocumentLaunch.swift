// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// AppKit can deliver document events before SwiftUI supplies its window action.
// Keep only bounded, non-secret file requests, never a connection/credential or
// a view/window owner. The installed action is app-scoped and survives closing
// the view that first supplied it. Every explicit open gets a distinct window ID.
@MainActor public final class NativeDocumentLaunchRouter {
  public static let maximumPending = 64
  public private(set) var pendingCount = 0
  private var pending: [NativeDocumentOpenRequest] = []
  private var open: (@MainActor (NativeDocumentOpenRequest) -> Void)?
  private var draining = false, stopped = false
  public init() {}
  @discardableResult public func route(urls: [URL], workingDirectory: String = FileManager.default.currentDirectoryPath) -> Bool {
    guard urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }) else { return false }
    return route(filePaths:urls.map(\.path),workingDirectory:workingDirectory)
  }
  @discardableResult public func route(filePaths: [String], workingDirectory: String = FileManager.default.currentDirectoryPath) -> Bool {
    guard !stopped, filePaths.count <= Self.maximumPending - pending.count,
          filePaths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) else { return false }
    // Validate the complete batch before appending or opening any member.
    pending += filePaths.map { NativeDocumentOpenRequest(url:URL(fileURLWithPath:$0),workingDirectory:workingDirectory) }
    pendingCount = pending.count
    drain()
    return true
  }
  public func install(_ open: @escaping @MainActor (NativeDocumentOpenRequest) -> Void) {
    guard !stopped else { return }
    self.open = open
    drain()
  }
  private func drain() {
    guard !draining else { return }
    draining = true; defer { draining = false }
    while !stopped, let action = open, !pending.isEmpty {
      let next = pending.removeFirst(); pendingCount = pending.count
      action(next)
    }
  }
  public func stop() {
    stopped = true; open = nil; pending.removeAll(); pendingCount = 0
  }
}
