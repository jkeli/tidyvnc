// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
@MainActor func until(_ condition: () -> Bool, line: UInt = #line) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Surface focus timeout at line \(line)")
}
@MainActor final class Capture: NativeKeyboardCapturing {
  var isActive = false
  func start() -> NativeKeyboardCaptureStart { isActive = true; return .active }
  func stop() { isActive = false }
}
@MainActor final class Window: NSWindow {
  var toggles = 0
  override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
}
@MainActor final class Reference {
  weak var value: NativeDesktopView?
  init(_ value: NativeDesktopView) { self.value = value }
}
@MainActor func key(_ view: NativeDesktopView, down: Bool) {
  let event = NSEvent.keyEvent(with:down ? .keyDown : .keyUp,location:.zero,modifierFlags:[],timestamp:0,
    windowNumber:view.window?.windowNumber ?? 0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
  if down { view.keyDown(with:event) } else { view.keyUp(with:event) }
}
@MainActor func exercise() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), session = try runtime.makeSession(), other = try runtime.makeSession()
  let peer = native_test_peer_create_pattern(0)!, second = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer); native_test_peer_destroy(second) }
  let left = NativeDesktopView(frame:.init(x:0,y:0,width:200,height:200))
  let right = NativeDesktopView(frame:.init(x:0,y:0,width:200,height:200))
  let a = Capture(), b = Capture(), commands = NativeDesktopCommands()
  commands.bind(session)
  let windows = [left,right].map { view in
    let window = Window(contentRect:view.bounds,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = view; return window
  }
  defer { left.detach(); right.detach(); commands.stop(); for window in windows { window.contentView = nil; window.close() } }
  left.captureOverride = a; right.captureOverride = b
  left.captureEligibilityOverride = { true }; right.captureEligibilityOverride = { true }
  left.bind(session); right.bind(session); left.observeCommands(commands); right.observeCommands(commands)
  try check(commands.isActiveHost(left),"background registration does not replace command host")
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
  _ = try await other.connect(endpoint:"127.0.0.1::\(native_test_peer_port(second))")
  try await until { (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]) &&
    left.displayedSequence == session.frame?.sequence && right.displayedSequence == session.frame?.sequence &&
    left.displayedImage != nil && right.displayedImage != nil && !left.isRendering && !right.isRendering && other.frame != nil }
  let otherOwner = UUID(); try other.setDesktopFocused(true,owner:otherOwner)
  try check(right.setFocus(true),"right gains scoped focus")
  try right.captureKeyboardForCommand()
  try check(session.desktopFocusOwner == right.focusOwner && commands.isActiveHost(right) && b.isActive && commands.keyboardCaptured,"focus selects command and capture owner")
  left.setFocus(false); left.clearCommandInput()
  try check(session.isFocused && b.isActive && commands.keyboardCaptured,"background blur and capture cleanup do not clear owner")
  try session.sendPointer(x:1,y:1,buttons:1)
  try await until { native_test_peer_has_input(peer,5,1,1,1) != 0 }
  key(right,down:true)
  try await until { native_test_peer_count_input(peer,1,0xff0d,0,0) == 1 }
  right.setMarkedText("pending",selectedRange:.init(location:0,length:0),replacementRange:.init(location:NSNotFound,length:0))
  var changes: [Bool] = []
  let observation = session.$isFocused.dropFirst().sink { changes.append($0) }
  try check(left.setFocus(true),"left takes scoped focus")
  try await until { native_test_peer_count_input(peer,0,0xff0d,0,0) == 1 && native_test_peer_has_input(peer,5,0,1,1) != 0 }
  try check(changes == [false,true] && !b.isActive && !right.hasMarkedText() && commands.isActiveHost(left),"handoff releases held input/capture/composition and invalidates focus interval")
  try check(other.isFocused && other.desktopFocusOwner == otherOwner,"another session keeps focus")
  await Task.yield(); await Task.yield()
  var commandChanges = 0
  let commandObservation = commands.objectWillChange.sink { commandChanges += 1 }
  for _ in 0..<100 { try check(left.setFocus(true),"repeated owner focus") }
  await Task.yield(); await Task.yield()
  try check(commandChanges == 0,"unchanged owner does not enqueue command recovery or invalidate SwiftUI")
  commandObservation.cancel()
  try left.captureKeyboardForCommand()
  key(left,down:true); try await until { native_test_peer_count_input(peer,1,0xff0d,0,0) == 2 }
  try session.sendPointer(x:0,y:0,buttons:1)
  try await until { native_test_peer_has_input(peer,5,1,0,0) != 0 }
  let oldPointerReleases = native_test_peer_count_input(peer,5,0,1,1)
  right.mouseUp(with:NSEvent.mouseEvent(with:.leftMouseUp,location:right.convert(.init(x:150,y:150),to:nil),
    modifierFlags:[],timestamp:0,windowNumber:windows[1].windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0)!)
  key(right,down:false); key(right,down:true)
  right.insertText("z",replacementRange:.init(location:NSNotFound,length:0))
  right.setMarkedText("stale",selectedRange:.init(location:0,length:0),replacementRange:.init(location:NSNotFound,length:0))
  right.clearCommandInput(); right.releaseKeyboardForCommand(); right.setFocus(false)
  right.isHidden = true; right.isHidden = false
  try await until { !right.isRendering }
  NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:windows[1])
  try commands.perform(.fullscreen)
  try check(windows[0].toggles == 1 && windows[1].toggles == 0,"window command follows focus rather than attachment order")
  try check(session.isFocused && session.desktopFocusOwner == left.focusOwner && a.isActive && commands.keyboardCaptured && !right.hasMarkedText(),"late inactive events cannot affect active input/capture state")
  // Use a wire barrier after rejected input to avoid a false pass from an unread socket.
  left.insertText("q",replacementRange:.init(location:NSNotFound,length:0))
  try await until { native_test_peer_has_input(peer,0,0x71,0,0) != 0 }
  try check(native_test_peer_count_input(peer,5,0,1,1) == oldPointerReleases && native_test_peer_count_input(peer,0,0xff0d,0,0) == 1 && native_test_peer_count_input(peer,1,0xff0d,0,0) == 2 && native_test_peer_has_input(peer,1,0x7a,0,0) == 0,"stale key/IME input is not sent and cannot release the new owner's held key")
  NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:windows[0])
  try await until { native_test_peer_count_input(peer,0,0xff0d,0,0) == 2 && native_test_peer_has_input(peer,5,0,0,0) != 0 }
  try check(!session.isFocused && session.desktopFocusOwner == nil && !a.isActive,"owner window close releases focus and capture")
  left.detach(); try check(commands.isActiveHost(right),"detaching active surface recovers remaining command host")
  try check(right.setFocus(true),"remaining surface gains focus")
  try right.captureKeyboardForCommand()
  try session.setFocused(false)
  try check(session.desktopFocusOwner == nil && !b.isActive && !commands.keyboardCaptured,"app-wide focus revocation clears scoped owner synchronously")
  observation.cancel()

  // Deferred deinit cleanup can release only the destroyed surface's token.
  var transient: NativeDesktopView? = NativeDesktopView(frame:.zero)
  transient!.bind(session); let released = Reference(transient!)
  try check(transient!.setFocus(true),"unattached lifetime fixture gains scope")
  try session.sendKey(id:123,keysym:0x61,down:true)
  try await until { native_test_peer_has_input(peer,1,0x61,0,0) != 0 }
  transient = nil
  try await until { released.value == nil && !session.isFocused && native_test_peer_has_input(peer,0,0x61,0,0) != 0 }
  transient = NativeDesktopView(frame:.zero); transient!.bind(session)
  try check(transient!.setFocus(true),"second lifetime fixture gains scope")
  transient = nil // Cleanup is queued; another surface wins before it runs.
  try check(right.setFocus(true),"new owner precedes old deinit cleanup")
  await Task.yield(); await Task.yield()
  try check(session.desktopFocusOwner == right.focusOwner && session.isFocused,"old deferred cleanup cannot revoke replacement owner")
  _ = try await session.disconnect()
  try await until { !session.isFocused && session.desktopFocusOwner == nil }
  try check(other.isFocused,"disconnect is session-local")
  let replacement = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(replacement) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(replacement))")
  try await until { right.displayedImage != nil && !right.isRendering && right.displayedSequence == session.frame?.sequence }
  try check(session.desktopFocusOwner == nil && !session.isFocused,"new attempt does not inherit an old focus lease")
  try check(right.setFocus(true),"surface can explicitly focus new generation")
  try await session.close()
  try check(session.desktopFocusOwner == nil && !session.isFocused && !right.setFocus(true),"close clears lease and rejects new acquisition")
  try await other.close(); try await runtime.shutdown()
  print("PASS scoped surface handoff, held-key release, stale event suppression, command/capture routing, composition, close/deinit and session isolation")
}
@main struct Main {
  static func main() async {
    do { try await exercise() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
