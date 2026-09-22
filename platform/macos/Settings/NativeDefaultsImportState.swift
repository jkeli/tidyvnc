// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

@MainActor public final class NativeDefaultsImportState: ObservableObject {
  @Published public private(set) var review: NativeDefaultsImportReview?
  @Published public private(set) var mapping: NativeDefaultsImportMapping?
  @Published public private(set) var requestID: UUID?
  @Published public private(set) var isLoading = false
  @Published public private(set) var isWriting = false
  @Published public private(set) var issue: String?
  @Published public private(set) var foundNoSource = false
  @Published public private(set) var imported: NativePreferencesSnapshot?
  private let service: any NativeDefaultsImportServing
  private var operation: Task<Void,Never>?
  private var stopped = false
  public var hasPending: Bool { requestID != nil || operation != nil }
  public var canEditMapping: Bool { review?.monitorNumbers.isEmpty == false }
  public init(service: any NativeDefaultsImportServing) { self.service = service }
  deinit { operation?.cancel() }

  @discardableResult public func begin(origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID],
                                      availableDisplays: [NativeDisplayID]? = nil) -> UUID? {
    guard !stopped, !hasPending else { return nil }
    dismissResult()
    let id = UUID(), service = self.service
    requestID = id; isLoading = true
    operation = Task { [weak self] in
      do {
        let result = try await service.prepareWithMapping(origin:origin,legacyDisplays:legacyDisplays,
          availableDisplays:availableDisplays ?? legacyDisplays)
        try Task.checkCancellation()
        guard let self else { return }
        self.operation = nil; self.isLoading = false
        guard !self.stopped, self.requestID == id else { return }
        switch result {
        case .review(let review): self.review = review
        case .mapping(let mapping): self.mapping = mapping
        case nil: self.foundNoSource = true; self.requestID = nil
        }
      } catch { self?.finish(error:error,request:id) }
    }
    return id
  }
  public func editMapping(_ id: UUID, legacyDisplays: [NativeDisplayID], availableDisplays: [NativeDisplayID]) {
    guard !stopped, operation == nil, !isWriting, let review, review.id == id,
          let projection = review.projection, !review.monitorNumbers.isEmpty else { return }
    do {
      mapping = try NativeDefaultsImportMapping(source:review.source,projection:projection,legacyDisplays:legacyDisplays,
        availableDisplays:availableDisplays,previous:review.monitorMapping)
      self.review = nil; issue = nil
    } catch { issue = NativeImportSourceError.invalidDisplayMapping.description }
  }
  public func resolveMapping(_ id: UUID, assignments: [Int:NativeDisplayID], availableDisplays: [NativeDisplayID]) {
    guard !stopped, operation == nil, !isWriting, let mapping, mapping.id == id else { return }
    do {
      review = try mapping.resolve(assignments,availableDisplays:availableDisplays)
      self.mapping = nil; issue = nil
    } catch { issue = String(localized:"import.defaults.choose.a.connected.display.for.every.imported.monitor.before.continuing", defaultValue:"Choose a connected display for every imported monitor before continuing.") }
  }
  // The request identity cancels loading; the distinct preview identity approves
  // exactly the rendered proposal. Late UI callbacks cannot approve a new review.
  public func cancel(_ id: UUID) {
    guard !stopped, !isWriting, requestID == id || review?.id == id || mapping?.id == id else { return }
    operation?.cancel(); review = nil; mapping = nil; requestID = nil; isLoading = false; issue = nil
  }
  public func approve(_ id: UUID, acknowledging lines: Set<UInt32>, currentDisplays: [NativeDisplayID]) {
    guard !stopped, operation == nil, let review, review.id == id, let request = requestID else { return }
    // Incomplete acknowledgement leaves the review available for correction.
    do { _ = try review.proposal.preferences(acknowledging:lines) }
    catch { issue = String(localized:"import.defaults.review.all.omitted.or.converted.settings.before.importing", defaultValue:"Review all omitted or converted settings before importing."); return }
    let service = self.service
    isWriting = true; issue = nil; self.review = nil
    operation = Task { [weak self] in
      do {
        let snapshot = try await service.commit(review,acknowledging:lines,currentDisplays:currentDisplays)
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
    requestID = nil; review = nil; mapping = nil
    if error is CancellationError || (error as? NativePreferencesError) == .cancelled { return }
    // Never surface arbitrary backend descriptions or raw source values.
    issue = (error as? NativeImportSourceError)?.description ??
      (error as? NativeDocumentOpenError)?.description ??
      (error as? NativeDocumentFailure)?.description ??
      (error as? NativeDocumentResolutionFailure)?.description ?? Self.storageMessage(error)
  }
  private static func storageMessage(_ error: Error) -> String {
    switch error as? NativePreferencesError {
    case .conflict: String(localized:"import.defaults.native.settings.changed.existing.settings.cannot.be.replaced.by.an.import", defaultValue:"Native settings changed. Existing settings cannot be replaced by an import.")
    case .corrupt, .futureSchema, .unsupportedFields, .unsupportedValue, .tooLarge:
      String(localized:"import.defaults.native.settings.could.not.be.loaded.resolve.the.stored.settings.problem.before", defaultValue:"Native settings could not be loaded. Resolve the stored settings problem before importing.")
    case .denied, .unavailable: String(localized:"import.defaults.native.settings.could.not.be.accessed.check.access.before.retrying", defaultValue:"Native settings could not be accessed. Check access before retrying.")
    default: String(localized:"import.defaults.settings.could.not.be.imported.reload.native.settings.and.review.the.source", defaultValue:"Settings could not be imported. Reload native settings and review the source before retrying.")
    }
  }
  public func dismissResult() { issue = nil; foundNoSource = false; imported = nil }
  public func stop() {
    stopped = true; operation?.cancel(); requestID = nil; review = nil; mapping = nil; dismissResult()
  }
  public func close() async { stop(); await operation?.value }
}
