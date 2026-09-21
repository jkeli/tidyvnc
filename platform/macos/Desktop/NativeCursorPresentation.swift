// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreGraphics
import Foundation

struct NativeCursorRequest: Sendable, Equatable {
  let image: NativeImage
  let scaleX: Double, scaleY: Double, backingScale: Double
  let filter: NativeScalingFilter
  let clip: CGRect
  let point: CGPoint?
  func hasSameRaster(as other: Self) -> Bool {
    image === other.image && scaleX == other.scaleX && scaleY == other.scaleY && filter == other.filter
  }
  func hasSamePresentation(as other: Self) -> Bool {
    hasSameRaster(as: other) && backingScale == other.backingScale && clip == other.clip
  }
  static func == (a: Self, b: Self) -> Bool { a.hasSamePresentation(as: b) && a.point == b.point }
}
struct NativeCursorBatch: Sendable {
  let request: NativeCursorRequest
  let tiles: [NativeRenderedTile]
  let width: UInt32, height: UInt32, hotspotX: UInt32, hotspotY: UInt32
  let origin: CGPoint
  let native: Bool, blank: Bool
  let bytes: Int, reusedTiles: Int
  var rectangle: CGRect {
    CGRect(origin: origin, size: CGSize(width: Double(width)/request.backingScale, height: Double(height)/request.backingScale))
  }
}
protocol NativeCursorRendering: Sendable {
  func render(_ request: NativeCursorRequest) async throws -> NativeCursorBatch
  func clear() async
}
actor NativeCursorRenderer: NativeCursorRendering {
  private var sampler: NativeCursorSampler?
  private var previous: NativeCursorBatch?
  func clear() { sampler = nil; previous = nil }
  func render(_ request: NativeCursorRequest) throws -> NativeCursorBatch {
    try Task.checkCancellation()
    guard request.backingScale.isFinite, request.backingScale > 0, request.backingScale <= 64,
          request.clip.origin.x.isFinite, request.clip.origin.y.isFinite,
          request.clip.width.isFinite, request.clip.height.isFinite,
          request.clip.width >= 0, request.clip.height >= 0,
          request.point.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else {
      throw NativeError(.invalidArgument, "Invalid cursor placement")
    }
    if previous?.request.hasSameRaster(as: request) != true {
      sampler = try NativeCursorSampler(image: request.image, scaleX: request.scaleX, scaleY: request.scaleY, filter: request.filter)
      previous = nil
    }
    let sampler = sampler!
    let native = sampler.width <= 128 && sampler.height <= 128
    let q = request.backingScale
    let origin = request.point.map { CGPoint(x: (floor($0.x*q)-Double(sampler.hotspotX))/q,
                                             y: (floor($0.y*q)-Double(sampler.hotspotY))/q) } ?? .zero
    guard origin.x.isFinite, origin.y.isFinite, (Double(sampler.width)/q).isFinite, (Double(sampler.height)/q).isFinite else {
      throw NativeError(.invalidArgument, "Cursor placement exceeds display limits")
    }
    let rectangle = CGRect(origin: origin, size: CGSize(width: Double(sampler.width)/q, height: Double(sampler.height)/q))
    let visible = rectangle.intersection(request.clip)
    let region: NativePixelRect
    if sampler.isBlank || (!native && (request.point == nil || visible.isNull || visible.isEmpty)) {
      region = NativePixelRect(x: 0, y: 0, width: 0, height: 0)
    } else if native { region = NativePixelRect(x: 0, y: 0, width: sampler.width, height: sampler.height) }
    else {
      let left = max(0, min(Double(sampler.width), floor((visible.minX-origin.x)*q)))
      let top = max(0, min(Double(sampler.height), floor((visible.minY-origin.y)*q)))
      let right = max(left, min(Double(sampler.width), ceil((visible.maxX-origin.x)*q)))
      let bottom = max(top, min(Double(sampler.height), ceil((visible.maxY-origin.y)*q)))
      region = NativePixelRect(x: UInt32(left), y: UInt32(top), width: UInt32(right-left), height: UInt32(bottom-top))
    }
    let grid = try NativeTileGrid(width: sampler.width, height: sampler.height, visible: region, maximumDimension: UInt32(Int32.max/4))
    let reusable = Dictionary(uniqueKeysWithValues: (previous?.tiles ?? []).map { ($0.rect, $0) })
    var tiles: [NativeRenderedTile] = []; tiles.reserveCapacity(grid.count)
    var reused = 0
    for y in stride(from: grid.top, to: grid.bottom, by: 256) {
      for x in stride(from: grid.left, to: grid.right, by: 256) {
        try Task.checkCancellation()
        let rect = NativePixelRect(x: x, y: y, width: min(256,sampler.width-x), height: min(256,sampler.height-y))
        if let tile = reusable[rect] { tiles.append(tile); reused += 1 }
        else { tiles.append(try sampler.render(rect)) }
      }
    }
    try Task.checkCancellation()
    let result = NativeCursorBatch(request: request, tiles: tiles, width: sampler.width, height: sampler.height,
      hotspotX: sampler.hotspotX, hotspotY: sampler.hotspotY, origin: origin, native: native, blank: sampler.isBlank,
      bytes: grid.bytes, reusedTiles: reused)
    previous = result; return result
  }
}

// One active and one latest request. Pointer-only motion finishes useful work;
// changes to shape/scale/filter/clip cancel and invalidate obsolete presentation.
@MainActor final class NativeCursorScheduler {
  private let renderer: any NativeCursorRendering
  private var latest: NativeCursorRequest?, pending: NativeCursorRequest?, active: NativeCursorRequest?
  private var running: Task<Void, Never>?
  private var stopped = false, clearRequested = false
  var onFrame: (NativeCursorBatch) -> Void = { _ in }
  var onError: (any Error) -> Void = { _ in }
  var isRunning: Bool { running != nil }
  var pendingCount: Int { pending == nil ? 0 : 1 }
  init(renderer: any NativeCursorRendering) { self.renderer = renderer }
  deinit { running?.cancel() }
  func submit(_ request: NativeCursorRequest) {
    guard !stopped, latest != request else { return }
    latest = request; pending = request; clearRequested = false
    if let active, !active.hasSamePresentation(as: request) { running?.cancel() }
    start()
  }
  private func start() {
    guard running == nil, !stopped else { return }
    if pending == nil && clearRequested {
      clearRequested = false; let renderer = renderer
      running = Task { [weak self] in await renderer.clear(); self?.running = nil; self?.start() }
      return
    }
    guard let request = pending else { return }
    pending = nil; active = request; let renderer = renderer
    running = Task { [weak self] in
      let result: Result<NativeCursorBatch, any Error>
      do { result = .success(try await renderer.render(request)) } catch { result = .failure(error) }
      self?.finish(request, result)
    }
  }
  private func finish(_ request: NativeCursorRequest, _ result: Result<NativeCursorBatch, any Error>) {
    running = nil; active = nil
    guard !stopped else { return }
    if let latest, request.hasSamePresentation(as: latest) {
      switch result {
      case .success(let batch): onFrame(batch)
      case .failure(let error):
        if !(error is CancellationError) && request == latest { self.latest = nil; onError(error) }
      }
    }
    start()
  }
  func reset() { guard !stopped else { return }; latest = nil; pending = nil; clearRequested = true; running?.cancel(); start() }
  func stop() { stopped = true; latest = nil; pending = nil; clearRequested = false; running?.cancel() }
  func close() async { stop(); let join = running; await join?.value; await renderer.clear() }
}
