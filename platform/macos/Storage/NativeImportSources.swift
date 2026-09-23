// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

// Snapshot only storage-path variables. Copying the whole process environment
// would also materialize launch passwords as immutable Foundation strings.
public enum NativePathEnvironment {
  // One named variable, bounded and UTF-8, without touching the rest of the
  // environment (which may hold launch credentials).
  public static func value(_ key: String, maximumBytes: Int) -> String? {
    guard let pointer = getenv(key) else { return nil }
    let count = strnlen(pointer, maximumBytes + 1)
    guard count <= maximumBytes else { return nil }
    return String(bytes:UnsafeBufferPointer(start:UnsafeRawPointer(pointer).assumingMemoryBound(to:UInt8.self),count:count),encoding:.utf8)
  }
  public static func capture() -> [String:String] {
    var result: [String:String] = [:]
    for key in ["HOME","XDG_CONFIG_HOME","XDG_DATA_HOME","XDG_STATE_HOME"] {
      guard let pointer = getenv(key) else { continue }
      let count = strnlen(pointer,65537)
      guard count <= 65536,
            let value = String(bytes:UnsafeBufferPointer(start:UnsafeRawPointer(pointer).assumingMemoryBound(to:UInt8.self),count:count),encoding:.utf8) else { continue }
      result[key] = value
    }
    return result
  }
}

public enum NativeImportSourceError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidPath, inaccessible, currentSourceExists, nativeStateExists, invalidDisplayMapping, topologyChanged
  public var description: String {
    switch self {
    case .invalidPath: String(localized:"import.source.the.import.location.is.invalid.check.the.home.and.xdg.paths", defaultValue:"The import location is invalid. Check the home and XDG paths.")
    case .inaccessible: String(localized:"import.source.the.import.source.could.not.be.inspected.check.its.location.and.access", defaultValue:"The import source could not be inspected. Check its location and access.")
    case .currentSourceExists: String(localized:"import.defaults.tidyvnc.settings.already.exist.review.those.settings.instead.of.importing.legacy.settings", defaultValue:"TidyVNC settings already exist. Review those settings instead of importing legacy settings.")
    case .nativeStateExists: String(localized:"import.defaults.native.settings.already.exist.and.cannot.be.replaced.by.an.import", defaultValue:"Native settings already exist and cannot be replaced by an import.")
    case .invalidDisplayMapping: String(localized:"import.defaults.the.monitor.selection.cannot.be.mapped.refresh.displays.and.review.the.import", defaultValue:"The monitor selection cannot be mapped. Refresh displays and review the import again.")
    case .topologyChanged: String(localized:"import.defaults.the.display.arrangement.changed.reload.the.import.and.review.its.monitor.selection", defaultValue:"The display arrangement changed. Reload the import and review its monitor selection.")
    }
  }
}

// Pure path construction: no reads, directory creation or implicit legacy fallback.
// Callers supply the launch environment and home explicitly, including in tests.
public struct NativeImportPaths: Sendable {
  public let currentDefaults: URL
  public let legacyDefaults: [URL]
  public let currentHistory: URL
  public let legacyHistory: [URL]
  public init(homeDirectory: String, environment: [String:String]) throws {
    func valid(_ path: String) -> Bool {
      path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 4096
    }
    guard valid(homeDirectory) else { throw NativeImportSourceError.invalidPath }
    func join(_ root: String, _ suffix: String) throws -> URL {
      let path = root + (root.hasSuffix("/") ? "" : "/") + suffix
      guard valid(path) else { throw NativeImportSourceError.invalidPath }
      // Do not standardize dot/parent components across possible symlinks.
      return URL(fileURLWithPath:path,isDirectory:false)
    }
    func base(_ key: String, _ fallback: String) throws -> String {
      if let value = environment[key], value.hasPrefix("/") {
        guard valid(value) else { throw NativeImportSourceError.invalidPath }
        return value
      }
      return try join(homeDirectory,fallback).path
    }
    let config = try base("XDG_CONFIG_HOME",".config")
    let state = try base("XDG_STATE_HOME",".local/state")
    currentDefaults = try join(config,"tidyvnc/default.tidyvnc")
    legacyDefaults = try [join(config,"tigervnc/default.tigervnc"),join(homeDirectory,".vnc/default.tigervnc")]
    currentHistory = try join(state,"tidyvnc/tidyvnc.history")
    legacyHistory = try [join(state,"tigervnc/tigervnc.history"),join(homeDirectory,".vnc/tigervnc.history")]
  }
}

public struct NativeDefaultsImportReview: Identifiable, Sendable {
  public var id: UUID { proposal.id }
  public let source: URL
  public let proposal: NativeDefaultsImport
  public let legacyDisplays: [NativeDisplayID]
  public var monitorNumbers: [Int] { projection?.monitorNumbers ?? [] }
  public let monitorMapping: [Int:NativeDisplayID]?
  public let availableDisplays: [NativeDisplayID]
  let projection: NativeDefaultsImportProjection?
  init(source: URL, proposal: NativeDefaultsImport, legacyDisplays: [NativeDisplayID],
       projection: NativeDefaultsImportProjection? = nil, monitorMapping: [Int:NativeDisplayID]? = nil,
       availableDisplays: [NativeDisplayID] = []) {
    self.source = source; self.proposal = proposal; self.legacyDisplays = legacyDisplays
    self.projection = projection; self.monitorMapping = monitorMapping; self.availableDisplays = availableDisplays
  }
}

