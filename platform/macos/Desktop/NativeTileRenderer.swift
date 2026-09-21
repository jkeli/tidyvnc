// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import CoreGraphics
import TidyVNC

extension tidyvnc_tile_options: ABIValue {}
extension tidyvnc_tile_result: ABIValue {}
public enum NativeScalingFilter: UInt32, Sendable, CaseIterable { case nearest = 0, bilinear, area }

struct NativeTileRequest: Sendable, Equatable {
  let image: NativeImage
  let width: UInt32, height: UInt32
  let visible: NativePixelRect
  let filter: NativeScalingFilter
  static func == (a: Self, b: Self) -> Bool { a.image === b.image && a.hasSamePresentation(as: b) }
  func hasSamePresentation(as other: Self) -> Bool {
    hasSameRaster(as: other) && visible == other.visible
  }
  func hasSameRaster(as other: Self) -> Bool {
    image.streamID == other.image.streamID && image.generation == other.image.generation &&
      image.sizeGeneration == other.image.sizeGeneration && width == other.width && height == other.height && filter == other.filter
  }
}
// One allocation is written by the actor before publication and then immutable.
// The CG provider retains it directly; composition does not copy the tile into Data.
final class NativeTilePixels: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer
  let count: Int
  init(count: Int) { self.count = count; pointer = .allocate(byteCount: count, alignment: 16) }
  deinit { pointer.deallocate() }
}
struct NativeRenderedTile: @unchecked Sendable {
  let rect: NativePixelRect
  let image: CGImage
  private let storage: NativeTilePixels
  var pixels: Data { Data(bytes: storage.pointer, count: storage.count) } // Explicit diagnostic/test copy only.
  init(rect: NativePixelRect, storage: NativeTilePixels, straightRGBA: Bool = false) throws {
    let retained = Unmanaged.passRetained(storage)
    guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: storage.pointer, size: storage.count, releaseData: { context, _, _ in
      if let context { Unmanaged<NativeTilePixels>.fromOpaque(context).release() }
    }) else { retained.release(); throw NativeError(.outOfMemory, "Could not retain tile pixels") }
    let layout = straightRGBA ? CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)) :
      CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
    guard let image = CGImage(width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: Int(rect.width)*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: layout,
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
      throw NativeError(.failed, "Could not create desktop tile")
    }
    self.rect = rect; self.storage = storage; self.image = image
  }
}
struct NativeTileBatch: Sendable {
  let request: NativeTileRequest
  let tiles: [NativeRenderedTile]
  let bytes: Int, cacheBytes: UInt64, cacheHits: Int, reusedTiles: Int, renderedBytes: Int
  init(request: NativeTileRequest, tiles: [NativeRenderedTile], bytes: Int, cacheBytes: UInt64, cacheHits: Int,
       reusedTiles: Int = 0, renderedBytes: Int = 0) {
    self.request = request; self.tiles = tiles; self.bytes = bytes; self.cacheBytes = cacheBytes; self.cacheHits = cacheHits
    self.reusedTiles = reusedTiles; self.renderedBytes = renderedBytes
  }
}
struct NativeTileGrid {
  let left: UInt32, top: UInt32, right: UInt32, bottom: UInt32
  let bytes: Int, count: Int
  init(_ request: NativeTileRequest) throws {
    try self.init(width: request.width, height: request.height, visible: request.visible)
  }
  init(width: UInt32, height: UInt32, visible: NativePixelRect, maximumDimension: UInt32 = 65535) throws {
    guard maximumDimension <= UInt32(Int32.max/4), width > 0, width <= maximumDimension, height > 0, height <= maximumDimension,
          visible.x <= width, visible.y <= height,
          visible.width <= width-visible.x, visible.height <= height-visible.y else {
      throw NativeError(.invalidArgument, "Invalid visible desktop region")
    }
    if visible.width == 0 || visible.height == 0 { left = 0; top = 0; right = 0; bottom = 0; bytes = 0; count = 0; return }
    left = visible.x / 256 * 256; top = visible.y / 256 * 256
    right = min(width, (visible.x + visible.width + 255) / 256 * 256)
    bottom = min(height, (visible.y + visible.height + 255) / 256 * 256)
    let payload = UInt64(right-left) * UInt64(bottom-top) * 4
    count = Int((right-left+255)/256) * Int((bottom-top+255)/256)
    guard payload <= NativeTileRenderer.byteLimit, count <= NativeTileRenderer.tileLimit else {
      throw NativeError(.resourceLimit, "Visible desktop exceeds the tile presentation budget. Reduce the window size or scaling.")
    }
    bytes = Int(payload)
  }
}
protocol NativeTileRendering: Sendable {
  func render(_ request: NativeTileRequest) async throws -> NativeTileBatch
  func clear() async throws
}

