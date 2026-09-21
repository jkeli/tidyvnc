// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
func document(_ body: String) throws -> NativeConnectionDocument {
  try NativeConnectionDocument(data:Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8))
}
final class Memory: NativePreferencesBacking, @unchecked Sendable {
  func read() -> Data? { nil }
  func write(_ data: Data) throws { throw Failure(message:"mapping must not write preferences") }
}
actor Reader: NativeDocumentReading {
  var bytes = Data("TidyVNC Configuration file Version 1.0\nServerName=fixture.invalid\nShared=on\nFullScreen=on\nFullScreenMode=Selected\nFullScreenSelectedMonitors=2,2147483647\nFuture=ignored\n".utf8)
  func read(_ url: URL) -> Data { bytes }
  func replace(_ bytes: Data) { self.bytes = bytes }
}
@MainActor final class Screens: NativeDisplaySource {
  var mirrored = true, removed = false
  func read() -> [NativeDisplay] {
    (removed ? [0] : [0,1]).map { index in
      let rect = NativeDisplayRectangle(x:mirrored ? 0 : Double(index*1000),y:0,width:1000,height:800)
      return NativeDisplay(id:.init(index == 0 ? "left" : "right"),name:index == 0 ? "Fixture Left" : "Fixture Right",
        bounds:rect,workArea:rect,backingScale:1,isPrimary:index == 0)
    }
  }
}
struct MappingFixtureView: View {
  @ObservedObject var loader: NativeSessionDefaults
  @ObservedObject var displays: NativeDisplayService
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      if let mapping = loader.invocationMapping {
        InvocationMonitorMappingView(mapping:mapping,displays:displays,issue:loader.invocationIssue,
          resolve:{ loader.resolveInvocationMapping(mapping.id,assignments:$0) },
          cancel:{ loader.cancelInvocationMapping(mapping.id) }).id(mapping.id)
      } else if let mapping = loader.documentMapping {
        DocumentMonitorMappingView(mapping:mapping,displays:displays,issue:loader.documentIssue,
          resolve:{ loader.resolveDocumentMapping(mapping.id,assignments:$0) },
          cancel:{ loader.cancelDocumentMapping(mapping.id) }).id(mapping.id)
      } else if let review = loader.documentReview {
        DocumentReviewView(review:review,displays:displays,editMapping:{ loader.editDocumentMapping(review.id) },
          accept:{ loader.acceptDocument(review.id) },cancel:{ loader.cancelDocument(review.id) })
      } else if loader.isReady {
        Text("Connection opened for \(loader.documentResolution?.endpoint ?? "")").font(.title2)
        Text("The fixture session is idle. No connection was started.")
      } else if let issue = loader.documentIssue {
        Text(issue)
        Button("Reload Connection File") { loader.load() }
      } else { ProgressView("Loading fixture…") }
    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
      .background(Color(nsColor:.windowBackgroundColor))
  }
}
@MainActor final class MappingTestApp: NSObject, NSApplicationDelegate {
  let reader = Reader(), screens = Screens()
  var runtime: NativeRuntime!, store: NativePreferencesStore!, displays: NativeDisplayService!, loader: NativeSessionDefaults!
  var window: NSWindow!, hosting: NSHostingController<MappingFixtureView>!
  var quitting = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      runtime = try NativeRuntime(); store = NativePreferencesStore(backing:Memory())
      displays = NativeDisplayService(source:screens)
      loader = NativeSessionDefaults(runtime:runtime,store:store,
        document:.init(url:URL(fileURLWithPath:"/fixture/mapping.tidyvnc")),documentReader:reader,
        documentDisplays:{ [displays] in displays!.refresh(); return (try? displays!.snapshot.documentMonitorOrder()) ?? [] },
        documentAvailableDisplays:{ [displays] in displays!.refresh(); return displays!.snapshot.displays.map(\.id) })
      window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:650),
        styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
      window.title = "Connection Display Mapping Fixture"; window.isReleasedWhenClosed = false
      hosting = NSHostingController(rootView:MappingFixtureView(loader:loader,displays:displays)); hosting.sizingOptions = []
      window.contentViewController = hosting; window.setContentSize(NSSize(width:720,height:650))
      window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
      loader.load()
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
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateNow }
    quitting = true; loader.stop()
    Task { @MainActor in
      await loader.close(); try? await runtime.shutdown(); await store.close(); displays.stop()
      window.close(); NSApp.reply(toApplicationShouldTerminate:true)
    }
    return .terminateLater
  }
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"mapping fixture timed out")
  }
  func render(_ name: String, dark: Bool = false) async throws {
    guard let view = window.contentView, let index = CommandLine.arguments.firstIndex(of:"--output"),
          index+1 < CommandLine.arguments.count else { throw Failure(message:"missing render path") }
    let root = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
    view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(100)); view.layoutSubtreeIfNeeded()
    let size = hosting.sizeThatFits(in:view.bounds.size)
    try check(size.width <= view.bounds.width && size.height <= view.bounds.height,"mapping content fits window")
    guard let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"missing bitmap") }
    view.cacheDisplay(in:view.bounds,to:image)
    try image.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name+".png"))
  }
  func verify() async throws {
    try resolution()
    try await until { loader.documentMapping != nil }
    let first = loader.documentMapping!
    try check(first.numbers == [2,2147483647] && first.suggested.isEmpty && loader.session == nil,"mirrors require explicit sparse mapping before session")
    try await render("mapping-light"); try await render("mapping-dark",dark:true)
    loader.resolveDocumentMapping(UUID(),assignments:[2:.init("left"),2147483647:.init("right")])
    try check(loader.documentMapping?.id == first.id,"stale mapping callback ignored")
    loader.resolveDocumentMapping(first.id,assignments:[2:.init("left")])
    try check(loader.documentIssue != nil && loader.session == nil,"incomplete mapping rejected")
    loader.resolveDocumentMapping(first.id,assignments:[2:.init("missing"),2147483647:.init("right")])
    try check(loader.documentMapping?.id == first.id && loader.documentReview == nil,"disconnected assignment rejected")
    await reader.replace(Data("invalid source changed after review".utf8))
    loader.resolveDocumentMapping(first.id,assignments:[2:.init("left"),2147483647:.init("right")])
    let reviewed = loader.documentReview!
    try check(loader.session == nil && reviewed.resolution.endpoint == "fixture.invalid" && reviewed.resolution.notices.count == 1,"mapping uses immutable source and requires final ignored-field review")
    try await render("review")
    loader.editDocumentMapping(UUID()); try check(loader.documentReview?.id == reviewed.id,"stale edit ignored")
    loader.editDocumentMapping(reviewed.id)
    let second = loader.documentMapping!
    try check(second.id != first.id,"editing replaces mapping identity")
    try check(second.suggested == reviewed.monitorMapping,"editing preserves connected explicit assignments")
    loader.resolveDocumentMapping(first.id,assignments:[2:.init("right"),2147483647:.init("right")])
    loader.acceptDocument(reviewed.id)
    try check(loader.documentMapping?.id == second.id && loader.session == nil,"old mapping/review cannot accept new draft")
    loader.resolveDocumentMapping(second.id,assignments:[2:.init("left"),2147483647:.init("left")])
    let combined = loader.documentReview!
    let config = try combined.resolution.configuration(acknowledging:Set(combined.resolution.notices.map(\.line)))
    try check(config.fullscreenPolicy.selectedDisplays == [.init("left")] && config.fullscreenPolicy.startsFullscreen,"explicit many-to-one uses one display and retains start policy")
    screens.removed = true; displays.refresh()
    loader.acceptDocument(combined.id)
    try check(loader.session == nil && loader.documentIssue == NativeDocumentOpenError.topologyChanged.description,"topology change invalidates mapped review")
    try check(loader.documentMapping != nil,"topology failure offers mapping of the retained document")
    await reader.replace(Data("TidyVNC Configuration file Version 1.0\nServerName=fixture.invalid\nFullScreenMode=Selected\nFullScreenSelectedMonitors=1\n".utf8))
    loader.load(); try await until { !loader.isLoading }
    let automatic = loader.documentReview!
    try check(automatic.monitorMapping == nil && automatic.resolution.monitorNumbers == [1],"resolvable numbering still supports automatic review")
    loader.editDocumentMapping(automatic.id)
    let editable = loader.documentMapping!
    try check(editable.suggested[1] == .init("left"),"automatic assignment is offered for editing")
    loader.cancelDocumentMapping(first.id); try check(loader.documentMapping != nil,"stale cancel ignored")
    loader.cancelDocumentMapping(editable.id)
    try check(loader.session == nil && loader.documentMapping == nil,"mapping cancel never creates session")
    loader.load(); try await until { !loader.isLoading }
    loader.editDocumentMapping(loader.documentReview!.id)
    screens.removed = false; screens.mirrored = true; displays.refresh()
    loader.resolveDocumentMapping(loader.documentMapping!.id,assignments:[1:.init("left")])
    let final = loader.documentReview!
    screens.mirrored = false; displays.refresh()
    loader.acceptDocument(final.id)
    try check(loader.isReady && loader.session?.snapshot.state == .idle && loader.documentResolution?.endpoint == "fixture.invalid","stable manual IDs survive rearrangement and create only an idle session")
    try await render("opened")
    loader.resolveDocumentMapping(editable.id,assignments:[1:.init("right")])
    try check(loader.documentResolution?.monitorNumbers == [1],"late mapping cannot mutate ready session")
    await loader.close()
    await reader.replace(Data("TidyVNC Configuration file Version 1.0\nShared=on\n".utf8))
    let invocation = NativeInvocationRequest(options:try .init(arguments:["-FullScreenMode=Selected","-FullScreenSelectedMonitors=99"]),
      endpoint:"cli.invalid",workingDirectory:"/fixture")
    loader = NativeSessionDefaults(runtime:runtime,store:store,invocation:invocation,
      document:.init(url:URL(fileURLWithPath:"/fixture/inherited.tidyvnc")),documentReader:reader,
      documentDisplays:{ [displays] in displays!.refresh(); return (try? displays!.snapshot.documentMonitorOrder()) ?? [] },
      documentAvailableDisplays:{ [displays] in displays!.refresh(); return displays!.snapshot.displays.map(\.id) })
    hosting.rootView = MappingFixtureView(loader:loader,displays:displays)
    loader.load(); try await until { !loader.isLoading }
    let cliMapping = loader.documentMapping!
    try check(cliMapping.monitorSource == .commandLine && cliMapping.numbers == [99],"chooser identifies inherited command-line selection")
    try await render("cli-mapping-light"); try await render("cli-mapping-dark",dark:true)
    loader.resolveDocumentMapping(cliMapping.id,assignments:[99:.init("right")])
    let cliReview = loader.documentReview!
    try check(cliReview.resolution.monitorSource == .commandLine && cliReview.resolution.resolvedMonitorMapping == [99:.init("right")],"review retains command-line origin and actual stable assignment")
    try await render("cli-review")
    loader.acceptDocument(cliReview.id)
    try check(loader.session?.initialFullscreenPolicy.selectedDisplays == [.init("right")] && loader.session?.snapshot.state == .idle,"inherited CLI choice reaches only reviewed idle session")
    await loader.close()
    loader = NativeSessionDefaults(runtime:runtime,store:store,invocation:invocation,
      documentDisplays:{ [displays] in displays!.refresh(); return (try? displays!.snapshot.documentMonitorOrder()) ?? [] },
      documentAvailableDisplays:{ [displays] in displays!.refresh(); return displays!.snapshot.displays.map(\.id) })
    hosting.rootView = MappingFixtureView(loader:loader,displays:displays)
    loader.load(); try await until { !loader.isLoading }
    let direct = loader.invocationMapping!
    try check(direct.numbers == [99] && loader.session == nil,"direct CLI waits for display choice")
    try await render("direct-cli-mapping")
    loader.resolveInvocationMapping(direct.id,assignments:[99:.init("left")])
    try check(loader.isReady && loader.invocationMapping == nil && loader.session?.initialFullscreenPolicy.selectedDisplays == [.init("left")],"direct CLI mapping installs final policy")
    print("PASS document, inherited and direct CLI monitor mapping, sparse bounds, immutable review, topology and admission")
  }
  func resolution() throws {
    let source = try document("FullScreen=on\nFullScreenMode=Selected\nFullScreenSelectedMonitors=2147483647,2,2")
    let result = try NativeDocumentResolution(document:source,monitorMapping:[2147483647:.init("right"),2:.init("left")])
    try check(result.monitorNumbers == [2,2147483647],"canonical sparse unique monitor numbers")
    try check(try result.configuration().fullscreenPolicy.selectedDisplays == [.init("left"),.init("right")],"explicit stable IDs resolve without legacy array")
    for assignments: [Int:NativeDisplayID] in [[:],[2:.init("left")],[2:.init("left"),2147483647:.init("right"),1:.init("extra")],[2:.init(""),2147483647:.init("right")]] {
      do { _ = try NativeDocumentResolution(document:source,monitorMapping:assignments); throw Failure(message:"invalid mapping accepted") }
      catch let error as NativeDocumentResolutionFailure { try check(error.reason == .displayMappingRequired,"mapping validation failure") }
    }
    let implicit = try NativeDocumentResolution(document:document("FullScreenMode=Selected"),monitorMapping:[1:.init("left")])
    try check(implicit.monitorNumbers == [1],"retained implicit monitor one can be mapped")
    let opaque = try NativeDocumentResolution(document:document("Audio=\\q\nFullScreenMode=Selected"),monitorMapping:[1:.init("left")])
    try check(opaque.notices.count == 1 && opaque.notices[0].kind == .platformOnly,"mapping leaves platform-only future escapes opaque")
    _ = try opaque.configuration(acknowledging:[2])
    var inherited = NativeSessionConfiguration()
    inherited.fullscreenPolicy = try .init(mode:.selected,selectedDisplays:[.init("saved")])
    let inheritedSelection = try NativeDocumentResolution(document:document("FullScreenMode=Selected"),base:inherited)
    try check(inheritedSelection.monitorNumbers.isEmpty,"inherited stable selection is not fabricated file numbering")
    let all = try NativeDocumentResolution(document:document("FullScreenMode=Selected\nFullScreenAllMonitors=on"))
    try check(all.monitorNumbers.isEmpty && (try all.configuration()).fullscreenPolicy.mode == .all,"deprecated all-monitor migration preserved")
    do {
      _ = try NativeDocumentResolution(document:document("Shared=invalid\nFullScreenSelectedMonitors=500"),monitorMapping:[500:.init("left")])
      throw Failure(message:"mapping bypassed known value validation")
    } catch is NativeDocumentFailure {}
    let oversized = try document("FullScreenSelectedMonitors="+(1...65).map(String.init).joined(separator:","))
    do {
      _ = try NativeDocumentMonitorMapping(document:oversized,base:.init(),workingDirectory:"/",legacyDisplays:[],available:[.init("left")])
      throw Failure(message:"unbounded mapping UI accepted")
    } catch let error as NativeDocumentResolutionFailure { try check(error.reason == .unrepresentableField,"bounded mapping controls") }
  }
}
@main struct NativeDocumentMappingUITests {
  @MainActor static func main() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = MappingTestApp(); app.delegate = delegate
    let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
    let quit = NSMenuItem(title:"Quit Mapping Fixture",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    quit.target = app; submenu.addItem(quit); item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
  }
}
