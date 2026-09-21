// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message:message) } }
@MainActor func until(_ condition: () -> Bool, line: UInt = #line) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Fullscreen resize timeout at \(line)")
}
@MainActor func quiet(_ peer: UnsafeMutableRawPointer, _ count: UInt32) async throws {
  try await Task.sleep(for:.milliseconds(220))
  try check(native_resize_peer_count(peer) == count,"Unexpected resize count: \(native_resize_peer_count(peer)), expected \(count)")
}
func display(_ id: String, x: Double, scale: Double = 1) -> NativeDisplay {
  let bounds = NativeDisplayRectangle(x:x,y:0,width:20,height:10)
  return .init(id:.init(id),name:id,bounds:bounds,workArea:bounds,backingScale:scale,isPrimary:x == 0)
}
@MainActor final class Displays: NativeDisplaySource {
  var values = [display("a",x:-20,scale:2),display("b",x:0)]
  func read() throws -> [NativeDisplay] { values }
}
@MainActor final class Window: NSWindow {
  var minimized = false
  override var isVisible: Bool { true }
  override var isMiniaturized: Bool { minimized }
  override var backingScaleFactor: CGFloat { 1 }
  override func miniaturize(_ sender: Any?) {
    minimized = true; NotificationCenter.default.post(name:NSWindow.didMiniaturizeNotification,object:self)
  }
}
@MainActor final class Backend: NativeFullscreenWindows {
  var toggled: NSWindow?
  var failAfter: Int?
  var created = 0
  func currentDisplay(_ window: NSWindow) -> NativeDisplayID? { .init("b") }
  func makeWindow(display: NativeDisplay, primary: Bool, strategy: NativeFullscreenStrategy) throws -> NSWindow {
    if let failAfter, created >= failAfter { throw Failure(message:"Factory failure") }; created += 1
    let window = Window(contentRect:.init(x:0,y:0,width:display.bounds.width,height:display.bounds.height),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; return window
  }
  func show(_ window: NSWindow, focus: Bool) {}
  func hide(_ window: NSWindow) {}
  func toggleNative(_ window: NSWindow) { toggled = window }
  func dispose(_ window: NSWindow) { window.close() }
}
@MainActor func scale(_ state: NativeScalingState, _ text: String = "100", device: Bool) throws {
  let draft = NativeScalingDraft(state:state), candidate = try NativeScaling(text,devicePixels:device)
  draft.mode = candidate.mode; draft.text = text; draft.devicePixels = device
  try check(draft.apply(),"Scale/units change applies")
}
@MainActor func ownedWindows() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime()
  var config = NativeSessionConfiguration(); config.scaling = try .init("100")
  let session = try runtime.makeSession(configuration:config), peer = native_resize_peer_create()!
  defer { native_resize_peer_destroy(peer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { session.snapshot.supportsResize }
  let scaling = NativeScalingState(), input = NativeInputState(), commands = NativeDesktopCommands()
  scaling.bind(session); input.bind(session); commands.bind(session)
  let source = NativeDesktopView(frame:.init(x:0,y:0,width:50,height:30))
  let original = Window(contentRect:source.bounds,styleMask:[.titled,.resizable,.miniaturizable],backing:.buffered,defer:false)
  original.isReleasedWhenClosed = false; original.contentView = source
  source.bind(session); source.observeScaling(scaling); source.observeInput(input); source.observeCommands(commands)
  let provider = Displays(), displays = NativeDisplayService(source:provider), backend = Backend()
  let owner = NativeFullscreenController(session:session,source:source,displays:displays,scaling:scaling,input:input,commands:commands,windows:backend)
  defer { owner.stop(); source.detach(); original.contentView = nil; original.close(); scaling.stop(); input.stop(); commands.stop(); displays.stop() }
  func enter() throws {
    try owner.enter(.all,strategy:.nativeSpace)
    try check(owner.phase == .entering,"native entry waits")
  }
  func activate() {
    owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:backend.toggled!))
  }
  func exit() {
    owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:backend.toggled!))
  }
  try enter(); source.setFrameSize(.init(width:51,height:31)); source.layout(); try await quiet(peer,0)
  let baseline = try session.desktopLayout().layout
  activate()
  let logical = try NativeDisplayLayout(displays:provider.values,devicePixels:false)
  let first = try logical.remoteLayout(matching:baseline)
  try await until { (try? session.desktopLayout().layout) == first }
  try check(first.screens.count == 2 && first.screens[0].id == 7 && first.screens[0].flags == 9 && first.screens[1].id == 0,"complete layout preserves remote identities/flags and allocates new IDs")
  try await quiet(peer,1)
  let device = try NativeDisplayLayout(displays:provider.values,devicePixels:true)
  let second = try device.remoteLayout(matching:first)
  try scale(scaling,device:true)
  try await until { (try? session.desktopLayout().layout) == second }
  try check(second.width == 60 && second.height == 20,"mixed-density geometry matches the rendering canvas")
  for view in owner.ownedViews { view.setFrameSize(.init(width:19,height:9)); view.layout() }
  source.setFrameSize(.init(width:55,height:35)); source.layout(); try await quiet(peer,2)
  native_resize_peer_reply(peer,UInt32.max)
  try scale(scaling,device:false); try await until { native_resize_peer_count(peer) == 3 }
  try scale(scaling,device:true); try await quiet(peer,3)
  native_resize_peer_reply(peer,0)
  try await until { native_resize_peer_count(peer) == 4 && (try? session.desktopLayout().layout) == second }
  try session.setViewOnly(true); try scale(scaling,device:false); try await quiet(peer,4)
  try session.setViewOnly(false); try await until { native_resize_peer_count(peer) == 5 && session.snapshot.width == 40 }
  try session.setResizePolicy(.init(enabled:false),expected:session.resizePolicyRevision)
  try scale(scaling,device:true); try await quiet(peer,5)
  try session.setResizePolicy(.init(),expected:session.resizePolicyRevision)
  try await until { native_resize_peer_count(peer) == 6 && session.snapshot.width == 60 }
  try scale(scaling,"Auto",device:true); try await quiet(peer,6)
  try scale(scaling,device:true); try await quiet(peer,6)
  let manual = try NativeRemoteLayout(width:17,height:13,screens:[.init(id:7,x:0,y:0,width:17,height:13,flags:9)])
  _ = try await session.requestDesktopLayout(manual,expectedGeneration:session.generation)
  try await quiet(peer,7)
  try scale(scaling,device:false); try await until { native_resize_peer_count(peer) == 8 && session.snapshot.width == 40 }
  native_resize_peer_reply(peer,1); try scale(scaling,device:true)
  try await until { session.remoteResize.message != nil }; try await quiet(peer,9)
  try session.setViewOnly(true); try session.setViewOnly(false); try await quiet(peer,9)
  native_resize_peer_reply(peer,0)
  try scale(scaling,device:false); try await quiet(peer,9)
  try scale(scaling,device:true); try await until { native_resize_peer_count(peer) == 10 && session.snapshot.width == 60 }
  owner.exit(); source.setFrameSize(.init(width:57,height:37)); source.layout(); try await quiet(peer,10)
  exit(); try await until { session.snapshot.width == 57 && session.snapshot.height == 37 }
  try check(try session.desktopLayout().layout.screens.count == 1,"exit restores the original window as the single authoritative viewport")
  try await quiet(peer,11)
  try enter(); activate(); try await until { native_resize_peer_count(peer) == 12 && session.snapshot.width == 60 }
  try commands.perform(.minimize); try await quiet(peer,12); exit()
  try check(original.isMiniaturized,"owned minimize completed on the original")
  try await quiet(peer,12)
  original.minimized = false; NotificationCenter.default.post(name:NSWindow.didDeminiaturizeNotification,object:original)
  try await until { native_resize_peer_count(peer) == 13 && session.snapshot.width == 57 }
  try enter(); activate(); try await until { native_resize_peer_count(peer) == 14 && session.snapshot.width == 60 }
  provider.values = [display("b",x:0)]; displays.refresh()
  try await until { owner.phase == .windowed && native_resize_peer_count(peer) == 15 && session.snapshot.width == 57 }
  try await quiet(peer,15)
  provider.values = [display("a",x:-20,scale:2),display("b",x:0)]; displays.refresh()
  backend.created = 0; backend.failAfter = 1
  do { try enter(); throw Failure(message:"Partial construction did not fail") }
  catch let error as Failure { try check(error.message == "Factory failure","expected factory rollback") }
  try check(owner.phase == .windowed && owner.ownedViews.isEmpty,"partial factory failure disposes the incomplete canvas")
  try await quiet(peer,15)
  backend.failAfter = nil
  try owner.enter(.all,strategy:.borderless)
  try await until { native_resize_peer_count(peer) == 16 && session.snapshot.width == 60 }
  owner.exit(); try await until { native_resize_peer_count(peer) == 17 && session.snapshot.width == 57 }
  try await quiet(peer,17)
  try await session.close(); try await runtime.shutdown()
  print("PASS owned fullscreen complete wire layouts, IDs/flags, mixed units, transition/minimize/topology handoff, coalescing, manual override and policy gates")
}
@MainActor func ownershipAndInitial() async throws {
  let runtime = try NativeRuntime()
  var config = NativeSessionConfiguration(); config.resizePolicy = try .init(initialSize:"8x4")
  let session = try runtime.makeSession(configuration:config), peer = native_resize_peer_create()!, second = native_resize_peer_create()!
  defer { native_resize_peer_destroy(peer); native_resize_peer_destroy(second) }
  let coordinator = session.remoteResize, window = UUID(), first = UUID(), replacement = UUID()
  let logical = try NativeDisplayLayout(displays:[display("a",x:-20),display("b",x:0)],devicePixels:false)
  coordinator.update(owner:window,viewport:.init(width:31,height:23,scale:1,unscaled:true,devicePixels:false,available:true))
  coordinator.beginCanvas(owner:first)
  coordinator.updateCanvas(owner:first,layout:logical,unscaled:false,available:false)
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { session.snapshot.supportsResize }; try await quiet(peer,0)
  coordinator.updateCanvas(owner:first,layout:logical,unscaled:false,available:true)
  try await until { session.snapshot.width == 8 }; try await quiet(peer,1)
  coordinator.updateCanvas(owner:first,layout:logical,unscaled:true,available:true)
  try await until { session.snapshot.width == 40 }; try await quiet(peer,2)
  coordinator.beginCanvas(owner:replacement)
  coordinator.endCanvas(owner:first); coordinator.updateCanvas(owner:first,layout:logical,unscaled:true,available:true)
  coordinator.attach(owner:UUID()); try await quiet(peer,2)
  coordinator.updateCanvas(owner:replacement,layout:logical,unscaled:true,available:true)
  try await quiet(peer,2)
  _ = try await session.disconnect()
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(second))")
  try await until { session.snapshot.width == 8 }; try await quiet(second,1)
  let changed = try NativeDisplayLayout(displays:[display("b",x:0)],devicePixels:false)
  native_resize_peer_reply(second,UInt32.max)
  coordinator.updateCanvas(owner:replacement,layout:changed,unscaled:true,available:true)
  try await until { native_resize_peer_count(second) == 2 }
  coordinator.endCanvas(owner:replacement); try await quiet(second,2)
  native_resize_peer_reply(second,0)
  try await until { native_resize_peer_count(second) == 3 && session.snapshot.width == 31 }
  try await quiet(second,3)
  coordinator.beginCanvas(owner:UUID()) // No layout during construction is unavailable.
  coordinator.detach(owner:window); try await quiet(second,3)
  try await session.close(); try await runtime.shutdown()
  print("PASS initial-size precedence/reconnect, replacement ownership, stale cleanup and sent-request drain before window restoration")
}
@MainActor func expiredOverrides() async throws {
  let runtime = try NativeRuntime(), peer = native_resize_peer_create()!
  defer { native_resize_peer_destroy(peer) }
  var config = NativeSessionConfiguration(); config.resizePolicy = try .init(initialSize:"8x4")
  let session = try runtime.makeSession(configuration:config), coordinator = session.remoteResize, owner = UUID()
  func viewport(_ width: Double, unscaled: Bool = true) {
    coordinator.update(owner:owner,viewport:.init(width:width,height:10,scale:1,unscaled:unscaled,devicePixels:false,available:true))
  }
  viewport(20)
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { session.snapshot.width == 8 }; try await quiet(peer,1)
  viewport(21); try await until { session.snapshot.width == 21 }
  viewport(20); try await until { session.snapshot.width == 20 }; try await quiet(peer,3)
  let manual = try NativeRemoteLayout(width:10,height:6,screens:[.init(id:7,x:0,y:0,width:10,height:6)])
  _ = try await session.requestDesktopLayout(manual,expectedGeneration:session.generation); try await quiet(peer,4)
  viewport(20,unscaled:false); try await quiet(peer,4)
  viewport(20); try await until { session.snapshot.width == 20 }; try await quiet(peer,5)
  try await session.close(); try await runtime.shutdown()
  print("PASS expired initial/manual overrides cannot suppress a later return to previously attempted geometry")
}
@main struct Main {
  static func main() async {
    do { try await ownedWindows(); try await ownershipAndInitial(); try await expiredOverrides() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
