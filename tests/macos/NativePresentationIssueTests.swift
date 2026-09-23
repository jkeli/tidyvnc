// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw Failure(message:message) }
}
struct UnprintableError: Error, CustomStringConvertible {
  var description: String { fatalError("Presentation must not evaluate arbitrary error descriptions") }
}
let privateDiagnostic = "private endpoint/password/path-%@-开发"
func mapping() throws {
  let defaults: [(NativePresentationIssue.Context, NativePresentationIssue)] = [
    (.startup,.startupUnavailable),(.desktop,.desktopUnavailable),(.cursor,.cursorUnavailable),
    (.layout,.layoutUnavailable),(.input,.inputFailed),(.shortcut,.shortcutUnavailable),
    (.fullscreen,.fullscreenUnavailable),(.command,.commandUnavailable)]
  for (context,expected) in defaults {
    for error in [UnprintableError(), NSError(domain:privateDiagnostic,code:99,
      userInfo:[NSLocalizedDescriptionKey:privateDiagnostic,NSFilePathErrorKey:privateDiagnostic]),
      NativeError(.internalFailure,privateDiagnostic)] as [any Error] {
      let issue = NativePresentationIssue(error:error,context:context)
      try check(issue == expected && !issue.message.contains("private"),"unknown errors use operation-specific redacted recovery")
    }
  }
  for status in [NativeStatus.resourceLimit,.outOfMemory] {
    let error = NativeError(status,privateDiagnostic)
    try check(NativePresentationIssue(error:error,context:.startup) == .startupResources,"startup resource recovery")
    try check(NativePresentationIssue(error:error,context:.desktop) == .desktopResources,"rendering resource recovery")
    try check(NativePresentationIssue(error:error,context:.layout) == .layoutResources,"layout resource recovery")
    try check(NativePresentationIssue(error:error,context:.cursor) == .cursorUnavailable,"cursor fallback remains specific")
  }
  for status in [NativeStatus.abiMismatch,.unsupported] {
    try check(NativePresentationIssue(error:NativeError(status,privateDiagnostic),context:.startup) == .startupIncompatible,"startup feature/ABI recovery")
  }
  try check(NativePresentationIssue(error:NativePreferencesError.unavailable,context:.startup) == .preferencesUnavailable,"settings startup failure")
  try check(NativePresentationIssue(error:NativeDisplayError.unavailable,context:.fullscreen) == .displaysUnavailable,"display discovery recovery")
  try check(NativePresentationIssue(error:NativeDisplayError.tooManyDisplays,context:.fullscreen) == .layoutResources,"display limit recovery")
  for status in [NativeStatus.notConnected,.viewOnly,.unfocused,.disabled] {
    try check(NativePresentationIssue(error:NativeError(status,privateDiagnostic),context:.input) == .inputUnavailable,"input eligibility recovery")
  }
  for status in [NativeStatus.busy,.queueFull] {
    try check(NativePresentationIssue(error:NativeError(status,privateDiagnostic),context:.input) == .inputBusy,"input admission recovery")
  }
  for context in [NativePresentationIssue.Context.shortcut,.command] {
    try check(NativePresentationIssue(error:NativeDesktopCommandIssue.keyboardCaptureUnavailable,context:context) == .keyboardCaptureUnavailable,"capture denial keeps Accessibility recovery")
  }
  print("PASS typed recovery mapping and no arbitrary diagnostic evaluation")
}
actor FailingTiles: NativeTileRendering {
  private let renderer: NativeTileRenderer
  private var failing = true
  init() throws { renderer = try NativeTileRenderer() }
  func recover() { failing = false }
  func render(_ request: NativeTileRequest) async throws -> NativeTileBatch {
    if failing { throw NativeError(.resourceLimit,privateDiagnostic) }
    return try await renderer.render(request)
  }
  func clear() async throws { try await renderer.clear() }
}
actor FailingCursor: NativeCursorRendering {
  func render(_ request: NativeCursorRequest) throws -> NativeCursorBatch { throw UnprintableError() }
  func clear() {}
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Presentation issue fixture timed out")
}
@MainActor func routedFailures() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_test_peer_create_pattern(0)!; defer { native_test_peer_destroy(peer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
  try await until { session.hasFrame }
  let renderer = try FailingTiles(), desktop = NativeDesktopView(frame:.init(x:0,y:0,width:64,height:48))
  var errors: [String] = []
  desktop.rendererOverride = renderer; desktop.onError = { errors.append($0) }; desktop.bind(session)
  try await until { errors.count == 1 && !desktop.isRendering }
  try check(errors == [NativePresentationIssue.desktopResources.message] && session.snapshot.state == .connected,"renderer failure is redacted and keeps the connection")
  let failedSequence = session.frame!.sequence
  native_test_peer_patch(peer); try await until { session.frame!.sequence > failedSequence && !desktop.isRendering }
  try check(errors.count == 1,"repeated rendering failure does not repeatedly alert")
  await renderer.recover()
  let recoverySequence = session.frame!.sequence
  native_test_peer_patch(peer)
  try await until { desktop.displayedSequence > recoverySequence && !desktop.isRendering }
  try check(errors.count == 1 && desktop.displayedImage != nil,"new frames recover after a renderer failure")
  desktop.detach(); try await until { session.presentations.count == 0 }

  let cursor = NativeDesktopView(frame:.init(x:0,y:0,width:64,height:48))
  errors = []; cursor.cursorRendererOverride = FailingCursor(); cursor.onError = { errors.append($0) }; cursor.bind(session)
  native_test_peer_cursor(peer,1)
  try await until { errors.count == 1 && !cursor.isRenderingCursor }
  try check(errors == [NativePresentationIssue.cursorUnavailable.message] && cursor.displayedCursor === NSCursor.arrow && session.snapshot.state == .connected,"cursor failure uses local fallback without leaking a diagnostic")
  cursor.detach(); try await until { session.presentations.count == 0 }

  let scaling = NativeScalingState(); scaling.bind(session)
  let view = NativeDesktopView(frame:.init(x:0,y:0,width:64,height:48)); view.bind(session)
  let canvas = try NativeDesktopCanvas(session:session,scaling:scaling)
  let bounds = NativeDisplayRectangle(x:0,y:0,width:64,height:48)
  let display = NativeDisplay(id:.init("fixture"),name:"Fixture",bounds:bounds,workArea:bounds,backingScale:1,isPrimary:true)
  try canvas.configure([(display,view)]); try await until { !view.isRendering }
  errors = []; view.onError = { errors.append($0) }
  let previous = view.desktopRectangle
  view.pan = .init(x:CGFloat.infinity,y:0)
  try check(errors == [NativePresentationIssue.layoutUnavailable.message] && view.pan == .zero && view.desktopRectangle == previous,"invalid canvas intent reports localized recovery and preserves geometry")
  canvas.stop(); view.detach(); scaling.stop()
  try await session.close(); try await runtime.shutdown()
  try check(session.presentations.count == 0,"failed renderers drain through session close")
  print("PASS renderer/cursor/canvas failure routing, redaction, fallback, recovery and drain")
}
@main struct NativePresentationIssueTests {
  static func main() async {
    do { try mapping(); try await routedFailures() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
