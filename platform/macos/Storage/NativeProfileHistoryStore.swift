// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreFoundation
import Foundation

public struct NativeConnectionProfile: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var name: String, endpoint: String
  public var settings: NativePreferences
  public var credentialReference: UUID? // Opaque identifier only; never secret bytes.
  public init(id: UUID = UUID(), name: String, endpoint: String, settings: NativePreferences = .init(), credentialReference: UUID? = nil) {
    self.id = id; self.name = name; self.endpoint = endpoint
    self.settings = settings; self.credentialReference = credentialReference
  }
  public func applying(to configuration: NativeSessionConfiguration) throws -> NativeSessionConfiguration {
    var value = configuration
    if let shared = settings.shared { value.shared = shared; value.sharedSource = .profile }
    if let retry = settings.reconnectOnError { value.reconnectOnError = retry; value.reconnectSource = .profile }
    if let send = settings.clipboardSend { value.clipboardSend = send }
    if let receive = settings.clipboardReceive { value.clipboardReceive = receive }
    if let encoding = settings.encoding { value.encoding = try encoding.resolved(base: configuration.encoding, source: .profile) }
    if let input = settings.input { value = try input.applying(to: value, source: .profile) }
    if let fullscreen = settings.fullscreen { value = try fullscreen.applying(to:value,source:.profile) }
    if let resize = settings.remoteResize { value = try resize.applying(to:value,source:.profile) }
    if let scaling = settings.scaling { value = try scaling.applying(to: value, source: .profile) }
    if let security = settings.security { value = try security.applying(to: value,source: .profile) }
    if let trustFiles = settings.trustFiles { value = try trustFiles.applying(to: value) }
    return value
  }
}
// Describes history's first initialization, not the latest writer. Import
// markers survive later recordings/clears; profile edits do not initialize it.
public enum NativeHistoryState: String, Codable, Sendable {
  case uninitialized, native, currentXDG, legacy
}
public struct NativeProfileHistorySnapshot: Equatable, Sendable {
  public let revision: UUID?
  public let profiles: [NativeConnectionProfile]
  // Most recent first; exact address text is retained, not DNS-normalized.
  public let recentEndpoints: [String]
  public let historyState: NativeHistoryState
  public var canImportHistory: Bool { historyState == .uninitialized && recentEndpoints.isEmpty }
  public var historyImportOrigin: NativeImportOrigin? {
    switch historyState { case .currentXDG: .currentXDG; case .legacy: .legacy; default: nil }
  }
}

