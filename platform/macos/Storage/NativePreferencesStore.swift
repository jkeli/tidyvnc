// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import CoreFoundation

// A typed patch, not a second source of compiled defaults. nil inherits the
// configuration default. Extend alongside the shared schema/bridge as settings
// become available; no arbitrary keys, credentials, endpoints or runtime state.
public struct NativePreferences: Codable, Equatable, Sendable {
  public var clipboardSend: Bool?, clipboardReceive: Bool?
  public var shared: Bool?, reconnectOnError: Bool?
  public var fullscreen: NativeFullscreenPreferences?
  public var remoteResize: NativeRemoteResizePreferences?
  public var security: NativeSecurityPreferences?
  public var trustFiles: NativeTrustFiles?
  public var scaling: NativeScalingPreferences?
  public var input: NativeInputPreferences?
  public var encoding: NativeEncodingPreferences?
  public init(clipboardSend: Bool? = nil, clipboardReceive: Bool? = nil, encoding: NativeEncodingPreferences? = nil, input: NativeInputPreferences? = nil, scaling: NativeScalingPreferences? = nil, trustFiles: NativeTrustFiles? = nil, security: NativeSecurityPreferences? = nil, shared: Bool? = nil, reconnectOnError: Bool? = nil, remoteResize: NativeRemoteResizePreferences? = nil, fullscreen: NativeFullscreenPreferences? = nil) {
    self.fullscreen = fullscreen
    self.remoteResize = remoteResize
    self.shared = shared; self.reconnectOnError = reconnectOnError
    self.clipboardSend = clipboardSend; self.clipboardReceive = clipboardReceive
    self.encoding = encoding; self.input = input; self.scaling = scaling; self.trustFiles = trustFiles; self.security = security
  }
  public func applying(to configuration: NativeSessionConfiguration) throws -> NativeSessionConfiguration {
    var result = configuration
    if let shared { result.shared = shared; result.sharedSource = .appDefaults }
    if let reconnectOnError { result.reconnectOnError = reconnectOnError; result.reconnectSource = .appDefaults }
    if let clipboardSend { result.clipboardSend = clipboardSend }
    if let clipboardReceive { result.clipboardReceive = clipboardReceive }
    if let encoding { result.encoding = try encoding.resolved(base: configuration.encoding) }
    if let input { result = try input.applying(to: result, source: .appDefaults) }
    if let scaling { result = try scaling.applying(to: result, source: .appDefaults) }
    if let fullscreen { result = try fullscreen.applying(to:result,source:.appDefaults) }
    if let remoteResize { result = try remoteResize.applying(to:result,source:.appDefaults) }
    if let security { result = try security.applying(to: result,source: .appDefaults) }
    if let trustFiles { result = try trustFiles.applying(to: result) }
    return result
  }
}
public struct NativePreferencesRevision: Equatable, Sendable {
  // nil represents an absent record. Each accepted commit, including reset,
  // gets a fresh identity, so resetting cannot make an old revision current.
  public let value: UUID?
}
public struct NativePreferencesSnapshot: Equatable, Sendable {
  public let revision: NativePreferencesRevision
  public let values: NativePreferences
  public let importedFrom: NativeImportOrigin?
  public init(revision: NativePreferencesRevision, values: NativePreferences, importedFrom: NativeImportOrigin? = nil) {
    self.revision = revision; self.values = values; self.importedFrom = importedFrom
  }
  public var isStored: Bool { revision.value != nil }
}
public enum NativePreferencesError: Error, Equatable, Sendable {
  case corrupt, futureSchema, unsupportedFields, tooLarge, invalidValue, invalidTLSPriority, unsupportedValue
  case conflict, unavailable, denied, ioFailure, cancelled, closed, resourceLimit
}

// Calls are synchronous within the owning actor: cancellation is checked before
// admission, never reported as rollback after the backend has accepted a write.
// A throwing write may still have effects: callers reread before retrying it.
public protocol NativePreferencesBacking: Sendable {
  func read() throws -> Data?
  func write(_ data: Data) throws
}
public final class UserDefaultsPreferencesBacking: NativePreferencesBacking, @unchecked Sendable {
  public static let applicationDomain = "io.github.jkeli.tidyvnc.native.preferences"
  static let recordKey = "preferences"
  private let defaults: UserDefaults
  private let domain: String
  // UserDefaults is thread-safe; these properties are immutable. The app must
  // own one store actor per domain. This adapter does not add cross-process CAS.
  public init(domain: String = applicationDomain) throws {
    guard !domain.isEmpty, domain.utf8.count <= 255, !domain.utf8.contains(0),
          let defaults = UserDefaults(suiteName: domain) else { throw NativePreferencesError.unavailable }
    self.domain = domain; self.defaults = defaults
  }
  public func read() throws -> Data? {
    // Read exactly this persistent domain, not argument/global/registration
    // fallbacks. In particular, malformed native state never imports XDG state.
    guard let value = defaults.persistentDomain(forName: domain)?[Self.recordKey] else { return nil }
    guard let data = value as? Data else { throw NativePreferencesError.corrupt }
    return data
  }
  public func write(_ data: Data) throws {
    defaults.set(data, forKey: Self.recordKey)
    // Only acknowledges acceptance into UserDefaults, whose persistence is
    // asynchronous. No fsync, crash durability or filesystem error claim.
    guard try read() == data else { throw NativePreferencesError.ioFailure }
  }
}

