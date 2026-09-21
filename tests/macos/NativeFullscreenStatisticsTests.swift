// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
@MainActor func until(_ condition: () -> Bool, line: UInt = #line) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Statistics timeout at \(line)")
}
@MainActor final class WeakView { weak var value: NSView?; init(_ value: NSView?) { self.value = value } }
@MainActor final class Displays: NativeDisplaySource {
  func read() throws -> [NativeDisplay] {
    [0,1].map { index in
      let b = NativeDisplayRectangle(x:Double(index)*600,y:0,width:600,height:400)
      return .init(id:.init("display-\(index)"),name:"Display \(index)",bounds:b,workArea:b,backingScale:1,isPrimary:index == 0)
    }
  }
}
@MainActor final class Window: NSWindow {
  override var isVisible: Bool { true }
  override var backingScaleFactor: CGFloat { 1 }
}
@MainActor final class Backend: NativeFullscreenWindows {
  weak var primary: NSWindow?
  func currentDisplay(_ window: NSWindow) -> NativeDisplayID? { .init("display-0") }
  func makeWindow(display: NativeDisplay, primary: Bool, strategy: NativeFullscreenStrategy) throws -> NSWindow {
    let window = Window(contentRect:.init(x:0,y:0,width:600,height:400),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    if primary { self.primary = window }; return window
  }
  func show(_ window: NSWindow, focus: Bool) {}
  func hide(_ window: NSWindow) {}
  func toggleNative(_ window: NSWindow) {}
  func dispose(_ window: NSWindow) { window.close() }
}
@MainActor final class Fixture {
  let session: NativeSession
  let source = NativeDesktopView(frame:.init(x:0,y:0,width:600,height:400))
  let original: NSWindow
  let scaling = NativeScalingState(), input = NativeInputState(), commands = NativeDesktopCommands()
  let displays = NativeDisplayService(source:Displays()), backend = Backend()
  let owner: NativeFullscreenController
  init(_ session: NativeSession) throws {
    self.session = session
    original = Window(contentRect:source.bounds,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    original.isReleasedWhenClosed = false; original.contentView = source
    scaling.bind(session); input.bind(session); commands.bind(session)
    source.bind(session); source.observeScaling(scaling); source.observeInput(input); source.observeCommands(commands)
    owner = NativeFullscreenController(session:session,source:source,displays:displays,scaling:scaling,input:input,commands:commands,windows:backend)
  }
  var roots: [NativeFullscreenContentView] { owner.ownedWindows.compactMap { $0.contentView as? NativeFullscreenContentView } }
  func enter() throws { try owner.enter(.all,strategy:.nativeSpace) }
  func activate() { owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:backend.primary!)) }
  func exit() { owner.exit(); owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:backend.primary!)) }
  func stop() {
    owner.stop(); source.detach(); original.contentView = nil; original.close()
    scaling.stop(); input.stop(); commands.stop(); displays.stop()
  }
}
@MainActor func capture(_ content: NativeFullscreenContentView, directory: URL, dark: Bool) async throws {
  content.window?.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
  content.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(80)); content.layoutSubtreeIfNeeded()
  guard let host = content.statisticsView else { throw Failure(message:"Missing statistics") }
  try check(host.frame.width > 0 && host.frame.height > 0 && content.bounds.contains(host.frame),"statistics stay inside fullscreen content")
  try check(host.fittingSize.height <= host.frame.height,"statistics render without vertical clipping")
  guard let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) else { throw Failure(message:"Missing bitmap") }
  content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in:content.bounds,to:bitmap) }
  guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw Failure(message:"Missing PNG") }
  try bytes.write(to:directory.appendingPathComponent(dark ? "fullscreen-statistics-dark.png" : "fullscreen-statistics.png"))
}
@MainActor func run() async throws {
  _ = NSApplication.shared
  let directory = URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory(),isDirectory:true)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  let runtime = try NativeRuntime(), session = try runtime.makeSession(), other = try runtime.makeSession()
  let peer = native_test_peer_create_pattern(0)!, otherPeer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer); native_test_peer_destroy(otherPeer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
  _ = try await other.connect(endpoint:"127.0.0.1::\(native_test_peer_port(otherPeer))")
  try await until { session.information?.frames ?? 0 > 0 && other.information?.frames ?? 0 > 0 }
  let fixture = try Fixture(session), second = try Fixture(other)
  defer { fixture.stop(); second.stop() }
  fixture.owner.showsStatistics = true; try fixture.enter(); try second.enter(); second.activate()
  try check(fixture.roots.count == 2 && fixture.roots.allSatisfy { $0.statisticsView == nil },"entry hides statistics until activation")
  fixture.activate()
  try await until { fixture.roots.allSatisfy { $0.statisticsInformation == session.information } }
  let roots = fixture.roots
  for root in roots {
    root.layoutSubtreeIfNeeded()
    try check(root.desktop.superview === root && root.desktop.frame == root.bounds,"overlay is a sibling and does not reserve desktop space")
    try check(root.statisticsView?.acceptsFirstResponder == false,"statistics cannot steal keyboard focus")
    let hit = root.hitTest(.init(x:root.bounds.maxX-25,y:25))
    try check(hit === root.desktop,"pointer events pass through the native hosting view")
    try check(root.window?.firstResponder === root.desktop,"desktop remains first responder")
    try check(root.desktop.accessibilityRole() == .image && root.statisticsView?.superview === root,"statistics are outside the accessible remote-image leaf")
  }
  try check(second.roots.allSatisfy { $0.statisticsView == nil },"fullscreen statistics are connection scoped")
  try await until { fixture.owner.ownedViews.allSatisfy { !$0.isRendering && $0.displayedSequence == session.frame?.sequence } }
  for dark in [false,true] { try await capture(roots[0],directory:directory,dark:dark) }
  let rectangles = fixture.owner.ownedViews.map(\.desktopRectangle)
  let identities = roots.map { ObjectIdentifier($0.statisticsView!) }, oldFrames = session.information!.frames
  native_test_peer_patch(peer)
  try await until { (session.information?.frames ?? 0) > oldFrames && roots.allSatisfy { $0.statisticsInformation == session.information } }
  try check(roots.map { ObjectIdentifier($0.statisticsView!) } == identities,"sample updates reuse existing overlay hosts")
  fixture.owner.showsStatistics = false
  try check(roots.allSatisfy { $0.statisticsView == nil } && fixture.owner.phase == .active,"hide does not exit fullscreen")
  try check(fixture.owner.ownedViews.map(\.desktopRectangle) == rectangles,"statistics updates leave rendering geometry unchanged")
  fixture.owner.showsStatistics = true
  try check(roots.allSatisfy { $0.statisticsInformation == session.information },"show uses the latest copied information")
  roots[0].window?.setContentSize(.init(width:480,height:360)); roots[0].layoutSubtreeIfNeeded()
  try check(roots[0].desktop.frame == roots[0].bounds && roots[0].bounds.contains(roots[0].statisticsView!.frame),"content resize keeps full desktop and bounded overlay")
  let discarded = WeakView(roots[0].statisticsView)
  fixture.owner.exit()
  try check(fixture.owner.phase == .exiting && roots.allSatisfy { $0.statisticsView == nil },"exit removes overlays before the native transition")
  fixture.owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:fixture.backend.primary!))
  try await until { discarded.value == nil }
  try check(roots.allSatisfy { $0.window == nil } && fixture.owner.showsStatistics,"windowed restoration disposes owned content but keeps connection visibility")
  try fixture.enter(); fixture.activate()
  try check(fixture.roots.allSatisfy { $0.statisticsInformation == session.information },"re-entry recreates the current statistics")
  _ = try await session.disconnect()
  try await until { fixture.owner.phase == .windowed }
  try check(!fixture.owner.showsStatistics && fixture.roots.isEmpty,"disconnect clears fullscreen statistics and owned content")
  try check(second.owner.phase == .active && second.roots.allSatisfy { $0.statisticsView == nil },"other fullscreen connection remains unchanged")
  second.owner.showsStatistics = true; second.owner.stop()
  try check(second.roots.isEmpty && !second.owner.showsStatistics,"stop disposes all statistics hosts and visibility")
  try await session.close(); try await other.close(); try await runtime.shutdown()
  print("PASS fullscreen statistics activation, sampled updates, input/geometry isolation, two sessions, transitions and teardown")
}
@main struct Main {
  static func main() async { do { try await run() } catch { print("FAIL \(error)"); exit(1) } }
}
