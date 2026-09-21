// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Shared canvas timeout")
}
@MainActor final class Window: NSWindow {
  var density = 1.0
  override var backingScaleFactor: CGFloat { density }
}
@MainActor final class Reference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
func display(_ id: String, x: Double, scale: Double = 1) -> NativeDisplay {
  let bounds = NativeDisplayRectangle(x:x,y:0,width:100,height:100)
  return .init(id:.init(id),name:id,bounds:bounds,workArea:bounds,backingScale:scale,isPrimary:x == 0)
}
@MainActor func apply(_ state: NativeScalingState, text: String, device: Bool = false) throws {
  let draft = NativeScalingDraft(state:state)
  let candidate = try NativeScaling(text,devicePixels:device)
  draft.mode = candidate.mode; draft.text = text; draft.devicePixels = device
  try check(draft.apply(),"shared scale applies: \(String(describing:draft.issue))")
}
@MainActor func exercise() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), session = try runtime.makeSession(), other = try runtime.makeSession()
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.frame != nil }
  let state = NativeScalingState(); state.bind(session)
  let left = NativeDesktopView(frame:.init(x:0,y:0,width:100,height:100))
  let right = NativeDesktopView(frame:left.frame)
  let windows = [left,right].map { view in
    let window = Window(contentRect:view.bounds,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = view; return window
  }
  defer { left.detach(); right.detach(); state.stop(); for window in windows { window.contentView = nil; window.close() } }
  left.bind(session); right.bind(session); left.observeScaling(state); right.observeScaling(state)
  try await until { !left.isRendering && !right.isRendering && left.displayedImage != nil && right.displayedImage != nil }
  // Registration order cannot hide an earlier surface's stricter backing limit.
  windows[0].density = 2
  let rejected = NativeScalingDraft(state:state); rejected.mode = .exact; rejected.text = "40000x100"
  let baseline = state.value, revision = state.revision
  try check(!rejected.apply() && rejected.issue == .dimensions && state.value == baseline && state.revision == revision,
    "all registered views preflight before committing state")
  windows[0].density = 1
  try apply(state,text:"600x300")
  let first = display("left",x:0,scale:2), second = display("right",x:100)
  var canvas: NativeDesktopCanvas? = try NativeDesktopCanvas(session:session,scaling:state)
  var errors: [String] = []; canvas!.onError = { errors.append($0) }
  try canvas!.configure([(first,left),(second,right)])
  try await until { !left.isRendering && !right.isRendering }
  try check(canvas!.layout?.width == 200 && left.desktopRectangle.minX == 0 && right.desktopRectangle.minX == -100,"one mapped layout for both surfaces")
  var bypassErrors = 0; left.onError = { _ in bypassErrors += 1 }
  left.scaling = "Auto"; left.devicePixels = true; left.filter = .area
  try check(bypassErrors == 3 && left.scaling == state.value.canonical && left.devicePixels == state.value.devicePixels && left.filter == state.value.filter,
    "direct per-view scale/filter writes cannot bypass group preflight")
  left.onError = nil
  try check(right.panDesktop(.right),"right surface command pans group")
  try await until { !left.isRendering && !right.isRendering }
  try check(canvas!.pan.x == 80 && left.pan.x == 80 && right.pan.x == 80 && left.desktopRectangle.minX == -80 && right.desktopRectangle.minX == -180,
    "pan from either member changes both regions")
  left.pan = .init(x:350,y:50)
  try await until { !left.isRendering && !right.isRendering }
  try check(canvas!.pan == left.pan && left.pan == right.pan && right.desktopRectangle.minX == -450,"direct pan follows coordinator")
  let quality = NativeScalingDraft(state:state); quality.filter = .nearest
  try check(quality.apply() && canvas!.pan.x == 350 && left.pan == right.pan && left.filter == .nearest && right.filter == .nearest,"filter-only apply preserves shared pan")
  try canvas!.setPan(.init(x:65535,y:65535))
  try check(canvas!.pan == .init(x:400,y:200) && left.pan == right.pan,"pan clamps against whole canvas")
  let oldLayout = canvas!.layout, oldPan = canvas!.pan
  do { try canvas!.setPan(.init(x:Double.infinity,y:0)); throw Failure(message:"invalid pan accepted") }
  catch let error as NativeError { try check(error.status == .invalidArgument,"typed pan failure") }
  do { try canvas!.configure([(first,left),(second,left)]); throw Failure(message:"duplicate surface accepted") }
  catch let error as NativeError { try check(error.status == .invalidArgument,"typed membership failure") }
  let foreign = NativeDesktopView(frame:left.frame); foreign.bind(other)
  do { try canvas!.configure([(first,left),(second,foreign)]); throw Failure(message:"foreign session accepted") }
  catch let error as NativeError { try check(error.status == .invalidArgument,"session membership failure") }
  foreign.detach()
  try check(canvas!.layout == oldLayout && canvas!.pan == oldPan && left.pan == right.pan,"rejected candidates preserve group")
  do { try left.setCanvasViewport(nil); throw Failure(message:"individual region bypass accepted") }
  catch let error as NativeError { try check(error.status == .busy,"managed viewport cannot bypass group") }
  try apply(state,text:"600x300",device:true)
  try check(canvas!.layout?.width == 300 && canvas!.layout?.devicePixels == true && left.canvasViewport?.region.width == 200 && right.canvasViewport?.region.x == 200 && left.pan == .zero && right.pan == .zero,
    "device units recompute complete mixed-density mapping and reset shared pan")
  try apply(state,text:"Auto",device:true)
  try check(canvas!.layout?.width == 200 && canvas!.layout?.devicePixels == false && right.canvasViewport?.region.x == 100,"fitting modes use retained logical monitor policy")
  try apply(state,text:"600x300")
  windows[1].density = 2
  let overflow = NativeScalingDraft(state:state); overflow.mode = .exact; overflow.text = "40000x100"
  let before = state.value, previousLayout = canvas!.layout
  try check(!overflow.apply() && overflow.issue == .dimensions && state.value == before && canvas!.layout == previousLayout && left.scaling == "600x300" && right.scaling == "600x300",
    "group preflight prevents a partial scale change")
  windows[1].density = 1
  // Failed topology reconfiguration also preserves all existing region assignments.
  do { try canvas!.configure([(first,left),(display("overlap",x:50),right)]); throw Failure(message:"overlap accepted") }
  catch is NativeError {}
  try check(canvas!.layout == previousLayout && right.canvasViewport?.region.x == 100,"topology failure preserves regions")
  try canvas!.configure([(display("left",x:100),left),(display("right",x:0),right)])
  try check(left.canvasViewport?.region.x == 100 && right.canvasViewport?.region.x == 0,"explicit topology swap applies complete mapping")
  right.detach()
  try apply(state,text:"500x300")
  try check(canvas!.layout?.width == 200 && left.canvasViewport?.region.x == 100 && right.canvasViewport == nil,"detaching one surface preserves remaining display coordinates")
  right.bind(session); right.observeScaling(state)
  try canvas!.configure([(first,left),(second,right)])
  var transient: NativeDesktopView? = NativeDesktopView(frame:left.frame)
  transient!.bind(session); let surfaceReference = Reference(transient)
  try canvas!.configure([(first,transient!),(second,right)])
  transient = nil
  try await until { surfaceReference.value == nil }
  try apply(state,text:"550x300")
  try check(right.canvasViewport?.region.x == 100 && canvas!.layout?.width == 200,"group and scaling registry do not retain destroyed surfaces or reflow their peers")
  try canvas!.configure([(first,left),(second,right)])
  let reference = Reference(canvas); canvas = nil
  try await until { reference.value == nil && left.canvasViewport == nil && right.canvasViewport == nil }
  try check(left.canvasCoordinator == nil && right.canvasCoordinator == nil,"weak ownership and destruction restore windowed views")
  var old: NativeDesktopCanvas? = try NativeDesktopCanvas(session:session,scaling:state)
  try old!.configure([(first,left),(second,right)]); old = nil
  let replacement = try NativeDesktopCanvas(session:session,scaling:state)
  try replacement.configure([(first,left),(second,right)])
  await Task.yield(); await Task.yield()
  try check(left.canvasCoordinator === replacement && right.canvasCoordinator === replacement && left.canvasViewport != nil,"old deferred cleanup cannot clear replacement group")
  try replacement.setPan(.init(x:200,y:100))
  _ = try await session.disconnect()
  try check(replacement.pan == .zero && left.pan == .zero && right.pan == .zero,"disconnect clears shared pan")
  try await session.close(); try await other.close(); try await runtime.shutdown()
  try check(replacement.layout == nil && left.canvasViewport == nil && right.canvasViewport == nil && errors.isEmpty,"close cleans up group")
  print("PASS all-surface preflight, shared pan/scaling/units, topology transaction, membership, lifetime and close")
}
@MainActor func resizeClamp() async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_resize_peer_create()!; defer { native_resize_peer_destroy(peer) }
  let state = NativeScalingState(); state.bind(session); try apply(state,text:"100")
  // Register the coordinator before the views, reversing the image-subscriber
  // order in exercise(). Both orders must converge on the current frame's bound.
  let canvas = try NativeDesktopCanvas(session:session,scaling:state)
  let left = NativeDesktopView(frame:.init(x:0,y:0,width:100,height:100)), right = NativeDesktopView(frame:.init(x:0,y:0,width:100,height:100))
  defer { left.detach(); right.detach(); canvas.stop(); state.stop() }
  left.bind(session); right.bind(session)
  try canvas.configure([(display("a",x:0),left),(display("b",x:100),right)])
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { session.snapshot.supportsResize }
  func resize(_ width: UInt32, _ height: UInt32) async throws {
    let layout = try NativeRemoteLayout(width:width,height:height,screens:[.init(id:7,x:0,y:0,width:width,height:height,flags:9)])
    _ = try await session.requestDesktopLayout(layout,expectedGeneration:session.generation)
    try await until { session.frame?.width == width && left.displayedSequence == session.frame?.sequence && right.displayedSequence == session.frame?.sequence && !left.isRendering && !right.isRendering }
  }
  try await resize(800,400)
  try canvas.setPan(.init(x:500,y:200))
  try check(left.pan == right.pan && canvas.pan.x == 500,"large frame admits shared pan")
  try await resize(300,200)
  try check(canvas.pan == .init(x:100,y:100) && left.pan == canvas.pan && right.pan == canvas.pan && left.desktopRectangle.minX == -100 && right.desktopRectangle.minX == -200,
    "remote shrink clamps every surface to the same global bound")
  try await resize(800,400)
  try check(canvas.pan == .init(x:100,y:100) && left.pan == right.pan,"remote growth cannot resurrect discarded pan")
  try await session.close(); try await runtime.shutdown()
  print("PASS shared pan clamps across actual remote resize without restoring stale offsets")
}
@main struct Main {
  static func main() async {
    do { try await exercise(); try await resizeClamp() } catch { print("FAIL \(error)"); exit(1) }
  }
}
