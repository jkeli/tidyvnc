// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
func document(_ body: String) throws -> NativeConnectionDocument {
  try .init(data:Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8))
}
func issue(_ reason: NativeDocumentResolutionFailure.Reason, line: UInt32 = 0, _ action: () throws -> Void) throws {
  do { try action(); throw Failure(message:"Unresolved document accepted") }
  catch let error as NativeDocumentResolutionFailure {
    try check(error.reason == reason && error.line == line,"resolution reason and line")
    try check(!error.description.contains("private-fixture"),"redacted resolution failure")
  }
}
func syntaxIssue(_ reason: NativeDocumentProblem, line: UInt32, _ action: () throws -> Void) throws {
  do { try action(); throw Failure(message:"Invalid document accepted") }
  catch let error as NativeDocumentFailure { try check(error.problem == reason && error.line == line,"typed semantic reason and line") }
}
func overlay() throws -> NativeDocumentResolution {
  var base = NativeSessionConfiguration()
  base.encoding = try NativeEncodingOptions(patch:[.init("FullColor","off")],source:.profile)
    .applying([.init("QualityLevel","9")],source:.commandLine)
  base.shared = false; base.reconnectOnError = true
  base.resizePolicy = try .init(enabled:false,initialSize:"800x600")
  let parsed = try document("""
  ServerName=private-fixture.invalid:2
  Shared=yes
  ReconnectOnError=no
  AcceptClipboard=off
  SendClipboard=on
  QualityLevel=0x3
  ScalingFactor=125%
  ScalingQuality=AREA
  DesktopPixelUnits=device
  ViewOnly=1
  EmulateMiddleButton=TRUE
  ShortcutModifiers= Cmd, Ctrl, Option,Win
  FullscreenSystemKeys=false
  AlwaysCursor=on
  CursorType=System
  FullScreen=on
  FullScreenMode=Selected
  FullScreenSelectedMonitors=2,1,2
  SecurityTypes=None
  X509CA=relative/../ca.pem
  X509CRL=
  """)
  let result = try NativeDocumentResolution(document:parsed,base:base,
    legacyDisplays:[.init("left"),.init("right")],workingDirectory:"/fixture")
  let config = try result.configuration()
  try check(result.endpoint == "private-fixture.invalid:2" && result.notices.isEmpty,"endpoint and understood fields")
  try check(config.shared && !config.reconnectOnError && config.sharedSource == .document && config.reconnectSource == .document,"connection provenance")
  try check(!config.clipboardReceive && config.clipboardSend,"clipboard overlay")
  let quality = try config.encoding!.value(for:.quality), color = try config.encoding!.value(for:.fullColor)
  try check(quality.value == "3" && quality.source == .document,"explicit file wins over preloaded CLI option")
  try check(color.value == "off" && color.source == .profile,"absent file field inherits")
  try check(config.scaling?.canonical == "125" && config.scaling?.filter == .area && config.scaling?.devicePixels == true,"scaling overlay")
  try check(config.input.viewOnly && config.input.emulateMiddle && !config.input.fullscreenSystemKeys,"input booleans")
  try check(config.input.shortcutModifiers == [.control,.option,.command] && config.input.cursorFallback == .system,"shortcut aliases and cursor fields")
  try check(config.inputSources[.viewOnly] == .document && config.scalingSources[.scaling] == .document,"input/scaling source")
  try check(config.fullscreenPolicy.startsFullscreen && config.fullscreenPolicy.mode == .selected,"fullscreen policy")
  try check(Set(config.fullscreenPolicy.selectedDisplays) == Set([NativeDisplayID("left"),.init("right")]),"explicit legacy ID mapping and deduplication")
  try check(config.securityTypes == [1] && config.securitySource == .document,"security allow-list")
  try check(config.caFile == "/fixture/relative/../ca.pem" && config.crlFile.isEmpty,"relative path preserves OS components")
  try check(config.resizePolicy == base.resizePolicy,"unrepresented settings inherit")
  let original = try base.encoding!.value(for:.quality)
  try check(original.value == "9" && original.source == .commandLine && !base.shared,"base remains unchanged")
  return result
}
func reviewAndFailures() throws {
  let parsed = try document("Future=\\q\nAudio=\\q\nFullColour=off\nRemoteResize=off\nShared=on\n")
  let reviewed = try NativeDocumentResolution(document:parsed)
  try check(reviewed.notices.map(\.line) == [2,3,4,5],"every ignored field is surfaced without decoding")
  try check(reviewed.notices[1].kind == .platformOnly,"platform-only classification")
  try issue(.reviewRequired) { _ = try reviewed.configuration() }
  try issue(.reviewRequired) { _ = try reviewed.configuration(acknowledging:[2,3,4]) }
  let accepted = try reviewed.configuration(acknowledging:[2,3,4,5])
  try check(accepted.shared && accepted.resizePolicy.enabled,"explicit reviewed omissions")
  try syntaxIssue(.invalidValue,line:2) { _ = try NativeDocumentResolution(document:document("Shared=broken\nShared=on")) }
  try syntaxIssue(.invalidEscape,line:2) { _ = try NativeDocumentResolution(document:document("Shared=\\q\nShared=on")) }
  try issue(.invalidEndpoint,line:2) { _ = try NativeDocumentResolution(document:document("ServerName=private-fixture::0")) }
  try issue(.relativePathNeedsBase,line:2) { _ = try NativeDocumentResolution(document:document("X509CA=private-fixture.pem")) }
  try issue(.displayMappingRequired,line:3) {
    _ = try NativeDocumentResolution(document:document("FullScreenMode=Selected\nFullScreenSelectedMonitors=2"),legacyDisplays:[.init("one")])
  }
  try issue(.displayMappingRequired,line:2) { _ = try NativeDocumentResolution(document:document("FullScreenMode=Selected")) }
  try syntaxIssue(.invalidValue,line:2) { _ = try NativeDocumentResolution(document:document("ShortcutModifiers=Ctrl,,Alt")) }
  if let unsupported = try NativeSecuritySelection.choices().first(where:{ !$0.available }) {
    try syntaxIssue(.unavailable,line:2) { _ = try NativeDocumentResolution(document:document("SecurityTypes="+unsupported.name)) }
  }
}
func migration() throws {
  let result = try NativeDocumentResolution(document:document("DotWhenNoCursor=on\nAlwaysCursor=off\nCursorType=System\nFullScreenAllMonitors=on\nFullScreenMode=Selected"))
  let config = try result.configuration()
  try check(config.input.cursorFallback == .dot && result.cursorType == .dot,"deprecated cursor wins after later modern fields")
  try check(config.fullscreenPolicy.mode == .all,"deprecated all displays wins after modern mode")
  try check(result.fieldLines["AlwaysCursor"] == 2 && result.fieldLines["FullScreenMode"] == 5,"migrated field provenance")
  let hidden = try NativeDocumentResolution(document:document("CursorType=System\nAlwaysCursor=off"))
  let hiddenConfig = try hidden.configuration()
  try check(hiddenConfig.input.cursorFallback == .hidden && hidden.cursorType == .system,"inactive shape is retained")
  let off = try NativeDocumentResolution(document:document("DotWhenNoCursor=on\nDotWhenNoCursor=off\nAlwaysCursor=off\nFullScreenAllMonitors=on\nFullScreenAllMonitors=off\nFullScreenMode=Current"))
  let offConfig = try off.configuration()
  try check(offConfig.input.cursorFallback == .hidden && offConfig.fullscreenPolicy.mode == .current,"last deprecated false cancels migration")
  let defaultDisplay = try NativeDocumentResolution(document:document("FullScreenMode=Selected"),legacyDisplays:[.init("first")])
  let selected = try defaultDisplay.configuration()
  try check(selected.fullscreenPolicy.selectedDisplays == [.init("first")],"retained default selected monitor 1")
  let empty = try NativeDocumentResolution(document:document("ServerName="))
  try check(empty.endpoint == "","empty explicitly clears address")
  let absent = try NativeDocumentResolution(document:document("Shared=on"))
  try check(absent.endpoint.isEmpty && absent.fieldLines["ServerName"] == nil,"absent address clears, matching the retained file reader")
}
@MainActor func sessionOwnership(_ result: NativeDocumentResolution) async throws {
  let runtime = try NativeRuntime()
  let hasTLS = try NativeSecuritySelection.choices().contains { $0.available && $0.protection == .x509TLS }
  let sessionConfiguration: NativeSessionConfiguration
  if hasTLS {
    sessionConfiguration = try result.configuration()
  } else {
    // The sanitizer builds omit GnuTLS. Configured verification files must
    // still fail at session admission, rather than being silently discarded.
    do {
      let unexpected = try runtime.makeSession(configuration:result.configuration())
      try await unexpected.close()
      throw Failure(message:"TLS-disabled session accepted configured verification files")
    } catch let error as NativeError {
      try check(error.status == .unsupported,"typed rejection of unavailable verification files")
    }
    // Use an explicitly different, file-selected empty CA for the wire test.
    // Keep the original resolved configuration unchanged.
    sessionConfiguration = try NativeDocumentResolution(document:document("X509CA="),
      base:result.configuration()).configuration()
    let unchanged = try result.configuration()
    try check(unchanged.caFile == "/fixture/relative/../ca.pem","failed admission preserves resolved verification path")
  }
  let first = try runtime.makeSession(configuration:sessionConfiguration)
  let second = try runtime.makeSession(configuration:.init())
  try check(first.initialShared && !first.initialReconnectOnError && !second.initialShared,"new sessions capture independent connection options")
  try check(first.initialInput.cursorFallback == .system && first.initialInputSources[.viewOnly] == .document,"actual session captures file input and source")
  try check(first.initialSecuritySource == .document && first.initialFullscreenPolicy.mode == .selected,"actual security/fullscreen capture")
  try check(second.initialInputSources.isEmpty && second.initialInput.cursorFallback == .hidden,"second session isolated")
  let peers = (0..<2).map { _ in native_test_peer_create_pattern(0)! }
  defer { for peer in peers { native_test_peer_destroy(peer) } }
  _ = try await first.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peers[0]))")
  _ = try await second.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peers[1]))")
  try check(native_test_peer_shared(peers[0]) == 1 && native_test_peer_shared(peers[1]) == 0,"file-selected sharing reaches independent real ClientInit bytes")
  try check(first.isViewOnly && !second.isViewOnly,"file input policy reaches actual sessions")
  _ = try await first.disconnect()
  try check(second.snapshot.state == .connected,"file session teardown does not affect the other session")
  try await first.close(); try await second.close(); try await runtime.shutdown()
}
@main struct NativeDocumentResolutionTests {
  static func main() async throws {
    let resolved = try overlay(); try reviewAndFailures(); try migration(); try await sessionOwnership(resolved)
    print("Native connection-document resolution, review, precedence and session ownership passed")
  }
}
