// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
func rejects(_ expected: NativeDocumentExportError, _ action: () throws -> Void) throws {
  do { try action(); throw Failure(message:"Invalid export mapping accepted") }
  catch let error as NativeDocumentExportError { try check(error == expected,"typed mapping failure") }
}
let left = NativeDisplayID("fixture-left"), absent = NativeDisplayID("fixture-disconnected")
func fixtureCapture(automatic: Bool = false) throws -> NativeDocumentExportCapture {
  var config = NativeSessionConfiguration()
  config.shared = true; config.securityTypes = [1]
  config.fullscreenPolicy = try .init(startsFullscreen:true,mode:.selected,selectedDisplays:[left,absent])
  return try NativeDocumentExportCapture(endpoint:"fixture.invalid",configuration:config,
    legacyDisplays:automatic ? [left,absent] : [left],displayNames:[left:"Fixture Left"],ignoredInput:true)
}
struct ExportFixtureView: View {
  @ObservedObject var state: NativeDocumentSaveState
  let begin: () -> Void
  let dismissed: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text("Export Mapping Fixture").font(.title2)
      Text("Only a private temporary fixture file can be saved. No connection or native store is used.")
      Button("Review Export",action:begin).disabled(state.hasPending)
      DocumentSaveStatusView(state:state)
    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
      .sheet(item:Binding(get:{ state.presentation },set:{ value in
        if value == nil, let id = state.presentation?.id { state.cancelPresentation(id) }
      }),onDismiss:dismissed) { _ in DocumentSaveReviewView(state:state) }
  }
}
@MainActor final class ExportMappingApp: NSObject, NSApplicationDelegate {
  let state = NativeDocumentSaveState()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-export-mapping-"+UUID().uuidString)
  var window: NSWindow!, capture: NativeDocumentExportCapture!
  var dismissals = 0, handoffs = 0, quitting = false
  var output: URL { root.appendingPathComponent("Fixture.tidyvnc") }
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
      capture = try fixtureCapture()
      window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:740),
        styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
      window.title = "Export Mapping Fixture"; window.isReleasedWhenClosed = false
      let host = NSHostingController(rootView:ExportFixtureView(state:state,begin:{ [weak self] in self?.begin() },
        dismissed:{ [weak self] in self?.dismissed() }))
      host.sizingOptions = []; window.contentViewController = host
      window.setContentSize(NSSize(width:780,height:740)); window.center(); window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps:true); begin()
      if CommandLine.arguments.contains("--verify") {
        Task { @MainActor in
          do {
            try await verify()
            NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0)
          } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
      }
    } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
  func begin() { do { _ = try state.begin(capture) } catch { exit(1) } }
  func dismissed() {
    dismissals += 1
    if let id = state.choosing {
      handoffs += 1
      // Same onDismiss handoff as the app, with a fixture-only destination
      // replacing NSSavePanel so automated tests never access user files.
      state.choose(output,id:id,overwrite:true)
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateNow }
    quitting = true; state.stop()
    Task { @MainActor in
      await state.close(); window.close(); try? FileManager.default.removeItem(at:root)
      NSApp.reply(toApplicationShouldTerminate:true)
    }
    return .terminateLater
  }
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"Export mapping fixture timed out")
  }
  func render(_ name: String, dark: Bool = false) async throws {
    guard let sheet = window.attachedSheet, let view = sheet.contentView,
          let index = CommandLine.arguments.firstIndex(of:"--output"), index+1 < CommandLine.arguments.count else { throw Failure(message:"missing sheet/render path") }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    sheet.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
    view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(150)); view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"missing bitmap") }
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
    try check(view.fittingSize.height <= view.bounds.height+1,"sheet content fits height: \(view.fittingSize) in \(view.bounds.size)")
  }
  func verify() async throws {
    try projection()
    try await until { window.attachedSheet != nil && state.mapping != nil }
    let sheet = window.attachedSheet!, presentation = state.presentation!.id, initial = state.mapping!
    try check(initial.suggestedIndices == [left:1] && state.review == nil && state.hasPending,"missing display gets recovery without guessing its number")
    try await render("mapping-light"); try await render("mapping-dark",dark:true)
    state.resolveMapping(UUID(),indices:[left:7,absent:9])
    try check(state.mapping?.id == initial.id,"stale mapping resolve ignored")
    state.resolveMapping(initial.id,indices:[left:7,absent:7])
    try check(state.issue != nil && state.mapping != nil && state.choosing == nil,"duplicate numbers cannot advance")
    state.resolveMapping(initial.id,indices:[left:7,absent:9])
    try await until { state.review != nil }
    try await render("review")
    // The fixed-height sheet must expose the complete review through one scroll
    // area, keeping the title and actions outside it. Exercise both ends.
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    guard let scroll = scrollViews(sheet.contentView!).first, let document = scroll.documentView else {
      throw Failure(message:"missing export details scroll area")
    }
    try check(document.bounds.height > scroll.contentView.bounds.height,"long review scrolls instead of compressing content")
    document.scroll(NSPoint(x:0,y:document.bounds.maxY)); scroll.reflectScrolledClipView(scroll.contentView)
    try check(scroll.contentView.bounds.origin.y > 0,"last omission notice reachable")
    try await render("review-bottom")
    let reviewed = state.review!
    try check(window.attachedSheet === sheet && state.presentation?.id == presentation && dismissals == 0,"mapping to review keeps one sheet and no premature destination handoff")
    try check(reviewed.monitorIndices == [left:7,absent:9] && reviewed.losses == [.remoteResize,.networkFamilies,.pointerTiming,.clipboardLimit,.windowPlacement,.displayIdentity,.ignoredInput],"exact numbering and all conversion losses reviewed")
    state.editMapping(reviewed.id)
    let edited = state.mapping!
    try check(edited.id != initial.id && edited.suggestedIndices == reviewed.monitorIndices,"edit uses fresh identity and retains choices")
    state.resolveMapping(initial.id,indices:[left:1,absent:2]); state.approve(reviewed.id)
    try check(state.mapping?.id == edited.id && state.choosing == nil,"late edit/approval cannot bypass new mapping")
    state.cancelPresentation(UUID()); try check(state.hasPending,"stale presentation dismissal ignored")
    state.resolveMapping(edited.id,indices:[left:3,absent:4])
    let final = state.review!
    state.approve(final.id)
    try await until { state.savedURL == output && window.attachedSheet == nil }
    try check(handoffs == 1 && dismissals == 1 && !state.hasPending,"one reviewed dismissal hands off to one private save")
    let bytes = try Data(contentsOf:output), parsed = try NativeConnectionDocument(data:bytes)
    let result = try NativeDocumentResolution(document:parsed,monitorMapping:[3:left,4:absent])
    let config = try result.configuration()
    try check(result.endpoint == "fixture.invalid" && config.shared && config.fullscreenPolicy.selectedDisplays == [absent,left],"saved bytes preserve captured values and explicit numbers")
    let text = String(decoding:bytes,as:UTF8.self)
    try check(!text.contains(left.rawValue) && !text.contains("Fixture Left") && !text.contains(absent.rawValue),"display IDs and UI names do not enter compatibility output")
    begin(); try await until { state.mapping != nil && window.attachedSheet != nil }
    let cancelled = state.mapping!.id
    state.cancel(cancelled); try await until { window.attachedSheet == nil }
    try check(handoffs == 1 && !state.hasPending,"cancel mapping never reaches writer")
    _ = try state.begin(fixtureCapture(automatic:true))
    try await until { state.review != nil && window.attachedSheet != nil }
    try check(state.canEditMapping && state.mapping == nil,"automatic numbering can also be edited")
    state.editMapping(state.review!.id); try check(state.mapping != nil,"automatic review enters manual chooser")
    state.stop(); await state.close(); try await until { window.attachedSheet == nil }
    state.resolveMapping(cancelled,indices:[left:1,absent:2])
    try check(!state.hasPending && state.presentation == nil && handoffs == 1,"close revokes mapping and cannot reopen save")
    print("PASS immutable export numbering, one-sheet review lifecycle, explicit destination handoff and private saved output")
  }
  func projection() throws {
    var config = NativeSessionConfiguration(); config.shared = true
    config.fullscreenPolicy = try .init(mode:.all,selectedDisplays:[left,absent])
    let captured = try NativeDocumentExportCapture(endpoint:"snapshot.invalid",configuration:config)
    config.shared = false; config.fullscreenPolicy = .builtIn
    let export = try captured.makeExport(monitorIndices:[left:1,absent:Int(Int32.max)])
    let parsed = try NativeConnectionDocument(data:export.serializedData(acknowledging:export.losses))
    let result = try NativeDocumentResolution(document:parsed,monitorMapping:[1:left,Int(Int32.max):absent])
    try check(try result.configuration().shared && result.configuration().fullscreenPolicy.mode == .all,"capture retains dormant IDs and values across caller changes")
    for indices: [NativeDisplayID:Int] in [[:],[left:1],[left:0,absent:2],[left:1,absent:1],[left:1,absent:Int(Int32.max)+1],[left:1,absent:2,.init("extra"):3]] {
      try rejects(.displayMapping) { _ = try captured.makeExport(monitorIndices:indices) }
    }
    let request = NativeDocumentExportMapping(capture:captured)
    for invalid in ["","0","-1","+1","0x1","1.5","1e2","２","2147483648",String(repeating:"1",count:100)] {
      try rejects(.displayMapping) { _ = try request.indices(from:[left:invalid,absent:"2"]) }
    }
    try rejects(.displayMapping) { _ = try request.indices(from:[left:"1",absent:"01"]) }
    try check(try request.indices(from:[left:" 007 ",absent:"2147483647"]) == [left:7,absent:Int(Int32.max)],"bounded decimal input and whitespace canonicalize")
    config.tlsPriority = "custom"
    try rejects(.securityPolicy) { _ = try NativeDocumentExportCapture(endpoint:"",configuration:config) }
    config.tlsPriority = ""; config.caFile = "relative.pem"
    try rejects(.invalidConfiguration) { _ = try NativeDocumentExportCapture(endpoint:"",configuration:config) }
  }
}
@main struct NativeExportMappingUITests {
  @MainActor static func main() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = ExportMappingApp(); app.delegate = delegate
    let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
    let quit = NSMenuItem(title:"Quit Export Mapping Fixture",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    quit.target = app; submenu.addItem(quit); item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
  }
}
