// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }
@MainActor func until(_ condition: () async -> Bool) async throws {
  for _ in 0..<2000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Cursor presentation timed out")
}
actor HeldCursor: NativeCursorRendering {
  private let actual = NativeCursorRenderer()
  private var gate: CheckedContinuation<Void, Never>?
  private(set) var starts = 0
  func render(_ request: NativeCursorRequest) async throws -> NativeCursorBatch {
    starts += 1; await withCheckedContinuation { gate = $0 }
    let worker = actual
    return try await Task.detached { try await worker.render(request) }.value
  }
  func release() { let value = gate; gate = nil; value?.resume() }
  func clear() async { await actual.clear() }
}
@MainActor func connect(_ runtime: NativeRuntime, _ peer: UnsafeMutableRawPointer) async throws -> NativeSession {
  var config = NativeSessionConfiguration(); config.securityTypes = [1]
  let session = try runtime.makeSession(configuration: config)
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]) }
  return session
}
@MainActor func move(_ view: NativeDesktopView, _ point: CGPoint) {
  let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
    windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
  view.mouseMoved(with: event)
}
@MainActor func capture(_ view: NSView, name: String? = nil) throws -> NSBitmapImageRep {
  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
  view.cacheDisplay(in: view.bounds, to: bitmap)
  if let name {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name+".png"))
  }
  return bitmap.converting(to: .sRGB, renderingIntent: .default)!
}
@MainActor func color(_ bitmap: NSBitmapImageRep, _ view: NSView, _ point: CGPoint) -> NSColor {
  bitmap.colorAt(x: Int(point.x*Double(bitmap.pixelsWide)/view.bounds.width), y: Int(point.y*Double(bitmap.pixelsHigh)/view.bounds.height))!.usingColorSpace(.sRGB)!
}
@MainActor func presentation() async throws {
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connect(runtime, peer)
  let view = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
  let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = view
  defer { view.detach(); window.contentView = nil; window.close() }
  var errors: [String] = []; view.onError = { errors.append($0) }; view.filter = .nearest; view.bind(session)
  try await until { !view.isRendering }
  native_test_peer_cursor(peer, 1); try await until { session.cursor != nil && !view.isRenderingCursor }
  move(view, CGPoint(x: 100, y: 125)); try await until { !view.isRenderingCursor }
  try check(view.cursorBatch?.native == false && (view.cursorBatch?.bytes ?? 0) > 0, "large sampled cursor uses visible software tiles")
  let bitmap = try capture(view, name: "software-nearest")
  let red = color(bitmap,view,CGPoint(x: 75,y: 150)), green = color(bitmap,view,CGPoint(x: 175,y: 150)), black = color(bitmap,view,CGPoint(x: 20,y: 150))
  try check(red.redComponent > 0.9 && red.blueComponent < 0.1 && green.greenComponent > 0.9 && green.blueComponent < 0.1,
    "software cursor overlays red/green on the blue/white desktop")
  try check(black.redComponent < 0.1 && black.greenComponent < 0.1, "cursor clips at the letterbox boundary")
  let originalTiles = view.cursorBatch!.tiles
  move(view, CGPoint(x: 105,y: 125)); try await until { !view.isRenderingCursor }
  try check(view.cursorBatch!.reusedTiles > 0 && view.cursorBatch!.tiles.contains { tile in originalTiles.contains { $0.image === tile.image } }, "pointer motion reuses immutable CG cursor tiles")
  move(view, CGPoint(x: 20,y: 125)); try check(view.cursorBatch == nil, "letterbox entry immediately erases software cursor")
  try await until { !view.isRenderingCursor }; try check(view.cursorBatch == nil, "late cursor work cannot restore an outside pointer")
  view.scaling = "20x20"; try await until { !view.isRendering && !view.isRenderingCursor && view.cursorBatch?.native == true }
  let native = view.cursorBatch!, q = window.backingScaleFactor
  try check(view.displayedCursor!.image.size == CGSize(width: Double(native.width)/q,height: Double(native.height)/q) &&
    view.displayedCursor!.hotSpot == CGPoint(x: Double(native.hotspotX)/q,y: Double(native.hotspotY)/q), "native cursor size and hotspot use sampled backing pixels")
  let alphaSequence = session.cursor!.sequence
  native_test_peer_cursor_alpha(peer)
  try await until { session.cursor!.sequence > alphaSequence && !view.isRenderingCursor }
  view.filter = .bilinear; view.scaling = "FixedRatio"; try await until { !view.isRendering && !view.isRenderingCursor }
  move(view, CGPoint(x: 100,y: 125)); try await until { !view.isRenderingCursor }
  _ = try capture(view,name: "software-alpha-bilinear")
  try check(view.cursorBatch!.request.filter == .bilinear && view.cursorBatch!.tiles.first!.image.alphaInfo == .last, "software alpha path uses selected filter and straight RGBA")
  view.isHidden = true; try check(view.cursorBatch == nil, "hide erases cursor presentation")
  view.isHidden = false; try await until { !view.isRendering && !view.isRenderingCursor }
  let beforeBlank = session.cursor!.sequence
  native_test_peer_cursor_blank(peer)
  try await until { session.cursor!.sequence > beforeBlank && view.cursorBatch?.blank == true && !view.isRenderingCursor }
  try check(view.displayedCursor!.image.size == CGSize(width: 1,height: 1), "blank cursor defaults to hidden")
  view.cursorFallback = .dot; try check(view.displayedCursor!.image.size == CGSize(width: 5,height: 5), "blank cursor dot fallback stays local-sized")
  view.cursorFallback = .system; try check(view.displayedCursor === NSCursor.arrow, "system fallback")
  try session.setViewOnly(true); try check(view.cursorBatch == nil && view.displayedCursor === NSCursor.arrow, "view-only uses local pointer")
  try session.setViewOnly(false); try await until { !view.isRenderingCursor }
  native_test_peer_cursor(peer, 0); try await until { session.cursor == nil }
  try check(view.cursorBatch == nil && view.displayedCursor === NSCursor.arrow, "empty remote cursor uses selected fallback")
  view.cursorFallback = .hidden; try check(view.displayedCursor!.image.size == CGSize(width: 1,height: 1), "hidden fallback after clear")
  try await session.close(); try await runtime.shutdown()
  try check(view.cursorBatch == nil && session.presentations.count == 0 && errors.isEmpty, "cursor presentation closes cleanly")
  print("PASS native/software cursor pixels, clipping, shared hotspot, pointer tile reuse, alpha/filter routing, hide, blank/empty fallback and view-only")
}
@MainActor func schedulingAndDrain() async throws {
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connect(runtime,peer)
  native_test_peer_cursor(peer,1); try await until { session.cursor != nil }
  let worker = HeldCursor(), scheduler = NativeCursorScheduler(renderer: worker), image = session.cursor!
  func request(_ x: CGFloat, filter: NativeScalingFilter = .nearest) -> NativeCursorRequest {
    NativeCursorRequest(image: image,scaleX: 200,scaleY: 200,backingScale: 1,filter: filter,
      clip: CGRect(x: 0,y: 0,width: 100,height: 100),point: CGPoint(x: x,y: 50))
  }
  var outputs: [CGFloat] = []; scheduler.onFrame = { outputs.append($0.request.point!.x) }
  scheduler.submit(request(0)); try await until { await worker.starts == 1 }
  for i in 1...500 { scheduler.submit(request(CGFloat(i%97))) }
  try check(scheduler.pendingCount == 1, "pointer requests coalesce to one pending job")
  await worker.release(); try await until { await worker.starts == 2 }
  await worker.release(); try await until { !scheduler.isRunning }
  try check(outputs == [0,15], "useful motion work finishes and only latest pending request runs")
  await scheduler.close()
  let bounded = NativeCursorRenderer()
  let excessive = NativeCursorRequest(image: image, scaleX: 65535, scaleY: 65535, backingScale: 1, filter: .nearest,
    clip: CGRect(x: 0,y: 0,width: 65535,height: 65535), point: CGPoint(x: 65535,y: 0))
  do { _ = try await bounded.render(excessive); throw Failure(message: "Unbounded cursor output") }
  catch let error as NativeError { try check(error.status == .resourceLimit, "visible cursor output admission is bounded before allocation") }
  let invalid = NativeCursorRequest(image: image,scaleX: 2,scaleY: 2,backingScale: .leastNonzeroMagnitude,filter: .nearest,
    clip: CGRect(x: 0,y: 0,width: 10,height: 10),point: .zero)
  do { _ = try await bounded.render(invalid); throw Failure(message: "Nonfinite cursor placement") }
  catch let error as NativeError { try check(error.status == .invalidArgument, "overflowing placement rejected") }
  _ = try await bounded.render(request(50)); await bounded.clear()
  let held = HeldCursor(), view = NativeDesktopView(frame: CGRect(x: 0,y: 0,width: 40,height: 40))
  view.cursorRendererOverride = held; view.bind(session)
  try await until { await held.starts == 1 }
  view.filter = .area; try await until { !view.isRendering }
  await held.release(); try await until { await held.starts == 2 }
  try check(view.cursorBatch == nil, "obsolete filter result suppressed even when worker ignores cancellation")
  await held.release(); try await until { !view.isRenderingCursor }
  try check(view.cursorBatch?.request.filter == .area, "latest cursor filter displayed")
  view.filter = .nearest; try await until { await held.starts == 3 }
  view.detach(); var closed = false
  let close = Task { try await session.close(); closed = true }
  await Task.yield(); try check(!closed && session.presentations.count == 1, "detached cursor worker counts until joined close")
  await held.release(); try await close.value
  try check(view.cursorBatch == nil && session.presentations.count == 0, "late result after detach cannot install and slot drains")
  try await runtime.shutdown()
  print("PASS 500-motion coalescing, useful completion, stale filter suppression and held cursor drain through detach/close")
}
@main struct NativeCursorPresentationTests {
  @MainActor static func main() async {
    _ = NSApplication.shared
    do { try await presentation(); try await schedulingAndDrain(); try await backingTransition() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}

@MainActor func backingTransition() async throws {
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connect(runtime,peer)
  native_test_peer_cursor(peer,1); try await until { session.cursor != nil }
  let view = NativeDesktopView(frame: CGRect(x: 0,y: 0,width: 70,height: 70)); view.bind(session)
  try await until { !view.isRendering && !view.isRenderingCursor && view.cursorBatch != nil }
  try check(view.cursorBatch!.native && view.cursorBatch!.width == 70 && view.displayedCursor!.image.size.width == 70,
    "unattached scale-one cursor uses native image")
  let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = view
  try await until { !view.isRendering && !view.isRenderingCursor }
  move(view,CGPoint(x: 35,y: 35)); try await until { !view.isRenderingCursor }
  let q = window.backingScaleFactor
  try check(view.cursorBatch!.width == UInt32(70*q) && view.cursorBatch!.request.backingScale == q,
    "window backing scale rebuilds cursor raster")
  if q > 128.0/70.0 { try check(!view.cursorBatch!.native, "backing growth crosses native/software threshold") }
  window.contentView = nil; window.close()
  try await until { !view.isRendering && !view.isRenderingCursor && view.cursorBatch?.native == true }
  try check(view.displayedCursor!.image.size.width == 70 && view.cursorBatch!.request.backingScale == 1,
    "return to scale one restores native cursor with stable logical size")
  view.detach(); try await session.close(); try await runtime.shutdown()
  print("PASS backing-scale attachment/detachment rebuilds sampled cursor and native/software choice")
}
