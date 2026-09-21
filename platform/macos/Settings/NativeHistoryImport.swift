// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public enum NativeHistoryImportError: Error, Equatable, Sendable, CustomStringConvertible {
  case tooLarge, invalidText(UInt32), lineTooLong(UInt32), reviewRequired
  case nativeHistoryExists, currentHistoryExists
  public var description: String {
    switch self {
    case .tooLarge: "The history file exceeds the 1 MiB import limit."
    case .invalidText(let line): "The history file contains invalid text on line \(line)."
    case .lineTooLong(let line): "The history entry on line \(line) exceeds the 254-byte source limit."
    case .reviewRequired: "Review the duplicate and older entries omitted from history before importing."
    case .nativeHistoryExists: "Native history has already been used or cleared and cannot be replaced by an import."
    case .currentHistoryExists: "Current TidyVNC history exists. Review that source instead of importing legacy history."
    }
  }
}

// History has separate consent from settings. This is only a bounded list of
// address text: no option parser, DNS lookup, session, credential or trust IO.
public struct NativeHistoryImport: Identifiable, Sendable {
  public static let maximumBytes = 1024 * 1024
  public static let maximumEntryBytes = 254 // Retained legacy history import.
  public let id = UUID()
  public let origin: NativeImportOrigin
  public let endpoints: [String]
  public let duplicateCount: Int
  public let omittedOlderCount: Int
  public var requiresOmissionReview: Bool { duplicateCount != 0 || omittedOlderCount != 0 }
  public init(data: Data, origin: NativeImportOrigin) throws {
    guard data.count <= Self.maximumBytes else { throw NativeHistoryImportError.tooLarge }
    var endpoints: [String] = [], seen = Set<String>(), duplicates = 0, older = 0
    for (index, raw) in data.split(separator:10,omittingEmptySubsequences:false).enumerated() {
      let line = UInt32(index+1)
      let bytes = raw.last == 13 ? raw.dropLast() : raw[...]
      guard bytes.count <= Self.maximumEntryBytes else { throw NativeHistoryImportError.lineTooLong(line) }
      guard !bytes.contains(0), let text = String(data:Data(bytes),encoding:.utf8) else {
        throw NativeHistoryImportError.invalidText(line)
      }
      // Validate every line, including duplicates and entries past capacity.
      // Preserve whitespace, case, display/port spelling and source order.
      guard !text.isEmpty else { continue }
      guard seen.insert(text).inserted else { duplicates += 1; continue }
      if endpoints.count < NativeProfileHistoryStore.historyCapacity { endpoints.append(text) }
      else { older += 1 }
    }
    self.origin = origin; self.endpoints = endpoints
    duplicateCount = duplicates; omittedOlderCount = older
  }
  public func reviewedEndpoints(acknowledgingOmissions: Bool) throws -> [String] {
    guard !requiresOmissionReview || acknowledgingOmissions else { throw NativeHistoryImportError.reviewRequired }
    return endpoints
  }
}
