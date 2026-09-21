// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_cursor_options: ABIValue {}
extension tidyvnc_cursor_geometry: ABIValue {}
extension tidyvnc_cursor_tile: ABIValue {}

// Immutable shared sampler. Construct/sample off MainActor: area filtering can
// traverse the original source inside a tile. No enlarged cursor is retained.
// The C sampler owns its premultiplied source copy, not the session/image lease.
final class NativeCursorSampler: @unchecked Sendable {
  private let handle: NativeHandle
  let width: UInt32, height: UInt32, hotspotX: UInt32, hotspotY: UInt32
  let sourceBytes: UInt64
  let isBlank: Bool
  init(image: NativeImage, scaleX: Double, scaleY: Double, filter: NativeScalingFilter) throws {
    try Task.checkCancellation()
    var options = abi(tidyvnc_cursor_options.self), geometry = abi(tidyvnc_cursor_geometry.self)
    options.scale_x = scaleX; options.scale_y = scaleY; options.quality = filter.rawValue
    var raw: UInt64 = 0
    try checked { tidyvnc_cursor_renderer_create(image.handle.raw, &options, &raw, &geometry, $0) }
    handle = NativeHandle(adopting: raw)
    width = geometry.width; height = geometry.height; hotspotX = geometry.hotspot_x; hotspotY = geometry.hotspot_y
    sourceBytes = geometry.source_bytes
    isBlank = geometry.blank != 0
    try Task.checkCancellation()
  }
  func render(_ rect: NativePixelRect) throws -> NativeRenderedTile {
    try Task.checkCancellation()
    guard rect.width > 0, rect.width <= 256, rect.height > 0, rect.height <= 256,
          rect.x <= width, rect.width <= width-rect.x, rect.y <= height, rect.height <= height-rect.y else {
      throw NativeError(.invalidArgument, "Invalid cursor tile")
    }
    var tile = abi(tidyvnc_cursor_tile.self)
    tile.x = rect.x; tile.y = rect.y; tile.width = rect.width; tile.height = rect.height
    let storage = NativeTilePixels(count: Int(rect.width)*Int(rect.height)*4)
    try checked { tidyvnc_cursor_renderer_render(handle.raw, &tile,
      tidyvnc_mutable_bytes(data: storage.pointer.assumingMemoryBound(to: UInt8.self), length: UInt64(storage.count)), $0) }
    try Task.checkCancellation()
    return try NativeRenderedTile(rect: rect, storage: storage, straightRGBA: true)
  }
}
