// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

final class WeakReference<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw Failure(message: message) } }
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message: "Unexpected defaults write") }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
  throw Failure(message: "Timed out")
}
func syntaxAndGeometry() throws {
  for mode in NativeScalingMode.allCases {
    let value = try NativeScaling(mode.initialText)
    try check(value.mode == mode, "all eight parser modes")
    try check(try NativeScaling(value.canonical) == value, "canonical round trip")
  }
  try check(try NativeScaling("137.50%").canonical == "137.5", "decimal precision")
  try check(try NativeScaling("100%").mode == .unscaled, "identity canonicalization")
  for text in ["", "0", "1.001", ".1", "1.", "65536x1", "1x0", "125%x80", "10000.01", "1\0", String(repeating: "1", count: 65)] {
    do { _ = try NativeScaling(text); throw Failure(message: "Accepted invalid scale") } catch is NativeError {}
  }
  let fixtures: [(String, Double, Double)] = [
    ("100",1920,1080), ("Auto",1000,800), ("FixedRatio",1000,562), ("FitWidth",1000,562),
    ("FitHeight",1422,800), ("800x600",800,600), ("137.5",2640,1485), ("125%x80%",2400,864)
  ]
  for (text, width, height) in fixtures {
    let geometry = try NativeGeometry(width: 1920, height: 1080, viewport: CGSize(width: 1000, height: 800), backingScale: 1, scaling: text)
    try check(geometry.rectangle.size == CGSize(width: width, height: height), "shared fixture dimensions")
    let point = try geometry.remotePoint(CGPoint(x: geometry.rectangle.midX, y: geometry.rectangle.midY))
    try check(abs(point.x - 960) <= 1 && abs(point.y - 540) <= 1, "same inverse transform")
  }
  for scale in [1.25, 1.5, 2.0, 3.0] {
    let geometry = try NativeGeometry(width: 1920, height: 1080, viewport: CGSize(width: 1000, height: 800), backingScale: scale,
      scaling: "1920x1080", devicePixels: true, pan: CGPoint(x: 12.5, y: 8.25))
    try check(geometry.rectangle.width == 1920 / scale, "device units at fractional backing scale")
    let point = try geometry.remotePoint(CGPoint(x: geometry.rectangle.midX, y: geometry.rectangle.midY))
    try check(abs(point.x - 960) <= 1 && abs(point.y - 540) <= 1, "fractional pan inverse")
  }
  print("PASS eight modes, syntax, canonical values, shared geometry fixtures and fractional device mapping")
}
@MainActor func drafts() throws {
  let first = NativeScalingState(), second = NativeScalingState()
  try check(first.value.filter == .bilinear, "bilinear default matches retained frontend")
  let cancelled = NativeScalingDraft(state: first)
  cancelled.mode = .independent; cancelled.text = "125.25%x80%"; cancelled.devicePixels = true; cancelled.filter = .area
  cancelled.mode = .exact; cancelled.text = "900x600"; cancelled.mode = .independent
  try check(cancelled.text == "125.25%x80%", "per-mode text retained")
  cancelled.cancel(); try check(!cancelled.apply() && first.value == .builtIn, "Cancel discards")
  let draft = NativeScalingDraft(state: first), stale = NativeScalingDraft(state: first)
  draft.mode = .percent; draft.text = "Auto"
  try check(draft.candidate == nil && !draft.canApply && !draft.apply(), "wrong selected mode rejected")
  draft.text = "100%"
  try check(draft.canApply && draft.apply() && first.value.canonical == "100", "100% accepted in percent editor")
  try check(second.value == .builtIn, "per-connection isolation")
  stale.mode = .fitHeight
  try check(!stale.apply() && stale.issue == .changed, "stale baseline cannot overwrite")
  let reopened = NativeScalingDraft(state: first)
  try check(reopened.mode == .unscaled && !reopened.canApply, "reopen current canonical value")
  let quality = NativeScalingDraft(state: first), staleQuality = NativeScalingDraft(state: first)
  quality.filter = .nearest
  try check(quality.canApply && quality.apply() && first.value.filter == .nearest && first.value.canonical == "100",
    "filter-only apply preserves geometry")
  staleQuality.filter = .area
  try check(!staleQuality.apply() && staleQuality.issue == .changed, "stale filter-only edit cannot overwrite")
  try check(second.value.filter == .bilinear && NativeScalingDraft(state: first).filter == .nearest,
    "filter isolation and reopen")
  first.stop(); reopened.mode = .automatic
  try check(!reopened.apply() && reopened.issue == .closed, "stopped state rejects editor")
  var owner: NativeScalingState? = NativeScalingState()
  let reference = WeakReference(owner)
  let orphan = NativeScalingDraft(state: owner!); owner = nil
  try check(reference.value == nil && !orphan.apply() && orphan.issue == .closed, "editor does not retain connection state")
  print("PASS copied drafts, per-mode values, cancel/apply/reopen, isolation, stale guards and weak ownership")
}
@MainActor func desktopAndController() async throws {
  _ = NSApplication.shared
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing: Preferences())
  let model = ConnectionModel(runtime: runtime, preferences: preferences) { _, _ in }
  try await until { model.defaults?.isReady == true }
  try check(!model.canOpenScaling, "unconnected action disabled")
  let session = model.session!
  // The no-auth peer is permitted by this build's default policy.
  _ = try await session.connect(endpoint: "127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.frame != nil }
  var view: NativeDesktopView? = NativeDesktopView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
  let released = WeakReference(view)
  view!.bind(session); view!.observeScaling(model.scaling)
  try await until { view!.displayedSequence == session.frame?.sequence && !view!.isRendering }
  try check(view!.desktopRectangle == CGRect(x: 50, y: 0, width: 200, height: 200), "initial fit")
  model.openScaling(); try check(model.scalingDraft != nil && !model.canOpenEncoding, "one editor per window")
  model.scalingDraft!.mode = .exact; model.scalingDraft!.text = "120x80"
  try check(view!.desktopRectangle.width == 200, "draft leaves presentation unchanged")
  try check(model.scalingDraft!.apply(), "apply")
  model.closeScaling()
  try await until { !view!.isRendering }
  try check(view!.desktopRectangle == CGRect(x: 90, y: 60, width: 120, height: 80), "atomic live presentation")
  view!.pan = CGPoint(x: 7.5, y: 4.25)
  try await until { !view!.isRendering }
  let panned = view!.desktopRectangle
  model.openScaling(); model.scalingDraft!.filter = .area
  try check(view!.filter == .bilinear, "filter draft does not mutate view")
  model.closeScaling()
  try check(view!.filter == .bilinear && model.scaling.value.filter == .bilinear, "filter cancel leaves live state")
  model.openScaling(); model.scalingDraft!.filter = .nearest
  try check(model.scalingDraft!.apply(), "live filter-only apply")
  model.closeScaling(); try await until { !view!.isRendering }
  try check(view!.filter == .nearest && view!.pan == .zero && view!.desktopRectangle == panned,
    "live quality preserves clamped pan and placement")
  view!.pan = .zero; try await until { !view!.isRendering }
  try session.setFocused(true)
  let point = CGPoint(x: 180, y: 120)
  let event = NSEvent.mouseEvent(with: .mouseMoved, location: view!.convert(point, to: nil),
    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
  view!.mouseMoved(with: event)
  try await until { native_test_peer_has_input(peer,5,0,1,1) != 0 }
  // Syntax can be valid before a display move makes its backing size too large.
  let large = NativeScalingDraft(state: model.scaling); large.mode = .exact; large.text = "65535x65535"
  try check(large.apply(), "largest logical size at backing scale one")
  let window = NSWindow(contentRect: view!.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  var failures = 0; view!.onError = { _ in failures += 1 }
  window.contentView = view!
  try await until { !view!.isRendering }
  if window.backingScaleFactor > 1 {
    print("PASS exercised Retina backing scale \(window.backingScaleFactor)")
    try check(view!.desktopRectangle.width <= 300 && failures == 1, "display change safely fits oversized selection")
    view!.layout(); view!.layout(); try check(failures == 1, "no repeated overflow alerts")
    let invalid = NativeScalingDraft(state: model.scaling); invalid.text = "65534x65534"
    try check(!invalid.apply() && invalid.issue == .dimensions && model.scaling.value.canonical == "65535x65535", "geometry preflight preserves applied state")
    invalid.devicePixels = true
    try check(invalid.apply() && failures == 1, "units and dimensions applied atomically")
  }
  model.openScaling(); try check(model.scalingDraft != nil, "reopen")
  _ = try await session.disconnect()
  try check(model.scalingDraft == nil && !model.canOpenScaling, "disconnect dismisses draft")
  view!.detach(); window.makeFirstResponder(nil); window.contentView = nil; window.close(); view = nil
  try await until { released.value == nil }
  try check(released.value == nil && model.scaling.desktop == nil, "detached view releases subscriptions")
  await model.close(); await preferences.close(); try await runtime.shutdown()
  print("PASS actual controller, desktop apply, pointer wire mapping, display-limit recovery and disconnect cleanup")
}
@main struct NativeScalingTests {
  @MainActor static func main() async {
    do { try syntaxAndGeometry(); try drafts(); try await desktopAndController() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