// The actor serializes cache use off MainActor. The scheduler below bounds
// admission; callers should not enqueue arbitrary independent actor requests.
actor NativeTileRenderer: NativeTileRendering {
  private let handle: NativeHandle
  private var previous: NativeTileBatch?
  static let byteLimit = 64 * 1024 * 1024
  static let tileLimit = 1024
  init(cacheBytes: UInt64 = 8 * 1024 * 1024) throws {
    var value: UInt64 = 0
    try checked { tidyvnc_renderer_create(cacheBytes, &value, $0) }
    handle = NativeHandle(adopting: value)
  }
  func clear() throws { previous = nil; try checked { tidyvnc_renderer_clear(handle.raw, $0) } }
  func render(_ request: NativeTileRequest) throws -> NativeTileBatch {
    try Task.checkCancellation()
    let grid = try NativeTileGrid(request)
    guard grid.count > 0 else {
      try clear()
      return NativeTileBatch(request: request, tiles: [], bytes: 0, cacheBytes: 0, cacheHits: 0)
    }
    var reusable: [NativePixelRect: NativeRenderedTile] = [:]
    var damage = CGRect.infinite
    if let previous, request.hasSameRaster(as: previous.request),
       previous.request.image.sequence == request.image.sequence || previous.request.image.sequence == request.image.previousSequence {
      reusable = Dictionary(uniqueKeysWithValues: previous.tiles.map { ($0.rect, $0) })
      if previous.request.image.sequence == request.image.sequence { damage = .zero }
      else {
        let transform = try NativeGeometry(width: request.image.width, height: request.image.height,
          viewport: CGSize(width: Int(request.width), height: Int(request.height)), backingScale: 1,
          scaling: "\(request.width)x\(request.height)", devicePixels: true)
        damage = try transform.damageRectangle(request.image.damage, filter: request.filter)
      }
    }
    var options = abi(tidyvnc_tile_options.self)
    options.width = request.width; options.height = request.height; options.quality = request.filter.rawValue
    options.previous_sequence = request.image.previousSequence
    options.damage_x = request.image.damage.x; options.damage_y = request.image.damage.y
    options.damage_width = request.image.damage.width; options.damage_height = request.image.damage.height
    var tiles: [NativeRenderedTile] = []; tiles.reserveCapacity(grid.count)
    var hits = 0, reused = 0, renderedBytes = 0, cacheBytes = previous?.cacheBytes ?? 0
    for y in stride(from: grid.top, to: grid.bottom, by: 256) {
      for x in stride(from: grid.left, to: grid.right, by: 256) {
        try Task.checkCancellation()
        options.x = x; options.y = y; options.tile_width = min(256, request.width-x); options.tile_height = min(256, request.height-y)
        let rect = NativePixelRect(x: x, y: y, width: options.tile_width, height: options.tile_height)
        let rectangle = CGRect(x: Int(x), y: Int(y), width: Int(rect.width), height: Int(rect.height))
        if let tile = reusable[rect], damage.isEmpty || !rectangle.intersects(damage) {
          tiles.append(tile); reused += 1; continue
        }
        let storage = NativeTilePixels(count: Int(rect.width)*Int(rect.height)*4)
        var result = abi(tidyvnc_tile_result.self)
        try checked { tidyvnc_renderer_render(handle.raw, request.image.handle.raw, &options,
          tidyvnc_mutable_bytes(data: storage.pointer.assumingMemoryBound(to: UInt8.self), length: UInt64(storage.count)), &result, $0) }
        cacheBytes = result.cache_bytes; if result.cache_hit != 0 { hits += 1 }; renderedBytes += storage.count
        tiles.append(try NativeRenderedTile(rect: rect, storage: storage))
      }
    }
    try Task.checkCancellation()
    let batch = NativeTileBatch(request: request, tiles: tiles, bytes: grid.bytes, cacheBytes: cacheBytes, cacheHits: hits,
      reusedTiles: reused, renderedBytes: renderedBytes)
    previous = batch; return batch
  }
}

// At most one render is running and one latest request is retained. A newer
// frame with the same presentation does not cancel useful work (avoids starvation
// under continuous updates); transform/source changes cancel at a tile boundary.
@MainActor final class NativeTileScheduler {
  private let renderer: any NativeTileRendering
  private var latest: NativeTileRequest?
  private var pending: NativeTileRequest?
  private var active: NativeTileRequest?
  private var running: Task<Void, Never>?
  private var stopped = false
  private var clearRequested = false
  var onFrame: (NativeTileBatch) -> Void = { _ in }
  var onError: (any Error) -> Void = { _ in }
  var isRunning: Bool { running != nil }
  var pendingCount: Int { pending == nil ? 0 : 1 }
  init(renderer: any NativeTileRendering) { self.renderer = renderer }
  deinit { running?.cancel() }
  func submit(_ request: NativeTileRequest) {
    guard !stopped, latest != request else { return }
    latest = request; pending = request; clearRequested = false
    if let active, !active.hasSamePresentation(as: request) { running?.cancel() }
    start()
  }
  private func start() {
    guard running == nil, !stopped else { return }
    if pending == nil && clearRequested {
      clearRequested = false
      let renderer = renderer
      running = Task { [weak self] in
        try? await renderer.clear()
        self?.running = nil; self?.start()
      }
      return
    }
    guard let request = pending else { return }
    pending = nil; active = request
    let renderer = renderer
    running = Task { [weak self] in
      let result: Result<NativeTileBatch, any Error>
      do { result = .success(try await renderer.render(request)) }
      catch { result = .failure(error) }
      self?.finish(request, result: result)
    }
  }
  private func finish(_ request: NativeTileRequest, result: Result<NativeTileBatch, any Error>) {
    active = nil; running = nil
    guard !stopped else { return }
    if let latest, request.hasSamePresentation(as: latest) {
      switch result {
      case .success(let batch): onFrame(batch)
      case .failure(let error):
        if !(error is CancellationError) && request == latest {
          self.latest = nil // The same request can be explicitly retried after failure.
          onError(error)
        }
      }
    }
    start()
  }
  func reset() {
    guard !stopped else { return }
    latest = nil; pending = nil; clearRequested = true; running?.cancel(); start()
  }
  func stop() { stopped = true; clearRequested = false; pending = nil; latest = nil; running?.cancel() }
  func close() async {
    stop(); let join = running
    await join?.value
    try? await renderer.clear()
  }
}
