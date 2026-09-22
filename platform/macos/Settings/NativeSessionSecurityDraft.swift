// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

private actor SecurityPreflight {
  func validate(_ preferences: NativeSecurityPreferences, files: NativeTrustFiles) throws {
    try Task.checkCancellation(); try preferences.validate(); try files.validate(); try Task.checkCancellation()
  }
}
@MainActor public final class NativeSessionSecurityDraft: ObservableObject, Identifiable {
  public nonisolated let id = UUID()
  @Published public var preferences = NativeSecurityPreferences()
  @Published public var trustFiles = NativeTrustFiles()
  @Published public private(set) var baseline: NativeSessionSecurity?
  @Published public private(set) var choices: [NativeSecurityChoice] = []
  @Published public private(set) var isBusy = false
  @Published public private(set) var needsReload = false
  @Published public private(set) var error: String?
  @Published public private(set) var didApply = false
  public let inherited: NativeSecurityPreferences
  public let inheritedFiles: NativeTrustFiles
  private weak var session: NativeSession?
  private let preflight = SecurityPreflight()
  private let onApplied: @MainActor () -> Void
  private var operation: Task<Void,Never>?
  private var observations: [AnyCancellable] = []
  private var stopped = false
  public init(session: NativeSession, onApplied: @escaping @MainActor () -> Void = {}) throws {
    self.onApplied = onApplied
    let choices = try NativeSecuritySelection.choices()
    let names = try session.initialSecurityTypes.map { type in
      guard let name = choices.first(where: { $0.id == type })?.name else { throw NativeError(.unsupported,"Unknown security method") }
      return name
    }
    inherited = .init(types:try NativeSecuritySelection(names.joined(separator:",")).canonical,tlsPriority:session.initialTLSPriority)
    inheritedFiles = session.initialTrustFiles
    self.session = session; self.choices = choices
    observations = [session.$snapshot.sink { [weak self] snapshot in
      MainActor.assumeIsolated {
        guard let self, let baseline = self.baseline else { return }
        if snapshot.generation != baseline.generation || ![.idle,.closed,.failed].contains(snapshot.state) {
          self.needsReload = true; self.didApply = false
          self.error = String(localized:"settings.security.the.connection.changed.reload.security.settings.before.applying", defaultValue:"The connection changed. Reload security settings before applying.")
        }
      }
    },session.$isClosing.sink { [weak self] closing in
      if closing { MainActor.assumeIsolated { self?.stop() } }
    }]
  }
  deinit { operation?.cancel() }
  private var resolved: NativeSecurityPreferences {
    let types = preferences.types ?? inherited.types
    return .init(types:(try? NativeSecuritySelection(types).canonical) ?? types,
      tlsPriority:preferences.tlsPriority ?? inherited.tlsPriority)
  }
  private var resolvedFiles: NativeTrustFiles {
    .init(caFile:trustFiles.caFile ?? inheritedFiles.caFile,crlFile:trustFiles.crlFile ?? inheritedFiles.crlFile)
  }
  public var sourceDescription: String {
    guard let session, let baseline else { return "" }
    if baseline.revision > 1 { return String(localized:"settings.security.current.source.connection.override", defaultValue:"Current source: connection override") }
    func label(_ source: NativeOptionSource) -> String {
      switch source { case .compiled: String(localized:"settings.connection.built.in.default", defaultValue:"built-in default"); case .appDefaults: String(localized:"settings.connection.app.default", defaultValue:"app default"); case .profile: String(localized:"settings.connection.profile", defaultValue:"profile"); case .session: String(localized:"settings.connection.connection.override", defaultValue:"connection override"); case .document: String(localized:"settings.connection.connection.file", defaultValue:"connection file"); case .commandLine: String(localized:"settings.connection.command.line", defaultValue:"command line") }
    }
    return String(localized:"settings.security.sources", defaultValue:"Methods: \(label(session.initialSecuritySource)) · TLS priority: \(label(session.initialTLSPrioritySource))")
  }
  public var canReload: Bool { !stopped && !isBusy && session?.isClosing == false && session.map { [.idle,.closed,.failed].contains($0.snapshot.state) } == true }
  public var hasChanges: Bool { baseline.map { $0.preferences != resolved || $0.trustFiles != resolvedFiles } ?? false }
  public var canApply: Bool { canReload && !needsReload && hasChanges && resolved.isValid && resolvedFiles.isValid }
  public func reload() {
    guard canReload, let session else { return }
    do {
      let value = try session.securityConfiguration()
      guard value.editable else { throw NativeError(.busy,"Disconnect and wait for the connection to finish closing.") }
      baseline = value
      preferences = .init(types:value.preferences.types == inherited.types ? nil : value.preferences.types,
        tlsPriority:value.preferences.tlsPriority == inherited.tlsPriority ? nil : value.preferences.tlsPriority)
      trustFiles = .init(caFile:value.trustFiles.caFile == inheritedFiles.caFile ? nil : value.trustFiles.caFile,
        crlFile:value.trustFiles.crlFile == inheritedFiles.crlFile ? nil : value.trustFiles.crlFile)
      needsReload = false; error = nil; didApply = false
    } catch { self.error = String(localized:"settings.security.security.settings.are.unavailable.disconnect.then.reload", defaultValue:"Security settings are unavailable. Disconnect, then reload."); needsReload = true }
  }
  public func apply() {
    guard canApply, let baseline, let session else { return }
    let submitted = resolved, files = resolvedFiles, validator = preflight
    isBusy = true; error = nil; didApply = false
    operation = Task { @MainActor [weak self] in
      defer { self?.isBusy = false; self?.operation = nil }
      do {
        try await validator.validate(submitted,files:files)
        try Task.checkCancellation()
        guard let self, !self.stopped else { return }
        try session.setSecurity(submitted,trustFiles:files,expected:baseline)
        self.onApplied()
        self.baseline = try session.securityConfiguration()
        self.preferences = submitted; self.trustFiles = files
        self.needsReload = false; self.didApply = true
      } catch {
        if let self, !self.stopped {
          if let failure = error as? NativePreferencesError {
            self.error = failure == .invalidTLSPriority ? String(localized:"settings.security.the.tls.priority.expression.is.invalid.correct.it.or.use.the.library", defaultValue:"The TLS priority expression is invalid. Correct it or use the library default.") : String(localized:"settings.security.a.security.setting.is.invalid.or.unavailable.in.this.build", defaultValue:"A security setting is invalid or unavailable in this build.")
          } else if let failure = error as? NativeError, failure.status == .unsupported {
            self.error = String(localized:"settings.security.a.security.setting.is.unavailable.in.this.build.correct.it.before.applying", defaultValue:"A security setting is unavailable in this build. Correct it before applying.")
          } else if error is CancellationError { self.error = String(localized:"settings.security.applying.security.settings.was.cancelled", defaultValue:"Applying security settings was cancelled.") }
          else { self.needsReload = true; self.error = String(localized:"settings.security.the.connection.or.security.settings.changed.reload.before.applying", defaultValue:"The connection or security settings changed. Reload before applying.") }
        }
      }
    }
  }
  public func cancelEdits() {
    guard !isBusy, !stopped, let baseline else { return }
    preferences = baseline.preferences; trustFiles = baseline.trustFiles; didApply = false
    if !needsReload { error = nil }
  }
  public func cancelApply() { operation?.cancel() }
  public func stop() { stopped = true; observations.removeAll(); operation?.cancel() }
  public func close() async { stop(); await operation?.value }
}
