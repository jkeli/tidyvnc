// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
@MainActor func until(_ condition: () async -> Bool) async throws {
  for _ in 0..<2500 { if await condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Canvas timeout")
}
func canvas(_ x: UInt32, width: UInt32 = 400, region: UInt32 = 200, device: Bool = false) throws -> NativeCanvasViewport {
  try .init(width:width,height:200,region:.init(x:x,y:0,width:region,height:200),devicePixels:device)
}
func geometry() throws {
  for scale in [1.0,1.25,1.5,2.0,3.0] {
    for device in [false,true] {
      for mode in ["100","Auto","FixedRatio","FitWidth","FitHeight","600x400","137.5","125%x80%"] {
        let region = try canvas(200,device:device)
        let q = device ? scale : 1
        let view = CGSize(width:200/q,height:200/q)
        let actual = try NativeGeometry(width:800,height:500,viewport:view,backingScale:scale,
          scaling:mode,pan:.init(x:65535,y:65535),canvas:region)
        // A region translates the exact same shared global transform. Test the
        // inverse and damage against a complete-canvas observation, not Swift math.
        let global = try NativeGeometry(width:800,height:500,viewport:.init(width:400/q,height:200/q),backingScale:scale,
          scaling:mode,devicePixels:device,pan:actual.panPosition)
        try check(actual.backingWidth == global.backingWidth && actual.backingHeight == global.backingHeight,"global scaling does not refit each monitor")
        try check(abs(actual.rectangle.minX - global.rectangle.minX + 200/q) <= 1/scale,"region translates shared image origin")
        let localPoint = try actual.remotePoint(.init(x:30/q,y:40/q))
        let globalPoint = try global.remotePoint(.init(x:230/q,y:40/q))
        try check(abs(localPoint.x-globalPoint.x) <= 1 && abs(localPoint.y-globalPoint.y) <= 1,"inverse mapping agrees across region seam")
        let clamped = try NativeGeometry(width:800,height:500,viewport:view,backingScale:scale,
          scaling:mode,pan:actual.panPosition,canvas:region)
        try check(clamped.rectangle == actual.rectangle && actual.panned(.right) == actual.panPosition,"global pan bound matches shared placement")
        for filter in [NativeScalingFilter.nearest,.bilinear,.area] {
          let patch = NativePixelRect(x:100,y:70,width:20,height:40)
          let a = try actual.damageRectangle(patch,filter:filter), b = try global.damageRectangle(patch,filter:filter)
          try check(abs(a.minX - b.minX + 200/q) <= 2 && a.minY == b.minY && abs(a.width-b.width) <= 1,"damage and filter halo follow region transform")
        }
      }
    }
  }
  // The shared device canvas retains identity across a 2x/1x seam.
  let a = NativeDisplayRectangle(x:0,y:0,width:101,height:77)
  let b = NativeDisplayRectangle(x:101,y:0,width:201,height:155)
  let layout = try NativeDisplayLayout(displays:[
    .init(id:.init("a"),name:"a",bounds:a,workArea:a,backingScale:2,isPrimary:true),
    .init(id:.init("b"),name:"b",bounds:b,workArea:b,backingScale:1,isPrimary:false)],devicePixels:true)
  for region in layout.regions {
    let q = region.display.backingScale
    let g = try NativeGeometry(width:layout.width,height:layout.height,
      viewport:.init(width:region.display.bounds.width,height:region.display.bounds.height),backingScale:q,
      scaling:"100",canvas:layout.viewport(for:region.id))
    try check(g.isIdentity,"per-display identity in device units")
    let first = try g.remotePoint(.init(x:0.5/q,y:0.5/q))
    let last = try g.remotePoint(.init(x:(Double(region.width)-0.5)/q,y:0.5/q))
    try check(first.x == region.x && first.y == region.y && last.x == region.x+region.width-1,"exact seam coordinates at each density")
  }
  for bad in [NativePixelRect(x:400,y:0,width:1,height:1),.init(x:0,y:0,width:0,height:1),.init(x:0,y:199,width:1,height:2),.init(x:UInt32.max,y:0,width:1,height:1)] {
    do { _ = try NativeCanvasViewport(width:400,height:200,region:bad,devicePixels:false); throw Failure(message:"invalid region accepted") }
    catch let error as NativeError { try check(error.status == .invalidArgument,"shared canvas validation") }
  }
  print("PASS canvas geometry across eight modes, fractional scales, units, global pan bounds, damage and mixed-density seams")
}
actor GatedRenderer: NativeTileRendering {
  let renderer = try! NativeTileRenderer()
  var held = false
  private(set) var waiting = false
  private var continuation: CheckedContinuation<Void,Never>?
  func hold() { held = true }
  func release() { held = false; waiting = false; let old = continuation; continuation = nil; old?.resume() }
  func render(_ request: NativeTileRequest) async throws -> NativeTileBatch {
    if held { waiting = true; await withCheckedContinuation { continuation = $0 } }
    return try await renderer.render(request)
  }
  func clear() async throws { try await renderer.clear() }
}
@MainActor func color(_ view: NativeDesktopView, x: Double, y: Double) throws -> NSColor {
  // Render directly into sRGB instead of round-tripping through a potentially
  // narrower physical display profile and irreversibly clipping source colors.
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)?.converting(to:.sRGB,renderingIntent:.default) else { throw Failure(message:"No canvas bitmap") }
  bitmap.size = view.bounds.size
  view.cacheDisplay(in:view.bounds,to:bitmap)
  guard let normalized = bitmap.converting(to:.sRGB,renderingIntent:.default),
        let color = normalized.colorAt(x:Int(x*Double(bitmap.pixelsWide)/view.bounds.width),y:Int(y*Double(bitmap.pixelsHigh)/view.bounds.height))?.usingColorSpace(.sRGB)
  else { throw Failure(message:"No canvas sample") }
  return color
}
@MainActor func move(_ view: NativeDesktopView, x: Double, y: Double) {
  view.mouseMoved(with:NSEvent.mouseEvent(with:.mouseMoved,location:view.convert(.init(x:x,y:y),to:nil),modifierFlags:[],
    timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!)
}
@MainActor func presentation() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  let left = NativeDesktopView(frame:.init(x:0,y:0,width:200,height:200)), right = NativeDesktopView(frame:.init(x:0,y:0,width:200,height:200))
  let windows = [left,right].map { view in
    let window = NSWindow(contentRect:view.bounds,styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = view; return window
  }
  defer { left.detach(); right.detach(); for window in windows { window.contentView = nil; window.close() } }
  let renderer = GatedRenderer(); right.rendererOverride = renderer
  left.bind(session); right.bind(session)
  left.scaling = "Auto"; right.scaling = "Auto"; left.filter = .nearest; right.filter = .nearest
  try left.setCanvasViewport(canvas(0)); try right.setCanvasViewport(canvas(200))
  var errors: [String] = []; left.onError = { errors.append($0) }; right.onError = { errors.append($0) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
  try await until { (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]) }
  try await until { left.displayedImage != nil && right.displayedImage != nil &&
    left.displayedSequence == session.frame?.sequence && right.displayedSequence == session.frame?.sequence && !left.isRendering && !right.isRendering }
  try check(left.desktopRectangle == .init(x:0,y:0,width:400,height:200) && right.desktopRectangle == .init(x:-200,y:0,width:400,height:200),"two surfaces crop one global transform")
  let red = try color(left,x:50,y:50), green = try color(right,x:50,y:50)
  let blue = try color(left,x:50,y:150), white = try color(right,x:50,y:150)
  // The display-profile round trip can add up to 0.2 in a non-dominant channel.
  // Check unambiguous quadrant colors, not an exact unprofiled byte match.
  try check(red.redComponent > 0.9 && red.greenComponent < 0.3 && green.greenComponent > 0.9 && green.redComponent < 0.1 &&
    blue.blueComponent > 0.9 && blue.redComponent < 0.1 && white.redComponent > 0.9 && white.greenComponent > 0.9,"displayed quadrants belong to their respective regions: \(red), \(green), \(blue), \(white)")
  try session.setFocused(true); move(left,x:100,y:50)
  try await until { native_test_peer_has_input(peer,5,0,0,0) != 0 }
  move(right,x:100,y:50); try await until { native_test_peer_has_input(peer,5,0,1,0) != 0 }
  let before = native_test_peer_count_input(peer,5,0,1,0)
  await renderer.hold(); try right.setCanvasViewport(canvas(0))
  try await until { await renderer.waiting }
  try check(right.desktopRectangle.minX == -200,"pending region keeps published geometry")
  try session.setFocused(true); move(right,x:100,y:50)
  try await until { native_test_peer_count_input(peer,5,0,1,0) > before }
  await renderer.release(); try await until { !right.isRendering }
  let next = native_test_peer_count_input(peer,5,0,0,0)
  try session.setFocused(true); move(right,x:100,y:50)
  try await until { native_test_peer_count_input(peer,5,0,0,0) > next }
  try check(right.desktopRectangle.minX == 0 && (try color(right,x:50,y:50)).redComponent > 0.9,"new pixels and inverse mapping publish together")
  try right.setCanvasViewport(nil); try await until { !right.isRendering }
  try check(right.canvasViewport == nil && right.desktopRectangle.width == 200,"clearing canvas restores independent window sizing")
  // A bad candidate must leave the live canvas, pan and image intact.
  let previous = left.desktopRectangle
  do { try left.setCanvasViewport(canvas(200),pan:.init(x:Double.infinity,y:0)); throw Failure(message:"invalid pan accepted") }
  catch let error as NativeError { try check(error.status == .invalidArgument,"invalid pan is typed") }
  try check(left.canvasViewport?.region.x == 0 && left.desktopRectangle == previous,"failed candidate leaves presentation intent unchanged")
  let sequence = left.displayedSequence
  native_test_peer_patch(peer)
  try await until { left.displayedSequence > sequence && left.displayedSequence == session.frame?.sequence && right.displayedSequence == session.frame?.sequence && !left.isRendering && !right.isRendering }
  let magenta = try color(left,x:50,y:50)
  try check(magenta.redComponent > 0.9 && magenta.blueComponent > 0.9 && magenta.greenComponent < 0.3,"canvas receives source damage and new displayed pixels")
  try check(errors.isEmpty,"no canvas rendering failure")
  await renderer.hold(); try left.setCanvasViewport(canvas(200)); try right.setCanvasViewport(canvas(200))
  try await until { await renderer.waiting }
  let closing = Task { try await session.close() }; await renderer.release(); try await closing.value
  try check(left.displayedImage == nil && right.displayedImage == nil,"close clears both canvas surfaces and joins renderers")
  try await runtime.shutdown()
  print("PASS two AppKit canvas surfaces: distinct displayed pixels, inverse wire input, pending publication, clear/invalid candidate and joined close")
}
@MainActor func resizeOwnership() async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_resize_peer_create()!; defer { native_resize_peer_destroy(peer) }
  let windowed = NativeDesktopView(frame:.init(x:0,y:0,width:40,height:30))
  let surface = NativeDesktopView(frame:.init(x:0,y:0,width:50,height:30))
  let region = try NativeCanvasViewport(width:100,height:30,region:.init(x:50,y:0,width:50,height:30),devicePixels:false)
  try surface.setCanvasViewport(region) // Configure before bind/window attachment.
  windowed.bind(session); windowed.scaling = "100"
  surface.bind(session); surface.scaling = "100"
  let windows = [windowed,surface].map { view in
    let window = NSWindow(contentRect:view.bounds,styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = view; return window
  }
  defer { windowed.detach(); surface.detach(); for window in windows { window.contentView = nil; window.close() } }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { native_resize_peer_count(peer) == 1 && session.snapshot.width == 40 }
  windowed.setFrameSize(.init(width:41,height:30)); windowed.layout()
  try await until { native_resize_peer_count(peer) == 2 && session.snapshot.width == 41 }
  try check(surface.canvasViewport == region,"canvas survives bind and window attachment without stealing resize owner")
  surface.detach()
  windowed.setFrameSize(.init(width:42,height:30)); windowed.layout()
  try await until { native_resize_peer_count(peer) == 3 && session.snapshot.width == 42 }
  try windowed.setCanvasViewport(region)
  windowed.setFrameSize(.init(width:43,height:30)); windowed.layout()
  try await Task.sleep(for:.milliseconds(180))
  try check(native_resize_peer_count(peer) == 3,"canvas surface never emits its region as whole remote desktop resize")
  try windowed.setCanvasViewport(nil)
  try await until { native_resize_peer_count(peer) == 4 && session.snapshot.width == 43 }
  try await session.close(); try await runtime.shutdown()
  print("PASS canvas surfaces do not steal automatic resize ownership; clearing restores window policy")
}
@main struct Main {
  static func main() async {
    do { try geometry(); try await presentation(); try await resizeOwnership() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
