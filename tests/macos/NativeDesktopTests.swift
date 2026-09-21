// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeKeyMap
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
@MainActor final class ViewReference {
  weak var value: NativeDesktopView?
  init(_ value: NativeDesktopView?) { self.value = value }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }
@MainActor func until(_ message: String = "native display", _ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out waiting for \(message)")
}
@MainActor func run() async throws {
  _ = NSApplication.shared
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime()
  var config = NativeSessionConfiguration(); config.securityTypes = [1]
  let session = try runtime.makeSession(configuration: config)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let view = NativeDesktopView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
  try check(view.filter == .bilinear, "native view defaults to bilinear like retained frontend")
  view.filter = .nearest // This fixture checks unblended source quadrants and orientation.
  window.contentView = view; view.bind(session)
  var errors: [String] = []; view.onError = { errors.append($0) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { (try? session.frame?.copyPixels().prefix(4)) == Data([0,0,255,0]) }
  try await until { view.displayedSequence == session.frame?.sequence && !view.isRendering }
  try check(view.displayedImage != nil, "frame delivered to AppKit")
  try check(view.desktopRectangle == CGRect(x: 50, y: 0, width: 200, height: 200), "letterbox placement")
  let retained = view.displayedImage!
  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
  view.cacheDisplay(in: view.bounds, to: bitmap)
  let sx = CGFloat(bitmap.pixelsWide)/view.bounds.width, sy = CGFloat(bitmap.pixelsHigh)/view.bounds.height
  // AppKit caches into the current display profile (e.g. Color LCD/P3).
  // Convert the bitmap itself: colorAt does not preserve this ICC profile.
  let normalized = bitmap.converting(to: .sRGB, renderingIntent: .default)!
  func color(_ x: CGFloat, _ y: CGFloat) -> NSColor { normalized.colorAt(x: Int(x*sx), y: Int(y*sy))!.usingColorSpace(.sRGB)! }
  let red = color(75,25), green = color(175,25), blue = color(75,125), white = color(175,125)
  if !(red.redComponent > 0.9 && red.blueComponent < 0.1 && green.greenComponent > 0.9 && green.redComponent < 0.1) {
    print("Render diagnostic: \(red), \(green), \(blue), \(white); \(bitmap.colorSpace); \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    if let data = bitmap.representation(using: .png, properties: [:]) {
      try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("desktop-failure.png"))
    }
  }
  try check(red.redComponent > 0.9 && red.blueComponent < 0.1 && green.greenComponent > 0.9 && green.redComponent < 0.1,
    "top source row is red/green with opaque padding")
  try check(blue.blueComponent > 0.9 && blue.redComponent < 0.1 && white.redComponent > 0.9 && white.greenComponent > 0.9,
    "bottom source row is blue/white")
  try check(color(10,100).redComponent < 0.1, "black letterbox")
  print("PASS AppKit retained image, channels, opaque alpha, row orientation and letterbox")
  // Explicit core focus avoids stealing the user's foreground app in this test.
  await Task.yield()
  _ = window.makeFirstResponder(view); try session.setFocused(true)
  let point = view.convert(CGPoint(x: 200, y: 150), to: nil)
  let moved = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
  view.mouseMoved(with: moved)
  try await until("pointer") { native_test_peer_has_input(peer,5,0,1,1) != 0 }
  let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0)!
  view.keyDown(with: down)
  try await until("key press") { native_test_peer_has_input(peer,1,65,0,0) != 0 }
  _ = view.resignFirstResponder()
  try await until("focus-loss release") { native_test_peer_has_input(peer,0,65,0,0) != 0 }
  try check(native_macos_qnum(0) == 0x1e && native_macos_special_keysym(123) == 0xff51,
    "shared hardware/scancode tables")
  print("PASS view pointer mapping, hardware key and focus-loss wire release")
  native_test_peer_resize(peer)
  try await until { session.frame?.width == 3 && view.displayedImage?.width == 3 }
  try check(view.desktopRectangle.height > 0 && view.desktopRectangle.height < 101, "resize updates transform")
  view.detach(); window.contentView = nil; window.close()
  try await session.close(); try await runtime.shutdown()
  let retainedBytes = retained.dataProvider!.data! as Data
  try check(retainedBytes.prefix(4) == Data([0,0,255,0]) && retained.width == 2, "CG provider owns old lease through resize, detach and shutdown")
  try check(errors.isEmpty, "no rendering or input errors")
  print("PASS server resize, detached view and old CG image after runtime shutdown")
  let repeated = try NativeRuntime()
  for _ in 0..<12 {
    let source = native_test_peer_create_pattern(0)!
    let current = try repeated.makeSession(configuration: config)
    var temporary: NativeDesktopView? = NativeDesktopView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let released = ViewReference(temporary)
    temporary!.bind(current)
    _ = try await current.connect(endpoint: "127.0.0.1::\(native_test_peer_port(source))")
    try await until { current.frame != nil }
    native_test_peer_resize(source)
    temporary!.detach(); temporary = nil
    try await current.close()
    native_test_peer_destroy(source)
    await Task.yield()
    try check(released.value == nil, "removed view released while resize delivery was active")
  }
  try await repeated.shutdown()
  print("PASS 12 view removals with server resize in flight")
}
@main struct NativeDesktopTests {
  @MainActor static func main() async {
    do { try await run() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
