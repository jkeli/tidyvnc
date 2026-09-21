// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message: message) }
}
@MainActor func until(_ condition: () async -> Bool) async throws {
  for _ in 0..<2000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Panning timed out")
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message: "Panning must not write preferences") }
}
@MainActor final class ViewReference {
  weak var value: NativeDesktopView?
  init(_ value: NativeDesktopView) { self.value = value }
}
actor GatedRenderer: NativeTileRendering {
  let renderer: NativeTileRenderer
  var held = false
  private(set) var waiting = false
  private var continuation: CheckedContinuation<Void, Never>?
  init() throws { renderer = try NativeTileRenderer() }
  func hold() { held = true }
  func release() { held = false; waiting = false; let old = continuation; continuation = nil; old?.resume() }
  func render(_ request: NativeTileRequest) async throws -> NativeTileBatch {
    if held { waiting = true; await withCheckedContinuation { continuation = $0 } }
    return try await renderer.render(request)
  }
  func clear() async throws { try await renderer.clear() }
}
func geometry() throws {
  for scale in [1.0, 1.25, 1.5, 2.0, 3.0] {
    for device in [false, true] {
      for mode in ["100", "Auto", "FixedRatio", "FitWidth", "FitHeight", "1920x1080", "137.5", "125%x80%"] {
        let viewport = CGSize(width: 301.25, height: 199.5)
        let value = try NativeGeometry(width: 800, height: 600, viewport: viewport, backingScale: scale,
          scaling: mode, devicePixels: device, pan: CGPoint(x: 65535, y: 65535))
        let unit = device ? scale : 1
        let limited = try NativeGeometry(width: 800, height: 600, viewport: viewport, backingScale: scale,
          scaling: mode, devicePixels: device, pan: value.panPosition)
        try check(value.rectangle == limited.rectangle, "stored limit matches shared placement for \(mode)/\(scale)/\(device)")
        try check(value.panPosition == value.panLimit && value.panned(.right) == value.panPosition && value.panned(.down) == value.panPosition, "bounded end of each axis")
        try check(value.panned(.origin) == .zero, "origin always resets both axes")
        if value.panLimit.x > 0 {
          try check(abs(value.rectangle.maxX - ceil(viewport.width * unit)/unit) <= 1/scale, "right edge uses shared rounded canvas")
        }
        if value.panLimit.y > 0 {
          try check(abs(value.rectangle.maxY - ceil(viewport.height * unit)/unit) <= 1/scale, "bottom edge uses shared rounded canvas")
        }
      }
    }
  }
  print("PASS all eight modes, fractional backing scales, logical/device units and shared edge clamping")
}
@MainActor func integration() async throws {
  _ = NSApplication.shared
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let model = ConnectionModel(runtime: runtime, preferences: preferences) { _, _ in }
  try await until { model.defaults?.isReady == true }
  let session = model.session!, commands = model.desktopCommands, worker = try GatedRenderer()
  let view = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
  let window = NSWindow(contentRect: view.bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.contentView = view
  defer { view.detach(); window.contentView = nil; window.close() }
  view.rendererOverride = worker; view.bind(session); view.observeCommands(commands); view.observeScaling(model.scaling)
  var errors: [String] = []; view.onError = { errors.append($0) }
  try check(!commands.canPerform(.pan(.right)), "idle pan unavailable")
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { view.displayedImage != nil && !view.isRendering }
  let draft = NativeScalingDraft(state: model.scaling); draft.mode = .exact; draft.text = "600x400"; draft.filter = .nearest
  try check(draft.apply(), "oversized desktop applies")
  try await until { !view.isRendering }
  try check(view.pan == .zero && commands.canPerform(.pan(.right)) && commands.canPerform(.pan(.down)) && !commands.canPerform(.pan(.left)), "origin availability")
  let names = view.accessibilityCustomActions()?.map(\.name) ?? []
  try check(names == ["Focus remote desktop", "Pan Right", "Pan Down"], "available accessibility actions have descriptive names")

  // Dispatch the actual native menu, leaving the user's foreground app alone.
  let popup = DesktopContextMenu(model: model), menu = popup.makeMenu()
  let panMenu = menu.items.first { $0.title == "Pan Desktop" }!.submenu!
  let right = panMenu.items.first { $0.title == "Pan Right" }!
  try check(right.isEnabled && !panMenu.items.first { $0.title == "Pan Left" }!.isEnabled, "native submenu edge gating")
  try check(NSApp.sendAction(right.action!, to: right.target, from: right), "native pan menu dispatch")
  try await until { !view.isRendering }
  try check(view.pan == CGPoint(x: 240, y: 0) && view.desktopRectangle.minX == -240, "menu pans eighty percent of viewport")
  try commands.perform(.pan(.right)); try commands.perform(.pan(.down)); try commands.perform(.pan(.down))
  try await until { !view.isRendering }
  try check(view.pan == CGPoint(x: 300, y: 200) && !commands.canPerform(.pan(.right)) && !commands.canPerform(.pan(.down)), "repeated pending commands stop at bottom right")
  let old = view.pan
  do { try commands.perform(.pan(.right)); throw Failure(message: "past-edge command accepted") }
  catch NativeDesktopCommandIssue.unavailable {}
  try check(view.pan == old, "rejected command leaves position unchanged")
  let quality = NativeScalingDraft(state: model.scaling); quality.filter = .bilinear
  try check(quality.apply(), "filter-only apply")
  try await until { !view.isRendering }
  try check(view.pan == old, "filter-only change preserves valid pan")

  // Accessibility dispatch works in view-only mode and does not acquire remote focus.
  try session.setViewOnly(true); try session.setFocused(false)
  let origin = view.accessibilityCustomActions()!.first { $0.name == "Return to Top Left" }!
  try check(NSApp.sendAction(origin.selector!, to: origin.target, from: nil), "accessibility action dispatch")
  try await until { !view.isRendering }
  try check(view.pan == .zero && !session.isFocused && commands.canPerform(.pan(.right)), "local pan permits view-only without stealing focus")
  try session.setViewOnly(false)

  // Pixels and their inverse input transform change together, even with delayed work.
  await worker.hold()
  try commands.perform(.pan(.right)); try commands.perform(.pan(.right))
  try commands.perform(.pan(.down)); try commands.perform(.pan(.down))
  try await until { await worker.waiting }
  try check(view.desktopRectangle.origin == .zero, "pending pan keeps old displayed geometry")
  func move() {
    let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(CGPoint(x: 20, y: 20), to: nil),
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    view.mouseMoved(with: event)
  }
  try session.setFocused(true); move()
  try await until { native_test_peer_has_input(peer, 5, 0, 0, 0) != 0 }
  await worker.release(); try await until { !view.isRendering }
  try check(view.desktopRectangle.origin == CGPoint(x: -300, y: -200), "latest pan publishes with rendered pixels")
  try session.setFocused(true); move()
  try await until { native_test_peer_has_input(peer, 5, 0, 1, 1) != 0 }

  // Resize clamps stored offsets; returning to a small viewport must not jump back.
  view.setFrameSize(CGSize(width: 550, height: 350)); view.layout()
  try await until { !view.isRendering }
  try check(view.pan == CGPoint(x: 50, y: 50), "larger viewport clamps both offsets")
  view.setFrameSize(CGSize(width: 700, height: 500)); view.layout()
  try await until { !view.isRendering }
  try check(view.pan == .zero && NativeDesktopPan.allCases.allSatisfy { !commands.canPerform(.pan($0)) }, "fitting desktop has no pan actions")
  view.setFrameSize(CGSize(width: 300, height: 200)); view.layout()
  try await until { !view.isRendering }
  try check(view.pan == .zero, "reshrinking viewport does not restore stale offsets")
  try commands.perform(.pan(.right)); try await until { !view.isRendering }
  view.isHidden = true
  try check(!commands.canPerform(.pan(.left)) && view.accessibilityCustomActions()?.count == 1, "hidden view drops pan actions")
  view.isHidden = false; try await until { !view.isRendering }
  try check(commands.canPerform(.pan(.left)), "unhidden view restores available actions")

  let q = window.backingScaleFactor
  let units = NativeScalingDraft(state: model.scaling); units.mode = .exact
  units.text = "\(Int(600*q))x\(Int(400*q))"; units.devicePixels = true
  try check(units.apply(), "device unit change applies")
  try await until { !view.isRendering }
  try check(view.pan == .zero, "unit change resets pan")
  try commands.perform(.pan(.right)); try await until { !view.isRendering }
  try check(view.pan.x == 240*q && view.desktopRectangle.minX == -240, "device-unit action still moves one logical viewport fraction")

  // A second presentation has independent pan, menus and weak action ownership.
  let otherCommands = NativeDesktopCommands(); otherCommands.bind(session)
  var other: NativeDesktopView? = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
  let released = ViewReference(other!)
  let otherWindow = NSWindow(contentRect: other!.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  otherWindow.isReleasedWhenClosed = false; otherWindow.contentView = other
  other!.bind(session); other!.scaling = "600x400"; other!.observeCommands(otherCommands)
  try await until { other!.displayedImage != nil && !other!.isRendering }
  try otherCommands.perform(.pan(.down)); try await until { !other!.isRendering }
  try check(other!.pan == CGPoint(x: 0, y: 160) && view.pan == CGPoint(x: 240*q, y: 0), "pan targets only owning presentation")
  other!.detach(); otherWindow.contentView = nil; other = nil; otherWindow.close()
  try await until { released.value == nil }
  try check(released.value == nil && !otherCommands.canPerform(.pan(.up)), "accessibility and command routing do not retain removed view")
  otherCommands.stop()

  let width = NativeScalingDraft(state: model.scaling); width.mode = .fitWidth
  try check(width.apply(), "fit width applies")
  try await until { !view.isRendering }
  try commands.perform(.pan(.down)); try await until { !view.isRendering }
  native_test_peer_resize(peer)
  try await until { session.frame?.width == 3 && view.displayedImage?.width == 3 && !view.isRendering }
  try check(view.pan == .zero && !commands.canPerform(.pan(.up)) && !commands.canPerform(.pan(.down)), "remote resize clamps pan when fitted aspect ratio changes")
  _ = try await session.disconnect()
  try check(NativeDesktopPan.allCases.allSatisfy { !commands.canPerform(.pan($0)) }, "disconnected pan unavailable")
  let reconnect = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(reconnect) }
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(reconnect))")
  try await until { view.displayedImage?.width == 2 && !view.isRendering }
  try check(view.pan == .zero && commands.canPerform(.pan(.down)), "reconnect starts at origin with fresh available actions")
  try commands.perform(.pan(.down)); try await until { !view.isRendering }
  model.requestClose()
  try await until { session.isClosing }
  try check(!view.panDesktop(.up) && view.accessibilityCustomActions()?.count == 1, "close rejects stale accessibility action")
  view.detach()
  try check(view.pan == .zero && view.accessibilityCustomActions()?.count == 1, "detach clears pan and accessibility targets")
  await model.close(); await preferences.close(); try await runtime.shutdown()
  try check(errors.isEmpty, "no rendering errors")
  print("PASS actual menu/accessibility routing, boundaries, view-only, coherent wire mapping, filter preservation, resize, hide and detach")
}
@main struct NativePanningTests {
  @MainActor static func main() async {
    do { try geometry(); try await integration() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
