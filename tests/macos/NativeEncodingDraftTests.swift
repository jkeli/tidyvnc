// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message: message) }
}
@MainActor func until(_ label: String, _ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out: \(label)")
}
@MainActor func editsAndConflicts() async throws {
  let target = try EncodingTarget(), draft = NativeSessionEncodingDraft(target: target)
  draft.reload(); draft.setEncoding(.quality, value: "0x5")
  try check(draft.values[.quality]?.value == "5" && draft.values[.quality]?.source == .session && draft.canApply, "canonical session draft")
  try check(try target.options.value(for: .quality).value == "3" && target.calls == 0, "editing never submits")
  draft.cancelEdits()
  try check(!draft.hasChanges && draft.values[.quality]?.source == .appDefaults && target.calls == 0, "cancel restores source without submit")
  draft.setEncoding(.quality, value: "100")
  try check(draft.error == .invalidValue && !draft.needsReload && !draft.hasChanges, "invalid input preserves draft")
  draft.setEncoding(.quality, value: "5"); draft.apply()
  try await until("first apply") { !draft.isBusy }
  try check(draft.didApply && !draft.hasChanges && draft.error == nil, "confirmed apply updates baseline")
  try check(try target.options.value(for: .quality).source == .session && target.options.value(for: .compression).source == .compiled, "only edited fields become overrides")
  draft.setEncoding(.quality, value: "6")
  target.options = try target.options.applying([.init("QualityLevel", "7")], source: .session)
  draft.apply()
  try check(draft.needsReload && draft.error == .changed && target.calls == 1 && draft.values[.quality]?.value == "6", "observed competing edit preserves draft without overwrite")
  draft.cancelEdits(); try check(draft.needsReload && !draft.canApply, "cancel never clears conflict gate")
  draft.reload(); try check(!draft.needsReload && draft.values[.quality]?.value == "7", "reload resolves conflict")
  await draft.close()
  print("PASS isolated draft edits, canonical validation, source preservation, Apply/Cancel and competing edits")
}
@MainActor func completionOutcomes() async throws {
  for mode in [EncodingTarget.Behavior.failBefore, .failAfter, .suspendBefore, .suspendAfter] {
    let target = try EncodingTarget(), draft = NativeSessionEncodingDraft(target: target)
    target.behavior = mode; draft.reload(); draft.setEncoding(.quality, value: "5"); draft.apply()
    if mode == .suspendBefore || mode == .suspendAfter {
      try await until("suspended apply") { target.isSuspended }
      draft.setEncoding(.quality, value: "8"); draft.cancelEdits(); draft.reload(); draft.apply()
      try check(draft.values[.quality]?.value == "5" && target.calls == 1, "pending operation gates edits, reload and duplicate apply")
      draft.cancelApply(); target.release()
    }
    try await until("failed/cancelled completion") { !draft.isBusy }
    try check(draft.needsReload && !draft.didApply && !draft.canApply && draft.hasChanges, "uncertain completion preserves draft and gates retry")
    try check(draft.error == ((mode == .suspendBefore || mode == .suspendAfter) ? .cancelled : .applyFailed), "typed redacted outcome")
    draft.reload()
    try check(draft.values[.quality]?.value == ((mode == .failAfter || mode == .suspendAfter) ? "5" : "3"), "reload reconciles actual state after failure/cancellation")
    await draft.close()
  }
  let target = try EncodingTarget(), draft = NativeSessionEncodingDraft(target: target)
  draft.reload(); draft.setEncoding(.quality, value: "5"); draft.apply(); draft.cancelApply()
  try await until("cancel before task runs") { !draft.isBusy }
  try check(target.calls == 0 && draft.error == .cancelled, "pre-admission cancellation makes no change")
  await draft.close()
  print("PASS before/after-acceptance cancellation/failure, current-state reconciliation and bounded pending operation")
}
@MainActor func generationAndLifetime() async throws {
  let target = try EncodingTarget(), draft = NativeSessionEncodingDraft(target: target)
  draft.reload(); draft.setEncoding(.quality, value: "5"); target.encodingGeneration += 1; draft.apply()
  try check(!draft.canApply && target.calls == 0, "generation guard before submission")
  draft.reload(); target.behavior = .suspendAfter; draft.setEncoding(.quality, value: "5"); draft.apply()
  try await until("pending old generation") { target.isSuspended }
  target.encodingGeneration += 1; target.release()
  try await until("old completion") { !draft.isBusy }
  try check(draft.error == .changed && draft.needsReload && !draft.didApply, "late completion cannot confirm a new generation")
  await draft.close()
  var owner: NativeSessionEncodingDraft? = NativeSessionEncodingDraft(target: target)
  let weakOwner = WeakReference(owner)
  owner?.reload(); owner?.setEncoding(.quality, value: "7"); owner?.apply()
  try await until("pending disposal") { target.isSuspended }
  owner?.stop(); owner = nil
  try check(weakOwner.value == nil, "pending task does not retain editor")
  target.release()
  let closing = NativeSessionEncodingDraft(target: target)
  closing.reload(); closing.setEncoding(.quality, value: "8"); closing.apply()
  try await until("pending close") { target.isSuspended }
  var joined = false
  let join = Task { await closing.close(); joined = true }
  for _ in 0..<5 { try await Task.sleep(for: .milliseconds(1)) }
  try check(!joined && !closing.canApply, "close suspends without blocking MainActor")
  target.release(); await join.value
  try check(joined && !closing.isBusy && !closing.didApply, "close joins accepted work and suppresses late UI confirmation")
  print("PASS generation guards, late completion, weak editor lifetime and asynchronous close join")
}
final class Peer {
  let raw: UnsafeMutableRawPointer
  init() throws {
    guard let raw = native_test_peer_create(0) else { throw Failure(message: "Peer unavailable") }
    self.raw = raw
  }
  var endpoint: String { "127.0.0.1::\(native_test_peer_port(raw))" }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func nativeSessionIntegration() async throws {
  let runtime = try NativeRuntime()
  var config = NativeSessionConfiguration(); config.securityTypes = [1]
  config.encoding = try NativeEncodingOptions(patch: [.init("AutoSelect", "off"), .init("QualityLevel", "3")], source: .appDefaults)
  let first = try runtime.makeSession(configuration: config), second = try runtime.makeSession(configuration: config)
  let peer = try Peer(), otherPeer = try Peer()
  _ = try await first.connect(endpoint: peer.endpoint); _ = try await second.connect(endpoint: otherPeer.endpoint)
  let draft = NativeSessionEncodingDraft(session: first)
  draft.reload(); draft.setEncoding(.quality, value: "5"); draft.apply()
  try await until("native apply") { !draft.isBusy }
  try check(draft.didApply && draft.error == nil, "real command completion confirms draft")
  try check(try first.encodingOptions().value(for: .quality).value == "5" && second.encodingOptions().value(for: .quality).value == "3", "only intended native session changes")
  draft.setEncoding(.quality, value: "7"); draft.cancelEdits()
  _ = try await first.disconnect()
  try check(draft.needsReload && !draft.isAvailable, "disconnect invalidates sheet via observation")
  let replacement = try Peer(); _ = try await first.connect(endpoint: replacement.endpoint)
  try check(!draft.canApply && draft.needsReload, "reconnect does not revive old edits")
  draft.reload()
  try check(draft.values[.quality]?.value == "5" && draft.values[.quality]?.source == .session, "successful override survives reconnect")
  try await first.close()
  try check(!draft.canApply && !draft.isAvailable, "native close invalidates editor")
  await draft.close(); try await runtime.shutdown()
  print("PASS two native sessions, actual command completion, disconnect/reconnect persistence and close observation")
}
final class EmptyPreferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ value: Data) throws { throw Failure(message: "Live sheet must not save defaults") }
}
@MainActor func connectionController() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing: EmptyPreferences())
  var registrations = 0
  let controller = ConnectionModel(runtime: runtime, preferences: store) { _, _ in registrations += 1 }
  try await until("controller defaults") { controller.defaults?.isReady == true }
  try check(registrations == 1 && !controller.canOpenEncoding, "one deferred session registration and disconnected editor gate")
  let peer = try Peer(); controller.endpoint = peer.endpoint; controller.connect()
  try await until("controller connect") { !controller.busy }
  try check(controller.canOpenEncoding, "connected controller enables editor")
  controller.openEncoding()
  guard let draft = controller.encodingDraft else { throw Failure(message: "Missing sheet model") }
  controller.openEncoding()
  try check(controller.encodingDraft === draft, "single editor per connection")
  draft.setEncoding(.quality, value: "5"); draft.apply(); controller.closeEncoding()
  try check(controller.encodingDraft == nil && !controller.canOpenEncoding, "dismissal gates reopening until cleanup completes")
  try await until("sheet join") { controller.canOpenEncoding }
  controller.openEncoding()
  try check(controller.encodingDraft != nil && controller.encodingDraft !== draft, "fresh editor after drain")
  controller.disconnect()
  try await until("controller disconnect") { !controller.busy }
  try check(controller.encodingDraft == nil && !controller.canOpenEncoding, "disconnect removes encoding sheet before another authentication flow")
  let replacement = try Peer(); controller.endpoint = replacement.endpoint; controller.connect()
  try await until("controller reconnect") { !controller.busy }
  controller.openEncoding(); controller.encodingDraft?.setEncoding(.quality, value: "7"); controller.encodingDraft?.apply()
  await controller.close()
  try check(controller.closing && controller.encodingDraft == nil && controller.session?.isClosing == true, "window close joins encoding and session cleanup")
  try await runtime.shutdown(); await store.close()
  print("PASS actual app controller: deferred registration, single sheet, reopen drain, disconnect dismissal and window-close join")
}
@main struct NativeEncodingDraftTests {
  @MainActor static func main() async {
    do { try await editsAndConflicts(); try await completionOutcomes(); try await generationAndLifetime(); try await nativeSessionIntegration(); try await connectionController() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