public actor NativePreferencesStore {
  private struct Record: Codable {
    let schema: UInt32
    let revision: UUID
    let values: NativePreferences
    let importedFrom: NativeImportOrigin?
  }
  private let backing: any NativePreferencesBacking
  private var observers: [UUID: AsyncStream<NativePreferencesSnapshot>.Continuation] = [:]
  private var lastPublished: NativePreferencesSnapshot?
  private var closed = false
  public init(backing: any NativePreferencesBacking) { self.backing = backing }
  deinit { for observer in observers.values { observer.finish() } }
  private func checkAdmission() throws {
    guard !closed else { throw NativePreferencesError.closed }
    guard !Task.isCancelled else { throw NativePreferencesError.cancelled }
  }
  private func load() throws -> NativePreferencesSnapshot {
    let bytes: Data?
    do { bytes = try backing.read() }
    catch let error as NativePreferencesError { throw error }
    catch { throw NativePreferencesError.ioFailure }
    do {
      guard let data = bytes else {
        return NativePreferencesSnapshot(revision: NativePreferencesRevision(value: nil), values: NativePreferences())
      }
      guard data.count <= 64 * 1024 else { throw NativePreferencesError.tooLarge }
      // Codable ignores unknown keys by default. Inspect the complete envelope
      // before decoding so newer data is never silently dropped on the next save.
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schema = object["schema"] as? NSNumber,
            CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue >= 1,
            schema.doubleValue.rounded(.towardZero) == schema.doubleValue
      else { throw NativePreferencesError.corrupt }
      guard schema.doubleValue <= 11 else { throw NativePreferencesError.futureSchema }
      let envelopeFields: Set<String> = schema.intValue >= 11 ? ["schema","revision","values","importedFrom"] : ["schema","revision","values"]
      guard Set(object.keys).isSubset(of:envelopeFields) else { throw NativePreferencesError.unsupportedFields }
      if let marker = object["importedFrom"] {
        guard let token = marker as? String else { throw NativePreferencesError.corrupt }
        guard NativeImportOrigin(rawValue:token) != nil else { throw NativePreferencesError.unsupportedValue }
      }
      guard Set(["schema", "revision", "values"]).isSubset(of:Set(object.keys)),
            let values = object["values"] as? [String: Any] else { throw NativePreferencesError.corrupt }
      var fields: Set<String> = ["clipboardSend", "clipboardReceive"]
      if schema.intValue >= 2 { fields.insert("encoding") }
      if schema.intValue >= 3 { fields.insert("input") }
      if schema.intValue >= 4 { fields.insert("scaling") }
      if schema.intValue >= 5 { fields.insert("trustFiles") }
      if schema.intValue >= 6 { fields.insert("security") }
      if schema.intValue >= 10 { fields.insert("fullscreen") }
      if schema.intValue >= 9 { fields.insert("remoteResize") }
      if schema.intValue >= 8 { fields.formUnion(["shared","reconnectOnError"]) }
      guard Set(values.keys).isSubset(of: fields)
      else { throw NativePreferencesError.unsupportedFields }
      // A present setting must be a Boolean, not null or a numeric coercion.
      guard values.filter({ $0.key != "fullscreen" && $0.key != "remoteResize" && $0.key != "encoding" && $0.key != "input" && $0.key != "scaling" && $0.key != "trustFiles" && $0.key != "security" }).values.allSatisfy({ value in
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
      }) else { throw NativePreferencesError.corrupt }
      if let encoded = values["encoding"] {
        guard let fields = encoded as? [String: Any] else { throw NativePreferencesError.corrupt }
        guard Set(fields.keys).isSubset(of: NativeEncodingPreferences.fieldNames) else { throw NativePreferencesError.unsupportedFields }
        guard !fields.values.contains(where: { $0 is NSNull }) else { throw NativePreferencesError.corrupt }
      }
      if let input = values["input"] { try NativeInputPreferences.validateObject(input) }
      if let fullscreen = values["fullscreen"] { try NativeFullscreenPreferences.validateObject(fullscreen) }
      if let resize = values["remoteResize"] { try NativeRemoteResizePreferences.validateObject(resize) }
      if let scaling = values["scaling"] { try NativeScalingPreferences.validateObject(scaling) }
      if let security = values["security"] { try NativeSecurityPreferences.validateObject(security, priorityAllowed: schema.intValue >= 7) }
      if let trustFiles = values["trustFiles"] { try NativeTrustFiles.validateObject(trustFiles) }
      let record = try JSONDecoder().decode(Record.self, from: data)
      try validate(record.values)
      return NativePreferencesSnapshot(revision: NativePreferencesRevision(value: record.revision), values: record.values, importedFrom: record.importedFrom)
    } catch let error as NativePreferencesError { throw error }
    catch { throw NativePreferencesError.corrupt }
  }
  private func validate(_ values: NativePreferences) throws {
    _ = try values.fullscreen?.resolved()
    _ = try values.remoteResize?.resolved()
    try values.security?.validate()
    try values.trustFiles?.validate()
    _ = try values.scaling?.resolved()
    _ = try values.input?.resolved()
    do { if let encoding = values.encoding { _ = try encoding.resolved() } }
    catch let error as NativeError {
      if error.status == .unsupported { throw NativePreferencesError.unsupportedValue }
      if error.status == .invalidArgument || error.status == .resourceLimit { throw NativePreferencesError.invalidValue }
      throw NativePreferencesError.unavailable
    }
  }
  private func publish(_ snapshot: NativePreferencesSnapshot) {
    guard snapshot != lastPublished else { return }; lastPublished = snapshot
    for observer in observers.values { observer.yield(snapshot) }
  }
  public func read() throws -> NativePreferencesSnapshot {
    try checkAdmission(); let snapshot = try load(); publish(snapshot); return snapshot
  }
  public func commit(_ values: NativePreferences, expected: NativePreferencesRevision) throws -> NativePreferencesSnapshot {
    try checkAdmission()
    // This fresh read detects observed external edits too, but UserDefaults
    // cannot atomically compare+replace against another process's concurrent write.
    let current = try load()
    guard current.revision == expected else { publish(current); throw NativePreferencesError.conflict }
    return try save(values, importedFrom:current.importedFrom)
  }
  // Import only into an absent native record. Even an explicit reset is stored
  // native state and prevents reimport; errors are never interpreted as absence.
  public func importDefaults(_ proposal: NativeDefaultsImport, acknowledging lines: Set<UInt32>) throws -> NativePreferencesSnapshot {
    try checkAdmission()
    let current = try load()
    guard !current.isStored else { publish(current); throw NativePreferencesError.conflict }
    return try save(proposal.preferences(acknowledging:lines),importedFrom:proposal.origin)
  }
  private func save(_ values: NativePreferences, importedFrom: NativeImportOrigin?) throws -> NativePreferencesSnapshot {
    var values = values
    values.fullscreen = try values.fullscreen?.canonicalized()
    values.remoteResize = try values.remoteResize?.canonicalized()
    values.scaling = try values.scaling?.canonicalized()
    values.security = try values.security?.canonicalized()
    try validate(values)
    let record = Record(schema: 11, revision: UUID(), values: values, importedFrom:importedFrom)
    let data: Data
    do { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; data = try encoder.encode(record) }
    catch { throw NativePreferencesError.corrupt }
    try checkAdmission()
    do { try backing.write(data) }
    catch let error as NativePreferencesError { throw error }
    catch { throw NativePreferencesError.ioFailure }
    let snapshot = NativePreferencesSnapshot(revision: NativePreferencesRevision(value: record.revision), values: values, importedFrom:importedFrom)
    publish(snapshot); return snapshot
  }
  public func reset(expected: NativePreferencesRevision) throws -> NativePreferencesSnapshot {
    try commit(NativePreferences(), expected: expected)
  }
  // Notifications reflect successful writes and fresh reads through this actor.
  // One latest value per subscriber, at most 64 subscribers. Call read on opening
  // Settings/app activation to refresh external state; no cross-process observer
  // or implicit fallback import is promised by this subscription.
  public func changes() throws -> AsyncStream<NativePreferencesSnapshot> {
    try checkAdmission()
    guard observers.count < 64 else { throw NativePreferencesError.resourceLimit }
    let snapshot = try load(), id = UUID()
    publish(snapshot) // A newly observed external edit also updates existing observers.
    let pair = AsyncStream<NativePreferencesSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    observers[id] = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    pair.continuation.yield(snapshot)
    return pair.stream
  }
  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
  public func close() {
    guard !closed else { return }; closed = true
    let pending = observers; observers.removeAll()
    for observer in pending.values { observer.finish() }
  }
}
