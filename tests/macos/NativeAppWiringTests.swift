// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// Builds the real AppCoordinator with memory stores and observable fakes, then
// checks the production wiring it performs for each new connection window.
import AppKit
import Foundation
@testable import TidyVNCNative

struct Failure: Error, CustomStringConvertible { let description: String }
func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
@MainActor func waitFor(_ message: String, _ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<1500 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
  try check(condition(), "timed out: " + message)
}

final class MemoryPreferences: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock(); private var bytes: Data?; private var count = 0
  var reads: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { count += 1; return bytes } }
  func write(_ data: Data) throws { lock.withLock { bytes = data } }
}
final class MemoryFile: NativeAtomicFileBacking, @unchecked Sendable {
  private let lock = NSLock(); private var bytes: Data?; private var count = 0
  var reads: Int { lock.withLock { count } }
  func read() throws -> Data? { lock.withLock { count += 1; return bytes } }
  func replace(_ data: Data, expected: Data?) throws {
    try lock.withLock { guard bytes == expected else { throw NativeStorageError.conflict }; bytes = data }
  }
}
final class EmptyVault: NativeCredentialBacking, @unchecked Sendable {
  func lookup(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialSecret { throw NativeCredentialStoreIssue.notFound }
  func save(_ key: NativeCredentialKey, secret: NativeCredentialSecret, mode: NativeCredentialSaveMode, interaction: NativeCredentialInteraction) throws {
    throw NativeCredentialStoreIssue.unavailable
  }
  func delete(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws { throw NativeCredentialStoreIssue.notFound }
  func metadata(_ key: NativeCredentialKey, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadata { throw NativeCredentialStoreIssue.notFound }
  func listMetadata(limit: Int, interaction: NativeCredentialInteraction) throws -> NativeCredentialMetadataPage { NativeCredentialMetadataPage(entries: [], hasMore: false) }
}
@MainActor final class RecordingPasteboard: NativePasteboardAccess {
  var change = 1, localWrites: [String] = []
  func currentChange() -> Int { change }
  func read(expectedChange: Int, maximumBytes: Int) throws -> NativePasteboardContent { .unavailable }
  func writeRemote(_ text: String, maximumBytes: Int) throws -> Int { change += 1; return change }
  func writeLocal(_ text: String, maximumBytes: Int) throws -> Int { localWrites.append(text); change += 1; return change }
}
@MainActor final class NoDisplays: NativeDisplaySource { func read() throws -> [NativeDisplay] { [] } }
@MainActor final class CountingBell: NativeBellSounding { var rings = 0; func ring() { rings += 1 } }

@MainActor func productionWiringReachesEachSession() async throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-wiring-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  let preferences = MemoryPreferences(), profiles = MemoryFile()
  let pasteboard = RecordingPasteboard(), bell = CountingBell()
  let services = AppServices(
    clipboard: NativeClipboardCoordinator(pasteboard: pasteboard, automaticPolling: false),
    bell: bell,
    displays: NativeDisplayService(source: NoDisplays(), notifications: NotificationCenter(), workspaceNotifications: NotificationCenter()),
    credentials: NativeCredentialStore(backing: EmptyVault()),
    legacyTrust: nil,
    savedTrust: NativeTrustStore(backing: MemoryFile()),
    savedHostKeys: NativeTrustStore(kind: .hostKey, backing: MemoryFile()),
    profiles: NativeProfileHistoryStore(backing: profiles),
    environment: ["HOME": home.path],
    makeRuntime: { try NativeRuntime() },
    makePreferencesBacking: { preferences })
  let coordinator = AppCoordinator(services: services)
  try check(coordinator.settings != nil && coordinator.profileLibrary != nil, "injected preferences back Settings and profiles")
  let model = coordinator.makeConnection()
  try await waitFor("the connection window receives its session") { model.session != nil }
  try check(preferences.reads > 0 && profiles.reads > 0, "the coordinator reads the injected preference and history stores")
  guard let session = model.session else { return }
  try check(session.bellHandler != nil, "every session gets the app bell")
  session.bellHandler?()
  try check(bell.rings == 1, "the session bell reaches the injected bell service")
  guard let copy = model.copyText else { throw Failure(description: "connection model has no copy action") }
  try await copy("redacted diagnostics")
  try check(pasteboard.localWrites == ["redacted diagnostics"], "app copies go through the coordinator's pasteboard contract")
  let second = coordinator.makeConnection()
  try await waitFor("a second window receives its own session") { second.session != nil }
  try check(second.session !== session && second.session?.bellHandler != nil && second.copyText != nil,
    "each connection window is wired independently")
  await model.close(); await second.close()
}

@main struct NativeAppWiringTests {
  @MainActor static func main() async {
    do {
      try await productionWiringReachesEachSession()
      print("PASS app coordinator injects stores, bell and pasteboard into every connection window")
    } catch {
      FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1)
    }
  }
}