public protocol NativeDefaultsImportServing: Sendable {
  func prepare(origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID]) async throws -> NativeDefaultsImportReview?
  func prepareWithMapping(origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID],
                          availableDisplays: [NativeDisplayID]) async throws -> NativeDefaultsImportPreparation?
  func commit(_ review: NativeDefaultsImportReview, acknowledging lines: Set<UInt32>,
              currentDisplays: [NativeDisplayID]) async throws -> NativePreferencesSnapshot
}

extension NativeDefaultsImportServing {
  public func prepareWithMapping(origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID],
                                 availableDisplays: [NativeDisplayID]) async throws -> NativeDefaultsImportPreparation? {
    try await prepare(origin:origin,legacyDisplays:legacyDisplays).map(NativeDefaultsImportPreparation.review)
  }
}

enum NativeImportSourceInspection {
  // Inspect components so a dangling parent symlink is an error, not absence
  // that could silently select a lower-priority source. A source symlink itself
  // counts as present; the bounded reader decides whether its target is usable.
  static func exists(_ url: URL) throws -> Bool {
    let parts = url.path.split(separator:"/",omittingEmptySubsequences:true)
    var path = ""
    for (index, part) in parts.enumerated() {
      try Task.checkCancellation()
      path += "/" + part
      var info = stat()
      if lstat(path,&info) != 0 {
        if errno == ENOENT { return false }
        throw NativeImportSourceError.inaccessible
      }
      if index != parts.count-1 {
        if info.st_mode & S_IFMT == S_IFLNK {
          guard stat(path,&info) == 0 else { throw NativeImportSourceError.inaccessible }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw NativeImportSourceError.inaccessible }
      }
    }
    return true
  }
}

// All source IO and projection run off the main actor. Native state is checked
// before inspecting any compatibility source and again by the committing store.
public actor NativeDefaultsImportService: NativeDefaultsImportServing {
  private let paths: NativeImportPaths
  private let store: NativePreferencesStore
  private let reader: any NativeDocumentReading
  public init(paths: NativeImportPaths, store: NativePreferencesStore,
              reader: any NativeDocumentReading = NativeDocumentFileReader()) {
    self.paths = paths; self.store = store; self.reader = reader
  }
  public func prepare(origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID]) async throws -> NativeDefaultsImportReview? {
    guard let (url,bytes) = try await readSource(origin:origin) else { return nil }
    let projection = try NativeDefaultsImportProjection(data:bytes,origin:origin)
    let proposal = try NativeDefaultsImport(projection:projection,legacyDisplays:legacyDisplays)
    if proposal.notices.contains(where: { $0.kind == .displayMapping }) {
      do { try NativeFullscreenPolicy.validateIDs(legacyDisplays) }
      catch { throw NativeImportSourceError.invalidDisplayMapping }
    }
    try Task.checkCancellation()
    return NativeDefaultsImportReview(source:url,proposal:proposal,legacyDisplays:legacyDisplays,projection:projection)
  }
  public func prepareWithMapping(origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID],
                                 availableDisplays: [NativeDisplayID]) async throws -> NativeDefaultsImportPreparation? {
    guard let (url,bytes) = try await readSource(origin:origin) else { return nil }
    let projection = try NativeDefaultsImportProjection(data:bytes,origin:origin)
    do {
      let proposal = try NativeDefaultsImport(projection:projection,legacyDisplays:legacyDisplays)
      if proposal.notices.contains(where:{ $0.kind == .displayMapping }) {
        do { try NativeFullscreenPolicy.validateIDs(legacyDisplays) }
        catch { throw NativeImportSourceError.invalidDisplayMapping }
      }
      try Task.checkCancellation()
      return .review(NativeDefaultsImportReview(source:url,proposal:proposal,legacyDisplays:legacyDisplays,projection:projection))
    } catch let failure as NativeDocumentResolutionFailure where failure.reason == .displayMappingRequired {
      let mapping = try NativeDefaultsImportMapping(source:url,projection:projection,legacyDisplays:legacyDisplays,availableDisplays:availableDisplays)
      try Task.checkCancellation()
      return .mapping(mapping)
    }
  }
  private func readSource(origin: NativeImportOrigin) async throws -> (URL,Data)? {
    try Task.checkCancellation()
    let native = try await store.read()
    guard !native.isStored else { throw NativeImportSourceError.nativeStateExists }
    try Task.checkCancellation()
    let candidates: [URL]
    switch origin {
    case .currentXDG: candidates = [paths.currentDefaults]
    case .legacy:
      guard try !NativeImportSourceInspection.exists(paths.currentDefaults) else { throw NativeImportSourceError.currentSourceExists }
      candidates = paths.legacyDefaults
    }
    for url in candidates {
      guard try NativeImportSourceInspection.exists(url) else { continue }
      let bytes = try await reader.read(url)
      try Task.checkCancellation()
      return (url,bytes)
    }
    return nil
  }
  public func commit(_ review: NativeDefaultsImportReview, acknowledging lines: Set<UInt32>,
                     currentDisplays: [NativeDisplayID]) async throws -> NativePreferencesSnapshot {
    try Task.checkCancellation()
    if review.proposal.notices.contains(where: { $0.kind == .displayMapping }) {
      let matches = review.monitorMapping == nil ? review.legacyDisplays == currentDisplays :
        Set(review.availableDisplays) == Set(currentDisplays)
      guard matches else { throw NativeImportSourceError.topologyChanged }
    }
    // Import the reviewed snapshot, not a second read of a possibly changed file.
    return try await store.importDefaults(review.proposal,acknowledging:lines)
  }
}
