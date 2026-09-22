// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

public struct NativeDocumentSavePresentation: Identifiable, Sendable {
  public let id = UUID()
}

@MainActor public final class NativeDocumentSaveState: ObservableObject {
  @Published public private(set) var review: NativeDocumentExport?
  @Published public private(set) var presentation: NativeDocumentSavePresentation?
  @Published public private(set) var mapping: NativeDocumentExportMapping?
  @Published public private(set) var choosing: UUID?
  @Published public private(set) var isWriting = false
  @Published public private(set) var issue: String?
  @Published public private(set) var savedURL: URL?
  private var pending: NativeDocumentExport?
  private var capture: NativeDocumentExportCapture?
  private var operation: Task<Void,Never>?
  private let writer: any NativeDocumentWriting
  private var stopped = false
  public var hasPending: Bool { pending != nil || mapping != nil || operation != nil }
  public var canEditMapping: Bool { capture?.selectedDisplays.isEmpty == false && review != nil }
  public var displayNames: [NativeDisplayID:String] { capture?.displayNames ?? [:] }
  public init(writer: any NativeDocumentWriting = NativeDocumentFileWriter()) { self.writer = writer }
  @discardableResult public func begin(_ export: NativeDocumentExport) -> Bool {
    guard !stopped, !hasPending else { return false }
    issue = nil; savedURL = nil; pending = export; review = export
    capture = nil; presentation = NativeDocumentSavePresentation()
    return true
  }
  @discardableResult public func begin(_ capture: NativeDocumentExportCapture) throws -> Bool {
    guard !stopped, !hasPending else { return false }
    let export: NativeDocumentExport?
    do { export = try capture.automaticExport() }
    catch NativeDocumentExportError.displayMapping { export = nil }
    issue = nil; savedURL = nil; self.capture = capture
    pending = export; review = export
    mapping = export == nil ? NativeDocumentExportMapping(capture:capture) : nil
    presentation = NativeDocumentSavePresentation()
    return true
  }
  public func editMapping(_ id: UUID) {
    guard !stopped, operation == nil, let review, review.id == id, let capture, canEditMapping else { return }
    mapping = NativeDocumentExportMapping(capture:capture,previous:review.monitorIndices)
    self.review = nil; pending = nil; issue = nil
  }
  public func resolveMapping(_ id: UUID, indices: [NativeDisplayID:Int]) {
    guard !stopped, operation == nil, let mapping, mapping.id == id else { return }
    do {
      let export = try mapping.capture.makeExport(monitorIndices:indices)
      pending = export; review = export; self.mapping = nil; issue = nil
    } catch { issue = String(localized:"document.assign.a.different.positive.monitor.number.to.every.saved.display.before.continuing", defaultValue:"Assign a different positive monitor number to every saved display before continuing.") }
  }
  public func cancelPresentation(_ id: UUID) {
    guard presentation?.id == id else { return }
    if let mapping { cancel(mapping.id) } else if let review { cancel(review.id) }
  }
  public func approve(_ id: UUID) {
    guard !stopped, review?.id == id, pending?.id == id else { return }
    choosing = id; review = nil; presentation = nil
  }
  public func cancel(_ id: UUID) {
    guard !stopped, operation == nil, pending?.id == id || mapping?.id == id else { return }
    pending = nil; review = nil; choosing = nil; mapping = nil; capture = nil; presentation = nil; issue = nil
  }
  public func choose(_ url: URL, id: UUID, overwrite: Bool) {
    guard !stopped, choosing == id, let export = pending, export.id == id, operation == nil else { return }
    isWriting = true; choosing = nil
    let writer = self.writer
    operation = Task { [weak self] in
      do {
        let destination = try await writer.prepare(url)
        try Task.checkCancellation()
        try await writer.write(export,acknowledging:export.losses,to:destination,overwrite:overwrite)
        self?.finish(id,saved:url,issue:nil)
      } catch is CancellationError { self?.finish(id,saved:nil,issue:nil) }
      catch {
        let message = (error as? NativeDocumentSaveError)?.description ??
          (error as? NativeDocumentExportError)?.description ?? NativeDocumentSaveError.writeFailed.description
        self?.finish(id,saved:nil,issue:message)
      }
    }
  }
  private func finish(_ id: UUID, saved: URL?, issue: String?) {
    operation = nil
    if !stopped, pending?.id == id { self.savedURL = saved; self.issue = issue }
    pending = nil; capture = nil; isWriting = false
  }
  public func dismissResult() { issue = nil; savedURL = nil }
  public func stop() {
    stopped = true; operation?.cancel(); pending = nil; review = nil; choosing = nil; issue = nil; savedURL = nil
    mapping = nil; capture = nil; presentation = nil
  }
  public func close() async { stop(); await operation?.value }
}
