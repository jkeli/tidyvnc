// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

// Internal injection point for deterministic admission/completion/lifetime tests.
@MainActor protocol NativeEncodingTarget: AnyObject {
  var encodingGeneration: UInt64 { get }
  var encodingEditable: Bool { get }
  func readEncoding() throws -> NativeEncodingOptions
  func submitEncoding(_ options: NativeEncodingOptions, generation: UInt64) async throws
}
extension NativeSession: NativeEncodingTarget {
  var encodingGeneration: UInt64 { generation }
  var encodingEditable: Bool { !isClosing && snapshot.state == .connected }
  func readEncoding() throws -> NativeEncodingOptions { try encodingOptions() }
  func submitEncoding(_ options: NativeEncodingOptions, generation: UInt64) async throws {
    _ = try await applyEncoding(options, expectedGeneration: generation)
  }
}

public enum NativeEncodingDraftError: Error, Equatable, Sendable {
  case unavailable, invalidValue, unsupportedValue, changed, applyFailed, cancelled
}

// One editor for one session generation. Nothing here accesses durable defaults.
@MainActor public final class NativeSessionEncodingDraft: ObservableObject, Identifiable {
  public nonisolated let id = UUID()
  @Published public private(set) var values: [NativeEncodingOption: NativeEncodingValue] = [:]
  @Published public private(set) var schema: [NativeEncodingSchema] = []
  @Published public private(set) var choices: [NativeEncodingChoice] = []
  @Published public private(set) var isBusy = false
  @Published public private(set) var isAvailable = false
  @Published public private(set) var needsReload = false
  @Published public private(set) var error: NativeEncodingDraftError?
  @Published public private(set) var didApply = false
  private weak var target: (any NativeEncodingTarget)?
  private var baseline: NativeEncodingOptions?, draft: NativeEncodingOptions?
  private var baselineValues: [NativeEncodingOption: NativeEncodingValue] = [:]
  private var generation: UInt64?
  private var operation: Task<Void, Never>?
  private var observations: [AnyCancellable] = []
  private var stopped = false
  init(target: any NativeEncodingTarget) { self.target = target }
  public convenience init(session: NativeSession) {
    self.init(target: session)
    observations = [session.$snapshot.sink { [weak self] snapshot in
      MainActor.assumeIsolated { self?.sessionChanged(generation: snapshot.generation, connected: snapshot.state == .connected) }
    }, session.$isClosing.sink { [weak self] closing in
      if closing { MainActor.assumeIsolated { self?.sessionChanged(generation: nil, connected: false) } }
    }]
  }
  deinit { operation?.cancel() }
  public var hasChanges: Bool { baseline != nil && values != baselineValues }
  public var canApply: Bool {
    !stopped && !isBusy && !needsReload && hasChanges && target?.encodingEditable == true && target?.encodingGeneration == generation
  }
  public var canReload: Bool { !stopped && !isBusy && target?.encodingEditable == true }
  private func sessionChanged(generation current: UInt64?, connected: Bool) {
    guard !stopped else { return }
    if isAvailable != connected { isAvailable = connected }
    if baseline != nil && (!connected || generation != current) {
      needsReload = true; error = .changed; didApply = false
    }
  }
  private static func readValues(_ options: NativeEncodingOptions) throws -> [NativeEncodingOption: NativeEncodingValue] {
    try Dictionary(uniqueKeysWithValues: NativeEncodingOption.allCases.map { ($0, try options.value(for: $0)) })
  }
  public func reload() {
    guard !stopped, !isBusy else { return }
    guard let target, target.encodingEditable else { isAvailable = false; needsReload = true; error = .unavailable; return }
    do {
      let current = try target.readEncoding(), fields = try Self.readValues(current)
      let schema = try NativeEncodingOptions.schema(), choices = try NativeEncodingOptions.choices()
      baseline = current; draft = current; baselineValues = fields; values = fields
      self.schema = schema; self.choices = choices; generation = target.encodingGeneration
      isAvailable = true; needsReload = false; error = nil; didApply = false
    } catch { needsReload = true; self.error = .unavailable }
  }
  public func setEncoding(_ option: NativeEncodingOption, value: String) {
    guard !stopped, !isBusy, !needsReload, let draft,
          let field = schema.first(where: { $0.id == option }), field.live else { return }
    do {
      let updated = try draft.applying([.init(field.name, value)], source: .session)
      let fields = try Self.readValues(updated)
      self.draft = updated; values = fields; error = nil; didApply = false
    } catch { self.error = (error as? NativeError)?.status == .unsupported ? .unsupportedValue : .invalidValue }
  }
  public func cancelEdits() {
    guard !isBusy, !stopped else { return }
    draft = baseline; values = baselineValues; didApply = false
    if !needsReload { error = nil }
  }
  public func apply() {
    guard canApply, let target, let submitted = draft, let generation else { return }
    do {
      // Detect an observed competing edit. This is not a core compare-and-swap;
      // the app admits only one encoding editor per connection at a time.
      guard try Self.readValues(target.readEncoding()) == baselineValues else {
        needsReload = true; error = .changed; return
      }
    } catch { needsReload = true; self.error = .unavailable; return }
    let submittedValues = values
    isBusy = true; error = nil; didApply = false
    operation = Task { @MainActor [weak self] in
      do {
        try Task.checkCancellation()
        try await target.submitEncoding(submitted, generation: generation)
        guard let self, !self.stopped else { self?.finish(); return }
        guard target.encodingEditable, target.encodingGeneration == generation,
              try Self.readValues(target.readEncoding()) == submittedValues else { throw NativeEncodingDraftError.changed }
        self.baseline = submitted; self.baselineValues = submittedValues
        self.needsReload = false; self.didApply = true
      } catch {
        if let self, !self.stopped {
          self.needsReload = true
          self.error = error is CancellationError ? .cancelled : (error as? NativeEncodingDraftError) ?? .applyFailed
        }
      }
      self?.finish()
    }
  }
  private func finish() { isBusy = false; operation = nil }
  public func cancelApply() { operation?.cancel() }
  public func stop() {
    guard !stopped else { return }
    stopped = true; isAvailable = false; observations.removeAll(); operation?.cancel()
  }
  public func close() async { stop(); await operation?.value }
}
