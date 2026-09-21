// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit

public enum NativePasteboardError: Error, Equatable {
  case changed, tooLarge, invalidText, unavailable, writeFailed
}
public enum NativePasteboardContent: Equatable {
  case text(String), remote, unavailable
}
// Small host contract, also implemented by deterministic test adapters. The
// coordinator serializes native access and focus changes on MainActor.
@MainActor public protocol NativePasteboardAccess: AnyObject {
  var changeCount: Int { get }
  func read(expectedChange: Int, maximumBytes: Int) throws -> NativePasteboardContent
  func writeRemote(_ text: String, maximumBytes: Int) throws -> Int
}
@MainActor public final class NativePasteboard: NativePasteboardAccess {
  static let remoteType = NSPasteboard.PasteboardType("io.github.jkeli.tidyvnc.remote-clipboard")
  private let board: NSPasteboard
  public init(_ board: NSPasteboard = .general) { self.board = board }
  public var changeCount: Int { board.changeCount }
  static func validate(_ text: String, maximumBytes: Int) throws {
    guard maximumBytes > 0, maximumBytes <= 16 * 1024 * 1024 else { throw NativePasteboardError.tooLarge }
    guard maximumBytes > 0, text.utf8.prefix(maximumBytes + 1).count <= maximumBytes else { throw NativePasteboardError.tooLarge }
    guard !text.utf8.contains(0) else { throw NativePasteboardError.invalidText }
  }
  public func read(expectedChange: Int, maximumBytes: Int) throws -> NativePasteboardContent {
    guard changeCount == expectedChange else { throw NativePasteboardError.changed }
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
    guard changeCount == expectedChange else { throw NativePasteboardError.changed }
    return value
  }
  public func writeRemote(_ text: String, maximumBytes: Int) throws -> Int {
    try Self.validate(text, maximumBytes: maximumBytes)
    let item = NSPasteboardItem()
    let origin = UUID().uuidString
    guard item.setString(text, forType: .string), item.setString(origin, forType: Self.remoteType) else { throw NativePasteboardError.writeFailed }
    // Prepare the complete item before changing the board. NSPasteboard does
    // not provide a cross-process CAS/transaction; report failures honestly.
    board.clearContents()
    guard board.writeObjects([item]) else { throw NativePasteboardError.writeFailed }
    let written = changeCount
    guard board.string(forType: Self.remoteType) == origin, changeCount == written else { throw NativePasteboardError.changed }
    return written
  }
}
