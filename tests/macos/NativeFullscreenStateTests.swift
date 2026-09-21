// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
@MainActor func until(_ condition: () -> Bool, line: UInt = #line) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Fullscreen state timeout at \(line)")
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"Unexpected write") }
}
func display(_ id: String, x: Double, primary: Bool = false) -> NativeDisplay {
  let bounds = NativeDisplayRectangle(x:x,y:0,width:100,height:100)
  return .init(id:.init(id),name:primary ? "External display" : "Retina display",bounds:bounds,workArea:bounds,backingScale:primary ? 1 : 2,isPrimary:primary)
}
@MainActor final class Displays: NativeDisplaySource {
  var values = [display("a",x:-100),display("b",x:0,primary:true)]
  func read() throws -> [NativeDisplay] { values }
}
@MainActor final class Window: NSWindow {
  var minimized = false
  var fixtureSheet: NSWindow?
  override var attachedSheet: NSWindow? { fixtureSheet }
  override var isMiniaturized: Bool { minimized }
  override var isVisible: Bool { true }
  override var backingScaleFactor: CGFloat { 1 }
}
@MainActor final class Backend: NativeFullscreenWindows {
  var made: [NSWindow] = [], toggled: [NSWindow] = []
  func currentDisplay(_ window: NSWindow) -> NativeDisplayID? { .init("b") }
  func makeWindow(display: NativeDisplay, primary: Bool, strategy: NativeFullscreenStrategy) throws -> NSWindow {
    let window = Window(contentRect:.init(x:display.bounds.x,y:0,width:100,height:100),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; made.append(window); return window
  }
  func show(_ window: NSWindow, focus: Bool) {}
  func hide(_ window: NSWindow) {}
  func toggleNative(_ window: NSWindow) { toggled.append(window) }
  func dispose(_ window: NSWindow) { window.close() }
  func owner() throws -> (NativeFullscreenController,NSWindow) {
    guard let window = toggled.last, let owner = window.delegate as? NativeFullscreenController else { throw Failure(message:"No owned primary") }
    return (owner,window)
  }
}
@MainActor final class Delegate: NSObject, NSWindowDelegate {}
@MainActor func capture(_ draft: NativeFullscreenDraft, directory: URL, name: String, dark: Bool) async throws {
  let view = NSHostingView(rootView:FullscreenSettingsSheet(model:draft,dismiss:{}).environment(\.colorScheme,dark ? .dark : .light).background(Color(nsColor:.windowBackgroundColor)))
  let window = NSWindow(contentRect:.init(x:0,y:0,width:560,height:730),styleMask:[.titled],backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); window.contentView = view
  defer { window.contentView = nil; window.close() }
  view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(50)); view.layoutSubtreeIfNeeded()
  try check(view.fittingSize.width <= 560 && view.fittingSize.height <= 730,"fullscreen sheet fits")
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"No bitmap") }
  view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
  guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw Failure(message:"No PNG") }
  try bytes.write(to:directory.appendingPathComponent(name+(dark ? "-dark" : "")+".png"))
}
@MainActor func run() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing:Preferences())
  let provider = Displays(), displays = NativeDisplayService(source:provider,notifications:NotificationCenter(),workspaceNotifications:NotificationCenter())
  let backend = Backend(), state = NativeFullscreenState(windows:backend)
  let model = ConnectionModel(runtime:runtime,preferences:preferences,fullscreen:state,displays:displays,onSession:{_,_ in})
  try await until { model.session != nil }
  let session = model.session!, source = NativeDesktopView(frame:.init(x:0,y:0,width:320,height:240))
  let window = Window(contentRect:source.bounds,styleMask:[.titled,.resizable,.miniaturizable],backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false; window.collectionBehavior = [.fullScreenPrimary]; let behavior = window.collectionBehavior
  let delegate = Delegate(); window.delegate = delegate; window.contentView = source
  source.bind(session); source.observeScaling(model.scaling); source.observeInput(model.input); source.observeCommands(model.desktopCommands); source.observeFullscreen(state)
  defer { source.detach(); window.delegate = nil; window.contentView = nil; window.close(); displays.stop() }
  try check(window.collectionBehavior.contains(.fullScreenNone) && window.delegate === delegate,"source attaches without replacing SwiftUI delegate")
  try check(!model.desktopCommands.canPerform(.fullscreen),"configured fullscreen entry requires a connected desktop")
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  model.endpoint = "127.0.0.1::\(native_test_peer_port(peer))"; model.connect()
  try await until { session.snapshot.state == .connected && !model.busy && source.displayedSequence == session.frame?.sequence }
  model.openFullscreen()
  guard let draft = model.fullscreenDraft else { throw Failure(message:"No fullscreen draft") }
  draft.mode = .selected
  try check(!draft.canApply && draft.validationMessage?.contains("Select") == true,"empty selection rejected")
  draft.selectedDisplays = [.init("a"),.init("missing")]
  try check(draft.canApply && draft.chosenDisplays.map(\.id) == [.init("a")] && draft.missing == [.init("missing")],"surviving IDs preserve missing intent")
  let directory = URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory(),isDirectory:true)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  for dark in [false,true] { try await capture(draft,directory:directory,name:"selected",dark:dark) }
  try check(draft.apply(),"apply selected displays"); model.closeFullscreen()
  let saved = state.selection
  let stale = NativeFullscreenDraft(state:state), newer = NativeFullscreenDraft(state:state)
  newer.mode = .all; try check(newer.apply(),"new selection revision")
  stale.mode = .current; try check(!stale.canApply && !stale.apply(),"stale draft cannot overwrite selection")
  let topology = NativeFullscreenDraft(state:state); topology.mode = .selected; topology.selectedDisplays = [.init("missing")]
  provider.values = [display("b",x:0,primary:true)]; displays.refresh()
  try check(topology.needsReview && !topology.apply(),"topology must be reviewed")
  topology.reviewDisplays()
  try check(topology.canApply && topology.chosenDisplays.map(\.id) == [.init("b")] && topology.apply(),"all missing selection falls back without rewriting IDs")
  try check(state.selection == .selected([.init("missing")]),"missing intent retained")
  provider.values = [display("a",x:-100),display("b",x:0,primary:true)]; displays.refresh()
  let all = NativeFullscreenDraft(state:state); all.mode = .all; try check(all.apply(),"restore all displays")
  var activations = 0; state.onActivate = { activations += 1 }
  func enter() throws -> (NativeFullscreenController,NSWindow) {
    model.performDesktop(.fullscreen)
    try check(state.phase == .entering,"model command enters owned fullscreen")
    let (owner,primary) = try backend.owner()
    owner.windowDidBecomeKey(.init(name:NSWindow.didBecomeKeyNotification,object:primary))
    owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:primary))
    return (owner,primary)
  }
  model.toggleStatistics()
  try check(model.showsStatistics && state.showsStatistics,"windowed toggle reaches fullscreen policy")
  let (owner,primary) = try enter()
  try check(owner.showsStatistics && owner.ownedWindows.allSatisfy { ($0.contentView as? NativeFullscreenContentView)?.statisticsView != nil },"statistics follows entry onto every display")
  model.toggleStatistics()
  try check(!model.showsStatistics && state.phase == .active && !state.waitingForWindow && owner.ownedWindows.allSatisfy { ($0.contentView as? NativeFullscreenContentView)?.statisticsView == nil },"model hides statistics in place without queuing exit")
  model.toggleStatistics()
  try check(model.showsStatistics && owner.showsStatistics && state.phase == .active,"model shows fullscreen statistics in place")
  try check(activations == 1 && state.phase == .active && owner.ownedWindows.count == 2,"owned activation routes the active connection")
  owner.windowDidBecomeKey(.init(name:NSWindow.didBecomeKeyNotification,object:window))
  try check(activations == 1,"unrelated window activation cannot select this connection")
  model.openInput()
  try check(model.inputDraft == nil && state.waitingForWindow && state.phase == .exiting,"sheet waits for source window restoration")
  model.openScaling(); try check(model.scalingDraft == nil,"only one deferred sheet is admitted")
  owner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:primary))
  try await until { model.inputDraft != nil }
  try check(state.phase == .windowed && !state.waitingForWindow && !model.canOpenFullscreen && window.delegate === delegate,"deferred sheet uses restored source and normal arbitration")
  model.closeInput()
  let (failedOwner,failedPrimary) = try enter(); model.openScaling()
  failedOwner.windowDidFailToExitFullScreen(failedPrimary)
  try await until { model.scalingDraft != nil }
  try check(state.message != nil && !state.waitingForWindow,"failed native exit restores source before presenting requested sheet")
  model.closeScaling()
  let (errorOwner,errorPrimary) = try enter(); model.message = "Fixture command error"
  try check(state.phase == .exiting && state.waitingForWindow,"desktop error exits fullscreen before alert presentation")
  errorOwner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:errorPrimary))
  try await until { !state.waitingForWindow }
  try check(model.message == "Fixture command error","error retained for restored SwiftUI host"); model.message = nil
  let (closedOwner,closedPrimary) = try enter(); model.openInformation()
  NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:window)
  closedOwner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:closedPrimary))
  try check(!state.waitingForWindow && model.informationID == nil,"original close revokes deferred sheet even before view detach")
  let (closingOwner,closingPrimary) = try enter(); model.openInformation()
  _ = try await session.disconnect()
  closingOwner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:closingPrimary))
  try await until { state.phase == .windowed && !state.waitingForWindow }
  try check(!model.showsStatistics && !state.showsStatistics && model.informationID == nil && state.selection == .all && saved != state.selection,"disconnect cancels deferred presentation but retains selection")
  let replacement = NativeFullscreenState(windows:backend)
  replacement.bind(session:session,displays:displays,scaling:model.scaling,input:model.input,commands:model.desktopCommands)
  source.observeFullscreen(replacement); state.stop()
  try check(model.desktopCommands.onEnterFullscreen != nil && window.collectionBehavior.contains(.fullScreenNone),"old state cannot remove replacement entry policy or window ownership")
  replacement.stop(); source.observeFullscreen(nil)
  try check(window.collectionBehavior == behavior,"detach restores original window behavior")
  await model.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS connection fullscreen selection, missing IDs, revisions/topology, owned commands, active connection routing, deferred sheets and replacement cleanup")
}

