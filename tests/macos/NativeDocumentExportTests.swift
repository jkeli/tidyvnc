// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
func rejects(_ expected: NativeDocumentExportError, _ action: () throws -> Void) throws {
  do { try action(); throw Failure(message:"Invalid export accepted") }
  catch let error as NativeDocumentExportError { try check(error == expected,"typed export failure") }
}
func resolve(_ export: NativeDocumentExport, displays: [NativeDisplayID] = []) throws -> NativeDocumentResolution {
  try NativeDocumentResolution(document:NativeConnectionDocument(data:export.serializedData(acknowledging:export.losses)),legacyDisplays:displays)
}
func roundTrip() throws {
  let displays: [NativeDisplayID] = [.init("right"),.init("left")]
  var config = NativeSessionConfiguration()
  config.shared = true; config.reconnectOnError = false
  config.clipboardSend = false; config.clipboardReceive = false
  config.securityTypes = [1]; config.caFile = "/fixture/ca=one\\two.pem"; config.crlFile = "/fixture/crl.pem"
  config.encoding = try NativeEncodingOptions(patch:[.init("QualityLevel","3"),.init("FullColor","off")])
  config.input = .init(viewOnly:true,emulateMiddle:true,shortcutModifiers:[.control,.shift,.option,.command],fullscreenSystemKeys:false,cursorFallback:.hidden)
  config.scaling = try .init("125%",devicePixels:true,filter:.area)
  config.fullscreenPolicy = try .init(startsFullscreen:true,mode:.selected,selectedDisplays:[displays[1]])
  config.resizePolicy = try .init(enabled:false,initialSize:"800x600")
  let export = try NativeDocumentExport(endpoint:"fixture.invalid:2",configuration:config,inactiveCursor:.system,legacyDisplays:displays,ignoredInput:true)
  try check(export.losses == [.remoteResize,.networkFamilies,.pointerTiming,.clipboardLimit,.windowPlacement,.displayIdentity,.ignoredInput],"complete loss disclosure")
  try rejects(.reviewRequired) { _ = try export.serializedData() }
  try rejects(.reviewRequired) { _ = try export.serializedData(acknowledging:[.displayIdentity,.ignoredInput]) }
  let result = try resolve(export,displays:displays), value = try result.configuration()
  try check(result.endpoint == "fixture.invalid:2" && result.notices.isEmpty,"understood endpoint and fields")
  try check(value.shared == config.shared && value.reconnectOnError == config.reconnectOnError,"connection round trip")
  try check(value.clipboardSend == config.clipboardSend && value.clipboardReceive == config.clipboardReceive,"clipboard round trip")
  try check(value.input == config.input && result.cursorType == .system,"input and dormant shape round trip")
  try check(value.scaling == config.scaling && value.fullscreenPolicy == config.fullscreenPolicy,"scaling and mapped display round trip")
  try check(value.securityTypes == config.securityTypes && value.caFile == config.caFile && value.crlFile == config.crlFile,"security and exact escaped paths")
  for field in try NativeEncodingOptions.schema() where field.persistent {
    let before = try config.encoding!.value(for:field.id), after = try value.encoding!.value(for:field.id)
    try check(before.value == after.value,"encoding round trip: \(field.name)")
  }
  try check(value.resizePolicy == .builtIn,"reviewed unsupported resize uses recipient settings")
  let data = try export.serializedData(acknowledging:export.losses)
  let names = try NativeConnectionDocument(data:data).entries.map(\.name)
  try check(Set(names).count == names.count,"one canonical assignment per field")
  try check(!names.contains("Password") && !names.contains("UserName") && !names.contains("TLSPriority") && !names.contains("RemoteResize"),"export scope")
  config.shared = false; config.securityTypes = []
  try check(tryData(export) == data,"immutable snapshot after caller edits")
  let defaultsExport = try NativeDocumentExport(endpoint:"",configuration:.init())
  try check(defaultsExport.losses == [.remoteResize,.networkFamilies,.pointerTiming,.clipboardLimit,.windowPlacement],"even built-in omitted resize needs review")
  try rejects(.reviewRequired) { _ = try defaultsExport.serializedData() }
  var recipient = NativeSessionConfiguration(); recipient.resizePolicy = try .init(enabled:false)
  let inherited = try NativeDocumentResolution(document:NativeConnectionDocument(data:defaultsExport.serializedData(acknowledging:[.remoteResize,.networkFamilies,.pointerTiming,.clipboardLimit,.windowPlacement])),base:recipient).configuration()
  try check(!inherited.resizePolicy.enabled,"recipient resize preferences demonstrate default omission loss")
  let deny = try resolve(defaultsExport)
  try check(deny.endpoint.isEmpty,"settings-only export")
  var empty = NativeSessionConfiguration(); empty.securityTypes = []
  let denyConfig = try resolve(NativeDocumentExport(endpoint:"",configuration:empty)).configuration()
  try check(denyConfig.securityTypes == [],"empty security allow-list remains deny-all")
  for shape: NativeCursorFallback in [.dot,.system] {
    for filter in NativeScalingFilter.allCases {
      var variants = NativeSessionConfiguration()
      variants.input = .init(shortcutModifiers:[],cursorFallback:shape)
      variants.scaling = try .init("FixedRatio",devicePixels:true,filter:filter)
      let after = try resolve(NativeDocumentExport(endpoint:"",configuration:variants)).configuration()
      try check(after.input == variants.input && after.scaling == variants.scaling,"visible shape, empty modifiers, scaling filter")
    }
  }
}
func tunnelExportReview() throws {
  let gateway = try NativeSSHGateway("alice@gateway.invalid")
  var configuration = NativeSessionConfiguration()
  configuration.fullscreenPolicy = try .init(mode:.selected,selectedDisplays:[.init("display")])
  let capture = try NativeDocumentExportCapture(endpoint:"remote.invalid",configuration:configuration,
    legacyDisplays:[.init("display")],sshGateway:gateway)
  for export in [try capture.automaticExport(),try capture.makeExport(monitorIndices:[.init("display"):2])] {
    try check(export.losses.contains(.sshGateway),"automatic and remapped exports preserve tunnel loss review")
    try rejects(.reviewRequired) { _ = try export.serializedData(acknowledging:export.losses.subtracting([.sshGateway])) }
    let bytes = try export.serializedData(acknowledging:export.losses)
    let document = try NativeConnectionDocument(data:bytes)
    let text = String(decoding:bytes,as:UTF8.self)
    try check(!text.contains(gateway.host) && !text.contains(gateway.routeIdentity) && !text.contains("alice"),
              "reviewed compatibility export omits gateway and derived route metadata")
    let endpoint = document.entries.first { $0.name == "ServerName" }
    try check(endpoint != nil && export.endpoint == "remote.invalid","export keeps logical remote destination")
  }
}
func tryData(_ export: NativeDocumentExport) -> Data? { try? export.serializedData(acknowledging:export.losses) }
func failures() throws {
  var config = NativeSessionConfiguration(); config.tlsPriority = "private-fixture-policy"
  try rejects(.securityPolicy) { _ = try NativeDocumentExport(endpoint:"",configuration:config) }
  config = .init(); config.caFile = "relative.pem"
  try rejects(.invalidConfiguration) { _ = try NativeDocumentExport(endpoint:"",configuration:config) }
  config = .init(); config.securityTypes = [UInt32.max]
  try rejects(.invalidConfiguration) { _ = try NativeDocumentExport(endpoint:"",configuration:config) }
  for unsupported in try NativeSecuritySelection.choices().filter({ !$0.available }) {
    config.securityTypes = [unsupported.id]
    try rejects(.invalidConfiguration) { _ = try NativeDocumentExport(endpoint:"",configuration:config) }
  }
  try rejects(.invalidConfiguration) { _ = try NativeDocumentExport(endpoint:"fixture::0",configuration:.init()) }
  try rejects(.invalidConfiguration) { _ = try NativeDocumentExport(endpoint:"",configuration:.init(),inactiveCursor:.hidden) }
  config = .init(); config.input = .init(shortcutModifiers:.init(rawValue:16))
  try rejects(.invalidConfiguration) { _ = try NativeDocumentExport(endpoint:"",configuration:config) }
  config = .init(); config.fullscreenPolicy = try .init(mode:.current,selectedDisplays:[.init("gone")])
  try rejects(.displayMapping) { _ = try NativeDocumentExport(endpoint:"",configuration:config) }
  try rejects(.displayMapping) { _ = try NativeDocumentExport(endpoint:"",configuration:config,legacyDisplays:[.init("gone"),.init("gone")]) }
  for mode: NativeFullscreenMode in [.current,.all] {
    config.fullscreenPolicy = try .init(mode:mode,selectedDisplays:[.init("gone")])
    let dormant = try NativeDocumentExport(endpoint:"",configuration:config,legacyDisplays:[.init("other"),.init("gone")])
    let after = try resolve(dormant,displays:[.init("other"),.init("gone")]).configuration()
    try check(after.fullscreenPolicy == config.fullscreenPolicy && dormant.losses.contains(.displayIdentity),"dormant display selections also preserve mapping")
  }
  config = .init(); config.caFile = "/"+String(repeating:"x",count:300)
  do { _ = try NativeDocumentExport(endpoint:"",configuration:config); throw Failure(message:"Overlong line exported") }
  catch let error as NativeDocumentFailure { try check(error.problem == .lineTooLong,"preflight bounds") }
}
final class Preferences: NativePreferencesBacking, Sendable {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"Unexpected persistence") }
}
@MainActor func liveCapture() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing:Preferences())
  let model = ConnectionModel(runtime:runtime,preferences:preferences) { _,_ in }
  try check(!model.canExportDocument,"unloaded model blocked")
  for _ in 0..<1000 { if model.defaults?.isReady == true { break }; try await Task.sleep(for:.milliseconds(2)) }
  guard let session = model.session else { throw Failure(message:"No session") }
  model.endpoint = "bad::0"
  try check(!model.canExportDocument,"invalid address gates Save")
  model.endpoint = "review.invalid"
  try check(model.canConnect,"ready before export review")
  model.beginDocumentExport()
  guard let reviewID = model.documentSave.review?.id else { throw Failure(message:"No model export review") }
  try check(!model.canExportDocument && !model.canConnect && !model.canOpenSecurity,"save flow excludes competing operations")
  model.documentSave.cancel(reviewID)
  model.endpoint = ""
  let initial = try model.documentExport(legacyDisplays:[])
  try session.setConnectionOptions(shared:true,reconnectOnError:false,expected:session.connectionOptions())
  try session.setSecurity(.init(types:"None",tlsPriority:""),trustFiles:.init(caFile:"",crlFile:""),expected:session.securityConfiguration())
  try session.setClipboardPolicy(send:false,receive:false)
  let scale = NativeScalingDraft(state:model.scaling); scale.mode = .percent; scale.text = "150"; scale.filter = .nearest
  try check(scale.apply(),"applied scaling")
  model.endpoint = "fixture.invalid::5901"
  let edited = try model.documentExport(legacyDisplays:[]), editedConfig = try resolve(edited).configuration()
  try check(editedConfig.shared && !editedConfig.reconnectOnError && editedConfig.securityTypes == [1],"captures current sharing and security")
  try check(!editedConfig.clipboardSend && !editedConfig.clipboardReceive && editedConfig.scaling?.canonical == "150","captures current clipboard and scaling")
  let initialConfig = try resolve(initial).configuration()
  try check(!initialConfig.shared && initialConfig.clipboardSend && initial.endpoint.isEmpty,"older export remains frozen")
  model.busy = true
  try rejects(.unavailable) { _ = try model.documentExport(legacyDisplays:[]) }; model.busy = false
  model.openConnectionOptions()
  try rejects(.unavailable) { _ = try model.documentExport(legacyDisplays:[]) }; model.closeConnectionOptions()
  let peer = native_test_peer_create_pattern(0)!
  defer { native_test_peer_destroy(peer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_test_peer_port(peer))")
  let input = NativeInputDraft(state:model.input); input.cursorFallback = .system; input.viewOnly = true
  try check(input.apply(),"live input edits")
  let hidden = NativeInputDraft(state:model.input); hidden.cursorFallback = .hidden
  try check(hidden.apply() && model.input.inactiveCursor == .system,"hidden preserves latest shape")
  let live = try resolve(model.documentExport(legacyDisplays:[]))
  let liveConfig = try live.configuration()
  try check(live.cursorType == .system && liveConfig.input.viewOnly,"export live input and dormant shape")
  let dot = NativeInputDraft(state:model.input); dot.cursorFallback = .dot; try check(dot.apply(),"change shape")
  let hiddenDot = NativeInputDraft(state:model.input); hiddenDot.cursorFallback = .hidden
  try check(hiddenDot.apply() && model.input.inactiveCursor == .dot,"hiding keeps replacement shape")
  let quality = try session.encodingOptions().applying([.init("QualityLevel","4")],source:.session)
  _ = try await session.applyEncoding(quality,expectedGeneration:session.generation)
  let encoding = try resolve(model.documentExport(legacyDisplays:[])).configuration().encoding!.value(for:.quality)
  try check(encoding.value == "4","captures current encoding")
  try session.setResizePolicy(.init(enabled:false),expected:session.resizePolicyRevision)
  let resized = try model.documentExport(legacyDisplays:[])
  try check(resized.losses == [.remoteResize,.networkFamilies,.pointerTiming,.clipboardLimit,.windowPlacement],"captures current unsupported resize policy")
  try check(model.documentSave.begin(resized),"begin export before close")
  model.requestClose()
  try check(model.documentSave.review == nil && !model.documentSave.hasPending,"model close stops review")
  try rejects(.unavailable) { _ = try model.documentExport(legacyDisplays:[]) }
  await model.close(); await preferences.close(); try await runtime.shutdown()
}
@MainActor func openedFileCapture() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:directory) }
  let url = directory.appendingPathComponent("Fixture.tidyvnc")
  try Data("TidyVNC Configuration file Version 1.0\nServerName=opened.invalid\nAlwaysCursor=off\nCursorType=System\nFutureOption=private-fixture\n".utf8).write(to:url)
  let runtime = try NativeRuntime(), preferences = NativePreferencesStore(backing:Preferences())
  let model = ConnectionModel(runtime:runtime,preferences:preferences,document:.init(url:url)) { _,_ in }
  for _ in 0..<1000 { if model.defaults?.documentReview != nil { break }; try await Task.sleep(for:.milliseconds(2)) }
  guard let review = model.defaults?.documentReview else { throw Failure(message:"No file review") }
  try rejects(.unavailable) { _ = try model.documentExport(legacyDisplays:[]) }
  model.defaults?.acceptDocument(review.id)
  guard model.session != nil else { throw Failure(message:"No accepted session") }
  let export = try model.documentExport(legacyDisplays:[]), result = try resolve(export)
  try check(result.cursorType == .system && model.input.inactiveCursor == .system,"opened dormant shape reaches live capture")
  try check(export.losses == [.remoteResize,.networkFamilies,.pointerTiming,.clipboardLimit,.windowPlacement,.ignoredInput] && result.endpoint == "opened.invalid","review original ignored fields on export")
  let text = String(data:try export.serializedData(acknowledging:export.losses),encoding:.utf8)!
  try check(!text.contains("FutureOption") && !text.contains("private-fixture"),"ignored input cannot leak to output")
  await model.close(); await preferences.close(); try await runtime.shutdown()
}
@main struct NativeDocumentExportTests {
  static func main() async throws {
    try roundTrip(); try tunnelExportReview(); try failures(); try await liveCapture(); try await openedFileCapture()
    print("PASS loss-aware export, semantic round trips, immutable live capture, fail-closed security and bounds")
  }
}
