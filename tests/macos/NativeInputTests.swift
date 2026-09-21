// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message: "Unexpected persistence") }
}
@MainActor func exercise() async throws {
  _ = NSApplication.shared
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let model = ConnectionModel(runtime: runtime, preferences: preferences) { _, _ in }
  try await until { model.defaults?.isReady == true }
  try check(!model.canOpenInput, "idle gating")
  let session = model.session!
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.frame != nil }
  var view: NativeDesktopView? = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
  let weakView = WeakReference(view)
  view!.bind(session); view!.observeInput(model.input)
  try await until { !view!.isRendering && view!.displayedSequence != 0 }
  model.openInput()
  try check(model.inputDraft != nil && !model.canOpenScaling && !model.canOpenEncoding, "exclusive sheet")
  model.inputDraft!.viewOnly = true; model.inputDraft!.cursorFallback = .dot
  try check(!session.isViewOnly && view!.cursorFallback == .hidden, "copied draft")
  model.closeInput()
  try check(!session.isViewOnly && model.input.value == NativeInputSettings(), "cancel")
  let stale = NativeInputDraft(state: model.input)
  try session.setFocused(true)
  let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
    windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0)!
  view!.keyDown(with: key)
  let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: view!.convert(CGPoint(x: 150, y: 150), to: nil),
    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  view!.mouseDown(with: mouse)
  try await until { native_test_peer_has_input(peer,1,65,0,0) != 0 && native_test_peer_has_input(peer,5,1,1,1) != 0 }
  view!.setMarkedText("draft", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
  model.openInput(); model.inputDraft!.viewOnly = true; model.inputDraft!.cursorFallback = .dot
  try check(model.inputDraft!.apply(), "apply")
  model.closeInput()
  try await until { native_test_peer_has_input(peer,0,65,0,0) != 0 && native_test_peer_has_input(peer,5,0,1,1) != 0 }
  try check(session.isViewOnly && view!.cursorFallback == .dot && !view!.hasMarkedText(), "live policy and local composition cleared")
  do { try session.sendKey(id: 99, keysym: 66, keycode: 0, down: true); throw Failure(message: "view-only sent input") }
  catch let error as NativeError { try check(error.status == .viewOnly, "view-only rejection") }
  stale.cursorFallback = .system
  try check(!stale.apply() && stale.issue == .changed, "stale apply")
  let reopened = NativeInputDraft(state: model.input)
  try check(reopened.viewOnly && reopened.cursorFallback == .dot && !reopened.canApply, "reopen baseline")
  // A button pressed while viewing must not accumulate local drag state.
  let blockedMouse = NSEvent.mouseEvent(with: .rightMouseDown, location: view!.convert(CGPoint(x: 25, y: 125), to: nil),
    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  view!.rightMouseDown(with: blockedMouse)
  try session.setViewOnly(false)
  view!.mouseMoved(with: blockedMouse)
  try await until { native_test_peer_has_input(peer,5,0,0,1) != 0 }
  try check(native_test_peer_has_input(peer,5,4,0,1) == 0, "view-only press cannot become a later drag")
  reopened.cursorFallback = .hidden
  try check(!reopened.apply() && reopened.issue == .changed && !model.input.value.viewOnly, "external view-only change invalidates editor")
  let otherSession = try runtime.makeSession()
  let other = NativeInputState(); other.bind(otherSession)
  try check(other.value == NativeInputSettings(), "session isolation")
  let fallback = NativeInputDraft(state: model.input); fallback.cursorFallback = .system
  try check(fallback.apply() && view!.cursorFallback == .system && !session.isViewOnly, "fallback-only change")
  let disconnected = NativeInputDraft(state: model.input)
  model.openInput(); _ = try await session.disconnect()
  disconnected.viewOnly = true
  try check(model.inputDraft == nil && !model.canOpenInput && !disconnected.apply() && disconnected.issue == .closed, "disconnect invalidation")
  let replacement = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(replacement) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(replacement))")
  try check(!disconnected.apply() && disconnected.issue == .changed, "old generation cannot apply after reconnect")
  let closing = NativeInputDraft(state: model.input); closing.viewOnly = true
  model.requestClose()
  try check(!closing.apply() && closing.issue == .closed, "close gates synchronous apply")
  view!.detach(); view = nil
  try check(weakView.value == nil, "view subscription weak ownership")
  var owner: NativeInputState? = NativeInputState(); owner!.bind(otherSession)
  let weakOwner = WeakReference(owner)
  let orphan = NativeInputDraft(state: owner!); owner = nil
  try check(weakOwner.value == nil && !orphan.apply() && orphan.issue == .closed, "draft weak ownership")
  await model.close(); other.stop(); try await otherSession.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS copied input drafts, cancellation, isolation, stale/disconnect guards, view-only wire release, fallback routing and weak cleanup")
}
@MainActor func middleButton() async throws {
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.frame != nil }
  let state = NativeInputState(); state.bind(session)
  let view = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
  view.bind(session); view.observeInput(state)
  try await until { !view.isRendering && view.displayedSequence != 0 }
  let cancelled = NativeInputDraft(state: state); cancelled.emulateMiddle = true; cancelled.cancel()
  try check(!cancelled.apply() && !session.emulatesMiddleButton, "cancel emulation")
  let draft = NativeInputDraft(state: state); draft.emulateMiddle = true
  try check(draft.apply() && session.emulatesMiddleButton && NativeInputDraft(state: state).emulateMiddle, "enable and reopen emulation")
  try session.setFocused(true)
  func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  view.mouseDown(with: mouse(.leftMouseDown,25,25))
  view.rightMouseDown(with: mouse(.rightMouseDown,150,150))
  try await until { native_test_peer_has_input(peer,5,2,0,0) != 0 }
  try check(native_test_peer_has_input(peer,5,1,0,0) == 0, "chord has no stray left press")
  view.mouseUp(with: mouse(.leftMouseUp,150,150))
  view.rightMouseUp(with: mouse(.rightMouseUp,150,150))
  try await until { native_test_peer_has_input(peer,5,0,1,1) != 0 }
  view.mouseDown(with: mouse(.leftMouseDown,25,150))
  try await until { native_test_peer_has_input(peer,5,1,0,1) != 0 }
  let stale = NativeInputDraft(state: state)
  try session.setInputPolicy(viewOnly: false, emulateMiddle: false)
  try await until { native_test_peer_has_input(peer,5,0,0,1) != 0 }
  stale.cursorFallback = .dot
  try check(!stale.apply() && stale.issue == .changed && !state.value.emulateMiddle, "external emulation change invalidates draft and releases drag")
  view.mouseMoved(with: mouse(.mouseMoved,150,25))
  try await until { native_test_peer_has_input(peer,5,0,1,0) != 0 }
  try check(native_test_peer_has_input(peer,5,1,1,0) == 0, "policy change clears local drag")
  state.stop(); view.detach(); try await session.close(); try await runtime.shutdown()
  print("PASS native middle-button setting, chord wire events, delayed single press and policy-change release")
}
@main struct NativeInputTests {
  @MainActor static func main() async {
    do { try await exercise(); try await middleButton() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