@MainActor func startupAndReconnect() async throws {
  let runtime = try NativeRuntime()
  var configuration = NativeSessionConfiguration()
  configuration.fullscreenPolicy = try .init(startsFullscreen:true,mode:.selected,selectedDisplays:[.init("missing")])
  configuration.fullscreenSources = [.startsFullscreen:.appDefaults,.mode:.profile,.selectedDisplays:.profile]
  configuration.windowStartupPolicy = .init(geometry:try NativeWindowGeometry("480x300+100+100"))
  let session = try runtime.makeSession(configuration:configuration)
  let scaling = NativeScalingState(), input = NativeInputState(), commands = NativeDesktopCommands()
  scaling.bind(session); input.bind(session); commands.bind(session)
  let provider = Displays(), displays = NativeDisplayService(source:provider)
  let backend = Backend(), state = NativeFullscreenState(windows:backend)
  var eligible = false; state.automaticEntryEligibility = { eligible }
  state.bind(session:session,displays:displays,scaling:scaling,input:input,commands:commands)
  let source = NativeDesktopView(frame:.init(x:0,y:0,width:160,height:120))
  let original = Window(contentRect:source.bounds,styleMask:[.titled,.resizable,.miniaturizable],backing:.buffered,defer:false)
  original.isReleasedWhenClosed = false
  var peers: [UnsafeMutableRawPointer] = []
  defer {
    state.stop(); source.detach(); original.contentView = nil; original.close()
    scaling.stop(); input.stop(); commands.stop(); displays.stop()
    peers.forEach { native_test_peer_destroy($0) }
  }
  func connect() async throws {
    let peer = native_test_peer_create_pattern(0)!; peers.append(peer)
    _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
    try await until { session.snapshot.state == .connected }
  }
  func activate() throws -> (NativeFullscreenController,NSWindow) {
    let (owner,window) = try backend.owner()
    owner.windowDidEnterFullScreen(.init(name:NSWindow.didEnterFullScreenNotification,object:window))
    try check(state.phase == .active,"startup completion activates owned group")
    return (owner,window)
  }
  func notify() { NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:original) }
  func settle() async throws { try await Task.sleep(for:.milliseconds(40)) }
  try await connect(); try await settle()
  try check(backend.made.isEmpty,"startup waits for source attachment")
  original.contentView = source; source.bind(session); source.observeScaling(scaling); source.observeInput(input); source.observeCommands(commands); source.observeFullscreen(state)
  let initialContent = original.contentRect(forFrameRect:original.frame)
  try check(state.windowStartup.resolved && abs(initialContent.width-480) < 1 && abs(initialContent.height-300) < 1,
            "initial geometry resolves before automatic fullscreen is eligible")
  try await settle(); try check(backend.made.isEmpty,"background window does not steal focus")
  eligible = true; source.isHidden = true; notify(); try await settle()
  try check(backend.made.isEmpty,"hidden source cannot auto-enter")
  source.isHidden = false; original.minimized = true; notify(); try await settle()
  try check(backend.made.isEmpty,"minimized source waits without entering")
  original.minimized = false; original.fixtureSheet = NSWindow(contentRect:.zero,styleMask:[],backing:.buffered,defer:false)
  original.fixtureSheet?.isReleasedWhenClosed = false; notify(); try await settle()
  try check(backend.made.isEmpty,"attached sheet prevents startup")
  original.fixtureSheet?.close(); original.fixtureSheet = nil
  NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:original)
  try await until { state.phase == .entering }
  let (first,firstWindow) = try activate()
  try check(first.ownedWindows.count == 1 && state.selection == .selected([.init("missing")]),"startup fallback keeps missing saved IDs")
  notify(); try await settle(); try check(backend.made.count == 1,"repeated notifications cannot duplicate entry")
  _ = try await session.disconnect(); try await until { state.phase == .windowed }
  original.setContentSize(NSSize(width:380,height:250)); let editedFrame = original.frame
  try await connect(); try await until { state.phase == .entering }
  try check(original.frame == editedFrame,"reconnect/fullscreen cannot replay initial placement over a user resize")
  let (second,secondWindow) = try activate()
  first.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:firstWindow))
  try check(state.phase == .active,"stale callback cannot cancel reconnect owner")
  try commands.perform(.fullscreen)
  // Disconnect before the native exit callback must still honor explicit exit.
  _ = try await session.disconnect(); try await until { state.phase == .windowed }
  second.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:secondWindow))
  try await connect(); notify(); try await settle()
  try check(state.phase == .windowed && backend.made.count == 2,"explicit exit intent survives a disconnect during transition")
  let draft = NativeFullscreenDraft(state:state); draft.mode = .all; draft.startsFullscreen = false
  try check(draft.source(.startsFullscreen) == .session && draft.source(.mode) == .session && draft.source(.selectedDisplays) == .profile,"draft changes only edited field sources")
  try check(draft.apply() && state.policy.selectedDisplays == [.init("missing")],"inactive selected IDs survive live Apply")
  let next = NativeFullscreenDraft(state:state); next.startsFullscreen = true; try check(next.apply(),"enable next attempt locally")
  try check(state.phase == .windowed,"startup edit does not enter immediately")
  _ = try await session.disconnect(); try await connect(); try await until { state.phase == .entering }
  let (failed,failedWindow) = try backend.owner(); failed.windowDidFailToEnterFullScreen(failedWindow)
  let count = backend.made.count; notify(); try await settle()
  try check(state.phase == .windowed && state.message != nil && backend.made.count == count,"failed startup is not retried by focus notifications")
  _ = try await session.disconnect(); try await connect(); notify(); try await settle()
  try check(backend.made.count == count,"failed startup clears reconnect intent")
  try commands.perform(.fullscreen); _ = try activate()
  var presented = false
  try check(!state.prepareForSettings { presented = true },"settings requests leave fullscreen")
  let (settingsOwner,settingsWindow) = try backend.owner()
  settingsOwner.windowDidExitFullScreen(.init(name:NSWindow.didExitFullScreenNotification,object:settingsWindow))
  try await until { presented }
  _ = try await session.disconnect(); try await connect(); notify(); try await settle()
  try check(state.phase == .windowed,"settings exit keeps reconnect windowed")
  try commands.perform(.fullscreen); _ = try activate()
  provider.values = [display("b",x:0,primary:true)]; displays.refresh()
  try check(state.phase == .windowed,"topology change closes active group")
  _ = try await session.disconnect(); try await connect(); notify(); try await settle()
  try check(state.phase == .windowed,"topology cancellation does not silently re-enter on reconnect")
  // Queue a startup while backgrounded, then cancel it before foreground return.
  let off = NativeFullscreenDraft(state:state); off.startsFullscreen = false; try check(off.apply(),"disable startup")
  let on = NativeFullscreenDraft(state:state); on.startsFullscreen = true; try check(on.apply(),"arm startup")
  eligible = false; _ = try await session.disconnect(); try await connect(); try await settle()
  let beforeStop = backend.made.count; state.stop(); eligible = true; notify(); try await settle()
  try check(backend.made.count == beforeStop,"stop cancels queued automatic entry")
  try await session.close(); try await runtime.shutdown()
  print("PASS saved startup, delayed attachment/focus, reconnect restore, explicit exit race, failure/settings cancellation and session sources")
}
@main struct Main {
  static func main() async { do { try await run(); try await startupAndReconnect() } catch { print("FAIL \(error)"); exit(1) } }
}