public actor NativeProfileHistoryStore {
  public static let historyCapacity = 20 // Retained viewer's SERVER_HISTORY_SIZE.
  public static let profileCapacity = 256
  private struct Record: Codable {
    let schema: UInt32, revision: UUID
    var profiles: [NativeConnectionProfile], recentEndpoints: [String]
    let historyState: NativeHistoryState?
    // Historical schemas cannot distinguish profile-only storage from a clear.
    // Their existing history, even empty, always wins over a compatibility file.
    var snapshot: NativeProfileHistorySnapshot {
      .init(revision:revision,profiles:profiles,recentEndpoints:recentEndpoints,historyState:historyState ?? .native)
    }
  }
  private let backing: any NativeProfileHistoryBacking
  private var closed = false
  public init(backing: any NativeProfileHistoryBacking) { self.backing = backing }
  private func admission() throws {
    guard !closed else { throw NativeStorageError.closed }
    guard !Task.isCancelled else { throw NativeStorageError.cancelled }
  }
  private func keys(_ object: [String: Any], allowed: Set<String>, required: Set<String> = []) throws {
    guard Set(object.keys).isSubset(of: allowed) else { throw NativeStorageError.unsupportedFields }
    guard required.isSubset(of: Set(object.keys)), !object.values.contains(where: { $0 is NSNull }) else { throw NativeStorageError.corrupt }
  }
  private func validateSettingsObject(_ object: [String: Any], inputAllowed: Bool, scalingAllowed: Bool, trustFilesAllowed: Bool, securityAllowed: Bool, priorityAllowed: Bool, connectionAllowed: Bool, resizeAllowed: Bool, fullscreenAllowed: Bool) throws {
    var allowed: Set<String> = ["clipboardSend", "clipboardReceive", "encoding"]
    if inputAllowed { allowed.insert("input") }
    if scalingAllowed { allowed.insert("scaling") }
    if trustFilesAllowed { allowed.insert("trustFiles") }
    if securityAllowed { allowed.insert("security") }
    if fullscreenAllowed { allowed.insert("fullscreen") }
    if resizeAllowed { allowed.insert("remoteResize") }
    if connectionAllowed { allowed.formUnion(["shared","reconnectOnError"]) }
    try keys(object, allowed: allowed)
    for (key, value) in object where key != "fullscreen" && key != "remoteResize" && key != "encoding" && key != "input" && key != "scaling" && key != "trustFiles" && key != "security" {
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw NativeStorageError.corrupt }
    }
    if let value = object["encoding"] {
      guard let encoding = value as? [String: Any] else { throw NativeStorageError.corrupt }
      try keys(encoding, allowed: NativeEncodingPreferences.fieldNames)
    }
    if let security = object["security"] {
      do { try NativeSecurityPreferences.validateObject(security, priorityAllowed: priorityAllowed) }
      catch let error as NativePreferencesError { throw settingsError(error) }
    }
    if let trustFiles = object["trustFiles"] {
      do { try NativeTrustFiles.validateObject(trustFiles) }
      catch let error as NativePreferencesError { throw settingsError(error) }
    }
    if let fullscreen = object["fullscreen"] {
      do { try NativeFullscreenPreferences.validateObject(fullscreen) }
      catch let error as NativePreferencesError { throw error == .unsupportedFields ? NativeStorageError.unsupportedFields : NativeStorageError.corrupt }
    }
    if let resize = object["remoteResize"] {
      do { try NativeRemoteResizePreferences.validateObject(resize) }
      catch let error as NativePreferencesError { throw settingsError(error) }
    }
    if let scaling = object["scaling"] {
      do { try NativeScalingPreferences.validateObject(scaling) }
      catch let error as NativePreferencesError { throw settingsError(error) }
    }
    if let input = object["input"] {
      do { try NativeInputPreferences.validateObject(input) }
      catch let error as NativePreferencesError { throw settingsError(error) }
    }
  }
  private func settingsError(_ error: NativePreferencesError) -> NativeStorageError {
    switch error {
    case .unsupportedFields: .unsupportedFields
    case .invalidValue: .invalid
    case .invalidTLSPriority: .invalidTLSPriority
    case .unsupportedValue: .unsupportedValue
    default: .corrupt
    }
  }
  private func address(_ value: String) throws {
    // Storage admission limits, not a second endpoint parser. The connection
    // flow must validate protocol syntax using the shared parser before use.
    guard !value.isEmpty, !value.utf8.contains(0), value.utf8.prefix(4097).count <= 4096 else { throw NativeStorageError.invalid }
  }
  private func validate(_ profiles: [NativeConnectionProfile], _ history: [String]) throws {
    guard profiles.count <= Self.profileCapacity, history.count <= Self.historyCapacity else { throw NativeStorageError.resourceLimit }
    guard Set(profiles.map(\.id)).count == profiles.count, Set(history).count == history.count else { throw NativeStorageError.corrupt }
    for profile in profiles {
      guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !profile.name.utf8.contains(0), profile.name.utf8.prefix(257).count <= 256 else { throw NativeStorageError.invalid }
      try address(profile.endpoint)
      do { try profile.settings.fullscreen?.validate(); _ = try profile.settings.remoteResize?.resolved(); try profile.settings.security?.validate(); try profile.settings.trustFiles?.validate(); _ = try profile.settings.input?.resolved(); _ = try profile.settings.scaling?.resolved() }
      catch let error as NativePreferencesError { throw settingsError(error) }
      do { _ = try profile.settings.encoding?.resolved(source: .profile) }
      catch let error as NativeError {
        switch error.status {
        case .unsupported: throw NativeStorageError.unsupportedValue
        case .invalidArgument, .resourceLimit: throw NativeStorageError.invalid
        default: throw NativeStorageError.unavailable
        }
      }
    }
    for endpoint in history { try address(endpoint) }
  }
  private func load() throws -> (NativeProfileHistorySnapshot, Data?) {
    guard let bytes = try backing.read() else {
      return (.init(revision:nil,profiles:[],recentEndpoints:[],historyState:.uninitialized),nil)
    }
    guard bytes.count <= NativePrivateFile.maximumBytes else { throw NativeStorageError.tooLarge }
    do {
      guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
            schema.doubleValue >= 1, schema.doubleValue.rounded(.towardZero) == schema.doubleValue else { throw NativeStorageError.corrupt }
      guard schema.doubleValue <= 10 else { throw NativeStorageError.futureSchema }
      var fields: Set<String> = ["schema", "revision", "profiles", "recentEndpoints"]
      if schema.intValue >= 10 { fields.insert("historyState") }
      try keys(object, allowed: fields, required: fields)
      if schema.intValue >= 10 {
        guard let value = object["historyState"] as? String else { throw NativeStorageError.corrupt }
        guard NativeHistoryState(rawValue:value) != nil else { throw NativeStorageError.unsupportedValue }
      }
      guard let profiles = object["profiles"] as? [[String: Any]], let history = object["recentEndpoints"] as? [String] else { throw NativeStorageError.corrupt }
      guard profiles.count <= Self.profileCapacity, history.count <= Self.historyCapacity else { throw NativeStorageError.resourceLimit }
      for profile in profiles {
        try keys(profile, allowed: ["id", "name", "endpoint", "settings", "credentialReference"], required: ["id", "name", "endpoint", "settings"])
        guard let settings = profile["settings"] as? [String: Any] else { throw NativeStorageError.corrupt }
        try validateSettingsObject(settings, inputAllowed: schema.intValue >= 2, scalingAllowed: schema.intValue >= 3, trustFilesAllowed: schema.intValue >= 4, securityAllowed: schema.intValue >= 5, priorityAllowed: schema.intValue >= 6, connectionAllowed: schema.intValue >= 7, resizeAllowed: schema.intValue >= 8, fullscreenAllowed: schema.intValue >= 9)
      }
      let record = try JSONDecoder().decode(Record.self, from: bytes)
      try validate(record.profiles, record.recentEndpoints)
      guard record.historyState != .uninitialized || record.recentEndpoints.isEmpty else { throw NativeStorageError.corrupt }
      return (record.snapshot, bytes)
    } catch let error as NativeStorageError { throw error }
    catch { throw NativeStorageError.corrupt }
  }
  public func read() throws -> NativeProfileHistorySnapshot { try admission(); return try load().0 }
  public func profile(id: UUID) throws -> NativeConnectionProfile {
    try admission()
    guard let profile = try load().0.profiles.first(where: { $0.id == id }) else { throw NativeStorageError.notFound }
    return profile
  }
  private func save(profiles: [NativeConnectionProfile], history: [String], state: NativeHistoryState, expected: Data?) throws -> NativeProfileHistorySnapshot {
    try validate(profiles,history)
    let record = Record(schema:10,revision:UUID(),profiles:profiles,recentEndpoints:history,historyState:state)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(record)
    guard encoded.count <= NativePrivateFile.maximumBytes else { throw NativeStorageError.tooLarge }
    try admission()
    try backing.replace(encoded,expected:expected)
    return record.snapshot
  }
  private func mutate(expected: UUID?, initializesHistory: Bool = false, _ change: (inout [NativeConnectionProfile], inout [String]) throws -> Void) throws -> NativeProfileHistorySnapshot {
    try admission()
    let (snapshot, bytes) = try load()
    guard snapshot.revision == expected else { throw NativeStorageError.conflict }
    var profiles = snapshot.profiles, history = snapshot.recentEndpoints
    try change(&profiles, &history)
    let state: NativeHistoryState = initializesHistory && snapshot.historyState == .uninitialized ? .native : snapshot.historyState
    return try save(profiles:profiles,history:history,state:state,expected:bytes)
  }
  public func upsert(_ profile: NativeConnectionProfile, expected: UUID?) throws -> NativeProfileHistorySnapshot {
    var profile = profile
    do { profile.settings.fullscreen = try profile.settings.fullscreen?.canonicalized(); profile.settings.remoteResize = try profile.settings.remoteResize?.canonicalized(); profile.settings.scaling = try profile.settings.scaling?.canonicalized(); profile.settings.security = try profile.settings.security?.canonicalized() }
    catch let error as NativePreferencesError { throw settingsError(error) }
    return try mutate(expected: expected) { profiles, _ in
      if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
      else { profiles.append(profile) }
    }
  }
  public func deleteProfile(id: UUID, expected: UUID?) throws -> NativeProfileHistorySnapshot {
    try mutate(expected: expected) { profiles, _ in
      guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw NativeStorageError.notFound }
      profiles.remove(at: index)
    }
  }
  public func recordRecent(_ endpoint: String, expected: UUID?) throws -> NativeProfileHistorySnapshot {
    try admission(); try address(endpoint)
    return try mutate(expected: expected, initializesHistory:true) { _, history in
      history.removeAll(where: { $0 == endpoint }); history.insert(endpoint, at: 0)
      history = Array(history.prefix(Self.historyCapacity))
    }
  }
  public func removeRecent(_ endpoint: String, expected: UUID?) throws -> NativeProfileHistorySnapshot {
    try mutate(expected: expected, initializesHistory:true) { _, history in
      guard history.contains(endpoint) else { throw NativeStorageError.notFound }
      history.removeAll(where: { $0 == endpoint })
    }
  }
  public func clearHistory(expected: UUID?) throws -> NativeProfileHistorySnapshot {
    try mutate(expected: expected, initializesHistory:true) { _, history in history.removeAll() }
  }
  public func importHistory(_ proposal: NativeHistoryImport, expected: UUID?, acknowledgingOmissions: Bool) throws -> NativeProfileHistorySnapshot {
    try admission()
    let (current, bytes) = try load()
    guard current.revision == expected, current.canImportHistory else { throw NativeStorageError.conflict }
    let history = try proposal.reviewedEndpoints(acknowledgingOmissions:acknowledgingOmissions)
    return try save(profiles:current.profiles,history:history,
                    state:proposal.origin == .currentXDG ? .currentXDG : .legacy,expected:bytes)
  }
  public func close() { closed = true }
}
