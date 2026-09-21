// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeKeyMap
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
@MainActor final class Capture: NativeKeyboardCapturing {
  var isActive = false, allowed = true, starts = 0, stops = 0
  func start() -> Bool { starts += 1; isActive = allowed; return isActive }
  func stop() { if isActive { stops += 1 }; isActive = false }
}
@MainActor final class Window: NSWindow {
  var toggles = 0, minimizes = 0
  override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
  override func miniaturize(_ sender: Any?) { minimizes += 1 }
}
@MainActor func exercise() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let view = NativeDesktopView(frame: CGRect(x: 0,y: 0,width: 200,height: 200)), capture = Capture()
  view.captureOverride = capture; view.captureEligibilityOverride = { true }
  let commands = NativeDesktopCommands(), input = NativeInputState()
  commands.bind(session); input.bind(session)
  let window = Window(contentRect: view.bounds, styleMask: [.titled,.resizable,.miniaturizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = view
  view.bind(session); view.observeInput(input); view.observeCommands(commands)
  var errors: [String] = [], menus = 0
  view.onError = { errors.append($0) }
  view.onContextMenu = { _ in menus += 1 }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { view.displayedSequence != 0 && !view.isRendering }
  await Task.yield(); _ = window.makeFirstResponder(view); try session.setFocused(true)
  func event(_ type: NSEvent.EventType, _ code: UInt16, _ text: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
  }
  let both = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.union(.option).rawValue | 0x21)
  func arm() {
    view.flagsChanged(with: event(.flagsChanged,59,"",.init(rawValue: NSEvent.ModifierFlags.control.rawValue | 1)))
    view.flagsChanged(with: event(.flagsChanged,58,"",both))
  }
  func release() {
    view.flagsChanged(with: event(.flagsChanged,58,"",.init(rawValue: NSEvent.ModifierFlags.control.rawValue | 1)))
    view.flagsChanged(with: event(.flagsChanged,59))
  }
  // Test real candidate translation, bounded writes and stable special keys.
  var candidates = [UInt32](repeating: 0xdeadbeef,count: 38)
  let count = candidates.withUnsafeMutableBufferPointer { native_macos_shortcut_candidates(46,$0.baseAddress,37) }
  try check(count > 0 && count <= 37 && candidates[37] == 0xdeadbeef, "layout candidates bounded")
  try check(Set(candidates.prefix(Int(count))).count == count, "layout candidates unique")
  try check(native_macos_shortcut_candidates(36,nil,2) == 0, "null candidate output")
  try check(candidates.withUnsafeMutableBufferPointer { native_macos_shortcut_candidates(36,$0.baseAddress,1) } == 1 && candidates[0] == 0xff0d, "special key candidate")
  // All keyboard layouts have Return and Space. Find the local menu/capture
  // physical keys from their current layout rather than assuming US text.
  func code(for symbol: UInt32) throws -> UInt16 {
    for code in UInt16(0)..<128 {
      var values = [UInt32](repeating: 0,count: 37)
      let n = values.withUnsafeMutableBufferPointer { native_macos_shortcut_candidates(code,$0.baseAddress,37) }
      if values.prefix(Int(n)).contains(symbol) { return code }
    }
    throw Failure(message: "Current keyboard layout has no shortcut candidate \(symbol)")
  }
  let menuCode = try code(for: 0x6d), captureCode = try code(for: 0x67)
  arm()
  try await until { native_test_peer_has_input(peer,1,0xffe3,0,0) != 0 && native_test_peer_has_input(peer,1,0xffe9,0,0) != 0 }
  view.keyDown(with: event(.keyDown,36,"\r",both))
  try await until { native_test_peer_has_input(peer,0,0xffe3,0,0) != 0 && native_test_peer_has_input(peer,0,0xffe9,0,0) != 0 }
  try check(window.toggles == 1 && session.isFocused, "fullscreen dispatch preserves focus while releasing remote keys")
  view.keyUp(with: event(.keyUp,36,"\r",both)); release()
  try check(native_test_peer_has_input(peer,1,0xff0d,0,0) == 0, "local Return never sent")
  arm()
  try check(view.performKeyEquivalent(with: event(.keyDown,captureCode,"g",both)), "armed shortcut takes key equivalent")
  try check(capture.isActive && commands.keyboardCaptured && capture.starts == 1, "capture dispatch")
  view.keyUp(with: event(.keyUp,captureCode,"g",both)); release()
  try check(capture.isActive, "command chord release keeps capture")
  arm(); release()
  try check(!capture.isActive && !commands.keyboardCaptured, "modifier-only chord releases capture")
  // Space bypass keeps modifiers down remotely, forwarding the next key.
  arm(); view.keyDown(with: event(.keyDown,49," ",both)); view.keyUp(with: event(.keyUp,49," ",both))
  try check(view.performKeyEquivalent(with: event(.keyDown,36,"\r",both)), "bypass key equivalent handled once")
  view.keyUp(with: event(.keyUp,36,"\r",both)); release()
  try await until { native_test_peer_has_input(peer,0,0xff0d,0,0) != 0 }
  try check(window.toggles == 1 && native_test_peer_count_input(peer,1,0xff0d,0,0) == 1, "bypass sends one remote pair")
  arm(); view.keyDown(with: event(.keyDown,menuCode,"m",both)); view.keyUp(with: event(.keyUp,menuCode,"m",both)); release()
  try check(menus == 1 && !session.isFocused, "context dispatch relinquishes focus while popup tracks")
  try session.setFocused(true); try session.setViewOnly(true)
  arm(); view.keyDown(with: event(.keyDown,36,"\r",both)); view.keyUp(with: event(.keyUp,36,"\r",both)); release()
  try check(window.toggles == 2, "view-only permits local fullscreen")
  do { try view.captureKeyboardForCommand(); throw Failure(message: "view-only captured keyboard") } catch NativeDesktopCommandIssue.unavailable {}
  try session.setViewOnly(false)
  // Settings are copied, validated and release an in-progress physical chord.
  let invalid = NativeInputDraft(state: input); invalid.shortcutModifiers = .init(rawValue: 16)
  try check(!invalid.apply() && invalid.issue == .failed, "unsupported modifier mask rejected")
  arm(); let draft = NativeInputDraft(state: input); draft.shortcutModifiers = []
  try check(draft.apply() && input.value.shortcutModifiers.isEmpty, "disable shortcuts")
  view.keyDown(with: event(.keyDown,36,"\r",both)); view.keyUp(with: event(.keyUp,36,"\r",both)); release()
  try await until { native_test_peer_count_input(peer,0,0xff0d,0,0) == 2 }
  try check(window.toggles == 2, "settings reset classifier")
  // Automatic capture attempts once, stops on focus loss, and respects release.
  view.fullscreenOverride = { true }; try session.setFocused(true)
  view.updateKeyboardCapture(); try check(capture.isActive, "fullscreen automatic capture")
  view.releaseKeyboardForCommand(); view.updateKeyboardCapture()
  try check(!capture.isActive, "manual release remains released while fullscreen")
  _ = view.resignFirstResponder(); try session.setFocused(true); view.updateKeyboardCapture()
  try check(capture.isActive, "focus regain allows fullscreen capture")
  capture.isActive = false; view.updateKeyboardCapture()
  try check(!commands.keyboardCaptured && commands.captureMessage != nil, "capture revocation reports status")
  _ = view.resignFirstResponder(); capture.allowed = false; try session.setFocused(true)
  view.updateKeyboardCapture(); let attempts = capture.starts
  view.updateKeyboardCapture(); view.updateKeyboardCapture()
  try check(capture.starts == attempts && commands.captureMessage?.contains("Accessibility") == true, "permission failure does not retry every frame")
  capture.allowed = true; try view.captureKeyboardForCommand()
  try check(capture.isActive && commands.captureMessage == nil, "explicit retry")
  try session.setFocused(false)
  try check(!capture.isActive && !commands.keyboardCaptured, "external session focus loss releases capture synchronously")
  try session.setFocused(true); view.updateKeyboardCapture()
  try check(capture.isActive, "external focus recovery")
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
  try check(!capture.isActive && !session.isFocused, "sleep notification releases capture and focus")
  try session.setFocused(true); view.updateKeyboardCapture()
  try check(capture.isActive, "capture can resume after a new focus")
  try commands.perform(.minimize)
  try check(window.minimizes == 1 && commands.isMinimizing && !capture.isActive && !session.isFocused,
    "minimize releases the actual view's injected capture and remote focus")
  try session.setFocused(true); view.updateKeyboardCapture()
  try check(!capture.isActive && !view.focusDesktop() && !view.focusForCommand(), "pending minimize gates capture and focus commands")
  let clicks = native_test_peer_count_input(peer, 5, 1, 0, 0)
  let typed = native_test_peer_count_input(peer, 1, 0x5a, 0, 0)
  let click = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(CGPoint(x: 20, y: 20), to: nil),
    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  view.mouseDown(with: click)
  view.setMarkedText("Z", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
  try check(!view.hasMarkedText(), "pending minimize ignores delayed IME composition")
  view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
  view.keyDown(with: event(.keyDown, 6, "Z", .control))
  // A subsequent explicit core key acts as a wire barrier for ignored callbacks.
  try session.sendKey(id: 999, keysym: 0xff1b, down: true)
  try session.sendKey(id: 999, keysym: 0xff1b, down: false)
  try await until { native_test_peer_has_input(peer, 0, 0xff1b, 0, 0) != 0 }
  try check(native_test_peer_count_input(peer, 5, 1, 0, 0) == clicks && native_test_peer_count_input(peer, 1, 0x5a, 0, 0) == typed,
    "pending minimize drops pointer, key and committed IME input even after external focus changes")
  _ = view.becomeFirstResponder()
  try check(!session.isFocused, "first-responder callback cannot restore input during minimize")
  NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
  try check(!commands.isMinimizing, "minimize completion reopens focus gate")
  try session.setFocused(true); view.updateKeyboardCapture()
  try check(capture.isActive, "capture resumes after completed minimize and new focus")
  _ = try await session.disconnect()
  try check(!capture.isActive && !commands.keyboardCaptured, "disconnect releases capture")
  try check(errors.isEmpty, "no unexpected input errors: \(errors)")
  view.detach(); commands.stop(); input.stop(); window.contentView = nil; window.close()
  try await session.close(); try await runtime.shutdown()
  print("PASS AppKit shortcut dispatch, layout candidates, wire release, bypass, view-only, settings reset and injected capture lifecycle")
}
@main struct NativeShortcutDispatchTests {
  @MainActor static func main() async {
    do { try await exercise() } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
