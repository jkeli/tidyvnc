// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_display_layout_request: ABIValue {}
extension tidyvnc_display_layout: ABIValue {}

public struct NativeDisplayRegion: Equatable, Sendable, Identifiable {
  public let display: NativeDisplay
  public var id: NativeDisplayID { display.id }
  public let x: UInt32, y: UInt32, width: UInt32, height: UInt32
}

// A value-only adapter to the retained viewer's shared DesktopLayout algorithm.
// Local UUIDs never become RFB identities or unstable saved monitor indices.
public struct NativeDisplayLayout: Equatable, Sendable {
  public let width: UInt32, height: UInt32
  public let normalized: Bool
  public let devicePixels: Bool
  public let regions: [NativeDisplayRegion]
  public init(displays: [NativeDisplay], devicePixels: Bool) throws {
    guard !displays.isEmpty, displays.count <= 64, Set(displays.map(\.id)).count == displays.count else {
      throw NativeError(.invalidArgument,"Invalid display selection")
    }
    let ordered = displays.sorted { $0.id.rawValue < $1.id.rawValue }
    let monitors = try ordered.enumerated().map { index, display -> tidyvnc_display_monitor in
      let b = display.bounds
      // AppKit's display frames use integral logical points. Reject fractional
      // boundaries rather than silently changing their adjacency or overlap.
      guard [b.x,b.y,b.width,b.height].allSatisfy({ $0.isFinite && $0.rounded(.towardZero) == $0 }),
            abs(b.x) <= 1_000_000, abs(b.y) <= 1_000_000,
            b.width >= 1, b.width <= 65535, b.height >= 1, b.height <= 65535,
            display.backingScale.isFinite, display.backingScale > 0 else {
        throw NativeError(.invalidArgument,"Invalid display geometry")
      }
      let bw = (b.width * display.backingScale).rounded(.down)
      let bh = (b.height * display.backingScale).rounded(.down)
      guard bw.isFinite, bh.isFinite, bw >= 1, bh >= 1, bw <= 65535, bh <= 65535 else {
        throw NativeError(.resourceLimit,"Display exceeds layout limits")
      }
      return .init(id:UInt32(index),x:Int32(b.x),y:Int32(b.y),width:UInt32(b.width),height:UInt32(b.height),
        backing_width:UInt32(bw),backing_height:UInt32(bh))
    }
    var output = abi(tidyvnc_display_layout.self)
    try monitors.withUnsafeBufferPointer { buffer in
      var request = abi(tidyvnc_display_layout_request.self)
      request.monitor_count = UInt32(buffer.count); request.device_pixels = devicePixels ? 1 : 0
      request.monitors = buffer.baseAddress
      try checked { tidyvnc_display_layout_compute(&request,&output,$0) }
    }
    self.devicePixels = devicePixels
    width = output.width; height = output.height; normalized = output.normalized != 0
    regions = withUnsafeBytes(of:output.screens) { bytes in
      bytes.bindMemory(to:tidyvnc_remote_screen.self).prefix(Int(output.screen_count)).map {
        NativeDisplayRegion(display:ordered[Int($0.id)],x:$0.x,y:$0.y,width:$0.width,height:$0.height)
      }
    }
  }
  public func viewport(for id: NativeDisplayID) throws -> NativeCanvasViewport {
    guard let region = regions.first(where:{ $0.id == id }) else { throw NativeError(.invalidArgument,"Display is not in this canvas") }
    return try NativeCanvasViewport(width:width,height:height,
      region:.init(x:region.x,y:region.y,width:region.width,height:region.height),devicePixels:devicePixels)
  }
  public func remoteLayout(matching baseline: NativeRemoteLayout) throws -> NativeRemoteLayout {
    // Preserve exact geometry identities first, then reuse the remaining server
    // IDs in numeric order. New screens receive the lowest unused RFB ID. Reserve
    // all baseline IDs so a new screen cannot accidentally claim a removed one.
    var remaining = baseline.screens.sorted { $0.id < $1.id }
    var identities: [NativeDisplayID:NativeRemoteScreen] = [:]
    for region in regions {
      if let index = remaining.firstIndex(where: { $0.x == region.x && $0.y == region.y && $0.width == region.width && $0.height == region.height }) {
        identities[region.id] = remaining.remove(at:index)
      }
    }
    var used = Set(baseline.screens.map(\.id)), candidate: UInt32 = 0
    let screens = regions.map { region -> NativeRemoteScreen in
      let identity: NativeRemoteScreen?
      if let exact = identities[region.id] { identity = exact }
      else if !remaining.isEmpty { identity = remaining.removeFirst() }
      else { identity = nil }
      let id: UInt32
      if let identity { id = identity.id }
      else {
        while used.contains(candidate) { candidate += 1 }
        id = candidate; used.insert(id)
      }
      return NativeRemoteScreen(id:id,x:region.x,y:region.y,width:region.width,height:region.height,flags:identity?.flags ?? 0)
    }
    return try NativeRemoteLayout(width:width,height:height,screens:screens)
  }
}
