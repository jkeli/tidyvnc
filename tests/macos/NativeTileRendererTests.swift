// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(message: message) } }
@MainActor func until(_ condition: () async -> Bool) async throws {
  for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
actor HeldRenderer: NativeTileRendering {
  private var gate: CheckedContinuation<Void, Never>?
  private var failure = false
  private(set) var starts = 0, clears = 0
  func render(_ request: NativeTileRequest) async throws -> NativeTileBatch {
    starts += 1
    await withCheckedContinuation { gate = $0 }
    if failure { failure = false; throw NativeError(.failed, "Injected renderer failure") }
    // Intentionally ignore cancellation to test late-result suppression/join.
    return NativeTileBatch(request: request, tiles: [], bytes: 0, cacheBytes: 0, cacheHits: 0)
  }
  func release(fail: Bool = false) { failure = fail; let current = gate; gate = nil; current?.resume() }
  func clear() { clears += 1 }
}
@MainActor final class WeakScheduler {
  weak var value: NativeTileScheduler?
  init(_ value: NativeTileScheduler?) { self.value = value }
}
func request(_ image: NativeImage, width: UInt32 = 4, height: UInt32 = 4,
             filter: NativeScalingFilter = .bilinear, visible: NativePixelRect? = nil) -> NativeTileRequest {
  NativeTileRequest(image: image, width: width, height: height,
    visible: visible ?? NativePixelRect(x: 0, y: 0, width: width, height: height), filter: filter)
}
func clone(_ image: NativeImage) throws -> NativeImage {
  try NativeImage(owning: NativeHandle(retaining: image.handle.raw), previousSequence: image.previousSequence,
    damage: image.damage, streamID: image.streamID)
}
@MainActor func scheduling(_ image: NativeImage) async throws {
  let worker = HeldRenderer(), scheduler = NativeTileScheduler(renderer: worker)
  var delivered: [NativeImage] = [], failures = 0
  scheduler.onFrame = { delivered.append($0.request.image) }; scheduler.onError = { _ in failures += 1 }
  scheduler.submit(request(image)); try await until { await worker.starts == 1 }
  var latest = image
  for _ in 0..<500 { latest = try clone(image); scheduler.submit(request(latest)) }
  let starts = await worker.starts
  try check(starts == 1 && scheduler.pendingCount == 1, "one active plus one latest request")
  await worker.release(); try await until { await worker.starts == 2 }
  try check(delivered.count == 1 && delivered[0] === image, "continuous frames do not starve completed presentation")
  await worker.release(); try await until { !scheduler.isRunning }
  try check(delivered.count == 2 && delivered[1] === latest, "500 queued frames coalesce to latest")
  scheduler.submit(request(latest, width: 8)); try await until { await worker.starts == 3 }
  scheduler.submit(request(latest, width: 16)); await worker.release()
  try await until { await worker.starts == 4 }
  try check(delivered.count == 2, "obsolete transform suppressed even when worker ignores cancellation")
  await worker.release(fail: true); try await until { !scheduler.isRunning }
  try check(failures == 1, "current render error delivered")
  scheduler.submit(request(latest, width: 16)); try await until { await worker.starts == 5 }
  var joined = false
  let close = Task { await scheduler.close(); joined = true }
  await Task.yield()
  try check(!joined && scheduler.pendingCount == 0, "close remains asynchronous and joins running work")
  await worker.release(); await close.value
  try check(joined && delivered.count == 2 && failures == 1, "late result ignored after close")
  scheduler.submit(request(image)); let finalStarts = await worker.starts, clears = await worker.clears
  try check(finalStarts == 5 && clears == 1, "stopped admission and cleared cache")
  let held = HeldRenderer()
  var owner: NativeTileScheduler? = NativeTileScheduler(renderer: held)
  let weak = WeakScheduler(owner)
  owner!.submit(request(image)); try await until { await held.starts == 1 }
  owner = nil; try check(weak.value == nil, "running task does not retain scheduler or view owner")
  await held.release()
  print("PASS bounded latest admission, progress under continuous frames, stale suppression, retry, nonblocking close and weak disposal")
}
@MainActor func pixels(_ image: NativeImage) async throws {
  let renderer = try NativeTileRenderer(cacheBytes: 1024*1024)
  let linear = try await renderer.render(request(image))
  try check(linear.tiles.count == 1 && linear.bytes == 64 && linear.cacheHits == 0, "one bounded tile")
  try check(Array(linear.tiles[0].pixels[20..<24]) == [64,64,159,255], "bilinear BGRA golden center sample")
  let cached = try await renderer.render(request(image))
  try check(cached.reusedTiles == 1 && cached.renderedBytes == 0 && cached.tiles[0].image === linear.tiles[0].image && cached.tiles[0].pixels == linear.tiles[0].pixels, "repeat reuses the immutable CG tile without copying pixels")
  let area = try await renderer.render(request(image, width: 1, height: 1, filter: .area))
  try check(Array(area.tiles[0].pixels) == [128,128,128,255], "area average of four colors")
  let nearest = try await renderer.render(request(image, width: 1, height: 1, filter: .nearest))
  try check(Array(nearest.tiles[0].pixels) == [255,255,255,255], "nearest samples bottom-right source pixel")
  let identity = try await renderer.render(request(image, width: 2, height: 2, filter: .area))
  try check(Array(identity.tiles[0].pixels.prefix(4)) == [0,0,255,255], "identity preserves color and makes opaque alpha")
  let zoom = try await renderer.render(request(image, width: 65535, height: 65535,
    visible: NativePixelRect(x: 64500, y: 100, width: 300, height: 200)))
  try check(zoom.tiles.count == 6 && zoom.bytes == 6*256*256*4 && zoom.cacheBytes <= 1024*1024, "large zoom renders only visible fixed-grid tiles")
  let pan = try await renderer.render(request(image, width: 65535, height: 65535,
    visible: NativePixelRect(x: 64501, y: 101, width: 300, height: 200)))
  try check(pan.tiles.count == 6 && pan.bytes == zoom.bytes && pan.reusedTiles == 6 && pan.renderedBytes == 0, "pan within grid has same bounded storage")
  do {
    _ = try await renderer.render(request(image, width: 65535, height: 65535))
    throw Failure(message: "Accepted unbounded presentation")
  } catch let error as NativeError { try check(error.status == .resourceLimit, "reject visible budget before allocation") }
  do {
    _ = try await renderer.render(request(image, visible: NativePixelRect(x: UInt32.max, y: 0, width: 1, height: 1)))
    throw Failure(message: "Accepted invalid visible region")
  } catch let error as NativeError { try check(error.status == .invalidArgument, "overflow-safe region validation") }
  let cancelled = Task { try await renderer.render(request(image, width: 4096, height: 4096)) }
  cancelled.cancel()
  do { _ = try await cancelled.value; throw Failure(message: "Ignored cancellation") } catch is CancellationError {}
  let hidden = try await renderer.render(request(image, visible: NativePixelRect(x: 0, y: 0, width: 0, height: 0)))
  try check(hidden.tiles.isEmpty && hidden.bytes == 0 && hidden.cacheBytes == 0, "empty viewport releases cached pixels")
  try await renderer.clear()
  let emptyCache = try await renderer.render(request(image))
  try check(emptyCache.cacheHits == 0 && emptyCache.tiles[0].pixels == linear.tiles[0].pixels, "clear and cancellation preserve future renders")
  print("PASS independent filter goldens, identity, cache, bounded extreme zoom, region/byte limits and cancellation")
}
@MainActor func skippedDamage(_ session: NativeSession, peer: UnsafeMutableRawPointer) async throws {
  let worker = try NativeTileRenderer(), first = session.frame!
  let initial = try await worker.render(request(first, width: 512, height: 512, filter: .nearest))
  try check(initial.tiles.count == 4, "damage fixture grid")
  native_test_peer_patch_other(peer); try await until { session.frame!.sequence > first.sequence }
  let skipped = session.frame!
  native_test_peer_patch(peer); try await until { session.frame!.sequence > skipped.sequence }
  let latest = session.frame!
  try check(latest.previousSequence == skipped.sequence, "damage is relative to skipped publication")
  let recovered = try await worker.render(request(latest, width: 512, height: 512, filter: .nearest))
  try check(recovered.reusedTiles == 0 && recovered.renderedBytes == recovered.bytes, "missing history disables CG tile reuse")
  try check(Array(recovered.tiles.last!.pixels.prefix(4)) == [0,0,0,255], "skipped bottom-right damage cannot leave stale pixels")
  let repeated = try await worker.render(request(latest, width: 512, height: 512, filter: .nearest))
  try check(repeated.reusedTiles == 4 && repeated.renderedBytes == 0, "recovered tiles reused without copying")
  let retained = recovered.tiles.last!.image
  try await worker.clear()
  try check((retained.dataProvider!.data! as Data).prefix(4) == Data([0,0,0,255]), "CG tile owns pixels after renderer clear")
  print("PASS skipped-frame damage recovery, zero-copy CG reuse and independent provider lifetime")
}
@main struct NativeTileRendererTests {
  @MainActor static func main() async {
    do {
      let peer = native_test_peer_create_pattern(0)!
      defer { native_test_peer_destroy(peer) }
      let runtime = try NativeRuntime()
      var config = NativeSessionConfiguration(); config.securityTypes = [1]
      let session = try runtime.makeSession(configuration: config)
      _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
      try await until { (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]) }
      let image = session.frame!
      try check(image.damage == NativePixelRect(x: 0, y: 0, width: 2, height: 2), "publication damage copied into immutable native image")
      try await skippedDamage(session, peer: peer)
      let beforeResize = session.frame!.sequence
      native_test_peer_resize(peer)
      try await until { session.frame?.width == 3 }
      try check(session.frame!.previousSequence == beforeResize && session.frame!.streamID == image.streamID, "frame history chain follows consumed native updates")
      try await session.close(); try await runtime.shutdown()
      try await pixels(image); try await scheduling(image)
      print("PASS rendering retained images after remote resize, session close and runtime shutdown")
    } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
