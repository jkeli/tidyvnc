// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import CoreGraphics
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }
final class WeakImage { weak var value: NativeImage?; init(_ value: NativeImage?) { self.value = value } }
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Cursor timed out")
}
@main struct NativeCursorTests {
  @MainActor static func main() async {
    do { try await run() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
  @MainActor static func run() async throws {
    let peer = native_test_peer_create_pattern(0)!
    defer { native_test_peer_destroy(peer) }
    let runtime = try NativeRuntime()
    var config = NativeSessionConfiguration(); config.securityTypes = [1]
    let session = try runtime.makeSession(configuration: config)
    _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
    try await until { session.frame != nil }
    native_test_peer_cursor_alpha(peer); try await until { session.cursor != nil }
    var image = session.cursor
    let released = WeakImage(image)
    let sampler = try await Task.detached { [image = image!] in
      try NativeCursorSampler(image: image, scaleX: 2, scaleY: 1, filter: .bilinear)
    }.value
    try check(sampler.width == 4 && sampler.height == 1 && sampler.hotspotX == 2 && sampler.hotspotY == 0 && sampler.sourceBytes == 8,
      "shared rounded cursor geometry and original-only source bytes")
    let rect = NativePixelRect(x: 0, y: 0, width: 4, height: 1)
    let expected = Data([0,0,0,0, 0,255,0,64, 0,255,0,191, 0,255,0,255])
    let tile = try await Task.detached { try sampler.render(rect) }.value
    try check(tile.pixels == expected && tile.image.alphaInfo == .last, "premultiplied filtering avoids transparent red fringes; CG output is straight RGBA")
    for filter in NativeScalingFilter.allCases {
      let result = try await Task.detached { [image = image!] in
        let identity = try NativeCursorSampler(image: image, scaleX: 1, scaleY: 1, filter: filter)
        return try identity.render(NativePixelRect(x: 0, y: 0, width: 2, height: 1))
      }.value
      try check(result.pixels == Data([0,0,0,0,0,255,0,255]), "identity preserves visible colors and clears transparent RGB")
    }
    let reduced = try await Task.detached { [image = image!] in
      let worker = try NativeCursorSampler(image: image, scaleX: 0.25, scaleY: 0.5, filter: .area)
      try check(worker.width == 1 && worker.height == 1 && worker.hotspotX == 0, "subpixel size rounds to one and hotspot clamps")
      return try worker.render(NativePixelRect(x: 0, y: 0, width: 1, height: 1))
    }.value
    try check(reduced.pixels == Data([0,255,0,128]), "area filtering averages premultiplied alpha")
    let huge = try await Task.detached { [image = image!] in
      let worker = try NativeCursorSampler(image: image, scaleX: 65535, scaleY: 1000, filter: .nearest)
      try check(worker.width == 131070 && worker.height == 1000 && worker.sourceBytes == 8, "extreme zoom retains only original source")
      return try worker.render(NativePixelRect(x: 65534, y: 500, width: 2, height: 1))
    }.value
    try check(huge.pixels == Data([0,0,0,0,0,255,0,255]), "visible tile straddles extreme-zoom boundary")
    do {
      _ = try await Task.detached { [frame = session.frame!] in try NativeCursorSampler(image: frame, scaleX: 1, scaleY: 1, filter: .nearest) }.value
      throw Failure(message: "Framebuffer accepted as cursor")
    } catch let error as NativeError { try check(error.status == .unsupported, "typed cursor-only service") }
    do { _ = try sampler.render(NativePixelRect(x: .max, y: 0, width: 1, height: 1)); throw Failure(message: "Invalid tile") }
    catch let error as NativeError { try check(error.status == .invalidArgument, "tile bounds preflight") }
    native_test_peer_cursor(peer, 0); try await until { session.cursor == nil }; image = nil
    try await until { released.value == nil }
    try await session.close(); try await runtime.shutdown()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { for _ in 0..<20 { let result = try sampler.render(rect); try check(result.pixels == expected, "concurrent immutable samples after close") } } }
      try await group.waitForAll()
    }
    let cancelled = Task.detached { while !Task.isCancelled { await Task.yield() }; return try sampler.render(rect) }
    cancelled.cancel()
    do { _ = try await cancelled.value; throw Failure(message: "Cancelled cursor rendered") } catch is CancellationError {}
    try check((tile.image.dataProvider!.data! as Data) == expected, "tile provider survives source, session and runtime")
    print("PASS cursor alpha goldens, all filters, identity, anisotropic/extreme scaling, clamped hotspot, bounded visible tiles, concurrent reads, cancellation and released source")
  }
}
