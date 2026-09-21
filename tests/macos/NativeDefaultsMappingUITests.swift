// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure(message:message) }
}
func source(_ body: String) -> Data { Data(("TidyVNC Configuration file Version 1.0\n"+body).utf8) }
final class Memory: NativePreferencesBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?
  func read() -> Data? { lock.withLock { bytes } }
  func write(_ value: Data) { lock.withLock { bytes = value } }
  func reset() { lock.withLock { bytes = nil } }
}
actor ReaderGate: NativeDocumentReading {
  let bytes: Data
  var continuation: CheckedContinuation<Void,Never>?
  init(_ bytes: Data) { self.bytes = bytes }
  func read(_ url: URL) async -> Data {
    await withCheckedContinuation { continuation = $0 }
    return bytes
  }
  func waiting() -> Bool { continuation != nil }
  func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class DefaultsMappingApp: NSObject, NSApplicationDelegate {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidyvnc-defaults-mapping-"+UUID().uuidString)
  let memory = Memory()
  let bytes = source("ServerName=private-endpoint.invalid\nPassword=private-password\nSecurityTypes=None\nX509CA=/private-ca.pem\nVia=private-tunnel\nFuture=private-unknown\\q\nAudio=\\q\nShared=on\nFullScreenMode=Selected\nFullScreenSelectedMonitors=2,2147483647\n")
  var store: NativePreferencesStore!, paths: NativeImportPaths!, service: NativeDefaultsImportService!
  var controller: DefaultsImportWindowController?
  var reversed = false, removed = false, quitting = false
  var snapshot: NativeDisplaySnapshot {
    let names = removed ? ["left"] : reversed ? ["right","left"] : ["left","right"]
    return NativeDisplaySnapshot(generation:reversed ? 2 : 1,displays:names.map { name in
      let rect = NativeDisplayRectangle(x:0,y:0,width:1000,height:800)
      return NativeDisplay(id:.init(name),name:name == "left" ? "Fixture Left" : "Fixture Right",bounds:rect,
        workArea:rect,backingScale:1,isPrimary:name == "left")
    },error:nil)
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      paths = try NativeImportPaths(homeDirectory:root.path,environment:[:])
      for url in [paths.currentDefaults,paths.legacyDefaults[0]] {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:url)
      }
      store = NativePreferencesStore(backing:memory); service = NativeDefaultsImportService(paths:paths,store:store)
      showImport(); NSApp.activate(ignoringOtherApps:true)
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
  func showImport() {
    controller = DefaultsImportWindowController(service:service,displays:{ [weak self] in self!.snapshot },
      openConnection:{},onClosed:{ [weak self] closed in if self?.controller === closed { self?.controller = nil } })
    controller?.showWindow(nil)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateNow }
    quitting = true
    Task { @MainActor in
      await controller?.shutdown(); await store.close(); try? FileManager.default.removeItem(at:root)
      NSApp.reply(toApplicationShouldTerminate:true)
    }
    return .terminateLater
  }
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
    throw Failure(message:"Defaults mapping fixture timed out")
  }
  func render(_ name: String, dark: Bool = false) async throws {
    guard let window = controller?.window, let view = window.contentView,
          let index = CommandLine.arguments.firstIndex(of:"--output"), index+1 < CommandLine.arguments.count else { throw Failure(message:"missing render context") }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
    view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(100)); view.layoutSubtreeIfNeeded()
    guard let fitting = controller?.contentSizeThatFits(view.bounds.size) else { throw Failure(message:"missing content") }
    try check(fitting.width <= view.bounds.width && fitting.height <= view.bounds.height,"defaults mapping fits window")
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"missing bitmap") }
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
  }
  func verify() async throws {
    try await preflight()
    let state = controller!.state
    state.begin(origin:.legacy,legacyDisplays:[],availableDisplays:snapshot.displays.map(\.id))
    try await until { !state.hasPending }
    try check(state.issue == NativeImportSourceError.currentSourceExists.description,"mapping does not bypass current-over-legacy precedence")
    state.begin(origin:.currentXDG,legacyDisplays:[],availableDisplays:snapshot.displays.map(\.id))
    try await until { state.mapping != nil }
    let first = state.mapping!
    try check(first.numbers == [2,2147483647] && first.suggested.isEmpty && state.review == nil,"mirrors/unavailable indices require explicit sparse mapping")
    let retained = first.projection.document.entries
    try check(Set(retained.map(\.name)) == ["Shared","FullScreenMode","FullScreenSelectedMonitors"],"recovery retains only allowed settings")
    try check(!retained.contains { $0.encodedValue.contains("private-") },"excluded and unknown values are absent from retained recovery")
    try await render("mapping-light"); try await render("mapping-dark",dark:true)
    state.resolveMapping(UUID(),assignments:[2:.init("left"),2147483647:.init("right")],availableDisplays:snapshot.displays.map(\.id))
    try check(state.mapping?.id == first.id,"stale mapping ignored")
    state.resolveMapping(first.id,assignments:[2:.init("left")],availableDisplays:snapshot.displays.map(\.id))
    try check(state.issue != nil && state.mapping != nil && memory.read() == nil,"incomplete mapping cannot write")
    state.resolveMapping(first.id,assignments:[2:.init("missing"),2147483647:.init("right")],availableDisplays:snapshot.displays.map(\.id))
    try check(state.mapping != nil,"disconnected assignments rejected")
    let changed = source("Shared=off\nPassword=other-private-password")
    try changed.write(to:paths.currentDefaults)
    state.resolveMapping(first.id,assignments:[2:.init("left"),2147483647:.init("right")],availableDisplays:snapshot.displays.map(\.id))
    let reviewed = state.review!
    let ack = Set(reviewed.proposal.notices.map(\.line))
    try check(try reviewed.proposal.preferences(acknowledging:ack).shared == true,"mapping does not reread changed source")
    try check(reviewed.proposal.notices.contains { $0.kind == .excluded } && reviewed.proposal.notices.contains { $0.kind == .platformOnly },"omission review survives filtering and mapping")
    state.approve(reviewed.id,acknowledging:[],currentDisplays:snapshot.displays.map(\.id))
    try check(state.review != nil && memory.read() == nil,"mapping does not grant omission consent")
    try await render("review")
    state.editMapping(reviewed.id,legacyDisplays:[],availableDisplays:snapshot.displays.map(\.id))
    let second = state.mapping!
    try check(second.id != first.id && second.suggested == reviewed.monitorMapping,"re-edit preserves explicit choices with fresh identity")
    state.resolveMapping(first.id,assignments:[2:.init("left"),2147483647:.init("left")],availableDisplays:snapshot.displays.map(\.id))
    state.approve(reviewed.id,acknowledging:ack,currentDisplays:snapshot.displays.map(\.id))
    try check(state.mapping?.id == second.id,"stale approval cannot bypass current mapping")
    state.resolveMapping(second.id,assignments:[2:.init("left"),2147483647:.init("left")],availableDisplays:snapshot.displays.map(\.id))
    let candidate = state.review!
    removed = true
    state.approve(candidate.id,acknowledging:Set(candidate.proposal.notices.map(\.line)),currentDisplays:snapshot.displays.map(\.id))
    try await until { !state.hasPending }
    try check(state.issue == NativeImportSourceError.topologyChanged.description && memory.read() == nil,"changed availability rejects final import")
    removed = false; try bytes.write(to:paths.currentDefaults)
    state.begin(origin:.currentXDG,legacyDisplays:[],availableDisplays:snapshot.displays.map(\.id))
    try await until { state.mapping != nil }
    state.resolveMapping(state.mapping!.id,assignments:[2:.init("left"),2147483647:.init("left")],availableDisplays:snapshot.displays.map(\.id))
    let accepted = state.review!; reversed = true
    state.approve(accepted.id,acknowledging:Set(accepted.proposal.notices.map(\.line)),currentDisplays:snapshot.displays.map(\.id))
    try await until { state.imported != nil }
    try check(state.imported?.values.shared == true && state.imported?.values.security == nil,"only allowed values committed")
    try check(state.imported?.values.fullscreen?.selectedDisplays == ["left"] && state.imported?.importedFrom == .currentXDG,"many-to-one mapping and origin commit together")
    try check(!String(decoding:memory.read()!,as:UTF8.self).contains("private-"),"native record excludes source private values")
    try check(try Data(contentsOf:paths.currentDefaults) == bytes,"original source remains unchanged")
    try await render("success")
    await controller?.shutdown(); memory.reset(); showImport()
    let replacement = controller!.state
    replacement.begin(origin:.currentXDG,legacyDisplays:[],availableDisplays:snapshot.displays.map(\.id))
    try await until { replacement.mapping != nil }
    let cancelled = replacement.mapping!.id
    replacement.cancel(cancelled)
    try check(!replacement.hasPending && memory.read() == nil,"mapping cancellation leaves no marker")
    replacement.begin(origin:.currentXDG,legacyDisplays:[],availableDisplays:snapshot.displays.map(\.id))
    try await until { replacement.mapping != nil }
    let closing = replacement.mapping!.id
    await controller?.shutdown()
    replacement.resolveMapping(closing,assignments:[2:.init("left"),2147483647:.init("right")],availableDisplays:snapshot.displays.map(\.id))
    try check(!replacement.hasPending && replacement.mapping == nil && memory.read() == nil,"close revokes mapping callbacks")
    print("PASS filtered defaults mapping, separate omission consent, immutable source, topology, origin and close lifecycle")
  }
  func preflight() async throws {
    let malformed = source("Shared=broken\nFullScreenSelectedMonitors=500")
    try malformed.write(to:paths.currentDefaults)
    do { _ = try await service.prepareWithMapping(origin:.currentXDG,legacyDisplays:[],availableDisplays:[.init("left")]); throw Failure(message:"invalid known value reached mapping") }
    catch is NativeDocumentFailure {}
    try source("Shared=on\nFullScreenMode=Selected\nFullScreenSelectedMonitors=2").write(to:paths.currentDefaults)
    let automatic = NativeDefaultsImportState(service:service)
    automatic.begin(origin:.currentXDG,legacyDisplays:[.init("left"),.init("right")],availableDisplays:[.init("left"),.init("right")])
    try await until { automatic.review != nil }
    let originalReview = automatic.review!
    try check(automatic.canEditMapping && originalReview.monitorNumbers == [2],"automatic import offers mapping edit")
    automatic.editMapping(originalReview.id,legacyDisplays:[.init("left"),.init("right")],availableDisplays:[.init("left"),.init("right")])
    try check(automatic.mapping?.suggested == [2:.init("right")],"automatic mapping remains a suggestion")
    automatic.resolveMapping(automatic.mapping!.id,assignments:[2:.init("left")],availableDisplays:[.init("left"),.init("right")])
    try check(automatic.review?.id != originalReview.id && automatic.review?.monitorMapping == [2:.init("left")],"automatic mapping can be replaced with a fresh review")
    await automatic.close()
    try bytes.write(to:paths.currentDefaults)
    guard case .mapping(let pending) = try await service.prepareWithMapping(origin:.currentXDG,legacyDisplays:[],availableDisplays:[.init("left")]) else { throw Failure(message:"missing mapping preflight") }
    let reviewed = try pending.resolve([2:.init("left"),2147483647:.init("left")],availableDisplays:[.init("left")])
    let before = try await store.read()
    _ = try await store.commit(.init(shared:false),expected:before.revision)
    do { _ = try await service.commit(reviewed,acknowledging:Set(reviewed.proposal.notices.map(\.line)),currentDisplays:[.init("left")]); throw Failure(message:"native data overwritten") }
    catch NativePreferencesError.conflict {}
    memory.reset()
    let gate = ReaderGate(bytes), delayed = NativeDefaultsImportState(service:NativeDefaultsImportService(paths:paths,store:store,reader:gate))
    let id = delayed.begin(origin:.currentXDG,legacyDisplays:[],availableDisplays:[.init("left")])!
    for _ in 0..<2000 { if await gate.waiting() { break }; try await Task.sleep(for:.milliseconds(2)) }
    let waiting = await gate.waiting()
    try check(waiting,"reader gate reached")
    delayed.cancel(id)
    try check(delayed.hasPending && delayed.begin(origin:.legacy,legacyDisplays:[]) == nil,"cancelled source read drains")
    await gate.release(); try await until { !delayed.hasPending }
    try check(delayed.mapping == nil && delayed.review == nil && memory.read() == nil,"late source read cannot publish mapping")
    await delayed.close()
  }
}
@main struct NativeDefaultsMappingUITests {
  @MainActor static func main() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = DefaultsMappingApp(); app.delegate = delegate
    let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
    let quit = NSMenuItem(title:"Quit Defaults Mapping Fixture",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    quit.target = app; submenu.addItem(quit); item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
  }
}
