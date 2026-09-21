// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public struct NativeHistoryImportReview: Identifiable, Sendable {
  public var id: UUID { proposal.id }
  public let source: URL
  public let proposal: NativeHistoryImport
  public let expectedRevision: UUID?
}
public protocol NativeHistoryImportServing: Sendable {
  func prepare(origin: NativeImportOrigin) async throws -> NativeHistoryImportReview?
  func commit(_ review: NativeHistoryImportReview, acknowledgingOmissions: Bool) async throws -> NativeProfileHistorySnapshot
}

// History has its own source selection and destination admission. Importing
// settings cannot read history or grant consent to import these addresses.
public actor NativeHistoryImportService: NativeHistoryImportServing {
  private let paths: NativeImportPaths
  private let store: NativeProfileHistoryStore
  private let reader: any NativeDocumentReading
  public init(paths: NativeImportPaths, store: NativeProfileHistoryStore,
              reader: any NativeDocumentReading = NativeDocumentFileReader()) {
    self.paths = paths; self.store = store; self.reader = reader
  }
  public func prepare(origin: NativeImportOrigin) async throws -> NativeHistoryImportReview? {
    try Task.checkCancellation()
    let native = try await store.read()
    guard native.canImportHistory else { throw NativeHistoryImportError.nativeHistoryExists }
    try Task.checkCancellation()
    let candidates: [URL]
    switch origin {
    case .currentXDG: candidates = [paths.currentHistory]
    case .legacy:
      guard try !NativeImportSourceInspection.exists(paths.currentHistory) else { throw NativeHistoryImportError.currentHistoryExists }
      candidates = paths.legacyHistory
    }
    for source in candidates {
      guard try NativeImportSourceInspection.exists(source) else { continue }
      let bytes = try await reader.read(source)
      try Task.checkCancellation()
      let proposal = try NativeHistoryImport(data:bytes,origin:origin)
      try Task.checkCancellation()
      return NativeHistoryImportReview(source:source,proposal:proposal,expectedRevision:native.revision)
    }
    return nil
  }
  public func commit(_ review: NativeHistoryImportReview, acknowledgingOmissions: Bool) async throws -> NativeProfileHistorySnapshot {
    try Task.checkCancellation()
    // Keep the source snapshot immutable. The shared destination revision and
    // backing CAS protect profile edits as well as independently recorded history.
    return try await store.importHistory(review.proposal,expected:review.expectedRevision,
                                         acknowledgingOmissions:acknowledgingOmissions)
  }
}
