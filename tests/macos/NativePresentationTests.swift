// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(message: message) } }
@MainActor func until(_ condition: () async -> Bool) async throws {
  for _ in 0..<2000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Presentation timed out")
}
actor HeldRenderer: NativeTileRendering {
  let actual: NativeTileRenderer
  private var gate: CheckedContinuation<Void, Never>?
  private(set) var starts = 0
  init() throws { actual = try NativeTileRenderer() }
  func render(_ request: NativeTileRequest) async throws -> NativeTileBatch {
    starts += 1; await withCheckedContinuation { gate = $0 }
    let worker = actual
    // Deliberately finish obsolete work to verify the owner suppresses delivery.
    return try await Task.detached { try await worker.render(request) }.value
  }
  func release() { let current = gate; gate = nil; current?.resume() }
  func clear() async throws { try await actual.clear() }
}
@MainActor func color(_ view: NSView, at point: CGPoint, artifact: String? = nil) throws -> NSColor {
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "Missing bitmap") }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  if let artifact {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "Missing PNG") }
    try png.write(to: directory.appendingPathComponent(artifact + ".png"))
  }
  guard let normalized = bitmap.converting(to: .sRGB, renderingIntent: .default),
        let color = normalized.colorAt(x: Int(point.x*Double(bitmap.pixelsWide)/view.bounds.width),
          y: Int(point.y*Double(bitmap.pixelsHigh)/view.bounds.height))?.usingColorSpace(.sRGB) else { throw Failure(message: "Missing sample") }
  return color
}
@MainActor final class ReferenceImageView: NSView {
  let image: CGImage
  init(image: CGImage) { self.image = image; super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 32)) }
  required init?(coder: NSCoder) { fatalError("Unused test initializer") }
  override func draw(_ dirtyRect: NSRect) { NSGraphicsContext.current!.cgContext.draw(image, in: bounds) }
}
@MainActor func referenceColor(_ bgra: [UInt8]) throws -> NSColor {
  let data = Data(bgra), provider = CGDataProvider(data: data as CFData)!
  let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let view = ReferenceImageView(image: image)
  let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = view
  defer { window.contentView = nil; window.close() }
  return try color(view, at: CGPoint(x: 16, y: 16))
}
func matches(_ a: NSColor, _ b: NSColor) -> Bool {
  abs(a.redComponent-b.redComponent) < 0.025 && abs(a.greenComponent-b.greenComponent) < 0.025 && abs(a.blueComponent-b.blueComponent) < 0.025
}
@MainActor func connected(_ runtime: NativeRuntime, peer: UnsafeMutableRawPointer) async throws -> NativeSession {
  var config = NativeSessionConfiguration(); config.securityTypes = [1]
  let session = try runtime.makeSession(configuration: config)
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]) }
  return session
}
@MainActor func composition() async throws {
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connected(runtime, peer: peer)
  let view = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
  let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = view
  defer { view.detach(); window.contentView = nil; window.close() }
  let scaling = NativeScalingState(), initial = NativeScalingDraft(state: scaling)
  initial.filter = .nearest; try check(initial.apply(), "initial nearest selection")
  var errors: [String] = []; view.onError = { errors.append($0) }; view.bind(session); view.observeScaling(scaling)
  try await until { view.displayedSequence == session.frame?.sequence && !view.isRendering }
  try check(!view.usesDirectImage && view.presentationBytes > 0 && view.renderedBytes == view.presentationBytes, "scaled presentation uses bounded tiles")
  let red = try color(view, at: CGPoint(x: 150, y: 150), artifact: "nearest"), white = try color(view, at: CGPoint(x: 450, y: 450))
  try check(red.redComponent > 0.9 && red.blueComponent < 0.1 && white.greenComponent > 0.9, "displayed tile color/orientation")
  let before = view.displayedSequence
  native_test_peer_patch(peer)
  try await until { view.displayedSequence > before && view.displayedSequence == session.frame?.sequence && !view.isRendering }
  try check(view.reusedTiles > 0 && view.renderedBytes < view.presentationBytes, "partial update shares unchanged CG images without pixel copies")
  try check(view.lastInvalidatedRectangle == CGRect(x: 0, y: 0, width: 300, height: 300), "shared damage maps to exact logical dirty quadrant")
  let magenta = try color(view, at: CGPoint(x: 150, y: 150), artifact: "partial-damage")
  try check(magenta.redComponent > 0.9 && magenta.blueComponent > 0.9 && magenta.greenComponent < 0.4, "new damage reaches displayed pixels")
  let smoothing = NativeScalingDraft(state: scaling); smoothing.filter = .bilinear
  try check(view.filter == .nearest && smoothing.apply(), "filter applies through connection settings")
  try await until { !view.isRendering }
  let blend = try color(view, at: CGPoint(x: 300, y: 300), artifact: "bilinear")
  let expectedBlend = try referenceColor([191,128,128,255])
  if !matches(blend, expectedBlend) { print("Blend diagnostic: \(blend), reference \(expectedBlend)") }
  try check(matches(blend, expectedBlend), "bilinear pixels match an independent golden image under the display profile")
  let reduction = NativeScalingDraft(state: scaling)
  reduction.filter = .area; reduction.mode = .exact; reduction.text = "1x1"; reduction.devicePixels = true
  try check(reduction.apply(), "filter, size and units apply together")
  try await until { !view.isRendering }
  let average = try color(view, at: CGPoint(x: view.desktopRectangle.midX, y: view.desktopRectangle.midY), artifact: "area")
  try check(matches(average, expectedBlend), "area average displayed in one backing pixel matches golden image")
  let identity = NativeScalingDraft(state: scaling); identity.mode = .unscaled
  try check(identity.apply() && scaling.value.filter == .area, "identity retains quality preference")
  try check(view.usesDirectImage && view.presentationBytes == 0 && view.renderedBytes == 0, "identity switches immediately to retained original CG image")
  try await until { !view.isRendering }
  let retained = view.displayedImage!
  let directColor = try color(view, at: CGPoint(x: view.desktopRectangle.minX + view.desktopRectangle.width/4,
    y: view.desktopRectangle.minY + view.desktopRectangle.height/4), artifact: "identity")
  // Display profile conversion can shift saturated colors. Match the original
  // retained-image path on the same display, while raw worker tests check bytes.
  try check(abs(directColor.redComponent-magenta.redComponent) < 0.02 &&
    abs(directColor.greenComponent-magenta.greenComponent) < 0.02 && abs(directColor.blueComponent-magenta.blueComponent) < 0.02,
    "scaled tiles and identity source have the same display-profile conversion")
  view.isHidden = true; try check(view.displayedImage == nil, "hidden presentation cleared")
  view.isHidden = false; try check(view.usesDirectImage && view.displayedImage != nil, "unhidden identity restored")
  try await session.close()
  try check(session.presentations.count == 0 && view.displayedImage == nil, "session close joins all presentation cleanup")
  try await runtime.shutdown()
  try check((retained.dataProvider!.data! as Data).prefix(4) == Data([255,0,255,0]), "old zero-copy identity provider survives teardown")
  try check(errors.isEmpty, "no composition errors")
  print("PASS displayed shared-filter pixels, damage-only redraw, CG tile reuse, identity, hide/unhide and joined cleanup")
}
@MainActor func coherentPresentationAndClose() async throws {
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connected(runtime, peer: peer), worker = try HeldRenderer()
  let view = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
  view.rendererOverride = worker; view.bind(session)
  try await until { await worker.starts == 1 }
  try check(view.desktopRectangle == .zero && view.displayedImage == nil, "no image or input geometry before initial pixels")
  await worker.release(); try await until { !view.isRendering }
  let original = view.desktopRectangle
  view.scaling = "120x80"; try await until { await worker.starts == 2 }
  try check(view.desktopRectangle == original, "pending scale retains the displayed image's input transform")
  view.scaling = "80x40"; await worker.release(); try await until { await worker.starts == 3 }
  try check(view.desktopRectangle == original, "obsolete scale result cannot replace presentation")
  await worker.release(); try await until { !view.isRendering }
  try check(view.desktopRectangle == CGRect(x: 110, y: 80, width: 80, height: 40), "latest image and inverse transform publish together")
  view.scaling = "90x50"; try await until { await worker.starts == 4 }
  view.detach()
  try check(session.presentations.count == 1 && view.displayedImage == nil, "detached active renderer stays accounted until drain")
  var closed = false
  let cleanup = Task { try await session.close(); closed = true }
  await Task.yield(); try check(!closed, "session close awaits renderer without blocking MainActor")
  await worker.release(); try await cleanup.value
  try check(closed && session.presentations.count == 0 && view.displayedImage == nil, "late completion suppressed after detach and close")
  try await runtime.shutdown()
  print("PASS coherent asynchronous image/input state, stale scale suppression, detached work accounting and nonblocking session close")
}
@MainActor func boundedPool() async throws {
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connected(runtime, peer: peer)
  let image = session.frame!, pool = session.presentations
  var workers: [HeldRenderer] = []
  for _ in 0..<16 {
    let worker = try HeldRenderer(); workers.append(worker)
    let (id, scheduler) = try pool.acquire(renderer: worker)
    scheduler.submit(NativeTileRequest(image: image, width: 4, height: 4,
      visible: NativePixelRect(x: 0, y: 0, width: 4, height: 4), filter: .nearest))
    try await until { await worker.starts == 1 }; pool.release(id)
  }
  try check(pool.count == 16, "pending cleanup counts against capacity")
  do { _ = try pool.acquire(); throw Failure(message: "Unbounded render admission") }
  catch let error as NativeError { try check(error.status == .resourceLimit, "bounded render admission") }
  let closing = Task { try await session.close() }
  for worker in workers { await worker.release() }
  try await closing.value
  try check(pool.count == 0, "all held renderers drained")
  do { _ = try pool.acquire(); throw Failure(message: "Admitted after close") }
  catch let error as NativeError { try check(error.status == .closing, "closed render admission") }
  try await runtime.shutdown()
  print("PASS 16-slot bound includes pending detach cleanup and shutdown gates new renderers")
}
@MainActor func releasedView() async throws {
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connected(runtime, peer: peer), worker = try HeldRenderer()
  var view: NativeDesktopView? = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
  weak var released: NativeDesktopView?
  released = view
  view!.rendererOverride = worker; view!.bind(session)
  try await until { await worker.starts == 1 }
  view = nil
  try check(released == nil, "render work and subscriptions do not retain the view")
  await worker.release()
  try await until { session.presentations.count == 0 }
  try await session.close(); try await runtime.shutdown()
  print("PASS released view drains its renderer without an explicit detach")
}
@MainActor func imageObservation() async throws {
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), session = try await connected(runtime, peer: peer)
  let view = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
  view.bind(session)
  try await until { !view.isRendering && session.snapshot.frames > 0 }
  var changes = 0, snapshots = 0, frames = 0, cursors = 0, availability: [Bool] = []
  var observers = Set<AnyCancellable>()
  session.objectWillChange.sink { MainActor.assumeIsolated { changes += 1 } }.store(in: &observers)
  session.$snapshot.dropFirst().sink { _ in MainActor.assumeIsolated { snapshots += 1 } }.store(in: &observers)
  session.frameUpdates.dropFirst().sink { _ in MainActor.assumeIsolated { frames += 1 } }.store(in: &observers)
  session.cursorUpdates.dropFirst().sink { _ in MainActor.assumeIsolated { cursors += 1 } }.store(in: &observers)
  session.$hasFrame.dropFirst().sink { value in MainActor.assumeIsolated { availability.append(value) } }.store(in: &observers)
  for _ in 0..<20 {
    let previous = session.frame!.sequence
    native_test_peer_patch(peer)
    try await until { session.frame!.sequence > previous }
  }
  native_test_peer_cursor(peer, 1); try await until { session.cursor != nil }
  let retainedCursor = session.cursor!
  try check(retainedCursor.width == 2 && retainedCursor.hotspotX == 1, "real cursor stream shape and hotspot")
  var replayedFrame: NativeImage?, replayedCursor: NativeImage?
  let frameReplay = session.frameUpdates.sink { value in MainActor.assumeIsolated { replayedFrame = value } }
  let cursorReplay = session.cursorUpdates.sink { value in MainActor.assumeIsolated { replayedCursor = value } }
  try check(replayedFrame === session.frame && replayedCursor === retainedCursor, "new subscribers synchronously receive current image leases")
  frameReplay.cancel(); cursorReplay.cancel()
  native_test_peer_cursor(peer, 0); try await until { session.cursor == nil && !view.isRendering }
  try session.setFocused(false); try session.setViewOnly(false)
  try check(frames >= 20 && cursors == 2 && availability.isEmpty, "images update independently while frame availability stays true")
  try check(changes == snapshots, "image delivery and unchanged focus produce no SwiftUI invalidations; only sampled snapshots do")
  print("PASS \(frames) frame and \(cursors) cursor updates with only \(snapshots) distinct snapshot invalidations")
  observers.removeAll()
  session.$hasFrame.dropFirst().sink { value in MainActor.assumeIsolated { availability.append(value) } }.store(in: &observers)
  _ = try await session.disconnect()
  try await until { session.frame == nil && view.displayedImage == nil }
  try check(availability == [false] && !session.hasFrame, "disconnect publishes one availability transition and clears AppKit")
  view.detach(); try await session.close(); try await runtime.shutdown()
  let cursorPixels = try retainedCursor.copyPixels()
  try check(cursorPixels == Data([255,0,0,255,0,255,0,255]), "retained cursor survives stream clearing and shutdown")
  try check(availability == [false], "close does not repeat unchanged availability")
}
@main struct NativePresentationTests {
  @MainActor static func main() async {
    _ = NSApplication.shared
    do { try await composition(); try await coherentPresentationAndClose(); try await boundedPool(); try await releasedView(); try await imageObservation() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
