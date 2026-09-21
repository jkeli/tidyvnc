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
@MainActor final class CommandWindow: NSWindow {
  var fullscreenRequests = 0, minimizeRequests = 0
  var simulatedFullscreen = false, completeMinimize = true
  var simulatedSheet: NSWindow?
  override var styleMask: NSWindow.StyleMask {
    get { simulatedFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
    set { super.styleMask = newValue }
  }
  override var attachedSheet: NSWindow? { simulatedSheet ?? super.attachedSheet }
  override func toggleFullScreen(_ sender: Any?) { fullscreenRequests += 1 }
  override func miniaturize(_ sender: Any?) {
    minimizeRequests += 1
    if completeMinimize { NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: self) }
  }
}
@MainActor final class Host: NativeDesktopCommandHost {
  let commandWindow: NSWindow?
  let commandViewport = CGSize(width: 200, height: 200)
  let commandDesktopSize = CGSize(width: 100, height: 100)
  weak var session: NativeSession?
  var allowFocus = true, blockInputOnFocus = false, clears = 0, captureReleases = 0, focusRefreshes = 0
  init(_ session: NativeSession) {
    self.session = session
    commandWindow = CommandWindow(contentRect: CGRect(x: 100,y: 100,width: 300,height: 300),
      styleMask: [.titled,.resizable,.miniaturizable], backing: .buffered, defer: false)
    commandWindow?.isReleasedWhenClosed = false
  }
  func focusForCommand() -> Bool {
    if allowFocus { try? session?.setFocused(true) }
    if blockInputOnFocus { try? session?.setViewOnly(true) }
    return allowFocus
  }
  func captureKeyboardForCommand() throws {}
  func releaseKeyboardForCommand() { captureReleases += 1 }
  func clearCommandInput() { clears += 1 }
  func canPan(_ direction: NativeDesktopPan) -> Bool { false }
  func panDesktop(_ direction: NativeDesktopPan) -> Bool { false }
  func refreshCommandFocus() { focusRefreshes += 1 }
}
@MainActor func minimizeTransitions() async throws {
  _ = NSApplication.shared
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try runtime.makeSession(), commands = NativeDesktopCommands()
  let host = Host(session), window = host.commandWindow as! CommandWindow
  let otherHost = Host(session), otherWindow = otherHost.commandWindow as! CommandWindow
  defer { window.close(); otherWindow.close() }
  commands.bind(session); commands.attach(host)
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.frame != nil }
  try session.setFocused(true)
  try session.sendKey(id: 9, keysym: 0x61, keycode: 0x1e, down: true)
  try await until { native_test_peer_has_input(peer, 1, 0x61, 0, 0) != 0 }
  window.simulatedFullscreen = true; window.completeMinimize = false
  let releases = host.captureReleases
  try check(commands.canPerform(.minimize), "fullscreen minimize available")
  try commands.perform(.minimize)
  try await until { native_test_peer_has_input(peer, 0, 0x61, 0, 0) != 0 }
  try check(window.fullscreenRequests == 1 && window.minimizeRequests == 0 && commands.isMinimizing,
    "exit request precedes minimization")
  try check(!session.isFocused && host.captureReleases > releases && host.clears > 0,
    "capture and held input released before transition")
  try check(!commands.canPerform(.minimize) && !commands.canPerform(.fullscreen) && !commands.canPerform(.control), "transition gates conflicting commands")
  do { try commands.perform(.minimize); throw Failure(message: "duplicate minimize accepted") }
  catch NativeDesktopCommandIssue.unavailable {}
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: otherWindow)
  try check(window.minimizeRequests == 0, "other window cannot settle transition")
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 1 && commands.isMinimizing, "one minimize after exit, waiting for actual completion")
  NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
  try check(!commands.isMinimizing && commands.windowMessage == nil && host.focusRefreshes == 1, "completion clears pending state")

  commands.minimizeTimeout = .milliseconds(20); window.simulatedFullscreen = true
  try commands.perform(.minimize)
  try await until { !commands.isMinimizing && commands.windowMessage != nil }
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 1, "late exit after timeout cannot minimize")
  window.completeMinimize = true
  try commands.perform(.minimize)
  try check(window.minimizeRequests == 2 && !commands.isMinimizing && commands.windowMessage == nil, "windowed retry clears failure status")
  commands.minimizeTimeout = .seconds(15)

  // Changing ownership, incoming sheets and reverse transitions cancel the intent.
  window.simulatedFullscreen = true; try commands.perform(.minimize)
  commands.detach(host); commands.attach(otherHost)
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 2 && otherWindow.minimizeRequests == 0 && !commands.isMinimizing, "detach cannot minimize either window later")
  commands.attach(host); window.simulatedFullscreen = true; try commands.perform(.minimize)
  window.simulatedSheet = otherWindow; window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(!commands.isMinimizing && window.minimizeRequests == 2, "sheet appearing during exit cancels minimize")
  window.simulatedSheet = nil; window.simulatedFullscreen = true; try commands.perform(.minimize)
  NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 2 && !commands.isMinimizing, "reversed transition cancels old intent")
  window.simulatedFullscreen = true; try commands.perform(.minimize)
  NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 2 && !commands.isMinimizing, "window close cancels old intent")

  let replacement = try runtime.makeSession()
  window.simulatedFullscreen = true; try commands.perform(.minimize); commands.bind(replacement)
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 2 && !commands.isMinimizing, "session rebind cancels pending transition")
  commands.bind(session); window.simulatedFullscreen = true; try commands.perform(.minimize)
  _ = try await session.disconnect()
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 2 && !commands.isMinimizing, "disconnect cancels pending transition")

  commands.bind(replacement); window.simulatedFullscreen = true; try commands.perform(.minimize)
  try await replacement.close()
  window.simulatedFullscreen = false
  NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
  try check(window.minimizeRequests == 2 && !commands.isMinimizing, "session close cancels pending transition")
  commands.stop(); try await session.close(); try await runtime.shutdown()

  let lifetimeRuntime = try NativeRuntime(), lifetimeSession = try lifetimeRuntime.makeSession()
  var owner: NativeDesktopCommands? = NativeDesktopCommands()
  let weakOwner = WeakReference(owner)
  owner!.bind(lifetimeSession); owner!.attach(host); window.simulatedFullscreen = true
  try owner!.perform(.minimize); owner = nil
  try check(weakOwner.value == nil, "pending deadline and window observers do not retain command owner")
  window.simulatedFullscreen = false
  try await lifetimeSession.close(); try await lifetimeRuntime.shutdown()
  print("PASS fullscreen/windowed minimize sequencing, held-key release, timeout/retry, notification isolation and cancellation lifetime")
}
@MainActor func exercise() async throws {
  _ = NSApplication.shared
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let model = ConnectionModel(runtime: runtime, preferences: preferences) { _,_ in }
  try await until { model.defaults?.isReady == true }
  let session = model.session!, commands = model.desktopCommands
  let host = Host(session); commands.attach(host)
  try check(!commands.canPerform(.control) && !model.canOpenInformation, "idle gating")
  model.toggleStatistics()
  try check(!model.showsStatistics && !model.canToggleStatistics, "idle statistics gating")
  let otherModel = ConnectionModel(runtime: runtime, preferences: preferences) { _,_ in }
  try await until { otherModel.defaults?.isReady == true }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.frame != nil }
  model.openInformation()
  try check(model.informationID != nil && !model.canOpenInput && !model.canOpenScaling && !model.canOpenEncoding, "information sheet arbitration")
  model.closeInformation()
  let popup = DesktopContextMenu(model: model), menu = popup.makeMenu()
  try check(menu.items.contains { $0.title == "Capture Keyboard" && $0.isEnabled }, "context capture item")
  try check(menu.items.contains { $0.title == "Send Ctrl-Alt-Delete" && $0.isEnabled }, "context synthetic command")
  let info = menu.items.first { $0.title == "Connection Information…" }!
  try check(NSApp.sendAction(info.action!, to: info.target, from: info) && model.informationID != nil, "context action routes to owning model")
  model.closeInformation()
  let stats = menu.items.first { $0.title == "Show Connection Statistics" }!
  try check(stats.isEnabled && stats.state == .off, "connected statistics menu availability")
  try check(NSApp.sendAction(stats.action!, to: stats.target, from: stats) && model.showsStatistics, "context statistics routes to owning model")
  try check(!otherModel.showsStatistics, "statistics visibility is connection scoped")
  let selectedPopup = DesktopContextMenu(model: model)
  try check(selectedPopup.makeMenu().items.first { $0.title == "Show Connection Statistics" }?.state == .on, "statistics menu reflects selection")
  model.busy = true; model.toggleStatistics()
  try check(!model.showsStatistics, "visible statistics can always be hidden")
  model.toggleStatistics()
  try check(!model.showsStatistics, "busy connection cannot show statistics")
  model.busy = false; try session.setViewOnly(true); model.toggleStatistics()
  try check(model.showsStatistics, "view-only connection permits statistics")
  try session.setViewOnly(false)
  try commands.perform(.fullscreen); try commands.perform(.minimize)
  let window = host.commandWindow as! CommandWindow
  try check(window.fullscreenRequests == 1 && window.minimizeRequests == 1, "owning window routing")
  var entryRequests = 0
  commands.onEnterFullscreen = { entryRequests += 1 }
  window.simulatedFullscreen = true
  try commands.perform(.fullscreen)
  try check(window.fullscreenRequests == 2 && entryRequests == 0, "existing native fullscreen exits before entry policy")
  window.simulatedFullscreen = false
  try commands.perform(.fullscreen)
  try check(entryRequests == 1 && window.fullscreenRequests == 2, "windowed command uses entry policy")
  commands.onEnterFullscreen = nil
  try commands.perform(.fitWindow)
  try check(window.frame.width == 200, "window fit includes chrome")
  let second = try runtime.makeSession(), other = NativeDesktopCommands(); other.bind(second)
  try commands.perform(.control)
  try await until { native_test_peer_count_input(peer,1,0xffe3,0,0) >= 1 }
  try check(commands.controlSelected && !other.controlSelected, "modifier state isolated")
  let pressed = native_test_peer_count_input(peer,1,0xffe3,0,0)
  try session.setFocused(false)
  try await until { native_test_peer_count_input(peer,0,0xffe3,0,0) >= 1 }
  try session.setFocused(true)
  try await until { native_test_peer_count_input(peer,1,0xffe3,0,0) > pressed }
  try check(commands.controlSelected, "focus loss releases and regain reasserts selection")
  try commands.perform(.alt)
  try await until { native_test_peer_has_input(peer,1,0xffe9,0,0) != 0 }
  try commands.perform(.controlAltDelete)
  try await until { native_test_peer_has_input(peer,0,0xffff,0,0) != 0 }
  try check(commands.controlSelected && commands.altSelected && host.clears >= 3, "chord releases Delete and preserves menu modifiers")
  let beforePolicy = native_test_peer_count_input(peer,1,0xffe3,0,0)
  try session.setViewOnly(true)
  try check(!commands.canPerform(.controlAltDelete), "view-only disables synthetic input")
  do { try commands.perform(.controlAltDelete); throw Failure(message: "view-only command sent") }
  catch NativeDesktopCommandIssue.unavailable {}
  try session.setViewOnly(false)
  try await until { native_test_peer_count_input(peer,1,0xffe3,0,0) > beforePolicy }
  try commands.perform(.control); try commands.perform(.alt)
  try check(!commands.controlSelected && !commands.altSelected, "toggle off")
  let beforeChord = native_test_peer_count_input(peer,0,0xffff,0,0)
  try commands.perform(.controlAltDelete)
  try await until { native_test_peer_count_input(peer,0,0xffff,0,0) > beforeChord && native_test_peer_has_control_alt_delete(peer) != 0 }
  host.allowFocus = false
  do { try commands.perform(.control); throw Failure(message: "inactive desktop accepted input") }
  catch NativeDesktopCommandIssue.unavailable {}
  try check(!commands.controlSelected, "focus refusal leaves selection unchanged")
  host.allowFocus = true; host.blockInputOnFocus = true
  do { try commands.perform(.control); throw Failure(message: "policy changed during focus") }
  catch NativeDesktopCommandIssue.unavailable {}
  try check(!commands.controlSelected, "post-focus policy check preserves selection")
  host.blockInputOnFocus = false; try session.setViewOnly(false)
  let beforeFinalControl = native_test_peer_count_input(peer,1,0xffe3,0,0)
  try commands.perform(.control)
  try await until { native_test_peer_count_input(peer,1,0xffe3,0,0) > beforeFinalControl }
  let beforeRebind = native_test_peer_count_input(peer,0,0xffe3,0,0)
  commands.bind(second)
  try await until { native_test_peer_count_input(peer,0,0xffe3,0,0) > beforeRebind }
  try check(!commands.controlSelected && !commands.canPerform(.control), "rebind releases old session")
  commands.bind(session); try commands.perform(.control)
  model.openInformation(); _ = try await session.disconnect()
  try check(!commands.controlSelected && !commands.altSelected && model.informationID == nil, "disconnect clears selection and info")
  try check(!model.showsStatistics && !model.canToggleStatistics, "disconnect clears statistics")
  _ = NSApp.sendAction(stats.action!, to: stats.target, from: stats)
  try check(!model.showsStatistics, "stale menu rechecks disconnected session")
  let reconnectPeer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(reconnectPeer) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(reconnectPeer))")
  try await until { session.information != nil }
  try check(!model.showsStatistics, "reconnect starts with hidden statistics")
  model.toggleStatistics(); try check(model.showsStatistics, "reconnected statistics available")
  commands.detach(host)
  try check(!commands.canPerform(.fullscreen), "detached target disabled")
  model.requestClose()
  try check(!model.showsStatistics && !model.canToggleStatistics, "close clears statistics immediately")
  await otherModel.close(); await model.close(); other.stop(); try await second.close(); await preferences.close(); try await runtime.shutdown()
  window.close()
  var owner: NativeDesktopCommands? = NativeDesktopCommands()
  let weakOwner = WeakReference(owner)
  owner!.bind(second); owner!.attach(host); owner = nil
  try check(weakOwner.value == nil, "observers and recovery task do not retain owner")
  print("PASS actual session commands, modifier wire release/reassertion, Ctrl-Alt-Delete, view-only/focus guards, isolation and sheet arbitration")
}
@MainActor func geometry() throws {
  let frame = NativeDesktopCommands.fitFrame(window: CGRect(x:-500,y:100,width:600,height:500), viewport: CGSize(width:580,height:400),
    desktop: CGSize(width:900,height:800), minimum: CGSize(width:200,height:100), screen: CGRect(x:-1000,y:0,width:1000,height:700))
  try check(frame == CGRect(x:-920,y:0,width:920,height:700), "negative-origin screen clamp")
  try check(NativeDesktopCommands.fitFrame(window: .zero, viewport: .zero, desktop: CGSize(width:1,height:1), minimum:.zero, screen:CGRect(x:0,y:0,width:10,height:10)) == nil, "zero viewport rejected")
}
@main struct NativeCommandTests {
  @MainActor static func main() async {
    do { try geometry(); try await exercise(); try await minimizeTransitions() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
