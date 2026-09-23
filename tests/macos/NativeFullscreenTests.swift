// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message:message) } }
@MainActor func until(_ condition: () -> Bool, line: UInt = #line) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Fullscreen timeout at line \(line)")
}
func display(_ id: String, x: Double, primary: Bool = false) -> NativeDisplay {
  let bounds = NativeDisplayRectangle(x:x,y:0,width:100,height:100)
  return .init(id:.init(id),name:id,bounds:bounds,workArea:bounds,backingScale:1,isPrimary:primary)
}
@MainActor final class Displays: NativeDisplaySource {
  var values = [display("a",x:0,primary:true),display("b",x:100)]
  func read() throws -> [NativeDisplay] { values }
}
@MainActor final class Window: NSWindow {
  var density = 1.0
  var minimizeRequests = 0
  var simulatedSheet: NSWindow?
  override var backingScaleFactor: CGFloat { density }
  override var isVisible: Bool { true }
  override var attachedSheet: NSWindow? { simulatedSheet ?? super.attachedSheet }
  override func miniaturize(_ sender: Any?) { minimizeRequests += 1 }
}
@MainActor final class Backend: NativeFullscreenWindows {
  var current = NativeDisplayID("b")
  var made: [NSWindow] = [], disposed: [NSWindow] = [], shown: [NSWindow] = [], hidden: [NSWindow] = [], toggled: [NSWindow] = []
  var failAt = Int.max
  func currentDisplay(_ window: NSWindow) -> NativeDisplayID? { current }
  func makeWindow(display: NativeDisplay, primary: Bool, strategy: NativeFullscreenStrategy) throws -> NSWindow {
    if made.count == failAt { throw NativeDisplayError.unavailable }
    let window = Window(contentRect:.init(x:display.bounds.x,y:0,width:100,height:100),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; made.append(window); return window
  }
  func show(_ window: NSWindow, focus: Bool) { shown.append(window) }
  func hide(_ window: NSWindow) { hidden.append(window) }
  func toggleNative(_ window: NSWindow) { toggled.append(window) }
  func dispose(_ window: NSWindow) { disposed.append(window); window.close() }
}
@MainActor final class Reference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
@MainActor final class OriginalDelegate: NSObject, NSWindowDelegate {}
@MainActor func backendConstruction() throws {
  _ = NSApplication.shared
  guard let display = try AppKitDisplaySource().read().first else { throw Failure(message:"No display for hidden AppKit construction") }
  let backend = AppKitFullscreenWindows()
  for (primary,strategy) in [(true,NativeFullscreenStrategy.nativeSpace),(false,.nativeSpace),(true,.borderless)] {
    let window = try backend.makeWindow(display:display,primary:primary,strategy:strategy)
    defer { backend.dispose(window) }
    try check(!window.isVisible && window.delegate == nil && window.canBecomeKey && !window.isReleasedWhenClosed,
      "real backend constructs hidden independently owned windows")
    try check(window.frame.width == display.bounds.width && window.frame.height == display.bounds.height && backend.currentDisplay(window) == display.id,
      "real backend resolves stable display identity and full logical bounds")
    if strategy == .nativeSpace && primary {
      try check(window.collectionBehavior.contains(.fullScreenPrimary) && window.styleMask.contains(.resizable),"native primary configuration")
    } else if strategy == .nativeSpace {
      try check(window.collectionBehavior.contains(.fullScreenAuxiliary) && window.collectionBehavior.contains(.canJoinAllSpaces),"native auxiliary configuration")
    } else { try check(window.styleMask.isEmpty && window.collectionBehavior.contains(.fullScreenNone),"borderless comparison configuration") }
  }
  print("PASS hidden real AppKit window construction; no native Space transition was requested")
}
@MainActor func run() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
  try await until { (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]) }
  let source = NativeDesktopView(frame:.init(x:0,y:0,width:160,height:120))
  let original = Window(contentRect:source.bounds,styleMask:[.titled,.resizable,.miniaturizable],backing:.buffered,defer:false)
  original.isReleasedWhenClosed = false; original.contentView = source
  let originalDelegate = OriginalDelegate(); original.delegate = originalDelegate
  let scaling = NativeScalingState(), input = NativeInputState(), commands = NativeDesktopCommands()
  scaling.bind(session); input.bind(session); commands.bind(session)
  source.bind(session); source.observeScaling(scaling); source.observeInput(input); source.observeCommands(commands)
  let provider = Displays(), displays = NativeDisplayService(source:provider)
  let backend = Backend()
  func controller() -> NativeFullscreenController {
    NativeFullscreenController(session:session,source:source,displays:displays,scaling:scaling,input:input,commands:commands,windows:backend)
  }
  let owner = controller()
  defer { owner.stop(); source.detach(); scaling.stop(); input.stop(); commands.stop(); displays.stop(); original.delegate = nil; original.contentView = nil; original.close() }
  try await until { source.displayedSequence == session.frame?.sequence && !source.isRendering }
  try check(source.setFocus(true),"source gains focus")
  try session.sendKey(id:1,keysym:0x61,down:true)
  try await until { native_test_peer_has_input(peer,1,0x61,0,0) != 0 }
  try owner.enter(.all,strategy:.nativeSpace)
  try check(owner.phase == .entering && owner.ownedViews.count == 2 && owner.ownedViews.allSatisfy(\.isHidden) && !source.isHidden,
    "native entry waits without hiding original or admitting input")
  try check(commands.isFullscreen && commands.canPerform(.fullscreen) && !commands.canPerform(.control) && !commands.canPerform(.minimize),"entry exposes Exit and gates conflicting commands")
  let generation = displays.snapshot.generation
  provider.values = provider.values.map {
    NativeDisplay(id:$0.id,name:$0.name,bounds:$0.bounds,
      workArea:.init(x:$0.bounds.x,y:10,width:100,height:90),backingScale:$0.backingScale,isPrimary:$0.isPrimary)
  }
  displays.refresh()
  try check(displays.snapshot.generation > generation && owner.phase == .entering,"Space work-area changes do not cancel native entry")
  try await until { native_test_peer_has_input(peer,0,0x61,0,0) != 0 }
  try check(source.setFocus(true) && !session.isFocused,"source cannot reacquire focus during native entry")
  source.insertText("x",replacementRange:.init(location:NSNotFound,length:0))
  try check(backend.toggled.last === owner.ownedWindows[1] && original.delegate === originalDelegate,"current selected monitor is primary; original delegate unchanged")
  do { try owner.enter(.current,strategy:.borderless); throw Failure(message:"duplicate enter admitted") }
  catch is NativeDesktopCommandIssue {}
  owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:original))
  try check(owner.phase == .entering,"unrelated notifications ignored")
  let primary = owner.ownedWindows[1]
  owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:primary))
  try check(owner.phase == .active && source.isHidden && owner.ownedViews.allSatisfy { !$0.isHidden } && backend.hidden.last === original && owner.canvasLayout?.width == 200,
    "native completion activates owned surfaces and hides source")
  provider.values = [display("a",x:0,primary:true),display("b",x:100)]
  displays.refresh()
  try check(owner.phase == .active,"menu bar and Dock work-area changes preserve active fullscreen")
  original.density = 2
  let scale = NativeScalingDraft(state:scaling); scale.mode = .exact; scale.text = "40000x100"
  try check(scale.apply(),"hidden original backing limits do not veto active canvas scaling")
  original.density = 1
  try await until { owner.ownedViews.allSatisfy { !$0.isRendering && $0.displayedImage != nil } }
  let firstView = owner.ownedViews[0]
  try check(firstView.setFocus(true),"owned surface focus")
  try session.sendKey(id:2,keysym:0x62,down:true)
  try await until { native_test_peer_has_input(peer,1,0x62,0,0) != 0 }
  try check(native_test_peer_has_input(peer,1,0x78,0,0) == 0,"entry source input is absent after an owned-surface wire barrier")
  try commands.perform(.fullscreen)
  try check(owner.phase == .exiting && owner.ownedViews.allSatisfy(\.isHidden),"exit gates surfaces before transition")
  try check(!commands.canPerform(.fullscreen) && !commands.canPerform(.captureKeyboard),"exit gates duplicate commands")
  try await until { native_test_peer_has_input(peer,0,0x62,0,0) != 0 }
  owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:primary))
  try check(owner.phase == .windowed && owner.ownedViews.isEmpty && !source.isHidden && source.fullscreenOwnerID == nil && backend.shown.last === original && commands.isActiveHost(source),"exit restores source and command route")
  try check(!commands.isFullscreen && commands.fullscreenOwner == nil,"completed exit clears weak command owner")
  try owner.enter(.current,strategy:.nativeSpace)
  owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:primary))
  owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:primary))
  try check(owner.phase == .entering,"callbacks from disposed windows cannot complete a newer transition")
  let userWindow = owner.ownedWindows[0]
  owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:userWindow))
  owner.windowWillExitFullScreen(.init(name:NSWindow.willExitFullScreenNotification,object:userWindow))
  try check(owner.phase == .exiting && owner.ownedViews.allSatisfy(\.isHidden),"user-initiated native exit gates input")
  owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:userWindow))
  try check(owner.phase == .windowed && !source.isHidden,"user-initiated native exit restores source")
  let oldDisposed = backend.disposed.count
  backend.failAt = backend.made.count+1
  do { try owner.enter(.all,strategy:.nativeSpace); throw Failure(message:"factory failure accepted") }
  catch is NativeDisplayError {}
  try check(owner.phase == .windowed && backend.disposed.count == oldDisposed+1 && !source.isHidden && owner.ownedViews.isEmpty,"partial factory failure rolls back all owned resources")
  backend.failAt = Int.max
  try owner.enter(.selected([.init("missing")]),strategy:.borderless)
  try check(owner.phase == .active && owner.ownedViews.count == 1 && owner.canvasLayout?.regions.first?.id == backend.current && owner.missingDisplays == [.init("missing")] && owner.selection == .selected([.init("missing")]),"missing saved identities retain intent and fall back to current display")
  try commands.perform(.fullscreen); try check(owner.phase == .windowed && !source.isHidden,"borderless command exit restores immediately")
  try owner.enter(.selected([.init("a"),.init("missing")]),strategy:.borderless)
  try check(owner.canvasLayout?.regions.map(\.id) == [.init("a")],"surviving explicit selection takes priority over fallback")
  provider.values = [display("a",x:0,primary:true)]
  displays.refresh()
  try check(owner.phase == .windowed && owner.message == String(localized:"desktop.fullscreen.displays.changed.full.screen.was.closed.choose.displays.again", defaultValue:"Displays changed. Full screen was closed; choose displays again.") && !source.isHidden,"topology change rolls back instead of keeping stale screen geometry")
  provider.values = [display("a",x:0,primary:true),display("b",x:100)]; displays.refresh()
  try owner.enter(.current,strategy:.nativeSpace)
  owner.windowDidFailToEnterFullScreen(owner.ownedWindows[0])
  try check(owner.phase == .windowed && !source.isHidden,"native enter failure restores")
  try owner.enter(.current,strategy:.nativeSpace)
  owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:owner.ownedWindows[0]))
  owner.exit(); owner.windowDidFailToExitFullScreen(owner.ownedWindows[0])
  try check(owner.phase == .windowed && !source.isHidden,"native exit failure restores")
  owner.transitionTimeout = .milliseconds(20)
  try owner.enter(.current,strategy:.nativeSpace)
  try await until { owner.phase == .windowed }
  try check(owner.message == String(localized:"desktop.fullscreen.the.full.screen.transition.did.not.finish.try.again", defaultValue:"The full-screen transition did not finish. Try again.") && !source.isHidden,"bounded native transition timeout restores")
  owner.transitionTimeout = .seconds(15)
  try owner.enter(.all,strategy:.borderless)
  owner.windowWillClose(.init(name:NSWindow.willCloseNotification,object:owner.ownedWindows[0]))
  try check(owner.phase == .windowed && !source.isHidden,"owned window close exits whole group")
  var transient: NativeFullscreenController? = controller()
  try transient!.enter(.all,strategy:.borderless)
  let weakOwner = Reference(transient), weakWindow = Reference(transient!.ownedWindows[0])
  transient = nil
  try await until { weakOwner.value == nil && source.fullscreenOwnerID == nil && !source.isHidden }
  // Backend diagnostic arrays intentionally retain disposed windows; they must
  // no longer retain their views or delegates after owner destruction.
  try check(weakWindow.value?.contentView == nil && weakWindow.value?.delegate == nil,"deinit detaches window resources")
  try check(commands.fullscreenOwner == nil && !commands.isFullscreen,"command route does not retain destroyed owner")
  commands.onEnterFullscreen = { [weak owner] in
    guard let owner else { throw NativeDesktopCommandIssue.unavailable }
    try owner.enter(.current,strategy:.borderless)
  }
  try commands.perform(.fullscreen)
  try check(owner.phase == .active && commands.isFullscreen,"frontend entry policy routes through the same command")
  try commands.perform(.fullscreen)
  try check(owner.phase == .windowed && !commands.isFullscreen,"active Exit takes priority over the entry hook")
  commands.onEnterFullscreen = nil
  // Owned windows are temporary. Minimize must exit and target the original,
  // even though none of the owned fullscreen windows is miniaturizable.
  try owner.enter(.all,strategy:.nativeSpace)
  let minimizingPrimary = owner.ownedWindows[1]
  owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:minimizingPrimary))
  try check(commands.canPerform(.minimize),"owned fullscreen can minimize original window")
  original.styleMask.remove(.miniaturizable)
  try check(!commands.canPerform(.minimize),"original window capability gates owned minimize")
  original.styleMask.insert(.miniaturizable)
  original.simulatedSheet = minimizingPrimary
  try check(!commands.canPerform(.minimize),"original sheet gates owned minimize")
  original.simulatedSheet = nil
  try check(owner.ownedViews[1].setFocus(true),"minimize input route")
  try session.sendKey(id:3,keysym:0x63,down:true)
  try await until { native_test_peer_has_input(peer,1,0x63,0,0) != 0 }
  try commands.perform(.minimize)
  try check(owner.phase == .exiting && original.minimizeRequests == 0 && !commands.canPerform(.minimize),"owned minimize waits for native exit and gates duplicates")
  try await until { native_test_peer_has_input(peer,0,0x63,0,0) != 0 }
  owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:original))
  try check(original.minimizeRequests == 0,"unrelated exit cannot minimize source")
  owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:minimizingPrimary))
  owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:minimizingPrimary))
  try check(owner.phase == .windowed && original.minimizeRequests == 1 && commands.isMinimizing && !session.isFocused,"successful exit minimizes source once and keeps input gated")
  do { try owner.enter(.current,strategy:.borderless); throw Failure(message:"fullscreen reentry raced original minimize") }
  catch NativeDesktopCommandIssue.unavailable {}
  NotificationCenter.default.post(name:NSWindow.didMiniaturizeNotification,object:original)
  try check(!commands.isMinimizing,"original completion settles minimize")
  try owner.enter(.all,strategy:.borderless)
  try commands.perform(.minimize)
  try check(owner.phase == .windowed && original.minimizeRequests == 2 && commands.isMinimizing,"borderless disposes group before minimizing source")
  NotificationCenter.default.post(name:NSWindow.didMiniaturizeNotification,object:original)
  for cancellation in 0..<4 {
    try owner.enter(.current,strategy:.nativeSpace)
    let window = owner.ownedWindows[0]
    owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:window))
    if cancellation == 2 { owner.transitionTimeout = .milliseconds(20) }
    try commands.perform(.minimize)
    switch cancellation {
    case 0:
      original.simulatedSheet = window
      owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:window))
      original.simulatedSheet = nil
    case 1: owner.windowDidFailToExitFullScreen(window)
    case 2: try await until { owner.phase == .windowed }; owner.transitionTimeout = .seconds(15)
    default:
      provider.values = [display("a",x:0,primary:true)]; displays.refresh()
      provider.values = [display("a",x:0,primary:true),display("b",x:100)]; displays.refresh()
    }
    owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:window))
    try check(owner.phase == .windowed && original.minimizeRequests == 2 && !commands.isMinimizing,"sheet, failure, deadline and topology cancellation cannot carry stale minimize intent")
  }
  try owner.enter(.all,strategy:.nativeSpace)
  owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:owner.ownedWindows[1]))
  try commands.perform(.minimize)
  _ = try await session.disconnect()
  try check(owner.phase == .windowed && !source.isHidden && original.delegate === originalDelegate && original.minimizeRequests == 2,"disconnect cancels owned minimize without replacing source delegate")
  try await session.close(); try await runtime.shutdown()
  print("PASS fullscreen strategies, scoped windows, shared canvas, focus release, transition failure/deadline, topology and joined cleanup")
}
@main struct Main {
  static func main() async {
    do { try backendConstruction(); try await run() } catch { print("FAIL \(error)"); exit(1) }
  }
}
