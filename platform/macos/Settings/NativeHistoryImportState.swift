// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

@MainActor public final class NativeHistoryImportState: ObservableObject {
  @Published public private(set) var review: NativeHistoryImportReview?
  @Published public private(set) var requestID: UUID?
  @Published public private(set) var isLoading = false
  @Published public private(set) var isWriting = false
  @Published public private(set) var issue: String?
  @Published public private(set) var foundNoSource = false
  @Published public private(set) var imported: NativeProfileHistorySnapshot?
  private let service: any NativeHistoryImportServing
  private var operation: Task<Void,Never>?
  private var stopped = false
  public var hasPending: Bool { requestID != nil || operation != nil }
  public init(service: any NativeHistoryImportServing) { self.service = service }
  deinit { operation?.cancel() }

  @discardableResult public func begin(origin: NativeImportOrigin) -> UUID? {
    guard !stopped, !hasPending else { return nil }
    dismissResult()
    let id = UUID(), service = self.service
    requestID = id; isLoading = true
    operation = Task { [weak self] in
      do {
        let result = try await service.prepare(origin:origin)
        try Task.checkCancellation()
        guard let self else { return }
        self.operation = nil; self.isLoading = false
        guard !self.stopped, self.requestID == id else { return }
        self.review = result; self.foundNoSource = result == nil
        if result == nil { self.requestID = nil }
      } catch { self?.finish(error:error,request:id) }
    }
    return id
  }
  // The request identity cancels loading; the distinct preview identity approves
  // exactly the rendered proposal. Late UI callbacks cannot approve a new review.
  public func cancel(_ id: UUID) {
    guard !stopped, !isWriting, requestID == id || review?.id == id else { return }
    operation?.cancel(); review = nil; requestID = nil; isLoading = false
  }
  public func approve(_ id: UUID, acknowledgingOmissions: Bool) {
    guard !stopped, operation == nil, let review, review.id == id, let request = requestID else { return }
    // Incomplete acknowledgement leaves the review available for correction.
    do { _ = try review.proposal.reviewedEndpoints(acknowledgingOmissions:acknowledgingOmissions) }
    catch { issue = String(localized:"history.import.review.the.duplicate.and.older.entries.omitted.from.history.before.importing", defaultValue:"Review the duplicate and older entries omitted from history before importing."); return }
    let service = self.service
    isWriting = true; issue = nil; self.review = nil
    operation = Task { [weak self] in
      do {
        let snapshot = try await service.commit(review,acknowledgingOmissions:acknowledgingOmissions)
        // A successful commit remains success even if cancellation arrived after
        // acceptance. Closed UI suppresses delivery without pretending rollback.
        guard let self else { return }
        self.operation = nil; self.isWriting = false
        if !self.stopped, self.requestID == request { self.imported = snapshot }
        self.requestID = nil
      } catch { self?.finish(error:error,request:request) }
    }
  }
  private func finish(error: Error, request: UUID) {
    operation = nil; isLoading = false; isWriting = false
    guard !stopped, requestID == request else { return }
    requestID = nil; review = nil
    if error is CancellationError || (error as? NativeStorageError) == .cancelled ||
       (error as? NativeDocumentOpenError) == .cancelled { return }
    // Backend descriptions can contain source values. Only controlled messages
    // reach the UI, with shared file-reader failures translated for history.
    issue = (error as? NativeHistoryImportError)?.description ?? Self.message(error)
  }
  private static func message(_ error: Error) -> String {
    if let source = error as? NativeImportSourceError {
      switch source {
      case .invalidPath, .inaccessible: return source.description
      default: return String(localized:"history.import.the.history.source.could.not.be.reviewed.check.its.location.and.retry", defaultValue:"The history source could not be reviewed. Check its location and retry.")
      }
    }
    if let file = error as? NativeDocumentOpenError {
      switch file {
      case .unreadable: return String(localized:"history.import.the.history.file.could.not.be.read.check.its.location.and.access", defaultValue:"The history file could not be read. Check its location and access, then retry.")
      case .notRegular: return String(localized:"history.import.the.history.source.must.be.a.regular.file", defaultValue:"The history source must be a regular file.")
      case .tooLarge: return String(localized:"history.import.the.history.file.exceeds.the.1.mib.limit", defaultValue:"The history file exceeds the 1 MiB limit.")
      case .changed: return String(localized:"history.import.the.history.file.changed.while.being.read.retry.to.review.its.current", defaultValue:"The history file changed while being read. Retry to review its current contents.")
      default: return String(localized:"history.import.the.history.file.could.not.be.reviewed.retry.before.importing", defaultValue:"The history file could not be reviewed. Retry before importing.")
      }
    }
    switch error as? NativeStorageError {
    case .conflict: return String(localized:"history.import.native.profiles.or.history.changed.review.the.source.again.before.importing", defaultValue:"Native profiles or history changed. Review the source again before importing.")
    case .corrupt, .futureSchema, .unsupportedFields, .unsupportedValue, .tooLarge:
      return String(localized:"history.import.native.profiles.and.history.could.not.be.loaded.resolve.the.stored.data", defaultValue:"Native profiles and history could not be loaded. Resolve the stored data problem before importing.")
    case .denied, .unavailable: return String(localized:"history.import.native.profiles.and.history.could.not.be.accessed.check.access.before.retrying", defaultValue:"Native profiles and history could not be accessed. Check access before retrying.")
    default: return String(localized:"history.import.history.import.could.not.be.confirmed.reload.recent.connections.before.reviewing.another", defaultValue:"History import could not be confirmed. Reload recent connections before reviewing another import.")
    }
  }
  public func dismissResult() { issue = nil; foundNoSource = false; imported = nil }
  public func stop() {
    stopped = true; operation?.cancel(); requestID = nil; review = nil; dismissResult()
  }
  public func close() async { stop(); await operation?.value }
}
